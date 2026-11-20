#ifndef RY_ENGINE_H
#define RY_ENGINE_H

#include <stdint.h>

/* Which backend executed the guest. */
enum {
    RY_BACKEND_NONE   = 0,
    RY_BACKEND_INTERP = 1,   /* ry_interp.c: plain C, no executable memory */
    RY_BACKEND_JIT    = 2,   /* Henge translator: needs debugger-granted RWX */
};

typedef struct {
    int ok;
    int stage;
    int backend;
    uint64_t ram_bytes;
    uint32_t sample_result;
    char detail[256];
} RyEngineStatus;

#ifdef __cplusplus
extern "C" {
#endif

/* backend: RY_BACKEND_JIT or RY_BACKEND_INTERP.
 * Pass INTERP unless a debugger is attached: touching a JIT page without
 * permission kills the process instead of failing gracefully. */
int ry_engine_init(uint64_t ram_bytes, int backend, RyEngineStatus *out);

/* Runs a real ARM64 program (sum + load/store) on the active backend. */
int ry_engine_selftest(RyEngineStatus *out);

/* Copies a kernel image into guest RAM at a physical address. */
int ry_engine_load(const void *data, uint64_t len, uint64_t pa, RyEngineStatus *out);

/* Steps the guest from pc for at most max_insns. */
int ry_engine_run_at(uint64_t pc, uint64_t max_insns, RyEngineStatus *out);

void ry_engine_shutdown(void);
int ry_engine_backend(void);
const char *ry_engine_detail(const RyEngineStatus *s);

#ifdef __cplusplus
}
#endif
#endif
