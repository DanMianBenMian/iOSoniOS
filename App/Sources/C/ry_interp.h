#ifndef RY_INTERP_H
#define RY_INTERP_H

#include <stdint.h>

/* Return codes. */
enum {
    RY_OK = 0,
    RY_ERR_PC = -1,           /* PC outside guest memory */
    RY_ERR_MEM = -2,          /* load/store outside guest memory */
    RY_ERR_UNSUPPORTED = -3,  /* instruction not implemented */
    RY_ERR_LIMIT = -4,        /* instruction budget exhausted */
    RY_ERR_HALT = -5,         /* WFI/WFE/HLT/BRK */
    RY_ERR_SVC = -6,          /* SVC/HVC/SMC (svc_imm holds the immediate) */
};

typedef struct {
    uint64_t x[31];
    uint64_t sp;
    uint64_t pc;
    uint64_t nzcv;
    __uint128_t v[32];        /* SIMD/FP registers */
    uint64_t fpcr, fpsr;

    /* System registers that early boot actually reads back. */
    uint64_t sctlr_el1, tcr_el1, ttbr0_el1, ttbr1_el1, mair_el1;
    uint64_t tpidr_el0, tpidr_el1, tpidrro_el0;
    uint64_t elr_el1, spsr_el1, sp_el0, sp_el1, daif;
    uint64_t currentel, spsr_el2, elr_el2, vbar_el1, cpacr_el1;
    uint64_t cntfrq_el0, cntvct_el0, cntpct_el0;
    uint64_t esr_el1, far_el1, mpidr_el1;
    uint32_t el;
} RyCpu;

typedef struct {
    RyCpu cpu;
    uint8_t *mem;
    uint64_t mem_size;
    uint64_t insns;
    uint32_t unsupported_insn;
    uint64_t unsupported_pc;
    int halted;
    int last_error;
    uint32_t svc_imm;
    uint64_t svc_pc;

    /* Exclusive monitor (LDXR/STXR): one slot is enough for these guests. */
    uint64_t excl_addr;
    uint32_t excl_size;
    uint64_t excl_val;
} RyInterp;

#ifdef __cplusplus
extern "C" {
#endif

/* Shared accessors, so every decoder file reads registers the same way. */
#define RY_X(in, i)      ((i) == 31 ? 0ull : (in)->cpu.x[(i)])
#define RY_XSET(in, i, v) do { if ((i) != 31) (in)->cpu.x[(i)] = (v); } while (0)

void ry_interp_reset(RyInterp *in, uint64_t entry);
int ry_interp_step(RyInterp *in);
int ry_interp_run(RyInterp *in, uint64_t stop_pc, uint64_t max_insns);

/* Internal helpers shared between the decoder and its sub-decoders. */
int decode_bitmask(unsigned n, unsigned imms, unsigned immr, int is64, uint64_t *out);
uint64_t rot_right(uint64_t v, unsigned amount, unsigned width);
uint32_t crc32_op(uint32_t acc, uint32_t data, unsigned variant);
uint64_t ry_sysreg_read(RyInterp *in, unsigned op0, unsigned op1,
                        unsigned crn, unsigned crm, unsigned op2);
void ry_sysreg_write(RyInterp *in, unsigned op0, unsigned op1,
                     unsigned crn, unsigned crm, unsigned op2, uint64_t value);
/* Returns 1 when the instruction is not a load/store, 0 when handled. */
int ry_interp_loadstore(RyInterp *in, uint32_t insn, uint64_t pc);
/* Returns 1 when not a SIMD/FP instruction, else the step result. */
int ry_interp_simd(RyInterp *in, uint32_t insn, uint64_t pc);

#ifdef __cplusplus
}
#endif
#endif
