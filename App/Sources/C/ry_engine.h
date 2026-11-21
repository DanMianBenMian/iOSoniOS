#ifndef RY_ENGINE_H
#define RY_ENGINE_H

#include <stdint.h>
#include <stddef.h>

/* Guest framebuffer dimensions (kept here so Swift can read them via the
 * accessors below without needing the C macros). */
#define RY_FB_W 1024
#define RY_FB_H 768

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

/* Guest UART output (kernel printk). Called for every byte the kernel writes.
 * Set before ry_engine_run_at; pass NULL to discard. */
void ry_engine_set_uart(void (*sink)(char));

/* Loads a kernelcache into guest RAM and starts executing it. Returns 0 if the
 * kernel began running, negative if the image could not be loaded. The stop
 * reason and the first fault are reported through `out`. */
int ry_engine_boot_kernel(const void *data, uint64_t len, uint64_t max_insns,
                          RyEngineStatus *out);

/* Where the loaded kernel's entry point ended up (0 before a load). */
uint64_t ry_engine_kernel_entry(void);

/* Last memory fault the interpreter hit (virtual, physical, and whether it was
 * a write to a read-only page). Zeroed when there has been no fault. */
void ry_engine_last_fault(uint64_t *va, uint64_t *pa, int *perm);
const char *ry_engine_detail(const RyEngineStatus *s);

/* Guest framebuffer readback for the on-screen display.
 * Returns a pointer to RY_FB_W*RY_FB_H*4 RGBA8888 bytes (valid until shutdown),
 * or NULL before init. The UI copies this into a CGImage each frame. */
const uint8_t *ry_engine_fb_pixels(void);
unsigned       ry_engine_fb_width(void);
unsigned       ry_engine_fb_height(void);
int            ry_engine_fb_is_test(void);   /* 1 = still showing test pattern */
void           ry_engine_fb_redraw_test(void);

#ifdef __cplusplus
}
#endif
#endif
