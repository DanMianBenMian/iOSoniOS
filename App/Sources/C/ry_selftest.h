#ifndef RY_SELFTEST_H
#define RY_SELFTEST_H

#include <stdint.h>

typedef struct {
    int jit_ok;
    int mmap_ok;
    int fault_signal;
    int page_size;
    int pages_match;
    uint32_t value;
    char detail[256];
} RySelfTestResult;

#ifdef __cplusplus
extern "C" {
#endif
void ry_selftest_run(RySelfTestResult *out);
#ifdef __cplusplus
}
#endif
#endif
