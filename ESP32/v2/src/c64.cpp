/* c64.c -- L64 (Commodore 64 core, L64/ep4_ce15/rtl/c64_system.v) on the SD loader */
/* ROMs: the Commodore ROMs are not part of the project. The user puts them on the card in */
/* /ROMS/C64/ (file names starting KERNAL, BASIC, CHAR and, for the 1541 drive, DOS1541 or */
/* 1541, e.g. VICE's kernal-901227-03.bin, basic-901226-01.bin, chargen-901225-01.bin, */
/* dos1541-325302-01+901229-05.bin; 8 / 8 / 4 / 16 KB). They are written into the */
/* configuration flash at 0x580000 through the FPGA's flash pass-through (tape loader */
/* register FLASH, SPI byte engine): 48 KB image = 4 KB header (F3 "L64 ROMS" + 4 spaces, byte 13 */
/* = 1 with a 1541 ROM), CHAR, BASIC, KERNAL, 8 KB FF, 1541 ROM (16 KB, or FF) */
/* (L64/ep4_ce15/tools/mk_c64rom.py makes the same image). After the write is verified, */
/* RELOAD makes the FPGA copy the ROMs into SDRAM and restart the C64. */
/* .prg / .t64: the CPU is stopped (snapshot freeze, at an instruction boundary) and the */
/* bytes are written into RAM with snapshot MWR commands (bursts on the link). A BASIC */
/* program ($0801) gets the BASIC pointers (VARTAB/ARYTAB/STREND = end) and RUN + RETURN */
/* in the keyboard buffer; other load addresses only set the end-of-load pointer. */
/* .tap (C64-TAPE-RAW): each byte b > 0 is one pulse of b * 8 cycles, 0 is an overflow */
/* (version 0: 256 * 8; version 1: the next 3 bytes are the length in cycles). A pulse */
/* becomes two pulse player half periods, so the CIA FLAG input (the read line) sees */
/* one falling edge per pulse. The player counts C64 cycles while the cassette motor is */
/* on, so the KERNAL's motor control pauses the tape as on a real datasette. */
/* Recording: the recorder (tape_loader REC) reports every edge of the cassette write line */
/* (6510 port bit 3) with the cycles since the previous one; two edges make one pulse, */
/* written as one byte (cycles / 8) or as 0 + 24-bit length (version 1) when longer (the */
/* edge after a pause carries the whole time since the previous edge). While */
/* armed, the C64 (CPU and CIAs) is held until each event has been read. The sense line */
/* shows PLAY pressed (TAPE_ON) during recording mode. */
/* Snapshots (.A64, our format): F2 freezes the C64 at an instruction boundary and saves */
/* a 32-byte header (CPU registers, the CIAs' CRA / CRB / interrupt masks), the 64 KB RAM */
/* and the 4 KB I/O shadow ($D000-$DFFF: the FPGA keeps the last value the CPU wrote to */
/* every VIC-II, SID, colour RAM and CIA register). Loading writes the RAM back, then a */
/* restore program into the FPGA's restore bank and resets the CPU alone in restore mode: */
/* the program writes the I/O registers, the 6510 port and the stack, loads A / X / Y / S */
/* and leaves with RTI into the snapshot (the FPGA then switches back to the real memory). */
/* Not saved: the 1541, the SID's and the timers' running state, the raster position. */
#include <stddef.h>
#include "hw.h"
#include "hal.h"
/* the card, the Spectrum's tape player, string functions */
#include "fat.h"
#include "tape.h"
#include "util.h"
/* this module's header, the Spectrum recorder's speed switch */
#include "c64.h"
#include "save.h"
/* screenshots, the flash */
#include "shot.h"
#include "flash.h"

/* snapshot port commands, and the command's place in the register */
#define C_MRD 1
#define C_MWR 2
#define C_REG 3
/* control, and where the command is */
#define C_CTL 4
#define CMD_SHIFT 28
/* the ROM image in the flash: where, how long; the waits allowed for an erase and a page */
#define ROM_BASE 0x580000u
#define ROM_LEN 49152u
/* the waits */
#define ERASE_MS 2000u
#define PROG_MS 50u
/* the flash: commands, page and erase block sizes */
#define FL_CMD_PAGE_PROGRAM 0x02
#define FL_CMD_READ 0x03
#define FL_CMD_SECTOR_ERASE 0x20
/* page and erase block */
#define FL_PAGE 256u
#define FL_BLOCK 4096u
/* the image: header mark as written and as a bit-reversed .jic stores it, the signature, the 1541 flag */
#define IMG_MARK 0xF3
#define IMG_MARK_REV 0xCF
#define IMG_SIG_OFF 1
/* its length, the 1541 flag */
#define IMG_SIG_LEN 12
#define IMG_1541_OFF 13
#define IMG_1541 0x01
/* the flag bit-reversed, bytes read, an erased byte */
#define IMG_1541_REV 0x80
#define IMG_HDR_READ 14
#define IMG_ERASED 0xFF
/* the image's parts: header 4 KB, CHAR 4 KB, BASIC 8 KB, KERNAL 8 KB, 8 KB unused, 1541 ROM 16 KB */
#define IMG_CHAR_OFF 4096u
#define IMG_BASIC_OFF 8192u
#define IMG_KERNAL_OFF 16384u
/* the gap, the 1541's ROM */
#define IMG_GAP_OFF 24576u
#define IMG_1541_ROM_OFF 32768u
/* the ROM files: index in the search result, how many kinds of names, their sizes */
#define ROM_CHAR 0
#define ROM_BASIC 1
#define ROM_KERNAL 2
/* the 1541's ROM, the number of kinds and of names */
#define ROM_1541 3
#define ROM_KINDS 4
#define ROM_NAMES 5
/* the sizes */
#define ROM_SIZE_4K 4096u
#define ROM_SIZE_8K 8192u
#define ROM_SIZE_16K 16384u
/* bits of a byte, for the bit reversal */
#define BITS_PER_BYTE 8
#define BIT_HIGH 0x80
#define ASCII_CASE_OFFSET 32
/* the directory callback's answers */
#define SCAN_GO_ON 0
#define SCAN_STOP 1
/* freezing the CPU */
#define CTL_FREEZE 1u
#define FREEZE_MS 200u
/* the C64's memory: its size, and addresses of the BASIC and KERNAL variables used */
#define C64_RAM 0x10000u
#define ADDR_MASK 0xFFFFu
#define BASIC_START 0x0801u
/* BASIC's pointers to its variables */
#define ZP_VARTAB 0x2Du
#define ZP_STREND 0x31u
#define ZP_POINTER_STEP 2u
/* where a load ended */
#define ZP_LOAD_END_LOW 0xAEu
#define ZP_LOAD_END_HIGH 0xAFu
/* the keyboard buffer's count, the cursor */
#define ZP_KEY_COUNT 0xC6u
#define ZP_CURSOR_BLINK 0xCCu
#define ZP_CHAR_UNDER_CURSOR 0xCEu
/* the screen line and column of the cursor */
#define ZP_LINE_LOW 0xD1u
#define ZP_LINE_HIGH 0xD2u
#define ZP_CURSOR_COLUMN 0xD3u
/* direct mode */
#define ZP_MSG_FLAG 0x9Du
#define MSG_FLAG_DIRECT 0x80u
/* the keyboard buffer, the IRQ vector */
#define KEY_BUFFER 0x0277u
#define VEC_IRQ_LOW 0x0314u
#define VEC_IRQ_HIGH 0x0315u
/* the KERNAL's own IRQ routine */
#define KERNAL_IRQ_LOW 0x31u
#define KERNAL_IRQ_HIGH 0xEAu
/* RUN and RETURN typed */
#define KEY_RETURN 13
#define RUN_KEYS 4
#define ONE_KEY 1
/* a screen line */
#define SCREEN_COLS 40u
/* hexadecimal output */
#define HEX_FIRST_SHIFT 12
#define HEX_DIGIT_BITS 4
#define HEX_DIGIT_MASK 15u
/* .t64: the number of directory entries, the directory, one entry and its fields */
#define T64_ENTRIES_OFF 0x22u
#define T64_DIR_OFF 0x40u
#define T64_ENTRY_LEN 32u
/* its type */
#define T64_ENTRY_TYPE 0
#define T64_TYPE_FILE 1
/* the start address */
#define T64_START_LOW 2
#define T64_START_HIGH 3
/* the end address */
#define T64_END_LOW 4
#define T64_END_HIGH 5
/* the data's offset in the file */
#define T64_OFF_0 8
#define T64_OFF_1 9
/* its upper bytes */
#define T64_OFF_2 10
#define T64_OFF_3 11
/* .prg: the load address and at least one byte */
#define PRG_MIN_SIZE 3u
#define PRG_ADDR_LEN 2u
/* bytes and shifts */
#define BYTE_1 1u
#define BYTE_2 2u
#define BYTE_3 3u
/* their shifts */
#define SHIFT_BYTE 8
#define SHIFT_WORD 16
#define SHIFT_3_BYTES 24
/* a byte's mask */
#define BYTE_MASK 0xFFu
/* .tap: signature, header, version, pulse lengths in units of 8 cycles */
#define TAP_SIG_LEN 12
#define TAP_HDR_LEN 20u
#define TAP_VERSION_MAX 1
/* version 1, the unit, what a 0 byte means in version 0 */
#define TAP_VERSION_1 1
#define TAP_UNIT 8u
#define TAP_OVERFLOW_V0 2048u
/* limits of a pulse */
#define TAP_LEN_MIN 2u
#define TAP_HALVES 2u
#define TAP_ROUND 4u
/* the longest short and long pulse, reserved bytes */
#define TAP_BYTE_MAX 255u
#define TAP_LONG_MAX 0xFFFFFFu
#define TAP_RESERVED 7
/* where the data size is */
#define TAP_SIZE_OFF 16u
/* recording: events handled in one call, the count in an event */
#define EVENTS_PER_CALL 64
#define EVENT_TIME_MASK 0xFFFFFFu
/* MCTL of the 1541: disk in, read only, turbo allowed, the track in the buffer, the disk ID */
#define MC_DISK 1u
#define MC_READ_ONLY 2u
#define MC_TURBO 4u
/* where the fields are */
#define MC_RO_SHIFT 1
#define MC_TRACK_SHIFT 8
/* the two ID characters */
#define MC_ID1_SHIFT 16
#define MC_ID2_SHIFT 24
/* MSTAT of the 1541: the head's track, the dirty sector bits */
#define MS_TRACK_MASK 0x3Fu
#define MS_DIRTY_SHIFT 8
#define MS_DIRTY_MASK 0x1FFFFFu
/* the disk: tracks, sectors per track in the four zones, the BAM track and the disk ID in it */
#define D64_MIN_SIZE 174848u
#define D64_TRACKS 35u
#define D64_SECTOR 256u
/* the last track of each zone */
#define D64_ZONE1_LAST 17u
#define D64_ZONE2_LAST 24u
#define D64_ZONE3_LAST 30u
/* sectors per track */
#define D64_ZONE1_SECTORS 21u
#define D64_ZONE2_SECTORS 19u
#define D64_ZONE3_SECTORS 18u
/* zone 4, the BAM */
#define D64_ZONE4_SECTORS 17u
#define D64_BAM_TRACK 18u
#define D64_ID_OFF 0xA2u
/* the first track; the pause of a disk change */
#define D64_FIRST_TRACK 1u
#define DISK_CHANGE_MS 300u
/* the track buffer in the snapshot port's address space */
#define TB_BASE 0x20000u
/* characters of a name shown in the status row */
#define STATUS_NAME_LEN 26
/* snapshots (.A64): the I/O shadow, the restore bank, the restore program and the colour RAM copy in it */
#define SH_BASE 0x3D000u
#define SH_LEN 4096u
#define RB_BASE 0x30000u
/* the header and the file */
#define A64_HDR 32u
#define A64_SIZE (A64_HDR + 65536u + 4096u)
/* the restore program, the colour RAM copy */
#define STUB 0x2000u
#define CRAM_BUF 0x3000u
#define CRAM_LEN 1024u
/* places in the shadow */
#define CRAM_PAGES 4u
#define SH_CRAM 0x800u
#define SH_SID 0x400u
/* the two CIAs */
#define SH_CIA1 0xC00u
#define SH_CIA2 0xD00u
/* the .A64 header */
#define A64_MAGIC_LEN 8
#define A64_VERSION_OFF 8
#define A64_VERSION 1
/* the 6502's registers */
#define A64_A 9
#define A64_X 10
#define A64_Y 11
/* P, S */
#define A64_P 12
#define A64_S 13
/* the PC */
#define A64_PCL 14
#define A64_PCH 15
/* CIA 1: interrupt mask, control registers */
#define A64_CIA1_IMR 16
#define A64_CIA1_CRA 17
#define A64_CIA1_CRB 18
/* CIA 2 */
#define A64_CIA2_IMR 19
#define A64_CIA2_CRA 20
#define A64_CIA2_CRB 21
/* the register words of the snapshot port */
#define REG_CPU 0
#define REG_CPU2 1
/* the two CIAs */
#define REG_CIA1 2
#define REG_CIA2 3
/* restore mode */
#define CTL_RESTORE_RESET 3u
#define CTL_RESTORE_RUN 1u
#define CTL_RESTORE_BUSY 1u
/* frame buffers held; the timeout */
#define CTL_HOLD_FB 4u
#define RESTORE_MS 500u
/* 6502 opcodes of the restore program */
#define OP_SEI 0x78
#define OP_CLD 0xD8
#define OP_LDA_IMM 0xA9
/* store, load */
#define OP_STA_ABS 0x8D
#define OP_LDA_ABS 0xAD
/* indexed */
#define OP_LDA_ABS_X 0xBD
#define OP_STA_ABS_X 0x9D
/* X, Y, the stack pointer */
#define OP_LDX_IMM 0xA2
#define OP_LDY_IMM 0xA0
#define OP_TXS 0x9A
/* the loop, return from interrupt */
#define OP_INX 0xE8
#define OP_BNE 0xD0
#define OP_RTI 0x40
/* the colour RAM copy loop: 4 x (LDA abs,X + STA abs,X) + INX + BNE = 27 bytes back */
#define CRAM_LOOP_BACK 27u
#define BRANCH_WRAP 0x100u
/* the reset vector and the stack */
#define VEC_RESET_LOW 0xFFFCu
#define VEC_RESET_HIGH 0xFFFDu
#define STACK_PAGE 0x0100u
/* what RTI takes from the stack */
#define STACK_RTI_FRAME 3
#define STACK_P 2
#define STACK_PCL 1
/* the chips as the restore program writes them */
#define VIC_BASE 0xD000u
#define VIC_LAST_REG 0x2Eu
#define VIC_SPRITE_COLLISION 0x1Eu
/* the collision and interrupt registers */
#define VIC_DATA_COLLISION 0x1Fu
#define VIC_IRQ_FLAGS 0x19u
#define VIC_IRQ_ACK_ALL 0x0F
/* the SID */
#define SID_BASE 0xD400u
#define SID_LAST_REG 0x18u
/* colour RAM, the CIAs */
#define CRAM_BASE_HIGH 0xD8u
#define CIA1_BASE 0xDC00u
#define CIA2_BASE 0xDD00u
/* CIA registers */
#define CIA_ICR 0x0Du
#define CIA_CRA 0x0Eu
#define CIA_CRB 0x0Fu
/* values written to them */
#define CIA_ICR_CLEAR_ALL 0x7F
#define CIA_ICR_SET 0x80
#define CIA_FORCE_LOAD 0x10
/* registers restored; the CPU's port */
#define CIA_RESTORED 8
#define CPU_PORT_DDR 0x0000u
#define CPU_PORT 0x0001u
/* its two bytes */
#define RAM_PORT_BYTES 2u
/* the screenshot: picture size, bytes of a buffer line, two dots per byte */
#define SHOT_WIDTH 400
#define SHOT_HEIGHT 284
#define SHOT_LAST_ROW 283
/* a buffer line */
#define FB_LINE_BYTES 256u
#define DOTS_PER_BYTE 2
/* a dot */
#define DOT_MASK 15u
#define DOT_SHIFT 4
#define NEXT_DOT 1
/* Kawari's palette has 6 bits per colour: widened to 8 */
#define PAL_WIDEN_UP 2
#define PAL_WIDEN_DOWN 4
/* flags as numbers */
#define YES 1
#define ONE 1u

/* the folder being looked for, and where it is */
typedef struct
{
/* the folder's name, its first cluster, found */
    const char *pc_dir;
    uint32_t ui32_clus;
    int32_t i32_found;
} FINDDIR;

/* the ROM files found: CHAR, BASIC, KERNAL, 1541 */
typedef struct
{
/* per kind of ROM: first cluster, size, found */
    uint32_t aui32_clus[ROM_KINDS];
    uint32_t aui32_size[ROM_KINDS];
    int32_t ai32_found[ROM_KINDS];
} FINDROM;

/* the starts of the ROM files' names, and the size each must have */
static const char *const g_apc_rom_prefix[ROM_NAMES] = { "CHAR", "BASIC", "KERNAL", "DOS1541", "1541" };
static const uint32_t g_aui32_rom_size[ROM_NAMES] = { ROM_SIZE_4K, ROM_SIZE_8K, ROM_SIZE_8K, ROM_SIZE_16K, ROM_SIZE_16K };
/* where each ROM starts in the image */
static const uint32_t g_aui32_img_base[ROM_KINDS] = { IMG_CHAR_OFF, IMG_BASIC_OFF, IMG_KERNAL_OFF, IMG_1541_ROM_OFF };
/* the image's signature now and before the rename (images installed earlier) */
static const char g_ac_sig[] = "L64 ROMS    ";
static const char g_ac_sig_old[] = "ADORE64 ROMS";
/* the start of a .tap file */
static const char g_ac_tap_sig[] = "C64-TAPE-RAW";
/* hexadecimal digits */
static const char g_ac_hex[] = "0123456789ABCDEF";
/* CIA registers restored from the shadow: DDRs, ports, timer latches */
static const uint8_t g_aui8_cia_regs[CIA_RESTORED] = { 2, 3, 0, 1, 4, 5, 6, 7 };
/* Kawari's palette, 6 bits per colour */
static const uint8_t g_aui8_k6[SHOT_COLOURS_4BPP][SHOT_RGB_LEN] =
{
    { 0x00, 0x00, 0x00 }, { 0x3f, 0x3f, 0x3f }, { 0x2b, 0x0a, 0x0a }, { 0x18, 0x36, 0x33 },
    { 0x2c, 0x0f, 0x2d }, { 0x12, 0x31, 0x12 }, { 0x0d, 0x0e, 0x31 }, { 0x39, 0x3b, 0x13 },
    { 0x2d, 0x16, 0x07 }, { 0x1a, 0x0e, 0x02 }, { 0x3a, 0x1d, 0x1b }, { 0x13, 0x13, 0x13 },
    { 0x21, 0x21, 0x21 }, { 0x29, 0x3e, 0x27 }, { 0x1c, 0x1f, 0x39 }, { 0x2d, 0x2d, 0x2d }
};
/* the ROM files on the card */
static FINDROM g_s_rom;
/* one page of the ROM image */
static uint8_t g_aui8_page[FL_PAGE];
/* the disk in: its name and one sector */
static char g_ac_disk_name[NAME_BUF_LEN];
static uint8_t g_aui8_sector[D64_SECTOR];
/* a snapshot's header, and (loading) the file's I/O shadow */
static uint8_t g_aui8_a64_hdr[A64_HDR];
static uint8_t g_aui8_a64_shadow[SH_LEN];
/* the .tap being played: file, version, state, second half period still to push (0 = none) */
static FFILE *g_ps_tap_file;
static int32_t g_i32_tap_ver;
/* state, the pending half */
static int32_t g_i32_tap_state;
static uint32_t g_ui32_tap_pend;
/* recording: on, one edge of a pulse seen, cycles collected, pulses written */
static int32_t g_i32_rec_on;
static int32_t g_i32_rec_half;
/* cycles, pulses */
static uint32_t g_ui32_rec_acc;
static uint32_t g_ui32_rec_pulses;
/* the disk in the 1541: its file, in, read only, the track in the buffer, MCTL's value for it */
static FFILE g_s_disk_file;
static int32_t g_i32_disk_on;
static int32_t g_i32_disk_ro;
/* the track in the buffer, MCTL's value */
static uint32_t g_ui32_disk_loaded;
static uint32_t g_ui32_disk_ctl;
/* where the restore program is being written */
static uint32_t g_ui32_stub_pc;

/* ROM image in flash: C64_ROM_NONE / C64_ROM_PRESENT / C64_ROM_WITH_1541 */
int32_t c64_rom_present(void)
{
/* local variables */
    uint8_t aui8_hdr[IMG_HDR_READ];
    uint8_t ui8_char;
    uint8_t ui8_rev;
/* loop counters */
    int32_t i32_index;
    int32_t i32_bit;
/* the four ways the signature may match */
    bool b_plain;
    bool b_rev;
    bool b_old_plain;
/* the result */
    bool b_old_rev;
    int32_t i32_result;

/* start values */
    ui8_char = 0;
    ui8_rev = 0;
/* counters */
    i32_index = 0;
    i32_bit = 0;
/* the signature may be stored as it is or bit-reversed (.jic images), under the new or the old name */
    b_plain = true;
    b_rev = true;
    b_old_plain = true;
/* no image until one of them holds */
    b_old_rev = true;
    i32_result = C64_ROM_NONE;
/* the header from the flash; the pass-through off */
    fl_read(ROM_BASE, aui8_hdr, sizeof aui8_hdr);
    FLASH = 0;
/* character by character */
    for (i32_index = 0; i32_index < IMG_SIG_LEN; i32_index++)
    {
        ui8_char = aui8_hdr[IMG_SIG_OFF + i32_index];
/* the byte with its bits in the other order */
        ui8_rev = 0;
        for (i32_bit = 0; i32_bit < BITS_PER_BYTE; i32_bit++)
        {
/* a set bit goes to the mirrored place */
            if ((ui8_char & (YES << i32_bit)) != 0)
            {
                ui8_rev |= (uint8_t)(BIT_HIGH >> i32_bit);
            }
        }
/* each of the four ways stays possible until a character differs */
        if (ui8_char != (uint8_t)g_ac_sig[i32_index])
        {
            b_plain = false;
        }
/* reversed */
        if (ui8_rev != (uint8_t)g_ac_sig[i32_index])
        {
            b_rev = false;
        }
/* the old name */
        if (ui8_char != (uint8_t)g_ac_sig_old[i32_index])
        {
            b_old_plain = false;
        }
/* the old name, reversed */
        if (ui8_rev != (uint8_t)g_ac_sig_old[i32_index])
        {
            b_old_rev = false;
        }
    }
/* byte 13: a 1541 ROM is included */
    if ((aui8_hdr[0] == IMG_MARK) && (b_plain || b_old_plain))
    {
        i32_result = C64_ROM_PRESENT;
/* with the 1541's ROM */
        if (aui8_hdr[IMG_1541_OFF] == IMG_1541)
        {
            i32_result = C64_ROM_WITH_1541;
        }
    }
/* a bit-reversed image */
    else if ((aui8_hdr[0] == IMG_MARK_REV) && (b_rev || b_old_rev))
    {
        i32_result = C64_ROM_PRESENT;
/* with the 1541's ROM */
        if (aui8_hdr[IMG_1541_OFF] == IMG_1541_REV)
        {
            i32_result = C64_ROM_WITH_1541;
        }
    }
    else
    {
/* no image */
    }
    return i32_result;
}

/* ROM install */

/* does a name start with a prefix (given in upper case), without regard to case? */
static bool prefix(const char *pc_name, const char *pc_prefix)
{
/* local variables */
    char c_name;
    bool b_result;

/* start values */
    c_name = 0;
    b_result = true;
/* character by character */
    while ((*pc_prefix != 0) && b_result)
    {
        c_name = *pc_name;
/* lower case letters count as upper case */
        if ((c_name >= 'a') && (c_name <= 'z'))
        {
            c_name = (char)(c_name - ASCII_CASE_OFFSET);
        }
/* a different character */
        if (c_name != *pc_prefix)
        {
            b_result = false;
        }
/* next */
        pc_name++;
        pc_prefix++;
    }
    return b_result;
}

/* directory callback: stop at the folder with the wanted name */
static int32_t dir_cb_find(const DIRENT *ps_entry, void *p_ctx)
{
/* local variables */
    FINDDIR *ps_find;
    int32_t i32_stop;

/* start values */
    ps_find = (FINDDIR *)p_ctx;
    i32_stop = SCAN_GO_ON;
    if (((ps_entry->ui8_attr & ATTR_DIR) != 0) && (u_stricmp(ps_entry->ac_name, ps_find->pc_dir) == 0))
    {
/* found: its first cluster */
        ps_find->ui32_clus = ps_entry->ui32_clus;
        ps_find->i32_found = YES;
        i32_stop = SCAN_STOP;
    }
/* the scan stops or goes on */
    return i32_stop;
}

/* directory callback: remember the ROM files (by the start of the name and the size) */
static int32_t rom_cb(const DIRENT *ps_entry, void *p_ctx)
{
/* local variables */
    FINDROM *ps_rom;
    int32_t i32_index;
    int32_t i32_kind;

/* start values */
    ps_rom = (FINDROM *)p_ctx;
    i32_index = 0;
    i32_kind = 0;
/* files only */
    if ((ps_entry->ui8_attr & ATTR_DIR) == 0)
    {
        for (i32_index = 0; i32_index < ROM_NAMES; i32_index++)
        {
/* the 1541 ROM has two possible names */
            i32_kind = i32_index;
            if (i32_kind > ROM_1541)
            {
                i32_kind = ROM_1541;
            }
/* the first file of a kind is taken */
            if ((ps_rom->ai32_found[i32_kind] == 0) && prefix(ps_entry->ac_name, g_apc_rom_prefix[i32_index]) &&
                (ps_entry->ui32_size == g_aui32_rom_size[i32_index]))
            {
                ps_rom->aui32_clus[i32_kind] = ps_entry->ui32_clus;
                ps_rom->aui32_size[i32_kind] = ps_entry->ui32_size;
/* found */
                ps_rom->ai32_found[i32_kind] = YES;
            }
        }
    }
    return SCAN_GO_ON;
}

/* one 256-byte page of the image at an offset (pages never cross a file boundary): C64_OK or FAT_EIO */
static int32_t image_page(uint32_t ui32_off)
{
/* local variables */
    FFILE s_file;
    int32_t i32_kind;
    int32_t i32_index;
/* a character, the result */
    int32_t i32_char;
    int32_t i32_result;

/* start values */
    i32_kind = ROM_CHAR;
    i32_index = 0;
    i32_char = 0;
/* no error; parts of the image that no file fills */
    i32_result = C64_OK;
    if ((ui32_off < IMG_CHAR_OFF) || ((ui32_off >= IMG_GAP_OFF) && (ui32_off < IMG_1541_ROM_OFF)) ||
        ((ui32_off >= IMG_1541_ROM_OFF) && (g_s_rom.ai32_found[ROM_1541] == 0)))
    {
/* the header's block, the gap, or the place of a 1541 ROM that is not there: erased bytes */
        u_memset(g_aui8_page, IMG_ERASED, sizeof g_aui8_page);
        if (ui32_off == 0)
        {
/* the header: mark, signature, 1541 flag */
            g_aui8_page[0] = IMG_MARK;
            u_memcpy(g_aui8_page + IMG_SIG_OFF, g_ac_sig, IMG_SIG_LEN);
/* the 1541 flag */
            g_aui8_page[IMG_1541_OFF] = 0;
            if (g_s_rom.ai32_found[ROM_1541] != 0)
            {
                g_aui8_page[IMG_1541_OFF] = IMG_1541;
            }
        }
    }
    else
    {
/* which ROM file the offset is in */
        if (ui32_off >= g_aui32_img_base[ROM_1541])
        {
            i32_kind = ROM_1541;
        }
/* the KERNAL */
        else if (ui32_off >= g_aui32_img_base[ROM_KERNAL])
        {
            i32_kind = ROM_KERNAL;
        }
/* BASIC, or the character ROM */
        else if (ui32_off >= g_aui32_img_base[ROM_BASIC])
        {
            i32_kind = ROM_BASIC;
        }
        else
        {
            i32_kind = ROM_CHAR;
        }
/* the page from that file */
        ff_open(&s_file, g_s_rom.aui32_clus[i32_kind], g_s_rom.aui32_size[i32_kind]);
        ff_seek(&s_file, ui32_off - g_aui32_img_base[i32_kind]);
/* 256 bytes */
        while ((i32_index < (int32_t)FL_PAGE) && (i32_result == C64_OK))
        {
            i32_char = ff_getc(&s_file);
            if (i32_char < 0)
            {
/* the card failed */
                i32_result = FAT_EIO;
            }
            else
            {
/* into the page */
                g_aui8_page[i32_index] = (uint8_t)i32_char;
                i32_index++;
            }
        }
    }
    return i32_result;
}

/* program one 256-byte page of the image: C64_OK, FAT_EIO or C64_EFLASH */
static int32_t write_page(uint32_t ui32_off)
{
/* local variables */
    uint32_t ui32_index;
    int32_t i32_result;

/* start values */
    ui32_index = 0;
    i32_result = C64_OK;
/* the page's contents */
    if (image_page(ui32_off) != C64_OK)
    {
        i32_result = FAT_EIO;
    }
    else
    {
/* write enable, then the page program command */
        fl_wren();
        fl_addr(FL_CMD_PAGE_PROGRAM, ROM_BASE + ui32_off);
/* the page's bytes */
        for (ui32_index = 0; ui32_index < FL_PAGE; ui32_index++)
        {
            fl_send(g_aui8_page[ui32_index]);
        }
/* the flash programs the page */
        fl_end();
        if (fl_wait(PROG_MS) != FL_OK)
        {
/* it did not finish */
            i32_result = C64_EFLASH;
        }
    }
    return i32_result;
}

/* compare the flash with the image from an offset to the end: C64_OK, FAT_EIO or C64_EFLASH */
static int32_t check_pages(uint32_t ui32_first)
{
/* local variables */
    uint32_t ui32_off;
    uint32_t ui32_index;
    int32_t i32_result;

/* start values */
    ui32_off = ui32_first;
    ui32_index = 0;
    i32_result = C64_OK;
/* page by page */
    while ((ui32_off < ROM_LEN) && (i32_result == C64_OK))
    {
        if (image_page(ui32_off) != C64_OK)
        {
            i32_result = FAT_EIO;
        }
        else
        {
/* read the page back, up to the first byte that differs */
            fl_addr(FL_CMD_READ, ROM_BASE + ui32_off);
            ui32_index = 0;
/* compare */
            while ((ui32_index < FL_PAGE) && (i32_result == C64_OK))
            {
                if (fl_xfer(0) != g_aui8_page[ui32_index])
                {
                    i32_result = C64_EFLASH;
                }
/* next byte */
                ui32_index++;
            }
/* the next page */
            fl_end();
            ui32_off += FL_PAGE;
        }
    }
    return i32_result;
}

/* /ROMS/C64/ on the card -> the ROM files: C64_OK, FAT_EIO or C64_ENOROM */
static int32_t rom_find(void)
{
/* local variables */
    FINDDIR s_find;
    uint32_t ui32_clus;
    int32_t i32_result;

/* start values */
    ui32_clus = 0;
    i32_result = C64_OK;
/* the folder ROMS in the root */
    s_find.pc_dir = "ROMS";
    s_find.i32_found = 0;
/* scan the root */
    if (fat_list(0, dir_cb_find, &s_find) != FAT_OK)
    {
        i32_result = FAT_EIO;
    }
/* no such folder */
    else if (s_find.i32_found == 0)
    {
        i32_result = C64_ENOROM;
    }
    else
    {
/* the folder C64 in it */
        ui32_clus = s_find.ui32_clus;
        s_find.pc_dir = "C64";
        s_find.i32_found = 0;
/* scan it */
        if (fat_list(ui32_clus, dir_cb_find, &s_find) != FAT_OK)
        {
            i32_result = FAT_EIO;
        }
/* no such folder */
        else if (s_find.i32_found == 0)
        {
            i32_result = C64_ENOROM;
        }
        else
        {
/* the folder is there */
        }
    }
/* the ROM files in it: CHAR, BASIC and KERNAL are needed */
    if (i32_result == C64_OK)
    {
        u_memset(&g_s_rom, 0, sizeof g_s_rom);
        if (fat_list(s_find.ui32_clus, rom_cb, &g_s_rom) != FAT_OK)
        {
/* the card failed */
            i32_result = FAT_EIO;
        }
        else if ((g_s_rom.ai32_found[ROM_CHAR] == 0) || (g_s_rom.ai32_found[ROM_BASIC] == 0) ||
                 (g_s_rom.ai32_found[ROM_KERNAL] == 0))
        {
            i32_result = C64_ENOROM;
        }
        else
        {
/* all there */
        }
    }
    return i32_result;
}

/* C64_YES = /ROMS/C64/ on the card has all ROMs, the 1541 one too */
int32_t c64_rom_card_1541(void)
{
/* local variables */
    int32_t i32_result;

/* start values */
    i32_result = 0;
    if ((rom_find() == C64_OK) && (g_s_rom.ai32_found[ROM_1541] != 0))
    {
/* the 1541's ROM is on the card */
        i32_result = C64_YES;
    }
    return i32_result;
}

/* Install the ROM files into flash, then reload the C64: C64_OK, C64_E*, FAT_EIO */
int32_t c64_rom_install(void (*pf_progress)(const char *pc_text))
{
/* local variables */
    uint32_t ui32_off;
    int32_t i32_result;

/* start values */
    ui32_off = 0;
    i32_result = rom_find();
    if (i32_result == C64_OK)
    {
/* The header page (offset 0, "L64 ROMS") is written last and only after the ROM data */
/* checked out, so an install that stops anywhere (error, reset) never leaves an image */
/* that looks valid; block 0 is erased first, which removes the old header. */
        pf_progress("Erasing flash");
        while ((ui32_off < ROM_LEN) && (i32_result == C64_OK))
        {
/* one 4 KB block */
            fl_wren();
            fl_addr(FL_CMD_SECTOR_ERASE, ROM_BASE + ui32_off);
            fl_end();
/* until it is erased */
            if (fl_wait(ERASE_MS) != FL_OK)
            {
                i32_result = C64_EFLASH;
            }
            ui32_off += FL_BLOCK;
        }
/* the ROM data, checked */
        if (i32_result == C64_OK)
        {
            pf_progress("Writing flash");
/* every page behind the first */
            for (ui32_off = FL_PAGE; (ui32_off < ROM_LEN) && (i32_result == C64_OK); ui32_off += FL_PAGE)
            {
                i32_result = write_page(ui32_off);
            }
/* then all of them are read back */
            if (i32_result == C64_OK)
            {
                pf_progress("Checking flash");
                i32_result = check_pages(FL_PAGE);
            }
/* the header: the image is valid from here on */
            if (i32_result == C64_OK)
            {
                i32_result = write_page(0);
            }
/* read back too */
            if (i32_result == C64_OK)
            {
                i32_result = check_pages(0);
            }
        }
/* the flash pins go back to the FPGA in every case */
        FLASH = 0;
/* the FPGA copies the ROMs and restarts the C64 */
        if (i32_result == C64_OK)
        {
            RELOAD = YES;
        }
    }
    return i32_result;
}

/* .prg / .t64 */

/* one snapshot port command; returns the data read */
static uint32_t snap_cmd(uint32_t ui32_cmd, uint32_t ui32_addr, uint32_t ui32_data)
{
/* local variables */
    uint32_t ui32_result;

    SNAPDAT = ui32_data;
    SNAPCMD = (ui32_cmd << CMD_SHIFT) | ui32_addr;
/* wait until the FPGA has done it */
    while ((SNAPCTL & SNAP_BUSY) != 0)
    {
    }
    ui32_result = SNAPDAT;
    return ui32_result;
}

/* one byte into the C64's RAM */
static void poke(uint32_t ui32_addr, uint8_t ui8_value)
{
    snap_cmd(C_MWR, ui32_addr & ADDR_MASK, ui8_value);
}

/* stop the CPU at an instruction boundary: C64_OK or C64_ERUN */
static int32_t freeze(void)
{
/* local variables */
    uint32_t ui32_start;
    int32_t i32_result;

/* start values */
    ui32_start = TIMER;
    i32_result = C64_OK;
/* ask for the stop, and wait for it */
    SNAPCTL = CTL_FREEZE;
    while ((i32_result == C64_OK) && ((SNAPCTL & SNAP_FROZEN) == 0))
    {
/* a CPU that is not running never gets there */
        if ((TIMER - ui32_start) > (FREEZE_MS * CLK_PER_MS))
        {
/* released, with an error */
            SNAPCTL = 0;
            i32_result = C64_ERUN;
        }
    }
    return i32_result;
}

/* "$1234" at pc_dst; returns its end */
static char *hex4(char *pc_dst, uint32_t ui32_value)
{
/* local variables */
    int32_t i32_shift;

    *pc_dst = '$';
    pc_dst++;
/* four digits, the highest first */
    for (i32_shift = HEX_FIRST_SHIFT; i32_shift >= 0; i32_shift -= HEX_DIGIT_BITS)
    {
        *pc_dst = g_ac_hex[(ui32_value >> i32_shift) & HEX_DIGIT_MASK];
        pc_dst++;
    }
/* the text's end */
    *pc_dst = 0;
    return pc_dst;
}

/* .t64: find the first used directory entry; start address, length and the file position are set. */
/* C64_OK or C64_EBAD */
static int32_t t64_find(FFILE *ps_file, uint32_t *pui32_start, uint32_t *pui32_count)
{
/* local variables */
    uint8_t aui8_entry[T64_ENTRY_LEN];
    uint32_t ui32_entries;
    uint32_t ui32_index;
/* a byte counter, the end address, the data's offset */
    uint32_t ui32_byte;
    uint32_t ui32_end;
    uint32_t ui32_off;
/* bytes read */
    int32_t i32_low;
    int32_t i32_high;
    int32_t i32_char;
/* an entry was found, the result */
    bool b_found;
    int32_t i32_result;

/* start values */
    ui32_entries = 0;
    ui32_index = 0;
    ui32_byte = 0;
/* nothing read yet */
    ui32_end = 0;
    ui32_off = 0;
    i32_char = 0;
/* nothing found, no error */
    b_found = false;
    i32_result = C64_OK;
/* the number of directory entries */
    ff_seek(ps_file, T64_ENTRIES_OFF);
    i32_low = ff_getc(ps_file);
    i32_high = ff_getc(ps_file);
/* the file ended */
    if ((i32_low < 0) || (i32_high < 0))
    {
        i32_result = C64_EBAD;
    }
    else
    {
/* a count of 0 is taken as 1 */
        ui32_entries = (uint32_t)(i32_low | (i32_high << SHIFT_BYTE));
        if (ui32_entries == 0)
        {
            ui32_entries = ONE;
        }
    }
/* the first entry of a normal file */
    while ((i32_result == C64_OK) && (ui32_index < ui32_entries) && !b_found)
    {
        ff_seek(ps_file, T64_DIR_OFF + (T64_ENTRY_LEN * ui32_index));
/* its 32 bytes */
        for (ui32_byte = 0; (ui32_byte < T64_ENTRY_LEN) && (i32_result == C64_OK); ui32_byte++)
        {
            i32_char = ff_getc(ps_file);
            if (i32_char < 0)
            {
/* the file ended */
                i32_result = C64_EBAD;
            }
            else
            {
                aui8_entry[ui32_byte] = (uint8_t)i32_char;
            }
        }
/* a normal file */
        if ((i32_result == C64_OK) && (aui8_entry[T64_ENTRY_TYPE] == T64_TYPE_FILE))
        {
            b_found = true;
        }
        ui32_index++;
    }
/* no entry of a normal file */
    if ((i32_result == C64_OK) && !b_found)
    {
        i32_result = C64_EBAD;
    }
/* start and end address, and where the data is in the file */
    if (i32_result == C64_OK)
    {
        *pui32_start = aui8_entry[T64_START_LOW] | ((uint32_t)aui8_entry[T64_START_HIGH] << SHIFT_BYTE);
        ui32_end = aui8_entry[T64_END_LOW] | ((uint32_t)aui8_entry[T64_END_HIGH] << SHIFT_BYTE);
/* the offset, 32 bits */
        ui32_off = aui8_entry[T64_OFF_0] | ((uint32_t)aui8_entry[T64_OFF_1] << SHIFT_BYTE) |
                   ((uint32_t)aui8_entry[T64_OFF_2] << SHIFT_WORD) | ((uint32_t)aui8_entry[T64_OFF_3] << SHIFT_3_BYTES);
        if (ui32_off >= ps_file->ui32_size)
        {
            i32_result = C64_EBAD;
        }
    }
/* the length from the two addresses */
    if (i32_result == C64_OK)
    {
        *pui32_count = 0;
/* if the end is behind the start */
        if (ui32_end > *pui32_start)
        {
            *pui32_count = ui32_end - *pui32_start;
        }
/* many .t64 files have a wrong end address: then the rest of the file is the program */
        if ((*pui32_count == 0) || ((ui32_off + *pui32_count) > ps_file->ui32_size))
        {
            *pui32_count = ps_file->ui32_size - ui32_off;
        }
/* ready to read the program */
        ff_seek(ps_file, ui32_off);
    }
    return i32_result;
}

/* Load a .prg or the first file of a .t64 into the running C64: C64_OK, C64_EBAD, C64_ERUN, FAT_EIO */
int32_t c64_prg_load(FFILE *ps_file, int32_t i32_t64, char *pc_info)
{
/* local variables */
    uint32_t ui32_start;
    uint32_t ui32_end;
    uint32_t ui32_count;
/* a counter, bytes read */
    uint32_t ui32_index;
    int32_t i32_char;
    int32_t i32_low;
/* the text's end, the result */
    int32_t i32_high;
    char *pc_end;
    int32_t i32_result;

/* start values */
    ui32_start = 0;
    ui32_end = 0;
    ui32_count = 0;
/* nothing read yet */
    ui32_index = 0;
    i32_char = 0;
    i32_low = 0;
/* the text, no error */
    i32_high = 0;
    pc_end = pc_info;
    i32_result = C64_OK;
/* .t64 or .prg */
    if (i32_t64 != 0)
    {
/* first used directory entry */
        i32_result = t64_find(ps_file, &ui32_start, &ui32_count);
    }
    else
    {
/* .prg: the load address, then the program */
        i32_low = ff_getc(ps_file);
        i32_high = ff_getc(ps_file);
/* too short for an address and a byte */
        if ((i32_low < 0) || (i32_high < 0) || (ps_file->ui32_size < PRG_MIN_SIZE))
        {
            i32_result = C64_EBAD;
        }
        else
        {
/* the address, and the bytes behind it */
            ui32_start = (uint32_t)(i32_low | (i32_high << SHIFT_BYTE));
            ui32_count = ps_file->ui32_size - PRG_ADDR_LEN;
        }
    }
    if (i32_result == C64_OK)
    {
/* nothing is loaded behind the end of the memory */
        if ((ui32_start + ui32_count) > C64_RAM)
        {
            ui32_count = C64_RAM - ui32_start;
        }
/* the end address; the C64 stops */
        ui32_end = ui32_start + ui32_count;
        i32_result = freeze();
    }
/* the program's bytes into the RAM; a card error lets the C64 run on */
    while ((i32_result == C64_OK) && (ui32_index < ui32_count))
    {
        i32_char = ff_getc(ps_file);
        if (i32_char < 0)
        {
/* the card failed: released */
            SNAPCTL = 0;
            i32_result = FAT_EIO;
        }
        else
        {
/* into the memory */
            poke(ui32_start + ui32_index, (uint8_t)i32_char);
            ui32_index++;
        }
    }
    if (i32_result == C64_OK)
    {
/* end of load */
        poke(ZP_LOAD_END_LOW, (uint8_t)ui32_end);
        poke(ZP_LOAD_END_HIGH, (uint8_t)(ui32_end >> SHIFT_BYTE));
/* BASIC: pointers as after LOAD, then RUN and RETURN in the keyboard buffer */
        if (ui32_start == BASIC_START)
        {
            for (ui32_index = ZP_VARTAB; ui32_index <= ZP_STREND; ui32_index += ZP_POINTER_STEP)
            {
/* low and high byte */
                poke(ui32_index, (uint8_t)ui32_end);
                poke(ui32_index + ONE, (uint8_t)(ui32_end >> SHIFT_BYTE));
            }
/* R, U, N */
            poke(KEY_BUFFER, 'R');
            poke(KEY_BUFFER + BYTE_1, 'U');
            poke(KEY_BUFFER + BYTE_2, 'N');
/* RETURN; four keys wait */
            poke(KEY_BUFFER + BYTE_3, KEY_RETURN);
            poke(ZP_KEY_COUNT, RUN_KEYS);
        }
/* the C64 runs */
        SNAPCTL = 0;
/* "$0801-$1234" */
        pc_end = hex4(pc_info, ui32_start);
        *pc_end = '-';
        pc_end++;
/* the end address */
        hex4(pc_end, ui32_end);
    }
    return i32_result;
}

/* .tap */

/* start playing a C64 .tap */
void c64tap_start(FFILE *ps_file)
{
/* local variables */
    int32_t i32_index;

/* start values */
    g_ps_tap_file = ps_file;
    g_ui32_tap_pend = 0;
    g_i32_tap_state = TS_RUN;
/* the signature */
    ff_seek(ps_file, 0);
    for (i32_index = 0; (i32_index < TAP_SIG_LEN) && (g_i32_tap_state == TS_RUN); i32_index++)
    {
        if (ff_getc(ps_file) != g_ac_tap_sig[i32_index])
        {
/* not a .tap file */
            g_i32_tap_state = TS_ERR;
        }
    }
/* the version, then the data behind the header */
    if (g_i32_tap_state == TS_RUN)
    {
        g_i32_tap_ver = ff_getc(ps_file);
        if ((g_i32_tap_ver < 0) || (g_i32_tap_ver > TAP_VERSION_MAX))
        {
/* a version not known */
            g_i32_tap_state = TS_ERR;
        }
        else
        {
            ff_seek(ps_file, TAP_HDR_LEN);
        }
    }
}

/* the length in cycles of the next pulse of the .tap; 0 = the file ended */
static uint32_t tap_next(void)
{
/* local variables */
    uint32_t ui32_len;
    int32_t i32_byte;
    int32_t i32_low;
/* the upper bytes of a long pulse */
    int32_t i32_mid;
    int32_t i32_high;

/* start values */
    ui32_len = 0;
    i32_low = 0;
    i32_mid = 0;
/* the next byte of the file */
    i32_high = 0;
    i32_byte = ff_getc(g_ps_tap_file);
    if (i32_byte < 0)
    {
/* the file's end */
        g_i32_tap_state = TS_END;
    }
    else if (i32_byte != 0)
    {
/* one byte: the length in units of 8 cycles */
        ui32_len = (uint32_t)i32_byte * TAP_UNIT;
    }
    else if (g_i32_tap_ver == 0)
    {
/* version 0: an overflow, 256 units */
        ui32_len = TAP_OVERFLOW_V0;
    }
    else
    {
/* version 1: the next 3 bytes are the length in cycles */
        i32_low = ff_getc(g_ps_tap_file);
        i32_mid = ff_getc(g_ps_tap_file);
        i32_high = ff_getc(g_ps_tap_file);
/* the file ended inside them */
        if (i32_high < 0)
        {
            g_i32_tap_state = TS_END;
        }
        else
        {
/* the length, 24 bits */
            ui32_len = (uint32_t)(i32_low | (i32_mid << SHIFT_BYTE) | (i32_high << SHIFT_WORD));
        }
    }
/* a pulse is two half periods of at least one cycle each, and of at most one command each */
    if (g_i32_tap_state == TS_RUN)
    {
        if (ui32_len < TAP_LEN_MIN)
        {
            ui32_len = TAP_LEN_MIN;
        }
/* not above what two commands can hold */
        if (ui32_len > (TAP_HALVES * CMD_MAX_T))
        {
            ui32_len = TAP_HALVES * CMD_MAX_T;
        }
    }
    return ui32_len;
}

/* generate pulse player commands while the FIFO has room; returns TS_* */
int32_t c64tap_pump(void)
{
/* local variables */
    uint32_t ui32_len;

/* start values */
    ui32_len = 0;
    while ((g_i32_tap_state == TS_RUN) && (fifo_free() > 0))
    {
        if (g_ui32_tap_pend != 0)
        {
/* the second half period of the pulse */
            fifo_push(CMD_PULSE(g_ui32_tap_pend));
            g_ui32_tap_pend = 0;
        }
        else
        {
            ui32_len = tap_next();
/* the first half period now, the second at the next pass */
            if (g_i32_tap_state == TS_RUN)
            {
                fifo_push(CMD_PULSE(ui32_len / TAP_HALVES));
                g_ui32_tap_pend = ui32_len - (ui32_len / TAP_HALVES);
            }
        }
    }
/* the player's state */
    return g_i32_tap_state;
}

/* .tap recording */

/* one byte to the file; a card error ends the recording */
static void r_put(uint8_t ui8_byte)
{
    if ((g_i32_rec_on != 0) && (fw_putc(&g_s_fw_file, ui8_byte) != FAT_OK))
    {
        g_i32_rec_on = 0;
/* recorder and tape off */
        RECCTL = 0;
        TAPE = 0;
    }
}

/* one pulse of a length in cycles to the file */
static void r_pulse(uint32_t ui32_len)
{
/* local variables */
    uint32_t ui32_units;

    ui32_units = (ui32_len + TAP_ROUND) / TAP_UNIT;
    if ((ui32_units >= ONE) && (ui32_units <= TAP_BYTE_MAX))
    {
/* one byte */
        r_put((uint8_t)ui32_units);
    }
    else
    {
/* 0 and the length in cycles, 24 bits */
        if (ui32_len > TAP_LONG_MAX)
        {
            ui32_len = TAP_LONG_MAX;
        }
/* the 0 that announces it */
        r_put(0);
        r_put((uint8_t)ui32_len);
/* its upper bytes */
        r_put((uint8_t)(ui32_len >> SHIFT_BYTE));
        r_put((uint8_t)(ui32_len >> SHIFT_WORD));
    }
    g_ui32_rec_pulses++;
}

/* start recording into a new .tap file: FAT_OK, FAT_* */
int32_t c64rec_start(uint32_t ui32_dir, const char ac_name11[FAT_NAME11_LEN])
{
/* local variables */
    int32_t i32_index;
    int32_t i32_result;

/* start values */
    i32_index = 0;
    i32_result = fw_create(&g_s_fw_file, ui32_dir, ac_name11);
/* the file is there: recording */
    if (i32_result == FAT_OK)
    {
        g_i32_rec_on = YES;
/* the header: signature, version 1, reserved bytes and the data size (patched at the end) */
        for (i32_index = 0; i32_index < TAP_SIG_LEN; i32_index++)
        {
            r_put((uint8_t)g_ac_tap_sig[i32_index]);
        }
/* version 1 */
        r_put(TAP_VERSION_1);
        for (i32_index = 0; i32_index < TAP_RESERVED; i32_index++)
        {
            r_put(0);
        }
/* nothing recorded yet */
        g_i32_rec_half = 0;
        g_ui32_rec_acc = 0;
        g_ui32_rec_pulses = 0;
/* reading clears an old event */
        while ((REC & REC_PEND) != 0)
        {
        }
/* sense: PLAY pressed; the C64 is held for every event */
        TAPE = TAPE_ON;
        RECCTL = REC_ARMED;
/* a card error while the header was written */
        if (g_i32_rec_on == 0)
        {
            i32_result = FAT_EIO;
        }
    }
    return i32_result;
}

/* call often while recording: two edges make one pulse */
void c64rec_service(void)
{
/* local variables */
    uint32_t ui32_event;
    int32_t i32_count;
    bool b_more;

/* start values */
    ui32_event = 0;
    i32_count = 0;
    b_more = true;
/* a limited number of events per call */
    while ((g_i32_rec_on != 0) && (i32_count < EVENTS_PER_CALL) && b_more)
    {
        i32_count++;
        ui32_event = REC;
/* no event waits */
        if ((ui32_event & REC_PEND) == 0)
        {
            b_more = false;
        }
/* a gap */
        else if ((ui32_event & REC_GAP) != 0)
        {
/* no edge yet: the next edge's count includes the pause */
        }
        else
        {
            g_ui32_rec_acc += ui32_event & EVENT_TIME_MASK;
/* the second edge completes the pulse */
            if (g_i32_rec_half != 0)
            {
                r_pulse(g_ui32_rec_acc);
/* a new pulse starts empty */
                g_ui32_rec_acc = 0;
                g_i32_rec_half = 0;
            }
            else
            {
                g_i32_rec_half = YES;
            }
        }
    }
}

/* stop recording and close the file (a file without pulses is removed) */
void c64rec_end(void)
{
/* local variables */
    uint32_t ui32_size;

/* start values */
    ui32_size = 0;
    if (g_i32_rec_on != 0)
    {
/* recorder and tape off */
        RECCTL = 0;
        TAPE = 0;
/* the last events, then the data size into the header */
        c64rec_service();
        ui32_size = g_s_fw_file.ui32_size - TAP_HDR_LEN;
/* its low bytes */
        fw_patch(&g_s_fw_file, TAP_SIZE_OFF, (uint8_t)ui32_size);
        fw_patch(&g_s_fw_file, TAP_SIZE_OFF + BYTE_1, (uint8_t)(ui32_size >> SHIFT_BYTE));
/* its high bytes */
        fw_patch(&g_s_fw_file, TAP_SIZE_OFF + BYTE_2, (uint8_t)(ui32_size >> SHIFT_WORD));
        fw_patch(&g_s_fw_file, TAP_SIZE_OFF + BYTE_3, (uint8_t)(ui32_size >> SHIFT_3_BYTES));
/* a file only if something was recorded */
        if (g_ui32_rec_pulses != 0)
        {
            fw_close(&g_s_fw_file);
        }
        else
        {
            fw_discard(&g_s_fw_file);
        }
/* recording is over */
        g_i32_rec_on = 0;
    }
}

/* C64_YES = recording is on */
int32_t c64rec_active(void)
{
/* local variables */
    int32_t i32_result;

    i32_result = g_i32_rec_on;
    return i32_result;
}

/* status for the bottom row into pc_text; 0 = nothing to show */
int32_t c64rec_status(char *pc_text)
{
/* local variables */
    char *pc_end;
    int32_t i32_result;

/* start values */
    pc_end = pc_text;
    i32_result = 0;
    if (g_i32_rec_on != 0)
    {
/* the number of pulses so far */
        pc_end = u_strcpy(pc_text, "Recording, ");
        pc_end = u_utoa(pc_end, g_ui32_rec_pulses);
        u_strcpy(pc_end, " pulses (F12)");
/* a status line was written */
        i32_result = C64_YES;
    }
    return i32_result;
}

/* .d64 (1541, rtl c1541.v): the FPGA makes the disk surface of one track from its track */
/* buffer (snapshot addresses 0x20000 + sector * 256); this keeps the buffer on the track */
/* under the head and writes sectors the DOS changed back into the file. */

/* MCTL with the turbo bit (F6) */
static void mctl(uint32_t ui32_value)
{
    if (g_i32_slow_mode != 0)
    {
        MCTL = ui32_value;
    }
    else
    {
/* turbo allowed */
        MCTL = ui32_value | MC_TURBO;
    }
}

/* the speed mode changed */
void c64_speed(void)
{
    if (g_i32_disk_on != 0)
    {
        mctl(g_ui32_disk_ctl | (g_ui32_disk_loaded << MC_TRACK_SHIFT));
    }
    else
    {
/* no disk */
        mctl(0u);
    }
}

/* sectors of a track */
static uint32_t spt(uint32_t ui32_track)
{
/* local variables */
    uint32_t ui32_sectors;

    if (ui32_track <= D64_ZONE1_LAST)
    {
        ui32_sectors = D64_ZONE1_SECTORS;
    }
/* 18-24 */
    else if (ui32_track <= D64_ZONE2_LAST)
    {
        ui32_sectors = D64_ZONE2_SECTORS;
    }
/* 25-30 */
    else if (ui32_track <= D64_ZONE3_LAST)
    {
        ui32_sectors = D64_ZONE3_SECTORS;
    }
    else
    {
/* 31-35 */
        ui32_sectors = D64_ZONE4_SECTORS;
    }
    return ui32_sectors;
}

/* where a sector is in the .d64 file */
static uint32_t d64_off(uint32_t ui32_track, uint32_t ui32_sector)
{
/* local variables */
    uint32_t ui32_index;
    uint32_t ui32_count;

    ui32_count = 0;
/* the sectors of the tracks before it */
    for (ui32_index = D64_FIRST_TRACK; ui32_index < ui32_track; ui32_index++)
    {
        ui32_count += spt(ui32_index);
    }
    return (ui32_count + ui32_sector) * D64_SECTOR;
}

/* the screen code of a character */
static uint8_t screen_code(uint8_t ui8_char)
{
    uint8_t ui8_code;

    ui8_code = ui8_char;
/* letters are 1 to 26 on the screen */
    if ((ui8_char >= 'A') && (ui8_char <= 'Z'))
    {
        ui8_code = (uint8_t)(ui8_char - '@');
    }
    return ui8_code;
}

/* puts a command on the cursor's screen line and RETURN into the keyboard buffer: BASIC */
/* reads the line from the screen, as if it had been typed (the buffer holds only 10 keys) */
static void type_line(const char *pc_text)
{
/* local variables */
    uint32_t ui32_line;
    uint32_t ui32_index;

/* start values */
    ui32_line = 0;
    ui32_index = 0;
    if (freeze() == C64_OK)
    {
/* start of the cursor's line */
        ui32_line = snap_cmd(C_MRD, ZP_LINE_LOW, 0);
        ui32_line |= snap_cmd(C_MRD, ZP_LINE_HIGH, 0) << SHIFT_BYTE;
/* the text as screen codes */
        while ((pc_text[ui32_index] != 0) && (ui32_index < SCREEN_COLS))
        {
            poke(ui32_line + ui32_index, screen_code((uint8_t)pc_text[ui32_index]));
            ui32_index++;
        }
/* cursor column 0 */
        poke(ZP_CURSOR_COLUMN, 0);
/* the cursor blink restores the character it hid there ($CE) when the key arrives */
        if (pc_text[0] != 0)
        {
            poke(ZP_CHAR_UNDER_CURSOR, screen_code((uint8_t)pc_text[0]));
        }
/* RETURN in the keyboard buffer; the C64 runs */
        poke(KEY_BUFFER, KEY_RETURN);
        poke(ZP_KEY_COUNT, ONE_KEY);
        SNAPCTL = 0;
    }
}

/* BASIC waits for input (frozen: the screen editor's cursor flashes, direct mode, the KERNAL's */
/* IRQ vector): only then is LOAD typed; a disk changed while a program runs is not typed into it */
static bool at_prompt(void)
{
    bool b_result;

    b_result = false;
/* each test only if the one before it held */
    if (snap_cmd(C_MRD, ZP_CURSOR_BLINK, 0) == 0)
    {
        if (snap_cmd(C_MRD, ZP_MSG_FLAG, 0) == MSG_FLAG_DIRECT)
        {
/* the IRQ vector is the KERNAL's */
            if (snap_cmd(C_MRD, VEC_IRQ_LOW, 0) == KERNAL_IRQ_LOW)
            {
                if (snap_cmd(C_MRD, VEC_IRQ_HIGH, 0) == KERNAL_IRQ_HIGH)
                {
                    b_result = true;
                }
            }
        }
    }
/* true only at BASIC's prompt */
    return b_result;
}

/* put a .d64 into the 1541 and type LOAD"*",8,1 if BASIC waits for input: C64_OK, C64_EBAD, FAT_EIO */
int32_t c64_d64_mount(const FFILE *ps_file, const char *pc_name, int32_t i32_ro)
{
/* local variables */
    int32_t i32_id1;
    int32_t i32_id2;
    int32_t i32_swap;
/* a wait's start, BASIC's prompt, the result */
    uint32_t ui32_start;
    bool b_prompt;
    int32_t i32_result;

/* start values */
    i32_id1 = 0;
    i32_id2 = 0;
/* a disk was in: this is a disk change */
    i32_swap = g_i32_disk_on;
    ui32_start = 0;
/* not known yet; no error */
    b_prompt = false;
    i32_result = C64_OK;
/* 35 tracks, 683 sectors */
    if (ps_file->ui32_size < D64_MIN_SIZE)
    {
        i32_result = C64_EBAD;
    }
    else
    {
/* the old disk out, the new file in */
        c64_d64_eject();
        u_memcpy(&g_s_disk_file, ps_file, sizeof g_s_disk_file);
/* disk ID in the BAM */
        ff_seek(&g_s_disk_file, d64_off(D64_BAM_TRACK, 0) + D64_ID_OFF);
        i32_id1 = ff_getc(&g_s_disk_file);
        i32_id2 = ff_getc(&g_s_disk_file);
/* the card failed */
        if ((i32_id1 < 0) || (i32_id2 < 0))
        {
            i32_result = FAT_EIO;
        }
    }
/* read only or not */
    if (i32_result == C64_OK)
    {
        g_i32_disk_ro = 0;
        if (i32_ro != 0)
        {
/* read only */
            g_i32_disk_ro = YES;
        }
/* no track in the buffer; MCTL's value with the ID */
        g_ui32_disk_loaded = 0;
        g_ui32_disk_ctl = MC_DISK | ((uint32_t)g_i32_disk_ro << MC_RO_SHIFT) | ((uint32_t)i32_id1 << MC_ID1_SHIFT) |
                          ((uint32_t)i32_id2 << MC_ID2_SHIFT);
/* disk change: the new disk covers the write-protect sensor while it slides in; */
/* the DOS sees the change (VIA2 PB4) and reads the new disk's BAM */
        if (i32_swap != 0)
        {
            mctl(MC_DISK | MC_READ_ONLY);
/* held for 300 ms */
            ui32_start = TIMER;
            while ((TIMER - ui32_start) < (DISK_CHANGE_MS * CLK_PER_MS))
            {
            }
        }
/* the new disk */
        mctl(g_ui32_disk_ctl);
        g_i32_disk_on = YES;
        u_strncpy(g_ac_disk_name, pc_name, NAME_MAX);
/* the track under the head first (18 after a reset): the DOS starts reading as soon as LOAD is typed */
        c64_d64_service();
        if (freeze() == C64_OK)
        {
/* is BASIC waiting at its prompt? */
            b_prompt = at_prompt();
            SNAPCTL = 0;
/* then the LOAD command is typed */
            if (b_prompt)
            {
                type_line("LOAD\"*\",8,1");
            }
        }
    }
    return i32_result;
}

/* take the disk out */
void c64_d64_eject(void)
{
/* last written sectors */
    if (g_i32_disk_on != 0)
    {
        c64_d64_service();
    }
/* no disk */
    mctl(0);
    g_i32_disk_on = 0;
}

/* write the sectors the DOS changed back into the file; false = the FPGA is gone, stop */
static bool write_back(uint32_t ui32_dirty)
{
/* local variables */
    uint32_t ui32_sector;
    uint32_t ui32_index;
    bool b_ok;

/* start values */
    ui32_sector = 0;
    ui32_index = 0;
    b_ok = true;
/* sector by sector */
    while ((ui32_sector < spt(g_ui32_disk_loaded)) && b_ok)
    {
        if ((ui32_dirty & (ONE << ui32_sector)) != 0)
        {
/* the sector from the track buffer */
            for (ui32_index = 0; ui32_index < D64_SECTOR; ui32_index++)
            {
                g_aui8_sector[ui32_index] = (uint8_t)snap_cmd(C_MRD, TB_BASE + (ui32_sector * D64_SECTOR) + ui32_index, 0);
            }
            if (link_alive() == 0)
            {
/* the data may be the gone FPGA's FFs */
                b_ok = false;
            }
            else
            {
/* into the file, unless it is read only; then the sector is clean */
                if (g_i32_disk_ro == 0)
                {
                    ff_update(&g_s_disk_file, d64_off(g_ui32_disk_loaded, ui32_sector), g_aui8_sector, D64_SECTOR);
                }
                MCLR = ONE << ui32_sector;
            }
        }
/* the next sector */
        ui32_sector++;
    }
    return b_ok;
}

/* the track under the head from the file into the track buffer */
static void load_track(uint32_t ui32_track)
{
/* local variables */
    uint32_t ui32_sector;
    uint32_t ui32_index;
    int32_t i32_char;

/* start values */
    ui32_index = 0;
    i32_char = 0;
/* nothing valid while loading */
    mctl(g_ui32_disk_ctl);
    for (ui32_sector = 0; ui32_sector < spt(ui32_track); ui32_sector++)
    {
/* the sector from the file */
        ff_seek(&g_s_disk_file, d64_off(ui32_track, ui32_sector));
        for (ui32_index = 0; ui32_index < D64_SECTOR; ui32_index++)
        {
/* a card error reads as 0 */
            i32_char = ff_getc(&g_s_disk_file);
            if (i32_char < 0)
            {
                i32_char = 0;
            }
/* into the track buffer */
            snap_cmd(C_MWR, TB_BASE + (ui32_sector * D64_SECTOR) + ui32_index, (uint32_t)i32_char);
        }
    }
    g_ui32_disk_loaded = ui32_track;
    mctl(g_ui32_disk_ctl | (ui32_track << MC_TRACK_SHIFT));
}

/* main loop: loads the track under the head and writes changed sectors back */
void c64_d64_service(void)
{
/* local variables */
    uint32_t ui32_status;
    uint32_t ui32_track;
/* written sectors, still fine */
    uint32_t ui32_dirty;
    bool b_ok;

/* start values */
    ui32_status = 0;
    ui32_track = 0;
    ui32_dirty = 0;
/* only with a disk in */
    b_ok = g_i32_disk_on != 0;
    if (b_ok)
    {
        ui32_status = MCTL;
/* the track under the head, the sectors written */
        ui32_track = ui32_status & MS_TRACK_MASK;
        ui32_dirty = (ui32_status >> MS_DIRTY_SHIFT) & MS_DIRTY_MASK;
/* a gone FPGA (Ctrl+Alt+Del / KEY1 to the menu, KEY0) reads all ones: head track 63, every */
/* sector dirty, sector data FF; writing that back would wipe the track (the loader restarts */
/* the ESP32 within 0.5 s) */
        if ((ui32_track > D64_TRACKS) ||
            ((g_ui32_disk_loaded != 0) && ((ui32_dirty >> spt(g_ui32_disk_loaded)) != 0)))
        {
            b_ok = false;
        }
    }
/* changed sectors of the track in the buffer */
    if (b_ok && (ui32_dirty != 0) && (g_ui32_disk_loaded != 0))
    {
        b_ok = write_back(ui32_dirty);
    }
/* the head moved to another track */
    if (b_ok && (ui32_track >= D64_FIRST_TRACK) && (ui32_track <= D64_TRACKS) && (ui32_track != g_ui32_disk_loaded))
    {
        load_track(ui32_track);
    }
}

/* "Disk: NAME" into pc_text while a disk is in: C64_YES, else 0 */
int32_t c64_d64_status(char *pc_text)
{
/* local variables */
    char *pc_end;
    int32_t i32_result;

/* start values */
    pc_end = pc_text;
    i32_result = 0;
    if (g_i32_disk_on != 0)
    {
/* the disk's name */
        pc_end = u_strcpy(pc_text, "Disk: ");
        u_strncpy(pc_end, g_ac_disk_name, STATUS_NAME_LEN);
/* a status line was written */
        i32_result = C64_YES;
    }
    return i32_result;
}

/* snapshots (.A64) */

/* stop the C64 at an instruction boundary: C64_OK or C64_ERUN */
int32_t c64_snap_freeze(void)
{
/* local variables */
    int32_t i32_result;

    i32_result = freeze();
    return i32_result;
}

/* the CPU's and the CIAs' state into the header buffer */
void c64_snap_capture(void)
{
/* local variables */
    uint32_t ui32_cpu;
    uint32_t ui32_cpu2;
/* the two CIAs */
    uint32_t ui32_cia1;
    uint32_t ui32_cia2;

/* start values */
    ui32_cpu = snap_cmd(C_REG, REG_CPU, 0);
    ui32_cpu2 = snap_cmd(C_REG, REG_CPU2, 0);
/* the two CIAs */
    ui32_cia1 = snap_cmd(C_REG, REG_CIA1, 0);
    ui32_cia2 = snap_cmd(C_REG, REG_CIA2, 0);
/* magic and version */
    u_memset(g_aui8_a64_hdr, 0, sizeof g_aui8_a64_hdr);
    u_memcpy(g_aui8_a64_hdr, "L64SNAPS", A64_MAGIC_LEN);
    g_aui8_a64_hdr[A64_VERSION_OFF] = A64_VERSION;
/* A, X, Y, P */
    g_aui8_a64_hdr[A64_A] = (uint8_t)ui32_cpu;
    g_aui8_a64_hdr[A64_X] = (uint8_t)(ui32_cpu >> SHIFT_BYTE);
/* Y and P */
    g_aui8_a64_hdr[A64_Y] = (uint8_t)(ui32_cpu >> SHIFT_WORD);
    g_aui8_a64_hdr[A64_P] = (uint8_t)(ui32_cpu >> SHIFT_3_BYTES);
/* S, PC */
    g_aui8_a64_hdr[A64_S] = (uint8_t)ui32_cpu2;
    g_aui8_a64_hdr[A64_PCL] = (uint8_t)(ui32_cpu2 >> SHIFT_WORD);
    g_aui8_a64_hdr[A64_PCH] = (uint8_t)(ui32_cpu2 >> SHIFT_3_BYTES);
/* CIA1: interrupt mask, CRA, CRB */
    g_aui8_a64_hdr[A64_CIA1_IMR] = (uint8_t)ui32_cia1;
    g_aui8_a64_hdr[A64_CIA1_CRA] = (uint8_t)(ui32_cia1 >> SHIFT_BYTE);
    g_aui8_a64_hdr[A64_CIA1_CRB] = (uint8_t)(ui32_cia1 >> SHIFT_WORD);
/* CIA2 */
    g_aui8_a64_hdr[A64_CIA2_IMR] = (uint8_t)ui32_cia2;
    g_aui8_a64_hdr[A64_CIA2_CRA] = (uint8_t)(ui32_cia2 >> SHIFT_BYTE);
    g_aui8_a64_hdr[A64_CIA2_CRB] = (uint8_t)(ui32_cia2 >> SHIFT_WORD);
}

/* the captured state, the RAM and the I/O shadow as a new file: FAT_* */
int32_t c64_snap_save(uint32_t ui32_dir, const char ac_name11[FAT_NAME11_LEN])
{
/* local variables */
    uint32_t ui32_index;
    int32_t i32_result;

/* start values */
    ui32_index = 0;
    i32_result = fw_create(&g_s_fw_file, ui32_dir, ac_name11);
    if (i32_result == FAT_OK)
    {
/* the header */
        for (ui32_index = 0; (ui32_index < A64_HDR) && (i32_result == FAT_OK); ui32_index++)
        {
            i32_result = fw_putc(&g_s_fw_file, g_aui8_a64_hdr[ui32_index]);
        }
/* the RAM */
        for (ui32_index = 0; (ui32_index < C64_RAM) && (i32_result == FAT_OK); ui32_index++)
        {
            i32_result = fw_putc(&g_s_fw_file, (uint8_t)snap_cmd(C_MRD, ui32_index, 0));
        }
/* the I/O shadow */
        for (ui32_index = 0; (ui32_index < SH_LEN) && (i32_result == FAT_OK); ui32_index++)
        {
            i32_result = fw_putc(&g_s_fw_file, (uint8_t)snap_cmd(C_MRD, SH_BASE + ui32_index, 0));
        }
/* a failed write leaves no file */
        if (i32_result != FAT_OK)
        {
            fw_discard(&g_s_fw_file);
        }
        else
        {
/* complete: the directory entry is written */
            i32_result = fw_close(&g_s_fw_file);
        }
    }
    return i32_result;
}

/* the C64 runs on */
void c64_snap_resume(void)
{
    SNAPCTL = 0;
}

/* restore program: one byte into the bank */
static void e8(uint8_t ui8_byte)
{
    snap_cmd(C_MWR, RB_BASE + g_ui32_stub_pc, ui8_byte);
    g_ui32_stub_pc++;
}

/* restore program: LDA #value / STA address */
static void e_sta(uint8_t ui8_value, uint32_t ui32_addr)
{
    e8(OP_LDA_IMM);
    e8(ui8_value);
/* the address, low byte first */
    e8(OP_STA_ABS);
    e8((uint8_t)ui32_addr);
    e8((uint8_t)(ui32_addr >> SHIFT_BYTE));
}

/* restore program: one CIA from its shadow, interrupt mask and control registers */
static void e_cia(uint32_t ui32_base, const uint8_t *pui8_shadow, uint8_t ui8_imr, uint8_t ui8_cra, uint8_t ui8_crb)
{
    uint32_t ui32_index;

/* no interrupts, timers stopped; LDA ICR clears pending flags */
    e_sta(CIA_ICR_CLEAR_ALL, ui32_base + CIA_ICR);
    e8(OP_LDA_ABS);
    e8(CIA_ICR);
/* the address's high byte; both timers stopped */
    e8((uint8_t)(ui32_base >> SHIFT_BYTE));
    e_sta(0, ui32_base + CIA_CRA);
    e_sta(0, ui32_base + CIA_CRB);
/* DDRs, ports, timer latches */
    for (ui32_index = 0; ui32_index < CIA_RESTORED; ui32_index++)
    {
        e_sta(pui8_shadow[g_aui8_cia_regs[ui32_index]], ui32_base + g_aui8_cia_regs[ui32_index]);
    }
/* force load from the latch, then the interrupt mask */
    e_sta((uint8_t)(ui8_cra | CIA_FORCE_LOAD), ui32_base + CIA_CRA);
    e_sta((uint8_t)(ui8_crb | CIA_FORCE_LOAD), ui32_base + CIA_CRB);
    e_sta((uint8_t)(CIA_ICR_SET | ui8_imr), ui32_base + CIA_ICR);
}

/* write the restore program into the restore bank: every chip back to its state, then RTI */
static void emit_restore(const uint8_t aui8_port[RAM_PORT_BYTES])
{
/* local variables */
    uint32_t ui32_index;
    uint8_t ui8_stack;

/* start values */
    ui32_index = 0;
    ui8_stack = g_aui8_a64_hdr[A64_S];
/* the colour RAM's copy, and the reset vector -> the program */
    for (ui32_index = 0; ui32_index < CRAM_LEN; ui32_index++)
    {
        snap_cmd(C_MWR, RB_BASE + CRAM_BUF + ui32_index, g_aui8_a64_shadow[SH_CRAM + ui32_index]);
    }
/* the reset vector */
    snap_cmd(C_MWR, RB_BASE + VEC_RESET_LOW, STUB & BYTE_MASK);
    snap_cmd(C_MWR, RB_BASE + VEC_RESET_HIGH, STUB >> SHIFT_BYTE);
    g_ui32_stub_pc = STUB;
/* SEI, CLD */
    e8(OP_SEI);
    e8(OP_CLD);
/* VIC-II: the collision registers are read only; $D019: acknowledge all */
    for (ui32_index = 0; ui32_index <= VIC_LAST_REG; ui32_index++)
    {
        if ((ui32_index != VIC_SPRITE_COLLISION) && (ui32_index != VIC_DATA_COLLISION))
        {
            if (ui32_index == VIC_IRQ_FLAGS)
            {
/* all interrupt flags acknowledged */
                e_sta(VIC_IRQ_ACK_ALL, VIC_BASE + ui32_index);
            }
            else
            {
                e_sta(g_aui8_a64_shadow[ui32_index], VIC_BASE + ui32_index);
            }
        }
    }
/* SID, volume last */
    for (ui32_index = 0; ui32_index <= SID_LAST_REG; ui32_index++)
    {
        e_sta(g_aui8_a64_shadow[SH_SID + ui32_index], SID_BASE + ui32_index);
    }
/* colour RAM: LDX #0; four times LDA CRAM_BUF+i*$100,X / STA $D800+i*$100,X; INX; BNE back */
    e8(OP_LDX_IMM);
    e8(0);
/* the four pages */
    for (ui32_index = 0; ui32_index < CRAM_PAGES; ui32_index++)
    {
        e8(OP_LDA_ABS_X);
        e8(0);
/* the copy's page */
        e8((uint8_t)((CRAM_BUF >> SHIFT_BYTE) + ui32_index));
/* into the colour RAM's page */
        e8(OP_STA_ABS_X);
        e8(0);
        e8((uint8_t)(CRAM_BASE_HIGH + ui32_index));
    }
/* the next of 256 bytes, until X wraps */
    e8(OP_INX);
    e8(OP_BNE);
    e8((uint8_t)(BRANCH_WRAP - CRAM_LOOP_BACK));
/* the two CIAs, then the 6510's port */
    e_cia(CIA1_BASE, g_aui8_a64_shadow + SH_CIA1, g_aui8_a64_hdr[A64_CIA1_IMR], g_aui8_a64_hdr[A64_CIA1_CRA],
          g_aui8_a64_hdr[A64_CIA1_CRB]);
    e_cia(CIA2_BASE, g_aui8_a64_shadow + SH_CIA2, g_aui8_a64_hdr[A64_CIA2_IMR], g_aui8_a64_hdr[A64_CIA2_CRA],
          g_aui8_a64_hdr[A64_CIA2_CRB]);
/* direction, then data */
    e_sta(aui8_port[0], CPU_PORT_DDR);
    e_sta(aui8_port[CPU_PORT], CPU_PORT);
/* LDX #S-3, TXS; the stack for RTI: P, PCL, PCH */
    e8(OP_LDX_IMM);
    e8((uint8_t)(ui8_stack - STACK_RTI_FRAME));
    e8(OP_TXS);
/* P, PCL, PCH where RTI finds them */
    e_sta(g_aui8_a64_hdr[A64_P], STACK_PAGE + (uint8_t)(ui8_stack - STACK_P));
    e_sta(g_aui8_a64_hdr[A64_PCL], STACK_PAGE + (uint8_t)(ui8_stack - STACK_PCL));
    e_sta(g_aui8_a64_hdr[A64_PCH], STACK_PAGE + ui8_stack);
/* LDA #A, LDX #X, LDY #Y, RTI */
    e8(OP_LDA_IMM);
    e8(g_aui8_a64_hdr[A64_A]);
/* X */
    e8(OP_LDX_IMM);
    e8(g_aui8_a64_hdr[A64_X]);
/* Y, and back into the program */
    e8(OP_LDY_IMM);
    e8(g_aui8_a64_hdr[A64_Y]);
    e8(OP_RTI);
}

/* run the restore program in restore mode: C64_OK or C64_ERUN */
static int32_t run_restore(void)
{
/* local variables */
    uint32_t ui32_start;
    int32_t i32_result;

/* start values */
    ui32_start = 0;
    i32_result = C64_OK;
/* restore mode, CPU in reset; the C64 runs again (CPU still in reset) */
    snap_cmd(C_CTL, 0, CTL_RESTORE_RESET);
    SNAPCTL = 0;
    ui32_start = TIMER;
/* one millisecond of reset */
    while ((TIMER - ui32_start) < CLK_PER_MS)
    {
    }
/* CPU out of reset: vector, program, RTI */
    snap_cmd(C_CTL, 0, CTL_RESTORE_RUN);
    ui32_start = TIMER;
    while ((i32_result == C64_OK) && ((snap_cmd(C_CTL, 0, CTL_RESTORE_RUN) & CTL_RESTORE_BUSY) != 0))
    {
/* the program did not reach its end */
        if ((TIMER - ui32_start) > (RESTORE_MS * CLK_PER_MS))
        {
            i32_result = C64_ERUN;
        }
    }
/* restore mode off */
    snap_cmd(C_CTL, 0, 0);
    return i32_result;
}

/* load a snapshot: C64_OK, C64_EBAD, C64_ERUN, FAT_EIO */
int32_t c64_snap_load(FFILE *ps_file)
{
/* local variables */
    uint32_t ui32_index;
    int32_t i32_char;
/* the 6510's port bytes, the result */
    uint8_t aui8_port[RAM_PORT_BYTES];
    int32_t i32_result;

/* start values */
    ui32_index = 0;
    i32_char = 0;
    i32_result = C64_OK;
/* the file has one size only */
    if (ps_file->ui32_size != A64_SIZE)
    {
        i32_result = C64_EBAD;
    }
/* the header */
    while ((i32_result == C64_OK) && (ui32_index < A64_HDR))
    {
        i32_char = ff_getc(ps_file);
        if (i32_char < 0)
        {
/* the card failed */
            i32_result = FAT_EIO;
        }
        else
        {
            g_aui8_a64_hdr[ui32_index] = (uint8_t)i32_char;
            ui32_index++;
        }
    }
/* the magic text (ADORE64S: saved before the rename) and the version */
    if ((i32_result == C64_OK) &&
        (((u_memcmp(g_aui8_a64_hdr, "L64SNAPS", A64_MAGIC_LEN) != 0) &&
          (u_memcmp(g_aui8_a64_hdr, "ADORE64S", A64_MAGIC_LEN) != 0)) ||
         (g_aui8_a64_hdr[A64_VERSION_OFF] != A64_VERSION)))
    {
        i32_result = C64_EBAD;
    }
/* the C64 stops */
    if (i32_result == C64_OK)
    {
        i32_result = freeze();
    }
/* RAM: into the machine; its first two bytes are the 6510's port */
    ui32_index = 0;
    while ((i32_result == C64_OK) && (ui32_index < C64_RAM))
    {
/* byte by byte */
        i32_char = ff_getc(ps_file);
        if (i32_char < 0)
        {
/* the card failed: released */
            SNAPCTL = 0;
            i32_result = FAT_EIO;
        }
        else
        {
/* the port bytes are kept for the restore program */
            if (ui32_index < RAM_PORT_BYTES)
            {
                aui8_port[ui32_index] = (uint8_t)i32_char;
            }
/* into the machine */
            snap_cmd(C_MWR, ui32_index, (uint32_t)i32_char);
            ui32_index++;
        }
    }
/* I/O shadow: into the buffer */
    ui32_index = 0;
    while ((i32_result == C64_OK) && (ui32_index < SH_LEN))
    {
/* byte by byte */
        i32_char = ff_getc(ps_file);
        if (i32_char < 0)
        {
/* the card failed: released */
            SNAPCTL = 0;
            i32_result = FAT_EIO;
        }
        else
        {
/* into the buffer */
            g_aui8_a64_shadow[ui32_index] = (uint8_t)i32_char;
            ui32_index++;
        }
    }
/* the restore program, and its run */
    if (i32_result == C64_OK)
    {
        emit_restore(aui8_port);
/* run it */
        i32_result = run_restore();
    }
    return i32_result;
}

/* screenshot (Print Screen): the newest complete frame of the FPGA's frame buffer */
/* (L64/ep4_ce15/rtl/c64_fb.v: 400 x 284 dots, 4 per 16-bit word, first dot in the low */
/* nibble, 256 bytes per line) as a BMP. While the hold is on (CTL[2]) the buffers do not */
/* change and MRD reads the newest one (address = offset in it); the C64 runs on. */
int32_t c64_screenshot(uint32_t ui32_dir, const char ac_name11[FAT_NAME11_LEN])
{
/* local variables */
    uint8_t aui8_pal[SHOT_COLOURS_4BPP][SHOT_RGB_LEN];
    uint8_t aui8_row[SHOT_WIDTH];
    uint32_t ui32_addr;
/* a buffer byte, counters */
    uint32_t ui32_byte;
    int32_t i32_index;
    int32_t i32_y;
/* the result of closing, the result */
    int32_t i32_x;
    int32_t i32_end;
    int32_t i32_result;

/* start values */
    ui32_addr = 0;
    ui32_byte = 0;
/* the bottom row first */
    i32_y = SHOT_LAST_ROW;
    i32_end = FAT_OK;
/* the palette, widened from 6 to 8 bits */
    for (i32_index = 0; i32_index < SHOT_COLOURS_4BPP; i32_index++)
    {
        for (i32_x = 0; i32_x < SHOT_RGB_LEN; i32_x++)
        {
            aui8_pal[i32_index][i32_x] = (uint8_t)((g_aui8_k6[i32_index][i32_x] << PAL_WIDEN_UP) |
                                                    (g_aui8_k6[i32_index][i32_x] >> PAL_WIDEN_DOWN));
        }
    }
/* hold the frame buffers while the picture is read, bottom row first */
    snap_cmd(C_CTL, 0, CTL_HOLD_FB);
    i32_result = shot_begin(ui32_dir, ac_name11, SHOT_WIDTH, SHOT_HEIGHT, aui8_pal);
    while ((i32_y >= 0) && (i32_result == FAT_OK))
    {
/* two dots per byte, the first in the low nibble */
        for (i32_x = 0; i32_x < SHOT_WIDTH; i32_x += DOTS_PER_BYTE)
        {
            ui32_addr = ((uint32_t)i32_y * FB_LINE_BYTES) + ((uint32_t)i32_x / DOTS_PER_BYTE);
            ui32_byte = snap_cmd(C_MRD, ui32_addr, 0);
/* its two dots */
            aui8_row[i32_x] = (uint8_t)(ui32_byte & DOT_MASK);
            aui8_row[i32_x + NEXT_DOT] = (uint8_t)((ui32_byte >> DOT_SHIFT) & DOT_MASK);
        }
/* into the file */
        i32_result = shot_row(aui8_row);
        i32_y--;
    }
/* the frame buffers run again */
    snap_cmd(C_CTL, 0, 0);
/* the file is closed, or deleted after an error; the first error is the result */
    i32_end = shot_end();
    if (i32_result == FAT_OK)
    {
/* the error of closing */
        i32_result = i32_end;
    }
    return i32_result;
}

/* back to the state after a start: the next machine starts the loader again without an ESP32 */
/* restart (esp_hw.cpp; the Bluetooth connection stays) */
void c64_reset(void)
{
    u_memset(&g_s_rom, 0, sizeof g_s_rom);
    u_memset(g_aui8_page, 0, sizeof g_aui8_page);
/* the tape */
    g_ps_tap_file = NULL;
    g_i32_tap_ver = 0;
/* state, pending half */
    g_i32_tap_state = 0;
    g_ui32_tap_pend = 0;
/* the recording */
    g_i32_rec_on = 0;
    g_i32_rec_half = 0;
/* cycles, pulses */
    g_ui32_rec_acc = 0;
    g_ui32_rec_pulses = 0;
/* the disk */
    u_memset(&g_s_disk_file, 0, sizeof g_s_disk_file);
    g_i32_disk_on = 0;
    g_i32_disk_ro = 0;
/* no track in the buffer */
    g_ui32_disk_loaded = 0;
    g_ui32_disk_ctl = 0;
/* its name, the sector buffer */
    u_memset(g_ac_disk_name, 0, sizeof g_ac_disk_name);
    u_memset(g_aui8_sector, 0, sizeof g_aui8_sector);
/* the snapshot */
    u_memset(g_aui8_a64_hdr, 0, sizeof g_aui8_a64_hdr);
    u_memset(g_aui8_a64_shadow, 0, sizeof g_aui8_a64_shadow);
    g_ui32_stub_pc = 0;
}
