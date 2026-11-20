#ifndef RY_INTERP_H
#define RY_INTERP_H

#include <stdint.h>

/* Return codes. */
enum {
    RY_OK = 0,
    RY_ERR_PC = -1,          /* PC outside guest memory */
    RY_ERR_MEM = -2,         /* load/store outside guest memory */
    RY_ERR_UNSUPPORTED = -3, /* instruction not implemented yet */
    RY_ERR_LIMIT = -4,       /* instruction budget exhausted */
};

typedef struct {
    uint64_t x[31];
    uint64_t sp;
    uint64_t pc;
    uint64_t nzcv;
} RyCpu;

typedef struct {
    RyCpu cpu;
    uint8_t *mem;            /* flat guest RAM window */
    uint64_t mem_size;
    uint64_t insns;          /* instructions executed so far */
    uint32_t unsupported_insn;
    uint64_t unsupported_pc;
} RyInterp;

#ifdef __cplusplus
extern "C" {
#endif

void ry_interp_reset(RyInterp *in, uint64_t entry);
/* Executes one instruction. Returns RY_OK or an error. */
int ry_interp_step(RyInterp *in);
/* Runs until PC == stop_pc, an error, or max_insns. */
int ry_interp_run(RyInterp *in, uint64_t stop_pc, uint64_t max_insns);

#ifdef __cplusplus
}
#endif
#endif
