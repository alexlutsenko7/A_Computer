/* snap.c -- .z80 snapshots: saving the running Spectrum (F2), loading a file (browser)
 *
 * The Spectrum CPU is stopped between two instructions (rtl/zx_bus.v, "Snapshots"),
 * and its registers, the 128K of RAM, the AY and the ports are read or written
 * through the snapshot commands. The CPU stays stopped while the name is typed.
 *
 * Saving writes version 3 (128K, hardware mode 4): 30-byte header, 54 more bytes,
 * then the 8 RAM pages as blocks 3..10, compressed (ED ED n b = n times b; runs of
 * 5 or more, runs of ED from 2; the byte after a single ED is never part of a
 * run). A page that would not get smaller is stored as 16384 plain bytes (length
 * FFFF). Not saved: the position in the video frame (the T-state counter is 0).
 *
 * Loading takes versions 1 (48K), 2 and 3, 48K and 128K. 48K snapshots run in
 * 48K mode: 7FFD = 30 (48 BASIC ROM, RAM page 0 at C000, paging locked). The
 * file is checked completely before anything is changed.
 */
#ifdef HOST_TEST
#include "../test/host_hw.h"
#else
#include "hw.h"
#endif
#include "fat.h"
#include "snap.h"
#include "shot.h"
#include "util.h"

/* snapshot commands (rtl/zx_bus.v) */
#define C_MRD    1
#define C_MWR    2
#define C_REG    3
#define C_DIR    4
#define C_LOAD   5
#define C_AYRD   6
#define C_AYWR   7
#define C_AYSEL  8
#define C_PORT   9
#define C_STATE  10

#define PAGE     16384u
#define HDR_LEN  86                     /* 30 + 2 + 54 */
#define ST_HALT  (1u << 24)

#ifndef HOST_TEST
static void     snap_ctl(uint32_t v) { SNAPCTL = v; }
static uint32_t snap_status(void)    { return SNAPCTL; }
static uint32_t timer_now(void)      { return TIMER; }
static __attribute__((noinline)) uint32_t snap_cmd(uint32_t c, uint32_t a, uint32_t d)
{
    SNAPDAT = d;
    SNAPCMD = (c << 28) | a;
    while (SNAPCTL & SNAP_BUSY) ;
    return SNAPDAT;
}
#endif

static uint8_t  hdr[HDR_LEN + 1];       /* captured state as a .z80 header; loading: the file's header */
#define wf fw_file                       /* shared with save.c (fat.h) */
static int      wr_err;
static uint32_t c_addr;                 /* one-byte SDRAM read cache */
static uint8_t  c_val;

static void     put16(uint8_t *p, uint32_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static uint32_t get16(const uint8_t *p)       { return p[0] | (uint32_t)p[1] << 8; }

/* registers: header offset, cpu_t80 word * 32 + bit, bytes (R, IM, IFF, PC: in the code) */
static const uint8_t rmap[][3] = {
    {  0,  0, 1 }, {  1,  8, 1 }, { 21, 16, 1 }, { 22, 24, 1 },     /* A F A' F' */
    { 10, 32, 1 }, {  8, 48, 2 },                                   /* I SP */
    {  2, 80, 2 }, { 13, 96, 2 }, {  4, 112, 2 },                   /* BC DE HL */
    { 25, 128, 2 }, { 15, 144, 2 }, { 17, 160, 2 }, { 19, 176, 2 }, /* IX BC' DE' HL' */
    { 23, 192, 2 },                                                 /* IY */
};
#define NRMAP (sizeof rmap / sizeof rmap[0])

int snap_freeze(void)
{
    uint32_t t0 = timer_now();
    snap_ctl(1);
    while (!(snap_status() & SNAP_FROZEN))
        if (timer_now() - t0 > 200 * CLK_PER_MS) { snap_ctl(0); return SNAP_ERUN; }
    return 0;
}

/*----------------------------------------------------------------------------
 * saving
 *--------------------------------------------------------------------------*/
void snap_capture(void)
{
    uint32_t w[7], st, pc, r;
    int i;

    for (i = 0; i < 7; i++) w[i] = snap_cmd(C_REG, (uint32_t)i, 0);
    st = snap_cmd(C_STATE, 0, 0);
    pc = w[2] & 0xFFFFu;
    if (st & ST_HALT) pc = (pc - 1) & 0xFFFFu;          /* in HALT: PC is past it, run it again */
    r = (w[1] >> 8) & 0xFFu;

    u_memset(hdr, 0, sizeof hdr);
    for (i = 0; i < (int)NRMAP; i++) {
        uint32_t v = w[rmap[i][1] >> 5] >> (rmap[i][1] & 31);
        hdr[rmap[i][0]] = (uint8_t)v;
        if (rmap[i][2] == 2) hdr[rmap[i][0] + 1] = (uint8_t)(v >> 8);
    }
    hdr[11] = (uint8_t)(r & 0x7F);
    hdr[12] = (uint8_t)((r >> 7) | ((st >> 8 & 7) << 1));   /* R bit 7, border */
    hdr[27] = (uint8_t)(w[6] >> 18 & 1);                /* IFF1, IFF2, IM */
    hdr[28] = (uint8_t)(w[6] >> 19 & 1);
    hdr[29] = (uint8_t)(w[6] >> 16 & 3);
    put16(hdr + 30, HDR_LEN - 32);                      /* version 3 */
    put16(hdr + 32, pc);
    hdr[34] = 4;                                        /* 128K */
    hdr[35] = (uint8_t)st;                              /* 7FFD */
    hdr[37] = 3;                                        /* R and LDIR emulation (as usual) */
    hdr[38] = (uint8_t)(st >> 16);                      /* AY register select */
    for (i = 0; i < 16; i++) hdr[39 + i] = (uint8_t)snap_cmd(C_AYRD, (uint32_t)i, 0);
    hdr[61] = hdr[62] = 0xFF;                           /* 0000-3FFF is ROM */

    for (i = 8; i <= 10; i++) snap_cmd(C_AYWR, (uint32_t)i, 0);     /* silence while stopped */
    snap_cmd(C_AYSEL, 0, hdr[38]);
}

void snap_resume(void)
{
    int i;
    for (i = 8; i <= 10; i++) snap_cmd(C_AYWR, (uint32_t)i, hdr[39 + i]);
    snap_cmd(C_AYSEL, 0, hdr[38]);
    snap_ctl(0);
}

static uint8_t rd(uint32_t a)
{
    if (a != c_addr) { c_val = (uint8_t)snap_cmd(C_MRD, a, 0); c_addr = a; }
    return c_val;
}

static void put(uint8_t b)
{
    int r;
    if (wr_err) return;
    r = fw_putc(&wf, b);
    if (r != FAT_OK) wr_err = r;
}

/* compressed length of the page at base; written too if emit */
static uint32_t pack(uint32_t base, int emit)
{
    uint32_t i = 0, n = 0, run, k;
    uint8_t  b;
    while (i < PAGE) {
        b = rd(base + i);
        for (run = 1; i + run < PAGE && run < 255 && rd(base + i + run) == b; run++) ;
        if (run >= 5 || (b == 0xED && run >= 2)) {
            if (emit) { put(0xED); put(0xED); put((uint8_t)run); put(b); }
            n += 4;
            i += run;
        } else if (b == 0xED) {                         /* single ED: the next byte stays plain */
            if (emit) put(b);
            n++;
            if (++i < PAGE) { if (emit) put(rd(base + i)); n++; i++; }
        } else {
            for (k = 0; k < run; k++) if (emit) put(b);
            n += run;
            i += run;
        }
    }
    return n;
}

int snap_save(uint32_t dir, const char name11[11])
{
    uint32_t pg, n, i;
    int r = fw_create(&wf, dir, name11);
    if (r != FAT_OK) return r;
    wr_err = 0;
    c_addr = 0xFFFFFFFFu;
    for (i = 0; i < HDR_LEN; i++) put(hdr[i]);
    for (pg = 0; pg < 8 && !wr_err; pg++) {
        n = pack(pg * PAGE, 0);
        if (n >= PAGE) {                                /* stored plain */
            put(0xFF); put(0xFF); put((uint8_t)(pg + 3));
            for (i = 0; i < PAGE; i++) put(rd(pg * PAGE + i));
        } else {
            put((uint8_t)n); put((uint8_t)(n >> 8)); put((uint8_t)(pg + 3));
            pack(pg * PAGE, 1);
        }
    }
    if (wr_err) { fw_discard(&wf); return wr_err; }
    return fw_close(&wf);
}

/*----------------------------------------------------------------------------
 * loading
 *--------------------------------------------------------------------------*/
/* SDRAM address of a memory block (page number in the file), or -1 to skip it */
static int32_t block_addr(uint32_t pg, int is128)
{
    if (is128) return (pg >= 3 && pg <= 10) ? (int32_t)((pg - 3) * PAGE) : -1;
    if (pg == 8) return 5 * PAGE;                       /* 4000-7FFF */
    if (pg == 4) return 2 * PAGE;                       /* 8000-BFFF */
    if (pg == 5) return 0;                              /* C000-FFFF: page 0 */
    return -1;
}

/* version 1: one 48K stream for 4000-FFFF */
static uint32_t v1_addr(uint32_t o)
{
    static const uint8_t pages[3] = { 5, 2, 0 };
    return pages[o / PAGE] * PAGE + o % PAGE;
}

static void wr(int v1, uint32_t base, uint32_t o, uint32_t v)
{
    snap_cmd(C_MWR, v1 ? v1_addr(o) : base + o, v);
}

/* n bytes into memory from at most avail bytes of the file; 0 = ok */
static __attribute__((noinline)) int unpack(FFILE *f, uint32_t avail, uint32_t n, int v1, uint32_t base, int packed)
{
    uint32_t o = 0, used = 0;
    int c, c2, cnt, val;
    while (o < n) {
        if (used++ >= avail || (c = ff_getc(f)) < 0) return -1;
        if (!packed || c != 0xED) { wr(v1, base, o++, (uint32_t)c); continue; }
        if (used >= avail) { wr(v1, base, o++, 0xED); continue; }
        used++;
        if ((c2 = ff_getc(f)) < 0) return -1;
        if (c2 != 0xED) {                               /* single ED and a plain byte */
            wr(v1, base, o++, 0xED);
            if (o < n) wr(v1, base, o++, (uint32_t)c2);
            continue;
        }
        used += 2;
        if (used > avail || (cnt = ff_getc(f)) < 0 || (val = ff_getc(f)) < 0) return -1;
        while (cnt-- > 0 && o < n) wr(v1, base, o++, (uint32_t)val);
    }
    return 0;
}

static int rd_bytes(FFILE *f, uint8_t *d, uint32_t n)
{
    int c;
    while (n--) {
        if ((c = ff_getc(f)) < 0) return -1;
        *d++ = (uint8_t)c;
    }
    return 0;
}

int snap_load(FFILE *f)
{
    uint8_t  b[3];
    uint32_t size = f->size, ext = 0, pc, pos, len, need, mask = 0, w[7], im, i;
    int      v1, is128, r, bad = 0;

    u_memset(hdr, 0, sizeof hdr);
    ff_seek(f, 0);
    if (size < 31 || rd_bytes(f, hdr, 30)) return SNAP_EBAD;
    if (hdr[12] == 0xFF) hdr[12] = 1;
    pc = get16(hdr + 6);
    v1 = pc != 0;
    is128 = 0;
    if (!v1) {                                          /* versions 2 and 3 */
        if (rd_bytes(f, b, 2)) return SNAP_EBAD;
        ext = get16(b);
        if (ext != 23 && ext != 54 && ext != 55) return SNAP_EBAD;
        if (rd_bytes(f, hdr + 32, ext > HDR_LEN - 32 ? HDR_LEN - 32 : ext)) return SNAP_EBAD;
        pc = get16(hdr + 32);
        if (ext == 23) is128 = hdr[34] >= 3;
        else           is128 = hdr[34] >= 4 && hdr[34] != 14 && hdr[34] != 15 && hdr[34] != 128;
        for (pos = 32 + ext; pos < size; pos += 3 + len) {     /* every block inside the file */
            ff_seek(f, pos);
            if (pos + 3 > size || rd_bytes(f, b, 3)) return SNAP_EBAD;
            len = get16(b) == 0xFFFF ? PAGE : get16(b);
            if (len == 0 || pos + 3 + len > size) return SNAP_EBAD;
            if (block_addr(b[2], is128) >= 0) mask |= 1u << b[2];
        }
        need = is128 ? 0x7F8u : (1u << 4) | (1u << 5) | (1u << 8);
        if ((mask & need) != need) return SNAP_EBAD;
    }

    r = snap_freeze();
    if (r) return r;

    if (v1) {
        ff_seek(f, 30);
        bad = unpack(f, size - 30, 3 * PAGE, 1, 0, hdr[12] & 0x20);
    } else
        for (pos = 32 + ext; pos < size && !bad; pos += 3 + len) {
            ff_seek(f, pos);
            if (rd_bytes(f, b, 3)) { bad = 1; break; }
            len = get16(b) == 0xFFFF ? PAGE : get16(b);
            if (block_addr(b[2], is128) >= 0)
                bad = unpack(f, len, PAGE, 0, (uint32_t)block_addr(b[2], is128), get16(b) != 0xFFFF);
        }

    /* AY (48K: silent unless the file says it has one), ports */
    for (i = 0; i < 16; i++)
        snap_cmd(C_AYWR, i, (is128 || (!v1 && (hdr[37] & 4))) ? hdr[39 + i] : 0);
    snap_cmd(C_AYSEL, 0, (is128 || (!v1 && (hdr[37] & 4))) ? hdr[38] : 0);
    snap_cmd(C_PORT, 0, (is128 ? hdr[35] : 0x30u) | (uint32_t)(hdr[12] >> 1 & 7) << 8);

    /* registers (cpu_t80 layout) */
    im = hdr[29] & 3;
    if (im == 3) im = 2;
    u_memset(w, 0, sizeof w);
    for (i = 0; i < NRMAP; i++)
        w[rmap[i][1] >> 5] |= (rmap[i][2] == 2 ? get16(hdr + rmap[i][0]) : hdr[rmap[i][0]]) << (rmap[i][1] & 31);
    w[1] |= (uint32_t)((hdr[11] & 0x7F) | (hdr[12] & 1) << 7) << 8;
    w[2] |= pc;
    w[6] |= im << 16 | (uint32_t)(hdr[27] != 0) << 18 | (uint32_t)(hdr[28] != 0) << 19;
    for (i = 0; i < 7; i++) snap_cmd(C_DIR, i, w[i]);
    snap_cmd(C_LOAD, 0, 0);
    snap_ctl(0);
    return bad ? SNAP_EBAD : 0;
}

/*----------------------------------------------------------------------------
 * screenshot (Print Screen): the screen shown (page 5 or 7) with the border as a
 * 320 x 240 BMP; flashing characters as their "off" phase
 *--------------------------------------------------------------------------*/
static uint8_t scr[6912];

int snap_screenshot(uint32_t dir, const char name11[11])
{
    static const uint8_t pal[16][3] = {                 /* as LSpectrum's VGA: normal E, bright F */
        {0x00,0x00,0x00}, {0x00,0x00,0xEE}, {0xEE,0x00,0x00}, {0xEE,0x00,0xEE},
        {0x00,0xEE,0x00}, {0x00,0xEE,0xEE}, {0xEE,0xEE,0x00}, {0xEE,0xEE,0xEE},
        {0x00,0x00,0x00}, {0x00,0x00,0xFF}, {0xFF,0x00,0x00}, {0xFF,0x00,0xFF},
        {0x00,0xFF,0x00}, {0x00,0xFF,0xFF}, {0xFF,0xFF,0x00}, {0xFF,0xFF,0xFF} };
    uint8_t  row[320];
    uint32_t st, base, i;
    int      y, x, r, border;

    if (snap_freeze() != 0) return SNAP_ERUN;
    st     = snap_cmd(C_STATE, 0, 0);
    base   = ((st & 8u) ? 7u : 5u) * PAGE;              /* 7FFD bit 3: screen in page 7 */
    border = (int)(st >> 8 & 7u);
    for (i = 0; i < sizeof scr; i++) scr[i] = (uint8_t)snap_cmd(C_MRD, base + i, 0);
    snap_ctl(0);                                        /* the Spectrum runs on */

    r = shot_begin(dir, name11, 320, 240, pal);
    for (y = 239; y >= 0 && r == FAT_OK; y--) {
        int sy = y - 24;
        for (x = 0; x < 320; x++) {
            int sx = x - 32;
            if (sy < 0 || sy >= 192 || sx < 0 || sx >= 256) { row[x] = (uint8_t)border; continue; }
            {
                uint8_t bits = scr[((sy & 0xC0) << 5) | ((sy & 7) << 8) | ((sy & 0x38) << 2) | (sx >> 3)];
                uint8_t attr = scr[6144 + (sy >> 3) * 32 + (sx >> 3)];
                int     ink  = (bits >> (7 - (sx & 7))) & 1;
                row[x] = (uint8_t)(((attr & 0x40) ? 8 : 0) | (ink ? (attr & 7) : ((attr >> 3) & 7)));
            }
        }
        r = shot_row(row);
    }
    if (r != FAT_OK) { shot_end(); return r; }
    return shot_end();
}

/* back to the state after a start: the next machine starts the loader again without an ESP32
 * restart (esp_hw.cpp; the Bluetooth connection stays) */
void snap_reset(void)
{
    u_memset(&hdr, 0, sizeof hdr);
    u_memset(&wr_err, 0, sizeof wr_err);
    u_memset(&c_addr, 0, sizeof c_addr);
    u_memset(&c_val, 0, sizeof c_val);
    u_memset(&scr, 0, sizeof scr);
}
