/* main.c -- LSpectrum SD tape loader: file browser on the OSD + TAP/TZX player */
/* Keys (zx_keyboard.v, see hw.h and docs/SD_TAPE_LOADER.md): */
/*   browser closed: F12 / keypad / / NumLock opens it; F11 / keypad 5 pause or */
/*                   continue the tape; keypad - goes back one block. */
/*   browser open:   up/down (keypad 8/2, F9/F10, arrows), page (keypad 4/6, Left/Right, PgUp/PgDn), */
/*                   Enter / keypad Enter / F11 loads a file or opens a folder, */
/*                   Esc / Backspace goes to the parent folder, F12 closes. */
/*                   Keypad 5 and keypad - work as above. */
/*   browser closed: Page Up / Page Down move the 50 Hz frame interrupt 1/8 VGA line */
/*                   (108 pixels) earlier / later, to line up border effects with the */
/*                   picture; "Frame INT: line.eighth" (default 24.1) for 4 s. */
/*   F5:             memory contention on (default) / off; "Contention: on/off" for 4 s. */
/*   always:         F7 / keypad * stops the tape: EAR and speed back to normal, */
/*                   no status row; the file has to be chosen again. */
/*                   F6 switches loading and saving between turbo (default) and */
/*                   normal speed; "Speed: normal" / "Speed: turbo" for 2 s. */
/* Playing a file switches the CPU to turbo (28 MHz) and feeds EAR from the */
/* pulse player; both are released at the end of the tape or at a stop block. */
/* Saving (save.c): the first browser line, [Save to this folder], asks for an */
/* 8.3 name and starts recording mode: everything the Spectrum saves goes into */
/* that .tap file until F12 (or F7) is pressed. */
/* Joysticks: F4 opens the joystick menu (up/down, Enter = select, F4/Esc = */
/* close): both DB9 ports Kempston (default); DB9-1 Kempston + DB9-2 Cursor; */
/* Interface 2 (DB9-1 Sinclair 1 = keys 6-0, DB9-2 Sinclair 2 = keys 1-5). */
/* Bluetooth (bt.c): F3 opens the Bluetooth audio menu (scan, connect, PIN, */
/* volume) for the ESP32 bridge; the tape goes on playing meanwhile. */
/* Snapshots (snap.c): F2 stops the Spectrum and asks for a name; the whole */
/* machine is saved as NAME.Z80 in the browser's current folder (the root after */
/* power-up), then it runs on. Choosing a .z80 file in the browser loads it. */
/* L64 (c64.c): the same with NAME.A64. */
/* Print Screen saves the picture as SCRNnnnn.BMP (16 colours, shot.c) in the browser's */
/* current folder: the Spectrum's screen with the border (snap.c), L64's frame buffer */
/* (LTari: its frame buffer, 256 colours, atari.c). */
/* LTari (Atari 800XL / 130XE): the browser lists .xex / .atr / .car files; an .atr goes */
/* into the SIO disk drive D1: (atari.c) and the Atari cold-starts from it; an .xex is served as a */
/* boot disk with our loader; a .car (standard 8 / 16 KB, Atarimax) plugs in as a cartridge. */
/* Shift + Enter on an .atr only changes the disk (the Atari runs on). The F3 and F4 menus work */
/* (F4: which DB9 port is stick 0); Print Screen saves a 256-colour BMP; F2 saves a snapshot */
/* NAME.A8S, loaded again from the browser; saving to tape is not used. */
/* Runs as a task on the ESP32 (esp_hw.cpp); KEY0 resets the FPGA's loader */
/* hardware and the ESP32 then restarts, so all state starts from zero again. */
#include <stdlib.h>
#include "hw.h"
#include "hal.h"
/* the card and the tape */
#include "fat.h"
#include "tape.h"
#include "sd.h"
/* the screen, strings, the recorder */
#include "osd.h"
#include "util.h"
#include "save.h"
/* snapshots, the two updates */
#include "snap.h"
#include "update.h"
#include "espupd.h"
/* the Bluetooth menu, L64, screenshots */
#include "bt.h"
#include "c64.h"
#include "shot.h"
/* LTari, the restart */
#include "atari.h"
#include "reset.h"

/* entries per folder, in the PSRAM (40 bytes each: 160 KB); without PSRAM: internal RAM (12.8 KB) */
#define MAXE 4096
#define MAXE_IRAM 320
/* the browser's list on the screen */
#define LIST_ROW 2
#define LIST_LINES 20
#define LIST_HALF 10
/* key repeat: the first after 400 ms, then every 60 ms */
#define REP_DELAY (400 * CLK_PER_MS)
#define REP_RATE (60 * CLK_PER_MS)
/* the whole name fat.c delivers */
#define ENT_NAME NAME_MAX
/* files larger than this are no file type we load (and do not fit the entry's size field) */
#define FILE_SIZE_BITS 22
#define FILE_SIZE_LIMIT (1u << FILE_SIZE_BITS)
/* one bit per flag of a list entry */
#define FLAG_BIT 1
/* messages over the list: no card (two rows), empty folder, cut list */
#define ROW_NOCARD 3
#define ROW_NOCARD_HELP 5
/* an empty folder, a cut list */
#define ROW_EMPTY 4
#define ROW_TRUNCATED 21
/* a folder name in the path gets a slash and the terminator */
#define PATH_EXTRA 2
/* characters 2 to 4 of the proposed name SAVEnnnn, and of an extension */
#define SAVE_CHAR_1 1
#define SAVE_CHAR_2 2
#define SAVE_CHAR_3 3
/* of an extension */
#define EXT_CHAR_1 1
#define EXT_CHAR_2 2
/* the two answer rows of the LTari question */
#define BASIC_ROW_F1 11
#define BASIC_ROW_F2 12
/* a register read from a gone FPGA */
#define ALL_ONES 0xFFFFFFFFu
/* fields of the FIFO and MARKER registers */
#define FIFO_COUNT_MASK 0x3FFu
#define MARKER_MASK 0xFFFFu
/* screen rows */
#define ROW_TITLE 0
#define ROW_PATH 1
#define ROW_NAME 3
/* progress, status, key help */
#define ROW_PROGRESS 3
#define ROW_STATUS 22
#define ROW_HELP 23
/* text buffers */
#define PATH_BUF 64
#define LINE_BUF 48
#define TEXT_BUF 33
/* a text's length, a short info, a number */
#define TEXT_MAX 32
#define INFO_BUF 16
#define NUM_BUF 12
/* file names, a line of the slot list */
#define FNAME_BUF 13
#define NAME8_BUF 12
#define SLOT_LINE_BUF 96
/* 8.3 names */
#define NAME8_LEN 8
#define EXT_LEN 3
#define N11_EXT 8
/* its other two characters */
#define N11_EXT_1 9
#define N11_EXT_2 10
/* how long messages are shown */
#define NOTE_MS 4000u
#define SPEED_MS 2000u
/* the main loop: redraw period, Print Screen poll period */
#define DRAW_MS 200u
#define PRTSC_MS 20u
/* the shell sort's gap sequence 1, 4, 13, 40, ... (Knuth) */
#define GAP_FACTOR 3
#define GAP_FIRST 1
/* USB HID key codes, and the Shift bits of the modifier byte */
#define HID_A 0x04
#define HID_Z 0x1D
#define HID_1 0x1E
/* 9, 0, Enter */
#define HID_9 0x26
#define HID_0 0x27
#define HID_ENTER 0x28
/* Esc, backspace, minus */
#define HID_ESC 0x29
#define HID_BACKSPACE 0x2A
#define HID_MINUS 0x2D
/* function keys, Print Screen */
#define HID_F1 0x3A
#define HID_F2 0x3B
#define HID_PRINT_SCREEN 0x46
/* the numpad */
#define HID_KP_MINUS 0x56
#define HID_KP_ENTER 0x58
#define HID_KP_1 0x59
/* its 9 and 0; both Shift keys */
#define HID_KP_9 0x61
#define HID_KP_0 0x62
#define MOD_SHIFTS 0x22
/* the raw keyboard report: three key codes and the modifiers in one word */
#define RAW_KEYS 3
#define RAW_MODS_SHIFT 24
#define RAW_KEY0_SHIFT 16
/* the third key, a key's mask, bits of a byte */
#define RAW_KEY1_SHIFT 8
#define RAW_KEY_MASK 0xFFu
#define BITS_PER_BYTE 8
/* the file name proposed for a recording: SAVE0001 to SAVE9999 */
#define SAVE_FIRST 1
#define SAVE_END 10000
#define SAVE_DIGIT_THOUSANDS 4
/* the other digits' places */
#define SAVE_DIGIT_HUNDREDS 5
#define SAVE_DIGIT_TENS 6
#define SAVE_DIGIT_ONES 7
/* decimal weights */
#define THOUSAND 1000
#define HUNDRED 100
#define TEN 10
/* the joystick menu */
#define JOY_MODES 3
#define JOY_MODES_ATARI 2
#define JOY_PORTS 2
/* its rows */
#define JOY_ROW_MODES 2
#define JOY_ROW_GAP 5
/* the two ports */
#define JOY_ROW_PORT1 6
#define JOY_ROW_PORT2 7
/* the "how to load" question of LTari */
#define BASIC_ROW 10
#define BASIC_NONE (-2)
#define BASIC_ESC (-1)
/* with or without BASIC */
#define BASIC_OFF 0
#define BASIC_ON 1
/* the frame interrupt position: pixels per VGA line, one step, the last line */
#define INT_LINE_MASK 0x3FFu
#define INT_PIXEL_SHIFT 16
#define INT_LINE_PIXELS 864u
/* one step, the last line */
#define INT_STEP 108u
#define INT_LAST_LINE 620u
/* L64's ROM install screen */
#define ROM_WAIT_MS 300u
#define ROM_TRIES 3
#define ROM_ROW_STATE 1
/* the help rows */
#define ROM_ROW_HELP1 3
#define ROM_ROW_HELP2 4
#define ROM_ROW_HELP3 5
/* the last help row, the retry row */
#define ROM_ROW_HELP4 6
#define ROM_ROW_RETRY 8
/* the name prompt's rows */
#define PROMPT_ROW_TEXT1 5
#define PROMPT_ROW_TEXT2 6
#define PROMPT_ROW_TEXT3 7
/* the last text row; the place of the text shown while saving */
#define PROMPT_ROW_TEXT4 8
#define SAVING_COL 8
#define SAVING_WIDTH 24
/* the update screens */
#define UPD_ROW_LINE1 4
#define UPD_ROW_LINE2 6
#define UPD_ROW_LINE3 8
/* the progress bar */
#define UPD_ROW_BAR 12
#define UPD_BAR_CELLS 30
#define UPD_BAR_END 31
/* its buffer, how often it is drawn, the halt time */
#define UPD_BAR_BUF 33
#define UPD_BAR_MS 300u
#define UPD_HALT_MS 1000u
/* times shown, the label's length */
#define UPD_DONE_MS 3000u
#define UPD_REBOOT_MS 1500u
#define UPD_LABEL_MAX 31
/* checking for a file, idling, the last slot */
#define UPD_CHECK_MS 2000u
#define UPD_IDLE_MS 20u
#define UPD_SLOTS_LAST 4
/* hexadecimal output */
#define HEX_HIGH_SHIFT 4
#define HEX_DIGIT_MASK 15
/* flags as numbers */
#define YES 1
#define NO_STATE (-1)
/* a failed listing; the distance from 'A' to 'a' */
#define LIST_ERROR (-1)
#define ASCII_CASE_OFFSET 32

/* keys that close the browser: it goes away only when the key that closed it is released */
#define CLOSE_KEYS (K_ENTER | K_F11 | K_MENU | K_BACK)
/* keys that repeat while held */
#define REP_KEYS (K_UP | K_DOWN | K_LEFT | K_RIGHT | K_PGUP | K_PGDN)

/* one entry of the browser's list, in one word and the name */
typedef struct
{
/* first cluster */
    uint32_t ui32_clus;
    uint32_t ui32_size : FILE_SIZE_BITS, ui32_dir : FLAG_BIT, ui32_tzx : FLAG_BIT, ui32_z80 : FLAG_BIT, ui32_prg : FLAG_BIT,
             ui32_t64 : FLAG_BIT, ui32_d64 : FLAG_BIT, ui32_ro : FLAG_BIT, ui32_xa : FLAG_BIT, ui32_atr : FLAG_BIT,
             ui32_xex : FLAG_BIT;
    char ac_name[NAME_BUF_LEN];
} ENT;

/* the player's states */
enum
{
    P_IDLE,
    P_RUN,
    P_DRAIN,
    P_STOPPED,
    P_PAUSED,
    P_END,
    P_ERR
};

/* names of the joystick modes for the three machines */
static const char *const g_apc_joy_name_zx[JOY_MODES] = { "Kempston", "Kempston + Cursor", "Interface 2" };
static const char *const g_apc_joy_name_c64[JOY_MODES] = { "DB9-1 = port 2", "DB9-1 = port 1", "Both = port 2" };
static const char *const g_apc_joy_name_at[JOY_MODES] = { "DB9-1 = stick 0", "DB9-1 = stick 1", "" };
/* what the two ports are in each mode */
static const char *const g_apc_port_zx[JOY_MODES][JOY_PORTS] =
{
    { " DB9-1: Kempston", " DB9-2: Kempston (same)" },
    { " DB9-1: Kempston", " DB9-2: Cursor (5 6 7 8, 0)" },
    { " DB9-1: Sinclair 1 (6-9, 0)", " DB9-2: Sinclair 2 (1-4, 5)" }
};
/* L64 */
static const char *const g_apc_port_c64[JOY_MODES][JOY_PORTS] =
{
    { " DB9-1: control port 2", " DB9-2: control port 1" },
    { " DB9-1: control port 1", " DB9-2: control port 2" },
    { " DB9-1 and DB9-2: port 2", " (port 1 unused)" }
};
/* LTari */
static const char *const g_apc_port_at[JOY_MODES][JOY_PORTS] =
{
    { " DB9-1: stick 0 (player 1)", " DB9-2: stick 1" },
    { " DB9-1: stick 1", " DB9-2: stick 0 (player 1)" },
    { "", "" }
};
/* hexadecimal digits */
static const char g_ac_hex[] = "0123456789ABCDEF";
/* the browser's path, and the folder just left (the cursor goes back to it) */
static char g_ac_path[PATH_BUF];
static char g_ac_came_from[NAME_BUF_LEN];
/* the name of the file being played */
static char g_ac_p_name[NAME_BUF_LEN];
/* an error line and a note for the status row */
static char g_ac_err_line[TEXT_BUF];
static char g_ac_note_line[TEXT_BUF];
/* the keys of the last raw keyboard report */
static uint8_t g_aui8_raw_prev[RAW_KEYS];
/* the list's entries, allocated once (list_alloc), and how many fit */
static ENT *g_ps_ent;
static int32_t g_i32_ent_max;
/* the list: entries, cursor, first line shown, cut short */
static int32_t g_i32_nent;
static int32_t g_i32_cur;
/* the first line shown, cut short */
static int32_t g_i32_top;
static int32_t g_i32_truncated;
/* the card is mounted; the browser is open; it is closing (waiting for the key's release) */
static int32_t g_i32_mounted;
static int32_t g_i32_menu;
static int32_t g_i32_closing;
/* the list holds folders only; the list is out of date (a file was written) */
static int32_t g_i32_list_folders;
static int32_t g_i32_list_stale;
/* the Bluetooth menu and the joystick menu are open; the joystick menu's cursor */
static int32_t g_i32_bt_on;
static int32_t g_i32_joy_on;
static int32_t g_i32_joy_cur;
/* the browser's folder */
static uint32_t g_ui32_dir_clus;
/* the file being played */
static FFILE g_s_tape_file;
/* the player: state, TZX file, stopped by a stop block, the block of a pause */
static int32_t g_i32_p_state;
static int32_t g_i32_p_tzx;
/* stopped by a stop block, the block of a pause */
static int32_t g_i32_p_stop;
static uint32_t g_ui32_p_block;
/* the keys of the last pass, and when the next repeat is due */
static uint32_t g_ui32_key_prev;
static uint32_t g_ui32_rep_time;
/* "Speed: ..." and the note are shown until then (0 = not shown) */
static uint32_t g_ui32_speed_until;
static uint32_t g_ui32_note_until;
/* Print Screen: when it was polled last, and whether it was down then */
static uint32_t g_ui32_prt_time;
static int32_t g_i32_prt_was;
/* when the update's progress bar was drawn last */
static uint32_t g_ui32_upd_time;

/* functions used before they are defined */
static int32_t speed_text(char *pc_text);
static int32_t note_text(char *pc_text);
/* the name prompt, saving a snapshot */
static int32_t name_prompt(char ac_name11[FAT_NAME11_LEN], int32_t i32_snap);
static void snap_save_ui(void);

/* the turbo bit of the TAPE register, unless F6 chose normal speed */
static uint32_t turbo_bit(void)
{
/* local variables */
    uint32_t ui32_bit;

/* start values */
    ui32_bit = TAPE_TURBO;
    if (g_i32_slow_mode != 0)
    {
/* normal speed */
        ui32_bit = 0u;
    }
    return ui32_bit;
}

/* platform functions for fat.c / tape.c */

/* free entries in the pulse FIFO */
uint32_t fifo_free(void)
{
/* local variables */
    uint32_t ui32_free;

    ui32_free = FIFO_DEPTH - (FIFO & FIFO_COUNT_MASK);
    return ui32_free;
}

/* keys: new presses, with auto-repeat for the movement keys */
static uint32_t key_events(void)
{
/* local variables */
    uint32_t ui32_now;
    uint32_t ui32_events;

/* start values */
    ui32_now = KEYS;
    ui32_events = 0;
/* a gone FPGA (reconfiguring) reads all ones */
    if (ui32_now != ALL_ONES)
    {
        ui32_events = ui32_now & ~g_ui32_key_prev;
        if ((ui32_events & REP_KEYS) != 0)
        {
/* a new press: the first repeat comes later */
            g_ui32_rep_time = TIMER + REP_DELAY;
        }
        else if ((ui32_now & REP_KEYS) != 0)
        {
/* held: repeat when it is due */
            if ((int32_t)(TIMER - g_ui32_rep_time) >= 0)
            {
                ui32_events |= ui32_now & REP_KEYS;
                g_ui32_rep_time = TIMER + REP_RATE;
            }
        }
        else
        {
/* no movement key */
        }
        g_ui32_key_prev = ui32_now;
    }
    return ui32_events;
}

/* directory list */

/* is entry a before entry b in the list? ".." first, folders before files, then by name */
static bool ent_less(const ENT *ps_a, const ENT *ps_b)
{
/* local variables */
    bool b_less;

    if ((ps_a->ac_name[0] == '.') && (ps_a->ac_name[YES] == '.'))
    {
        b_less = true;
    }
/* and the other way round */
    else if ((ps_b->ac_name[0] == '.') && (ps_b->ac_name[YES] == '.'))
    {
        b_less = false;
    }
    else if (ps_a->ui32_dir != ps_b->ui32_dir)
    {
/* folders before files */
        b_less = ps_a->ui32_dir != 0;
    }
    else
    {
        b_less = u_stricmp(ps_a->ac_name, ps_b->ac_name) < 0;
    }
    return b_less;
}

/* has an entry this extension? */
static bool has_ext(const DIRENT *ps_entry, const char *pc_ext)
{
/* local variables */
    bool b_same;

    b_same = u_stricmp(ps_entry->ac_ext, pc_ext) == 0;
    return b_same;
}

/* directory callback: the folders, and the files the machine on the link can load */
static int32_t list_cb(const DIRENT *ps_entry, void *p_ctx)
{
/* local variables */
    ENT *ps_new;
    bool b_dir;
    bool b_tap;
/* the kinds of files */
    bool b_tzx;
    bool b_snap;
    bool b_atr;
/* Atari files, C64 programs */
    bool b_xex;
    bool b_xa;
    bool b_prg;
/* C64 tape archive and disk; taken into the list */
    bool b_t64;
    bool b_d64;
    bool b_take;
/* the scan stops */
    int32_t i32_stop;

/* the callback's context is not used */
    (void)p_ctx;
    ps_new = NULL;
    b_dir = (ps_entry->ui8_attr & ATTR_DIR) != 0;
/* tapes: not on LTari; TZX only on the Spectrum */
    b_tap = (g_i32_machine_atari == 0) && has_ext(ps_entry, "TAP");
    b_tzx = (g_i32_machine_c64 == 0) && (g_i32_machine_atari == 0) && has_ext(ps_entry, "TZX");
/* snapshot */
    if (g_i32_machine_c64 != 0)
    {
        b_snap = has_ext(ps_entry, "A64");
    }
/* LTari */
    else if (g_i32_machine_atari != 0)
    {
        b_snap = has_ext(ps_entry, "A8S");
    }
    else
    {
        b_snap = has_ext(ps_entry, "Z80");
    }
/* LTari: disk; .xex (.com: same format); .car */
    b_atr = (g_i32_machine_atari != 0) && has_ext(ps_entry, "ATR");
    b_xex = (g_i32_machine_atari != 0) && (has_ext(ps_entry, "XEX") || has_ext(ps_entry, "COM"));
    b_xa = b_xex || ((g_i32_machine_atari != 0) && has_ext(ps_entry, "CAR"));
/* L64: .prg, .t64, .d64 (and C64 .tap) */
    b_prg = (g_i32_machine_c64 != 0) && has_ext(ps_entry, "PRG");
    b_t64 = (g_i32_machine_c64 != 0) && has_ext(ps_entry, "T64");
    b_d64 = (g_i32_machine_c64 != 0) && has_ext(ps_entry, "D64");
/* taken unless a rule below says no */
    b_take = true;
    i32_stop = 0;
    if ((ps_entry->ac_name[0] == '.') && (ps_entry->ac_name[YES] == 0))
    {
/* "." */
        b_take = false;
    }
    else if ((ps_entry->ui8_attr & (ATTR_HIDDEN | ATTR_SYSTEM)) != 0)
    {
        b_take = false;
    }
/* a file the machine cannot load, or any file when only folders are wanted */
    else if (!b_dir && ((g_i32_list_folders != 0) ||
                        (!b_tap && !b_tzx && !b_snap && !b_prg && !b_t64 && !b_d64 && !b_xa && !b_atr)))
    {
/* a file of no use here */
        b_take = false;
    }
    else if (!b_dir && (ps_entry->ui32_size >= FILE_SIZE_LIMIT))
    {
/* > 4 MB: no file type we load */
        b_take = false;
    }
    else if (g_i32_nent == g_i32_ent_max)
    {
/* the list is full */
        g_i32_truncated = YES;
        b_take = false;
        i32_stop = YES;
    }
    else
    {
/* an entry for the list */
    }
    if (b_take)
    {
        ps_new = &g_ps_ent[g_i32_nent];
        g_i32_nent++;
/* where it is, how long */
        ps_new->ui32_clus = ps_entry->ui32_clus;
        ps_new->ui32_size = ps_entry->ui32_size;
/* what it is */
        ps_new->ui32_dir = (uint32_t)b_dir;
        ps_new->ui32_tzx = (uint32_t)b_tzx;
        ps_new->ui32_z80 = (uint32_t)b_snap;
/* C64 files */
        ps_new->ui32_prg = (uint32_t)b_prg;
        ps_new->ui32_t64 = (uint32_t)b_t64;
        ps_new->ui32_d64 = (uint32_t)b_d64;
/* Atari files */
        ps_new->ui32_xa = (uint32_t)b_xa;
        ps_new->ui32_atr = (uint32_t)b_atr;
        ps_new->ui32_xex = (uint32_t)b_xex;
/* the file's read-only attribute */
        ps_new->ui32_ro = (uint32_t)((ps_entry->ui8_attr & ATTR_RO) != 0);
        u_strncpy(ps_new->ac_name, ps_entry->ac_name, ENT_NAME);
    }
    return i32_stop;
}

/* the list's memory, on first use: PSRAM, else (no PSRAM found) the internal heap */
static void list_alloc(void)
{
    if (g_ps_ent == NULL)
    {
        g_ps_ent = (ENT *)ext_alloc(MAXE * (uint32_t)sizeof(ENT));
/* PSRAM: the long list */
        if (g_ps_ent != NULL)
        {
            g_i32_ent_max = MAXE;
        }
        else
        {
/* no PSRAM: a shorter list */
            g_ps_ent = (ENT *)malloc(MAXE_IRAM * sizeof(ENT));
            if (g_ps_ent != NULL)
            {
                g_i32_ent_max = MAXE_IRAM;
            }
        }
    }
}

/* folder list into the entries, sorted; i32_folders_only for the save dialog: 0 or LIST_ERROR */
static int32_t load_list(uint32_t ui32_clus, int32_t i32_folders_only)
{
/* local variables */
    int32_t i32_index;
    int32_t i32_place;
    int32_t i32_gap;
/* an entry on the move, the result */
    ENT s_moved;
    int32_t i32_result;

/* start values */
    i32_index = 0;
    i32_place = 0;
    i32_gap = GAP_FIRST;
/* no error; an empty list */
    i32_result = 0;
    list_alloc();
    g_i32_nent = 0;
/* not cut, the cursor at the top */
    g_i32_truncated = 0;
    g_i32_cur = 0;
    g_i32_top = 0;
/* the scan */
    g_i32_list_folders = i32_folders_only;
    if (fat_list(ui32_clus, list_cb, 0) != FAT_OK)
    {
/* the card is gone */
        g_i32_mounted = 0;
        g_i32_nent = 0;
        i32_result = LIST_ERROR;
    }
    else
    {
/* shell sort, gaps 1, 4, 13, 40, ... (Knuth) */
        while (i32_gap < (g_i32_nent / GAP_FACTOR))
        {
            i32_gap = (GAP_FACTOR * i32_gap) + GAP_FIRST;
        }
/* gap by gap, down to 1 */
        while (i32_gap > 0)
        {
            for (i32_index = i32_gap; i32_index < g_i32_nent; i32_index++)
            {
/* the entry moves down to its place among those a gap apart */
                u_memcpy(&s_moved, &g_ps_ent[i32_index], sizeof s_moved);
                i32_place = i32_index;
/* entries after it move up */
                while ((i32_place >= i32_gap) && ent_less(&s_moved, &g_ps_ent[i32_place - i32_gap]))
                {
                    u_memcpy(&g_ps_ent[i32_place], &g_ps_ent[i32_place - i32_gap], sizeof s_moved);
                    i32_place -= i32_gap;
                }
/* there */
                u_memcpy(&g_ps_ent[i32_place], &s_moved, sizeof s_moved);
            }
            i32_gap /= GAP_FACTOR;
        }
    }
    return i32_result;
}

/* browser list: item 0 is [Save to this folder], items 1.. are the entries; */
/* the cursor starts on the first file or folder */
static int32_t load_dir(uint32_t ui32_clus)
{
/* local variables */
    int32_t i32_result;

/* start values */
    i32_result = load_list(ui32_clus, 0);
    if (i32_result == 0)
    {
/* this is the folder shown */
        g_ui32_dir_clus = ui32_clus;
        g_i32_list_stale = 0;
        g_i32_cur = 0;
/* the first entry, if there is one */
        if (g_i32_nent != 0)
        {
            g_i32_cur = YES;
        }
    }
    return i32_result;
}

/* start the card and its file system, and list the root folder */
static void mount_card(void)
{
    g_i32_mounted = 0;
/* the file system only on a card that started */
    if (sd_init() == SD_OK)
    {
        if (fat_mount() == FAT_OK)
        {
/* mounted; the path is the root */
            g_i32_mounted = YES;
            g_ac_path[0] = '/';
            g_ac_path[YES] = 0;
/* its list */
            load_dir(0);
        }
    }
}

/* player */

/* play the file from a block */
static void play_from(uint32_t ui32_block)
{
    TAPE = TAPE_ON | turbo_bit() | TAPE_FLUSH;
    if (g_i32_machine_c64 != 0)
    {
/* C64 .tap: always from the start */
        c64tap_start(&g_s_tape_file);
    }
    else
    {
        tape_start(&g_s_tape_file, g_i32_p_tzx, ui32_block);
    }
    g_i32_p_state = P_RUN;
}

/* play a file of the list */
static void player_open(const ENT *ps_ent)
{
    ff_open(&g_s_tape_file, ps_ent->ui32_clus, ps_ent->ui32_size);
    g_i32_p_tzx = (int32_t)ps_ent->ui32_tzx;
/* its name, and from the first block */
    u_strncpy(g_ac_p_name, ps_ent->ac_name, NAME_MAX);
    play_from(0);
}

/* pause, continue, or go on after a stop block */
static void player_pause(void)
{
    if ((g_i32_p_state == P_RUN) || (g_i32_p_state == P_DRAIN))
    {
/* the block being played is where it continues */
        g_ui32_p_block = MARKER & MARKER_MASK;
        TAPE = TAPE_FLUSH;
        g_i32_p_state = P_PAUSED;
    }
/* paused: go on at that block */
    else if (g_i32_p_state == P_PAUSED)
    {
        play_from(g_ui32_p_block);
    }
/* stopped by a stop block: go on */
    else if (g_i32_p_state == P_STOPPED)
    {
        TAPE = TAPE_ON | turbo_bit();
        tape_continue();
/* playing again */
        g_i32_p_state = P_RUN;
    }
    else
    {
/* nothing is playing */
    }
}

/* stop the tape: EAR back to the beeper, turbo off, FIFO empty */
static void player_stop(void)
{
    TAPE = TAPE_FLUSH;
    g_i32_p_state = P_IDLE;
}

/* one block back */
static void player_rewind(void)
{
/* local variables */
    uint32_t ui32_block;

/* start values */
    ui32_block = 0;
    if ((g_i32_p_state == P_RUN) || (g_i32_p_state == P_DRAIN) || (g_i32_p_state == P_STOPPED))
    {
        ui32_block = MARKER & MARKER_MASK;
/* one block back, and play */
        if (ui32_block != 0)
        {
            ui32_block--;
        }
        play_from(ui32_block);
    }
/* paused: one block back */
    else if (g_i32_p_state == P_PAUSED)
    {
        if (g_ui32_p_block != 0)
        {
            g_ui32_p_block--;
        }
    }
    else
    {
/* nothing is playing */
    }
}

/* feed the pulse FIFO, and see the tape's end */
static void player_service(void)
{
/* local variables */
    int32_t i32_result;

/* start values */
    i32_result = TS_RUN;
    if (g_i32_p_state == P_RUN)
    {
        if (g_i32_machine_c64 != 0)
        {
/* the C64's tape */
            i32_result = c64tap_pump();
        }
        else
        {
            i32_result = tape_pump();
        }
/* a bad file */
        if (i32_result == TS_ERR)
        {
            TAPE = TAPE_FLUSH;
            g_i32_p_state = P_ERR;
        }
/* the end, or a stop block */
        else if (i32_result != TS_RUN)
        {
/* the file is done: wait until the FIFO is played */
            g_i32_p_stop = 0;
            if (i32_result == TS_STOP)
            {
                g_i32_p_stop = YES;
            }
/* play out what is queued */
            g_i32_p_state = P_DRAIN;
        }
        else
        {
/* still generating */
        }
    }
    else if (g_i32_p_state == P_DRAIN)
    {
        if ((FIFO & FIFO_IDLE) != 0)
        {
/* EAR back to the tape input, turbo off */
            TAPE = 0;
            if (g_i32_p_stop != 0)
            {
                g_i32_p_state = P_STOPPED;
            }
            else
            {
/* the end of the tape */
                g_i32_p_state = P_END;
            }
        }
    }
    else
    {
/* nothing to do */
    }
}

/* status line; returns 0 if there is nothing to say */
static int32_t status_text(char *pc_text)
{
/* local variables */
    char *pc_end;
    uint32_t ui32_block;
    int32_t i32_result;

/* start values */
    pc_end = pc_text;
    ui32_block = MARKER & MARKER_MASK;
    i32_result = YES;
/* by the player's state */
    switch (g_i32_p_state)
    {
    case P_RUN:
    case P_DRAIN:
/* the block being played */
        pc_end = u_strcpy(pc_end, "Playing block ");
        pc_end = u_utoa(pc_end, ui32_block);
        break;
/* paused */
    case P_PAUSED:
        pc_end = u_strcpy(pc_end, "Paused, block ");
        pc_end = u_utoa(pc_end, g_ui32_p_block);
/* the key that continues */
        pc_end = u_strcpy(pc_end, " (5=go)");
        break;
    case P_STOPPED:
/* the same key */
        pc_end = u_strcpy(pc_end, "Tape stopped (5=go on)");
        break;
    case P_END:
/* the tape's end; an error */
        pc_end = u_strcpy(pc_end, "End of tape");
        break;
    case P_ERR:
/* its text */
        pc_end = u_strcpy(pc_end, "Bad file or read error");
        break;
    default:
/* idle */
        i32_result = 0;
        break;
    }
/* the text's end */
    *pc_end = 0;
    return i32_result;
}

/* screen */

/* the title of the browser for the machine on the link */
static const char *loader_title(void)
{
/* local variables */
    const char *pc_title;

/* start values */
    pc_title = " LSpectrum tape loader";
    if (g_i32_machine_c64 != 0)
    {
        pc_title = " L64 loader";
    }
/* LTari */
    else if (g_i32_machine_atari != 0)
    {
        pc_title = " LTari loader";
    }
    else
    {
/* the Spectrum */
    }
    return pc_title;
}

/* the end of the path that fits the screen */
static const char *path_tail(void)
{
/* local variables */
    const char *pc_tail;
    int32_t i32_len;

/* start values */
    pc_tail = g_ac_path;
    i32_len = u_strlen(g_ac_path);
    if (i32_len > OSD_COLS)
    {
/* only its end fits */
        pc_tail = g_ac_path + i32_len - OSD_COLS;
    }
    return pc_tail;
}

/* the browser */
static void draw_menu(void)
{
/* local variables */
    char ac_line[LINE_BUF];
    char *pc_end;
    const char *pc_text;
/* a row, an item, inverse or normal */
    int32_t i32_index;
    int32_t i32_item;
    int32_t i32_inverse;

/* start values */
    pc_end = ac_line;
    pc_text = "";
/* the title and the path */
    osd_text(ROW_TITLE, 0, loader_title(), OSD_COLS, YES);
    osd_text(ROW_PATH, 0, path_tail(), OSD_COLS, 0);
/* the list: item 0 is the save line, then the entries; the cursor's line inverse */
    for (i32_index = 0; i32_index < LIST_LINES; i32_index++)
    {
        i32_item = g_i32_top + i32_index;
        ac_line[0] = 0;
/* the save line */
        if ((g_i32_mounted != 0) && (i32_item == 0))
        {
            u_strcpy(ac_line, " [Save to this folder]");
        }
        else if ((g_i32_mounted != 0) && (i32_item <= g_i32_nent))
        {
/* a name, with a slash behind a folder's */
            pc_end = ac_line;
            *pc_end = ' ';
            pc_end++;
/* the name */
            pc_end = u_strcpy(pc_end, g_ps_ent[i32_item - YES].ac_name);
            if (g_ps_ent[i32_item - YES].ui32_dir != 0)
            {
                *pc_end = '/';
/* the text's end */
                pc_end++;
            }
            *pc_end = 0;
        }
        else
        {
/* an empty line */
        }
        i32_inverse = 0;
        if ((g_i32_mounted != 0) && (i32_item <= g_i32_nent) && (i32_item == g_i32_cur))
        {
            i32_inverse = YES;
        }
/* the row */
        osd_text(LIST_ROW + i32_index, 0, ac_line, OSD_COLS, i32_inverse);
    }
/* what is wrong or missing, over the list */
    if (g_i32_mounted == 0)
    {
        osd_text(ROW_NOCARD, 0, " No SD card, or not FAT16/FAT32", OSD_COLS, 0);
        osd_text(ROW_NOCARD_HELP, 0, " Enter = try again", OSD_COLS, 0);
    }
/* an empty folder: what the machine could load */
    else if (g_i32_nent == 0)
    {
        if (g_i32_machine_c64 != 0)
        {
            pc_text = " (no .prg/.t64/.tap/.d64/.a64)";
        }
/* LTari, LSpectrum */
        else if (g_i32_machine_atari != 0)
        {
            pc_text = " (no .xex/.com/.atr/.car/.a8s)";
        }
        else
        {
            pc_text = " (no .tap/.tzx/.z80 files here)";
        }
/* shown */
        osd_text(ROW_EMPTY, 0, pc_text, OSD_COLS, 0);
    }
    else if (g_i32_truncated != 0)
    {
/* how many entries the list holds */
        u_strcpy(u_utoa(u_strcpy(ac_line, " (only the first "), (uint32_t)g_i32_ent_max), " entries)");
        osd_text(ROW_TRUNCATED, 0, ac_line, OSD_COLS, 0);
    }
    else
    {
/* a normal list */
    }
/* the status row: the first of speed, note, player state, error that has something to say */
    if (speed_text(ac_line) == 0)
    {
        if (note_text(ac_line) == 0)
        {
            if (status_text(ac_line) == 0)
            {
/* the last error */
                u_strcpy(ac_line, g_ac_err_line);
            }
        }
    }
    osd_text(ROW_STATUS, 0, ac_line, OSD_COLS, 0);
/* .atr: Enter asks F1 no BASIC / F2 BASIC */
    if (g_i32_machine_atari != 0)
    {
        osd_text(ROW_HELP, 0, "Ent=load Shift+Ent=swap disk", OSD_COLS, YES);
    }
    else
    {
        osd_text(ROW_HELP, 0, "Ent=load Esc=up 5=stop F12=exit", OSD_COLS, YES);
    }
}

/* F6: toggle the speed; a playing tape or a block being saved changes at once */
/* (L64: the FPGA runs turbo while a motor runs, if MCTL allows it) */
static void speed_toggle(void)
{
/* LTari: no turbo yet */
    if (g_i32_machine_atari == 0)
    {
        if (g_i32_slow_mode != 0)
        {
            g_i32_slow_mode = 0;
        }
        else
        {
/* normal speed */
            g_i32_slow_mode = YES;
        }
        if (g_i32_machine_c64 != 0)
        {
            c64_speed();
        }
        else
        {
/* a playing tape changes its speed at once */
            if ((g_i32_p_state == P_RUN) || (g_i32_p_state == P_DRAIN))
            {
                TAPE = TAPE_ON | turbo_bit();
            }
            rec_speed();
        }
/* the speed is shown for a moment */
        g_ui32_speed_until = TIMER + (SPEED_MS * CLK_PER_MS);
    }
}

/* a message for 4 s (bottom row, or line 22 of the browser) */
static void note(const char *pc_first, const char *pc_second)
{
/* local variables */
    char *pc_end;

/* start values */
    pc_end = u_strncpy(g_ac_note_line, pc_first, TEXT_MAX);
    u_strncpy(pc_end, pc_second, TEXT_MAX - (int32_t)(pc_end - g_ac_note_line));
    g_ui32_note_until = TIMER + (NOTE_MS * CLK_PER_MS);
}

/* the note into pc_text while its time runs: 1, else 0 */
static int32_t note_text(char *pc_text)
{
/* local variables */
    int32_t i32_result;

/* start values */
    i32_result = 0;
    if (g_ui32_note_until != 0)
    {
        if ((int32_t)(TIMER - g_ui32_note_until) >= 0)
        {
/* its time is over */
            g_ui32_note_until = 0;
        }
        else
        {
/* the note */
            u_strcpy(pc_text, g_ac_note_line);
            i32_result = YES;
        }
    }
    return i32_result;
}

/* "Speed: ..." into pc_text while its time runs: 1, else 0 */
static int32_t speed_text(char *pc_text)
{
/* local variables */
    int32_t i32_result;

/* start values */
    i32_result = 0;
    if (g_ui32_speed_until != 0)
    {
        if ((int32_t)(TIMER - g_ui32_speed_until) >= 0)
        {
/* its time is over */
            g_ui32_speed_until = 0;
        }
        else
        {
/* the speed in use */
            if (g_i32_slow_mode != 0)
            {
                u_strcpy(pc_text, "Speed: normal");
            }
            else
            {
                u_strcpy(pc_text, "Speed: turbo");
            }
/* a text was written */
            i32_result = YES;
        }
    }
    return i32_result;
}

/* the recording status of the machine on the link */
static int32_t any_rec_status(char *pc_text)
{
/* local variables */
    int32_t i32_result;

    if (g_i32_machine_c64 != 0)
    {
        i32_result = c64rec_status(pc_text);
    }
    else
    {
/* the Spectrum's recorder */
        i32_result = rec_status(pc_text);
    }
    return i32_result;
}

/* is the machine on the link recording? */
static int32_t any_rec_active(void)
{
/* local variables */
    int32_t i32_result;

    if (g_i32_machine_c64 != 0)
    {
        i32_result = c64rec_active();
    }
    else
    {
/* the Spectrum's recorder */
        i32_result = rec_active();
    }
    return i32_result;
}

/* browser closed: show the bottom status row only while there is something to say */
/* (speed, a note, recording, or a tape that waits for the user) */
static void draw_bar(void)
{
    char ac_line[LINE_BUF];
    bool b_show;

/* the first that has something to say */
    b_show = speed_text(ac_line) != 0;
    if (!b_show)
    {
        b_show = note_text(ac_line) != 0;
    }
/* the recorder */
    if (!b_show)
    {
        b_show = any_rec_status(ac_line) != 0;
    }
/* the player, when it waits or failed */
    if (!b_show)
    {
        if ((g_i32_p_state == P_PAUSED) || (g_i32_p_state == P_STOPPED) || (g_i32_p_state == P_ERR))
        {
            b_show = status_text(ac_line) != 0;
        }
    }
/* one row at the bottom, or nothing */
    if (b_show)
    {
        osd_text(ROW_HELP, 0, ac_line, OSD_COLS, YES);
        osd_show(0);
    }
    else
    {
/* nothing to say */
        osd_hide();
    }
}

/* open the browser */
static void menu_open(void)
{
    g_i32_menu = YES;
/* the card, if it is not mounted yet */
    if (g_i32_mounted == 0)
    {
        mount_card();
    }
/* the folder changed behind the list */
    else if (g_i32_list_stale != 0)
    {
        load_dir(g_ui32_dir_clus);
    }
    else
    {
/* the list is up to date */
    }
    osd_clear();
    osd_show(YES);
}

/* The browser goes away only when the key that closed it is released: the */
/* Spectrum keyboard is unblocked at that moment and must not see Enter or */
/* Esc (BREAK). */
static void menu_close(void)
{
    g_i32_closing = YES;
}

/* path ("/a/b/") after entering a folder; returns 1 if it was "..", with the folder left in pc_from */
static int32_t path_step(char *pc_path, int32_t i32_size, const ENT *ps_ent, char *pc_from)
{
/* local variables */
    char *pc_end;
    int32_t i32_start;
    int32_t i32_len;
/* 1 = went up a folder */
    int32_t i32_result;

/* start values */
    pc_end = pc_path;
    i32_start = 0;
    i32_len = 0;
/* not going up, unless the entry is the parent folder */
    i32_result = 0;
    if ((ps_ent->ac_name[0] == '.') && (ps_ent->ac_name[YES] == '.'))
    {
/* path ends with '/': the last folder's name starts behind the slash before it */
        i32_len = u_strlen(pc_path) - YES;
        i32_start = i32_len - YES;
/* back to the slash before it */
        while ((i32_start > 0) && (pc_path[i32_start - YES] != '/'))
        {
            i32_start--;
        }
/* its name is kept, and cut from the path */
        u_strncpy(pc_from, pc_path + i32_start, i32_len - i32_start);
        pc_path[i32_start] = 0;
        i32_result = YES;
    }
    else
    {
/* going down: no folder was left */
        pc_from[0] = 0;
/* the folder's name and a slash, if the path has room */
        if ((u_strlen(pc_path) + u_strlen(ps_ent->ac_name) + PATH_EXTRA) < i32_size)
        {
            pc_end = pc_path + u_strlen(pc_path);
            pc_end = u_strcpy(pc_end, ps_ent->ac_name);
/* the slash */
            pc_end[0] = '/';
            pc_end[YES] = 0;
        }
    }
    return i32_result;
}

/* enter a folder of the list */
static void enter_dir(const ENT *ps_ent)
{
/* local variables */
    uint32_t ui32_clus;
    int32_t i32_index;
    bool b_found;

/* start values */
    ui32_clus = ps_ent->ui32_clus;
    i32_index = 0;
    b_found = false;
/* the path, then the folder's list */
    path_step(g_ac_path, (int32_t)sizeof g_ac_path, ps_ent, g_ac_came_from);
    if (load_dir(ui32_clus) == 0)
    {
/* cursor on the folder we left */
        while ((g_ac_came_from[0] != 0) && (i32_index < g_i32_nent) && !b_found)
        {
            if (u_stricmp(g_ps_ent[i32_index].ac_name, g_ac_came_from) == 0)
            {
/* its line (line 0 is the save line) */
                g_i32_cur = i32_index + YES;
                g_i32_top = 0;
                if (g_i32_cur >= LIST_LINES)
                {
/* in the middle of the screen */
                    g_i32_top = g_i32_cur - LIST_HALF;
                }
                b_found = true;
            }
            i32_index++;
        }
    }
}

/* move the cursor by a number of lines, in a list of i32_count items on i32_lines screen lines */
static void move_in(int32_t i32_delta, int32_t i32_count, int32_t i32_lines)
{
    if (i32_count != 0)
    {
        g_i32_cur += i32_delta;
/* inside the list */
        if (g_i32_cur < 0)
        {
            g_i32_cur = 0;
        }
/* not behind the last */
        if (g_i32_cur >= i32_count)
        {
            g_i32_cur = i32_count - YES;
        }
/* and on the screen */
        if (g_i32_cur < g_i32_top)
        {
            g_i32_top = g_i32_cur;
        }
/* not below the last line */
        if (g_i32_cur >= (g_i32_top + i32_lines))
        {
            g_i32_top = (g_i32_cur - i32_lines) + YES;
        }
    }
}

/* move the browser's cursor */
static void move(int32_t i32_delta)
{
    move_in(i32_delta, g_i32_nent + YES, LIST_LINES);
}

/* 8.3 name for messages */
static void name83(char *pc_dst, const char ac_name11[FAT_NAME11_LEN])
{
    int32_t i32_index;

    i32_index = 0;
/* the name part */
    while ((i32_index < NAME8_LEN) && (ac_name11[i32_index] != ' '))
    {
        *pc_dst = ac_name11[i32_index];
/* next character */
        pc_dst++;
        i32_index++;
    }
/* the dot */
    *pc_dst = '.';
    pc_dst++;
/* the extension */
    i32_index = NAME8_LEN;
    while ((i32_index < FAT_NAME11_LEN) && (ac_name11[i32_index] != ' '))
    {
/* one character over */
        *pc_dst = ac_name11[i32_index];
        pc_dst++;
        i32_index++;
    }
/* the text's end */
    *pc_dst = 0;
}

/* load a .z80 snapshot of the list */
static void snap_open(const ENT *ps_ent)
{
    int32_t i32_result;

/* the tape belongs to the old program */
    if (g_i32_p_state != P_IDLE)
    {
        player_stop();
    }
/* the snapshot */
    ff_open(&g_s_tape_file, ps_ent->ui32_clus, ps_ent->ui32_size);
    i32_result = snap_load(&g_s_tape_file);
    if (i32_result == SNAP_OK)
    {
/* what happened */
        note("Loaded ", ps_ent->ac_name);
    }
    else if (i32_result == SNAP_ERUN)
    {
        note("Spectrum not running", "");
    }
/* a bad file, or the card */
    else if (i32_result == SNAP_EBAD)
    {
        note("Not a usable .z80: ", ps_ent->ac_name);
    }
    else
    {
        note("Card error", "");
    }
}

/* load an .a8s snapshot of the list */
static void a8s_open(const ENT *ps_ent)
{
/* local variables */
    char ac_name[TEXT_BUF];
    int32_t i32_result;

/* the snapshot */
    ff_open(&g_s_tape_file, ps_ent->ui32_clus, ps_ent->ui32_size);
    i32_result = at_snap_load(&g_s_tape_file, ac_name);
    if ((i32_result == AT_OK) && (ac_name[0] != 0))
    {
/* Shift+Enter on that .atr */
        note("Loaded; disk was ", ac_name);
    }
    else if (i32_result == AT_OK)
    {
        note("Loaded ", ps_ent->ac_name);
    }
/* the Atari did not stop */
    else if (i32_result == AT_ERUN)
    {
        note("Atari not running", "");
    }
    else if (i32_result == AT_EMODEL)
    {
/* the wrong model; a missing cartridge */
        note("Snapshot of the other model", "");
    }
    else if (i32_result == AT_ECART)
    {
        note("Load cartridge first: ", ac_name);
    }
/* a bad file, or the card */
    else if (i32_result == AT_EBAD)
    {
        note("Not a usable .a8s: ", ps_ent->ac_name);
    }
    else
    {
        note("Card error", "");
    }
}

/* load an .a64 snapshot of the list */
static void a64_open(const ENT *ps_ent)
{
/* local variables */
    int32_t i32_result;

    if (g_i32_p_state != P_IDLE)
    {
        player_stop();
    }
/* the snapshot */
    ff_open(&g_s_tape_file, ps_ent->ui32_clus, ps_ent->ui32_size);
    i32_result = c64_snap_load(&g_s_tape_file);
    if (i32_result == C64_OK)
    {
/* what happened */
        note("Loaded ", ps_ent->ac_name);
    }
    else if (i32_result == C64_ERUN)
    {
        note("C64 not running", "");
    }
/* a bad file, or the card */
    else if (i32_result == C64_EBAD)
    {
        note("Not a usable .a64: ", ps_ent->ac_name);
    }
    else
    {
        note("Card error", "");
    }
}

/* load a .prg or .t64 of the list */
static void prg_open(const ENT *ps_ent)
{
/* local variables */
    char ac_info[INFO_BUF];
    int32_t i32_result;

/* the tape belongs to the old program */
    if (g_i32_p_state != P_IDLE)
    {
        player_stop();
    }
/* the program */
    ff_open(&g_s_tape_file, ps_ent->ui32_clus, ps_ent->ui32_size);
    i32_result = c64_prg_load(&g_s_tape_file, (int32_t)ps_ent->ui32_t64, ac_info);
    if (i32_result == C64_OK)
    {
/* what happened */
        note("Loaded ", ac_info);
    }
    else if (i32_result == C64_ERUN)
    {
        note("C64 not running", "");
    }
/* a bad file, or the card */
    else if (i32_result == C64_EBAD)
    {
        note("Not a usable file: ", ps_ent->ac_name);
    }
    else
    {
        note("Card error", "");
    }
}

/* a status line of the ROM install */
static void rom_progress(const char *pc_text)
{
    osd_text(ROW_PROGRESS, 0, "", OSD_COLS, 0);
    osd_text(ROW_PROGRESS, YES, pc_text, OSD_COLS - YES, 0);
}

/* the ROM install's error screen; then F12 is waited for and the card mounted again */
static void rom_error_screen(int32_t i32_result)
{
    if (i32_result == C64_ENOROM)
    {
/* the files are missing */
        osd_text(ROM_ROW_HELP1, 0, " Put KERNAL*, BASIC*, CHAR* files", OSD_COLS, 0);
        osd_text(ROM_ROW_HELP2, 0, " (8, 8, 4 KB) in /ROMS/C64/ on", OSD_COLS, 0);
/* the 1541's ROM is optional */
        osd_text(ROM_ROW_HELP3, 0, " the SD card (DOS1541* 16 KB for", OSD_COLS, 0);
        osd_text(ROM_ROW_HELP4, 0, " the disk drive).", OSD_COLS, 0);
    }
    else
    {
/* the flash or the card failed */
        if (i32_result == C64_EFLASH)
        {
            osd_text(ROM_ROW_HELP1, 0, " Flash write failed", OSD_COLS, 0);
        }
        else
        {
            osd_text(ROM_ROW_HELP1, 0, " Card error", OSD_COLS, 0);
        }
/* the other help rows empty */
        osd_text(ROM_ROW_HELP2, 0, "", OSD_COLS, 0);
        osd_text(ROM_ROW_HELP3, 0, "", OSD_COLS, 0);
        osd_text(ROM_ROW_HELP4, 0, "", OSD_COLS, 0);
    }
/* what the user can do */
    osd_text(ROM_ROW_RETRY, 0, " F12: try again", OSD_COLS, 0);
    osd_text(ROW_HELP, 0, "", OSD_COLS, YES);
/* F12 released, pressed, released (KEY0 / KEY1: the link check restarts the ESP32) */
    while ((KEYS & K_MENU) != 0)
    {
    }
    while ((KEYS & K_MENU) == 0)
    {
    }
    while ((KEYS & K_MENU) != 0)
    {
    }
/* the card may have been changed */
    mount_card();
}

/* L64 start: no ROMs in flash, or no 1541 ROM there while the card has one -> install them */
/* from /ROMS/C64/ on the card; a flash or card error is retried twice, then (and when the files */
/* are missing) F12 tries again */
static void c64_roms(void)
{
/* local variables */
    int32_t i32_result;
    int32_t i32_try;
    int32_t i32_have;
/* a wait's start, the end */
    uint32_t ui32_start;
    bool b_done;

/* start values */
    i32_result = C64_OK;
    i32_try = 0;
    ui32_start = TIMER;
/* the FPGA's ROM load is over (the pins are its until then) */
    while ((TIMER - ui32_start) < (ROM_WAIT_MS * CLK_PER_MS))
    {
    }
    i32_have = c64_rom_present();
/* everything is there, or the C64 ROMs are and the card has no 1541 ROM to add */
    b_done = i32_have == C64_ROM_WITH_1541;
    if (!b_done && (i32_have == C64_ROM_PRESENT))
    {
/* no card: nothing to add */
        if (g_i32_mounted == 0)
        {
            b_done = true;
        }
/* no 1541 ROM on the card */
        else if (c64_rom_card_1541() == 0)
        {
            b_done = true;
        }
        else
        {
/* the card has a 1541 ROM to add */
        }
    }
    while (!b_done)
    {
        osd_clear();
/* what is being done */
        osd_text(ROW_TITLE, 0, " L64: C64 ROMs", OSD_COLS, YES);
        if (i32_have == C64_ROM_PRESENT)
        {
            osd_text(ROM_ROW_STATE, 0, " Adding the 1541 ROM to the flash.", OSD_COLS, 0);
        }
        else
        {
/* a first install */
            osd_text(ROM_ROW_STATE, 0, " No ROMs in the flash yet.", OSD_COLS, 0);
        }
        osd_show(YES);
/* up to three tries; missing files end them at once */
        i32_try = 0;
        i32_result = C64_ENOROM;
        while ((i32_try < ROM_TRIES) && !b_done)
        {
/* without a card there are no files */
            i32_result = C64_ENOROM;
            if (g_i32_mounted != 0)
            {
                i32_result = c64_rom_install(rom_progress);
            }
/* installed */
            if (i32_result == C64_OK)
            {
                note("C64 ROMs installed", "");
                osd_clear();
/* the screen is given back */
                osd_hide();
                b_done = true;
            }
            else if (i32_result == C64_ENOROM)
            {
/* no more tries; or one more */
                i32_try = ROM_TRIES;
            }
            else
            {
                i32_try++;
            }
        }
        if (!b_done)
        {
/* failed */
            if (i32_have == C64_ROM_PRESENT)
            {
/* the C64 ROMs are there: run without the drive */
                note("1541 ROM not added", "");
                osd_clear();
/* the screen is given back */
                osd_hide();
                b_done = true;
            }
            else
            {
                rom_error_screen(i32_result);
            }
        }
    }
}

/* open the Bluetooth menu */
static void bt_menu(void)
{
/* instead of the browser */
    g_i32_menu = 0;
    g_i32_bt_on = YES;
    bt_open();
}

/* F4: joystick menu (the mode is INTPOS[29:28], rtl/zx_system.v) */

/* the name of a joystick mode on the machine on the link */
static const char *joy_name(int32_t i32_mode)
{
/* local variables */
    const char *pc_name;

    if (g_i32_machine_c64 != 0)
    {
        pc_name = g_apc_joy_name_c64[i32_mode];
    }
/* LTari */
    else if (g_i32_machine_atari != 0)
    {
        pc_name = g_apc_joy_name_at[i32_mode];
    }
    else
    {
/* LSpectrum */
        pc_name = g_apc_joy_name_zx[i32_mode];
    }
    return pc_name;
}

/* the number of joystick modes of the machine on the link */
static int32_t joy_modes(void)
{
/* local variables */
    int32_t i32_modes;

/* start values */
    i32_modes = JOY_MODES;
    if (g_i32_machine_atari != 0)
    {
/* LTari has two */
        i32_modes = JOY_MODES_ATARI;
    }
    return i32_modes;
}

/* open the joystick menu */
static void joy_menu(void)
{
    g_i32_menu = 0;
    g_i32_joy_on = YES;
/* the cursor on the mode in use */
    g_i32_joy_cur = (int32_t)((INTPOS & INT_JOY) >> INT_JOY_SH);
    if (g_i32_joy_cur >= joy_modes())
    {
        g_i32_joy_cur = 0;
    }
/* the full-screen OSD, empty */
    osd_clear();
    osd_show(YES);
}

/* the joystick menu's keys; 0 = close */
static int32_t joy_keys(uint32_t ui32_keys)
{
/* local variables */
    int32_t i32_result;

/* start values */
    i32_result = YES;
    if ((ui32_keys & (K_JOY | K_BACK | K_MENU)) != 0)
    {
        i32_result = 0;
    }
    else
    {
/* up and down move the cursor */
        if (((ui32_keys & K_UP) != 0) && (g_i32_joy_cur > 0))
        {
            g_i32_joy_cur--;
        }
/* down */
        if (((ui32_keys & K_DOWN) != 0) && (g_i32_joy_cur < (joy_modes() - YES)))
        {
            g_i32_joy_cur++;
        }
/* Enter selects the mode and closes */
        if ((ui32_keys & (K_ENTER | K_F11)) != 0)
        {
            INTPOS = (INTPOS & ~INT_JOY) | ((uint32_t)g_i32_joy_cur << INT_JOY_SH);
            note("Joystick: ", joy_name(g_i32_joy_cur));
/* the menu closes */
            i32_result = 0;
        }
    }
    return i32_result;
}

/* draw the joystick menu */
static void joy_draw(void)
{
/* the ports' texts of this machine, a line, its end */
    const char *const (*papc_port)[JOY_PORTS];
    char ac_line[LINE_BUF];
    char *pc_end;
/* a counter, the mode in use, inverse or normal */
    int32_t i32_index;
    int32_t i32_now;
    int32_t i32_inverse;

/* the table of this machine */
    papc_port = g_apc_port_zx;
    if (g_i32_machine_c64 != 0)
    {
        papc_port = g_apc_port_c64;
    }
/* LTari */
    else if (g_i32_machine_atari != 0)
    {
        papc_port = g_apc_port_at;
    }
    else
    {
/* the Spectrum's table */
    }
    pc_end = ac_line;
    i32_now = (int32_t)((INTPOS & INT_JOY) >> INT_JOY_SH);
    i32_inverse = 0;
/* the title, an empty row */
    osd_text(ROW_TITLE, 0, " Joysticks", OSD_COLS, YES);
    osd_text(ROW_PATH, 0, "", OSD_COLS, 0);
/* the modes, a star at the one in use */
    for (i32_index = 0; i32_index < JOY_MODES; i32_index++)
    {
        if (i32_index == i32_now)
        {
            pc_end = u_strcpy(ac_line, " * ");
        }
        else
        {
/* no star */
            pc_end = u_strcpy(ac_line, "   ");
        }
        u_strcpy(pc_end, joy_name(i32_index));
        i32_inverse = 0;
/* the cursor's line inverse */
        if (i32_index == g_i32_joy_cur)
        {
            i32_inverse = YES;
        }
/* a machine with fewer modes shows an empty line */
        if (i32_index < joy_modes())
        {
            osd_text(JOY_ROW_MODES + i32_index, 0, ac_line, OSD_COLS, i32_inverse);
        }
        else
        {
            osd_text(JOY_ROW_MODES + i32_index, 0, "", OSD_COLS, i32_inverse);
        }
    }
/* what the two ports are in the mode under the cursor */
    osd_text(JOY_ROW_GAP, 0, "", OSD_COLS, 0);
    osd_text(JOY_ROW_PORT1, 0, papc_port[g_i32_joy_cur][0], OSD_COLS, 0);
    osd_text(JOY_ROW_PORT2, 0, papc_port[g_i32_joy_cur][YES], OSD_COLS, 0);
/* the keys */
    osd_text(ROW_HELP, 0, "Enter=select  F4/Esc=exit", OSD_COLS, YES);
}

/* the raw keyboard report, read twice until both reads agree (32 bits from another clock domain) */
static uint32_t raw_report(void)
{
/* local variables */
    uint32_t ui32_first;
    uint32_t ui32_second;

    do
    {
/* read twice */
        ui32_first = KEYRAW;
        ui32_second = KEYRAW;
    } while (ui32_first != ui32_second);
/* a stable report */
    return ui32_first;
}

/* LTari, booting an .atr (an .xex decides itself: our loader switches BASIC off): three lines on */
/* the OSD, F1 = no BASIC (OPTION held at the cold start), F2 = with BASIC (as a real XL); */
/* BASIC_OFF / BASIC_ON, BASIC_ESC = Esc (nothing loaded) */
static int32_t basic_prompt(void)
{
/* local variables */
    uint8_t aui8_events[RAW_EVENTS_MAX];
    uint8_t ui8_mods;
    uint8_t ui8_code;
/* the raw report, counters */
    uint32_t ui32_report;
    int32_t i32_index;
    int32_t i32_count;
/* the answer, a key still held */
    int32_t i32_answer;
    bool b_held;

/* start values */
    ui8_mods = 0;
    ui8_code = 0;
    ui32_report = 0;
/* nothing read yet */
    i32_index = 0;
    i32_count = 0;
/* no answer yet; keys count as held */
    i32_answer = BASIC_NONE;
    b_held = true;
/* keys already held do not count */
    raw_events(aui8_events, &ui8_mods);
    osd_clear();
/* the question */
    osd_text(BASIC_ROW, 0, " How do you want to load it:", OSD_COLS, YES);
    osd_text(BASIC_ROW_F1, 0, "   <F1> No BASIC", OSD_COLS, YES);
    osd_text(BASIC_ROW_F2, 0, "   <F2> with BASIC", OSD_COLS, YES);
/* F1, F2 or Esc */
    while (i32_answer == BASIC_NONE)
    {
        i32_count = raw_events(aui8_events, &ui8_mods);
        for (i32_index = 0; (i32_index < i32_count) && (i32_answer == BASIC_NONE); i32_index++)
        {
/* F1: without BASIC */
            if (aui8_events[i32_index] == HID_F1)
            {
                i32_answer = BASIC_OFF;
            }
/* F2: with BASIC */
            else if (aui8_events[i32_index] == HID_F2)
            {
                i32_answer = BASIC_ON;
            }
/* Esc: not loaded */
            else if (aui8_events[i32_index] == HID_ESC)
            {
                i32_answer = BASIC_ESC;
            }
            else
            {
/* another key */
            }
        }
    }
/* released first: F2 is also the snapshot key */
    while (b_held)
    {
        ui32_report = raw_report();
        b_held = false;
/* any of the three keys in the report */
        for (i32_index = 0; i32_index < RAW_KEYS; i32_index++)
        {
            ui8_code = (uint8_t)(ui32_report >> (BITS_PER_BYTE * i32_index));
            if ((ui8_code == HID_F1) || (ui8_code == HID_F2) || (ui8_code == HID_ESC))
            {
/* still held */
                b_held = true;
            }
        }
    }
/* their presses are forgotten, the screen is empty again */
    raw_events(aui8_events, &ui8_mods);
    osd_clear();
    return i32_answer;
}

/* Enter on [Save to this folder]: ask for a name and start recording mode */
static void enter_save(void)
{
/* local variables */
    char ac_name11[FAT_NAME11_LEN];
    int32_t i32_result;

/* start values */
    i32_result = FAT_OK;
    if (g_i32_machine_atari != 0)
    {
        note("No tape saving on LTari", "");
    }
/* a name was typed */
    else if (name_prompt(ac_name11, 0) != 0)
    {
        if (g_i32_p_state != P_IDLE)
        {
            player_stop();
        }
/* the machine's recorder */
        if (g_i32_machine_c64 != 0)
        {
            i32_result = c64rec_start(g_ui32_dir_clus, ac_name11);
        }
        else
        {
            i32_result = rec_start(g_ui32_dir_clus, ac_name11);
        }
/* the folder gets a new file */
        g_i32_list_stale = YES;
/* recording runs with the browser closed */
        if (i32_result == FAT_OK)
        {
            menu_close();
        }
        else if (i32_result == FAT_EFULL)
        {
/* the error is shown in the browser */
            u_strcpy(g_ac_err_line, "Card or folder full");
        }
        else
        {
            u_strcpy(g_ac_err_line, "Card error");
        }
    }
    else
    {
/* Esc in the name prompt */
    }
}

/* Enter on an .xex or a .car (LTari): .xex runs, .car plugs in */
static void enter_xa(const ENT *ps_ent)
{
/* local variables */
    FFILE s_file;
    int32_t i32_result;

/* the file, as a program or as a cartridge */
    ff_open(&s_file, ps_ent->ui32_clus, ps_ent->ui32_size);
    if (ps_ent->ui32_xex != 0)
    {
        i32_result = at_xex_mount(&s_file, ps_ent->ac_name);
    }
    else
    {
/* a cartridge */
        i32_result = at_car_mount(&s_file, ps_ent->ac_name);
    }
    if (i32_result == AT_OK)
    {
        if (ps_ent->ui32_xex != 0)
        {
/* what was started */
            note("Run: ", ps_ent->ac_name);
        }
        else
        {
            note("Cartridge: ", ps_ent->ac_name);
        }
    }
    else if (i32_result == AT_EBAD)
    {
/* a bad file; a cartridge type not supported yet */
        note("Not usable: ", ps_ent->ac_name);
    }
    else if (i32_result == AT_ETYPE)
    {
        note("Cart type not yet: ", ps_ent->ac_name);
    }
    else
    {
/* the card failed; the browser closes */
        note("Card error", "");
    }
    menu_close();
}

/* Enter on an .atr (LTari): into D1:, and boot from it unless Shift is held (disk change only) */
static void enter_atr(const ENT *ps_ent)
{
/* local variables */
    FFILE s_file;
    int32_t i32_result;
    int32_t i32_swap;
/* with BASIC, booting, the raw keyboard report */
    int32_t i32_basic;
    int32_t i32_boot;
    uint32_t ui32_report;

/* start values */
    i32_basic = BASIC_ON;
    i32_boot = YES;
    ui32_report = raw_report();
/* Shift + Enter: change the disk only */
    i32_swap = (int32_t)((ui32_report >> RAW_MODS_SHIFT) & MOD_SHIFTS);
    if (i32_swap == 0)
    {
        i32_basic = basic_prompt();
    }
/* Esc in the question: back to the browser, nothing loaded */
    if (i32_basic >= 0)
    {
        if (i32_swap != 0)
        {
            i32_boot = 0;
        }
/* the disk goes in */
        ff_open(&s_file, ps_ent->ui32_clus, ps_ent->ui32_size);
        i32_result = at_atr_mount(&s_file, ps_ent->ac_name, (int32_t)ps_ent->ui32_ro, i32_boot, i32_basic);
        if (i32_result == AT_OK)
        {
/* a change, or a new start */
            if (i32_swap != 0)
            {
                note("Disk changed, D1: ", ps_ent->ac_name);
            }
            else
            {
                note("D1: ", ps_ent->ac_name);
            }
        }
/* a bad file, or the card */
        else if (i32_result == AT_EBAD)
        {
            note("Not an .atr: ", ps_ent->ac_name);
        }
        else
        {
            note("Card error", "");
        }
/* the browser closes */
        menu_close();
    }
}

/* Enter on a .d64 (L64): into the 1541 */
static void enter_d64(const ENT *ps_ent)
{
/* local variables */
    FFILE s_file;
    int32_t i32_result;

/* the disk goes into drive 8 */
    ff_open(&s_file, ps_ent->ui32_clus, ps_ent->ui32_size);
    i32_result = c64_d64_mount(&s_file, ps_ent->ac_name, (int32_t)ps_ent->ui32_ro);
    if (i32_result == C64_OK)
    {
/* what happened */
        note("Disk 8: ", ps_ent->ac_name);
    }
    else if (i32_result == C64_EBAD)
    {
        note("Not a .d64: ", ps_ent->ac_name);
    }
    else
    {
/* the card failed; the browser closes */
        note("Card error", "");
    }
    menu_close();
}

/* Enter on an entry of the list; true = the key press is done with (a folder is not: the */
/* other keys of the same pass still count, as before) */
static bool enter_entry(const ENT *ps_ent)
{
/* local variables */
    bool b_done;

/* start values */
    b_done = true;
    if (ps_ent->ui32_dir != 0)
    {
        enter_dir(ps_ent);
/* the browser stays open */
        b_done = false;
    }
    else if (ps_ent->ui32_xa != 0)
    {
        enter_xa(ps_ent);
    }
/* a disk image */
    else if (ps_ent->ui32_atr != 0)
    {
        enter_atr(ps_ent);
    }
    else if (ps_ent->ui32_z80 != 0)
    {
/* a snapshot of the machine on the link */
        if (g_i32_machine_c64 != 0)
        {
            a64_open(ps_ent);
        }
        else if (g_i32_machine_atari != 0)
        {
/* LTari, LSpectrum */
            a8s_open(ps_ent);
        }
        else
        {
            snap_open(ps_ent);
        }
        menu_close();
    }
/* a C64 program */
    else if ((ps_ent->ui32_prg != 0) || (ps_ent->ui32_t64 != 0))
    {
        prg_open(ps_ent);
        menu_close();
    }
/* a C64 disk */
    else if (ps_ent->ui32_d64 != 0)
    {
        enter_d64(ps_ent);
    }
    else
    {
/* a tape */
        player_open(ps_ent);
        menu_close();
    }
    return b_done;
}

/* the browser's keys */
static void menu_keys(uint32_t ui32_keys)
{
/* local variables */
    bool b_done;

/* start values */
    b_done = true;
    if ((ui32_keys & K_MENU) != 0)
    {
        menu_close();
    }
/* F3: the Bluetooth menu */
    else if ((ui32_keys & K_BT) != 0)
    {
        bt_menu();
    }
/* F4: the joystick menu */
    else if ((ui32_keys & K_JOY) != 0)
    {
        joy_menu();
    }
    else if (g_i32_mounted == 0)
    {
/* no card: Enter tries again, Esc closes */
        if ((ui32_keys & (K_ENTER | K_F11)) != 0)
        {
            mount_card();
        }
/* Esc */
        if ((ui32_keys & K_BACK) != 0)
        {
            menu_close();
        }
    }
    else
    {
/* a card is there: the list's keys */
        b_done = false;
    }
    if (!b_done)
    {
/* the cursor */
        if ((ui32_keys & K_UP) != 0)
        {
            move(-YES);
        }
/* down */
        if ((ui32_keys & K_DOWN) != 0)
        {
            move(YES);
        }
/* a page up */
        if ((ui32_keys & (K_LEFT | K_PGUP)) != 0)
        {
            move(-LIST_LINES);
        }
/* a page down */
        if ((ui32_keys & (K_RIGHT | K_PGDN)) != 0)
        {
            move(LIST_LINES);
        }
/* Enter: the save line, or an entry (the cursor may be on an empty line of an unmounted list) */
        if ((ui32_keys & (K_ENTER | K_F11)) != 0)
        {
            if (g_i32_cur == 0)
            {
/* the save line */
                enter_save();
                b_done = true;
            }
/* an entry */
            else if (g_i32_cur <= g_i32_nent)
            {
                b_done = enter_entry(&g_ps_ent[g_i32_cur - YES]);
            }
            else
            {
/* no entry there */
            }
        }
    }
    if (!b_done)
    {
/* Esc: the parent folder, or out of the browser from the root */
        if ((ui32_keys & K_BACK) != 0)
        {
            if ((g_i32_nent != 0) && (g_ps_ent[0].ui32_dir != 0) && (g_ps_ent[0].ac_name[0] == '.') &&
                (g_ps_ent[0].ac_name[YES] == '.'))
            {
                enter_dir(&g_ps_ent[0]);
            }
            else
            {
/* the root: the browser closes */
                menu_close();
            }
        }
/* the player's keys work in the browser too */
        if ((ui32_keys & K_KP5) != 0)
        {
            player_pause();
        }
/* rewind */
        if ((ui32_keys & K_REW) != 0)
        {
            player_rewind();
        }
/* stop */
        if ((ui32_keys & K_STOP) != 0)
        {
            player_stop();
        }
/* F6: speed */
        if ((ui32_keys & K_SPEED) != 0)
        {
            speed_toggle();
        }
/* F2: a snapshot */
        if ((ui32_keys & K_SNAP) != 0)
        {
            snap_save_ui();
            menu_close();
        }
    }
}

/* PgUp / PgDn with the browser closed: the frame interrupt 1/8 VGA line earlier / later (ZX only) */
static void int_pos_keys(uint32_t ui32_keys)
{
/* local variables */
    char ac_text[NUM_BUF];
    char *pc_end;
    uint32_t ui32_reg;
/* the position in pixels */
    uint32_t ui32_pixels;

    ui32_reg = INTPOS;
/* pixels after vsync */
    ui32_pixels = ((ui32_reg & INT_LINE_MASK) * INT_LINE_PIXELS) + ((ui32_reg >> INT_PIXEL_SHIFT) & INT_LINE_MASK);
    if (((ui32_keys & K_PGUP) != 0) && (ui32_pixels >= INT_STEP))
    {
        ui32_pixels -= INT_STEP;
    }
/* later */
    if (((ui32_keys & K_PGDN) != 0) && (ui32_pixels < (INT_LAST_LINE * INT_LINE_PIXELS)))
    {
        ui32_pixels += INT_STEP;
    }
/* the other bits of the register stay */
    INTPOS = (ui32_reg & (INT_NOCONT | INT_JOY)) | ((ui32_pixels % INT_LINE_PIXELS) << INT_PIXEL_SHIFT) |
             (ui32_pixels / INT_LINE_PIXELS);
/* "line.eighth" */
    pc_end = u_utoa(ac_text, ui32_pixels / INT_LINE_PIXELS);
    *pc_end = '.';
    pc_end++;
/* the eighth */
    u_utoa(pc_end, (ui32_pixels % INT_LINE_PIXELS) / INT_STEP);
    note("Frame INT: line ", ac_text);
}

/* the keys with the browser closed */
static void play_keys(uint32_t ui32_keys)
{
    if ((ui32_keys & K_SPEED) != 0)
    {
        speed_toggle();
    }
/* while recording */
    if (any_rec_active() != 0)
    {
/* recording: F12 (or F7) stops it */
        if ((ui32_keys & (K_MENU | K_STOP)) != 0)
        {
            if (g_i32_machine_c64 != 0)
            {
                c64rec_end();
            }
            else
            {
/* the Spectrum's recorder */
                rec_end();
            }
        }
        if ((ui32_keys & K_SNAP) != 0)
        {
            note("Recording: F12 first", "");
        }
    }
/* F2: a snapshot */
    else if ((ui32_keys & K_SNAP) != 0)
    {
        snap_save_ui();
    }
/* F5 on LTari */
    else if (((ui32_keys & K_CONT) != 0) && (g_i32_machine_atari != 0))
    {
/* LTari: F5 not used */
    }
    else if (((ui32_keys & K_CONT) != 0) && (g_i32_machine_c64 != 0))
    {
/* L64: SID 6581 / 8580 */
        INTPOS ^= INT_SID8580;
        if ((INTPOS & INT_SID8580) != 0)
        {
            note("SID: ", "8580");
        }
        else
        {
/* the older chip */
            note("SID: ", "6581");
        }
    }
    else if ((ui32_keys & K_CONT) != 0)
    {
/* contention on / off */
        INTPOS ^= INT_NOCONT;
        if ((INTPOS & INT_NOCONT) != 0)
        {
            note("Contention: ", "off");
        }
        else
        {
/* on */
            note("Contention: ", "on");
        }
    }
    else if (((ui32_keys & (K_PGUP | K_PGDN)) != 0) && (g_i32_machine_c64 == 0) && (g_i32_machine_atari == 0))
    {
/* frame interrupt position (ZX only) */
        int_pos_keys(ui32_keys);
    }
/* F12: the browser */
    else if ((ui32_keys & K_MENU) != 0)
    {
        g_ac_err_line[0] = 0;
        menu_open();
    }
/* F3: the Bluetooth menu */
    else if ((ui32_keys & K_BT) != 0)
    {
        bt_menu();
    }
/* F4: the joystick menu */
    else if ((ui32_keys & K_JOY) != 0)
    {
        joy_menu();
    }
    else
    {
/* the player */
        if ((ui32_keys & (K_F11 | K_KP5)) != 0)
        {
            player_pause();
        }
/* rewind */
        if ((ui32_keys & K_REW) != 0)
        {
            player_rewind();
        }
/* stop */
        if ((ui32_keys & K_STOP) != 0)
        {
            player_stop();
        }
    }
}

/* name for a recording (modal, browser open) */

/* new key presses from the raw keyboard report (USB HID codes); returns the count */
int32_t raw_events(uint8_t aui8_events[RAW_EVENTS_MAX], uint8_t *pui8_mods)
{
/* local variables */
    uint32_t ui32_report;
    uint8_t aui8_now[RAW_KEYS];
    int32_t i32_index;
/* a place in the last report, events found */
    int32_t i32_prev;
    int32_t i32_count;

/* start values */
    i32_prev = 0;
    i32_count = 0;
    ui32_report = raw_report();
/* three key codes and the modifiers */
    aui8_now[0] = (uint8_t)(ui32_report >> RAW_KEY0_SHIFT);
    aui8_now[YES] = (uint8_t)(ui32_report >> RAW_KEY1_SHIFT);
    aui8_now[RAW_KEYS - YES] = (uint8_t)ui32_report;
/* the modifiers */
    *pui8_mods = (uint8_t)(ui32_report >> RAW_MODS_SHIFT);
/* a key that was not in the last report is a new press */
    for (i32_index = 0; i32_index < RAW_KEYS; i32_index++)
    {
        if (aui8_now[i32_index] != 0)
        {
/* look for it in the last report */
            i32_prev = 0;
            while ((i32_prev < RAW_KEYS) && (g_aui8_raw_prev[i32_prev] != aui8_now[i32_index]))
            {
                i32_prev++;
            }
/* not there: a new press */
            if (i32_prev == RAW_KEYS)
            {
                aui8_events[i32_count] = aui8_now[i32_index];
                i32_count++;
            }
        }
    }
/* this report is the last one next time */
    for (i32_index = 0; i32_index < RAW_KEYS; i32_index++)
    {
        g_aui8_raw_prev[i32_index] = aui8_now[i32_index];
    }
    return i32_count;
}

/* the character of a key for a file name: letters, digits, minus (underscore with Shift); 0 = none */
char key_char(uint8_t ui8_code, uint8_t ui8_mods)
{
/* local variables */
    char c_char;

/* start values */
    c_char = 0;
    if ((ui8_code >= HID_A) && (ui8_code <= HID_Z))
    {
        c_char = (char)(('A' + ui8_code) - HID_A);
    }
/* the digits 1 to 9 */
    else if ((ui8_code >= HID_1) && (ui8_code <= HID_9))
    {
        c_char = (char)(('1' + ui8_code) - HID_1);
    }
/* 0 */
    else if ((ui8_code == HID_0) || (ui8_code == HID_KP_0))
    {
        c_char = '0';
    }
    else if ((ui8_code >= HID_KP_1) && (ui8_code <= HID_KP_9))
    {
/* the keypad's digits */
        c_char = (char)(('1' + ui8_code) - HID_KP_1);
    }
    else if (ui8_code == HID_MINUS)
    {
/* minus, or underscore with Shift */
        c_char = '-';
        if ((ui8_mods & MOD_SHIFTS) != 0)
        {
            c_char = '_';
        }
    }
/* the keypad's minus */
    else if (ui8_code == HID_KP_MINUS)
    {
        c_char = '-';
    }
    else
    {
/* a key without a character for a name */
    }
    return c_char;
}

/* the extension of the file a name is asked for */
static const char *prompt_ext(int32_t i32_snap)
{
/* local variables */
    const char *pc_ext;

/* start values */
    pc_ext = "TAP";
    if (i32_snap != 0)
    {
/* a snapshot of the machine on the link */
        if (g_i32_machine_c64 != 0)
        {
            pc_ext = "A64";
        }
        else if (g_i32_machine_atari != 0)
        {
/* LTari, LSpectrum */
            pc_ext = "A8S";
        }
        else
        {
            pc_ext = "Z80";
        }
    }
    return pc_ext;
}

/* the name prompt's screen */
static void prompt_draw(const char *pc_name, const char *pc_ext, const char *pc_msg, int32_t i32_snap)
{
/* local variables */
    char ac_line[LINE_BUF];
    char *pc_end;

/* the title */
    if (i32_snap == 0)
    {
        osd_text(ROW_TITLE, 0, " Save to SD card", OSD_COLS, YES);
    }
    else if (g_i32_machine_c64 != 0)
    {
/* a snapshot's kind */
        osd_text(ROW_TITLE, 0, " Save snapshot (.a64)", OSD_COLS, YES);
    }
    else if (g_i32_machine_atari != 0)
    {
        osd_text(ROW_TITLE, 0, " Save snapshot (.a8s)", OSD_COLS, YES);
    }
    else
    {
/* LSpectrum; then the folder */
        osd_text(ROW_TITLE, 0, " Save snapshot (.z80)", OSD_COLS, YES);
    }
    osd_text(ROW_PATH, 0, path_tail(), OSD_COLS, 0);
/* " Name: NAME_.EXT" */
    pc_end = u_strcpy(ac_line, " Name: ");
    pc_end = u_strcpy(pc_end, pc_name);
    pc_end = u_strcpy(pc_end, "_.");
/* the extension */
    u_strcpy(pc_end, pc_ext);
    osd_text(ROW_NAME, 0, ac_line, OSD_COLS, 0);
/* what happens after Enter */
    if (i32_snap != 0)
    {
        if (g_i32_machine_c64 != 0)
        {
            osd_text(PROMPT_ROW_TEXT1, 0, " The C64 is stopped. The", OSD_COLS, 0);
        }
/* LTari */
        else if (g_i32_machine_atari != 0)
        {
            osd_text(PROMPT_ROW_TEXT1, 0, " The Atari is stopped. The", OSD_COLS, 0);
        }
        else
        {
/* LSpectrum */
            osd_text(PROMPT_ROW_TEXT1, 0, " The Spectrum is stopped. The", OSD_COLS, 0);
        }
/* the same for every machine */
        osd_text(PROMPT_ROW_TEXT2, 0, " whole machine is saved; load", OSD_COLS, 0);
        osd_text(PROMPT_ROW_TEXT3, 0, " it again from the browser.", OSD_COLS, 0);
        osd_text(PROMPT_ROW_TEXT4, 0, "", OSD_COLS, 0);
    }
    else
    {
/* a recording */
        osd_text(PROMPT_ROW_TEXT1, 0, " After Enter, save on the", OSD_COLS, 0);
        if (g_i32_machine_c64 != 0)
        {
            osd_text(PROMPT_ROW_TEXT2, 0, " C64 as often as you like;", OSD_COLS, 0);
        }
        else
        {
/* LSpectrum */
            osd_text(PROMPT_ROW_TEXT2, 0, " Spectrum as often as you like;", OSD_COLS, 0);
        }
        osd_text(PROMPT_ROW_TEXT3, 0, " all blocks go into this file.", OSD_COLS, 0);
        osd_text(PROMPT_ROW_TEXT4, 0, " F12 stops recording.", OSD_COLS, 0);
    }
/* the message, and the keys */
    osd_text(ROW_STATUS, 0, pc_msg, OSD_COLS, 0);
    if (i32_snap != 0)
    {
        osd_text(ROW_HELP, 0, "Type name, Ent=save, Esc=cancel", OSD_COLS, YES);
    }
    else
    {
/* a recording */
        osd_text(ROW_HELP, 0, "Type name, Ent=start, Esc=back", OSD_COLS, YES);
    }
}

/* asks for an 8.3 name for a new file in the current folder: a .TAP for recording */
/* (proposes the first free SAVEnnnn) or, if i32_snap, a snapshot (.Z80, L64 .A64; no */
/* proposal); 1 = name in ac_name11, 0 = Esc */
static int32_t name_prompt(char ac_name11[FAT_NAME11_LEN], int32_t i32_snap)
{
/* local variables */
    const char *pc_ext;
    char ac_name[NAME8_BUF];
    char ac_msg[TEXT_BUF];
/* a typed character, the name's length, counters */
    char c_char;
    int32_t i32_len;
    int32_t i32_index;
/* the number of a proposed name, events, a name's existence */
    int32_t i32_number;
    int32_t i32_count;
    int32_t i32_exists;
/* the keys */
    uint8_t aui8_events[RAW_EVENTS_MAX];
    uint8_t ui8_mods;
    uint8_t ui8_code;
/* a free name found, done, the result */
    bool b_free;
    bool b_done;
    int32_t i32_result;

/* start values */
    pc_ext = prompt_ext(i32_snap);
    c_char = 0;
    i32_len = 0;
/* the first proposed number */
    i32_index = 0;
    i32_number = SAVE_FIRST;
    i32_count = 0;
/* nothing read yet */
    i32_exists = 0;
    ui8_mods = 0;
    ui8_code = 0;
/* not done, not saved */
    b_free = false;
    b_done = false;
    i32_result = 0;
/* an empty name */
    ac_name[0] = 0;
/* default for a recording: first free SAVEnnnn */
    while ((i32_snap == 0) && (i32_number < SAVE_END) && !b_free)
    {
        ac_name[0] = 'S';
/* the rest of SAVE */
        ac_name[SAVE_CHAR_1] = 'A';
        ac_name[SAVE_CHAR_2] = 'V';
        ac_name[SAVE_CHAR_3] = 'E';
/* the number as four digits */
        ac_name[SAVE_DIGIT_THOUSANDS] = (char)('0' + (i32_number / THOUSAND));
        ac_name[SAVE_DIGIT_HUNDREDS] = (char)('0' + ((i32_number / HUNDRED) % TEN));
        ac_name[SAVE_DIGIT_TENS] = (char)('0' + ((i32_number / TEN) % TEN));
/* ones, and the end of the text */
        ac_name[SAVE_DIGIT_ONES] = (char)('0' + (i32_number % TEN));
        ac_name[NAME8_LEN] = 0;
/* as a stored 8.3 name */
        for (i32_index = 0; i32_index < NAME8_LEN; i32_index++)
        {
            ac_name11[i32_index] = ac_name[i32_index];
        }
/* the extension TAP */
        ac_name11[N11_EXT] = 'T';
        ac_name11[N11_EXT_1] = 'A';
        ac_name11[N11_EXT_2] = 'P';
/* is that name free? */
        i32_len = NAME8_LEN;
        if (fat_exists(g_ui32_dir_clus, ac_name11) == 0)
        {
            b_free = true;
        }
        else
        {
/* the next number */
            i32_number++;
        }
    }
    ac_msg[0] = 0;
/* keys already held do not count */
    raw_events(aui8_events, &ui8_mods);
    osd_clear();
/* until Enter or Esc */
    while (!b_done)
    {
        prompt_draw(ac_name, pc_ext, ac_msg, i32_snap);
/* wait for key presses */
        do
        {
            i32_count = raw_events(aui8_events, &ui8_mods);
        } while (i32_count == 0);
/* key by key */
        for (i32_index = 0; (i32_index < i32_count) && !b_done; i32_index++)
        {
            ui8_code = aui8_events[i32_index];
            if (ui8_code == HID_ESC)
            {
/* Esc */
                osd_clear();
                b_done = true;
            }
            else
            {
/* a character for the name */
                c_char = key_char(ui8_code, ui8_mods);
                if ((c_char != 0) && (i32_len < NAME8_LEN))
                {
                    ac_name[i32_len] = c_char;
/* one longer; the message goes */
                    i32_len++;
                    ac_name[i32_len] = 0;
                    ac_msg[0] = 0;
                }
/* Backspace */
                if ((ui8_code == HID_BACKSPACE) && (i32_len != 0))
                {
                    i32_len--;
                    ac_name[i32_len] = 0;
                }
/* Enter: the name must be new */
                if (((ui8_code == HID_ENTER) || (ui8_code == HID_KP_ENTER)) && (i32_len != 0))
                {
                    for (i32_number = 0; i32_number < NAME8_LEN; i32_number++)
                    {
/* spaces behind the name */
                        ac_name11[i32_number] = ' ';
                        if (i32_number < i32_len)
                        {
                            ac_name11[i32_number] = ac_name[i32_number];
                        }
                    }
/* the extension */
                    ac_name11[N11_EXT] = pc_ext[0];
                    ac_name11[N11_EXT_1] = pc_ext[EXT_CHAR_1];
                    ac_name11[N11_EXT_2] = pc_ext[EXT_CHAR_2];
/* is there a file of that name? */
                    i32_exists = fat_exists(g_ui32_dir_clus, ac_name11);
                    if (i32_exists > 0)
                    {
                        u_strcpy(ac_msg, " Already exists: another name");
                    }
/* the card failed */
                    else if (i32_exists < 0)
                    {
                        u_strcpy(ac_msg, " Card error");
                    }
                    else
                    {
/* a new name: done */
                        osd_clear();
                        i32_result = YES;
                        b_done = true;
                    }
                }
            }
        }
    }
/* 1 = a name was chosen, 0 = Esc */
    return i32_result;
}

/* Print Screen: the picture as SCRNnnnn.BMP in the browser's current folder (no OSD in it) */
static void screenshot(void)
{
/* local variables */
    char ac_name11[FAT_NAME11_LEN];
    char ac_fname[FNAME_BUF];
    int32_t i32_result;

/* start values */
    i32_result = FAT_OK;
    if (g_i32_mounted == 0)
    {
        mount_card();
    }
/* still no card */
    if (g_i32_mounted == 0)
    {
        note("No SD card", "");
    }
/* a recording uses the file system */
    else if (any_rec_active() != 0)
    {
        note("Recording: F12 first", "");
    }
    else
    {
/* the first free name, then the machine's picture */
        i32_result = shot_name(g_ui32_dir_clus, ac_name11);
        if (i32_result == FAT_OK)
        {
            if (g_i32_machine_c64 != 0)
            {
/* L64 */
                i32_result = c64_screenshot(g_ui32_dir_clus, ac_name11);
            }
            else if (g_i32_machine_atari != 0)
            {
                i32_result = at_screenshot(g_ui32_dir_clus, ac_name11);
            }
            else
            {
/* LSpectrum */
                i32_result = snap_screenshot(g_ui32_dir_clus, ac_name11);
            }
        }
        g_i32_list_stale = YES;
        name83(ac_fname, ac_name11);
/* what happened */
        if (i32_result == FAT_OK)
        {
            note("Saved ", ac_fname);
        }
        else if (i32_result == SNAP_ERUN)
        {
/* the machine did not stop; no room */
            note("Spectrum not running", "");
        }
        else if (i32_result == FAT_EFULL)
        {
            note("Card or folder full", "");
        }
        else
        {
/* the card failed */
            note("Card error", "");
        }
    }
}

/* the Print Screen key (USB HID 0x46) in the raw keyboard report, polled every 20 ms; */
/* 1 on a new press */
static int32_t prtsc_pressed(void)
{
/* local variables */
    uint32_t ui32_report;
    int32_t i32_now;
    int32_t i32_result;

/* start values */
    ui32_report = 0;
    i32_now = 0;
    i32_result = 0;
/* looked at every few milliseconds */
    if ((TIMER - g_ui32_prt_time) >= (PRTSC_MS * CLK_PER_MS))
    {
        g_ui32_prt_time = TIMER;
        ui32_report = raw_report();
/* any of the three keys of the report */
        if ((((ui32_report >> RAW_KEY0_SHIFT) & RAW_KEY_MASK) == HID_PRINT_SCREEN) ||
            (((ui32_report >> RAW_KEY1_SHIFT) & RAW_KEY_MASK) == HID_PRINT_SCREEN) ||
            ((ui32_report & RAW_KEY_MASK) == HID_PRINT_SCREEN))
        {
            i32_now = YES;
        }
/* a new press */
        if ((i32_now != 0) && (g_i32_prt_was == 0))
        {
            g_i32_prt_was = YES;
            i32_result = YES;
        }
        else
        {
/* held, or released */
            g_i32_prt_was = i32_now;
        }
    }
    return i32_result;
}

/* stop the machine on the link and capture its state; false = it is not running (a note says so) */
static bool snap_stop_machine(void)
{
/* local variables */
    bool b_ok;

/* start values */
    b_ok = true;
    if (g_i32_machine_atari != 0)
    {
        if (at_snap_freeze() != AT_OK)
        {
/* it did not stop; else its state is taken */
            note("Atari not running", "");
            b_ok = false;
        }
        else
        {
            at_snap_capture();
        }
    }
/* L64 */
    else if (g_i32_machine_c64 != 0)
    {
        if (c64_snap_freeze() != C64_OK)
        {
            note("C64 not running", "");
/* not stopped */
            b_ok = false;
        }
        else
        {
            c64_snap_capture();
        }
    }
    else
    {
        if (snap_freeze() != SNAP_OK)
        {
/* LSpectrum did not stop */
            note("Spectrum not running", "");
            b_ok = false;
        }
        else
        {
            snap_capture();
        }
    }
/* true = the machine is stopped */
    return b_ok;
}

/* F2: stop the machine, ask for a name, save NAME.Z80 (L64: NAME.A64, LTari: NAME.A8S) in the current folder */
static void snap_save_ui(void)
{
/* local variables */
    char ac_name11[FAT_NAME11_LEN];
    char ac_fname[FNAME_BUF];
/* the result, fine so far */
    int32_t i32_result;
    bool b_ok;

/* start values */
    i32_result = FAT_OK;
    b_ok = true;
    if (g_i32_mounted == 0)
    {
/* the card */
        mount_card();
    }
    if (g_i32_mounted == 0)
    {
        note("No SD card", "");
/* no card; else the machine stops */
        b_ok = false;
    }
    if (b_ok)
    {
        b_ok = snap_stop_machine();
    }
/* the name, on the full screen */
    if (b_ok)
    {
        osd_clear();
        osd_show(YES);
/* a name was typed */
        if (name_prompt(ac_name11, YES) != 0)
        {
            name83(ac_fname, ac_name11);
/* what is being saved */
            osd_text(ROW_NAME, 0, " Saving ", OSD_COLS, 0);
            osd_text(ROW_NAME, SAVING_COL, ac_fname, SAVING_WIDTH, 0);
/* the machine's snapshot */
            if (g_i32_machine_atari != 0)
            {
                i32_result = at_snap_save(g_ui32_dir_clus, ac_name11);
            }
            else if (g_i32_machine_c64 != 0)
            {
/* L64 */
                i32_result = c64_snap_save(g_ui32_dir_clus, ac_name11);
            }
            else
            {
                i32_result = snap_save(g_ui32_dir_clus, ac_name11);
            }
            g_i32_list_stale = YES;
/* what happened */
            if (i32_result == FAT_OK)
            {
                note("Saved ", ac_fname);
            }
            else if (i32_result == FAT_EFULL)
            {
/* no room; the card failed */
                note("Card or folder full", "");
            }
            else
            {
                note("Card error", "");
            }
        }
/* the machine must not see Enter / Esc */
        while ((KEYS & CLOSE_KEYS) != 0)
        {
        }
/* the machine runs again */
        if (g_i32_machine_atari != 0)
        {
            at_snap_resume();
        }
        else if (g_i32_machine_c64 != 0)
        {
/* L64, LSpectrum; the screen is given back */
            c64_snap_resume();
        }
        else
        {
            snap_resume();
        }
        osd_clear();
/* back to the browser, or to the machine's picture */
        if (g_i32_menu != 0)
        {
            osd_show(YES);
        }
        else
        {
            osd_hide();
        }
    }
}

/* the machine menu (AMenu) on the link: flash update from the card, "no machines installed" */

/* wait some milliseconds, or until the menu is left */
static void wait_ms(uint32_t ui32_ms)
{
/* local variables */
    uint32_t ui32_start;
    bool b_wait;

/* start values */
    ui32_start = TIMER;
    b_wait = true;
    while (b_wait)
    {
/* the time is over */
        if ((TIMER - ui32_start) >= (ui32_ms * CLK_PER_MS))
        {
            b_wait = false;
        }
/* the menu is gone */
        else if (menu_present() == 0)
        {
            b_wait = false;
        }
        else
        {
/* register reads: the link check runs */
            (void)KEYS;
        }
    }
}

/* a full-screen message: title and three lines */
static void upd_screen(const char *pc_title, const char *pc_line1, const char *pc_line2, const char *pc_line3)
{
    osd_clear();
/* title, first and second line */
    osd_text(ROW_TITLE, 0, pc_title, OSD_COLS, YES);
    osd_text(UPD_ROW_LINE1, YES, pc_line1, OSD_COLS - YES, 0);
    osd_text(UPD_ROW_LINE2, YES, pc_line2, OSD_COLS - YES, 0);
/* third line; shown */
    osd_text(UPD_ROW_LINE3, YES, pc_line3, OSD_COLS - YES, 0);
    osd_show(YES);
}

/* the message stays until the board is switched off */
static void upd_halt(void)
{
    while (true)
    {
        wait_ms(UPD_HALT_MS);
    }
}

/* the progress bar of an update */
static void upd_bar(uint32_t ui32_done, uint32_t ui32_total)
{
/* local variables */
    char ac_line[UPD_BAR_BUF];
    int32_t i32_filled;
    int32_t i32_index;
/* redraw now */
    bool b_draw;

/* start values */
    i32_filled = 0;
    if (ui32_total != 0)
    {
        i32_filled = (int32_t)(((uint64_t)ui32_done * UPD_BAR_CELLS) / ui32_total);
    }
/* not more often than every 300 ms, but always at the end */
    b_draw = true;
    if ((TIMER - g_ui32_upd_time) < (UPD_BAR_MS * CLK_PER_MS))
    {
        if (ui32_done < ui32_total)
        {
/* too soon */
            b_draw = false;
        }
    }
    if (b_draw)
    {
        g_ui32_upd_time = TIMER;
/* the bar: filled cells as # */
        ac_line[0] = '[';
        for (i32_index = 0; i32_index < UPD_BAR_CELLS; i32_index++)
        {
            ac_line[YES + i32_index] = '.';
/* a filled cell */
            if (i32_index < i32_filled)
            {
                ac_line[YES + i32_index] = '#';
            }
        }
/* its end, and the row */
        ac_line[UPD_BAR_END] = ']';
        ac_line[UPD_BAR_END + YES] = 0;
        osd_text(UPD_ROW_BAR, 0, ac_line, OSD_COLS, 0);
    }
}

/* LUPDATE.BIN: check it, write the flash, say how it went */
static void menu_update(const DIRENT *ps_entry)
{
/* local variables */
    char ac_label[TEXT_BUF];
    int32_t i32_result;
    int32_t i32_menu_changed;
/* sectors written */
    uint32_t ui32_written;

    i32_menu_changed = 0;
    ui32_written = 0;
/* the file is checked completely first */
    upd_screen(" L update", "Checking LUPDATE.BIN ...", "", "Do not switch off.");
    g_ui32_upd_time = 0;
    i32_result = upd_check(ps_entry, upd_bar);
/* not usable */
    if (i32_result != UPD_OK)
    {
        if (i32_result == UPD_EBAD)
        {
            upd_screen(" L update", "LUPDATE.BIN is not a valid", "update file (damaged?).", "Nothing was changed.");
        }
        else
        {
/* the card failed; nothing more is done */
            upd_screen(" L update", "Card read error.", "", "Nothing was changed.");
        }
        upd_halt();
    }
/* the file is good: write */
    u_strncpy(ac_label, upd_label(), UPD_LABEL_MAX);
    upd_screen(" L update", ac_label, "Writing the flash ...", "Do not switch off.");
    g_ui32_upd_time = 0;
/* the update */
    i32_result = upd_run(ps_entry, upd_bar, &i32_menu_changed, &ui32_written);
    if (i32_result == UPD_EFLASH)
    {
        upd_screen(" L update", "Flash write error.", "LUPDATE.BIN is kept: switch", "off and on to try again.");
/* nothing more is done */
        upd_halt();
    }
/* the card failed */
    if (i32_result != UPD_OK)
    {
        upd_screen(" L update", "Card error.", "LUPDATE.BIN is kept: switch", "off and on to try again.");
        upd_halt();
    }
/* a new menu runs only after a power cycle */
    if (i32_menu_changed != 0)
    {
        upd_screen(" L update", "Update complete.", "Switch the board off and on.", "");
        upd_halt();
    }
/* done; was anything written? */
    if (ui32_written != 0)
    {
        upd_screen(" L update", "Update complete.", "", "");
    }
    else
    {
        upd_screen(" L update", "Update complete.", "(the flash was up to date)", "");
    }
/* shown for a while */
    wait_ms(UPD_DONE_MS);
}

/* LESP32.BIN: the ESP32's own firmware; on success the ESP32 restarts (the menu is found again) */
static void menu_espupd(const DIRENT *ps_entry)
{
/* local variables */
    int32_t i32_result;

    upd_screen(" L update", "ESP32 firmware (LESP32.BIN):", "Writing ...", "Do not switch off.");
/* the bar from the start; the update */
    g_ui32_upd_time = 0;
    i32_result = espupd_run(ps_entry, upd_bar);
    if (i32_result == ESPUPD_OK)
    {
/* installed: the ESP32 restarts into it */
        upd_screen(" L update", "ESP32 firmware installed.", "Restarting the ESP32 ...", "");
        wait_ms(UPD_REBOOT_MS);
        esp_reboot();
    }
/* it failed: the old firmware goes on */
    if (i32_result == ESPUPD_EBAD)
    {
        upd_screen(" L update", "LESP32.BIN is not an ESP32", "firmware file (v2.ino.bin).",
                   "Remove the file, then switch off and on.");
    }
    else if (i32_result == ESPUPD_EWRITE)
    {
/* the write failed, or the card */
        upd_screen(" L update", "ESP32 firmware write failed.", "The old firmware still runs.",
                   "Remove the file, then switch off and on.");
    }
    else
    {
        upd_screen(" L update", "Card read error.", "The old firmware still runs.",
                   "Remove the file, then switch off and on.");
    }
    upd_halt();
}

/* diagnostics: the bytes at the image start of the menu and the four machine slots, to the serial port */
static void log_slots(void)
{
/* local variables */
    char ac_line[SLOT_LINE_BUF];
    char *pc_end;
    uint8_t aui8_bytes[UPD_SLOT_BYTES];
/* counters */
    int32_t i32_slot;
    int32_t i32_index;

/* 56 EF EF EF where an image is */
    pc_end = u_strcpy(ac_line, "flash at +0x20 of menu / 4 machine slots:");
    for (i32_slot = 0; i32_slot <= UPD_SLOTS_LAST; i32_slot++)
    {
        upd_slot_bytes(i32_slot, aui8_bytes);
/* a space before each slot */
        *pc_end = ' ';
        pc_end++;
/* each byte as two hexadecimal digits */
        for (i32_index = 0; i32_index < UPD_SLOT_BYTES; i32_index++)
        {
            *pc_end = g_ac_hex[aui8_bytes[i32_index] >> HEX_HIGH_SHIFT];
            pc_end++;
/* the low digit */
            *pc_end = g_ac_hex[aui8_bytes[i32_index] & HEX_DIGIT_MASK];
            pc_end++;
        }
    }
    *pc_end = 0;
/* to the console */
    log_line(ac_line);
}

/* the loader while the machine menu is on the link: updates from the card, and the Bluetooth menu */
static void menu_main(void)
{
/* local variables */
    DIRENT s_entry;
    int32_t i32_shown;
    int32_t i32_bt_result;
/* keys, the times of the last card check and redraw */
    uint32_t ui32_keys;
    uint32_t ui32_check_time;
    uint32_t ui32_draw_time;
/* running, redraw, nothing to do */
    bool b_run;
    bool b_draw;
    bool b_idle;

/* start values */
    i32_shown = 0;
    i32_bt_result = 0;
    ui32_keys = 0;
/* nothing drawn yet */
    ui32_draw_time = 0;
    b_draw = false;
    b_idle = false;
/* an empty screen; the slots on the console */
    osd_hide();
    osd_clear();
    log_slots();
/* the checks run at once */
    ui32_check_time = TIMER - (UPD_CHECK_MS * CLK_PER_MS);
    b_run = menu_present() != 0;
    while (b_run)
    {
/* F3: the Bluetooth menu on the OSD (the menu takes no keys while the OSD is on) */
        ui32_keys = key_events();
/* a machine is starting: no more menu */
        if (menu_present() == 0)
        {
            b_run = false;
        }
/* the Bluetooth menu's keys */
        if (b_run)
        {
            if (g_i32_bt_on != 0)
            {
                i32_bt_result = bt_keys(ui32_keys);
/* closed */
                if (i32_bt_result == BT_KEYS_CLOSE)
                {
                    g_i32_bt_on = 0;
                    bt_close();
/* the menu must not see Enter */
                    while ((KEYS & (CLOSE_KEYS | K_BT)) != 0)
                    {
                    }
                    osd_clear();
                    osd_hide();
/* "no machines" is drawn again */
                    i32_shown = 0;
                }
            }
/* F3 opens the Bluetooth menu */
            else if ((ui32_keys & K_BT) != 0)
            {
                g_i32_bt_on = YES;
                bt_open();
            }
            else
            {
/* no key for the Bluetooth menu */
            }
/* redraw on news from the ESP32, a key, a typed PIN, and 5 times a second */
            b_draw = bt_service() != 0;
            if (!b_draw)
            {
                b_draw = ui32_keys != 0;
            }
/* the PIN changed */
            if (!b_draw)
            {
                b_draw = i32_bt_result == BT_KEYS_REDRAW;
            }
/* the clock */
            if (!b_draw)
            {
                b_draw = (TIMER - ui32_draw_time) > (DRAW_MS * CLK_PER_MS);
            }
/* only the Bluetooth menu has something to draw here */
            if (b_draw)
            {
                if (g_i32_bt_on != 0)
                {
                    bt_draw();
                }
/* drawn now */
                ui32_draw_time = TIMER;
            }
            i32_bt_result = 0;
/* the card is looked at every 2 s, and not while the Bluetooth menu is open */
            b_idle = g_i32_bt_on != 0;
            if (!b_idle)
            {
                b_idle = (TIMER - ui32_check_time) < (UPD_CHECK_MS * CLK_PER_MS);
            }
/* nothing to do for a moment */
            if (b_idle)
            {
                wait_ms(UPD_IDLE_MS);
            }
            else
            {
                ui32_check_time = TIMER;
/* the ESP32's own firmware first */
                if (sd_init() == SD_OK)
                {
                    if (fat_mount() == FAT_OK)
                    {
                        if (espupd_find(&s_entry) > 0)
                        {
/* only with the FPGA still there */
                            if (link_alive() != 0)
                            {
                                menu_espupd(&s_entry);
                            }
                        }
                    }
                }
/* then the flash update */
                if (sd_ready() != 0)
                {
                    if (upd_find(&s_entry) > 0)
                    {
                        menu_update(&s_entry);
/* the screen is drawn again after it */
                        i32_shown = 0;
                    }
                }
                if (upd_machines_present() == 0)
                {
/* a machine started meanwhile: those flash reads were the reconfiguration's noise, and the */
/* screen would go to the new machine's OSD (seen on hardware) */
                    if (link_alive() == 0)
                    {
                        b_run = false;
                    }
                    else
                    {
/* said once */
                        if (i32_shown == 0)
                        {
                            upd_screen(" L", "No machines installed.", "Copy LUPDATE.BIN to the SD", "card's root folder.");
                        }
                        i32_shown = YES;
                    }
                }
/* machines are there: the text goes */
                else if (i32_shown != 0)
                {
                    osd_hide();
                    i32_shown = 0;
                }
                else
                {
/* machines are installed and nothing is shown */
                }
            }
        }
/* the next pass only while the menu is on the link */
        if (b_run)
        {
            b_run = menu_present() != 0;
        }
    }
/* the Bluetooth menu does not stay open */
    if (g_i32_bt_on != 0)
    {
        g_i32_bt_on = 0;
        bt_close();
    }
}

/* the loader for a machine: runs until the machine leaves the link (esp_hw.cpp ends the task) */
static void machine_main(void)
{
/* local variables */
    uint32_t ui32_keys;
    uint32_t ui32_draw_time;
    int32_t i32_last_state;
/* Bluetooth: a line came, the keys' result; redraw */
    int32_t i32_bt_line;
    int32_t i32_bt_result;
    bool b_draw;

/* start values */
    ui32_keys = 0;
    i32_last_state = NO_STATE;
    i32_bt_line = 0;
/* nothing yet; no tape plays */
    i32_bt_result = 0;
    b_draw = false;
    TAPE = TAPE_FLUSH;
/* an empty screen, the card */
    osd_hide();
    osd_clear();
    mount_card();
/* L64: its ROMs, its speed */
    if (g_i32_machine_c64 != 0)
    {
        c64_roms();
        c64_speed();
    }
/* the main loop */
    ui32_draw_time = TIMER;
    while (true)
    {
        ui32_keys = key_events();
/* a menu is closing */
        if (g_i32_closing != 0)
        {
/* a menu closes when the key that closed it is released */
            if ((KEYS & CLOSE_KEYS) == 0)
            {
                g_i32_closing = 0;
                g_i32_menu = 0;
/* the Bluetooth menu */
                if (g_i32_bt_on != 0)
                {
                    g_i32_bt_on = 0;
                    bt_close();
                }
/* the joystick menu; an empty screen */
                g_i32_joy_on = 0;
                osd_clear();
/* redraw: status bar or nothing */
                i32_last_state = NO_STATE;
            }
        }
/* the Bluetooth menu's keys */
        else if (g_i32_bt_on != 0)
        {
            i32_bt_result = bt_keys(ui32_keys);
            if (i32_bt_result == BT_KEYS_CLOSE)
            {
/* it closes */
                g_i32_closing = YES;
            }
        }
/* the joystick menu's keys */
        else if (g_i32_joy_on != 0)
        {
            if (joy_keys(ui32_keys) == 0)
            {
                g_i32_closing = YES;
            }
        }
/* the browser's keys */
        else if (g_i32_menu != 0)
        {
            menu_keys(ui32_keys);
        }
        else
        {
/* no menu: the player's keys */
            play_keys(ui32_keys);
        }
/* the tape, and the machine's own services */
        player_service();
        if (g_i32_machine_c64 != 0)
        {
            c64rec_service();
/* the 1541's disk */
            c64_d64_service();
        }
        else if (g_i32_machine_atari != 0)
        {
            at_service();
        }
        else
        {
/* the Spectrum's recorder */
            rec_service();
        }
/* Print Screen, not while a menu of its own is open */
        if (prtsc_pressed() != 0)
        {
            if ((g_i32_bt_on == 0) && (g_i32_joy_on == 0))
            {
                screenshot();
            }
        }
/* lines from the ESP32's Bluetooth part */
        i32_bt_line = bt_service();
/* redraw on a key, on a player state change, on news from the ESP32 (menu open), */
/* and 5 times a second (block number) */
        b_draw = ui32_keys != 0;
        if (!b_draw)
        {
            b_draw = g_i32_p_state != i32_last_state;
        }
/* news for the Bluetooth menu */
        if (!b_draw)
        {
            b_draw = (g_i32_bt_on != 0) && ((i32_bt_line != 0) || (i32_bt_result == BT_KEYS_REDRAW));
        }
/* the clock */
        if (!b_draw)
        {
            b_draw = (TIMER - ui32_draw_time) > (DRAW_MS * CLK_PER_MS);
        }
/* what is on the screen */
        if (b_draw)
        {
            if (g_i32_bt_on != 0)
            {
                bt_draw();
            }
/* the joystick menu */
            else if (g_i32_joy_on != 0)
            {
                joy_draw();
            }
/* the browser */
            else if (g_i32_menu != 0)
            {
                draw_menu();
            }
            else
            {
/* the status bar */
                draw_bar();
            }
/* drawn now */
            i32_last_state = g_i32_p_state;
            ui32_draw_time = TIMER;
        }
    }
}

/* the loader's task (esp_hw.cpp): returns only when the machine menu is left */
int main(void)
{
    if (g_i32_machine_menu != 0)
    {
        menu_main();
    }
    else
    {
/* a machine */
        machine_main();
    }
    return 0;
}

/* every module back to the state after a start (esp_hw.cpp, before the loader runs for the next */
/* machine: no ESP32 restart, so the Bluetooth connection stays) */
void loader_reset_all(void)
{
/* the list's memory stays allocated */
    if (g_ps_ent != NULL)
    {
        u_memset(g_ps_ent, 0, (uint32_t)g_i32_ent_max * sizeof(ENT));
    }
/* an empty list */
    g_i32_nent = 0;
    g_i32_cur = 0;
/* the top, not cut */
    g_i32_top = 0;
    g_i32_truncated = 0;
/* the browser and the menus */
    g_i32_mounted = 0;
    g_i32_menu = 0;
    g_i32_closing = 0;
/* the list */
    g_i32_list_folders = 0;
    g_i32_list_stale = 0;
/* the two menus */
    g_i32_bt_on = 0;
    g_i32_joy_on = 0;
    g_i32_joy_cur = 0;
/* the folder */
    g_ui32_dir_clus = 0;
    u_memset(g_ac_path, 0, sizeof g_ac_path);
    u_memset(g_ac_came_from, 0, sizeof g_ac_came_from);
/* the player */
    u_memset(&g_s_tape_file, 0, sizeof g_s_tape_file);
    g_i32_p_state = 0;
    g_i32_p_tzx = 0;
/* no stop block, no pause, no name */
    g_i32_p_stop = 0;
    g_ui32_p_block = 0;
    u_memset(g_ac_p_name, 0, sizeof g_ac_p_name);
/* the keys and the messages */
    g_ui32_key_prev = 0;
    g_ui32_rep_time = 0;
    u_memset(g_ac_err_line, 0, sizeof g_ac_err_line);
/* the speed text, the note */
    g_ui32_speed_until = 0;
    u_memset(g_ac_note_line, 0, sizeof g_ac_note_line);
    g_ui32_note_until = 0;
/* the raw keyboard report */
    u_memset(g_aui8_raw_prev, 0, sizeof g_aui8_raw_prev);
/* the update bar and Print Screen */
    g_ui32_upd_time = 0;
    g_ui32_prt_time = 0;
    g_i32_prt_was = 0;
/* the modules */
    at_reset();
    c64_reset();
    save_reset();
/* screenshots, snapshots, the tape */
    shot_reset();
    snap_reset();
    tape_reset();
/* the Bluetooth menu, the file system */
    bt_reset();
    fat_reset();
}
