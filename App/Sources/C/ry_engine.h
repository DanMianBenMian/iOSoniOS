#ifndef RY_ENGINE_H
#define RY_ENGINE_H

#include <stdint.h>

typedef struct {
    int ok;
    int stage;
    uint64_t ram_bytes;
    uint64_t jit_bytes;
    uint32_t sample_result;
    char detail[256];
} RyEngineStatus;

#ifdef __cplusplus
extern "C" {
#endif

/* Creates the Henge machine: JIT region, guest RAM, one CPU. */
int ry_engine_init(uint64_t ram_bytes, uint64_t jit_bytes, RyEngineStatus *out);
/* Runs a 2-instruction program and checks the result. Proves translation works. */
int ry_engine_selftest(RyEngineStatus *out);
/* Copies a kernel image into guest RAM at a physical address. */
int ry_engine_load(const void *data, uint64_t len, uint64_t pa, RyEngineStatus *out);
/* Sets PC and runs. Returns the engine's hv_run result. */
int ry_engine_run_at(uint64_t pc, RyEngineStatus *out);
void ry_engine_shutdown(void);

const char *ry_engine_detail(const RyEngineStatus *s);

#ifdef __cplusplus
}
#endif
#endif
