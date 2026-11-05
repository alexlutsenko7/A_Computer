/* main.c -- LSpectrum SD tape loader: file browser on the OSD + TAP/TZX player
 *
 * Keys (zx_keyboard.v, see hw.h and docs/SD_TAPE_LOADER.md):
 *   browser closed: F12 / keypad / / NumLock opens it; F11 / keypad 5 pause or
 *                   continue the tape; keypad - goes back one block.
 *   browser open:   up/down (keypad 8/2, F9/F10, arrows), page (keypad 4/6, Left/Right, PgUp/PgDn),
 *                   Enter / keypad Enter / F11 loads a file or opens a folder,
 *                   Esc / Backspace goes to the parent folder, F12 closes.
 *                   Keypad 5 and keypad - work as above.
 *   browser closed: Page Up / Page Down move the 50 Hz frame interrupt 1/8 VGA line
 *                   (108 pixels) earlier / later, to line up border effects with the
 *                   picture; "Frame INT: line.eighth" (default 24.1) for 4 s.
 *   F5:             memory contention on (default) / off; "Contention: on/off" for 4 s.
 *   always:         F7 / keypad * stops the tape: EAR and speed back to normal,
 *                   no status row; the file has to be chosen again.
 *                   F6 switches loading and saving between turbo (default) and
 *                   normal speed; "Speed: normal" / "Speed: turbo" for 2 s.
 * Playing a file switches the CPU to turbo (28 MHz) and feeds EAR from the
 * pulse player; both are released at the end of the tape or at a stop block.
 *
 * Saving (save.c): the first browser line, [Save to this folder], asks for an
 * 8.3 name and starts recording mode: everything the Spectrum saves goes into
 * that .tap file until F12 (or F7) is pressed.
 *
 * Joysticks: F4 opens the joystick menu (up/down, Enter = select, F4/Esc =
 * close): both DB9 ports Kempston (default); DB9-1 Kempston + DB9-2 Cursor;
 * Interface 2 (DB9-1 Sinclair 1 = keys 6-0, DB9-2 Sinclair 2 = keys 1-5).
 *
 * Bluetooth (bt.c): F3 opens the Bluetooth audio menu (scan, connect, PIN,
 * volume) for the ESP32 bridge; the tape goes on playing meanwhile.
 *
 * Snapshots (snap.c): F2 stops the Spectrum and asks for a name; the whole
 * machine is saved as NAME.Z80 in the browser's current folder (the root after
 * power-up), then it runs on. Choosing a .z80 file in the browser loads it.
 * L64 (c64.c): the same with NAME.A64.
 *
 * Print Screen saves the picture as SCRNnnnn.BMP (16 colours, shot.c) in the browser's
 * current folder: the Spectrum's screen with the border (snap.c), L64's frame buffer
 * (LTari: its frame buffer, 256 colours, atari.c).
 *
 * LTari (Atari 800XL / 130XE): the browser lists .xex / .atr / .car files; an .atr goes
 * into the SIO disk drive D1: (atari.c) and the Atari cold-starts from it; an .xex is served as a
 * boot disk with our loader; a .car (standard 8 / 16 KB, Atarimax) plugs in as a cartridge.
 * Shift + Enter on an .atr only changes the disk (the Atari runs on). The F3 and F4 menus work
 * (F4: which DB9 port is stick 0); Print Screen saves a 256-colour BMP; F2 saves a snapshot
 * NAME.A8S, loaded again from the browser; saving to tape is not used.
 *
 * Runs as a task on the ESP32 (esp_hw.cpp); KEY0 resets the FPGA's loader
 * hardware and the ESP32 then restarts, so all state starts from zero again.
 */
#include <stdlib.h>
#include "hw.h"
#include "hal.h"
#include "fat.h"
#include "tape.h"
#include "sd.h"
#include "osd.h"
#include "util.h"
#include "save.h"
#include "snap.h"
#include "update.h"
#include "espupd.h"
#include "bt.h"
#include "c64.h"
#include "shot.h"
#include "atari.h"
#include "reset.h"

#define MAXE       4096                /* entries per folder, in the PSRAM (40 bytes each: 160 KB) */
#define MAXE_IRAM  320                 /* without PSRAM: internal RAM (12.8 KB) */
#define LIST_ROW   2
#define LIST_LINES 20
#define REP_DELAY  (400 * CLK_PER_MS)
#define REP_RATE   (60 * CLK_PER_MS)

#define ENT_NAME   NAME_MAX            /* the whole name fat.c delivers */

typedef struct {
    uint32_t clus;
    uint32_t size : 22, dir : 1, tzx : 1, z80 : 1, prg : 1, t64 : 1, d64 : 1, ro : 1, xa : 1, atr : 1, xex : 1;   /* one word */
    char     name[ENT_NAME + 1];
} ENT;

enum { P_IDLE, P_RUN, P_DRAIN, P_STOPPED, P_PAUSED, P_END, P_ERR };

static ENT     *ent;                        /* ent_max entries, allocated once (list_alloc) */
static int      ent_max;
static int      nent, cur, top, truncated, mounted, menu, closing, list_folders, list_stale, bt_on, joy_on, joy_cur;
static uint32_t dir_clus;
static char     path[64];
static char     came_from[NAME_MAX + 1];

static FFILE    tf;
static int      p_state, p_tzx, p_stop;
static uint32_t p_block;
static char     p_name[NAME_MAX + 1];

static uint32_t kprev, t_rep;
static char     err_line[33];
static uint32_t speed_t;                    /* "Speed: ..." shown until then */
static char     note_line[33];
static uint32_t note_t;                     /* note_line shown until then */

#define TURBO_BIT (slow_mode ? 0u : TAPE_TURBO)
static int speed_text(char *s);
static int note_text(char *s);

/*----------------------------------------------------------------------------
 * platform functions for fat.c / tape.c
 *--------------------------------------------------------------------------*/
uint32_t fifo_free(void)        { return FIFO_DEPTH - (FIFO & 0x3FFu); }

/*----------------------------------------------------------------------------
 * keys: new presses, with auto-repeat for the movement keys
 *--------------------------------------------------------------------------*/
static uint32_t key_events(void)
{
    const uint32_t rep_keys = K_UP | K_DOWN | K_LEFT | K_RIGHT | K_PGUP | K_PGDN;
    uint32_t now = KEYS;
    uint32_t ev;
    if (now == 0xFFFFFFFFu) return 0;                       /* a gone FPGA (reconfiguring) reads all ones */
    ev = now & ~kprev;

    if (ev & rep_keys)
        t_rep = TIMER + REP_DELAY;
    else if ((now & rep_keys) && (int32_t)(TIMER - t_rep) >= 0) {
        ev |= now & rep_keys;
        t_rep = TIMER + REP_RATE;
    }
    kprev = now;
    return ev;
}

/*----------------------------------------------------------------------------
 * directory list
 *--------------------------------------------------------------------------*/
static int ent_less(const ENT *a, const ENT *b)
{
    if (a->name[0] == '.' && a->name[1] == '.') return 1;   /* ".." first */
    if (b->name[0] == '.' && b->name[1] == '.') return 0;
    if (a->dir != b->dir) return a->dir;                    /* folders before files */
    return u_stricmp(a->name, b->name) < 0;
}

static int list_cb(const DIRENT *d, void *ctx)
{
    ENT *e;
    int  is_dir = (d->attr & ATTR_DIR) != 0;
    int  tap    = !machine_atari && u_stricmp(d->ext, "TAP") == 0;
    int  tzx    = !machine_c64 && !machine_atari && u_stricmp(d->ext, "TZX") == 0;
    int  z80    = u_stricmp(d->ext, machine_c64 ? "A64" : machine_atari ? "A8S" : "Z80") == 0;   /* snapshot */
    int  atr    = machine_atari && u_stricmp(d->ext, "ATR") == 0;              /* LTari: disk */
    int  xex    = machine_atari && (u_stricmp(d->ext, "XEX") == 0 || u_stricmp(d->ext, "COM") == 0);   /* .com: same format */
    int  xa     = xex || (machine_atari && u_stricmp(d->ext, "CAR") == 0);
    int  prg    = machine_c64 && u_stricmp(d->ext, "PRG") == 0;   /* L64: .prg, .t64, C64 .tap */
    int  t64    = machine_c64 && u_stricmp(d->ext, "T64") == 0;
    int  d64    = machine_c64 && u_stricmp(d->ext, "D64") == 0;
    (void)ctx;

    if (d->name[0] == '.' && d->name[1] == 0) return 0;     /* "." */
    if (d->attr & (ATTR_HIDDEN | ATTR_SYSTEM)) return 0;
    if (!is_dir && (list_folders || (!tap && !tzx && !z80 && !prg && !t64 && !d64 && !xa && !atr))) return 0;
    if (!is_dir && d->size >= (1u << 22)) return 0;           /* > 4 MB: no file type we load (and ENT.size) */
    if (nent == ent_max) { truncated = 1; return 1; }
    e = &ent[nent++];
    e->clus = d->clus;
    e->size = d->size;
    e->dir  = (unsigned)is_dir;
    e->tzx  = (unsigned)tzx;
    e->z80  = (unsigned)z80;
    e->prg  = (unsigned)prg;
    e->t64  = (unsigned)t64;
    e->d64  = (unsigned)d64;
    e->xa   = (unsigned)xa;
    e->atr  = (unsigned)atr;
    e->xex  = (unsigned)xex;
    e->ro   = (d->attr & ATTR_RO) != 0;
    u_strncpy(e->name, d->name, ENT_NAME);
    return 0;
}

/* the list's memory, on first use: PSRAM, else (no PSRAM found) the internal heap */
static void list_alloc(void)
{
    if (ent) return;
    if ((ent = (ENT *)ext_alloc(MAXE * (uint32_t)sizeof(ENT))) != 0) { ent_max = MAXE; return; }
    if ((ent = (ENT *)malloc(MAXE_IRAM * sizeof(ENT))) != 0) ent_max = MAXE_IRAM;
}

/* folder list into ent[], sorted; folders_only for the save dialog */
static int load_list(uint32_t clus, int folders_only)
{
    int i, j, gap;
    ENT t;

    list_alloc();
    nent = 0;
    truncated = 0;
    cur = top = 0;
    list_folders = folders_only;
    if (fat_list(clus, list_cb, 0) != FAT_OK) { mounted = 0; nent = 0; return -1; }
    for (gap = 1; gap < nent / 3; gap = 3 * gap + 1) ;      /* shell sort, gaps 1, 4, 13, 40, ... (Knuth) */
    for (; gap > 0; gap /= 3)
        for (i = gap; i < nent; i++) {
            u_memcpy(&t, &ent[i], sizeof t);
            for (j = i; j >= gap && ent_less(&t, &ent[j - gap]); j -= gap)
                u_memcpy(&ent[j], &ent[j - gap], sizeof t);
            u_memcpy(&ent[j], &t, sizeof t);
        }
    return 0;
}

/* browser list: item 0 is [Save to this folder], items 1.. are ent[0..];
 * the cursor starts on the first file or folder */
static int load_dir(uint32_t clus)
{
    if (load_list(clus, 0) != 0) return -1;
    dir_clus = clus;
    list_stale = 0;
    cur = nent ? 1 : 0;
    return 0;
}

static void mount_card(void)
{
    mounted = 0;
    if (sd_init() != 0 || fat_mount() != FAT_OK) return;
    mounted = 1;
    path[0] = '/';
    path[1] = 0;
    load_dir(0);
}

/*----------------------------------------------------------------------------
 * player
 *--------------------------------------------------------------------------*/
static void play_from(uint32_t block)
{
    TAPE = TAPE_ON | TURBO_BIT | TAPE_FLUSH;
    if (machine_c64) c64tap_start(&tf);                     /* C64 .tap: always from the start */
    else             tape_start(&tf, p_tzx, block);
    p_state = P_RUN;
}

static void player_open(const ENT *e)
{
    ff_open(&tf, e->clus, e->size);
    p_tzx = e->tzx;
    u_strncpy(p_name, e->name, NAME_MAX);
    play_from(0);
}

static void player_pause(void)
{
    if (p_state == P_RUN || p_state == P_DRAIN) {
        p_block = MARKER & 0xFFFFu;
        TAPE = TAPE_FLUSH;
        p_state = P_PAUSED;
    } else if (p_state == P_PAUSED) {
        play_from(p_block);
    } else if (p_state == P_STOPPED) {
        TAPE = TAPE_ON | TURBO_BIT;
        tape_continue();
        p_state = P_RUN;
    }
}

static void player_stop(void)
{
    TAPE = TAPE_FLUSH;                                      /* EAR back to the beeper, turbo off, FIFO empty */
    p_state = P_IDLE;
}

static void player_rewind(void)
{
    uint32_t b;
    if (p_state == P_RUN || p_state == P_DRAIN || p_state == P_STOPPED) {
        b = MARKER & 0xFFFFu;
        play_from(b ? b - 1 : 0);
    } else if (p_state == P_PAUSED) {
        if (p_block) p_block--;
    }
}

static void player_service(void)
{
    int r;
    if (p_state == P_RUN) {
        r = machine_c64 ? c64tap_pump() : tape_pump();
        if (r == TS_ERR) { TAPE = TAPE_FLUSH; p_state = P_ERR; }
        else if (r != TS_RUN) { p_stop = (r == TS_STOP); p_state = P_DRAIN; }
    } else if (p_state == P_DRAIN && (FIFO & FIFO_IDLE)) {
        TAPE = 0;                                           /* EAR back to the tape input, turbo off */
        p_state = p_stop ? P_STOPPED : P_END;
    }
}

/* status line; returns 0 if there is nothing to say */
static int status_text(char *s)
{
    char *p = s;
    uint32_t b = MARKER & 0xFFFFu;
    switch (p_state) {
    case P_RUN: case P_DRAIN:
        p = u_strcpy(p, "Playing block "); p = u_utoa(p, b); break;
    case P_PAUSED:
        p = u_strcpy(p, "Paused, block "); p = u_utoa(p, p_block); p = u_strcpy(p, " (5=go)"); break;
    case P_STOPPED:
        p = u_strcpy(p, "Tape stopped (5=go on)"); break;
    case P_END:
        p = u_strcpy(p, "End of tape"); break;
    case P_ERR:
        p = u_strcpy(p, "Bad file or read error"); break;
    default:
        *p = 0; return 0;
    }
    *p = 0;
    return 1;
}

/*----------------------------------------------------------------------------
 * screen
 *--------------------------------------------------------------------------*/
static void draw_menu(void)
{
    char line[48];
    int  i, n;

    osd_text(0, 0, machine_c64 ? " L64 loader" : machine_atari ? " LTari loader" : " LSpectrum tape loader", OSD_COLS, 1);
    n = u_strlen(path);
    osd_text(1, 0, n > OSD_COLS ? path + n - OSD_COLS : path, OSD_COLS, 0);
    for (i = 0; i < LIST_LINES; i++) {
        int k = top + i;
        line[0] = 0;
        if (mounted && k == 0)
            u_strcpy(line, " [Save to this folder]");
        else if (mounted && k <= nent) {
            char *p = line;
            *p++ = ' ';
            p = u_strcpy(p, ent[k - 1].name);
            if (ent[k - 1].dir) *p++ = '/';
            *p = 0;
        }
        osd_text(LIST_ROW + i, 0, line, OSD_COLS, mounted && k <= nent && k == cur);
    }
    if (!mounted) {
        osd_text(LIST_ROW + 1, 0, " No SD card, or not FAT16/FAT32", OSD_COLS, 0);
        osd_text(LIST_ROW + 3, 0, " Enter = try again", OSD_COLS, 0);
    } else if (nent == 0)
        osd_text(LIST_ROW + 2, 0, machine_c64 ? " (no .prg/.t64/.tap/.d64/.a64)" : machine_atari ? " (no .xex/.com/.atr/.car/.a8s)"
                                                                       : " (no .tap/.tzx/.z80 files here)", OSD_COLS, 0);
    else if (truncated) {
        u_strcpy(u_utoa(u_strcpy(line, " (only the first "), (uint32_t)ent_max), " entries)");
        osd_text(LIST_ROW + LIST_LINES - 1, 0, line, OSD_COLS, 0);
    }
    if (!speed_text(line) && !note_text(line) && !status_text(line)) u_strcpy(line, err_line);
    osd_text(22, 0, line, OSD_COLS, 0);
    osd_text(23, 0, machine_atari ? "Ent=load Shift+Ent=swap disk"      /* .atr: Enter asks F1 no BASIC / F2 BASIC */
                                  : "Ent=load Esc=up 5=stop F12=exit", OSD_COLS, 1);
}

/* browser closed: show the bottom status row only while the tape waits for the user */
/* F6: toggle the speed; a playing tape or a block being saved changes at once
   (L64: the FPGA runs turbo while a motor runs, if MCTL allows it) */
static void speed_toggle(void)
{
    if (machine_atari) return;                              /* LTari: no turbo yet */
    slow_mode = !slow_mode;
    if (machine_c64)
        c64_speed();
    else {
        if (p_state == P_RUN || p_state == P_DRAIN)
            TAPE = TAPE_ON | TURBO_BIT;
        rec_speed();
    }
    speed_t = TIMER + 2000 * CLK_PER_MS;
}

/* a message for 4 s (bottom row, or line 22 of the browser) */
static void note(const char *a, const char *b)
{
    char *p = u_strncpy(note_line, a, 32);
    u_strncpy(p, b, 32 - (int)(p - note_line));
    note_t = TIMER + 4000 * CLK_PER_MS;
}

static int note_text(char *s)
{
    if (!note_t) return 0;
    if ((int32_t)(TIMER - note_t) >= 0) { note_t = 0; return 0; }
    u_strcpy(s, note_line);
    return 1;
}

static int speed_text(char *s)
{
    if (!speed_t) return 0;
    if ((int32_t)(TIMER - speed_t) >= 0) { speed_t = 0; return 0; }
    u_strcpy(s, slow_mode ? "Speed: normal" : "Speed: turbo");
    return 1;
}

static void draw_bar(void)
{
    char line[48];
    if (speed_text(line) || note_text(line) || (machine_c64 ? c64rec_status(line) : rec_status(line)) ||
        ((p_state == P_PAUSED || p_state == P_STOPPED || p_state == P_ERR) && status_text(line))) {
        osd_text(23, 0, line, OSD_COLS, 1);
        osd_show(0);
    } else
        osd_hide();
}

static void menu_open(void)
{
    menu = 1;
    if (!mounted) mount_card();
    else if (list_stale) load_dir(dir_clus);
    osd_clear();
    osd_show(1);
}

/* The browser goes away only when the key that closed it is released: the
 * Spectrum keyboard is unblocked at that moment and must not see Enter or
 * Esc (BREAK). */
#define CLOSE_KEYS (K_ENTER | K_F11 | K_MENU | K_BACK)

static void menu_close(void)
{
    closing = 1;
}

/* path ("/a/b/") after entering folder e; returns 1 if it was "..", with the folder left in from */
static int path_step(char *pth, int size, const ENT *e, char *from)
{
    int i, n;
    if (e->name[0] == '.' && e->name[1] == '.') {
        n = u_strlen(pth) - 1;                              /* path ends with '/' */
        for (i = n - 1; i > 0 && pth[i - 1] != '/'; i--) ;
        u_strncpy(from, pth + i, n - i);
        pth[i] = 0;
        return 1;
    }
    from[0] = 0;
    if (u_strlen(pth) + u_strlen(e->name) + 2 < size) {
        char *p = pth + u_strlen(pth);
        p = u_strcpy(p, e->name);
        p[0] = '/';
        p[1] = 0;
    }
    return 0;
}

static void enter_dir(const ENT *e)
{
    uint32_t clus = e->clus;
    int      i;

    path_step(path, (int)sizeof path, e, came_from);
    if (load_dir(clus) != 0) return;
    for (i = 0; came_from[0] && i < nent; i++)              /* cursor on the folder we left */
        if (u_stricmp(ent[i].name, came_from) == 0) {
            cur = i + 1;
            top = cur >= LIST_LINES ? cur - LIST_LINES / 2 : 0;
            break;
        }
}

static void move_in(int d, int count, int lines)
{
    if (!count) return;
    cur += d;
    if (cur < 0) cur = 0;
    if (cur >= count) cur = count - 1;
    if (cur < top) top = cur;
    if (cur >= top + lines) top = cur - lines + 1;
}

static void move(int d) { move_in(d, nent + 1, LIST_LINES); }

static int  name_prompt(char n11[11], int snap);
static void snap_save_ui(void);

/* 8.3 name for messages */
static void name83(char *d, const char n11[11])
{
    int i;
    for (i = 0; i < 8 && n11[i] != ' '; i++) *d++ = n11[i];
    *d++ = '.';
    for (i = 8; i < 11 && n11[i] != ' '; i++) *d++ = n11[i];
    *d = 0;
}

static void snap_open(const ENT *e)
{
    int r;
    if (p_state != P_IDLE) player_stop();               /* the tape belongs to the old program */
    ff_open(&tf, e->clus, e->size);
    r = snap_load(&tf);
    if (r == 0)               note("Loaded ", e->name);
    else if (r == SNAP_ERUN)  note("Spectrum not running", "");
    else if (r == SNAP_EBAD)  note("Not a usable .z80: ", e->name);
    else                      note("Card error", "");
}

static void a8s_open(const ENT *e)
{
    char nm[33];
    int  r;
    ff_open(&tf, e->clus, e->size);
    r = at_snap_load(&tf, nm);
    if (r == 0 && nm[0])       note("Loaded; disk was ", nm);    /* Shift+Enter on that .atr */
    else if (r == 0)           note("Loaded ", e->name);
    else if (r == AT_ERUN)     note("Atari not running", "");
    else if (r == AT_EMODEL)   note("Snapshot of the other model", "");
    else if (r == AT_ECART)    note("Load cartridge first: ", nm);
    else if (r == AT_EBAD)     note("Not a usable .a8s: ", e->name);
    else                       note("Card error", "");
}

static void a64_open(const ENT *e)
{
    int r;
    if (p_state != P_IDLE) player_stop();
    ff_open(&tf, e->clus, e->size);
    r = c64_snap_load(&tf);
    if (r == 0)              note("Loaded ", e->name);
    else if (r == C64_ERUN)  note("C64 not running", "");
    else if (r == C64_EBAD)  note("Not a usable .a64: ", e->name);
    else                     note("Card error", "");
}

static void prg_open(const ENT *e)
{
    char info[16];
    int  r;
    if (p_state != P_IDLE) player_stop();
    ff_open(&tf, e->clus, e->size);
    r = c64_prg_load(&tf, e->t64, info);
    if (r == 0)              note("Loaded ", info);
    else if (r == C64_ERUN)  note("C64 not running", "");
    else if (r == C64_EBAD)  note("Not a usable file: ", e->name);
    else                     note("Card error", "");
}

static void rom_progress(const char *t)
{
    osd_text(3, 0, "", OSD_COLS, 0);
    osd_text(3, 1, t, OSD_COLS - 1, 0);
}

/* L64 start: no ROMs in flash, or no 1541 ROM there while the card has one -> install them
 * from /ROMS/C64/ on the card; a flash or card error is retried twice, then (and when the files
 * are missing) F12 tries again */
static void c64_roms(void)
{
    int r, n, have;
    uint32_t t0 = TIMER;
    while (TIMER - t0 < 300 * CLK_PER_MS) ;                 /* the FPGA's ROM load is over (the pins are its until then) */
    have = c64_rom_present();
    if (have == 2 || (have == 1 && !(mounted && c64_rom_card_1541()))) return;
    for (;;) {
        osd_clear();
        osd_text(0, 0, " L64: C64 ROMs", OSD_COLS, 1);
        osd_text(1, 0, have == 1 ? " Adding the 1541 ROM to the flash." : " No ROMs in the flash yet.", OSD_COLS, 0);
        osd_show(1);
        for (n = 0; n < 3; n++) {
            r = mounted ? c64_rom_install(rom_progress) : C64_ENOROM;
            if (r == 0) {
                note("C64 ROMs installed", "");
                osd_clear();
                osd_hide();
                return;
            }
            if (r == C64_ENOROM) break;
        }
        if (have == 1) {                                    /* the C64 ROMs are there: run without the drive */
            note("1541 ROM not added", "");
            osd_clear();
            osd_hide();
            return;
        }
        osd_text(3, 0, r == C64_ENOROM ? " Put KERNAL*, BASIC*, CHAR* files" :
                       r == C64_EFLASH ? " Flash write failed" : " Card error", OSD_COLS, 0);
        osd_text(4, 0, r == C64_ENOROM ? " (8, 8, 4 KB) in /ROMS/C64/ on" : "", OSD_COLS, 0);
        osd_text(5, 0, r == C64_ENOROM ? " the SD card (DOS1541* 16 KB for" : "", OSD_COLS, 0);
        osd_text(6, 0, r == C64_ENOROM ? " the disk drive)." : "", OSD_COLS, 0);
        osd_text(8, 0, " F12: try again", OSD_COLS, 0);
        osd_text(23, 0, "", OSD_COLS, 1);
        while (KEYS & K_MENU) ;
        while (!(KEYS & K_MENU)) ;                          /* KEY0 / KEY1: the link check restarts the ESP32 */
        while (KEYS & K_MENU) ;
        mount_card();                                       /* the card may have been changed */
    }
}

static void bt_menu(void)
{
    menu = 0;
    bt_on = 1;
    bt_open();
}

/*----------------------------------------------------------------------------
 * F4: joystick menu (the mode is INTPOS[29:28], rtl/zx_system.v)
 *--------------------------------------------------------------------------*/
static const char *const joy_name_zx[3]  = { "Kempston", "Kempston + Cursor", "Interface 2" };
static const char *const joy_name_c64[3] = { "DB9-1 = port 2", "DB9-1 = port 1", "Both = port 2" };
static const char *const joy_name_at[3]  = { "DB9-1 = stick 0", "DB9-1 = stick 1", "" };
#define joy_name (machine_c64 ? joy_name_c64 : machine_atari ? joy_name_at : joy_name_zx)
#define joy_modes (machine_atari ? 2 : 3)

static void joy_menu(void)
{
    menu = 0;
    joy_on = 1;
    joy_cur = (int)((INTPOS & INT_JOY) >> INT_JOY_SH);
    if (joy_cur >= joy_modes) joy_cur = 0;
    osd_clear();
    osd_show(1);
}

/* 0 = close */
static int joy_keys(uint32_t k)
{
    if (k & (K_JOY | K_BACK | K_MENU)) return 0;
    if ((k & K_UP) && joy_cur > 0)   joy_cur--;
    if ((k & K_DOWN) && joy_cur < joy_modes - 1) joy_cur++;
    if (k & (K_ENTER | K_F11)) {
        INTPOS = (INTPOS & ~INT_JOY) | (uint32_t)joy_cur << INT_JOY_SH;
        note("Joystick: ", joy_name[joy_cur]);
        return 0;
    }
    return 1;
}

static void joy_draw(void)
{
    static const char *const port_zx[3][2] = {
        { " DB9-1: Kempston",              " DB9-2: Kempston (same)" },
        { " DB9-1: Kempston",              " DB9-2: Cursor (5 6 7 8, 0)" },
        { " DB9-1: Sinclair 1 (6-9, 0)",   " DB9-2: Sinclair 2 (1-4, 5)" },
    };
    static const char *const port_c64[3][2] = {
        { " DB9-1: control port 2",        " DB9-2: control port 1" },
        { " DB9-1: control port 1",        " DB9-2: control port 2" },
        { " DB9-1 and DB9-2: port 2",      " (port 1 unused)" },
    };
    static const char *const port_at[3][2] = {
        { " DB9-1: stick 0 (player 1)",    " DB9-2: stick 1" },
        { " DB9-1: stick 1",               " DB9-2: stick 0 (player 1)" },
        { "", "" },
    };
    const char *const (*port)[2] = machine_c64 ? port_c64 : machine_atari ? port_at : port_zx;
    char l[48];
    int  i, now = (int)((INTPOS & INT_JOY) >> INT_JOY_SH);

    osd_text(0, 0, " Joysticks", OSD_COLS, 1);
    osd_text(1, 0, "", OSD_COLS, 0);
    for (i = 0; i < 3; i++) {
        char *p = u_strcpy(l, i == now ? " * " : "   ");
        u_strcpy(p, joy_name[i]);
        osd_text(2 + i, 0, i < joy_modes ? l : "", OSD_COLS, i == joy_cur);
    }
    osd_text(5, 0, "", OSD_COLS, 0);
    osd_text(6, 0, port[joy_cur][0], OSD_COLS, 0);
    osd_text(7, 0, port[joy_cur][1], OSD_COLS, 0);
    osd_text(23, 0, "Enter=select  F4/Esc=exit", OSD_COLS, 1);
}

/* LTari, booting an .atr (an .xex decides itself: our loader switches BASIC off): three lines on the OSD, F1 = no BASIC (OPTION held at the
 * cold start), F2 = with BASIC (as a real XL); 0 / 1, -1 = Esc (nothing loaded) */
static int basic_prompt(void)
{
    uint8_t  ev[3], mods;
    uint32_t r, r2;
    int      i, n, a = -2;
    raw_events(ev, &mods);                                  /* keys already held do not count */
    osd_clear();
    osd_text(10, 0, " How do you want to load it:", OSD_COLS, 1);
    osd_text(11, 0, "   <F1> No BASIC", OSD_COLS, 1);
    osd_text(12, 0, "   <F2> with BASIC", OSD_COLS, 1);
    while (a == -2) {
        n = raw_events(ev, &mods);
        for (i = 0; i < n && a == -2; i++)
            a = ev[i] == 0x3A ? 0 : ev[i] == 0x3B ? 1 : ev[i] == 0x29 ? -1 : -2;   /* F1, F2, Esc */
    }
    do {                                                    /* released first: F2 is also the snapshot key */
        do { r = KEYRAW; r2 = KEYRAW; } while (r != r2);
        for (i = 0, n = 0; i < 3; i++) {
            uint8_t c = (uint8_t)(r >> (8 * i));
            if (c == 0x3A || c == 0x3B || c == 0x29) n = 1;
        }
    } while (n);
    raw_events(ev, &mods);
    osd_clear();
    return a;
}

static void menu_keys(uint32_t k)
{
    if (k & K_MENU) { menu_close(); return; }
    if (k & K_BT)   { bt_menu(); return; }
    if (k & K_JOY)  { joy_menu(); return; }
    if (!mounted) {
        if (k & (K_ENTER | K_F11)) mount_card();
        if (k & K_BACK) menu_close();
        return;
    }
    if (k & K_UP)    move(-1);
    if (k & K_DOWN)  move(1);
    if (k & (K_LEFT | K_PGUP))  move(-LIST_LINES);
    if (k & (K_RIGHT | K_PGDN)) move(LIST_LINES);
    if (k & (K_ENTER | K_F11)) {
        if (cur == 0) {                                     /* [Save to this folder] */
            char n11[11];
            int  r;
            if (machine_atari) { note("No tape saving on LTari", ""); return; }
            if (!name_prompt(n11, 0)) return;
            if (p_state != P_IDLE) player_stop();
            r = machine_c64 ? c64rec_start(dir_clus, n11) : rec_start(dir_clus, n11);
            list_stale = 1;
            if (r == FAT_OK) { menu_close(); return; }
            u_strcpy(err_line, r == FAT_EFULL ? "Card or folder full" : "Card error");
            return;
        }
        if (cur <= nent) {
            const ENT *e = &ent[cur - 1];
            if (e->dir) enter_dir(e);
            else if (e->xa) {                                            /* LTari: .xex runs, .car plugs in */
                FFILE xf;
                int   r;
                ff_open(&xf, e->clus, e->size);
                r = e->xex ? at_xex_mount(&xf, e->name) : at_car_mount(&xf, e->name);
                if (r == 0)             note(e->xex ? "Run: " : "Cartridge: ", e->name);
                else if (r == AT_EBAD)  note("Not usable: ", e->name);
                else if (r == AT_ETYPE) note("Cart type not yet: ", e->name);
                else                    note("Card error", "");
                menu_close();
                return;
            }
            else if (e->atr) {                                           /* LTari: D1:, boot from it */
                FFILE    af;
                int      r, swap, b = 1;
                uint32_t kr, kr2;
                do { kr = KEYRAW; kr2 = KEYRAW; } while (kr != kr2);
                swap = (kr >> 24) & 0x22;                                /* Shift + Enter: change the disk only */
                if (!swap && (b = basic_prompt()) < 0) return;           /* Esc: back to the browser */
                ff_open(&af, e->clus, e->size);
                r = at_atr_mount(&af, e->name, e->ro, !swap, b);
                if (r == 0)             note(swap ? "Disk changed, D1: " : "D1: ", e->name);
                else if (r == AT_EBAD)  note("Not an .atr: ", e->name);
                else                    note("Card error", "");
                menu_close();
                return;
            }
            else if (e->z80) {
                if (machine_c64) a64_open(e); else if (machine_atari) a8s_open(e); else snap_open(e);
                menu_close();
                return;
            }
            else if (e->prg || e->t64) { prg_open(e); menu_close(); return; }
            else if (e->d64) {
                FFILE df;
                int   r;
                ff_open(&df, e->clus, e->size);
                r = c64_d64_mount(&df, e->name, e->ro);
                if (r == 0)              note("Disk 8: ", e->name);
                else if (r == C64_EBAD)  note("Not a .d64: ", e->name);
                else                     note("Card error", "");
                menu_close();
                return;
            }
            else { player_open(e); menu_close(); return; }
        }
    }
    if (k & K_BACK) {
        if (nent && ent[0].dir && ent[0].name[0] == '.' && ent[0].name[1] == '.')
            enter_dir(&ent[0]);
        else
            menu_close();
    }
    if (k & K_KP5)   player_pause();
    if (k & K_REW)   player_rewind();
    if (k & K_STOP)  player_stop();
    if (k & K_SPEED) speed_toggle();
    if (k & K_SNAP)  { snap_save_ui(); menu_close(); }
}

static void play_keys(uint32_t k)
{
    if (k & K_SPEED) speed_toggle();
    if (machine_c64 ? c64rec_active() : rec_active()) {    /* recording: F12 (or F7) stops it */
        if (k & (K_MENU | K_STOP)) { if (machine_c64) c64rec_end(); else rec_end(); }
        if (k & K_SNAP) note("Recording: F12 first", "");
        return;
    }
    if (k & K_SNAP) { snap_save_ui(); return; }
    if ((k & K_CONT) && machine_atari) return;              /* LTari: F5 not used */
    if ((k & K_CONT) && machine_c64) {                      /* L64: SID 6581 / 8580 */
        INTPOS ^= INT_SID8580;
        note("SID: ", (INTPOS & INT_SID8580) ? "8580" : "6581");
        return;
    }
    if (k & K_CONT) {                                       /* contention on / off */
        INTPOS ^= INT_NOCONT;
        note("Contention: ", (INTPOS & INT_NOCONT) ? "off" : "on");
        return;
    }
    if ((k & (K_PGUP | K_PGDN)) && !machine_c64 && !machine_atari) {   /* frame interrupt position (ZX only) */
        char t[12], *q;
        uint32_t r = INTPOS, p = (r & 0x3FFu) * 864u + (r >> 16 & 0x3FFu);   /* pixels after vsync */
        if ((k & K_PGUP) && p >= 108)        p -= 108;
        if ((k & K_PGDN) && p < 620u * 864u) p += 108;
        INTPOS = (r & (INT_NOCONT | INT_JOY)) | (p % 864u) << 16 | p / 864u;
        q = u_utoa(t, p / 864u);
        *q++ = '.';
        u_utoa(q, p % 864u / 108u);
        note("Frame INT: line ", t);
        return;
    }
    if (k & K_MENU) { err_line[0] = 0; menu_open(); return; }
    if (k & K_BT)   { bt_menu(); return; }
    if (k & K_JOY)  { joy_menu(); return; }
    if (k & (K_F11 | K_KP5)) player_pause();
    if (k & K_REW)  player_rewind();
    if (k & K_STOP) player_stop();
}

/*----------------------------------------------------------------------------
 * name for a recording (modal, browser open)
 *--------------------------------------------------------------------------*/
static uint8_t rprev[3];

/* new key presses from the raw keyboard report (USB HID codes); returns the count */
int raw_events(uint8_t ev[3], uint8_t *mods)
{
    uint32_t r, r2;
    uint8_t  now[3];
    int      i, j, n = 0;
    do { r = KEYRAW; r2 = KEYRAW; } while (r != r2);       /* 32 bits from another clock domain */
    now[0] = (uint8_t)(r >> 16); now[1] = (uint8_t)(r >> 8); now[2] = (uint8_t)r;
    *mods = (uint8_t)(r >> 24);
    for (i = 0; i < 3; i++) {
        if (!now[i]) continue;
        for (j = 0; j < 3 && rprev[j] != now[i]; j++) ;
        if (j == 3) ev[n++] = now[i];
    }
    for (i = 0; i < 3; i++) rprev[i] = now[i];
    return n;
}

char key_char(uint8_t c, uint8_t mods)
{
    if (c >= 0x04 && c <= 0x1D) return (char)('A' + c - 0x04);
    if (c >= 0x1E && c <= 0x26) return (char)('1' + c - 0x1E);
    if (c == 0x27 || c == 0x62) return '0';
    if (c >= 0x59 && c <= 0x61) return (char)('1' + c - 0x59);
    if (c == 0x2D) return (mods & 0x22) ? '_' : '-';
    if (c == 0x56) return '-';
    return 0;
}

/* asks for an 8.3 name for a new file in the current folder: a .TAP for recording
 * (proposes the first free SAVEnnnn) or, if snap, a snapshot (.Z80, L64 .A64; no
 * proposal); 1 = name in n11, 0 = Esc */
static int name_prompt(char n11[11], int snap)
{
    const char *ext = !snap ? "TAP" : machine_c64 ? "A64" : machine_atari ? "A8S" : "Z80";
    char    name[12], line[48], msg[33];
    int     len = 0, i, k, n, r;
    uint8_t ev[3], mods, c;

    name[0] = 0;
    for (k = 1; !snap && k < 10000; k++) {                  /* default: first free SAVEnnnn */
        name[0] = 'S'; name[1] = 'A'; name[2] = 'V'; name[3] = 'E';
        name[4] = (char)('0' + k / 1000); name[5] = (char)('0' + k / 100 % 10);
        name[6] = (char)('0' + k / 10 % 10); name[7] = (char)('0' + k % 10); name[8] = 0;
        for (i = 0; i < 8; i++) n11[i] = name[i];
        n11[8] = 'T'; n11[9] = 'A'; n11[10] = 'P';
        len = 8;
        if (fat_exists(dir_clus, n11) == 0) break;
    }
    msg[0] = 0;
    raw_events(ev, &mods);                                  /* keys already held do not count */
    osd_clear();
    for (;;) {
        osd_text(0, 0, !snap ? " Save to SD card" : machine_c64 ? " Save snapshot (.a64)" : machine_atari ? " Save snapshot (.a8s)"
                                                                                       : " Save snapshot (.z80)", OSD_COLS, 1);
        n = u_strlen(path);
        osd_text(1, 0, n > OSD_COLS ? path + n - OSD_COLS : path, OSD_COLS, 0);
        {
            char *p = u_strcpy(line, " Name: ");
            p = u_strcpy(p, name);
            p = u_strcpy(p, "_.");
            u_strcpy(p, ext);
        }
        osd_text(3, 0, line, OSD_COLS, 0);
        if (snap) {
            osd_text(5, 0, machine_c64 ? " The C64 is stopped. The" : machine_atari ? " The Atari is stopped. The"
                                                                    : " The Spectrum is stopped. The", OSD_COLS, 0);
            osd_text(6, 0, " whole machine is saved; load", OSD_COLS, 0);
            osd_text(7, 0, " it again from the browser.", OSD_COLS, 0);
            osd_text(8, 0, "", OSD_COLS, 0);
        } else {
            osd_text(5, 0, " After Enter, save on the", OSD_COLS, 0);
            osd_text(6, 0, machine_c64 ? " C64 as often as you like;" : " Spectrum as often as you like;", OSD_COLS, 0);
            osd_text(7, 0, " all blocks go into this file.", OSD_COLS, 0);
            osd_text(8, 0, " F12 stops recording.", OSD_COLS, 0);
        }
        osd_text(22, 0, msg, OSD_COLS, 0);
        osd_text(23, 0, snap ? "Type name, Ent=save, Esc=cancel" : "Type name, Ent=start, Esc=back", OSD_COLS, 1);
        do n = raw_events(ev, &mods); while (!n);
        for (i = 0; i < n; i++) {
            c = ev[i];
            if (c == 0x29) { osd_clear(); return 0; }       /* Esc */
            {
                char ch = key_char(c, mods);
                if (ch && len < 8) { name[len++] = ch; name[len] = 0; msg[0] = 0; }
            }
            if (c == 0x2A && len) name[--len] = 0;          /* Backspace */
            if ((c == 0x28 || c == 0x58) && len) {          /* Enter */
                for (k = 0; k < 8; k++) n11[k] = k < len ? name[k] : ' ';
                n11[8] = ext[0]; n11[9] = ext[1]; n11[10] = ext[2];
                r = fat_exists(dir_clus, n11);
                if (r > 0) { u_strcpy(msg, " Already exists: another name"); continue; }
                if (r < 0) { u_strcpy(msg, " Card error"); continue; }
                osd_clear();
                return 1;
            }
        }
    }
}

/* Print Screen: the picture as SCRNnnnn.BMP in the browser's current folder (no OSD in it) */
static void screenshot(void)
{
    char n11[11], fname[13];
    int  r;
    if (!mounted) mount_card();
    if (!mounted) { note("No SD card", ""); return; }
    if (machine_c64 ? c64rec_active() : rec_active()) { note("Recording: F12 first", ""); return; }
    r = shot_name(dir_clus, n11);
    if (r == 0) r = machine_c64 ? c64_screenshot(dir_clus, n11) : machine_atari ? at_screenshot(dir_clus, n11)
                                                                             : snap_screenshot(dir_clus, n11);
    list_stale = 1;
    name83(fname, n11);
    if (r == 0)                note("Saved ", fname);
    else if (r == SNAP_ERUN)   note("Spectrum not running", "");
    else if (r == FAT_EFULL)   note("Card or folder full", "");
    else                       note("Card error", "");
}

/* the Print Screen key (USB HID 0x46) in the raw keyboard report, polled every 20 ms;
   1 on a new press */
static uint32_t prt_t;
static int      prt_was;
static int prtsc_pressed(void)
{
    uint32_t r, r2;
    int      now;
    if (TIMER - prt_t < 20 * CLK_PER_MS) return 0;
    prt_t = TIMER;
    do { r = KEYRAW; r2 = KEYRAW; } while (r != r2);
    now = ((r >> 16) & 0xFF) == 0x46 || ((r >> 8) & 0xFF) == 0x46 || (r & 0xFF) == 0x46;
    if (now && !prt_was) { prt_was = 1; return 1; }
    prt_was = now;
    return 0;
}

/* F2: stop the machine, ask for a name, save NAME.Z80 (L64: NAME.A64, LTari: NAME.A8S) in the current folder */
static void snap_save_ui(void)
{
    char n11[11], fname[13];
    int  r;

    if (!mounted) mount_card();
    if (!mounted) { note("No SD card", ""); return; }
    if (machine_atari) {
        if (at_snap_freeze() != 0) { note("Atari not running", ""); return; }
        at_snap_capture();
    } else if (machine_c64) {
        if (c64_snap_freeze() != 0) { note("C64 not running", ""); return; }
        c64_snap_capture();
    } else {
        if (snap_freeze() != 0) { note("Spectrum not running", ""); return; }
        snap_capture();
    }
    osd_clear();
    osd_show(1);
    if (name_prompt(n11, 1)) {
        name83(fname, n11);
        osd_text(3, 0, " Saving ", OSD_COLS, 0);
        osd_text(3, 8, fname, 24, 0);
        r = machine_atari ? at_snap_save(dir_clus, n11) : machine_c64 ? c64_snap_save(dir_clus, n11) : snap_save(dir_clus, n11);
        list_stale = 1;
        if (r == FAT_OK)          note("Saved ", fname);
        else if (r == FAT_EFULL)  note("Card or folder full", "");
        else                      note("Card error", "");
    }
    while (KEYS & CLOSE_KEYS) ;                             /* the machine must not see Enter / Esc */
    if (machine_atari) at_snap_resume(); else if (machine_c64) c64_snap_resume(); else snap_resume();
    osd_clear();
    if (menu) osd_show(1); else osd_hide();
}

/*----------------------------------------------------------------------------
 * the machine menu (AMenu) on the link: flash update from the card, "no machines installed"
 *--------------------------------------------------------------------------*/
static uint32_t upd_t;

static void wait_ms(uint32_t ms)
{
    uint32_t t0 = TIMER;
    while (TIMER - t0 < ms * CLK_PER_MS && menu_present()) (void)KEYS;   /* register reads: the link check runs */
}

static void upd_screen(const char *title, const char *l1, const char *l2, const char *l3)
{
    osd_clear();
    osd_text(0, 0, title, OSD_COLS, 1);
    osd_text(4, 1, l1, OSD_COLS - 1, 0);
    osd_text(6, 1, l2, OSD_COLS - 1, 0);
    osd_text(8, 1, l3, OSD_COLS - 1, 0);
    osd_show(1);
}

static void upd_bar(uint32_t done, uint32_t total)
{
    char line[33];
    int  n = total ? (int)((uint64_t)done * 30u / total) : 0, i;
    if (TIMER - upd_t < 300 * CLK_PER_MS && done < total) return;
    upd_t = TIMER;
    line[0] = '[';
    for (i = 0; i < 30; i++) line[1 + i] = i < n ? '#' : '.';
    line[31] = ']';
    line[32] = 0;
    osd_text(12, 0, line, OSD_COLS, 0);
}

static void menu_update(const DIRENT *d)
{
    char     n[33];
    int      r, menu_changed;
    uint32_t written;

    upd_screen(" L update", "Checking LUPDATE.BIN ...", "", "Do not switch off.");
    upd_t = 0;
    r = upd_check(d, upd_bar);
    if (r) {
        upd_screen(" L update", r == UPD_EBAD ? "LUPDATE.BIN is not a valid" : "Card read error.",
                   r == UPD_EBAD ? "update file (damaged?)." : "", "Nothing was changed.");
        for (;;) wait_ms(1000);
    }
    u_strncpy(n, upd_label(), 31);
    upd_screen(" L update", n, "Writing the flash ...", "Do not switch off.");
    upd_t = 0;
    r = upd_run(d, upd_bar, &menu_changed, &written);
    if (r == UPD_EFLASH) {
        upd_screen(" L update", "Flash write error.", "LUPDATE.BIN is kept: switch", "off and on to try again.");
        for (;;) wait_ms(1000);
    }
    if (r) {
        upd_screen(" L update", "Card error.", "LUPDATE.BIN is kept: switch", "off and on to try again.");
        for (;;) wait_ms(1000);
    }
    if (menu_changed) {
        upd_screen(" L update", "Update complete.", "Switch the board off and on.", "");
        for (;;) wait_ms(1000);
    }
    upd_screen(" L update", "Update complete.", written ? "" : "(the flash was up to date)", "");
    wait_ms(3000);
}

/* LESP32.BIN: the ESP32's own firmware; on success the ESP32 restarts (the menu is found again) */
static void menu_espupd(const DIRENT *d)
{
    int r;
    upd_screen(" L update", "ESP32 firmware (LESP32.BIN):", "Writing ...", "Do not switch off.");
    upd_t = 0;
    r = espupd_run(d, upd_bar);
    if (r == 0) {
        upd_screen(" L update", "ESP32 firmware installed.", "Restarting the ESP32 ...", "");
        wait_ms(1500);
        esp_reboot();
    }
    upd_screen(" L update", r == ESPUPD_EBAD ? "LESP32.BIN is not an ESP32" : r == ESPUPD_EWRITE ? "ESP32 firmware write failed."
                                                                                                : "Card read error.",
               r == ESPUPD_EBAD ? "firmware file (esp32_v2.ino.bin)." : "The old firmware still runs.",
               "Remove the file, then switch off and on.");
    for (;;) wait_ms(1000);
}

static void menu_main(void)
{
    DIRENT d;
    int    shown = 0, i, bt_r = 0;
    uint32_t k, t_chk, t_draw = 0;
    char   line[96], *p;
    uint8_t b[4];
    static const char hx[] = "0123456789ABCDEF";
    osd_hide();
    osd_clear();
    p = u_strcpy(line, "flash at +0x20 of menu / 4 machine slots:");     /* 56 EF EF EF where an image is */
    for (k = 0; k <= 4; k++) {
        upd_slot_bytes(k, b);
        *p++ = ' ';
        for (i = 0; i < 4; i++) { *p++ = hx[b[i] >> 4]; *p++ = hx[b[i] & 15]; }
    }
    *p = 0;
    log_line(line);
    t_chk = TIMER - 2000 * CLK_PER_MS;                      /* the checks run at once */
    while (menu_present()) {
        /* F3: the Bluetooth menu on the OSD (the menu takes no keys while the OSD is on) */
        k = key_events();
        if (!menu_present()) break;                         /* a machine is starting: no more menu */
        if (bt_on) {
            bt_r = bt_keys(k);
            if (!bt_r) {
                bt_on = 0;
                bt_close();
                while (KEYS & (CLOSE_KEYS | K_BT)) ;        /* the menu must not see Enter */
                osd_clear();
                osd_hide();
                shown = 0;                                  /* "no machines" is drawn again */
            }
        } else if (k & K_BT) {
            bt_on = 1;
            bt_open();
        }
        if (bt_service() || k || bt_r == 2 || TIMER - t_draw > 200 * CLK_PER_MS) {
            if (bt_on) bt_draw();
            t_draw = TIMER;
        }
        bt_r = 0;
        if (bt_on || TIMER - t_chk < 2000 * CLK_PER_MS) { wait_ms(20); continue; }
        t_chk = TIMER;
        if (sd_init() == 0 && fat_mount() == FAT_OK && espupd_find(&d) > 0 && link_alive())
            menu_espupd(&d);
        if (sd_ready() && upd_find(&d) > 0) {
            menu_update(&d);
            shown = 0;
        }
        if (!upd_machines_present()) {
            /* a machine started meanwhile: those flash reads were the reconfiguration's noise, and the
             * screen would go to the new machine's OSD (seen on hardware) */
            if (!link_alive()) break;
            if (!shown) upd_screen(" L", "No machines installed.", "Copy LUPDATE.BIN to the SD",
                                   "card's root folder.");
            shown = 1;
        } else if (shown) {
            osd_hide();
            shown = 0;
        }
    }
    if (bt_on) { bt_on = 0; bt_close(); }
}

int main(void)
{
    uint32_t k, t_draw = 0;
    int      last_state = -1, bt_line, bt_r = 0;

    if (machine_menu) { menu_main(); return 0; }

    TAPE = TAPE_FLUSH;
    osd_hide();
    osd_clear();
    mount_card();
    if (machine_c64) { c64_roms(); c64_speed(); }
    t_draw = TIMER;
    for (;;) {
        k = key_events();
        if (closing) {
            if (!(KEYS & CLOSE_KEYS)) {
                closing = 0;
                menu = 0;
                if (bt_on) { bt_on = 0; bt_close(); }
                joy_on = 0;
                osd_clear();
                last_state = -1;                            /* redraw: status bar or nothing */
            }
        } else if (bt_on) {
            bt_r = bt_keys(k);
            if (!bt_r) closing = 1;
        } else if (joy_on) {
            if (!joy_keys(k)) closing = 1;
        } else if (menu)
            menu_keys(k);
        else
            play_keys(k);
        player_service();
        if (machine_c64) { c64rec_service(); c64_d64_service(); }
        else if (machine_atari) at_service();
        else rec_service();
        if (prtsc_pressed() && !bt_on && !joy_on) screenshot();
        bt_line = bt_service();
        /* redraw on a key, on a player state change, on news from the ESP32 (menu open),
           and 5 times a second (block number) */
        if (k || p_state != last_state || (bt_on && (bt_line || bt_r == 2)) || TIMER - t_draw > 200 * CLK_PER_MS) {
            if (bt_on) bt_draw(); else if (joy_on) joy_draw(); else if (menu) draw_menu(); else draw_bar();
            last_state = p_state;
            t_draw = TIMER;
        }
    }
}

/* every module back to the state after a start (esp_hw.cpp, before the loader runs for the next
 * machine: no ESP32 restart, so the Bluetooth connection stays) */
void loader_reset_all(void)
{
    if (ent) u_memset(ent, 0, (uint32_t)ent_max * sizeof(ENT));   /* the memory stays allocated */
    u_memset(&nent, 0, sizeof nent);
    u_memset(&cur, 0, sizeof cur);
    u_memset(&top, 0, sizeof top);
    u_memset(&truncated, 0, sizeof truncated);
    u_memset(&mounted, 0, sizeof mounted);
    u_memset(&menu, 0, sizeof menu);
    u_memset(&closing, 0, sizeof closing);
    u_memset(&list_folders, 0, sizeof list_folders);
    u_memset(&list_stale, 0, sizeof list_stale);
    u_memset(&bt_on, 0, sizeof bt_on);
    u_memset(&joy_on, 0, sizeof joy_on);
    u_memset(&joy_cur, 0, sizeof joy_cur);
    u_memset(&dir_clus, 0, sizeof dir_clus);
    u_memset(&path, 0, sizeof path);
    u_memset(&came_from, 0, sizeof came_from);
    u_memset(&tf, 0, sizeof tf);
    u_memset(&p_state, 0, sizeof p_state);
    u_memset(&p_tzx, 0, sizeof p_tzx);
    u_memset(&p_stop, 0, sizeof p_stop);
    u_memset(&p_block, 0, sizeof p_block);
    u_memset(&p_name, 0, sizeof p_name);
    u_memset(&kprev, 0, sizeof kprev);
    u_memset(&t_rep, 0, sizeof t_rep);
    u_memset(&err_line, 0, sizeof err_line);
    u_memset(&speed_t, 0, sizeof speed_t);
    u_memset(&note_line, 0, sizeof note_line);
    u_memset(&note_t, 0, sizeof note_t);
    u_memset(&rprev, 0, sizeof rprev);
    u_memset(&upd_t, 0, sizeof upd_t);
    u_memset(&prt_t, 0, sizeof prt_t);
    u_memset(&prt_was, 0, sizeof prt_was);
    at_reset();
    c64_reset();
    save_reset();
    shot_reset();
    snap_reset();
    tape_reset();
    bt_reset();
    fat_reset();
}
