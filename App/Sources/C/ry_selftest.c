/*
 * iOSoniOS engine self-test (P1).
 *
 * Checks the one thing the whole project stands on: can this app, on this iOS
 * build with this signature, allocate and EXECUTE code in anonymous memory?
 * That is the JIT gate.
 *
 * CRITICAL: a distribution-signed app can sometimes mmap RWX successfully but
 * still be killed by AMFI on the first instruction fetch. Calling such a page
 * without a signal guard crashes the app. We therefore wrap the indirect call
 * in sigsetjmp/siglongjmp: a fault becomes a reported result, not a crash.
 */
#include <sys/mman.h>
#include <sys/types.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <setjmp.h>
#include <signal.h>

typedef struct {
    int jit_ok;
    int mmap_ok;
    int fault_signal;
    int page_size;
    int pages_match;
    uint32_t value;
    char detail[256];
} RySelfTestResult;

/* AArch64: mov w0, #42 (0x52800540); ret (0xd65f03c0), little endian. */
static const uint32_t kMovW0_42 = 0x52800540u;
static const uint32_t kRet      = 0xd65f03c0u;
typedef int (*fn_t)(void);

static sigjmp_buf ry_jmp;
static volatile sig_atomic_t ry_fault = 0;

static void ry_fault_handler(int sig) {
    ry_fault = sig;
    siglongjmp(ry_jmp, 1);
}

void ry_selftest_run(RySelfTestResult *out) {
    memset(out, 0, sizeof(*out));

    long ps = sysconf(_SC_PAGESIZE);
    out->page_size = (int)ps;
    out->pages_match = (ps == 16384);

    size_t map_len = (size_t)ps;
    void *p = mmap(NULL, map_len, PROT_READ | PROT_WRITE | PROT_EXEC,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) {
        snprintf(out->detail, sizeof(out->detail),
                 "RWX mmap 被拒 errno=%d (%s)。没有可执行内存，JIT 不可用。",
                 errno, strerror(errno));
        return;
    }
    out->mmap_ok = 1;

    uint32_t *code = (uint32_t *)p;
    code[0] = kMovW0_42;
    code[1] = kRet;
    __atomic_thread_fence(__ATOMIC_SEQ_CST);

    /* Guard the indirect call. Save and restore the app's own crash handlers
     * (RyLog installs them) so only this one execution is protected. */
    void (*old_segv)(int) = signal(SIGSEGV, ry_fault_handler);
    void (*old_bus)(int)  = signal(SIGBUS,  ry_fault_handler);
    void (*old_ill)(int)  = signal(SIGILL,  ry_fault_handler);
    void (*old_abrt)(int) = signal(SIGABRT, ry_fault_handler);

    ry_fault = 0;
    if (sigsetjmp(ry_jmp, 1) == 0) {
        fn_t fn = (fn_t)(uintptr_t)p;
        int r = fn();
        out->value = (uint32_t)r;
        out->jit_ok = (r == 42);
        if (out->jit_ok) {
            snprintf(out->detail, sizeof(out->detail),
                     "成功： guest 代码执行并返回 42，JIT 可用。");
        } else {
            snprintf(out->detail, sizeof(out->detail),
                     "代码返回 %d（期望 42），执行结果异常。", r);
        }
    } else {
        out->fault_signal = (int)ry_fault;
        out->jit_ok = 0;
        snprintf(out->detail, sizeof(out->detail),
                 "执行被系统拦截：信号 %d。mmap 拿到了 RWX 但 AMFI/W^X 不允许运行"
                 "（常见于分发证书签名）。可尝试开发者签名 + 调试器附加。",
                 out->fault_signal);
    }

    signal(SIGSEGV, old_segv);
    signal(SIGBUS,  old_bus);
    signal(SIGILL,  old_ill);
    signal(SIGABRT, old_abrt);
    munmap(p, map_len);
}
