/*
 * iOSoniOS engine self-test (P1).
 *
 * Verifies the one thing the whole project stands on: this app, on this iOS
 * build, with this signature, can allocate executable memory and run code in
 * it. That is the JIT gate. Also checks that guest/host page size matches
 * (16 KB on Apple Silicon) -- Henge's engine maps guest RAM 1:1 to host pages
 * and this must hold for an iOS guest on an iOS host.
 *
 * The test writes `mov w0, #42; ret` (ARM64) into a RWX page and calls it.
 * If JIT is denied, mmap PROT_READ|PROT_WRITE|PROT_EXEC fails with EPERM.
 */
#include <sys/mman.h>
#include <sys/types.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>

typedef struct {
    int jit_ok;
    int page_size;
    int pages_match;
    uint32_t value;
    char detail[256];
} RySelfTestResult;

/* AArch64: mov w0, #42 (0x52800540); ret (0xd65f03c0), little endian. */
static const uint32_t kMovW0_42 = 0x52800540u;
static const uint32_t kRet      = 0xd65f03c0u;
typedef int (*fn_t)(void);

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
                 "RWX mmap failed errno=%d (%s) - JIT not granted",
                 errno, strerror(errno));
        return;
    }

    uint32_t *code = (uint32_t *)p;
    code[0] = kMovW0_42;
    code[1] = kRet;
    /* Apple Silicon has coherent I/D caches, so no cache flush is needed.
     * (Using __builtin___clear_cache here would emit ___clear_cache, which
     * the iOS SDK does not link.) An atomic barrier keeps the stores ordered
     * before the indirect call below. */
    __atomic_thread_fence(__ATOMIC_SEQ_CST);

    fn_t fn = (fn_t)(uintptr_t)p;
    int r = fn();
    out->value = (uint32_t)r;
    out->jit_ok = (r == 42);
    if (out->jit_ok) {
        snprintf(out->detail, sizeof(out->detail), "executed guest code, returned 42");
    } else {
        snprintf(out->detail, sizeof(out->detail), "code returned %d, expected 42", r);
    }
    munmap(p, map_len);
}
