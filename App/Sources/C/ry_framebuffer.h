#ifndef RY_FRAMEBUFFER_H
#define RY_FRAMEBUFFER_H

#include <stdint.h>
#include <stddef.h>

/* Guest display framebuffer.
 *
 * A host-side RGBA8888 buffer that stands in for the guest's screen memory.
 * It is deliberately NOT carved out of guest RAM: guest RAM size varies (1-3 GiB)
 * and the kernel loader writes segments into it, so a fixed offset would clash.
 *
 * The UI reads this buffer every frame and renders it as a CGImage. Right now a
 * deterministic test pattern is painted here to prove the readback -> render
 * chain works. Once the guest display driver runs, its writes will be routed
 * here through the MMU framebuffer window (ry_fb_window_*).
 */
#define RY_FB_WIDTH   1024u
#define RY_FB_HEIGHT  768u
#define RY_FB_BPP     4u                              /* RGBA8888 */
#define RY_FB_SIZE    (RY_FB_WIDTH * RY_FB_HEIGHT * RY_FB_BPP)

#ifdef __cplusplus
extern "C" {
#endif

/* Allocate the buffer and paint the initial test pattern. Safe to call twice. */
int  ry_fb_init(void);
void ry_fb_shutdown(void);

/* Direct pointer to the RGBA8888 pixels (RY_FB_SIZE bytes). NULL before init. */
const uint8_t *ry_fb_pixels(void);

/* Paint helpers. */
void ry_fb_draw_test_pattern(void);   /* recognisable startup image */
void ry_fb_clear(void);               /* solid black */
int  ry_fb_is_test_pattern(void);     /* 1 while no guest/driver wrote pixels */

/* MMU framebuffer window: guest physical range reserved for the display.
 * Reads/writes in [RY_FB_WINDOW_BASE, +RY_FB_SIZE) map into the RGBA buffer. */
#define RY_FB_WINDOW_BASE  0x300000000ull             /* 12 GiB, clear of RAM/UART/GIC */
#define RY_FB_WINDOW_END   (RY_FB_WINDOW_BASE + RY_FB_SIZE)

int  ry_fb_window_read (uint64_t pa, unsigned size, uint64_t *out);
int  ry_fb_window_write(uint64_t pa, unsigned size, uint64_t v);

#ifdef __cplusplus
}
#endif
#endif
