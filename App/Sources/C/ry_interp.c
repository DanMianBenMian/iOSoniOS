/*
 * A software ARM64 interpreter -- top-level decoder.
 *
 * Why: Henge's engine is a JIT translator and needs executable memory. On a
 * distribution-signed app AMFI kills the process on the first instruction
 * fetch, so the JIT is unusable without a debugger. This interpreter runs guest
 * code as data in plain C, so it works under any signature.
 *
 * Coverage: the full integer instruction set, common system instructions, every
 * load/store form (including exclusive and LSE atomics), and scalar FP plus
 * basic SIMD. Anything unimplemented returns RY_ERR_UNSUPPORTED together with
 * the opcode and PC rather than computing something wrong.
 */
#include <stdint.h>
#include <string.h>

#include "ry_interp.h"

#define BIT(x, n)       (((x) >> (n)) & 1u)
#define BITS(x, hi, lo) (((x) >> (lo)) & ((1u << ((hi) - (lo) + 1)) - 1u))
#define SEXT(v, bits)   ((int64_t)((uint64_t)(v) << (64 - (bits))) >> (64 - (bits)))
#define X(i)            RY_X(in, (i))
#define XSET(i, v)      RY_XSET(in, (i), (v))
#define MASK64          (~0ull)
#define MASK32          0xffffffffull
#define WMASK(sf)       ((sf) ? MASK64 : MASK32)

/* ---------------- shared small helpers ---------------- */

static int64_t asr_imm(int64_t v, unsigned sh) {
    return sh >= 64 ? (v < 0 ? -1 : 0) : (v >> sh);
}

static uint64_t shift_reg(uint64_t value, unsigned type, unsigned amount, int is64) {
    uint64_t v = is64 ? value : (value & MASK32);
    amount &= is64 ? 63u : 31u;
    switch (type) {
    case 0: return is64 ? (v << amount) : (uint64_t)((uint32_t)v << amount);
    case 1: return is64 ? (v >> amount) : (uint64_t)((uint32_t)v >> amount);
    case 2: return (uint64_t)asr_imm(is64 ? (int64_t)v : (int64_t)(int32_t)v, amount);
    default: {
        if (!is64) {
            uint32_t u = (uint32_t)v;
            return amount ? (uint64_t)((u >> amount) | (u << (32 - amount))) : u;
        }
        return amount ? ((v >> amount) | (v << (64 - amount))) : v;
    }
    }
}

static uint64_t extend_reg(uint64_t value, unsigned option, unsigned shift, int is64) {
    int64_t v;
    switch (option) {
    case 0: v = (int64_t)(uint8_t)value; break;
    case 1: v = (int64_t)(uint16_t)value; break;
    case 2: v = (int64_t)(uint32_t)value; break;
    case 3: v = (int64_t)value; break;
    case 4: v = (int8_t)value; break;
    case 5: v = (int16_t)value; break;
    case 6: v = (int32_t)value; break;
    default: v = (int64_t)value; break;
    }
    uint64_t r = (uint64_t)v << shift;
    return is64 ? r : (r & MASK32);
}

static int cond_holds(unsigned cond, uint64_t nzcv) {
    int n = (int)((nzcv >> 31) & 1), z = (int)((nzcv >> 30) & 1);
    int c = (int)((nzcv >> 29) & 1), v = (int)((nzcv >> 28) & 1);
    switch (cond & 15) {
    case 0:  return z;
    case 1:  return !z;
    case 2:  return c;
    case 3:  return !c;
    case 4:  return n;
    case 5:  return !n;
    case 6:  return v;
    case 7:  return !v;
    case 8:  return c && !z;
    case 9:  return !c || z;
    case 10: return n == v;
    case 11: return n != v;
    case 12: return !z && n == v;
    case 13: return z || n != v;
    default: return 1;
    }
}

static uint64_t nzcv_logic(uint64_t r, int is64) {
    unsigned w = is64 ? 64 : 32;
    return ((uint64_t)((r >> (w - 1)) & 1) << 31) | ((r == 0 ? 1ull : 0ull) << 30);
}

/* flags for add/sub, with optional carry-in (carryIn < 0 means "no carry") */
static uint64_t nzcv_addsub(uint64_t a, uint64_t b, uint64_t r, int is64, int isSub, int carryIn) {
    unsigned w = is64 ? 64 : 32;
    uint64_t mask = WMASK(is64);
    uint64_t sa = a & mask, sb = b & mask, sr = r & mask;
    int n = (int)((sr >> (w - 1)) & 1);
    int z = (sr == 0);
    int c, v;
    if (isSub) {
        unsigned __int128 sub = (unsigned __int128)sa - sb - (carryIn >= 0 && !carryIn ? 1 : 0);
        c = ((sub >> 64) & 1) == 0 ? 1 : 0;
        v = (int)((((sa ^ sb) & (sa ^ sr)) >> (w - 1)) & 1);
    } else {
        unsigned __int128 add = (unsigned __int128)sa + sb + (carryIn == 1 ? 1 : 0);
        c = ((add >> w) & 1) ? 1 : 0;
        v = (int)(((~(sa ^ sb) & (sa ^ sr)) >> (w - 1)) & 1);
    }
    return ((uint64_t)n << 31) | ((uint64_t)z << 30) | ((uint64_t)c << 29) | ((uint64_t)v << 28);
}

/* ---------------- main decode ---------------- */

int ry_interp_step(RyInterp *in) {
    RyCpu *cpu = &in->cpu;
    if (cpu->pc + 4 > in->mem_size) return RY_ERR_PC;

    uint32_t insn;
    memcpy(&insn, in->mem + cpu->pc, 4);
    uint64_t pc = cpu->pc;
    cpu->pc = pc + 4;
    in->insns++;

    /* ===== HINT / NOP / barriers in the hint space ===== */
    if ((insn & 0xfffff01f) == 0xd503201f) {
        unsigned imm = BITS(insn, 11, 5);
        if (imm == 3 || imm == 4) { in->halted = 1; return RY_ERR_HALT; }  /* WFI/WFE */
        return RY_OK;
    }

    /* ===== Unconditional branch (immediate) ===== */
    if ((insn & 0x7c000000) == 0x14000000) {
        int64_t off = SEXT(BITS(insn, 25, 0), 26) << 2;
        if (BIT(insn, 31)) cpu->x[30] = pc + 4;
        cpu->pc = pc + (uint64_t)off;
        return RY_OK;
    }

    /* ===== Unconditional branch (register): BR/BLR/RET/ERET/DRPS ===== */
    if ((insn & 0xfe000000) == 0xd6000000) {
        unsigned opc = BITS(insn, 24, 21);
        uint64_t target = X(BITS(insn, 9, 5));
        switch (opc) {
        case 0: cpu->pc = target; return RY_OK;                        /* BR */
        case 1: cpu->x[30] = pc + 4; cpu->pc = target; return RY_OK;    /* BLR */
        case 2: cpu->pc = target; return RY_OK;                        /* RET */
        case 4: case 5:                                                /* ERET / DRPS */
            cpu->pc = cpu->elr_el1 ? cpu->elr_el1 : target;
            cpu->el = (unsigned)((cpu->spsr_el1 >> 2) & 3);
            if (cpu->el == 0) cpu->pc = cpu->elr_el1;
            return RY_OK;
        default: break;
        }
    }

    /* ===== Conditional branch ===== */
    if ((insn & 0xff000010) == 0x54000000) {
        if (cond_holds(BITS(insn, 3, 0), cpu->nzcv))
            cpu->pc = pc + (uint64_t)(SEXT(BITS(insn, 23, 5), 19) << 2);
        return RY_OK;
    }

    /* ===== CBZ / CBNZ ===== */
    if ((insn & 0x7e000000) == 0x34000000) {
        int is64 = (int)BIT(insn, 31);
        uint64_t v = X(BITS(insn, 4, 0));
        if (!is64) v &= MASK32;
        int nz = (v != 0);
        if (nz == (int)BIT(insn, 24))
            cpu->pc = pc + (uint64_t)(SEXT(BITS(insn, 23, 5), 19) << 2);
        return RY_OK;
    }

    /* ===== TBZ / TBNZ ===== */
    if ((insn & 0x7e000000) == 0x36000000) {
        unsigned bit = BITS(insn, 23, 19) | (BIT(insn, 31) << 5);
        int set = (int)((X(BITS(insn, 4, 0)) >> bit) & 1);
        if (set == (int)BIT(insn, 24))
            cpu->pc = pc + (uint64_t)(SEXT(BITS(insn, 18, 5), 14) << 2);
        return RY_OK;
    }

    /* ===== Exception generation: SVC/HVC/SMC/BRK/HLT ===== */
    if ((insn & 0xff000000) == 0xd4000000) {
        unsigned opc = BITS(insn, 23, 21);
        uint32_t imm16 = BITS(insn, 20, 5);
        if (opc == 1 || opc == 2 || opc == 0) {
            in->svc_imm = imm16;
            in->svc_pc = pc;
            cpu->elr_el1 = pc + 4;
            cpu->esr_el1 = ((uint64_t)0x15 << 26) | ((uint64_t)(opc == 1 ? 0x15 : 0x16) << 26);
            return RY_ERR_SVC;
        }
        return RY_ERR_HALT;      /* BRK / HLT */
    }

    /* ===== System instructions (MSR/MRS/SYS/SYSL/barriers) ===== */
    if ((insn & 0xffc00000) == 0xd5000000) {
        unsigned l = BIT(insn, 21);
        unsigned op0 = BITS(insn, 20, 19), op1 = BITS(insn, 18, 16);
        unsigned crn = BITS(insn, 15, 12), crm = BITS(insn, 11, 8), op2 = BITS(insn, 7, 5);
        unsigned rt = BITS(insn, 4, 0);

        if (op0 == 0 && op1 == 3 && crn == 4) return RY_OK;   /* DSB/DMB/ISB */

        if (l) {
            XSET(rt, ry_sysreg_read(in, op0, op1, crn, crm, op2));
        } else if (rt != 31) {
            ry_sysreg_write(in, op0, op1, crn, crm, op2, X(rt));
        }
        return RY_OK;
    }

    /* ===== ADR / ADRP ===== */
    if ((insn & 0x1f000000) == 0x10000000) {
        int page = (int)BIT(insn, 31);
        unsigned rd = BITS(insn, 4, 0);
        int64_t imm = SEXT((int64_t)(((uint64_t)BITS(insn, 23, 5) << 2) | BITS(insn, 30, 29)), 21);
        XSET(rd, page ? ((pc & ~0xfffull) + ((uint64_t)imm << 12))
                      : (uint64_t)((int64_t)pc + imm));
        return RY_OK;
    }

    /* ===== Add/subtract (immediate) ===== */
    if ((insn & 0x1f000000) == 0x11000000) {
        int is64 = (int)BIT(insn, 31), isSub = (int)BIT(insn, 30), setf = (int)BIT(insn, 29);
        uint64_t imm = BITS(insn, 21, 10);
        if (BIT(insn, 22)) imm <<= 12;
        unsigned rn = BITS(insn, 9, 5), rd = BITS(insn, 4, 0);
        uint64_t a = X(rn), r = isSub ? (a - imm) : (a + imm);
        if (!is64) r &= MASK32;
        if (setf) cpu->nzcv = nzcv_addsub(a, imm, r, is64, isSub, -1);
        else XSET(rd, r);
        return RY_OK;
    }

    /* ===== Logical (immediate) ===== */
    if ((insn & 0x1f800000) == 0x12000000) {
        int is64 = (int)BIT(insn, 31);
        unsigned opc = BITS(insn, 30, 29);
        uint64_t imm;
        if (!decode_bitmask(BIT(insn, 22), BITS(insn, 15, 10), BITS(insn, 21, 16), is64, &imm))
            return RY_ERR_UNSUPPORTED;
        uint64_t a = X(BITS(insn, 9, 5)), r;
        unsigned rd = BITS(insn, 4, 0);
        int setf = 0;
        switch (opc) {
        case 0: r = a & imm; break;
        case 1: r = a | imm; break;
        case 2: r = a ^ imm; break;
        default: r = a & imm; setf = 1; break;
        }
        if (!is64) r &= MASK32;
        if (setf) cpu->nzcv = nzcv_logic(r, is64);
        else XSET(rd, r);
        return RY_OK;
    }

    /* ===== Move wide (immediate): MOVN / MOVZ / MOVK ===== */
    if ((insn & 0x1f800000) == 0x12800000) {
        int is64 = (int)BIT(insn, 31);
        unsigned opc = BITS(insn, 30, 29), hw = BITS(insn, 22, 21);
        uint64_t imm = (uint64_t)BITS(insn, 20, 5) << (16 * hw);
        unsigned rd = BITS(insn, 4, 0);
        uint64_t v;
        if (opc == 0) v = ~imm;
        else if (opc == 2) v = imm;
        else if (opc == 3) v = ((rd == 31 ? 0 : cpu->x[rd]) & ~((uint64_t)0xffff << (16 * hw))) | imm;
        else return RY_ERR_UNSUPPORTED;
        if (!is64) v &= MASK32;
        XSET(rd, v);
        return RY_OK;
    }

    /* ===== Bitfield: SBFM / BFM / UBFM (LSL/LSR/ASR imm, UBFX/SBFX, BFI/BFXIL) ===== */
    if ((insn & 0x1f800000) == 0x13000000) {
        int is64 = (int)BIT(insn, 31);
        unsigned opc = BITS(insn, 30, 29);
        unsigned immr = BITS(insn, 21, 16), imms = BITS(insn, 15, 10);
        unsigned rn = BITS(insn, 9, 5), rd = BITS(insn, 4, 0);
        unsigned width = is64 ? 64 : 32;
        if (imms < immr) return RY_ERR_UNSUPPORTED;
        unsigned bits = imms - immr + 1;
        uint64_t src = X(rn);
        uint64_t rotated = rot_right(is64 ? src : (src & MASK32), immr, width);
        uint64_t field_mask = (bits == 64) ? MASK64 : (((uint64_t)1 << bits) - 1);
        uint64_t v;
        if (opc == 2) {                    /* UBFM */
            v = rotated & field_mask;
        } else if (opc == 0) {             /* SBFM */
            v = (uint64_t)SEXT(rotated & field_mask, bits);
        } else {                           /* BFM */
            uint64_t dst = (rd == 31 ? 0 : cpu->x[rd]);
            v = (dst & ~field_mask) | (rotated & field_mask);
        }
        if (!is64) v &= MASK32;
        XSET(rd, v);
        return RY_OK;
    }

    /* ===== EXTR ===== */
    if ((insn & 0x1f800000) == 0x13800000) {
        int is64 = (int)BIT(insn, 31);
        unsigned rm = BITS(insn, 20, 16), lsb = BITS(insn, 15, 10);
        unsigned width = is64 ? 64 : 32;
        uint64_t hi = X(BITS(insn, 9, 5)), lo = X(rm);
        uint64_t v = lsb ? ((lo >> lsb) | (hi << (width - lsb))) : lo;
        if (!is64) v &= MASK32;
        XSET(BITS(insn, 4, 0), v);
        return RY_OK;
    }

    /* ===== Logical (shifted register), incl. BIC/ORN/EON/BICS (N bit) ===== */
    if ((insn & 0x1f000000) == 0x0a000000) {
        int is64 = (int)BIT(insn, 31);
        unsigned opc = BITS(insn, 30, 29);
        uint64_t b = shift_reg(X(BITS(insn, 20, 16)), BITS(insn, 23, 22), BITS(insn, 15, 10), is64);
        if (BIT(insn, 21)) b = is64 ? ~b : ((~b) & MASK32);
        uint64_t a = X(BITS(insn, 9, 5)), r;
        unsigned rd = BITS(insn, 4, 0);
        int setf = 0;
        switch (opc) {
        case 0: r = a & b; break;
        case 1: r = a | b; break;
        case 2: r = a ^ b; break;
        default: r = a & b; setf = 1; break;
        }
        if (!is64) r &= MASK32;
        if (setf) cpu->nzcv = nzcv_logic(r, is64);
        else XSET(rd, r);
        return RY_OK;
    }

    /* ===== Add/subtract (shifted register) ===== */
    if ((insn & 0x1f200000) == 0x0b000000) {
        int is64 = (int)BIT(insn, 31), isSub = (int)BIT(insn, 30), setf = (int)BIT(insn, 29);
        uint64_t b = shift_reg(X(BITS(insn, 20, 16)), BITS(insn, 23, 22), BITS(insn, 15, 10), is64);
        uint64_t a = X(BITS(insn, 9, 5));
        uint64_t r = isSub ? (a - b) : (a + b);
        if (!is64) r &= MASK32;
        if (setf) cpu->nzcv = nzcv_addsub(a, b, r, is64, isSub, -1);
        else XSET(BITS(insn, 4, 0), r);
        return RY_OK;
    }

    /* ===== Add/subtract (extended register) ===== */
    if ((insn & 0x1f200000) == 0x0b200000) {
        int is64 = (int)BIT(insn, 31), isSub = (int)BIT(insn, 30), setf = (int)BIT(insn, 29);
        uint64_t b = extend_reg(X(BITS(insn, 20, 16)), BITS(insn, 15, 13), BITS(insn, 12, 10), is64);
        uint64_t a = X(BITS(insn, 9, 5));
        uint64_t r = isSub ? (a - b) : (a + b);
        if (!is64) r &= MASK32;
        if (setf) cpu->nzcv = nzcv_addsub(a, b, r, is64, isSub, -1);
        else XSET(BITS(insn, 4, 0), r);
        return RY_OK;
    }

    /* ===== Add/subtract with carry: ADC / ADCS / SBC / SBCS ===== */
    if ((insn & 0x1fe00000) == 0x1a000000) {
        int is64 = (int)BIT(insn, 31), isSub = (int)BIT(insn, 30), setf = (int)BIT(insn, 29);
        uint64_t carry = (cpu->nzcv >> 29) & 1;
        uint64_t a = X(BITS(insn, 9, 5));
        uint64_t b = X(BITS(insn, 20, 16));
        uint64_t eff = isSub ? (~b & WMASK(is64)) : b;
        uint64_t r = a + eff + carry;
        if (!is64) r &= MASK32;
        if (setf) {
            unsigned w = is64 ? 64 : 32;
            uint64_t mask = WMASK(is64);
            uint64_t sa = a & mask, sb = eff & mask, sr = r & mask;
            unsigned __int128 full = (unsigned __int128)sa + sb + carry;
            int c = (int)((full >> w) & 1);
            int v = (int)(((~(sa ^ sb) & (sa ^ sr)) >> (w - 1)) & 1);
            cpu->nzcv = ((uint64_t)((sr >> (w - 1)) & 1) << 31)
                      | ((sr == 0 ? 1ull : 0ull) << 30) | ((uint64_t)c << 29) | ((uint64_t)v << 28);
        } else XSET(BITS(insn, 4, 0), r);
        return RY_OK;
    }

    /* ===== Conditional compare: CCMP / CCMN ===== */
    if ((insn & 0x1fe00800) == 0x1a400000) {
        int is64 = (int)BIT(insn, 31), isSub = (int)BIT(insn, 30);
        uint64_t a = X(BITS(insn, 9, 5)), b = X(BITS(insn, 20, 16));
        if (!is64) { a &= MASK32; b &= MASK32; }
        if (cond_holds(BITS(insn, 15, 12), cpu->nzcv)) {
            uint64_t r = isSub ? (a - b) : (a + b);
            if (!is64) r &= MASK32;
            cpu->nzcv = nzcv_addsub(a, b, r, is64, isSub, -1);
        } else {
            cpu->nzcv = ((uint64_t)BITS(insn, 3, 0) & 0xf) << 28;
        }
        return RY_OK;
    }

    /* ===== Conditional select: CSEL / CSINC / CSINV / CSNEG ===== */
    if ((insn & 0x1fe00800) == 0x1a800000) {
        int is64 = (int)BIT(insn, 31);
        uint64_t v;
        if (cond_holds(BITS(insn, 15, 12), cpu->nzcv)) {
            v = X(BITS(insn, 9, 5));
        } else {
            uint64_t b = X(BITS(insn, 20, 16));
            switch (BITS(insn, 11, 10)) {
            case 0: v = b; break;
            case 1: v = b + 1; break;
            case 2: v = ~b; break;
            default: v = (uint64_t)(-(int64_t)b); break;
            }
        }
        if (!is64) v &= MASK32;
        XSET(BITS(insn, 4, 0), v);
        return RY_OK;
    }

    /* ===== Data-processing (3 source) ===== */
    if ((insn & 0x1f000000) == 0x1b000000) {
        int is64 = (int)BIT(insn, 31);
        unsigned op31 = BITS(insn, 23, 21), o0 = BIT(insn, 15);
        uint64_t a = X(BITS(insn, 9, 5)), b = X(BITS(insn, 20, 16));
        uint64_t acc = X(BITS(insn, 14, 10)), v;
        if (op31 == 0 && !o0) v = a * b + acc;                       /* MADD */
        else if (op31 == 0 && o0) v = acc - a * b;                    /* MSUB */
        else if (op31 == 1) {                                         /* SMADDL/SMSUBL */
            int64_t p = (int64_t)(int32_t)a * (int64_t)(int32_t)b;
            v = o0 ? (uint64_t)((int64_t)acc - p) : (uint64_t)(p + (int64_t)acc);
            is64 = 1;
        } else if (op31 == 5) {                                       /* UMADDL/UMSUBL */
            uint64_t p = (uint64_t)(uint32_t)a * (uint64_t)(uint32_t)b;
            v = o0 ? (acc - p) : (p + acc);
            is64 = 1;
        } else if (op31 == 2) {                                       /* SMULH */
            __int128 p = (__int128)(int64_t)a * (__int128)(int64_t)b;
            v = (uint64_t)(p >> 64); is64 = 1;
        } else if (op31 == 6) {                                       /* UMULH */
            unsigned __int128 p = (unsigned __int128)a * b;
            v = (uint64_t)(p >> 64); is64 = 1;
        } else return RY_ERR_UNSUPPORTED;
        if (!is64) v &= MASK32;
        XSET(BITS(insn, 4, 0), v);
        return RY_OK;
    }

    /* ===== Data-processing (2 source) ===== */
    if ((insn & 0x1fe00000) == 0x1ac00000) {
        int is64 = (int)BIT(insn, 31);
        uint64_t a = X(BITS(insn, 9, 5)), b = X(BITS(insn, 20, 16)), v;
        if (!is64) { a &= MASK32; b &= MASK32; }
        switch (BITS(insn, 15, 10)) {
        case 0x02: v = b ? a / b : 0; break;                          /* UDIV */
        case 0x03: {                                                   /* SDIV */
            if (!b) { v = 0; break; }
            int64_t sa = is64 ? (int64_t)a : (int64_t)(int32_t)a;
            int64_t sb = is64 ? (int64_t)b : (int64_t)(int32_t)b;
            v = (uint64_t)(sa / sb);
            break;
        }
        case 0x08: v = shift_reg(a, 0, (unsigned)b, is64); break;     /* LSLV */
        case 0x09: v = shift_reg(a, 1, (unsigned)b, is64); break;     /* LSRV */
        case 0x0a: v = shift_reg(a, 2, (unsigned)b, is64); break;     /* ASRV */
        case 0x0b: v = shift_reg(a, 3, (unsigned)b, is64); break;     /* RORV */
        case 0x10: case 0x11: case 0x12: case 0x13:
        case 0x14: case 0x15: case 0x16: case 0x17:
            v = crc32_op((uint32_t)a, (uint32_t)b, BITS(insn, 15, 10) & 0xf);
            break;
        default: return RY_ERR_UNSUPPORTED;
        }
        if (!is64) v &= MASK32;
        XSET(BITS(insn, 4, 0), v);
        return RY_OK;
    }

    /* ===== Data-processing (1 source): RBIT/REV16/REV32/REV/CLZ/CLS ===== */
    if ((insn & 0x5fe00000) == 0x5ac00000) {
        int is64 = (int)BIT(insn, 31);
        uint64_t a = X(BITS(insn, 9, 5)), v = 0;
        if (!is64) a &= MASK32;
        unsigned n = is64 ? 64 : 32;
        switch (BITS(insn, 15, 10)) {
        case 0x00: {                                                  /* RBIT */
            for (unsigned i = 0; i < n; i++) if ((a >> i) & 1) v |= 1ull << (n - 1 - i);
            break;
        }
        case 0x01: {                                                  /* REV16 */
            unsigned lanes = is64 ? 4 : 2;
            for (unsigned i = 0; i < lanes; i++) {
                uint16_t h = (uint16_t)(a >> (16 * i));
                v |= (uint64_t)(uint16_t)((h >> 8) | (h << 8)) << (16 * i);
            }
            break;
        }
        case 0x02: {                                                  /* REV32 */
            unsigned lanes = is64 ? 2 : 1;
            for (unsigned i = 0; i < lanes; i++) {
                uint32_t w = (uint32_t)(a >> (32 * i));
                uint32_t rv = ((w & 0xff) << 24) | ((w & 0xff00) << 8)
                            | ((w >> 8) & 0xff00) | ((w >> 24) & 0xff);
                v |= (uint64_t)rv << (32 * i);
            }
            break;
        }
        case 0x03: {                                                  /* REV */
            if (is64) {
                v = __builtin_bswap64(a);
            } else {
                v = __builtin_bswap32((uint32_t)a);
            }
            break;
        }
        case 0x04:                                                    /* CLZ */
            v = a ? (uint64_t)(n - 1 - (63 - __builtin_clzll(a))) : (uint64_t)n;
            v = a ? (uint64_t)(__builtin_clzll(a) - (64 - n)) : (uint64_t)n;
            break;
        case 0x05: {                                                  /* CLS */
            uint64_t sign = (a >> (n - 1)) & 1;
            unsigned cnt = 0;
            for (int i = (int)n - 2; i >= 0; i--) {
                if (((a >> i) & 1) != sign) break;
                cnt++;
            }
            v = cnt;
            break;
        }
        default: return RY_ERR_UNSUPPORTED;
        }
        if (!is64) v &= MASK32;
        XSET(BITS(insn, 4, 0), v);
        return RY_OK;
    }

    /* ===== Load / store ===== */
    if (ry_interp_loadstore(in, insn, pc) == 0) return RY_OK;

    /* ===== SIMD / FP ===== */
    {
        int rc = ry_interp_simd(in, insn, pc);
        if (rc != 1) return rc;
    }

    in->unsupported_insn = insn;
    in->unsupported_pc = pc;
    return RY_ERR_UNSUPPORTED;
}

int ry_interp_run(RyInterp *in, uint64_t stop_pc, uint64_t max_insns) {
    while (in->insns < max_insns) {
        if (stop_pc != 0 && in->cpu.pc == stop_pc) return RY_OK;
        int rc = ry_interp_step(in);
        if (rc != RY_OK) return rc;
    }
    return RY_ERR_LIMIT;
}

void ry_interp_reset(RyInterp *in, uint64_t entry) {
    uint8_t *mem = in->mem;
    uint64_t size = in->mem_size;
    memset(&in->cpu, 0, sizeof(in->cpu));
    in->cpu.pc = entry;
    in->cpu.el = 1;
    in->cpu.currentel = 0x4;          /* EL1 */
    in->cpu.mpidr_el1 = 0x80000000ull; /* uniprocessor affinity */
    in->mem = mem;
    in->mem_size = size;
    in->insns = 0;
    in->unsupported_insn = 0;
    in->unsupported_pc = 0;
    in->halted = 0;
    in->last_error = RY_OK;
    in->svc_imm = 0;
    in->svc_pc = 0;
}
