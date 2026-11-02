/* shot.c -- screenshots as 16-colour BMP files (Windows bitmap, 4 bits per pixel,
 * uncompressed, bottom-up rows): every PC viewer opens them, and the machines' 16
 * colours are stored exactly. LTari's 256 colours: 8 bits per pixel. The file goes
 * through fat.c's file writer (fw_file). */
#include "shot.h"
#include "util.h"

static int      s_w, s_err, s_bpp;
static uint32_t s_rowbytes;

static void put(uint8_t b)
{
    int r;
    if (s_err) return;
    r = fw_putc(&fw_file, b);
    if (r != FAT_OK) s_err = r;
}
static void put16(uint32_t v) { put((uint8_t)v); put((uint8_t)(v >> 8)); }
static void put32(uint32_t v) { put16(v & 0xFFFFu); put16(v >> 16); }

int shot_name(uint32_t dir, char name11[11])
{
    int k, r;
    for (k = 1; k < 10000; k++) {
        u_memcpy(name11, "SCRN0000BMP", 11);
        name11[4] = (char)('0' + k / 1000);
        name11[5] = (char)('0' + k / 100 % 10);
        name11[6] = (char)('0' + k / 10 % 10);
        name11[7] = (char)('0' + k % 10);
        r = fat_exists(dir, name11);
        if (r == 0) return 0;
        if (r < 0) return FAT_EIO;
    }
    return FAT_EFULL;
}

static int begin(uint32_t dir, const char name11[11], int w, int h, const uint8_t (*pal)[3], int bpp)
{
    uint32_t data, n = bpp == 8 ? 256u : 16u;
    int i, r = fw_create(&fw_file, dir, name11);
    if (r != FAT_OK) return r;
    s_err      = 0;
    s_w        = w;
    s_bpp      = bpp;
    s_rowbytes = (bpp == 8 ? (uint32_t)w : (uint32_t)(w + 1) / 2) + 3u & ~3u;   /* rows padded to 4 bytes */
    data       = s_rowbytes * (uint32_t)h;
    put('B'); put('M'); put32(14 + 40 + 4 * n + data); put32(0); put32(14 + 40 + 4 * n);   /* file header */
    put32(40); put32((uint32_t)w); put32((uint32_t)h); put16(1); put16((uint32_t)bpp);    /* BITMAPINFOHEADER */
    put32(0); put32(data); put32(2835); put32(2835); put32(n); put32(n);                /* BI_RGB, 72 dpi */
    for (i = 0; i < (int)n; i++) { put(pal[i][2]); put(pal[i][1]); put(pal[i][0]); put(0); }   /* B G R 0 */
    return s_err;
}

int shot_begin(uint32_t dir, const char name11[11], int w, int h, const uint8_t pal[16][3])
{
    return begin(dir, name11, w, h, pal, 4);
}

int shot_begin8(uint32_t dir, const char name11[11], int w, int h, const uint8_t pal[256][3])
{
    return begin(dir, name11, w, h, pal, 8);
}

int shot_row(const uint8_t *px)
{
    uint32_t i;
    int x;
    if (s_bpp == 8) {
        for (x = 0; x < s_w; x++) put(px[x]);
        i = (uint32_t)s_w;
    } else {
        for (x = 0; x < s_w; x += 2)                    /* left pixel in the high nibble */
            put((uint8_t)((px[x] & 15) << 4 | (x + 1 < s_w ? px[x + 1] & 15 : 0)));
        i = ((uint32_t)s_w + 1) / 2;
    }
    for (; i < s_rowbytes; i++) put(0);
    return s_err;
}

int shot_end(void)
{
    if (s_err) { fw_discard(&fw_file); return s_err; }
    return fw_close(&fw_file);
}

/* back to the state after a start: the next machine starts the loader again without an ESP32
 * restart (esp_hw.cpp; the Bluetooth connection stays) */
void shot_reset(void)
{
    u_memset(&s_w, 0, sizeof s_w);
    u_memset(&s_err, 0, sizeof s_err);
    u_memset(&s_bpp, 0, sizeof s_bpp);
    u_memset(&s_rowbytes, 0, sizeof s_rowbytes);
}
