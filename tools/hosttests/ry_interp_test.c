/* Host-side test for ry_interp.c. Not shipped in the app.
 * Build: clang -I. ry_interp_test.c ry_interp.c -o interp_test
 */
#include <stdio.h>
#include <string.h>
#include "ry_interp.h"

static uint8_t mem[65536];
static RyInterp interp;

static void put32(uint64_t addr, uint32_t v) { memcpy(mem + addr, &v, 4); }

static uint64_t get32(uint64_t addr) { uint32_t v; memcpy(&v, mem + addr, 4); return v; }

static int failures;

static void expect(const char *name, uint64_t got, uint64_t want) {
    if (got == want) {
        printf("  ok   %-28s = 0x%llx\n", name, (unsigned long long)got);
    } else {
        printf("  FAIL %-28s got 0x%llx want 0x%llx\n",
               name, (unsigned long long)got, (unsigned long long)want);
        failures++;
    }
}

int main(void) {
    memset(mem, 0, sizeof(mem));

    /* --- test 1: mov w0, #42 ; ret --- */
    put32(0x100, 0x52800540u);   /* mov w0, #42 */
    put32(0x104, 0xd65f03c0u);   /* ret  (x30 = 0) */
    memset(&interp, 0, sizeof(interp));
    interp.mem = mem;
    interp.mem_size = sizeof(mem);
    ry_interp_reset(&interp, 0x100);
    int rc = ry_interp_run(&interp, 0, 1000);
    printf("test1 mov+ret rc=%d\n", rc);
    expect("w0", interp.cpu.x[0], 42);
    expect("insns", interp.insns, 2);

    /* --- test 2: arithmetic + loop: x1=0; for x0=10..1 x1+=x0 --- */
    uint64_t p = 0x200;
    put32(p, 0xd2800001u); p += 4;   /* mov x1, #0        */
    put32(p, 0xd2800140u); p += 4;   /* mov x0, #10       */
    put32(p, 0x8b000021u); p += 4;   /* add x1, x1, x0    */
    put32(p, 0xd1000400u); p += 4;   /* sub x0, x0, #1    */
    put32(p, 0xb5000040u); p += 4;   /* cbnz x0, +8       */
    put32(p, 0xd65f03c0u); p += 4;   /* ret               */

    memset(&interp, 0, sizeof(interp));
    interp.mem = mem;
    interp.mem_size = sizeof(mem);
    ry_interp_reset(&interp, 0x200);
    rc = ry_interp_run(&interp, 0, 10000);
    printf("test2 loop rc=%d\n", rc);
    expect("sum 10..1", interp.cpu.x[1], 55);
    expect("x0 final", interp.cpu.x[0], 0);

    /* --- test 3: memory: str x2,[x3]; ldr x4,[x3] --- */
    p = 0x300;
    put32(p, 0xd2802a42u); p += 4;   /* mov x2, #0x152    */
    put32(p, 0xd2802003u); p += 4;   /* mov x3, #0x100    */
    put32(p, 0xf9000062u); p += 4;   /* str x2, [x3]      */
    put32(p, 0xf9400064u); p += 4;   /* ldr x4, [x3]      */
    put32(p, 0xd65f03c0u); p += 4;
    memset(&interp, 0, sizeof(interp));
    interp.mem = mem;
    interp.mem_size = sizeof(mem);
    ry_interp_reset(&interp, 0x300);
    rc = ry_interp_run(&interp, 0, 1000);
    printf("test3 mem rc=%d\n", rc);
    expect("x4 loaded", interp.cpu.x[4], 0x152);
    expect("mem[0x100]", get32(0x100 + 0), 0x152);

    /* --- test 4: cmp + b.eq --- */
    p = 0x400;
    put32(p, 0xd28000a5u); p += 4;   /* mov x5, #5      */
    put32(p, 0xf10008bfu); p += 4;   /* cmp x5, #2      */
    put32(p, 0x54000040u); p += 4;   /* b.eq +8         */
    put32(p, 0xd2800066u); p += 4;   /* mov x6, #3  (not taken) */
    put32(p, 0xd65f03c0u); p += 4;
    memset(&interp, 0, sizeof(interp));
    interp.mem = mem;
    interp.mem_size = sizeof(mem);
    ry_interp_reset(&interp, 0x400);
    rc = ry_interp_run(&interp, 0, 1000);
    printf("test4 cmp/b.eq rc=%d\n", rc);
    expect("x6 not set", interp.cpu.x[6], 3);  /* falls through, sets 3 */

    printf(failures ? "\nFAILURES: %d\n" : "\nall ok\n", failures);
    return failures ? 1 : 0;
}
