/* c64.c -- L64 (Commodore 64 core, L64/rtl/c64_system.v) on the SD loader
 *
 * ROMs: the Commodore ROMs are not part of the project. The user puts them on the card in
 * /ROMS/C64/ (file names starting KERNAL, BASIC, CHAR and, for the 1541 drive, DOS1541 or
 * 1541, e.g. VICE's kernal-901227-03.bin, basic-901226-01.bin, chargen-901225-01.bin,
 * dos1541-325302-01+901229-05.bin; 8 / 8 / 4 / 16 KB). They are written into the
 * configuration flash at 0x200000 through the FPGA's flash pass-through (tape loader
 * register FLASH, SPI byte engine): 48 KB image = 4 KB header (F3 "L64 ROMS" + 4 spaces, byte 13
 * = 1 with a 1541 ROM), CHAR, BASIC, KERNAL, 8 KB FF, 1541 ROM (16 KB, or FF)
 * (L64/tools/mk_c64rom.py makes the same image). After the write is verified,
 * RELOAD makes the FPGA copy the ROMs into SDRAM and restart the C64.
 *
 * .prg / .t64: the CPU is stopped (snapshot freeze, at an instruction boundary) and the
 * bytes are written into RAM with snapshot MWR commands (bursts on the link). A BASIC
 * program ($0801) gets the BASIC pointers (VARTAB/ARYTAB/STREND = end) and RUN + RETURN
 * in the keyboard buffer; other load addresses only set the end-of-load pointer.
 *
 * .tap (C64-TAPE-RAW): each byte b > 0 is one pulse of b * 8 cycles, 0 is an overflow
 * (version 0: 256 * 8; version 1: the next 3 bytes are the length in cycles). A pulse
 * becomes two pulse player half periods, so the CIA FLAG input (the read line) sees
 * one falling edge per pulse. The player counts C64 cycles while the cassette motor is
 * on, so the KERNAL's motor control pauses the tape as on a real datasette.
 *
 * Recording: the recorder (tape_loader REC) reports every edge of the cassette write line
 * (6510 port bit 3) with the cycles since the previous one; two edges make one pulse,
 * written as one byte (cycles / 8) or as 0 + 24-bit length (version 1) when longer (the
 * edge after a pause carries the whole time since the previous edge). While
 * armed, the C64 (CPU and CIAs) is held until each event has been read. The sense line
 * shows PLAY pressed (TAPE_ON) during recording mode.
 *
 * Snapshots (.A64, our format): F2 freezes the C64 at an instruction boundary and saves
 * a 32-byte header (CPU registers, the CIAs' CRA / CRB / interrupt masks), the 64 KB RAM
 * and the 4 KB I/O shadow ($D000-$DFFF: the FPGA keeps the last value the CPU wrote to
 * every VIC-II, SID, colour RAM and CIA register). Loading writes the RAM back, then a
 * restore program into the FPGA's restore bank and resets the CPU alone in restore mode:
 * the program writes the I/O registers, the 6510 port and the stack, loads A / X / Y / S
 * and leaves with RTI into the snapshot (the FPGA then switches back to the real memory).
 * Not saved: the 1541, the SID's and the timers' running state, the raster position.
 */
#include "hw.h"
#include "hal.h"
#include "fat.h"
#include "tape.h"
#include "util.h"
#include "c64.h"
#include "save.h"
#include "shot.h"
#include "flash.h"

#define C_MRD    1
#define C_MWR    2
#define C_REG    3
#define C_CTL    4
#define ROM_BASE 0x200000u
#define ROM_LEN  49152u
#define ERASE_MS 2000u      /* 4 KB erase, above the datasheet maximum (0.4 s) */
#define PROG_MS  50u        /* page program (maximum 5 ms) */


int c64_rom_present(void)
{
    uint8_t h[14];
    static const char sig[] = "L64 ROMS    ", old[] = "ADORE64 ROMS";   /* old: installed before the rename */
    int i, plain = 1, rev = 1, oplain = 1, orev = 1;
    fl_read(ROM_BASE, h, sizeof h);
    FLASH = 0;
    for (i = 0; i < 12; i++) {
        uint8_t c = h[1 + i], r = 0;
        for (int b = 0; b < 8; b++) if (c & (1 << b)) r |= (uint8_t)(0x80 >> b);
        if (c != (uint8_t)sig[i]) plain = 0;
        if (r != (uint8_t)sig[i]) rev = 0;                   /* .jic images are stored bit-reversed */
        if (c != (uint8_t)old[i]) oplain = 0;
        if (r != (uint8_t)old[i]) orev = 0;
    }
    plain |= oplain;
    rev   |= orev;
    if (h[0] == 0xF3 && plain) return h[13] == 0x01 ? 2 : 1;       /* byte 13: a 1541 ROM is included */
    if (h[0] == 0xCF && rev)   return h[13] == 0x80 ? 2 : 1;
    return 0;
}

/*----------------------------------------------------------------------------
 * ROM install
 *--------------------------------------------------------------------------*/
typedef struct { const char *dir; uint32_t clus; int found; } FINDDIR;
typedef struct { uint32_t clus[4], size[4]; int found[4]; } FINDROM;

static int prefix(const char *s, const char *p)
{
    while (*p) {
        char a = *s++, b = *p++;
        if (a >= 'a' && a <= 'z') a = (char)(a - 32);
        if (a != b) return 0;
    }
    return 1;
}

static int dir_cb_find(const DIRENT *d, void *ctx)
{
    FINDDIR *f = (FINDDIR *)ctx;
    if ((d->attr & ATTR_DIR) && u_stricmp(d->name, f->dir) == 0) { f->clus = d->clus; f->found = 1; return 1; }
    return 0;
}

static int rom_cb(const DIRENT *d, void *ctx)
{
    FINDROM *r = (FINDROM *)ctx;
    static const char *const pre[5] = { "CHAR", "BASIC", "KERNAL", "DOS1541", "1541" };
    static const uint32_t len[5] = { 4096, 8192, 8192, 16384, 16384 };
    int i;
    if (d->attr & ATTR_DIR) return 0;
    for (i = 0; i < 5; i++) {
        int k = i < 3 ? i : 3;
        if (!r->found[k] && prefix(d->name, pre[i]) && d->size == len[i]) {
            r->clus[k] = d->clus; r->size[k] = d->size; r->found[k] = 1;
        }
    }
    return 0;
}

static FINDROM rom;
static uint8_t page[256];

/* one 256-byte page of the image at offset a (pages never cross a file boundary) */
static int image_page(uint32_t a)
{
    static const uint32_t base[4] = { 4096, 8192, 16384, 32768 };
    FFILE f;
    int k, i, c;
    if (a < 4096 || (a >= 24576 && a < 32768) || (a >= 32768 && !rom.found[3])) {
        u_memset(page, 0xFF, sizeof page);
        if (a == 0) { page[0] = 0xF3; u_memcpy(page + 1, "L64 ROMS    ", 12); page[13] = rom.found[3] ? 1 : 0; }
        return 0;
    }
    k = a >= base[3] ? 3 : a >= base[2] ? 2 : a >= base[1] ? 1 : 0;
    ff_open(&f, rom.clus[k], rom.size[k]);
    ff_seek(&f, a - base[k]);
    for (i = 0; i < 256; i++) {
        if ((c = ff_getc(&f)) < 0) return FAT_EIO;
        page[i] = (uint8_t)c;
    }
    return 0;
}

/* program one 256-byte page of the image: 0, FAT_EIO or C64_EFLASH */
static int write_page(uint32_t a)
{
    uint32_t i;
    if (image_page(a)) return FAT_EIO;
    fl_wren();
    fl_addr(0x02, ROM_BASE + a);
    for (i = 0; i < 256; i++) fl_send(page[i]);
    fl_end();
    return fl_wait(PROG_MS) ? C64_EFLASH : 0;
}

/* compare the flash with the image from offset first to the end: 0, FAT_EIO or C64_EFLASH */
static int check_pages(uint32_t first)
{
    uint32_t a, i;
    for (a = first; a < ROM_LEN; a += 256) {
        if (image_page(a)) return FAT_EIO;
        fl_addr(0x03, ROM_BASE + a);
        for (i = 0; i < 256; i++)
            if (fl_xfer(0) != page[i]) { fl_end(); return C64_EFLASH; }
        fl_end();
    }
    return 0;
}

/* /ROMS/C64/ on the card -> rom: 0, FAT_EIO or C64_ENOROM */
static int rom_find(void)
{
    FINDDIR fd;
    uint32_t a;

    fd.dir = "ROMS"; fd.found = 0;
    if (fat_list(0, dir_cb_find, &fd) != FAT_OK) return FAT_EIO;
    if (!fd.found) return C64_ENOROM;
    a = fd.clus; fd.dir = "C64"; fd.found = 0;
    if (fat_list(a, dir_cb_find, &fd) != FAT_OK) return FAT_EIO;
    if (!fd.found) return C64_ENOROM;
    u_memset(&rom, 0, sizeof rom);
    if (fat_list(fd.clus, rom_cb, &rom) != FAT_OK) return FAT_EIO;
    if (!rom.found[0] || !rom.found[1] || !rom.found[2]) return C64_ENOROM;
    return 0;
}

int c64_rom_card_1541(void)
{
    return rom_find() == 0 && rom.found[3];
}

int c64_rom_install(void (*progress)(const char *))
{
    uint32_t a;
    int r = rom_find();

    if (r) return r;
    /* The header page (offset 0, "L64 ROMS") is written last and only after the ROM data
     * checked out, so an install that stops anywhere (error, reset) never leaves an image
     * that looks valid; block 0 is erased first, which removes the old header. */
    progress("Erasing flash");
    for (a = 0; a < ROM_LEN; a += 4096) {
        fl_wren();
        fl_addr(0x20, ROM_BASE + a);
        fl_end();
        if (fl_wait(ERASE_MS)) { FLASH = 0; return C64_EFLASH; }
    }
    progress("Writing flash");
    for (a = 256; a < ROM_LEN && !r; a += 256) r = write_page(a);
    if (!r) { progress("Checking flash"); r = check_pages(256); }
    if (!r) r = write_page(0);                      /* the header: the image is valid from here on */
    if (!r) r = check_pages(0);
    if (r) { FLASH = 0; return r; }
    FLASH = 0;
    RELOAD = 1;                                     /* the FPGA copies the ROMs and restarts the C64 */
    return 0;
}

/*----------------------------------------------------------------------------
 * .prg / .t64
 *--------------------------------------------------------------------------*/
static uint32_t snap_cmd(uint32_t c, uint32_t a, uint32_t d)
{
    SNAPDAT = d;
    SNAPCMD = (c << 28) | a;
    while (SNAPCTL & SNAP_BUSY) ;
    return SNAPDAT;
}

static void poke(uint32_t a, uint8_t v) { snap_cmd(C_MWR, a & 0xFFFFu, v); }

static int freeze(void)
{
    uint32_t t0 = TIMER;
    SNAPCTL = 1;
    while (!(SNAPCTL & SNAP_FROZEN))
        if (TIMER - t0 > 200 * CLK_PER_MS) { SNAPCTL = 0; return C64_ERUN; }
    return 0;
}

static char *hex4(char *p, uint32_t v)
{
    static const char h[] = "0123456789ABCDEF";
    *p++ = '$';
    for (int s = 12; s >= 0; s -= 4) *p++ = h[(v >> s) & 15];
    *p = 0;
    return p;
}

int c64_prg_load(FFILE *f, int t64, char *info)
{
    uint32_t start, end, n, i, off = 0;
    int c, lo, hi;

    if (t64) {                                      /* first used directory entry */
        uint8_t e[32];
        uint32_t ents;
        ff_seek(f, 0x22);
        lo = ff_getc(f); hi = ff_getc(f);
        if (lo < 0 || hi < 0) return C64_EBAD;
        ents = (uint32_t)(lo | hi << 8);
        for (i = 0; i < (ents ? ents : 1); i++) {
            ff_seek(f, 0x40 + 32 * i);
            for (c = 0; c < 32; c++) { int b = ff_getc(f); if (b < 0) return C64_EBAD; e[c] = (uint8_t)b; }
            if (e[0] == 1) break;
        }
        if (e[0] != 1) return C64_EBAD;
        start = e[2] | (uint32_t)e[3] << 8;
        end   = e[4] | (uint32_t)e[5] << 8;
        off   = e[8] | (uint32_t)e[9] << 8 | (uint32_t)e[10] << 16 | (uint32_t)e[11] << 24;
        if (off >= f->size) return C64_EBAD;
        n = end > start ? end - start : 0;
        if (n == 0 || off + n > f->size) n = f->size - off;  /* many .t64 files have a wrong end address */
        ff_seek(f, off);
    } else {
        lo = ff_getc(f); hi = ff_getc(f);
        if (lo < 0 || hi < 0 || f->size < 3) return C64_EBAD;
        start = (uint32_t)(lo | hi << 8);
        n = f->size - 2;
    }
    if (start + n > 0x10000u) n = 0x10000u - start;
    end = start + n;

    if (freeze()) return C64_ERUN;
    for (i = 0; i < n; i++) {
        if ((c = ff_getc(f)) < 0) { SNAPCTL = 0; return FAT_EIO; }
        poke(start + i, (uint8_t)c);
    }
    poke(0xAE, (uint8_t)end); poke(0xAF, (uint8_t)(end >> 8));          /* end of load */
    if (start == 0x0801) {                          /* BASIC: pointers as after LOAD, then RUN */
        for (i = 0x2D; i <= 0x31; i += 2) { poke(i, (uint8_t)end); poke(i + 1, (uint8_t)(end >> 8)); }
        poke(0x0277, 'R'); poke(0x0278, 'U'); poke(0x0279, 'N'); poke(0x027A, 13);
        poke(0xC6, 4);
    }
    SNAPCTL = 0;
    char *p = hex4(info, start);
    *p++ = '-';
    hex4(p, end);
    return 0;
}

/*----------------------------------------------------------------------------
 * .tap
 *--------------------------------------------------------------------------*/
static FFILE   *t_f;
static int      t_ver, t_state;
static uint32_t t_pend;                             /* second half period still to push (0 = none) */

void c64tap_start(FFILE *f)
{
    static const char sig[] = "C64-TAPE-RAW";
    int i;
    t_f = f;
    t_pend = 0;
    t_state = TS_RUN;
    ff_seek(f, 0);
    for (i = 0; i < 12; i++) if (ff_getc(f) != sig[i]) { t_state = TS_ERR; return; }
    t_ver = ff_getc(f);
    if (t_ver < 0 || t_ver > 1) { t_state = TS_ERR; return; }
    ff_seek(f, 20);
}

int c64tap_pump(void)
{
    while (t_state == TS_RUN && fifo_free() > 0) {
        uint32_t len;
        int b;
        if (t_pend) { fifo_push(CMD_PULSE(t_pend)); t_pend = 0; continue; }
        b = ff_getc(t_f);
        if (b < 0) { t_state = TS_END; break; }
        if (b) len = (uint32_t)b * 8u;
        else if (t_ver == 0) len = 256u * 8u;
        else {
            int b0 = ff_getc(t_f), b1 = ff_getc(t_f), b2 = ff_getc(t_f);
            if (b2 < 0) { t_state = TS_END; break; }
            len = (uint32_t)(b0 | b1 << 8 | b2 << 16);
        }
        if (len < 2) len = 2;
        if (len > 2 * CMD_MAX_T) len = 2 * CMD_MAX_T;
        fifo_push(CMD_PULSE(len / 2));
        t_pend = len - len / 2;
    }
    return t_state;
}

/*----------------------------------------------------------------------------
 * .tap recording
 *--------------------------------------------------------------------------*/
static int      r_on, r_half;
static uint32_t r_acc, r_pulses;

static void r_put(uint8_t b)
{
    if (r_on && fw_putc(&fw_file, b) != FAT_OK) { r_on = 0; RECCTL = 0; TAPE = 0; }
}

static void r_pulse(uint32_t len)
{
    uint32_t v = (len + 4) / 8;
    if (v >= 1 && v <= 255) r_put((uint8_t)v);
    else {
        if (len > 0xFFFFFFu) len = 0xFFFFFFu;
        r_put(0); r_put((uint8_t)len); r_put((uint8_t)(len >> 8)); r_put((uint8_t)(len >> 16));
    }
    r_pulses++;
}

int c64rec_start(uint32_t dir, const char name11[11])
{
    static const char sig[] = "C64-TAPE-RAW";
    int r, i;
    r = fw_create(&fw_file, dir, name11);
    if (r != FAT_OK) return r;
    r_on = 1;
    for (i = 0; i < 12; i++) r_put((uint8_t)sig[i]);
    r_put(1);                                       /* version 1 */
    for (i = 0; i < 7; i++) r_put(0);               /* reserved, data size (patched at the end) */
    r_half = 0; r_acc = 0; r_pulses = 0;
    while (REC & REC_PEND) ;                        /* reading clears an old event */
    TAPE = TAPE_ON;                                 /* sense: PLAY pressed */
    RECCTL = REC_ARMED;
    return r_on ? FAT_OK : FAT_EIO;
}

void c64rec_service(void)
{
    uint32_t ev;
    int n = 0;
    while (r_on && n++ < 64 && ((ev = REC) & REC_PEND)) {
        if (ev & REC_GAP) continue;                 /* no edge yet: the next edge's count includes the pause */
        r_acc += ev & 0xFFFFFFu;
        if (r_half) { r_pulse(r_acc); r_acc = 0; }
        r_half = !r_half;
    }
}

void c64rec_end(void)
{
    uint32_t size;
    if (!r_on) return;
    RECCTL = 0;
    TAPE = 0;
    c64rec_service();
    size = fw_file.size - 20;
    fw_patch(&fw_file, 16, (uint8_t)size);       fw_patch(&fw_file, 17, (uint8_t)(size >> 8));
    fw_patch(&fw_file, 18, (uint8_t)(size >> 16)); fw_patch(&fw_file, 19, (uint8_t)(size >> 24));
    if (r_pulses) fw_close(&fw_file); else fw_discard(&fw_file);
    r_on = 0;
}

int c64rec_active(void) { return r_on; }

int c64rec_status(char *s)
{
    if (!r_on) return 0;
    char *p = u_strcpy(s, "Recording, ");
    p = u_utoa(p, r_pulses);
    u_strcpy(p, " pulses (F12)");
    return 1;
}

/*----------------------------------------------------------------------------
 * .d64 (1541, rtl c1541.v): the FPGA makes the disk surface of one track from its track
 * buffer (snapshot addresses 0x20000 + sector * 256); this keeps the buffer on the track
 * under the head and writes sectors the DOS changed back into the file.
 *--------------------------------------------------------------------------*/
#define TB_BASE 0x20000u
static FFILE    d_f;
static int      d_on, d_ro;
static uint32_t d_loaded, d_ctl;

/* MCTL with the turbo bit (F6) */
static void mctl(uint32_t v)
{
    MCTL = v | (slow_mode ? 0u : 4u);
}

void c64_speed(void)
{
    mctl(d_on ? d_ctl | (d_loaded << 8) : 0u);
}
static char     d_name[NAME_MAX + 1];
static uint8_t  d_sec[256];

static uint32_t spt(uint32_t t) { return t <= 17 ? 21 : t <= 24 ? 19 : t <= 30 ? 18 : 17; }

static uint32_t d64_off(uint32_t t, uint32_t s)
{
    uint32_t i, n = 0;
    for (i = 1; i < t; i++) n += spt(i);
    return (n + s) * 256u;
}

/* puts a command on the cursor's screen line and RETURN into the keyboard buffer: BASIC
 * reads the line from the screen, as if it had been typed (the buffer holds only 10 keys) */
static void type_line(const char *t)
{
    uint32_t pnt, i;
    if (freeze()) return;
    pnt = snap_cmd(C_MRD, 0xD1, 0) | snap_cmd(C_MRD, 0xD2, 0) << 8;     /* start of the cursor's line */
    for (i = 0; t[i] && i < 40; i++) {
        uint8_t c = (uint8_t)t[i];
        poke(pnt + i, (uint8_t)(c >= 'A' && c <= 'Z' ? c - '@' : c));  /* screen codes */
    }
    poke(0xD3, 0);                                                    /* cursor column 0 */
    if (t[0]) {                                                       /* the cursor blink restores the character */
        uint8_t c = (uint8_t)t[0];                                    /* it hid there ($CE) when the key arrives */
        poke(0xCE, (uint8_t)(c >= 'A' && c <= 'Z' ? c - '@' : c));
    }
    poke(0x0277, 13);
    poke(0xC6, 1);
    SNAPCTL = 0;
}

/* BASIC waits for input (frozen: the screen editor's cursor flashes, direct mode, the KERNAL's
 * IRQ vector): only then is LOAD typed; a disk changed while a program runs is not typed into it */
static int at_prompt(void)
{
    return snap_cmd(C_MRD, 0xCC, 0) == 0 && snap_cmd(C_MRD, 0x9D, 0) == 0x80 &&
           snap_cmd(C_MRD, 0x314, 0) == 0x31 && snap_cmd(C_MRD, 0x315, 0) == 0xEA;
}

int c64_d64_mount(const FFILE *f, const char *name, int ro)
{
    int a, b, swap = d_on;
    uint32_t t0;
    if (f->size < 174848u) return C64_EBAD;                 /* 35 tracks, 683 sectors */
    c64_d64_eject();
    u_memcpy(&d_f, f, sizeof d_f);
    ff_seek(&d_f, d64_off(18, 0) + 0xA2);                   /* disk ID in the BAM */
    a = ff_getc(&d_f); b = ff_getc(&d_f);
    if (a < 0 || b < 0) return FAT_EIO;
    d_ro     = ro != 0;
    d_loaded = 0;
    d_ctl    = 1u | (uint32_t)d_ro << 1 | (uint32_t)a << 16 | (uint32_t)b << 24;
    if (swap) {                                             /* disk change: the new disk covers the write-protect */
        mctl(1u | 2u);                                      /* sensor while it slides in; the DOS sees the change */
        t0 = TIMER;                                         /* (VIA2 PB4) and reads the new disk's BAM */
        while (TIMER - t0 < 300 * CLK_PER_MS) ;
    }
    mctl(d_ctl);
    d_on     = 1;
    u_strncpy(d_name, name, NAME_MAX);
    c64_d64_service();                                      /* the track under the head first (18 after a reset):
                                                               the DOS starts reading as soon as LOAD is typed */
    if (freeze() == 0) {
        int p = at_prompt();
        SNAPCTL = 0;
        if (p) type_line("LOAD\"*\",8,1");
    }
    return 0;
}

void c64_d64_eject(void)
{
    if (d_on) c64_d64_service();                            /* last written sectors */
    mctl(0);
    d_on = 0;
}

void c64_d64_service(void)
{
    uint32_t st, t, dirty, s, i;
    if (!d_on) return;
    st    = MCTL;
    t     = st & 0x3Fu;
    dirty = (st >> 8) & 0x1FFFFFu;
    /* a gone FPGA (Ctrl+Alt+Del / KEY1 to the menu, KEY0) reads all ones: head track 63, every
     * sector dirty, sector data FF; writing that back would wipe the track (the loader restarts
     * the ESP32 within 0.5 s) */
    if (t > 35 || (d_loaded && (dirty >> spt(d_loaded)) != 0)) return;
    if (dirty && d_loaded) {
        for (s = 0; s < spt(d_loaded); s++)
            if (dirty & (1u << s)) {
                for (i = 0; i < 256; i++) d_sec[i] = (uint8_t)snap_cmd(C_MRD, TB_BASE + s * 256 + i, 0);
                if (!link_alive()) return;                  /* the data may be the gone FPGA's FFs */
                if (!d_ro) ff_update(&d_f, d64_off(d_loaded, s), d_sec, 256);
                MCLR = 1u << s;
            }
    }
    if (t >= 1 && t <= 35 && t != d_loaded) {
        mctl(d_ctl);                                        /* nothing valid while loading */
        for (s = 0; s < spt(t); s++) {
            ff_seek(&d_f, d64_off(t, s));
            for (i = 0; i < 256; i++) {
                int c = ff_getc(&d_f);
                snap_cmd(C_MWR, TB_BASE + s * 256 + i, (uint32_t)(c < 0 ? 0 : c));
            }
        }
        d_loaded = t;
        mctl(d_ctl | t << 8);
    }
}

int c64_d64_status(char *s)
{
    if (!d_on) return 0;
    char *p = u_strcpy(s, "Disk: ");
    u_strncpy(p, d_name, 26);
    return 1;
}

/*----------------------------------------------------------------------------
 * snapshots (.A64)
 *--------------------------------------------------------------------------*/
#define SH_BASE  0x3D000u               /* I/O shadow */
#define RB_BASE  0x30000u               /* restore bank: the CPU's view in restore mode */
#define A64_HDR  32u
#define A64_SIZE (A64_HDR + 65536u + 4096u)
#define STUB     0x2000u                /* restore program in the bank */
#define CRAM_BUF 0x3000u                /* colour RAM copy in the bank */

static uint8_t a64_hdr[A64_HDR];
static uint8_t a64_sh[4096];            /* loading: the file's I/O shadow */
static uint32_t stub_pc;

int c64_snap_freeze(void) { return freeze(); }

void c64_snap_capture(void)
{
    uint32_t r0 = snap_cmd(C_REG, 0, 0), r1 = snap_cmd(C_REG, 1, 0);
    uint32_t c1 = snap_cmd(C_REG, 2, 0), c2 = snap_cmd(C_REG, 3, 0);
    u_memset(a64_hdr, 0, sizeof a64_hdr);
    u_memcpy(a64_hdr, "L64SNAPS", 8);
    a64_hdr[8]  = 1;                                    /* version */
    a64_hdr[9]  = (uint8_t)r0;                          /* A */
    a64_hdr[10] = (uint8_t)(r0 >> 8);                   /* X */
    a64_hdr[11] = (uint8_t)(r0 >> 16);                  /* Y */
    a64_hdr[12] = (uint8_t)(r0 >> 24);                  /* P */
    a64_hdr[13] = (uint8_t)r1;                          /* S */
    a64_hdr[14] = (uint8_t)(r1 >> 16);                  /* PC */
    a64_hdr[15] = (uint8_t)(r1 >> 24);
    a64_hdr[16] = (uint8_t)c1; a64_hdr[17] = (uint8_t)(c1 >> 8); a64_hdr[18] = (uint8_t)(c1 >> 16);   /* CIA1 IMR CRA CRB */
    a64_hdr[19] = (uint8_t)c2; a64_hdr[20] = (uint8_t)(c2 >> 8); a64_hdr[21] = (uint8_t)(c2 >> 16);   /* CIA2 */
}

int c64_snap_save(uint32_t dir, const char name11[11])
{
    uint32_t i;
    int r = fw_create(&fw_file, dir, name11);
    if (r != FAT_OK) return r;
    for (i = 0; i < A64_HDR && r == FAT_OK; i++) r = fw_putc(&fw_file, a64_hdr[i]);
    for (i = 0; i < 65536u && r == FAT_OK; i++) r = fw_putc(&fw_file, (uint8_t)snap_cmd(C_MRD, i, 0));
    for (i = 0; i < 4096u && r == FAT_OK; i++) r = fw_putc(&fw_file, (uint8_t)snap_cmd(C_MRD, SH_BASE + i, 0));
    if (r != FAT_OK) { fw_discard(&fw_file); return r; }
    return fw_close(&fw_file);
}

void c64_snap_resume(void) { SNAPCTL = 0; }

/* restore program: bytes into the bank */
static void e8(uint8_t b)                { snap_cmd(C_MWR, RB_BASE + stub_pc++, b); }
static void e_sta(uint8_t v, uint32_t a) { e8(0xA9); e8(v); e8(0x8D); e8((uint8_t)a); e8((uint8_t)(a >> 8)); }   /* LDA #v / STA a */

static void e_cia(uint32_t base, const uint8_t *sh, uint8_t imr, uint8_t cra, uint8_t crb)
{
    static const uint8_t regs[] = { 2, 3, 0, 1, 4, 5, 6, 7 };   /* DDRs, ports, timer latches */
    uint32_t i;
    e_sta(0x7F, base + 0x0D);                           /* no interrupts, timers stopped */
    e8(0xAD); e8(0x0D); e8((uint8_t)(base >> 8));      /* LDA ICR: clears pending flags */
    e_sta(0x00, base + 0x0E);
    e_sta(0x00, base + 0x0F);
    for (i = 0; i < sizeof regs; i++) e_sta(sh[regs[i]], base + regs[i]);
    e_sta((uint8_t)(cra | 0x10), base + 0x0E);          /* force load from the latch */
    e_sta((uint8_t)(crb | 0x10), base + 0x0F);
    e_sta((uint8_t)(0x80 | imr), base + 0x0D);
}

int c64_snap_load(FFILE *f)
{
    uint32_t i, t0;
    int c;
    uint8_t s, pcl, pch, ram01[2];

    if (f->size != A64_SIZE) return C64_EBAD;
    for (i = 0; i < A64_HDR; i++) {
        if ((c = ff_getc(f)) < 0) return FAT_EIO;
        a64_hdr[i] = (uint8_t)c;
    }
    if ((u_memcmp(a64_hdr, "L64SNAPS", 8) != 0 && u_memcmp(a64_hdr, "ADORE64S", 8) != 0) || a64_hdr[8] != 1)
        return C64_EBAD;                                /* ADORE64S: saved before the rename */
    if (freeze()) return C64_ERUN;
    for (i = 0; i < 65536u; i++) {                      /* RAM */
        if ((c = ff_getc(f)) < 0) { SNAPCTL = 0; return FAT_EIO; }
        if (i < 2) ram01[i] = (uint8_t)c;
        snap_cmd(C_MWR, i, (uint32_t)c);
    }
    for (i = 0; i < 4096u; i++) {                       /* I/O shadow */
        if ((c = ff_getc(f)) < 0) { SNAPCTL = 0; return FAT_EIO; }
        a64_sh[i] = (uint8_t)c;
    }
    for (i = 0; i < 1024u; i++) snap_cmd(C_MWR, RB_BASE + CRAM_BUF + i, a64_sh[0x800 + i]);
    snap_cmd(C_MWR, RB_BASE + 0xFFFC, STUB & 0xFF);     /* reset vector -> the program */
    snap_cmd(C_MWR, RB_BASE + 0xFFFD, STUB >> 8);

    stub_pc = STUB;
    e8(0x78); e8(0xD8);                                 /* SEI, CLD */
    for (i = 0; i <= 0x2E; i++) {                       /* VIC-II */
        if (i == 0x1E || i == 0x1F) continue;           /* collisions: read only */
        e_sta(i == 0x19 ? 0x0F : a64_sh[i], 0xD000 + i);   /* $D019: acknowledge all */
    }
    for (i = 0; i <= 0x18; i++) e_sta(a64_sh[0x400 + i], 0xD400 + i);     /* SID, volume last */
    e8(0xA2); e8(0x00);                                 /* LDX #0 */
    for (i = 0; i < 4; i++) {                           /* colour RAM: LDA CRAM_BUF+i*$100,X / STA $D800+i*$100,X */
        e8(0xBD); e8(0x00); e8((uint8_t)((CRAM_BUF >> 8) + i));
        e8(0x9D); e8(0x00); e8((uint8_t)(0xD8 + i));
    }
    e8(0xE8); e8(0xD0); e8((uint8_t)(0x100 - 27));      /* INX, BNE back to the first LDA */
    e_cia(0xDC00, a64_sh + 0xC00, a64_hdr[16], a64_hdr[17], a64_hdr[18]);
    e_cia(0xDD00, a64_sh + 0xD00, a64_hdr[19], a64_hdr[20], a64_hdr[21]);
    e_sta(ram01[0], 0x0000);                            /* 6510 port */
    e_sta(ram01[1], 0x0001);
    s = a64_hdr[13]; pcl = a64_hdr[14]; pch = a64_hdr[15];
    e8(0xA2); e8((uint8_t)(s - 3)); e8(0x9A);           /* LDX #S-3, TXS */
    e_sta(a64_hdr[12], 0x0100u + (uint8_t)(s - 2));     /* stack for RTI: P, PCL, PCH */
    e_sta(pcl,         0x0100u + (uint8_t)(s - 1));
    e_sta(pch,         0x0100u + s);
    e8(0xA9); e8(a64_hdr[9]);                           /* LDA #A */
    e8(0xA2); e8(a64_hdr[10]);                          /* LDX #X */
    e8(0xA0); e8(a64_hdr[11]);                          /* LDY #Y */
    e8(0x40);                                           /* RTI */

    snap_cmd(C_CTL, 0, 3);                              /* restore mode, CPU in reset */
    SNAPCTL = 0;                                        /* the C64 runs again (CPU still in reset) */
    t0 = TIMER;
    while (TIMER - t0 < CLK_PER_MS) ;
    snap_cmd(C_CTL, 0, 1);                              /* CPU out of reset: vector, program, RTI */
    t0 = TIMER;
    while (snap_cmd(C_CTL, 0, 1) & 1)
        if (TIMER - t0 > 500 * CLK_PER_MS) { snap_cmd(C_CTL, 0, 0); return C64_ERUN; }
    snap_cmd(C_CTL, 0, 0);
    return 0;
}

/*----------------------------------------------------------------------------
 * screenshot (Print Screen): the newest complete frame of the FPGA's frame buffer
 * (L64/rtl/c64_fb.v: 400 x 284 dots, 4 per 16-bit word, first dot in the low
 * nibble, 256 bytes per line) as a BMP. While the hold is on (CTL[2]) the buffers do not
 * change and MRD reads the newest one (address = offset in it); the C64 runs on.
 *--------------------------------------------------------------------------*/
int c64_screenshot(uint32_t dir, const char name11[11])
{
    static const uint8_t k6[16][3] = {                  /* Kawari's palette, 6 bits per colour */
        {0x00,0x00,0x00}, {0x3f,0x3f,0x3f}, {0x2b,0x0a,0x0a}, {0x18,0x36,0x33},
        {0x2c,0x0f,0x2d}, {0x12,0x31,0x12}, {0x0d,0x0e,0x31}, {0x39,0x3b,0x13},
        {0x2d,0x16,0x07}, {0x1a,0x0e,0x02}, {0x3a,0x1d,0x1b}, {0x13,0x13,0x13},
        {0x21,0x21,0x21}, {0x29,0x3e,0x27}, {0x1c,0x1f,0x39}, {0x2d,0x2d,0x2d} };
    uint8_t  pal[16][3], row[400];
    uint32_t a, b;
    int      i, y, x, r;

    for (i = 0; i < 16; i++)
        for (x = 0; x < 3; x++) pal[i][x] = (uint8_t)(k6[i][x] << 2 | k6[i][x] >> 4);
    snap_cmd(C_CTL, 0, 4);                              /* hold the frame buffers */
    r = shot_begin(dir, name11, 400, 284, pal);
    for (y = 283; y >= 0 && r == FAT_OK; y--) {
        for (x = 0; x < 400; x += 2) {
            a = (uint32_t)y * 256u + (uint32_t)x / 2;
            b = snap_cmd(C_MRD, a, 0);
            row[x] = (uint8_t)(b & 15);
            row[x + 1] = (uint8_t)(b >> 4 & 15);
        }
        r = shot_row(row);
    }
    snap_cmd(C_CTL, 0, 0);
    if (r != FAT_OK) { shot_end(); return r; }
    return shot_end();
}

/* back to the state after a start: the next machine starts the loader again without an ESP32
 * restart (esp_hw.cpp; the Bluetooth connection stays) */
void c64_reset(void)
{
    u_memset(&rom, 0, sizeof rom);
    u_memset(&page, 0, sizeof page);
    u_memset(&t_f, 0, sizeof t_f);
    u_memset(&t_ver, 0, sizeof t_ver);
    u_memset(&t_state, 0, sizeof t_state);
    u_memset(&t_pend, 0, sizeof t_pend);
    u_memset(&r_on, 0, sizeof r_on);
    u_memset(&r_half, 0, sizeof r_half);
    u_memset(&r_acc, 0, sizeof r_acc);
    u_memset(&r_pulses, 0, sizeof r_pulses);
    u_memset(&d_f, 0, sizeof d_f);
    u_memset(&d_on, 0, sizeof d_on);
    u_memset(&d_ro, 0, sizeof d_ro);
    u_memset(&d_loaded, 0, sizeof d_loaded);
    u_memset(&d_ctl, 0, sizeof d_ctl);
    u_memset(&d_name, 0, sizeof d_name);
    u_memset(&d_sec, 0, sizeof d_sec);
    u_memset(&a64_hdr, 0, sizeof a64_hdr);
    u_memset(&a64_sh, 0, sizeof a64_sh);
    u_memset(&stub_pc, 0, sizeof stub_pc);
}
