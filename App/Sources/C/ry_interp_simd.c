/*
 * Scalar floating point and the small set of SIMD operations an early boot
 * path touches (register moves, loads/stores, integer add/sub on vectors).
 *
 * Vector register model: v[n] is a 128-bit value; S/D/Q views are the low 32,
 * 64 and 128 bits. Lane-wise operations use the size field in the encoding.
 */
#include <stdint.h>
#include <string.h>
#include <math.h>

#include "ry_interp.h"

#define BIT(x, n)       (((x) >> (n)) & 1u)
#define BITS(x, hi, lo) (((x) >> (lo)) & ((1u << ((hi) - (lo) + 1)) - 1u))
#define SEXT(v, bits)   ((int64_t)((uint64_t)(v) << (64 - (bits))) >> (64 - (bits)))
#define MASK64          (~0ull)

static uint64_t vget_lo(RyInterp *in, unsigned r) { return (uint64_t)in->cpu.v[r & 31]; }
static uint64_t vget_hi(RyInterp *in, unsigned r) { return (uint64_t)(in->cpu.v[r & 31] >> 64); }
static void vset(RyInterp *in, unsigned r, uint64_t lo, uint64_t hi) {
    in->cpu.v[r & 31] = ((__uint128_t)hi << 64) | lo;
}
static void vset_lo(RyInterp *in, unsigned r, uint64_t lo) {
    in->cpu.v[r & 31] = (__uint128_t)lo;
}
static uint32_t vget_s(RyInterp *in, unsigned r) { return (uint32_t)in->cpu.v[r & 31]; }
static void vset_s(RyInterp *in, unsigned r, uint32_t v) {
    in->cpu.v[r & 31] = (__uint128_t)v;
}

/* Expand an 8-bit floating immediate (VFPExpandImm) for FMOV Sd/Dd,#imm. */
static double fp_imm8(unsigned imm8, int isDouble) {
    unsigned sign = (imm8 >> 7) & 1;
    unsigned exp = (imm8 >> 4) & 7;
    unsigned frac = imm8 & 0xf;
    if (exp == 0) {
        if (frac == 0) return sign ? -0.0 : 0.0;
        double v = ldexp((double)frac / 16.0, -2);
        return sign ? -v : v;
    }
    if (exp == 7 && frac == 0) return sign ? -INFINITY : INFINITY;
    if (exp == 7 && frac != 0) return NAN;
    double v = ldexp(1.0 + (double)frac / 16.0, (int)exp - 3);
    return sign ? -v : v;
}

int ry_interp_simd(RyInterp *in, uint32_t insn, uint64_t pc) {
    (void)pc;

    /* ---- Scalar FP: 0x1E/0x1F opcodes ---- */
    if ((insn & 0x5f000000) == 0x1e000000) {
        unsigned m = BIT(insn, 31);          /* 0: single, 1: double */
        unsigned type = BITS(insn, 23, 22);
        unsigned rt = BITS(insn, 4, 0), rn = BITS(insn, 9, 5), rm = BITS(insn, 20, 16);

        /* FMOV (register) */
        if ((insn & 0x7fe0fc00) == 0x1e604000) {
            if (m) {
                uint64_t v = vget_lo(in, rn);
                vset_lo(in, rt, v);
            } else {
                uint32_t v = vget_s(in, rn);
                vset_s(in, rt, v);
            }
            return RY_OK;
        }
        /* FMOV (general register) */
        if ((insn & 0x7fe0fc00) == 0x1e600000) {
            unsigned sf = BIT(insn, 31);
            unsigned rmode = BITS(insn, 18, 16);
            if (rmode == 6) {                 /* FMOV Xd, Dn / Wd, Sn */
                if (sf) RY_XSET(in, rt, vget_lo(in, rn));
                else RY_XSET(in, rt, vget_s(in, rn));
            } else if (rmode == 7) {          /* FMOV Dd, Xn / Sd, Wn */
                if (sf) vset_lo(in, rt, RY_X(in, rn));
                else vset_s(in, rt, (uint32_t)RY_X(in, rn));
            }
            return RY_OK;
        }
        /* FMOV (immediate) */
        if ((insn & 0x7fe01fe0) == 0x1e201000) {
            double d = fp_imm8(BITS(insn, 20, 13), m);
            if (m) { double v = d; uint64_t b; memcpy(&b, &v, 8); vset_lo(in, rt, b); }
            else { float f = (float)d; uint32_t b; memcpy(&b, &f, 4); vset_s(in, rt, b); }
            return RY_OK;
        }
        /* Floating point 2-source: FADD/FSUB/FMUL/FDIV/FMAX/FMIN */
        if ((insn & 0x5f200000) == 0x1e200000) {
            unsigned opc = BITS(insn, 15, 12);
            double a, b, r;
            if (m) { uint64_t t; memcpy(&t, &in->cpu.v[rn & 31], 8); memcpy(&a, &t, 8);
                     memcpy(&t, &in->cpu.v[rm & 31], 8); memcpy(&b, &t, 8); }
            else { uint32_t t; memcpy(&t, &in->cpu.v[rn & 31], 4); memcpy(&a, &t, 4);
                   memcpy(&t, &in->cpu.v[rm & 31], 4); memcpy(&b, &t, 4); }
            switch (opc) {
            case 0x2: r = a * b; break;
            case 0x3: r = a / b; break;
            case 0x8: r = a + b; break;
            case 0x9: r = a - b; break;
            case 0xa: r = fmax(a, b); break;
            case 0xb: r = fmin(a, b); break;
            default: return RY_ERR_UNSUPPORTED;
            }
            if (m) { uint64_t t; memcpy(&t, &r, 8); vset_lo(in, rt, t); }
            else { float f = (float)r; uint32_t t; memcpy(&t, &f, 4); vset_s(in, rt, t); }
            return RY_OK;
        }
        /* Floating point 1-source: FMOV/FABS/FNEG/FCVT */
        if ((insn & 0x5f207c00) == 0x1e204000) {
            unsigned opc = BITS(insn, 20, 15);
            if (opc == 0x00) {           /* FMOV */
                if (m) vset_lo(in, rt, vget_lo(in, rn));
                else vset_s(in, rt, vget_s(in, rn));
                return RY_OK;
            }
            if (opc == 0x01) {           /* FABS */
                if (m) vset_lo(in, rt, vget_lo(in, rn) & 0x7fffffffffffffffull);
                else vset_s(in, rt, vget_s(in, rn) & 0x7fffffff);
                return RY_OK;
            }
            if (opc == 0x02) {           /* FNEG */
                if (m) vset_lo(in, rt, vget_lo(in, rn) ^ 0x8000000000000000ull);
                else vset_s(in, rt, vget_s(in, rn) ^ 0x80000000);
                return RY_OK;
            }
            if (opc == 0x04 || opc == 0x05) {   /* FCVT single<->double */
                if (m) {                          /* double source */
                    double d; uint64_t t = vget_lo(in, rn); memcpy(&d, &t, 8);
                    float f = (float)d; uint32_t b; memcpy(&b, &f, 4); vset_s(in, rt, b);
                } else {                          /* single source */
                    float f; uint32_t t = vget_s(in, rn); memcpy(&f, &t, 4);
                    double d = (double)f; uint64_t b; memcpy(&b, &d, 8); vset_lo(in, rt, b);
                }
                return RY_OK;
            }
            return RY_ERR_UNSUPPORTED;
        }
        /* FCMP / FCMPE */
        if ((insn & 0x5f203c00) == 0x1e202000) {
            unsigned rmode = BITS(insn, 4, 3);
            double a, b;
            if (m) { uint64_t t; memcpy(&t, &in->cpu.v[rn & 31], 8); memcpy(&a, &t, 8); }
            else { uint32_t t; memcpy(&t, &in->cpu.v[rn & 31], 4); memcpy(&a, &t, 4); }
            if (rmode == 0) b = 0.0;
            else {
                if (m) { uint64_t t; memcpy(&t, &in->cpu.v[rm & 31], 8); memcpy(&b, &t, 8); }
                else { uint32_t t; memcpy(&t, &in->cpu.v[rm & 31], 4); memcpy(&b, &t, 4); }
            }
            uint64_t nzcv;
            if (isnan(a) || isnan(b)) nzcv = 0x3ull << 28;       /* N=0,Z=0,C=1,V=1 */
            else if (a == b) nzcv = 0x6ull << 28;                 /* Z=1,C=1 */
            else if (a < b) nzcv = 0x8ull << 28;                  /* N=1 */
            else nzcv = 0x2ull << 28;                             /* C=1 */
            in->cpu.nzcv = nzcv;
            return RY_OK;
        }
        /* SCVTF / UCVTF / FCVTZS / FCVTZU (int <-> fp) */
        if ((insn & 0x5f20fc00) == 0x1e200000 || (insn & 0x7f20fc00) == 0x1e200000) {
            unsigned sf = BIT(insn, 31);
            unsigned opc = BITS(insn, 20, 16);
            unsigned rmode = BITS(insn, 15, 10);
            (void)rmode;
            if (opc == 2) {              /* SCVTF */
                int64_t iv = sf ? (int64_t)RY_X(in, rn) : (int64_t)(int32_t)RY_X(in, rn);
                double d = (double)iv;
                if (m) { uint64_t t; memcpy(&t, &d, 8); vset_lo(in, rt, t); }
                else { float f = (float)d; uint32_t t; memcpy(&t, &f, 4); vset_s(in, rt, t); }
                return RY_OK;
            }
            if (opc == 3) {              /* UCVTF */
                uint64_t uv = sf ? RY_X(in, rn) : (uint32_t)RY_X(in, rn);
                double d = (double)uv;
                if (m) { uint64_t t; memcpy(&t, &d, 8); vset_lo(in, rt, t); }
                else { float f = (float)d; uint32_t t; memcpy(&t, &f, 4); vset_s(in, rt, t); }
                return RY_OK;
            }
            if (opc == 0 || opc == 1) {  /* FCVTZS / FCVTZU */
                double d;
                if (m) { uint64_t t = vget_lo(in, rn); memcpy(&d, &t, 8); }
                else { uint32_t t = vget_s(in, rn); float f; memcpy(&f, &t, 4); d = (double)f; }
                if (opc == 0) {
                    int64_t iv = (int64_t)d;
                    RY_XSET(in, rt, sf ? (uint64_t)iv : (uint64_t)(int64_t)(int32_t)iv);
                } else {
                    uint64_t uv = (uint64_t)d;
                    RY_XSET(in, rt, sf ? uv : (uv & 0xffffffffull));
                }
                return RY_OK;
            }
            return RY_ERR_UNSUPPORTED;
        }
        return RY_ERR_UNSUPPORTED;
    }

    /* ---- SIMD (advanced SIMD) ---- */

    /* MOVI / DUP (immediate) for the common 32-bit pattern */
    if ((insn & 0x9ff80400) == 0x0f000400) {
        unsigned q = BIT(insn, 30);
        unsigned imm8 = (BITS(insn, 18, 16) << 5) | BITS(insn, 9, 5);
        uint32_t pat = (imm8 << 24) | (imm8 << 16) | (imm8 << 8) | imm8;
        uint64_t lo = ((uint64_t)pat << 32) | pat;
        vset(in, BITS(insn, 4, 0), lo, q ? lo : 0);
        return RY_OK;
    }

    /* DUP (element) */
    if ((insn & 0x9fe0fc00) == 0x0e000c00) {
        unsigned q = BIT(insn, 30);
        unsigned imm5 = BITS(insn, 20, 16);
        unsigned rd = BITS(insn, 4, 0), rn = BITS(insn, 9, 5);
        unsigned size = 0;
        while (!(imm5 & 1) && size < 4) { imm5 >>= 1; size++; }
        unsigned index = imm5 >> 1;
        unsigned bits = 8u << size;
        uint64_t elem = vget_lo(in, rn) >> (index * bits);
        elem &= (bits == 64) ? MASK64 : ((1ull << bits) - 1);
        uint64_t lo = 0;
        for (unsigned i = 0; i < 64; i += bits) lo |= (elem << i);
        vset(in, rd, lo, q ? lo : 0);
        return RY_OK;
    }

    /* INS (element) */
    if ((insn & 0x9fe08400) == 0x0e000400) {
        unsigned imm5 = BITS(insn, 20, 16), imm4 = BITS(insn, 14, 11);
        unsigned rd = BITS(insn, 4, 0), rn = BITS(insn, 9, 5);
        unsigned size = 0, t = imm5;
        while (!(t & 1) && size < 4) { t >>= 1; size++; }
        unsigned bits = 8u << size;
        unsigned dst_idx = imm5 >> (size + 1);
        unsigned src_idx = imm4 >> size;
        uint64_t mask = (bits == 64) ? MASK64 : ((1ull << bits) - 1);
        uint64_t elem = (vget_lo(in, rn) >> (src_idx * bits)) & mask;
        uint64_t cur = vget_lo(in, rd);
        cur &= ~(mask << (dst_idx * bits));
        cur |= elem << (dst_idx * bits);
        vset_lo(in, rd, cur);
        return RY_OK;
    }

    /* Vector integer add/sub (8/16/32/64-bit lanes) */
    if ((insn & 0x9f200400) == 0x0e208400
        || (insn & 0x9f200400) == 0x0e208400) {
        /* handled below */
    }
    if ((insn & 0x0f200400) == 0x0e208400) {
        unsigned q = BIT(insn, 30);
        unsigned op = BIT(insn, 23);          /* 0 add, 1 sub */
        unsigned size = BITS(insn, 23, 22);
        unsigned rd = BITS(insn, 4, 0), rn = BITS(insn, 9, 5), rm = BITS(insn, 20, 16);
        unsigned bytes = 8u << size;
        unsigned lanes = 64 / bytes;
        uint64_t a = vget_lo(in, rn), b = vget_lo(in, rm), r = 0;
        uint64_t mask = (bytes == 8) ? MASK64 : ((1ull << bytes) - 1);
        for (unsigned i = 0; i < lanes; i++) {
            uint64_t la = (a >> (i * bytes)) & mask;
            uint64_t lb = (b >> (i * bytes)) & mask;
            uint64_t lr;
            if (BIT(insn, 15)) lr = la - lb;   /* sub */
            else lr = la + lb;
            r |= (lr & mask) << (i * bytes);
        }
        vset(in, rd, r, q ? r : 0);
        (void)op;
        return RY_OK;
    }

    /* Vector LDR/STR (Q/D/S) -- ld1/st1 style single register */
    if ((insn & 0x3f000000) == 0x0c000000) {
        unsigned q = BIT(insn, 30);
        unsigned opc = BITS(insn, 11, 10);   /* 00 S, 01 D, 10 Q */
        unsigned rn = BITS(insn, 9, 5), rt = BITS(insn, 4, 0);
        int isLoad = BIT(insn, 22);
        int64_t off = SEXT(BITS(insn, 20, 12), 9);
        unsigned size = (opc == 0) ? 4 : (opc == 1) ? 8 : 16;
        uint64_t addr = RY_X(in, rn) + (uint64_t)off;
        uint8_t *p = (addr <= in->mem_size && size <= in->mem_size - addr) ? in->mem + addr : NULL;
        if (p) {
            if (isLoad) {
                uint64_t lo = 0, hi = 0;
                memcpy(&lo, p, size >= 8 ? 8 : size);
                if (size == 16) memcpy(&hi, p + 8, 8);
                vset(in, rt, lo, size == 16 ? hi : 0);
            } else {
                uint64_t lo = vget_lo(in, rt), hi = vget_hi(in, rt);
                memcpy(p, &lo, size >= 8 ? 8 : size);
                if (size == 16) memcpy(p + 8, &hi, 8);
            }
        }
        (void)q;
        return RY_OK;
    }

    return 1;   /* not SIMD/FP */
}
