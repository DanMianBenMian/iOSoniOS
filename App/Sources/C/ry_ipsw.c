/*
 * In-app IPSW -> bootkc extraction.
 *
 * An IPSW is a (very large) zip. The kernel lives at
 *   kernelcache.release.<board>
 * as an IMG4/IM4P container whose payload is LZFSE-compressed. Extracting it
 * needs three layers:
 *
 *   zip central directory -> raw deflate  (zlib)
 *   IM4P/DER walk        -> OCTET STRING  (payload)
 *   LZFSE payload        -> raw Mach-O    (libcompression)
 *
 * We never read the whole 10 GB: the zip directory is located by seeking to the
 * end, and only the one entry's bytes are pulled in.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <zlib.h>
#include <compression.h>

#include "ry_ipsw.h"

#define EOCD_SIG      0x06054b50u
#define EOCD64_SIG    0x06064b50u
#define EOCD64_LOC_SIG 0x07064b50u
#define CEN_SIG       0x02014b50u
#define LOC_SIG       0x04034b50u

static uint32_t rd32f(FILE *f) {
    uint8_t b[4];
    if (fread(b, 1, 4, f) != 4) return 0;
    return (uint32_t)b[0] | ((uint32_t)b[1] << 8) | ((uint32_t)b[2] << 16) | ((uint32_t)b[3] << 24);
}

static uint64_t rd64f(FILE *f) {
    uint32_t lo = rd32f(f);
    uint32_t hi = rd32f(f);
    return (uint64_t)lo | ((uint64_t)hi << 32);
}

/* Locate the central directory. Handles the zip64 case, which an IPSW uses
 * because its entries sit past 4 GiB. */
static int find_central_dir(FILE *f, long long file_size,
                            uint64_t *cd_offset, uint64_t *cd_size, uint64_t *entries) {
    long long tail = file_size < (1 << 17) ? file_size : (1 << 17);
    uint8_t *buf = (uint8_t *)malloc((size_t)tail);
    if (!buf) return -1;
    if (fseek(f, file_size - tail, SEEK_SET) != 0) { free(buf); return -1; }
    if (fread(buf, 1, (size_t)tail, f) != (size_t)tail) { free(buf); return -1; }

    long long eocd_pos = -1;
    for (long long i = tail - 22; i >= 0; i--) {
        if (buf[i] == 0x50 && buf[i + 1] == 0x4b && buf[i + 2] == 0x05 && buf[i + 3] == 0x06) {
            eocd_pos = i;
            break;
        }
    }
    if (eocd_pos < 0) { free(buf); return -1; }

    uint32_t ent32 = 0, cd32 = 0;
    memcpy(&ent32, buf + eocd_pos + 10, 4);
    memcpy(&cd32, buf + eocd_pos + 16, 4);

    int need64 = (ent32 == 0xffffffffu || cd32 == 0xffffffffu);

    /* Zip64 EOCD locator sits 20 bytes before the EOCD. */
    if (need64 && eocd_pos >= 20) {
        uint32_t locsig = 0;
        memcpy(&locsig, buf + eocd_pos - 20, 4);
        if (locsig == EOCD64_LOC_SIG) {
            uint64_t eocd64_off = 0;
            memcpy(&eocd64_off, buf + eocd_pos - 20 + 8, 8);
            free(buf);
            if (fseek(f, (long long)eocd64_off, SEEK_SET) != 0) return -1;
            uint32_t sig = rd32f(f);
            if (sig != EOCD64_SIG) return -1;
            (void)rd64f(f);                 /* size of record */
            fseek(f, 4, SEEK_CUR);          /* version made/needed */
            fseek(f, 8, SEEK_CUR);          /* disk numbers */
            *entries = rd64f(f);
            *entries = rd64f(f);            /* total entries */
            *cd_size = rd64f(f);
            *cd_offset = rd64f(f);
            return 0;
        }
    }

    free(buf);
    *entries = ent32;
    *cd_size = cd32;
    *cd_offset = cd32;
    return 0;
}

/* Walk central-directory entries looking for the kernelcache. */
static int find_kernel_entry(FILE *f, uint64_t cd_offset, uint64_t entries,
                             uint64_t *local_off, uint64_t *comp_size,
                             uint64_t *uncomp_size, uint16_t *method,
                             char *name_out, size_t name_len_max) {
    if (fseek(f, (long long)cd_offset, SEEK_SET) != 0) return -1;
    for (uint64_t i = 0; i < entries; i++) {
        uint8_t hdr[46];
        if (fread(hdr, 1, 46, f) != 46) return -1;
        uint32_t sig = (uint32_t)hdr[0] | ((uint32_t)hdr[1] << 8)
                     | ((uint32_t)hdr[2] << 16) | ((uint32_t)hdr[3] << 24);
        if (sig != CEN_SIG) return -1;

        uint16_t entry_method = (uint16_t)(hdr[10] | (hdr[11] << 8));
        uint32_t csize = (uint32_t)hdr[20] | ((uint32_t)hdr[21] << 8)
                       | ((uint32_t)hdr[22] << 16) | ((uint32_t)hdr[23] << 24);
        uint32_t usize = (uint32_t)hdr[24] | ((uint32_t)hdr[25] << 8)
                       | ((uint32_t)hdr[26] << 16) | ((uint32_t)hdr[27] << 24);
        uint16_t name_len = (uint16_t)(hdr[28] | (hdr[29] << 8));
        uint16_t extra_len = (uint16_t)(hdr[30] | (hdr[31] << 8));
        uint16_t comment_len = (uint16_t)(hdr[32] | (hdr[33] << 8));
        uint32_t loff32 = (uint32_t)hdr[42] | ((uint32_t)hdr[43] << 8)
                        | ((uint32_t)hdr[44] << 16) | ((uint32_t)hdr[45] << 24);

        char name[512];
        size_t take = name_len < sizeof(name) - 1 ? name_len : sizeof(name) - 1;
        if (take && fread(name, 1, take, f) != take) return -1;
        name[take] = 0;
        if (name_len > take) fseek(f, name_len - (uint16_t)take, SEEK_CUR);

        uint64_t local = loff32, cs = csize, us = usize;

        if (csize == 0xffffffffu || usize == 0xffffffffu || loff32 == 0xffffffffu) {
            /* zip64 extra: values appear in this order when the field was 0xFFFFFFFF */
            uint8_t extra[512];
            size_t ex = extra_len < sizeof(extra) ? extra_len : sizeof(extra);
            if (ex && fread(extra, 1, ex, f) == ex) {
                size_t p = 0;
                while (p + 4 <= ex) {
                    uint16_t id = (uint16_t)(extra[p] | (extra[p + 1] << 8));
                    uint16_t sz = (uint16_t)(extra[p + 2] | (extra[p + 3] << 8));
                    p += 4;
                    if (p + sz > ex) break;
                    if (id == 0x0001) {
                        size_t q = p;
                        if (usize == 0xffffffffu && q + 8 <= p + sz) {
                            memcpy(&us, extra + q, 8); q += 8;
                        }
                        if (csize == 0xffffffffu && q + 8 <= p + sz) {
                            memcpy(&cs, extra + q, 8); q += 8;
                        }
                        if (loff32 == 0xffffffffu && q + 8 <= p + sz) {
                            memcpy(&local, extra + q, 8); q += 8;
                        }
                        break;
                    }
                    p += sz;
                }
            }
            if (extra_len > ex) fseek(f, extra_len - (uint16_t)ex, SEEK_CUR);
        } else {
            fseek(f, extra_len, SEEK_CUR);
        }
        fseek(f, comment_len, SEEK_CUR);

        if (strncmp(name, "kernelcache.release.", 20) == 0 || strcmp(name, "kernelcache") == 0) {
            if (name_out) {
                size_t n = strlen(name);
                if (n >= name_len_max) n = name_len_max - 1;
                memcpy(name_out, name, n);
                name_out[n] = 0;
            }
            *local_off = local;
            *comp_size = cs;
            *uncomp_size = us;
            *method = entry_method;
            return 0;
        }
    }
    return -1;
}

/* inflate a zip entry's data */
static uint8_t *inflate_entry(FILE *f, uint64_t local_off, uint64_t comp_size,
                              uint64_t uncomp_size, uint16_t method, uint64_t *out_len) {
    if (fseek(f, (long long)local_off, SEEK_SET) != 0) return NULL;
    uint8_t lh[30];
    if (fread(lh, 1, 30, f) != 30) return NULL;
    uint32_t sig = (uint32_t)lh[0] | ((uint32_t)lh[1] << 8)
                 | ((uint32_t)lh[2] << 16) | ((uint32_t)lh[3] << 24);
    if (sig != LOC_SIG) return NULL;
    uint16_t name_len = (uint16_t)(lh[26] | (lh[27] << 8));
    uint16_t extra_len = (uint16_t)(lh[28] | (lh[29] << 8));
    fseek(f, name_len + extra_len, SEEK_CUR);

    if (comp_size > (512ull << 20)) return NULL;      /* sanity */
    uint8_t *cbuf = (uint8_t *)malloc((size_t)comp_size);
    if (!cbuf) return NULL;
    if (fread(cbuf, 1, (size_t)comp_size, f) != (size_t)comp_size) { free(cbuf); return NULL; }

    if (method == 0) {                                 /* stored */
        *out_len = comp_size;
        return cbuf;
    }
    if (method != 8) { free(cbuf); return NULL; }       /* only deflate */

    uint8_t *out = (uint8_t *)malloc((size_t)uncomp_size);
    if (!out) { free(cbuf); return NULL; }
    z_stream zs;
    memset(&zs, 0, sizeof(zs));
    if (inflateInit2(&zs, -15) != Z_OK) { free(cbuf); free(out); return NULL; }
    zs.next_in = cbuf;
    zs.avail_in = (uInt)comp_size;
    zs.next_out = out;
    zs.avail_out = (uInt)uncomp_size;
    int rc = inflate(&zs, Z_FINISH);
    inflateEnd(&zs);
    free(cbuf);
    if (rc != Z_STREAM_END) { free(out); return NULL; }
    *out_len = uncomp_size;
    return out;
}

/* Walk the IM4P DER wrapper and return a pointer to the OCTET STRING payload. */
static const uint8_t *im4p_payload(const uint8_t *d, size_t len, size_t *pay_len) {
    if (len < 12) return NULL;
    /* The outer SEQUENCE's length can use 1/2/4 length-of-length bytes, so the
     * "IM4P" IA5String is NOT at a fixed offset (real 27b2 kernelcache:
     * 30 84 <4 len> 16 04 "IM4P" ... — magic sits at byte 8, not 6).
     * Search the DER header window instead of assuming a fixed position. */
    size_t scan = len < 32 ? len : 32;
    int has_im4p = 0;
    for (size_t k = 0; k + 4 <= scan; k++) {
        if (memcmp(d + k, "IM4P", 4) == 0) { has_im4p = 1; break; }
    }
    if (!has_im4p) return NULL;

    size_t i = 2;
    if (d[1] == 0x84) i = 6;
    else if (d[1] == 0x83) i = 5;
    else if (d[1] == 0x82) i = 4;

    while (i + 6 < len) {
        if (d[i] == 0x04 && d[i + 1] == 0x84) {
            uint32_t n = ((uint32_t)d[i + 2] << 24) | ((uint32_t)d[i + 3] << 16)
                       | ((uint32_t)d[i + 4] << 8) | (uint32_t)d[i + 5];
            if ((uint64_t)i + 6 + n <= len) {
                *pay_len = n;
                return d + i + 6;
            }
            return NULL;
        }
        if (d[i] == 0x04 && d[i + 1] == 0x83) {
            uint32_t n = ((uint32_t)d[i + 2] << 16) | ((uint32_t)d[i + 3] << 8) | d[i + 4];
            if ((uint64_t)i + 5 + n <= len) { *pay_len = n; return d + i + 5; }
            return NULL;
        }
        if (d[i] == 0x16) {                 /* IA5String (type/description) */
            size_t n = d[i + 1];
            i += 2 + n;
            continue;
        }
        if (d[i] == 0x30) {
            size_t n = d[i + 1];
            i += 2 + n;
            continue;
        }
        i++;
    }
    return NULL;
}

/* Grow the destination until libcompression succeeds. */
static uint8_t *lzfse_decode(const uint8_t *src, size_t src_len, size_t *out_len) {
    size_t cap = 64ull << 20;
    for (int attempt = 0; attempt < 4; attempt++) {
        uint8_t *dst = (uint8_t *)malloc(cap);
        if (!dst) return NULL;
        size_t n = compression_decode_buffer(dst, cap, src, src_len, NULL,
                                             COMPRESSION_LZFSE);
        if (n > 0 && n < cap) { *out_len = n; return dst; }
        free(dst);
        cap *= 2;
    }
    return NULL;
}

int ry_ipsw_extract_bootkc(const char *ipsw_path, const char *out_path,
                           uint64_t *out_size, char *detail, size_t detail_len) {
    FILE *f = fopen(ipsw_path, "rb");
    if (!f) {
        snprintf(detail, detail_len, "打不开 IPSW");
        return -1;
    }
    fseek(f, 0, SEEK_END);
    long long size = ftell(f);
    fseek(f, 0, SEEK_SET);

    uint64_t cd_off = 0, cd_size = 0, entries = 0;
    if (find_central_dir(f, size, &cd_off, &cd_size, &entries) != 0) {
        snprintf(detail, detail_len, "找不到 zip 目录");
        fclose(f);
        return -2;
    }

    uint64_t local = 0, csize = 0, usize = 0;
    uint16_t method = 0;
    char name[256] = {0};
    if (find_kernel_entry(f, cd_off, entries, &local, &csize, &usize, &method,
                          name, sizeof(name)) != 0) {
        snprintf(detail, detail_len, "IPSW 里没有 kernelcache（共 %llu 个条目）",
                 (unsigned long long)entries);
        fclose(f);
        return -3;
    }

    uint64_t im4p_len = 0;
    uint8_t *im4p = inflate_entry(f, local, csize, usize, method, &im4p_len);
    fclose(f);
    if (!im4p) {
        snprintf(detail, detail_len, "解压 %s 失败", name);
        return -4;
    }

    size_t pay_len = 0;
    const uint8_t *pay = im4p_payload(im4p, (size_t)im4p_len, &pay_len);
    if (!pay) {
        snprintf(detail, detail_len, "%s 不是有效的 IM4P", name);
        free(im4p);
        return -5;
    }

    /* Either already a Mach-O, or LZFSE-compressed. */
    uint8_t *image = NULL;
    size_t image_len = 0;
    if (pay_len >= 4 && pay[0] == 0xcf && pay[1] == 0xfa && pay[2] == 0xed && pay[3] == 0xfe) {
        image = (uint8_t *)malloc(pay_len);
        if (image) { memcpy(image, pay, pay_len); image_len = pay_len; }
    } else if (pay_len >= 4 && memcmp(pay, "bvx2", 4) == 0) {
        image = lzfse_decode(pay, pay_len, &image_len);
    }
    free(im4p);

    if (!image) {
        snprintf(detail, detail_len, "%s 的负载解压失败（不支持的格式）", name);
        return -6;
    }

    FILE *o = fopen(out_path, "wb");
    if (!o) {
        snprintf(detail, detail_len, "无法写入 %s", out_path);
        free(image);
        return -7;
    }
    size_t written = fwrite(image, 1, image_len, o);
    fclose(o);
    free(image);

    if (written != image_len) {
        snprintf(detail, detail_len, "写入不完整");
        return -8;
    }
    if (out_size) *out_size = (uint64_t)written;
    snprintf(detail, detail_len, "%s → bootkc，%llu MiB",
             name, (unsigned long long)(written >> 20));
    return 0;
}
