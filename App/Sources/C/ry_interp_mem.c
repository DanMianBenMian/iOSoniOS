/*
 * Interpreter support: bitmask immediates, system registers, all load/store
 * forms, and scalar FP + basic SIMD.
 *
 * Split out of ry_interp.c to keep each decoder readable.
 */
#include <stdint.h>
#include <string.h>
#include <math.h>

#include "ry_interp.h"

#define BIT(x, n)       (((x) >> (n)) & 1u)
#define BITS(x, hi, lo) (((x) >> (lo)) & ((1u << ((hi) - (lo) + 1)) - 1u))
#define SEXT(v, bits)   ((int64_t)((uint64_t)(v) << (64 - (bits))) >> (64 - (bits)))
#define X(i)            ((i) == 31 ? 0ull : in->cpu.x[(i)])
#define XSET(i, v)      do { if ((i) != 31) in->cpu.x[(i)] = (v); } while (0)
#define MASK64          (~0ull)
#define MASK32          0xffffffffull

/* ---------------- bitmask immediate ---------------- */

int decode_bitmask(unsigned n, unsigned imms, unsigned immr, int is64, uint64_t *out) {
    unsigned combined = (n << 6) | (~imms & 0x3f);
    if (combined == 0) return 0;
    unsigned len = 31 - __builtin_clz(combined);
    if (len < 1) return 0;
    unsigned size = 1u << len;
    if (!is64 && size > 32) return 0;

    unsigned levels = size - 1;
    unsigned s = imms & levels;
    unsigned r = immr & levels;
    if (s == levels) return 0;

    uint64_t elem = (s == 63) ? MASK64 : ((1ull << (s + 1)) - 1);
    if (size < 64) elem &= ((1ull << size) - 1);
    uint64_t rotated;
    if (r == 0) rotated = elem;
    else {
        uint64_t mask = (size == 64) ? MASK64 : ((1ull << size) - 1);
        rotated = ((elem >> r) | (elem << (size - r))) & mask;
    }
    uint64_t replic = 0;
    for (unsigned i = 0; i < 64; i += size) replic |= rotated << i;
    *out = replic;
    return 1;
}

uint64_t rot_right(uint64_t v, unsigned amount, unsigned width) {
    uint64_t mask = (width == 64) ? MASK64 : ((1ull << width) - 1);
    v &= mask;
    amount %= width;
    if (!amount) return v;
    return ((v >> amount) | (v << (width - amount))) & mask;
}

/* ---------------- CRC32 (for the CRC32* instructions) ---------------- */

static uint32_t crc32_table(uint32_t poly, uint32_t acc, uint32_t data, int bytes) {
    for (int i = 0; i < bytes; i++) {
        acc ^= (data >> (8 * i)) & 0xff;
        for (int b = 0; b < 8; b++)
            acc = (acc & 1) ? ((acc >> 1) ^ poly) : (acc >> 1);
    }
    return acc;
}

uint32_t crc32_op(uint32_t acc, uint32_t data, unsigned variant) {
    /* variants: 0x10 CRC32B, 0x11 CRC32H, 0x12 CRC32W, 0x13 CRC32X,
                 0x14 CRC32CB, 0x15 CRC32CH, 0x16 CRC32CW, 0x17 CRC32CX */
    int isCastagnoli = (variant >= 0x14);
    uint32_t poly = isCastagnoli ? 0x82f63b78u : 0xedb88320u;
    int op = variant & 0x3;
    int bytes = (op == 0) ? 1 : (op == 1) ? 2 : 4;
    return crc32_table(poly, acc, data, bytes);
}

/* ---------------- system registers ---------------- */

uint64_t ry_sysreg_read(RyInterp *in, unsigned op0, unsigned op1,
                        unsigned crn, unsigned crm, unsigned op2) {
    RyCpu *c = &in->cpu;
    /* S3_0_Cn_Cm_op2 for the registers early boot touches. */
    if (op0 == 3 && op1 == 0) {
        switch (crn) {
        case 0:
            if (crm == 0 && op2 == 0) return 0x410fd034ull;  /* MIDR: A14-ish */
            break;
        case 1:
            if (crm == 0 && op2 == 0) return c->sctlr_el1;
            break;
        case 2:
            if (crm == 0 && op2 == 0) return c->ttbr0_el1;
            if (crm == 0 && op2 == 1) return c->ttbr1_el1;
            if (crm == 0 && op2 == 2) return c->tcr_el1;
            break;
        case 3:
            if (crm == 0 && op2 == 0) return c->mair_el1;
            break;
        case 4:
            if (crm == 0 && op2 == 0) return c->spsr_el1;
            if (crm == 0 && op2 == 1) return c->elr_el1;
            if (crm == 4 && op2 == 0) return c->spsr_el2;
            if (crm == 4 && op2 == 1) return c->elr_el2;
            break;
        case 5:
            if (crm == 2 && op2 == 0) return c->esr_el1;
            if (crm == 6 && op2 == 0) return c->far_el1;
            break;
        case 6:
            if (crm == 0 && op2 == 0) return c->cpacr_el1;
            break;
        case 12:
            if (crm == 0 && op2 == 0) return c->vbar_el1;
            break;
        case 13:
            if (crm == 0 && op2 == 2) return c->tpidr_el0;
            if (crm == 0 && op2 == 3) return c->tpidrro_el0;
            if (crm == 0 && op2 == 4) return c->tpidr_el1;
            if (crm == 0 && op2 == 0) return htole64((uint64_t)(in->insns * 24));
            break;
        case 14:
            if (crm == 0 && op2 == 0) return c->cntfrq_el0 ? c->cntfrq_el0 : 24000000ull;
            break;
        }
    }
    if (op0 == 3 && op1 == 3 && crn == 0 && crm == 0) {
        if (op2 == 0) return c->cntvct_el0 ? c->cntvct_el0 : (uint64_t)(in->insns * 24);
        if (op2 == 1) return c->cntpct_el0 ? c->cntpct_el0 : (uint64_t)(in->insns * 24);
    }
    if (op0 == 3 && op1 == 0 && crn == 4 && crm == 0 && op2 == 0) return c->spsr_el1;
    if (op0 == 3 && op1 == 0 && crn == 0 && crm == 0 && op2 == 5) return c->mpidr_el1;
    if (op0 == 3 && op1 == 0 && crn == 4 && crm == 2 && op2 == 0) return c->currentel;
    /* Unknown system register: return 0 rather than failing the boot. */
    return 0;
}

void ry_sysreg_write(RyInterp *in, unsigned op0, unsigned op1,
                     unsigned crn, unsigned crm, unsigned op2, uint64_t value) {
    RyCpu *c = &in->cpu;
    if (op0 == 3 && op1 == 0) {
        switch (crn) {
        case 1: if (crm == 0 && op2 == 0) { c->sctlr_el1 = value; return; } break;
        case 2:
            if (crm == 0 && op2 == 0) { c->ttbr0_el1 = value; return; }
            if (crm == 0 && op2 == 1) { c->ttbr1_el1 = value; return; }
            if (crm == 0 && op2 == 2) { c->tcr_el1 = value; return; }
            break;
        case 3: if (crm == 0 && op2 == 0) { c->mair_el1 = value; return; } break;
        case 4:
            if (crm == 0 && op2 == 0) { c->spsr_el1 = value; return; }
            if (crm == 0 && op2 == 1) { c->elr_el1 = value; return; }
            if (crm == 4 && op2 == 0) { c->spsr_el2 = value; return; }
            if (crm == 4 && op2 == 1) { c->elr_el2 = value; return; }
            break;
        case 5:
            if (crm == 2 && op2 == 0) { c->esr_el1 = value; return; }
            if (crm == 6 && op2 == 0) { c->far_el1 = value; return; }
            break;
        case 6: if (crm == 0 && op2 == 0) { c->cpacr_el1 = value; return; } break;
        case 12: if (crm == 0 && op2 == 0) { c->vbar_el1 = value; return; } break;
        case 13:
            if (crm == 0 && op2 == 2) { c->tpidr_el0 = value; return; }
            if (crm == 0 && op2 == 3) { c->tpidrro_el0 = value; return; }
            if (crm == 0 && op2 == 4) { c->tpidr_el1 = value; return; }
            break;
        case 14: if (crm == 0 && op2 == 0) { c->cntfrq_el0 = value; return; } break;
        }
    }
    if (op0 == 3 && op1 == 3 && crn == 0 && crm == 0) {
        if (op2 == 0) { c->cntvct_el0 = value; return; }
        if (op2 == 1) { c->cntpct_el0 = value; return; }
    }
    /* Barriers / cache maintenance / TLBI: nothing to do in a flat model. */
}

/* ---------------- load / store ---------------- */

static uint8_t *ptr_of(RyInterp *in, uint64_t addr, unsigned size) {
    if (addr > in->mem_size || size > in->mem_size - addr) return NULL;
    return in->mem + addr;
}

static int do_load(RyInterp *in, uint64_t addr, unsigned size, int sign, uint64_t *out) {
    uint8_t *p = ptr_of(in, addr, size);
    if (!p) return -1;
    uint64_t v = 0;
    memcpy(&v, p, size);
    if (sign) {
        if (size == 1) v = (uint64_t)(int64_t)(int8_t)v;
        else if (size == 2) v = (uint64_t)(int64_t)(int16_t)v;
        else if (size == 4) v = (uint64_t)(int64_t)(int32_t)v;
    }
    *out = v;
    return 0;
}

static int do_store(RyInterp *in, uint64_t addr, unsigned size, uint64_t v) {
    uint8_t *p = ptr_of(in, addr, size);
    if (!p) return -1;
    memcpy(p, &v, size);
    return 0;
}

/* Load/store pair, exclusive, and single-register forms. */
int ry_interp_loadstore(RyInterp *in, uint32_t insn, uint64_t pc) {
    /* --- Load register (literal): LDR/LDRSW/PRFM --- */
    if ((insn & 0x3b000000) == 0x18000000) {
        unsigned opc = BITS(insn, 31, 30);
        unsigned rt = BITS(insn, 4, 0);
        int64_t off = SEXT(BITS(insn, 23, 5), 19) << 2;
        uint64_t addr = pc + off;
        if (opc == 0) {          /* LDR Wt */
            uint64_t v; if (do_load(in, addr, 4, 0, &v)) return 0;
            XSET(rt, v & MASK32);
        } else if (opc == 1) {   /* LDR Xt */
            uint64_t v; if (do_load(in, addr, 8, 0, &v)) return 0;
            XSET(rt, v);
        } else if (opc == 2) {   /* LDRSW */
            uint64_t v; if (do_load(in, addr, 4, 1, &v)) return 0;
            XSET(rt, v);
        }
        return 0;
    }

    /* --- Load/store pair: post-index(1) / signed-offset(2) / pre-index(3) / no-alloc --- */
    if ((insn & 0x3a000000) == 0x28000000) {
        unsigned opc = BITS(insn, 31, 30);
        unsigned mode = BITS(insn, 24, 23);
        int isLoad = (int)BIT(insn, 22);
        int64_t off = SEXT(BITS(insn, 21, 15), 7);
        unsigned rt = BITS(insn, 4, 0), rt2 = BITS(insn, 14, 10);
        unsigned rn = BITS(insn, 9, 5);
        unsigned size = 4, sign = 0;
        if (opc == 0) size = 4;
        else if (opc == 1) { size = 8; }
        else if (opc == 2) { size = 8; sign = 0; }   /* SIMD pair: treat as 8 */
        else return 0;
        uint64_t base = X(rn);
        uint64_t addr = (mode == 1) ? base : (base + (uint64_t)off);
        if (isLoad) {
            uint64_t a, b;
            if (do_load(in, addr, size, sign, &a)) return 0;
            if (do_load(in, addr + size, size, sign, &b)) return 0;
            if (opc == 0) { a &= MASK32; b &= MASK32; }
            XSET(rt, a); XSET(rt2, b);
        } else {
            do_store(in, addr, size, X(rt));
            do_store(in, addr + size, size, X(rt2));
        }
        if (mode != 2 && mode != 0) XSET(rn, base + (uint64_t)off);
        return 0;
    }

    /* --- Load/store exclusive + atomics (LDXR/STXR/LDADD/CAS/SWP...) --- */
    if ((insn & 0x3f000000) == 0x08000000) {
        unsigned size_code = BITS(insn, 31, 30);
        unsigned o2 = BIT(insn, 23), l = BIT(insn, 22), o1 = BIT(insn, 21), o0 = BIT(insn, 15);
        unsigned rs = BITS(insn, 20, 16), rt2 = BITS(insn, 14, 10);
        unsigned rn = BITS(insn, 9, 5), rt = BITS(insn, 4, 0);
        unsigned size = 1u << size_code;
        uint64_t addr = X(rn);

        if (o2 == 0 && o1 == 0 && o0 == 0) {
            /* LDXR / STXR */
            if (l) {
                uint64_t v;
                if (do_load(in, addr, size, 0, &v)) return 0;
                if (size == 4) v &= MASK32;
                XSET(rt, v);
                in->excl_addr = addr; in->excl_size = size; in->excl_val = v;
            } else {
                int ok = (in->excl_addr == addr);
                if (ok) {
                    do_store(in, addr, size, X(rt2));
                    in->excl_addr = ~0ull;
                }
                XSET(rs, ok ? 0 : 1);
            }
            return 0;
        }
        if (o2 == 0 && o1 == 0 && o0 == 1) {
            /* LDAR / STLR */
            if (l) {
                uint64_t v;
                if (do_load(in, addr, size, 0, &v)) return 0;
                if (size == 4) v &= MASK32;
                XSET(rt, v);
            } else {
                do_store(in, addr, size, X(rt));
            }
            return 0;
        }
        /* Atomic memory ops (LSE): LDADD/LDCLR/LDEOR/LDSET/LDSMAX/LDSMIN/
           LDUMAX/LDUMIN/LDSWP/CAS. o2=1. */
        if (o2 == 1) {
            uint64_t old;
            if (do_load(in, addr, size, 0, &old)) return 0;
            uint64_t mask = (size == 8) ? MASK64 : ((1ull << (size * 8)) - 1);
            uint64_t src = X(rs) & mask;
            uint64_t cur = old & mask;
            uint64_t nv;
            unsigned op = (unsigned)((o1 << 1) | o0);
            switch (op) {
            case 0: nv = cur + src; break;                       /* LDADD */
            case 1: nv = cur & ~src; break;                      /* LDCLR */
            case 2: nv = cur ^ src; break;                       /* LDEOR */
            case 3: nv = cur | src; break;                       /* LDSET */
            case 4: {                                            /* LDSMAX */
                int64_t a = (int64_t)(size == 8 ? cur : (int32_t)cur);
                int64_t b = (int64_t)(size == 8 ? src : (int32_t)src);
                nv = (uint64_t)(a > b ? a : b);
                break;
            }
            case 5: {                                            /* LDSMIN */
                int64_t a = (int64_t)(size == 8 ? cur : (int32_t)cur);
                int64_t b = (int64_t)(size == 8 ? src : (int32_t)src);
                nv = (uint64_t)(a < b ? a : b);
                break;
            }
            case 6: nv = cur > src ? cur : src; break;           /* LDUMAX */
            case 7: nv = cur < src ? cur : src; break;           /* LDUMIN */
            default: return 0;
            }
            do_store(in, addr, size, nv & mask);
            if (size == 4) old &= MASK32;
            XSET(rt, old);
            return 0;
        }
        /* CAS / CASA / CASL: l=1,o0=0, size_code in {2,3} */
        if (l && o1 == 1 && o0 == 0) {
            uint64_t old;
            if (do_load(in, addr, size, 0, &old)) return 0;
            uint64_t expected = X(rt) & ((size == 8) ? MASK64 : MASK32);
            if ((old & ((size == 8) ? MASK64 : MASK32)) == expected)
                do_store(in, addr, size, X(rt2));
            if (size == 4) old &= MASK32;
            XSET(rs, old);
            return 0;
        }
        if (l && o1 == 1 && o0 == 1) {                            /* SWP */
            uint64_t old;
            if (do_load(in, addr, size, 0, &old)) return 0;
            do_store(in, addr, size, X(rs));
            if (size == 4) old &= MASK32;
            XSET(rt, old);
            return 0;
        }
        return 0;
    }

    /* --- Load/store register: unsigned offset (imm12) --- */
    if ((insn & 0x3b000000) == 0x39000000) {
        unsigned size_code = BITS(insn, 31, 30);
        unsigned opc = BITS(insn, 23, 22);
        unsigned rt = BITS(insn, 4, 0), rn = BITS(insn, 9, 5);
        unsigned size = 1u << size_code;
        uint64_t addr = X(rn) + ((uint64_t)BITS(insn, 21, 10) << size_code);
        int isLoad = (opc != 0);
        int sign = (size_code == 2 && opc == 2) || (size_code == 3 && opc == 2);
        if (isLoad) {
            uint64_t v;
            if (do_load(in, addr, size, sign, &v)) return 0;
            if (size_code == 2 && !sign) v &= MASK32;
            XSET(rt, v);
        } else {
            do_store(in, addr, size, X(rt));
        }
        return 0;
    }

    /* --- Load/store register: unscaled (LDUR/STUR) and pre/post index --- */
    if ((insn & 0x3b200000) == 0x38000000) {
        unsigned size_code = BITS(insn, 31, 30);
        unsigned opc = BITS(insn, 23, 22);
        unsigned rt = BITS(insn, 4, 0), rn = BITS(insn, 9, 5);
        unsigned size = 1u << size_code;
        int64_t off = SEXT(BITS(insn, 20, 12), 9);
        unsigned mode = BITS(insn, 11, 10);   /* 0 unscaled, 1 post, 3 pre */
        uint64_t base = X(rn);
        uint64_t addr = (mode == 1) ? base : (base + (uint64_t)off);
        int isLoad = (opc != 0);
        int sign = (opc == 2) && (size_code == 2 || size_code == 3);
        if (isLoad) {
            uint64_t v;
            if (do_load(in, addr, size, sign, &v)) return 0;
            if (size_code == 2 && !sign) v &= MASK32;
            XSET(rt, v);
        } else {
            do_store(in, addr, size, X(rt));
        }
        if (mode == 1 || mode == 3) XSET(rn, base + (uint64_t)off);
        return 0;
    }

    /* --- Load/store register: register offset --- */
    if ((insn & 0x3b200800) == 0x38200800) {
        unsigned size_code = BITS(insn, 31, 30);
        unsigned opc = BITS(insn, 23, 22);
        unsigned rm = BITS(insn, 20, 16), option = BITS(insn, 15, 13);
        unsigned s = BIT(insn, 12), rn = BITS(insn, 9, 5), rt = BITS(insn, 4, 0);
        unsigned size = 1u << size_code;
        uint64_t index = X(rm);
        /* Option: 010 UXTW, 011 LSL, 110 SXTW, 111 SXTX */
        int64_t off;
        if (option & 2) off = (int64_t)X(rm);
        else off = (int64_t)(uint32_t)X(rm);
        if (s) off <<= size_code;
        uint64_t addr = X(rn) + (uint64_t)off;
        int isLoad = (opc != 0);
        int sign = (opc == 2) && (size_code == 2 || size_code == 3);
        if (isLoad) {
            uint64_t v;
            if (do_load(in, addr, size, sign, &v)) return 0;
            if (size_code == 2 && !sign) v &= MASK32;
            XSET(rt, v);
        } else {
            do_store(in, addr, size, X(rt));
        }
        (void)index;
        return 0;
    }

    return 1;   /* not a load/store */
}
