/*
 * Bridge between the Swift app and the Henge arm64 engine (core/).
 *
 * The engine is a translator plus a software MMU: hv_machine_init() allocates a
 * JIT region, hv_machine_add_ram() registers RAM, hv_cpu_reset() sets a CPU up,
 * and hv_run() executes translated blocks until something stops it.
 *
 * We deliberately keep the machine model minimal here (one flat RAM range, no
 * devices). That is enough to prove the engine is alive and executing guest
 * instructions on the device, which is what "接引擎" needs to mean first.
 */
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <stdarg.h>

#include "machine.h"
#include "cpu.h"
#include "dispatch.h"
#include "memop.h"

/* One machine for the app's lifetime. */
static HvMachine *g_machine;
static HvCpu *g_cpu;
static uint8_t *g_ram;
static uint64_t g_ram_bytes;
static int g_ready;

typedef struct {
    int ok;
    int stage;                 /* how far it got */
    uint64_t ram_bytes;
    uint64_t jit_bytes;
    uint32_t sample_result;    /* value the test program computed */
    char detail[256];
} RyEngineStatus;

/* ARM64: mov w0, #42 ; ret */
static const uint32_t kTestCode[] = { 0x52800540u, 0xd65f03c0u };

static void set_detail(RyEngineStatus *s, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(s->detail, sizeof(s->detail), fmt, ap);
    va_end(ap);
}

int ry_engine_init(uint64_t ram_bytes, uint64_t jit_bytes, RyEngineStatus *out) {
    if (out) memset(out, 0, sizeof(*out));
    if (g_ready) {
        if (out) { out->ok = 1; out->ram_bytes = g_ram_bytes; set_detail(out, "已在运行"); }
        return 0;
    }

    g_machine = calloc(1, sizeof(HvMachine));
    if (!g_machine) {
        if (out) set_detail(out, "HvMachine 分配失败");
        return -1;
    }
    if (out) out->stage = 1;

    if (hv_machine_init(g_machine, (size_t)jit_bytes) != 0) {
        if (out) set_detail(out, "hv_machine_init 失败（JIT 区域申请不了）");
        free(g_machine);
        g_machine = NULL;
        return -2;
    }
    if (out) { out->stage = 2; out->jit_bytes = jit_bytes; }

    g_ram = aligned_alloc(16384, (size_t)ram_bytes);
    if (!g_ram) {
        if (out) set_detail(out, "guest RAM 分配失败");
        hv_machine_free(g_machine);
        free(g_machine);
        g_machine = NULL;
        return -3;
    }
    memset(g_ram, 0, (size_t)ram_bytes);
    g_ram_bytes = ram_bytes;

    /* Physical base 0: the engine treats this as the guest's low memory. */
    if (hv_machine_add_ram(g_machine, 0, ram_bytes, g_ram, 0) != 0) {
        if (out) set_detail(out, "hv_machine_add_ram 失败");
        free(g_ram); g_ram = NULL;
        hv_machine_free(g_machine);
        free(g_machine);
        g_machine = NULL;
        return -4;
    }
    if (out) out->stage = 3;

    g_cpu = calloc(1, sizeof(HvCpu));
    if (!g_cpu) {
        if (out) set_detail(out, "HvCpu 分配失败");
        return -5;
    }
    hv_cpu_reset(g_cpu, g_machine);
    if (out) out->stage = 4;

    g_ready = 1;
    if (out) { out->ok = 1; out->ram_bytes = ram_bytes; set_detail(out, "引擎就绪"); }
    return 0;
}

/* Run a two-instruction program to prove translation + execution works. */
int ry_engine_selftest(RyEngineStatus *out) {
    if (out) memset(out, 0, sizeof(*out));
    if (!g_ready) {
        if (out) set_detail(out, "引擎未初始化");
        return -1;
    }

    /* Put the program at physical 0x1000 (inside our RAM range). */
    const uint64_t code_pa = 0x1000;
    uint8_t *dst = hv_phys_ptr(g_machine, code_pa, sizeof(kTestCode));
    if (!dst) {
        if (out) set_detail(out, "取不到 guest 物理地址 0x1000");
        return -2;
    }
    memcpy(dst, kTestCode, sizeof(kTestCode));
    hv_invalidate_code(g_machine, code_pa);

    hv_cpu_reset(g_cpu, g_machine);
    g_cpu->pc = code_pa;
    g_cpu->el = 1;
    /* Stop as soon as the program returns to a sentinel address. */
    g_machine->stop_pc = 0xDEAD0000ull;

    int rc = hv_run(g_cpu);

    if (out) {
        out->ok = (g_cpu->x[0] == 42);
        out->sample_result = (uint32_t)g_cpu->x[0];
        out->ram_bytes = g_ram_bytes;
        set_detail(out, "hv_run rc=%d x0=%llu", rc, (unsigned long long)g_cpu->x[0]);
    }
    return out ? (out->ok ? 0 : -3) : (g_cpu->x[0] == 42 ? 0 : -3);
}

/* Copy the guest kernelcache into low guest RAM at `pa`. */
int ry_engine_load(const void *data, uint64_t len, uint64_t pa, RyEngineStatus *out) {
    if (out) memset(out, 0, sizeof(*out));
    if (!g_ready) { if (out) set_detail(out, "引擎未初始化"); return -1; }
    if (pa + len > g_ram_bytes) { if (out) set_detail(out, "镜像超出 guest RAM"); return -2; }
    uint8_t *dst = hv_phys_ptr(g_machine, pa, len);
    if (!dst) { if (out) set_detail(out, "目标物理地址不可写"); return -3; }
    memcpy(dst, data, (size_t)len);
    hv_invalidate_code(g_machine, pa);
    if (out) {
        out->ok = 1; out->ram_bytes = g_ram_bytes;
        set_detail(out, "已载入 %llu 字节 @ 0x%llx", (unsigned long long)len, (unsigned long long)pa);
    }
    return 0;
}

int ry_engine_run_at(uint64_t pc, RyEngineStatus *out) {
    if (out) memset(out, 0, sizeof(*out));
    if (!g_ready) { if (out) set_detail(out, "引擎未初始化"); return -1; }
    g_cpu->pc = pc;
    g_cpu->el = 1;
    int rc = hv_run(g_cpu);
    if (out) {
        out->ok = 1; out->ram_bytes = g_ram_bytes;
        set_detail(out, "hv_run rc=%d pc=0x%llx", rc, (unsigned long long)g_cpu->pc);
    }
    return rc;
}

void ry_engine_shutdown(void) {
    if (g_cpu) { free(g_cpu); g_cpu = NULL; }
    if (g_ram) { free(g_ram); g_ram = NULL; }
    if (g_machine) { hv_machine_free(g_machine); free(g_machine); g_machine = NULL; }
    g_ready = 0;
    g_ram_bytes = 0;
}

const char *ry_engine_detail(const RyEngineStatus *s) {
    return s->detail;
}
