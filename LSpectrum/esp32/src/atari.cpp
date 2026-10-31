/* atari.c -- LTari (Atari 800XL / 130XE core): the SIO disk drive D1: for .atr images
 *
 * The FPGA's SIO bridge (LTari/rtl/atari_sio.v) gives us the bytes POKEY sends, each with
 * the command line state, and sends our bytes to POKEY's serial input at 19,200 baud:
 *   MSTAT (read MCTL): [7:0] byte, [8] valid, [9] sent during a command frame, [10] first byte of
 *                      the frame, [11] command line asserted now, [13] everything sent
 *   MCLR:              [7:0] byte, [8] send it, [9] drop the oldest received byte, [10] flush
 * The drive follows the SIO protocol of the Altirra Hardware Reference Manual (9.1, 10.2): a command
 * frame (device, command, AUX1, AUX2, checksum) is answered after the command line is raised:
 * ACK 'A' (or NAK 'N'), then for a write the computer's data frame and a second ACK, then at least
 * 250 us later Complete 'C' (or Error 'E') and, for a read, the data frame. Checksums are the 8-bit
 * sum with the carry added back in.
 * Commands: $53 status (4 bytes: drive status, inverted FDC status, format timeout $E0, 0),
 * $52 read, $50 put / $57 write, $21 / $22 format (sectors filled with 0; the answer is a
 * sector-sized buffer of $FF = no bad sectors); anything else is NAKed. Sectors 1-3 are always
 * 128 bytes, the others the image's sector size (128 or 256).
 *
 * .atr: 16-byte header ($96 $02, size in 16-byte paragraphs [3:2] + [6] << 16, sector size [5:4]),
 * then the sectors in order (a header size beyond the file's end, as some old images have, is cut to
 * the file). Mounting cold-starts the Atari (RELOAD), so the OS boots from D1:.
 * .car: 16-byte header ("CART", type and checksum big-endian), then the ROM. Types 1 (standard 8 KB,
 * $A000) and 2 (standard 16 KB, $8000) are written to SDRAM 0x28000, types 41 (Atarimax 128 KB), 42
 * (Atarimax 1 MB, starts in bank 0) and 75 (the same, starting in bank 127) to 0x100000 through the
 * cartridge window (MCTL [23], 256 KB page in [21:20]); the snapshot port's MWR does the writing. MCTL
 * [18:16] then switches the cartridge on (rtl/atari_system.v) and the Atari cold-starts into it. Inserting
 * an .atr or running an .xex takes the cartridge out again (KEY0 too).
 * Screenshot: the frame buffer's newest frame (rtl/atari_fb.v: 376 x 240 pixels, one byte each,
 * 512 bytes per line), held while it is read (memory command CTL [2]), as a 256-colour BMP.
 * .xex: a read-only virtual disk: sectors 1-3 = our boot loader (atari_xexboot.h, from
 * LTari/tools/mk_xexboot.py, with the file length patched in), sectors 4.. = the file.
 * Snapshots (.A8S, as L64's .A64; rtl/atari_system.v): freeze at an instruction boundary,
 * 128-byte header (CPU, PIA, cartridge state, cartridge / disk names), the I/O shadow
 * (0x3D000-0x3D4FF: GTIA, -, POKEY, PIA, ANTIC pages), 64 KB RAM (+ 64 KB extended on the 130).
 * Loading: RAM back, then a restore program in the restore bank (0x30000) runs in restore mode:
 * POKEY, GTIA, PIA, ANTIC, Atarimax bank, stack, A / X / Y, RTI.
 */
#include <stdlib.h>
#include "hw.h"
#include "hal.h"
#include "atari.h"
#include "util.h"
#include "atari_xexboot.h"
#include "atari_palette.h"
#include "shot.h"
#include "fat.h"

#define ST_VALID  (1u << 8)
#define ST_CMD    (1u << 9)
#define ST_FIRST  (1u << 10)
#define ST_CMDNOW (1u << 11)
#define ST_TXDONE (1u << 13)
#define CL_PUSH   (1u << 8)
#define CL_POP    (1u << 9)
#define CL_FLUSH  (1u << 10)

#define DEV_D1    0x31
#define CART_BASE 0x28000u                  /* SDRAM address of the cartridge image (rtl/atari_system.v) */

/* snapshot port memory command (esp_hw.cpp turns MWR into bursts); the CPU need not stop */
static uint32_t snap_cmd(uint32_t c, uint32_t a, uint32_t d)
{
    SNAPDAT = d;
    SNAPCMD = (c << 28) | a;
    while (SNAPCTL & SNAP_BUSY) ;
    return SNAPDAT;
}

enum { C_MRD = 1, C_MWR = 2, C_REG = 3, C_CTL = 4 };    /* snapshot port commands */

static char     a_cname[NAME_MAX + 1];  /* the cartridge in (snapshots check it) */
static FFILE    a_f;
static int      a_on, a_ro, a_wperr, a_xex;
static uint32_t a_cart;                 /* MCTL [18:16]: the cartridge in */
static uint32_t a_ssz, a_nsec;
static char     a_name[NAME_MAX + 1];
static uint8_t  a_buf[257];
static uint8_t  cf[5];
static int      cn;

static uint8_t csum(const uint8_t *d, int n)
{
    unsigned s = 0;
    int      i;
    for (i = 0; i < n; i++) {
        s += d[i];
        s = (s & 0xFFu) + (s >> 8);
    }
    return (uint8_t)s;
}

static uint32_t sec_len(uint32_t s) { return s <= 3 ? 128u : a_ssz; }
static uint32_t sec_off(uint32_t s) { return s <= 3 ? 16u + (s - 1u) * 128u : 16u + 384u + (s - 4u) * a_ssz; }
static uint32_t a_xlen;                 /* .xex: the file length, patched into the loader sectors */

static void wait_us(uint32_t us)
{
    uint32_t t0 = TIMER;
    while (TIMER - t0 < us * (CLK_PER_MS / 1000u)) ;
}

static void tx(uint8_t b) { MCLR = CL_PUSH | b; }

static void tx_frame(const uint8_t *d, int n)
{
    int i;
    for (i = 0; i < n; i++) tx(d[i]);
    tx(csum(d, n));
}

/* until the last byte's stop bit is out (at most 200 ms) */
static void tx_wait(void)
{
    uint32_t t0 = TIMER;
    while (!(MCTL & ST_TXDONE) && TIMER - t0 < 200u * CLK_PER_MS) ;
}

/* the result byte after an ACK: at least 250 us of dead time after it */
static void tx_result(uint8_t b)
{
    tx_wait();
    wait_us(300);
    tx(b);
}

/* the computer's data frame: n bytes + checksum into d; 0 = ok, -1 = timeout / command
   frame instead, -2 = bad checksum */
static int rx_frame(uint8_t *d, int n)
{
    uint32_t t0 = TIMER, st;
    int      i = 0;
    while (i < n + 1) {
        st = MCTL;
        if (st == 0xFFFFFFFFu) return -1;                   /* FPGA gone */
        if (st & ST_VALID) {
            if (st & ST_CMD) return -1;
            d[i++] = (uint8_t)st;
            MCLR = CL_POP;
            t0 = TIMER;
        } else if (TIMER - t0 > 50u * CLK_PER_MS)
            return -1;
    }
    return csum(d, n) == d[n] ? 0 : -2;
}

static int read_sec(uint32_t s, uint8_t *d)
{
    uint32_t i, n = sec_len(s);
    int      c, err = 0;
    if (a_xex) {                                            /* loader, then the file, padded with 0 */
        if (s <= 3) {                                       /* the loader (flash) with the file length */
            uint32_t k, o;
            u_memcpy(d, atari_xexboot + (s - 1u) * 128u, 128);
            for (k = 0; k < 3; k++) {
                o = XEXBOOT_LEN_OFS + k;
                if (o / 128u == s - 1u) d[o % 128u] = (uint8_t)(a_xlen >> (8u * k));
            }
            return 0;
        }
        ff_seek(&a_f, (s - 4u) * 128u);
        for (i = 0; i < 128; i++) {
            c = (s - 4u) * 128u + i < a_f.size ? ff_getc(&a_f) : 0;
            if (c < 0) { c = 0; err = 1; }
            d[i] = (uint8_t)c;
        }
        return err ? -1 : 0;
    }
    ff_seek(&a_f, sec_off(s));
    for (i = 0; i < n; i++) {
        c = ff_getc(&a_f);
        if (c < 0) { c = 0; err = 1; }
        d[i] = (uint8_t)c;
    }
    return err ? -1 : 0;
}

/* ff_update writes inside one card sector: a disk sector may straddle two */
static int write_sec(uint32_t s, const uint8_t *d)
{
    uint32_t off = sec_off(s), n = sec_len(s), k;
    while (n) {
        k = 512u - (off & 511u);
        if (k > n) k = n;
        if (ff_update(&a_f, off, d, k) != FAT_OK) return -1;
        off += k; d += k; n -= k;
    }
    return 0;
}

static void command(void)
{
    uint32_t s = (uint32_t)cf[2] | (uint32_t)cf[3] << 8, n, i;
    uint8_t  st[4];
    int      r;

    if (cf[0] != DEV_D1 || csum(cf, 4) != cf[4]) return;  /* another device, or a bad frame: no answer */
    switch (cf[1]) {
    case 0x53:                                              /* status */
        tx(0x41);
        st[0] = (uint8_t)((a_ssz == 256 ? 0x20 : 0) | (a_nsec == 1040 ? 0x80 : 0) | (a_wperr ? 0x08 : 0));
        st[1] = 0xFF;
        st[2] = 0xE0;
        st[3] = 0x00;
        tx_result(0x43);
        tx_frame(st, 4);
        break;
    case 0x52:                                              /* read */
        if (s < 1 || s > a_nsec) { tx(0x4E); break; }
        tx(0x41);
        n = sec_len(s);
        r = read_sec(s, a_buf);
        tx_result(r ? 0x45 : 0x43);
        tx_frame(a_buf, (int)n);
        break;
    case 0x50: case 0x57:                                   /* put, write */
        if (s < 1 || s > a_nsec) { tx(0x4E); break; }
        tx(0x41);
        n = sec_len(s);
        r = rx_frame(a_buf, (int)n);
        if (r == -2) { wait_us(1000); tx(0x4E); break; }    /* bad checksum: NAK, command ends */
        if (r) break;                                       /* no data frame: the computer retries */
        wait_us(1000);                                      /* 850 us-16 ms after the frame */
        tx(0x41);
        a_wperr = a_ro;
        r = a_ro ? -1 : !link_alive() ? -1 : write_sec(s, a_buf);
        tx_result(r ? 0x45 : 0x43);
        break;
    case 0x21: case 0x22:                                   /* format */
        tx(0x41);
        a_wperr = a_ro;
        r = a_ro ? -1 : 0;
        if (!r) {
            for (i = 0; i < 256; i++) a_buf[i] = 0;
            for (i = 1; i <= a_nsec && !r; i++) r = write_sec(i, a_buf);
        }
        n = sec_len(4);
        for (i = 0; i < n; i++) a_buf[i] = 0xFF;            /* bad sector list: empty ($FFFF first) */
        tx_result(r ? 0x45 : 0x43);
        tx_frame(a_buf, (int)n);
        break;
    default:
        tx(0x4E);
        break;
    }
}

void at_service(void)
{
    uint32_t st = 0;
    int      k;
    if (!a_on) return;
    for (k = 0; k < 64; k++) {
        st = MCTL;
        if (st == 0xFFFFFFFFu) return;                      /* a gone FPGA reads all ones */
        if (!(st & ST_VALID)) break;
        MCLR = CL_POP;
        if (st & ST_CMD) {
            if (st & ST_FIRST) cn = 0;
            if (cn < 5) cf[cn++] = (uint8_t)st;
        }
    }
    if (cn == 5 && !(st & ST_CMDNOW)) {                     /* frame complete, command line raised */
        cn = 0;
        command();
    }
}

int at_atr_mount(const FFILE *f, const char *name, int ro, int boot)
{
    uint8_t  h[16];
    uint32_t bytes, ssz, nsec;
    int      i, c;
    FFILE    t;

    u_memcpy(&t, f, sizeof t);                              /* checked first: the disk in stays valid */
    ff_seek(&t, 0);
    for (i = 0; i < 16; i++) {
        c = ff_getc(&t);
        if (c < 0) return FAT_EIO;
        h[i] = (uint8_t)c;
    }
    if (h[0] != 0x96 || h[1] != 0x02) return AT_EBAD;
    bytes = ((uint32_t)h[2] | (uint32_t)h[3] << 8 | (uint32_t)h[6] << 16) * 16u;
    ssz   = (uint32_t)h[4] | (uint32_t)h[5] << 8;
    if (ssz != 128 && ssz != 256) return AT_EBAD;
    if (16u + bytes > f->size) bytes = f->size - 16u;       /* old writers: header size too big, the file counts */
    nsec  =ssz == 128 || bytes <= 384 ? bytes / 128u : 3u + (bytes - 384u) / 256u;
    if (nsec == 0 || 16u + bytes > f->size) return AT_EBAD;
    u_memcpy(&a_f, &t, sizeof a_f);
    a_xex   = 0;
    a_ssz   = ssz;
    a_nsec  = nsec;
    a_ro    = ro != 0;
    a_wperr = 0;
    a_on    = 1;
    cn      = 0;
    u_strncpy(a_name, name, NAME_MAX);
    if (!boot) return 0;                                    /* disk change only: as a real drive's door */
    a_cart = 0;                                             /* a disk boot takes the cartridge out */
    MCTL = 0;                                               /* 19,200 baud */
    MCLR = CL_FLUSH;
    RELOAD = 1;                                             /* cold start: the OS boots from D1: */
    return 0;
}

int at_xex_mount(const FFILE *f, const char *name)
{
    int   a, b;
    FFILE t;
    u_memcpy(&t, f, sizeof t);                              /* checked first: the disk in stays valid */
    ff_seek(&t, 0);
    a = ff_getc(&t); b = ff_getc(&t);
    if (a < 0 || b < 0) return FAT_EIO;
    if (a != 0xFF || b != 0xFF || f->size < 7) return AT_EBAD;   /* a binary load file starts with $FFFF */
    u_memcpy(&a_f, &t, sizeof a_f);
    a_xlen  = f->size;
    a_xex   = 1;
    a_ssz   = 128;
    a_nsec  = 3u + (f->size + 127u) / 128u;
    a_ro    = 1;
    a_wperr = 0;
    a_on    = 1;
    cn      = 0;
    u_strncpy(a_name, name, NAME_MAX);
    a_cart = 0;
    MCTL = 0;
    MCLR = CL_FLUSH;
    RELOAD = 1;                                             /* cold start: the OS boots the loader */
    return 0;
}

int at_car_mount(const FFILE *f, const char *name)
{
    uint8_t  h[16];
    uint32_t type, len, i, mode, win;
    int      c;
    FFILE    cf;
    u_memcpy(&cf, f, sizeof cf);
    ff_seek(&cf, 0);
    for (i = 0; i < 16; i++) {
        c = ff_getc(&cf);
        if (c < 0) return FAT_EIO;
        h[i] = (uint8_t)c;
    }
    if (h[0] != 'C' || h[1] != 'A' || h[2] != 'R' || h[3] != 'T') return AT_EBAD;
    type = (uint32_t)h[4] << 24 | (uint32_t)h[5] << 16 | (uint32_t)h[6] << 8 | h[7];
    switch (type) {
    case 1:  len = 8192u;    mode = 1; break;
    case 2:  len = 16384u;   mode = 2; break;
    case 41: len = 131072u;  mode = 3; break;
    case 42: len = 1048576u; mode = 4; break;
    case 75: len = 1048576u; mode = 5; break;
    default: return AT_ETYPE;
    }
    if (f->size < 16u + len) return AT_EBAD;
    a_cart = 0;
    win    = mode >= 3;                                     /* Atarimax: through the cartridge window */
    MCTL   = 0;                                             /* not mapped while it is written */
    for (i = 0; i < len; i++) {
        if (win && (i & 0x3FFFFu) == 0) MCTL = 1u << 23 | (i >> 18) << 20;     /* next 256 KB page */
        c = ff_getc(&cf);
        if (c < 0) { MCTL = 0; return FAT_EIO; }
        snap_cmd(2, win ? (i & 0x3FFFFu) : CART_BASE + i, (uint32_t)c);
    }
    a_cart = mode;
    a_on   = 0;                                             /* no disk: the cartridge runs */
    u_strncpy(a_cname, name, NAME_MAX);
    MCTL = a_cart << 16;
    MCLR = CL_FLUSH;
    RELOAD = 1;
    return 0;
}

void at_atr_eject(void)
{
    a_on = 0;
}

int at_status(char *s)
{
    if (!a_on) return 0;
    u_strncpy(u_strcpy(s, "D1: "), a_name, 26);
    return 1;
}

int at_screenshot(uint32_t dir, const char name11[11])
{
    uint8_t *row = (uint8_t *)malloc(376);                  /* not static: RAM for the Bluetooth stack */
    int y, x, r;
    if (!row) return FAT_EIO;
    snap_cmd(4, 0, 4);                                      /* hold the frame buffers */
    r = shot_begin8(dir, name11, 376, 240, atari_pal);
    for (y = 239; y >= 0 && r == FAT_OK; y--) {
        for (x = 0; x < 376; x++) row[x] = (uint8_t)snap_cmd(1, (uint32_t)y * 512u + (uint32_t)x, 0);
        r = shot_row(row);
    }
    snap_cmd(4, 0, 0);
    free(row);
    if (r != FAT_OK) { shot_end(); return r; }
    return shot_end();
}

/*----------------------------------------------------------------------------
 * snapshots (.A8S)
 *--------------------------------------------------------------------------*/
#define SH_BASE  0x3D000u               /* I/O shadow (rtl/atari_system.v) */
#define SH_LEN   0x500u                 /* GTIA $D0, $D1 (unused), POKEY $D2, PIA $D3, ANTIC $D4 */
#define RB_BASE  0x30000u               /* restore bank: the CPU's view in restore mode */
#define STUB     0x2000u                /* restore program in the bank */
#define A8S_HDR  128u

static uint8_t  s_hdr[A8S_HDR];
static uint8_t *s_sh;                   /* SH_LEN bytes while a snapshot loads (heap) */
static uint32_t stub_pc;

static uint32_t a8s_size(int m130) { return A8S_HDR + SH_LEN + (m130 ? 131072u : 65536u); }

int at_snap_freeze(void)
{
    uint32_t t0 = TIMER;
    SNAPCTL = 1;
    while (!(SNAPCTL & SNAP_FROZEN))
        if (TIMER - t0 > 200 * CLK_PER_MS) { SNAPCTL = 0; return AT_ERUN; }
    return 0;
}

void at_snap_resume(void) { SNAPCTL = 0; }

void at_snap_capture(void)
{
    uint32_t r0 = snap_cmd(C_REG, 0, 0), r1 = snap_cmd(C_REG, 1, 0);
    uint32_t pa = snap_cmd(C_REG, 2, 0), pb = snap_cmd(C_REG, 3, 0), m = snap_cmd(C_REG, 4, 0);
    u_memset(s_hdr, 0, sizeof s_hdr);
    u_memcpy(s_hdr, "LTARISNP", 8);
    s_hdr[8]  = 1;                                      /* version */
    s_hdr[9]  = (uint8_t)(m >> 12 & 1);                 /* 1 = 130XE */
    s_hdr[10] = (uint8_t)r0;                            /* A */
    s_hdr[11] = (uint8_t)(r0 >> 8);                     /* X */
    s_hdr[12] = (uint8_t)(r0 >> 16);                    /* Y */
    s_hdr[13] = (uint8_t)(r0 >> 24);                    /* P */
    s_hdr[14] = (uint8_t)r1;                            /* S */
    s_hdr[15] = (uint8_t)(r1 >> 16);                    /* PC */
    s_hdr[16] = (uint8_t)(r1 >> 24);
    s_hdr[17] = (uint8_t)pa; s_hdr[18] = (uint8_t)(pa >> 8); s_hdr[19] = (uint8_t)(pa >> 16);   /* ORA DDRA PACTL */
    s_hdr[20] = (uint8_t)pb; s_hdr[21] = (uint8_t)(pb >> 8); s_hdr[22] = (uint8_t)(pb >> 16);   /* ORB DDRB PBCTL */
    s_hdr[23] = (uint8_t)(m & 7);                       /* cartridge type (MCTL [18:16]) */
    s_hdr[24] = (uint8_t)(m >> 4 & 0x7F);               /* Atarimax bank */
    s_hdr[25] = (uint8_t)(m >> 11 & 1);                 /* Atarimax off */
    s_hdr[26] = (uint8_t)(a_on && !a_xex);              /* a disk in D1: */
    if (m & 7) u_strncpy((char *)s_hdr + 32, a_cname, 31);
    if (s_hdr[26]) u_strncpy((char *)s_hdr + 64, a_name, 31);
}

int at_snap_save(uint32_t dir, const char name11[11])
{
    uint32_t i, ram = s_hdr[9] ? 131072u : 65536u;
    int r = fw_create(&fw_file, dir, name11);
    if (r != FAT_OK) return r;
    for (i = 0; i < A8S_HDR && r == FAT_OK; i++) r = fw_putc(&fw_file, s_hdr[i]);
    for (i = 0; i < SH_LEN && r == FAT_OK; i++)  r = fw_putc(&fw_file, (uint8_t)snap_cmd(C_MRD, SH_BASE + i, 0));
    for (i = 0; i < ram && r == FAT_OK; i++)     r = fw_putc(&fw_file, (uint8_t)snap_cmd(C_MRD, i, 0));
    if (r != FAT_OK) { fw_discard(&fw_file); return r; }
    return fw_close(&fw_file);
}

/* restore program: bytes into the bank */
static void e8(uint8_t b)                { snap_cmd(C_MWR, RB_BASE + stub_pc++, b); }
static void e_sta(uint8_t v, uint32_t a) { e8(0xA9); e8(v); e8(0x8D); e8((uint8_t)a); e8((uint8_t)(a >> 8)); }   /* LDA #v / STA a */

/* PIA port: DDR (control bit 2 = 0), then the output register, then the control register */
static void e_pia(uint32_t port, uint32_t ctl, uint8_t ddr, uint8_t orr, uint8_t c)
{
    e_sta((uint8_t)(c & 0x3B), ctl);
    e_sta(ddr, port);
    e_sta((uint8_t)((c & 0x3F) | 0x04), ctl);
    e_sta(orr, port);
    e_sta((uint8_t)(c & 0x3F), ctl);
}

static int snap_load(FFILE *f, char *disk);

int at_snap_load(FFILE *f, char *disk)
{
    int r;
    if (!(s_sh = (uint8_t *)malloc(SH_LEN))) return FAT_EIO;
    r = snap_load(f, disk);
    free(s_sh);
    s_sh = 0;
    return r;
}

static int snap_load(FFILE *f, char *disk)
{
    static const uint8_t antic[] = { 0x01, 0x02, 0x03, 0x04, 0x05, 0x07, 0x09, 0x00 };   /* NMIEN last */
    uint32_t i, t0, ram, m, type;
    int c;
    uint8_t s;

    disk[0] = 0;
    for (i = 0; i < A8S_HDR; i++) {
        if ((c = ff_getc(f)) < 0) return FAT_EIO;
        s_hdr[i] = (uint8_t)c;
    }
    if (u_memcmp(s_hdr, "LTARISNP", 8) != 0 || s_hdr[8] != 1 || f->size != a8s_size(s_hdr[9])) return AT_EBAD;
    m = snap_cmd(C_REG, 4, 0);
    if ((uint32_t)s_hdr[9] != (m >> 12 & 1)) return AT_EMODEL;
    type = s_hdr[23];
    if (type && (a_cart != type || u_stricmp(a_cname, (const char *)s_hdr + 32) != 0)) {
        u_strncpy(disk, (const char *)s_hdr + 32, 31);  /* the cartridge to load first */
        return AT_ECART;
    }
    ram = s_hdr[9] ? 131072u : 65536u;
    if (at_snap_freeze()) return AT_ERUN;
    for (i = 0; i < SH_LEN; i++) {                      /* I/O shadow */
        if ((c = ff_getc(f)) < 0) { SNAPCTL = 0; return FAT_EIO; }
        s_sh[i] = (uint8_t)c;
    }
    for (i = 0; i < ram; i++) {                         /* RAM (+ extended) */
        if ((c = ff_getc(f)) < 0) { SNAPCTL = 0; return FAT_EIO; }
        snap_cmd(C_MWR, i, (uint32_t)c);
    }
    if (!type && a_cart) { a_cart = 0; MCTL = 0; }      /* the snapshot ran without the cartridge */
    snap_cmd(C_MWR, RB_BASE + 0xFFFC, STUB & 0xFF);     /* reset vector -> the program */
    snap_cmd(C_MWR, RB_BASE + 0xFFFD, STUB >> 8);

    stub_pc = STUB;
    e8(0x78); e8(0xD8);                                 /* SEI, CLD */
    e_sta(0x00, 0xD40E);                                /* NMIEN off until the end */
    e_sta(0x00, 0xD20F);                                /* POKEY: SKCTL init, then the registers */
    e_sta(s_sh[0x208], 0xD208);                         /* AUDCTL */
    for (i = 0; i < 8; i++) e_sta(s_sh[0x200 + i], 0xD200 + i);   /* AUDF / AUDC 1-4 */
    e_sta(s_sh[0x20E], 0xD20E);                         /* IRQEN */
    e_sta(s_sh[0x20F], 0xD20F);                         /* SKCTL */
    e_sta(0x00, 0xD209);                                /* STIMER */
    for (i = 0; i <= 0x1D; i++) e_sta(s_sh[i], 0xD000 + i);       /* GTIA */
    e_sta(0x00, 0xD01E);                                /* HITCLR */
    e_sta(s_sh[0x1F], 0xD01F);                          /* CONSOL (speaker) */
    e_pia(0xD300, 0xD302, s_hdr[18], s_hdr[17], s_hdr[19]);
    e_pia(0xD301, 0xD303, s_hdr[21], s_hdr[20], s_hdr[22]);
    for (i = 0; i < sizeof antic; i++) e_sta(s_sh[0x400 + antic[i]], 0xD400 + antic[i]);
    if (type >= 3) {                                    /* Atarimax: any access to $D5xx selects the bank */
        uint32_t a = 0xD500u + s_hdr[24] + (s_hdr[25] ? (type == 3 ? 0x10u : 0x80u) : 0u);
        e8(0xAD); e8((uint8_t)a); e8((uint8_t)(a >> 8));   /* LDA $D5xx */
    }
    s = s_hdr[14];
    e8(0xA2); e8((uint8_t)(s - 3)); e8(0x9A);           /* LDX #S-3, TXS */
    e_sta(s_hdr[13], 0x0100u + (uint8_t)(s - 2));       /* stack for RTI: P, PCL, PCH */
    e_sta(s_hdr[15], 0x0100u + (uint8_t)(s - 1));
    e_sta(s_hdr[16], 0x0100u + s);
    e_sta(s_sh[0x40E], 0xD40E);                         /* NMIEN (NMIs stay masked until the RTI is done) */
    e8(0xA9); e8(s_hdr[10]);                            /* LDA #A */
    e8(0xA2); e8(s_hdr[11]);                            /* LDX #X */
    e8(0xA0); e8(s_hdr[12]);                            /* LDY #Y */
    e8(0x40);                                           /* RTI */

    snap_cmd(C_CTL, 0, 3);                              /* restore mode, CPU in reset */
    SNAPCTL = 0;                                        /* the Atari runs again (CPU still in reset) */
    t0 = TIMER;
    while (TIMER - t0 < CLK_PER_MS) ;
    snap_cmd(C_CTL, 0, 1);                              /* CPU out of reset: vector, program, RTI */
    t0 = TIMER;
    while (snap_cmd(C_CTL, 0, 1) & 1)
        if (TIMER - t0 > 500 * CLK_PER_MS) { snap_cmd(C_CTL, 0, 0); return AT_ERUN; }
    snap_cmd(C_CTL, 0, 0);
    if (s_hdr[26] && (!a_on || a_xex || u_stricmp(a_name, (const char *)s_hdr + 64) != 0))
        u_strncpy(disk, (const char *)s_hdr + 64, 31);  /* the program had this disk in D1: */
    return 0;
}

