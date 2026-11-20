/*
 * Minimal Mach-O loader for XNU kernelcaches.
 *
 * iOS kernelcaches are MH_FILESET: the real kernel is a nested Mach-O named
 * com.apple.kernel inside the fileset. We locate it, copy its segments into
 * guest RAM at their vmaddrs, and hand back the entry point.
 *
 * This is the physical-memory half of a boot. iBoot would also build a boot
 * args structure and set up the device tree registers; we hand over a pointer to
 * a zeroed boot-args page and let the kernel fail loudly if it needs more, which
 * is visible in the log instead of guessing.
 */
#include <stdint.h>
#include <string.h>

#include "ry_macho.h"

#define MH_MAGIC_64     0xfeedfacfu
#define MH_FILESET      0xcu
#define LC_SEGMENT_64   0x19u
#define LC_UNIXTHREAD   0x5u
#define LC_MAIN         0x80000028u
#define LC_FILESET_ENTRY 0x80000035u
#define ARM_THREAD_STATE64 6u

typedef struct {
    uint32_t magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved;
} MachHeader64;

typedef struct {
    uint32_t cmd, cmdsize;
    char segname[16];
    uint64_t vmaddr, vmsize, fileoff, filesize;
    uint32_t maxprot, initprot, nsects, flags;
} SegmentCommand64;

typedef struct {
    uint32_t cmd, cmdsize;
    uint64_t vmaddr, vmsize;
    uint64_t fileoff;
    uint32_t entry_id, reserved;
} FilesetEntryCommand;

static uint32_t rd32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static uint64_t rd64(const uint8_t *p) {
    return (uint64_t)rd32(p) | ((uint64_t)rd32(p + 4) << 32);
}

/* Returns the offset of the nested kernel Mach-O inside the file, or 0. */
static uint64_t find_kernel_offset(const uint8_t *data, uint64_t len, const char **name_out) {
    if (len < sizeof(MachHeader64)) return 0;
    const MachHeader64 *mh = (const MachHeader64 *)data;
    if (mh->magic != MH_MAGIC_64) return 0;
    if (mh->filetype != MH_FILESET) return 0;

    uint64_t off = sizeof(MachHeader64);
    for (uint32_t i = 0; i < mh->ncmds && off + 8 <= len; i++) {
        const uint8_t *cmd = data + off;
        uint32_t cmdsize = rd32(cmd + 4);
        if (cmdsize < 8 || off + cmdsize > len) break;
        uint32_t c = rd32(cmd);
        if (c == LC_FILESET_ENTRY) {
            const FilesetEntryCommand *fe = (const FilesetEntryCommand *)cmd;
            const char *name = (const char *)(cmd + sizeof(FilesetEntryCommand));
            if (strstr(name, "com.apple.kernel") && !strstr(name, "collection")) {
                if (name_out) *name_out = name;
                return fe->fileoff;
            }
        }
        off += cmdsize;
    }
    return 0;
}

/* Copies every segment with file content into `ram`, and reports where the
 * entry point is. `ram_size` bounds the writes. */
int macho_load_kernel(const uint8_t *data, uint64_t len, uint8_t *ram, uint64_t ram_size,
                      uint64_t load_bias, uint64_t *entry_out, MachoInfo *info) {
    if (info) memset(info, 0, sizeof(*info));

    const char *name = NULL;
    uint64_t base = find_kernel_offset(data, len, &name);
    if (base == 0) {
        /* Not a fileset: treat the file itself as the kernel image. */
        base = 0;
    } else if (info) {
        info->fileset = 1;
        if (name) {
            strncpy(info->nested_name, name, sizeof(info->nested_name) - 1);
        }
    }

    if (base + sizeof(MachHeader64) > len) return -1;
    const MachHeader64 *mh = (const MachHeader64 *)(data + base);
    if (mh->magic != MH_MAGIC_64) return -2;

    uint64_t entry = 0;
    uint64_t text_vm = 0;
    int segs = 0;

    uint64_t off = base + sizeof(MachHeader64);
    for (uint32_t i = 0; i < mh->ncmds && off + 8 <= len; i++) {
        const uint8_t *cmd = data + off;
        uint32_t cmdsize = rd32(cmd + 4);
        if (cmdsize < 8 || off + cmdsize > len) break;
        uint32_t c = rd32(cmd);

        if (c == LC_SEGMENT_64 && cmdsize >= sizeof(SegmentCommand64)) {
            const SegmentCommand64 *sg = (const SegmentCommand64 *)cmd;
            if (sg->filesize > 0) {
                uint64_t dst = sg->vmaddr + load_bias;
                uint64_t src = base + sg->fileoff;
                if (dst < ram_size && src + sg->filesize <= len) {
                    uint64_t n = sg->filesize;
                    if (dst + n > ram_size) n = ram_size - dst;
                    memcpy(ram + dst, data + src, (size_t)n);
                    segs++;
                    if (strcmp(sg->segname, "__TEXT") == 0) text_vm = dst;
                }
            }
            if (info) info->total_vmsize += sg->vmsize;
        } else if (c == LC_MAIN && cmdsize >= 24) {
            uint64_t entryoff = rd64(cmd + 8);
            entry = (text_vm ? text_vm : load_bias) + entryoff;
        } else if (c == LC_UNIXTHREAD) {
            /* ARM_THREAD_STATE64: flavor 6, count 68, x0..x28, fp, lr, sp, pc, cpsr */
            const uint8_t *st = cmd + 16;
            if (cmdsize >= 16 + 34 * 8) {
                uint64_t pc = rd64(st + 32 * 8);
                if (pc) entry = pc + load_bias;
            }
        }
        off += cmdsize;
    }

    if (entry == 0) entry = text_vm + 0x1000;   /* conservative fallback */
    *entry_out = entry;
    if (info) {
        info->segments = segs;
        info->entry = entry;
        info->text_vmaddr = text_vm;
    }
    return 0;
}
