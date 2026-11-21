/*
 * Guest framebuffer: a host RGBA8888 buffer the UI renders as the guest screen.
 *
 * No guest kernel exists yet, so this module paints a deterministic test image
 * (deep graphite field, cool-blue accent, a simple "booting" glyph) to prove
 * the pixel-readback path. When a display driver eventually writes to the
 * framebuffer MMU window, those bytes land in the same buffer and the UI picks
 * them up with no change.
 */
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include "ry_framebuffer.h"

static uint8_t *g_fb;
static int g_is_test;

static void put(int x, int y, uint8_t r, uint8_t g, uint8_t b) {
    if (x < 0 || y < 0 || x >= (int)RY_FB_WIDTH || y >= (int)RY_FB_HEIGHT) return;
    uint8_t *p = g_fb + ((y * RY_FB_WIDTH) + x) * 4;
    p[0] = r; p[1] = g; p[2] = b; p[3] = 255;
}

static void fill_rect(int x0, int y0, int x1, int y1,
                      uint8_t r, uint8_t g, uint8_t b) {
    for (int y = y0; y < y1; y++)
        for (int x = x0; x < x1; x++)
            put(x, y, r, g, b);
}

int ry_fb_init(void) {
    if (!g_fb) g_fb = (uint8_t *)calloc(1, RY_FB_SIZE);
    if (!g_fb) return -1;
    ry_fb_draw_test_pattern();
    return 0;
}

void ry_fb_shutdown(void) {
    free(g_fb);
    g_fb = NULL;
    g_is_test = 0;
}

const uint8_t *ry_fb_pixels(void) { return g_fb; }

void ry_fb_draw_test_pattern(void) {
    if (!g_fb) return;
    /* Deep graphite vertical field, lighter at top — matches the app theme. */
    for (int y = 0; y < (int)RY_FB_HEIGHT; y++) {
        int t = (y * 255) / RY_FB_HEIGHT;
        uint8_t g = (uint8_t)(44 - t * 12 / 255);
        uint8_t r = (uint8_t)(26 - t * 8 / 255);
        uint8_t b = (uint8_t)(33 - t * 10 / 255);
        for (int x = 0; x < (int)RY_FB_WIDTH; x++) put(x, y, r, g, b);
    }
    /* Thin cool-blue horizon line. */
    fill_rect(0, 300, RY_FB_WIDTH, 302, 110, 157, 214);

    /* Centered rounded-square "nested" glyph — echoes the app icon. */
    int cx = RY_FB_WIDTH / 2, cy = RY_FB_HEIGHT / 2;
    int r = 150, t = 10;
    /* outer frame */
    for (int y = cy - r; y <= cy + r; y++) {
        for (int x = cx - r; x <= cx + r; x++) {
            int d = (x > cx-r+t && x < cx+r-t && y > cy-r+t && y < cy+r-t);
            if (!d) put(x, y, 176, 190, 210);
        }
    }
    /* inner solid block */
    int ir = 62;
    fill_rect(cx - ir, cy - ir, cx + ir, cy + ir, 150, 163, 182);
    /* top edge highlight of inner block */
    fill_rect(cx - ir, cy - ir, cx + ir, cy - ir + 6, 205, 218, 235);

    g_is_test = 1;
}

void ry_fb_clear(void) {
    if (!g_fb) return;
    memset(g_fb, 0, RY_FB_SIZE);
    g_is_test = 0;
}

int ry_fb_is_test_pattern(void) { return g_is_test; }

/* A guest driver writing anywhere in the window clears the "still test" flag;
 * the store itself lands in the RGBA buffer at the corresponding offset. */
static uint8_t *fb_at(uint64_t pa, unsigned size) {
    if (pa < RY_FB_WINDOW_BASE || pa + size > RY_FB_WINDOW_END) return NULL;
    if (!g_fb) return NULL;
    return g_fb + (pa - RY_FB_WINDOW_BASE);
}

int ry_fb_window_read(uint64_t pa, unsigned size, uint64_t *out) {
    uint8_t *p = fb_at(pa, size);
    if (!p) return 0;
    uint64_t v = 0;
    memcpy(&v, p, size > 8 ? 8 : size);
    if (out) *out = v;
    return 1;
}

int ry_fb_window_write(uint64_t pa, unsigned size, uint64_t v) {
    uint8_t *p = fb_at(pa, size);
    if (!p) return 0;
    memcpy(p, &v, size > 8 ? 8 : size);
    g_is_test = 0;
    return 1;
}
