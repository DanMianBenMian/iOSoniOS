/*
 * Guest execution with two backends.
 *
 *   JIT        -- Henge's arm64 translator (core/ + host/enter.S). Fast, but it
 *                 needs executable memory, which iOS only grants a process with
 *                 a debugger attached. Usable only when P_TRACED is set.
 *   Interp     -- ry_interp.c, a software ARM64 interpreter. Slower, but it runs
 *                 guest instructions as data, so any signature works.
 *
 * The backend is chosen once at init: the JIT is never even initialised unless
 * the caller says a debugger is present. That matters because touching a JIT
 * page without permission kills the process rather than returning an error.
 */
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <stdarg.h>

#include "ry_engine.h"
#include "ry_interp.h"

#if RY_HAVE_JIT
#include "machine.h"
#include "cpu.h"
#include "dispatch.h"
#include "memop.h"
#endif

static int g_backend;                 /* RY_BACKEND_* */
static int g_ready;

/* Interpreter backend state */
static RyInterp *g_interp;
static uint8_t *g_ram;
static uint64_t g_ram_bytes;

/* JIT backend state */
#if RY_HAVE_JIT
static HvMachine *g_machine;
static HvCpu *g_cpu;
#endif

static void set_detail(RyEngineStatus *s, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(s->detail, sizeof(s->detail), fmt, ap);
    va_end(ap);
}

/* ---------------- init ---------------- */

int ry_engine_init(uint64_t ram_bytes, int backend, RyEngineStatus *out) {
    if (out) memset(out, 0, sizeof(*out));
    if (g_ready) {
        if (out) {
            out->ok = 1;
            out->ram_bytes = g_ram_bytes;
            out->backend = g_backend;
            set_detail(out, "已在运行");
        }
        return 0;
    }

#if RY_HAVE_JIT
    if (backend == RY_BACKEND_JIT) {
        g_machine = (HvMachine *)calloc(1, sizeof(HvMachine));
        if (!g_machine) { if (out) set_detail(out, "HvMachine 分配失败"); return -1; }
        if (out) out->stage = 1;

        if (hv_machine_init(g_machine, (size_t)(256ull << 20)) != 0) {
            if (out) set_detail(out, "JIT 区域申请失败（无调试权限时属正常）");
            free(g_machine); g_machine = NULL;
            return -2;
        }
        if (out) out->stage = 2;

        g_ram = (uint8_t *)calloc(1, (size_t)ram_bytes);
        if (!g_ram) { if (out) set_detail(out, "guest RAM 分配失败"); return -3; }
        g_ram_bytes = ram_bytes;

        if (hv_machine_add_ram(g_machine, 0, ram_bytes, g_ram, 0) != 0) {
            if (out) set_detail(out, "hv_machine_add_ram 失败");
            return -4;
        }

        g_cpu = (HvCpu *)calloc(1, sizeof(HvCpu));
        if (!g_cpu) { if (out) set_detail(out, "HvCpu 分配失败"); return -5; }
        hv_cpu_reset(g_cpu, g_machine);
        g_machine->cpu = g_cpu;
        g_machine->cpus[0] = g_cpu;
        g_machine->ncpus = 1;
        if (out) out->stage = 4;

        g_backend = RY_BACKEND_JIT;
        g_ready = 1;
        if (out) {
            out->ok = 1;
            out->ram_bytes = ram_bytes;
            out->backend = g_backend;
            set_detail(out, "JIT 引擎就绪：RAM %llu MiB + 256 MiB 可执行区",
                       (unsigned long long)(ram_bytes >> 20));
        }
        return 0;
    }
#else
    (void)backend;
#endif

    /* Interpreter backend (also the fallback when the JIT is unavailable). */
    g_ram = (uint8_t *)calloc(1, (size_t)ram_bytes);
    if (!g_ram) {
        if (out) set_detail(out, "guest RAM 分配失败（%llu MiB）",
                            (unsigned long long)(ram_bytes >> 20));
        return -1;
    }
    g_ram_bytes = ram_bytes;
    if (out) out->stage = 1;

    g_interp = (RyInterp *)calloc(1, sizeof(RyInterp));
    if (!g_interp) { if (out) set_detail(out, "CPU 状态分配失败"); return -2; }
    g_interp->mem = g_ram;
    g_interp->mem_size = ram_bytes;
    if (out) out->stage = 2;

    g_backend = RY_BACKEND_INTERP;
    g_ready = 1;
    if (out) {
        out->ok = 1;
        out->ram_bytes = ram_bytes;
        out->backend = g_backend;
        set_detail(out, "解释器就绪：RAM %llu MiB（纯软件，无 JIT）",
                   (unsigned long long)(ram_bytes >> 20));
    }
    return 0;
}

/* ---------------- self test ---------------- */

int ry_engine_selftest(RyEngineStatus *out) {
    if (out) memset(out, 0, sizeof(*out));
    if (!g_ready) { if (out) set_detail(out, "引擎未初始化"); return -1; }

    const uint64_t entry = 0x1000;
    /* mov x1,#0; mov x0,#10; add x1,x1,x0; sub x0,x0,#1; cbnz x0,-8;
       mov x2,#0x152; mov x3,#0x2000; str x2,[x3]; ldr x4,[x3]; ret */
    static const uint32_t prog[] = {
        0xd2800001u, 0xd2800140u, 0x8b000021u, 0xd1000400u, 0xb5ffffc0u,
        0xd2802a42u, 0xd2804003u, 0xf9000062u, 0xf9400064u, 0xd65f03c0u
    };
    if (entry + sizeof(prog) > g_ram_bytes) {
        if (out) set_detail(out, "测试程序超出 guest RAM");
        return -2;
    }
    memcpy(g_ram + entry, prog, sizeof(prog));

#if RY_HAVE_JIT
    if (g_backend == RY_BACKEND_JIT) {
        hv_invalidate_code(g_machine, entry);
        hv_cpu_reset(g_cpu, g_machine);
        g_cpu->pc = entry;
        g_cpu->el = 1;
        g_machine->stop_pc = 0;
        int rc = hv_run(g_cpu);
        uint64_t sum = g_cpu->x[1], loaded = g_cpu->x[4];
        if (out) {
            out->ok = (rc == 0 && sum == 55 && loaded == 0x152);
            out->sample_result = (uint32_t)sum;
            out->ram_bytes = g_ram_bytes;
            out->backend = g_backend;
            set_detail(out, "JIT 执行 rc=%d：累加=%llu，访存读回=0x%llx",
                       rc, (unsigned long long)sum, (unsigned long long)loaded);
        }
        return out && out->ok ? 0 : -3;
    }
#endif

    ry_interp_reset(g_interp, entry);
    int rc = ry_interp_run(g_interp, 0, 100000);
    uint64_t sum = g_interp->cpu.x[1], loaded = g_interp->cpu.x[4];
    if (out) {
        out->ok = (rc == RY_OK && sum == 55 && loaded == 0x152);
        out->sample_result = (uint32_t)sum;
        out->ram_bytes = g_ram_bytes;
        out->backend = g_backend;
        if (rc == RY_ERR_UNSUPPORTED)
            set_detail(out, "遇到未实现的指令 0x%08x (pc=0x%llx)",
                       g_interp->unsupported_insn,
                       (unsigned long long)g_interp->unsupported_pc);
        else
            set_detail(out, "解释器执行 %llu 条：累加=%llu，访存读回=0x%llx",
                       (unsigned long long)g_interp->insns,
                       (unsigned long long)sum, (unsigned long long)loaded);
    }
    return out && out->ok ? 0 : -3;
}

/* ---------------- load / run ---------------- */

int ry_engine_load(const void *data, uint64_t len, uint64_t pa, RyEngineStatus *out) {
    if (out) memset(out, 0, sizeof(*out));
    if (!g_ready) { if (out) set_detail(out, "引擎未初始化"); return -1; }
    if (pa + len > g_ram_bytes) {
        if (out) set_detail(out, "镜像超出 guest RAM（需要 %llu MiB）",
                            (unsigned long long)((pa + len) >> 20));
        return -2;
    }
    memcpy(g_ram + pa, data, (size_t)len);
#if RY_HAVE_JIT
    if (g_backend == RY_BACKEND_JIT) hv_invalidate_code(g_machine, pa);
#endif
    if (out) {
        out->ok = 1; out->ram_bytes = g_ram_bytes; out->backend = g_backend;
        set_detail(out, "已载入 %llu 字节 @ 0x%llx",
                   (unsigned long long)len, (unsigned long long)pa);
    }
    return 0;
}

int ry_engine_run_at(uint64_t pc, uint64_t max_insns, RyEngineStatus *out) {
    if (out) memset(out, 0, sizeof(*out));
    if (!g_ready) { if (out) set_detail(out, "引擎未初始化"); return -1; }

#if RY_HAVE_JIT
    if (g_backend == RY_BACKEND_JIT) {
        hv_cpu_reset(g_cpu, g_machine);
        g_cpu->pc = pc;
        g_cpu->el = 1;
        int rc = hv_run(g_cpu);
        if (out) {
            out->ok = (rc == 0);
            out->ram_bytes = g_ram_bytes;
            out->backend = g_backend;
            set_detail(out, "JIT pc=0x%llx rc=%d", (unsigned long long)g_cpu->pc, rc);
        }
        return rc;
    }
#endif

    ry_interp_reset(g_interp, pc);
    int rc = ry_interp_run(g_interp, 0, max_insns);
    if (out) {
        out->ok = (rc == RY_OK);
        out->ram_bytes = g_ram_bytes;
        out->backend = g_backend;
        if (rc == RY_ERR_UNSUPPORTED)
            set_detail(out, "未实现指令 0x%08x @ 0x%llx（已执行 %llu 条）",
                       g_interp->unsupported_insn,
                       (unsigned long long)g_interp->unsupported_pc,
                       (unsigned long long)g_interp->insns);
        else
            set_detail(out, "pc=0x%llx 执行 %llu 条 rc=%d",
                       (unsigned long long)g_interp->cpu.pc,
                       (unsigned long long)g_interp->insns, rc);
    }
    return rc;
}

void ry_engine_shutdown(void) {
#if RY_HAVE_JIT
    if (g_cpu) { free(g_cpu); g_cpu = NULL; }
    if (g_machine) { hv_machine_free(g_machine); free(g_machine); g_machine = NULL; }
#endif
    if (g_interp) { free(g_interp); g_interp = NULL; }
    if (g_ram) { free(g_ram); g_ram = NULL; }
    g_ready = 0;
    g_backend = RY_BACKEND_NONE;
    g_ram_bytes = 0;
}

int ry_engine_backend(void) { return g_backend; }

const char *ry_engine_detail(const RyEngineStatus *s) { return s->detail; }
