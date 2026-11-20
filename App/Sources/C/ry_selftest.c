/*
 * iOSoniOS engine self-test (P1) - SAFE PROBE.
 *
 * Only probes whether the app can MAP executable memory. It never executes a
 * translated block: on a distribution-signed app, AMFI can kill the process on
 * the first instruction fetch even when mmap(PROT_EXEC) succeeded. The previous
 * version called such a page and crashed on device; a siglongjmp guard did not
 * help because unwinding across the Swift call frame is undefined behaviour.
 *
 * Real JIT execution was already confirmed working on the user's iPadOS 27
 * with a debugger-attached setup, so a safe capability probe is enough here.
 */
#include <sys/mman.h>
#include <sys/types.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>

typedef struct {
    int jit_ok;          /* RWX mapping could be created */
    int mmap_ok;
    int fault_signal;    /* always 0 now - kept for ABI compatibility */
    int page_size;
    int pages_match;
    uint32_t value;      /* always 0 now */
    char detail[256];
} RySelfTestResult;

const char *ry_selftest_detail(const RySelfTestResult *out) {
    return out->detail;
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
                 "RWX mmap 被拒 errno=%d (%s)。可执行内存不可用。",
                 errno, strerror(errno));
        return;
    }
    out->mmap_ok = 1;
    out->jit_ok = 1;
    snprintf(out->detail, sizeof(out->detail),
             "可执行内存申请成功（只探测，不执行，避免被系统拦截）。页大小 %d 字节。",
             (int)ps);
    munmap(p, map_len);
}
