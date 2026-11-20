/*
 * Guest execution for the app.
 *
 * This build interprets ARM64 in plain C (ry_interp.c). It never asks for
 * executable memory, so it works with an ordinary distribution signature and
 * cannot be killed by AMFI on an instruction fetch. Henge's JIT would be much
 * faster, but it needs a debugger-granted RWX region, which this build does not
 * have; correctness and not-crashing come first.
 *
 * Guest RAM is ordinary writable memory (calloc), addressed flat from 0.
 */
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <stdarg.h>

#include "ry_engine.h"
#include "ry_interp.h"

static RyInterp *g_interp;
static uint8_t *g_ram;
static uint64_t g_ram_bytes;
static int g_ready;

static void set_detail(RyEngineStatus *s, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(s->detail, sizeof(s->detail), fmt, ap);
    va_end(ap);
}

int ry_engine_init(uint64_t ram_bytes, uint64_t jit_bytes, RyEngineStatus *out) {
    if (out) memset(out, 0, sizeof(*out));
    (void)jit_bytes;              /* no JIT in this build */

    if (g_ready) {
        if (out) { out->ok = 1; out->ram_bytes = g_ram_bytes; set_detail(out, "已在运行"); }
        return 0;
    }

    g_ram = (uint8_t *)calloc(1, (size_t)ram_bytes);
    if (!g_ram) {
        if (out) set_detail(out, "guest RAM 分配失败（%llu MiB）",
                            (unsigned long long)(ram_bytes >> 20));
        return -1;
    }
    g_ram_bytes = ram_bytes;
    if (out) out->stage = 1;

    g_interp = (RyInterp *)calloc(1, sizeof(RyInterp));
    if (!g_interp) {
        if (out) set_detail(out, "CPU 状态分配失败");
        free(g_ram); g_ram = NULL;
        return -2;
    }
    g_interp->mem = g_ram;
    g_interp->mem_size = ram_bytes;
    if (out) out->stage = 2;

    g_ready = 1;
    if (out) {
        out->ok = 1;
        out->ram_bytes = ram_bytes;
        set_detail(out, "解释器就绪，guest RAM %llu MiB（纯软件，无 JIT）",
                   (unsigned long long)(ram_bytes >> 20));
    }
    return 0;
}

/* Runs a real instruction sequence: sum 1..10, then a load/store round trip. */
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

    ry_interp_reset(g_interp, entry);
    int rc = ry_interp_run(g_interp, 0, 100000);

    uint64_t sum = g_interp->cpu.x[1];
    uint64_t loaded = g_interp->cpu.x[4];

    if (out) {
        out->ok = (rc == RY_OK && sum == 55 && loaded == 0x152);
        out->sample_result = (uint32_t)sum;
        out->ram_bytes = g_ram_bytes;
        if (rc != RY_OK) {
            if (rc == RY_ERR_UNSUPPORTED) {
                set_detail(out, "遇到未实现的指令 0x%08x (pc=0x%llx)",
                           g_interp->unsupported_insn,
                           (unsigned long long)g_interp->unsupported_pc);
            } else {
                set_detail(out, "解释器退出 rc=%d（已执行 %llu 条）", rc,
                           (unsigned long long)g_interp->insns);
            }
        } else {
            set_detail(out, "执行 %llu 条指令：累加=%llu，访存读回=0x%llx",
                       (unsigned long long)g_interp->insns,
                       (unsigned long long)sum, (unsigned long long)loaded);
        }
    }
    return out ? (out->ok ? 0 : -3) : (sum == 55 ? 0 : -3);
}

int ry_engine_load(const void *data, uint64_t len, uint64_t pa, RyEngineStatus *out) {
    if (out) memset(out, 0, sizeof(*out));
    if (!g_ready) { if (out) set_detail(out, "引擎未初始化"); return -1; }
    if (pa + len > g_ram_bytes) {
        if (out) set_detail(out, "镜像超出 guest RAM（需要 %llu MiB）",
                            (unsigned long long)((pa + len) >> 20));
        return -2;
    }
    memcpy(g_ram + pa, data, (size_t)len);
    if (out) {
        out->ok = 1; out->ram_bytes = g_ram_bytes;
        set_detail(out, "已载入 %llu 字节 @ 0x%llx",
                   (unsigned long long)len, (unsigned long long)pa);
    }
    return 0;
}

/* Steps the guest from `pc` for at most `max_insns`. */
int ry_engine_run_at(uint64_t pc, uint64_t max_insns, RyEngineStatus *out) {
    if (out) memset(out, 0, sizeof(*out));
    if (!g_ready) { if (out) set_detail(out, "引擎未初始化"); return -1; }
    ry_interp_reset(g_interp, pc);
    int rc = ry_interp_run(g_interp, 0, max_insns);
    if (out) {
        out->ok = (rc == RY_OK);
        out->ram_bytes = g_ram_bytes;
        if (rc == RY_ERR_UNSUPPORTED) {
            set_detail(out, "未实现指令 0x%08x @ 0x%llx（已执行 %llu 条）",
                       g_interp->unsupported_insn,
                       (unsigned long long)g_interp->unsupported_pc,
                       (unsigned long long)g_interp->insns);
        } else {
            set_detail(out, "pc=0x%llx 执行 %llu 条，rc=%d",
                       (unsigned long long)g_interp->cpu.pc,
                       (unsigned long long)g_interp->insns, rc);
        }
    }
    return rc;
}

void ry_engine_shutdown(void) {
    if (g_interp) { free(g_interp); g_interp = NULL; }
    if (g_ram) { free(g_ram); g_ram = NULL; }
    g_ready = 0;
    g_ram_bytes = 0;
}

const char *ry_engine_detail(const RyEngineStatus *s) {
    return s->detail;
}
