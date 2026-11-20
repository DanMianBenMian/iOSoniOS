#ifndef RY_SELFTEST_H
#define RY_SELFTEST_H

typedef struct {
    int jit_ok;
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
