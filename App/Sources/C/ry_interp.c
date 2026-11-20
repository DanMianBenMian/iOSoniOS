/*
 * A small ARM64 interpreter.
 *
 * Why this exists: the Henge engine is a JIT translator, which needs executable
 * memory. On a distribution-signed app AMFI kills the process the first time
 * translated code runs, so a JIT is not usable without a debugger. Interpreting
 * guest instructions in plain C needs no executable memory at all: the host
 * reads guest bytes and does the work itself, so nothing can be blocked.
 *
 * Scope: the integer subset needed to boot-test small programs (moves, add/sub,
 * logic, shifts, compares, branches, returns, and basic loads/stores). Floating
 * point, atomics and system registers are out of scope for now and report
 * themselves as unsupported rather than silently doing the wrong thing.
 */
#include <stdint.h>
#include <string.h>
#include <stdio.h>

#include "ry_interp.h"

#define BIT(x, n) (((x) >> (n)) & 1u)
#define BITS(x, hi, lo) (((x) >> (lo)) & ((1u << ((hi) - (lo) + 1)) - 1u))
#define SEXT(v, bits) ((int64_t)((uint64_t)(v) << (64 - (bits))) >> (64 - (bits)))
#define X(i) ((i) == 31 ? 0ull : cpu->x[(i)])
#define XSET(i, v) do { if ((i) != 31) cpu->x[(i)] = (v); } while (0)

static int64_t arshift(int64_t v, unsigned sh) {
    if (sh >= 64) return v < 0 ? -1 : 0;
    return v >> sh;
}

/* 64-bit shifted register operand for logical ops. */
static uint64_t shift_reg(uint64_t value, unsigned type, unsigned amount, int is64) {
    if (!is64) value &= 0xffffffffull;
    switch (type) {
    case 0: /* LSL */
        return amount >= 64 ? 0 : (value << amount);
    case 1: /* LSR */
        return amount >= 64 ? 0 : ((is64 ? value : (uint32_t)value) >> amount);
    case 2: /* ASR */
        return (uint64_t)arshift((int64_t)(is64 ? value : (int32_t)value), amount);
    case 3: /* ROR */
        if (!is64) {
            uint32_t v = (uint32_t)value;
            unsigned r = amount & 31;
            return r ? ((v >> r) | (v << (32 - r))) : v;
        } else {
            unsigned r = amount & 63;
            return r ? ((value >> r) | (value << (64 - r))) : value;
        }
    }
    return value;
}

static int64_t apply_extend(uint64_t value, unsigned option, unsigned shift) {
    int64_t v;
    switch (option) {
    case 0: v = (int64_t)(int8_t)value; break;    /* UXTB */
    case 1: v = (int64_t)(int16_t)value; break;   /* UXTH */
    case 2: v = (int64_t)(int32_t)value; break;   /* UXTW */
    case 3: v = (int64_t)value; break;            /* UXTX */
    case 4: v = (int8_t)value; break;             /* SXTB */
    case 5: v = (int16_t)value; break;            /* SXTH */
    case 6: v = (int32_t)value; break;            /* SXTW */
    default: v = (int64_t)value; break;           /* SXTX */
    }
    return v << shift;
}

static int cond_holds(unsigned cond, uint64_t nzcv) {
    int n = (int)((nzcv >> 31) & 1);
    int z = (int)((nzcv >> 30) & 1);
    int c = (int)((nzcv >> 29) & 1);
    int v = (int)((nzcv >> 28) & 1);
    switch (cond) {
    case 0:  return z == 1;              /* EQ */
    case 1:  return z == 0;              /* NE */
    case 2:  return c == 1;              /* CS */
    case 3:  return c == 0;              /* CC */
    case 4:  return n == 1;              /* MI */
    case 5:  return n == 0;              /* PL */
    case 6:  return v == 1;              /* VS */
    case 7:  return v == 0;              /* VC */
    case 8:  return c == 1 && z == 0;    /* HI */
    case 9:  return c == 0 || z == 1;    /* LS */
    case 10: return n == v;              /* GE */
    case 11: return n != v;              /* LT */
    case 12: return z == 0 && n == v;    /* GT */
    case 13: return z == 1 || n != v;    /* LE */
    default: return 1;                   /* AL / NV */
    }
}

static uint64_t set_nzcv_add(uint64_t a, uint64_t b, uint64_t r, int is64, int isSub) {
    unsigned width = is64 ? 64 : 32;
    uint64_t mask = is64 ? ~0ull : 0xffffffffull;
    uint64_t sa = a & mask, sb = b & mask, sr = r & mask;
    int n = (int)((sr >> (width - 1)) & 1);
    int z = (sr == 0);
    int c, v;
    if (isSub) {
        c = (sa >= sb);
        v = (int)((((sa ^ sb) & (sa ^ sr)) >> (width - 1)) & 1);
    } else {
        c = ((sa + sb) > mask);
        v = (int)(((~(sa ^ sb) & (sa ^ sr)) >> (width - 1)) & 1);
    }
    return ((uint64_t)n << 31) | ((uint64_t)z << 30) | ((uint64_t)c << 29) | ((uint64_t)v << 28);
}

/* Memory access through the flat guest RAM window. */
static uint8_t *mem_ptr(RyInterp *in, uint64_t addr, unsigned size) {
    if (addr + size > in->mem_size) return NULL;
    return in->mem + addr;
}

static int load_mem(RyInterp *in, uint64_t addr, unsigned size, int is_signed, uint64_t *out) {
    uint8_t *p = mem_ptr(in, addr, size);
    if (!p) return -1;
    uint64_t v = 0;
    memcpy(&v, p, size);
    if (is_signed) {
        switch (size) {
        case 1: v = (uint64_t)(int64_t)(int8_t)v; break;
        case 2: v = (uint64_t)(int64_t)(int16_t)v; break;
        case 4: v = (uint64_t)(int64_t)(int32_t)v; break;
        default: break;
        }
    }
    *out = v;
    return 0;
}

static int store_mem(RyInterp *in, uint64_t addr, unsigned size, uint64_t v) {
    uint8_t *p = mem_ptr(in, addr, size);
    if (!p) return -1;
    memcpy(p, &v, size);
    return 0;
}

int ry_interp_step(RyInterp *in) {
    RyCpu *cpu = &in->cpu;
    if (cpu->pc + 4 > in->mem_size) return RY_ERR_PC;
    uint32_t insn;
    memcpy(&insn, in->mem + cpu->pc, 4);
    uint64_t pc = cpu->pc;
    cpu->pc = pc + 4;          /* advance first; branches overwrite */
    in->insns++;

    /* NOP / HINT */
    if (insn == 0xd503201f) return RY_OK;

    /* RET / BR / BLR: opcode 1101011, op field selects */
    if ((insn & 0xfffffc1f) == 0xd65f0000) {   /* RET */
        cpu->pc = X(BITS(insn, 9, 5));
        return RY_OK;
    }
    if ((insn & 0xfffffc1f) == 0xd61f0000) {   /* BR */
        cpu->pc = X(BITS(insn, 9, 5));
        return RY_OK;
    }
    if ((insn & 0xfffffc1f) == 0xd63f0000) {   /* BLR */
        uint64_t target = X(BITS(insn, 9, 5));
        cpu->x[30] = pc + 4;
        cpu->pc = target;
        return RY_OK;
    }

    /* B / BL immediate */
    if ((insn & 0x7c000000) == 0x14000000) {
        int64_t off = SEXT(BITS(insn, 25, 0), 26) << 2;
        if (BIT(insn, 31)) cpu->x[30] = pc + 4;
        cpu->pc = pc + off;
        return RY_OK;
    }

    /* B.cond */
    if ((insn & 0xff000010) == 0x54000000) {
        if (cond_holds(BITS(insn, 3, 0), cpu->nzcv)) {
            cpu->pc = pc + (SEXT(BITS(insn, 23, 5), 19) << 2);
        }
        return RY_OK;
    }

    /* CBZ / CBNZ */
    if ((insn & 0x7e000000) == 0x34000000) {
        int is64 = (int)BIT(insn, 31);
        uint64_t v = X(BITS(insn, 4, 0));
        if (!is64) v &= 0xffffffffull;
        int nonzero = (v != 0);
        int want = BIT(insn, 24) ? 1 : 0;   /* bit24: CBNZ */
        if (nonzero == want) cpu->pc = pc + (SEXT(BITS(insn, 23, 5), 19) << 2);
        return RY_OK;
    }

    /* MOVZ / MOVN / MOVK (move wide immediate) */
    if ((insn & 0x1f800000) == 0x12800000) {
        int is64 = (int)BIT(insn, 31);
        unsigned opc = BITS(insn, 30, 29);
        unsigned hw = BITS(insn, 22, 21);
        uint64_t imm = (uint64_t)BITS(insn, 20, 5) << (16 * hw);
        unsigned rd = BITS(insn, 4, 0);
        uint64_t cur = 0;
        if (opc == 3 && rd != 31) cur = cpu->x[rd];      /* MOVK keeps the rest */
        uint64_t val;
        switch (opc) {
        case 0: val = ~imm; break;                       /* MOVN */
        case 2: val = imm; break;                        /* MOVZ */
        case 3: {                                        /* MOVK */
            uint64_t keep = is64 ? ~0ull : 0xffffffffull;
            uint64_t clear = ~((uint64_t)0xffff << (16 * hw));
            val = (cur & clear) | imm;
            val &= keep;
            break;
        }
        default: return RY_ERR_UNSUPPORTED;
        }
        if (!is64) val &= 0xffffffffull;
        XSET(rd, val);
        return RY_OK;
    }

    /* ADD/SUB immediate (includes CMP/CMN with Rd=31) */
    if ((insn & 0x1f000000) == 0x11000000) {
        int is64 = (int)BIT(insn, 31);
        int isSub = (int)BIT(insn, 30);
        int setflags = (int)BIT(insn, 29);
        unsigned sh = BIT(insn, 22);
        uint64_t imm = (uint64_t)BITS(insn, 21, 10);
        if (sh) imm <<= 12;
        unsigned rn = BITS(insn, 9, 5);
        unsigned rd = BITS(insn, 4, 0);
        uint64_t a = X(rn), b = imm;
        uint64_t r = isSub ? (a - b) : (a + b);
        if (!is64) r &= 0xffffffffull;
        if (setflags) {
            cpu->nzcv = set_nzcv_add(a, b, r, is64, isSub);
        } else {
            XSET(rd, r);
        }
        return RY_OK;
    }

    /* ADD/SUB shifted register */
    if ((insn & 0x1f200000) == 0x0b000000) {
        int is64 = (int)BIT(insn, 31);
        int isSub = (int)BIT(insn, 30);
        int setflags = (int)BIT(insn, 29);
        unsigned shift_type = BITS(insn, 23, 22);
        unsigned amount = BITS(insn, 15, 10);
        unsigned rm = BITS(insn, 20, 16);
        unsigned rn = BITS(insn, 9, 5);
        unsigned rd = BITS(insn, 4, 0);
        uint64_t b = shift_reg(X(rm), shift_type, amount, is64);
        uint64_t a = X(rn);
        uint64_t r = isSub ? (a - b) : (a + b);
        if (!is64) r &= 0xffffffffull;
        if (setflags) cpu->nzcv = set_nzcv_add(a, b, r, is64, isSub);
        else XSET(rd, r);
        return RY_OK;
    }

    /* Logical shifted register (AND/ORR/EOR/ANDS/BIC/ORN/EON) */
    if ((insn & 0x1f000000) == 0x0a000000) {
        int is64 = (int)BIT(insn, 31);
        unsigned opc = BITS(insn, 30, 29);
        unsigned shift_type = BITS(insn, 23, 22);
        unsigned amount = BITS(insn, 15, 10);
        unsigned rm = BITS(insn, 20, 16);
        unsigned rn = BITS(insn, 9, 5);
        unsigned rd = BITS(insn, 4, 0);
        uint64_t a = X(rn);
        uint64_t b = shift_reg(X(rm), shift_type, amount, is64);
        uint64_t r;
        int setflags = 0;
        switch (opc) {
        case 0: r = a & b; break;                          /* AND */
        case 1: r = a | b; break;                          /* ORR */
        case 2: r = a ^ b; break;                          /* EOR */
        case 3: r = a & b; setflags = 1; break;            /* ANDS */
        default: return RY_ERR_UNSUPPORTED;
        }
        if (!is64) r &= 0xffffffffull;
        if (setflags) {
            unsigned width = is64 ? 64 : 32;
            cpu->nzcv = (((r >> (width - 1)) & 1) << 31) | ((r == 0) ? (1ull << 30) : 0);
        } else {
            XSET(rd, r);
        }
        return RY_OK;
    }

    /* Logical immediate (AND/ORR/EOR/ANDS #imm) -- decode via bitmask immediate */
    if ((insn & 0x1f800000) == 0x12000000) {
        int is64 = (int)BIT(insn, 31);
        unsigned opc = BITS(insn, 30, 29);
        unsigned n = BIT(insn, 22);
        unsigned immr = BITS(insn, 21, 16);
        unsigned imms = BITS(insn, 15, 10);
        unsigned rn = BITS(insn, 9, 5);
        unsigned rd = BITS(insn, 4, 0);
        unsigned len = 31 - __builtin_clz((n << 6) | (~imms & 0x3f));
        if (len < 1) return RY_ERR_UNSUPPORTED;
        unsigned size = 1u << len;
        uint64_t mask = (size == 64) ? ~0ull : ((1ull << size) - 1);
        unsigned levels = size - 1;
        uint64_t s = imms & levels;
        unsigned r = immr & levels;
        uint64_t welem = (s == levels) ? mask : ((1ull << (s + 1)) - 1);
        uint64_t imm;
        if (r == 0) imm = welem;
        else imm = ((welem >> r) | (welem << (size - r))) & mask;
        if (size < 64) {
            uint64_t rep = 0;
            for (unsigned i = 0; i < 64; i += size) rep |= imm << i;
            imm = rep;
        }
        uint64_t a = X(rn), rr;
        int setflags = 0;
        switch (opc) {
        case 0: rr = a & imm; break;
        case 1: rr = a | imm; break;
        case 2: rr = a ^ imm; break;
        case 3: rr = a & imm; setflags = 1; break;
        default: return RY_ERR_UNSUPPORTED;
        }
        if (!is64) rr &= 0xffffffffull;
        if (setflags) {
            unsigned width = is64 ? 64 : 32;
            cpu->nzcv = (((rr >> (width - 1)) & 1) << 31) | ((rr == 0) ? (1ull << 30) : 0);
        } else XSET(rd, rr);
        return RY_OK;
    }

    /* Move (register) alias of ORR #0, and MOVN handled above */
    if ((insn & 0x7fe0ffe0) == 0x2a0003e0) {   /* ORR Wd, WZR, Wm */
        XSET(BITS(insn, 4, 0), X(BITS(insn, 20, 16)) & 0xffffffffull);
        return RY_OK;
    }

    /* LDR/STR (unsigned offset, 64/32/16/8-bit) */
    if ((insn & 0x3b000000) == 0x39000000) {
        unsigned size_code = BITS(insn, 31, 30);
        unsigned opc = BITS(insn, 23, 22);
        int is_load = BIT(insn, 22) == 1;
        unsigned size = 1u << size_code;
        unsigned rt = BITS(insn, 4, 0);
        unsigned rn = BITS(insn, 9, 5);
        uint64_t addr = X(rn) + ((uint64_t)BITS(insn, 21, 10) << size_code);
        if (is_load) {
            int is_signed = (opc >= 2);
            uint64_t v;
            if (load_mem(in, addr, size, is_signed, &v) != 0) return RY_ERR_MEM;
            if (size_code == 2 && !is_signed) v &= 0xffffffffull;  /* 32-bit load zeroes upper */
            XSET(rt, v);
        } else {
            if (store_mem(in, addr, size, X(rt)) != 0) return RY_ERR_MEM;
        }
        return RY_OK;
    }

    /* LDR/STR (pre/post index, 64-bit only for now) */
    if ((insn & 0x3b200c00) == 0x38000c00) {
        unsigned size_code = BITS(insn, 31, 30);
        unsigned size = 1u << size_code;
        int is_load = BIT(insn, 22) == 1;
        unsigned rt = BITS(insn, 4, 0);
        unsigned rn = BITS(insn, 9, 5);
        int64_t off = SEXT(BITS(insn, 20, 12), 9);
        int mode = (int)BITS(insn, 11, 10);   /* 1 post, 3 pre */
        uint64_t base = X(rn);
        uint64_t addr = (mode == 1) ? base : (base + off);
        if (is_load) {
            uint64_t v;
            if (load_mem(in, addr, size, 0, &v) != 0) return RY_ERR_MEM;
            if (size_code == 2) v &= 0xffffffffull;
            XSET(rt, v);
        } else {
            if (store_mem(in, addr, size, X(rt)) != 0) return RY_ERR_MEM;
        }
        if (mode != 0) XSET(rn, base + off);
        return RY_OK;
    }

    /* ADR / ADRP */
    if ((insn & 0x1f000000) == 0x10000000) {
        int is_page = (int)BIT(insn, 31);
        unsigned rd = BITS(insn, 4, 0);
        int64_t imm = (int64_t)(((uint64_t)BITS(insn, 23, 5) << 2) | BITS(insn, 30, 29));
        imm = SEXT(imm, 21);
        if (is_page) {
            uint64_t base = pc & ~0xfffull;
            XSET(rd, base + (imm << 12));
        } else {
            XSET(rd, pc + imm);
        }
        return RY_OK;
    }

    in->unsupported_insn = insn;
    in->unsupported_pc = pc;
    return RY_ERR_UNSUPPORTED;
}

int ry_interp_run(RyInterp *in, uint64_t stop_pc, uint64_t max_insns) {
    while (in->insns < max_insns) {
        if (in->cpu.pc == stop_pc) return RY_OK;
        int rc = ry_interp_step(in);
        if (rc != RY_OK) return rc;
    }
    return RY_ERR_LIMIT;
}

void ry_interp_reset(RyInterp *in, uint64_t entry) {
    memset(&in->cpu, 0, sizeof(in->cpu));
    in->cpu.pc = entry;
    in->insns = 0;
    in->unsupported_insn = 0;
    in->unsupported_pc = 0;
}
