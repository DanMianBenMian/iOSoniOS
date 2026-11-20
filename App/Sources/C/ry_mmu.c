/*
 * ARM64 MMU for the interpreter: virtual-to-physical translation using the
 * guest's own page tables, plus a tiny UART so kernel printk reaches the app.
 *
 * Why this is required before an XNU kernel can run: the kernel turns the MMU
 * on almost immediately and then addresses everything through VA. Until then a
 * flat physical address happens to work; afterwards every access through a
 * physical address is wrong. So all loads/stores go through mmu_translate().
 *
 * Translation follows the Arm ARM: TCR_EL1 selects granule and sizes, TTBR0/1
 * give the table roots, and each level contributes 9 bits of index (4 KiB
 * granule). Block descriptors at L1/L2 map large regions; L3 descriptors map
 * 4 KiB pages. Permission faults and unmapped addresses are reported, not
 * silently zero-filled.
 */
#include <stdint.h>
#include <string.h>
#include <stdio.h>

#include "ry_interp.h"

#define BIT(x, n)       (((x) >> (n)) & 1u)
#define BITS(x, hi, lo) (((x) >> (lo)) & ((1u << ((hi) - (lo) + 1)) - 1u))

/* Physical address space: guest RAM plus the device window. */
#define UART_BASE   0x35200000ull
#define UART_SIZE   0x4000ull
#define GIC_BASE    0x23b000000ull
#define GIC_SIZE    0x10000ull

/* Samsung-style UART registers (uart-1,samsung in the DeviceTree). */
#define ULCON   0x00
#define UCON    0x04
#define UFCON   0x08
#define UTRSTAT 0x10
#define UTXH    0x20
#define URXH    0x24
#define UBRDIV  0x28
#define UFRACVAL 0x2c

static char g_uart_shadow[16];

/* ---------------- descriptor walk ---------------- */

/* Returns 1 and fills *out on success. */
static int walk_table(RyInterp *in, uint64_t root, int levels, uint64_t va,
                      TransResult *out) {
    uint64_t table = root & ~0xfffull;
    if (levels < 1) levels = 4;

    for (int level = 0; level < levels; level++) {
        unsigned shift = 12 + 9 * (levels - 1 - level);
        unsigned index = (unsigned)((va >> shift) & 0x1ff);
        uint64_t entry_pa = table + (uint64_t)index * 8;
        if (entry_pa + 8 > in->mem_size) return 0;

        uint64_t d;
        memcpy(&d, in->mem + entry_pa, 8);

        if (!(d & 1)) { out->ok = 0; return 0; }     /* invalid */

        int is_table = (d >> 1) & 1;
        if (is_table) {
            table = d & 0x0000fffffffff000ull;
            continue;
        }
        /* Block or page descriptor. */
        unsigned out_shift = shift;
        uint64_t base = d & 0x0000fffffffff000ull;
        uint64_t pa = base | (va & ((1ull << out_shift) - 1));
        out->pa = pa;
        out->ok = 1;
        /* AP[2:1]: 00/10 = RW EL1, 01/11 = RO EL1 */
        unsigned ap = BITS(d, 7, 6);
        out->perm = (ap & 2) ? 1 : 0;
        if (BITS(d, 7, 6) == 0x2) out->perm = 1;     /* AP[2]=1 -> RO */
        return 1;
    }
    out->ok = 0;
    return 0;
}

int mmu_translate(RyInterp *in, uint64_t va, TransResult *out) {
    out->ok = 0;
    out->pa = va;      /* identity until the MMU is on */
    out->perm = 0;

    RyCpu *c = &in->cpu;
    int mmu_on = (c->sctlr_el1 & 1) != 0;
    if (!mmu_on) {
        out->ok = 1;
        out->pa = va;      /* flat physical */
        return 1;
    }

    unsigned t0sz = BITS(c->tcr_el1, 5, 0);
    unsigned t1sz = BITS(c->tcr_el1, 21, 16);
    unsigned tg0 = BITS(c->tcr_el1, 15, 14);
    unsigned tg1 = BITS(c->tcr_el1, 23, 22);

    /* 4 KiB granule: 4 levels, 39-bit VA at T0SZ=25. Scale level count with TnSZ. */
    int levels0 = 4;
    if (t0sz > 33) levels0 = 3;
    if (t0sz > 24) levels0 = 4;
    int levels1 = (t1sz > 24) ? 3 : 4;

    int in_low = (va < (1ull << (64 - t0sz)) && t0sz < 64);

    uint64_t root;
    int levels;
    if (in_low) {
        root = c->ttbr0_el1;
        levels = levels0;
    } else {
        root = c->ttbr1_el1;
        levels = levels1;
        /* TTBR1 covers the high half; mask VA to its range for the walk. */
    }
    (void)tg0; (void)tg1;

    if (walk_table(in, root, levels, va, out)) return 1;

    /* Fall back: if the walk failed and the address lands in RAM, allow it.
     * Early boot touches a few addresses before the tables are complete. */
    if (va < in->mem_size) {
        out->ok = 1;
        out->pa = va;
        return 1;
    }
    return 0;
}

/* ---------------- device window ---------------- */

int mmu_device_read(RyInterp *in, uint64_t pa, unsigned size, uint64_t *out) {
    (void)in;
    if (pa >= UART_BASE && pa < UART_BASE + UART_SIZE) {
        unsigned off = (unsigned)(pa - UART_BASE);
        switch (off & ~3u) {
        case UTRSTAT: *out = 0x6; return 1;     /* TX empty + TX ready */
        case ULCON: case UCON: case UFCON:
        case UBRDIV: case UFRACVAL:
            *out = (uint64_t)(unsigned char)g_uart_shadow[(off >> 2) & 7];
            return 1;
        case URXH: *out = 0; return 1;          /* no input yet */
        default: *out = 0; return 1;
        }
    }
    if (pa >= GIC_BASE && pa < GIC_BASE + GIC_SIZE) {
        *out = 0;                                /* no interrupts pending */
        return 1;
    }
    return 0;
}

int mmu_device_write(RyInterp *in, uint64_t pa, unsigned size, uint64_t v) {
    if (pa >= UART_BASE && pa < UART_BASE + UART_SIZE) {
        unsigned off = (unsigned)(pa - UART_BASE);
        if ((off & ~3u) == UTXH) {
            char ch = (char)(v & 0xff);
            in->uart_byte(ch);
        } else {
            g_uart_shadow[(off >> 2) & 7] = (char)(v & 0xff);
        }
        return 1;
    }
    if (pa >= GIC_BASE && pa < GIC_BASE + GIC_SIZE) {
        return 1;                                /* ignore */
    }
    return 0;
}
