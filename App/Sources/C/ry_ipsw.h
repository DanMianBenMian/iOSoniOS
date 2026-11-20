#ifndef RY_IPSW_H
#define RY_IPSW_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Extracts kernelcache.release.* from an IPSW and writes the decompressed
 * Mach-O to out_path. Returns 0 on success; `detail` receives a message. */
int ry_ipsw_extract_bootkc(const char *ipsw_path, const char *out_path,
                           uint64_t *out_size, char *detail, size_t detail_len);

#ifdef __cplusplus
}
#endif
#endif
