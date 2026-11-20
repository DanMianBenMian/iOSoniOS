#ifndef RY_MACHO_H
#define RY_MACHO_H

#include <stdint.h>

typedef struct {
    int fileset;              /* 1 when the image was an MH_FILESET container */
    char nested_name[64];     /* name of the nested image we loaded */
    int segments;             /* segments copied into RAM */
    uint64_t total_vmsize;
    uint64_t text_vmaddr;
    uint64_t entry;
} MachoInfo;

#ifdef __cplusplus
extern "C" {
#endif

/* Loads a kernelcache into `ram` (flat physical, base 0) and reports the entry
 * point. Returns 0 on success, negative on a bad header. */
int macho_load_kernel(const uint8_t *data, uint64_t len, uint8_t *ram, uint64_t ram_size,
                      uint64_t load_bias, uint64_t *entry_out, MachoInfo *info);

#ifdef __cplusplus
}
#endif
#endif
