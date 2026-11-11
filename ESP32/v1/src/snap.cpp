/* snap.c -- .z80 snapshots: saving the running Spectrum (F2), loading a file (browser) */
/* The Spectrum CPU is stopped between two instructions (rtl/zx_bus.v, "Snapshots"), */
/* and its registers, the 128K of RAM, the AY and the ports are read or written */
/* through the snapshot commands. The CPU stays stopped while the name is typed. */
/* Saving writes version 3 (128K, hardware mode 4): 30-byte header, 54 more bytes, */
/* then the 8 RAM pages as blocks 3..10, compressed (ED ED n b = n times b; runs of */
/* 5 or more, runs of ED from 2; the byte after a single ED is never part of a */
/* run). A page that would not get smaller is stored as 16384 plain bytes (length */
/* FFFF). Not saved: the position in the video frame (the T-state counter is 0). */
/* Loading takes versions 1 (48K), 2 and 3, 48K and 128K. 48K snapshots run in */
/* 48K mode: 7FFD = 30 (48 BASIC ROM, RAM page 0 at C000, paging locked). The */
/* file is checked completely before anything is changed. */
#ifdef HOST_TEST
#include "../../../ESP32_test/v1/test/host_hw.h"
#else
/* the FPGA's registers */
#include "hw.h"
#endif
#include "fat.h"
/* this module's header, screenshots, string functions */
#include "snap.h"
#include "shot.h"
#include "util.h"

/* snapshot commands (rtl/zx_bus.v) */
#define C_MRD 1
#define C_MWR 2
#define C_REG 3
/* a register word for a LOAD, the LOAD itself */
#define C_DIR 4
#define C_LOAD 5
/* the AY: read, write, select */
#define C_AYRD 6
#define C_AYWR 7
#define C_AYSEL 8
/* the ports, the machine's state */
#define C_PORT 9
#define C_STATE 10
/* the command number's place in the command register */
#define CMD_SHIFT 28
/* the CPU is asked to stop; how long it may take */
#define CTL_FREEZE 1u
#define FREEZE_MS 200u
/* one RAM page, and the 128K's eight */
#define PAGE 16384u
#define PAGES 8u
/* the .z80 header of version 3: 30 + 2 + 54 bytes; one more byte in the buffer */
#define HDR_LEN 86
#define HDR_BUF_LEN 87
/* the part every version has, where the extended header starts */
#define HDR_V1_LEN 30u
#define HDR_EXT_OFF 32u
/* the smallest file: a version 1 header and a byte */
#define FILE_MIN 31u
/* offsets in the .z80 header */
#define H_A 0
#define H_F 1
#define H_BC 2
/* HL, PC, SP */
#define H_HL 4
#define H_PC 6
#define H_SP 8
/* I, R, the flags byte */
#define H_I 10
#define H_R 11
#define H_FLAGS 12
/* DE, then the alternate set */
#define H_DE 13
#define H_BC_ALT 15
#define H_DE_ALT 17
/* HL', A', F' */
#define H_HL_ALT 19
#define H_A_ALT 21
#define H_F_ALT 22
/* the index registers, interrupts enabled */
#define H_IY 23
#define H_IX 25
#define H_IFF1 27
/* IFF2, interrupt mode, the extended header's length */
#define H_IFF2 28
#define H_IM 29
#define H_EXT_LEN 30
/* version 2 and 3: PC, hardware mode, 7FFD */
#define H_PC_V2 32
#define H_HW_MODE 34
#define H_7FFD 35
/* emulation flags, the AY */
#define H_EMU_FLAGS 37
#define H_AY_SELECT 38
#define H_AY_REGS 39
/* which ROMs are paged in */
#define H_ROM_PAGED_LOW 61
#define H_ROM_PAGED_HIGH 62
/* header byte 12: R bit 7, the border in bits 1-3, version 1 data compressed; FF means 1 */
#define FLAGS_R7 0x01
#define FLAGS_BORDER_SHIFT 1
#define FLAGS_BORDER_MASK 7u
/* version 1's compression, the value that means 1 */
#define FLAGS_V1_PACKED 0x20
#define FLAGS_UNSET 0xFF
#define FLAGS_DEFAULT 1
/* header values written */
#define HW_MODE_128K 4
#define EMU_R_LDIR 3
#define ROM_PAGED 0xFF
/* header byte 37: the 48K snapshot has an AY */
#define EMU_FLAG_AY 0x04
/* lengths of the extended header that are known, and what the hardware mode means in each */
#define EXT_V2 23u
#define EXT_V3 54u
#define EXT_V3_1FFD 55u
/* the first 128K mode of version 2 and of version 3 */
#define HW_V2_128K_MIN 3
#define HW_V3_128K_MIN 4
/* other machines of version 3 */
#define HW_V3_PENTAGON 14
#define HW_V3_SCORPION 15
#define HW_V3_TS2068 128
/* memory blocks: a 3-byte head (length, page), length FFFF = not compressed */
#define BLOCK_HEAD_LEN 3u
#define BLOCK_PAGE_OFF 2
#define BLOCK_PLAIN 0xFFFFu
/* block numbers in the file: 128K RAM pages 0-7 are blocks 3-10; 48K: 4 = 8000, 5 = C000, 8 = 4000 */
#define BLOCK_FIRST_128K 3u
#define BLOCK_LAST_128K 10u
/* the 48K blocks */
#define BLOCK_48K_8000 4u
#define BLOCK_48K_C000 5u
#define BLOCK_48K_4000 8u
/* all eight 128K pages as a mask; a block of another machine */
#define BLOCKS_NEEDED_128K 0x7F8u
#define NO_BLOCK (-1)
/* RAM pages of the 48K memory map: 4000 = page 5, 8000 = page 2, C000 = page 0 */
#define PAGE_AT_4000 5u
#define PAGE_AT_8000 2u
#define V1_PAGES 3u
/* 48K mode: 48 BASIC ROM, RAM page 0 at C000, paging locked */
#define PORT_7FFD_48K 0x30u
#define PORT_BORDER_SHIFT 8
/* compression: the escape byte, the shortest run packed, the longest run of one code */
#define PACK_ESCAPE 0xED
#define PACK_RUN_MIN 5u
#define PACK_RUN_MIN_ESCAPE 2u
/* the longest run, the length of its code */
#define PACK_RUN_MAX 255u
#define PACK_CODE_LEN 4u
/* unpack: the file ended, or the block is not valid */
#define UNPACK_OK 0
#define UNPACK_BAD (-1)
/* no address in the one-byte read cache */
#define ADDR_NONE 0xFFFFFFFFu
/* the CPU's registers as the snapshot commands give them (cpu_t80): 7 words of 32 bits */
#define REG_WORDS 7
#define REG_WORD_SHIFT 5
#define REG_BIT_MASK 31u
/* the words with R, PC and the interrupt state */
#define REG_WORD_R 1
#define REG_WORD_PC 2
#define REG_WORD_INT 6
/* place of each register in those words: word * 32 + bit */
#define POS_A 0
#define POS_F 8
#define POS_A_ALT 16
/* F', I, SP */
#define POS_F_ALT 24
#define POS_I 32
#define POS_SP 48
/* the pairs */
#define POS_BC 80
#define POS_DE 96
#define POS_HL 112
/* IX, the alternate pairs */
#define POS_IX 128
#define POS_BC_ALT 144
#define POS_DE_ALT 160
/* HL', IY */
#define POS_HL_ALT 176
#define POS_IY 192
/* the register table's columns, its size, and a register's size in bytes */
#define RMAP_HDR 0
#define RMAP_POS 1
#define RMAP_BYTES 2
/* its size */
#define RMAP_COLS 3
#define RMAP_ROWS 14
/* one or two bytes */
#define REG_8BIT 1
#define REG_16BIT 2
/* fields of the register words: R, PC, interrupt mode and the two interrupt flip-flops */
#define R_SHIFT 8
#define R_MASK 0xFFu
#define R_LOW_MASK 0x7F
/* bit 7 of R, the PC */
#define R_BIT7_SHIFT 7
#define PC_MASK 0xFFFFu
/* interrupt mode */
#define IM_SHIFT 16
#define IM_MASK 3u
#define IM_INVALID 3u
/* mode 2, the flip-flops */
#define IM_2 2u
#define IFF1_SHIFT 18
#define IFF2_SHIFT 19
/* the state word: 7FFD in bits 0-7, the border in 8-10, AY select in 16-23, HALT in bit 24 */
#define ST_HALT (1u << 24)
#define ST_BORDER_SHIFT 8
#define ST_BORDER_MASK 7u
/* AY select, the screen shown */
#define ST_AY_SELECT_SHIFT 16
#define ST_SCREEN_PAGE7 8u
/* the AY: 16 registers, the three volume registers 8-10 */
#define AY_REGS 16
#define AY_VOLUME_FIRST 8
#define AY_VOLUME_LAST 10
/* bytes and bits */
#define SHIFT_BYTE 8
#define NEXT_BYTE 1
/* the number one, a set flag */
#define ONE 1u
#define YES 1
/* the screenshot: picture, border, Spectrum screen */
#define SHOT_WIDTH 320
#define SHOT_HEIGHT 240
#define SHOT_LAST_ROW 239
/* the border's size */
#define SHOT_BORDER_TOP 24
#define SHOT_BORDER_LEFT 32
/* the Spectrum's screen */
#define SCREEN_WIDTH 256
#define SCREEN_HEIGHT 192
#define SCREEN_BYTES 6912
/* its attributes */
#define SCREEN_ATTR_OFF 6144
#define SCREEN_ATTR_COLS 32
/* the pages that hold a screen */
#define SCREEN_PAGE_NORMAL 5u
#define SCREEN_PAGE_SHADOW 7u
/* the screen's row address: the bits of y are spread over the address */
#define Y_THIRD_MASK 0xC0
#define Y_THIRD_SHIFT 5
#define Y_LINE_MASK 7
/* the character row */
#define Y_LINE_SHIFT 8
#define Y_ROW_MASK 0x38
#define Y_ROW_SHIFT 2
/* the byte of x, the bit of x */
#define X_BYTE_SHIFT 3
#define X_BIT_MASK 7
#define X_FIRST_BIT 7
/* attribute byte: ink, paper, bright */
#define ATTR_INK_MASK 7
#define ATTR_PAPER_SHIFT 3
/* bright */
#define ATTR_BRIGHT 0x40
#define COLOUR_BRIGHT 8
/* the palette's levels: as LSpectrum's VGA, normal E, bright F */
#define LVL_NORMAL 0xEE
#define LVL_BRIGHT 0xFF

/* registers: header offset, place in the register words, bytes (R, IM, IFF, PC: in the code) */
static const uint8_t g_aui8_rmap[RMAP_ROWS][RMAP_COLS] =
{
    { H_A, POS_A, REG_8BIT }, { H_F, POS_F, REG_8BIT }, { H_A_ALT, POS_A_ALT, REG_8BIT },
    { H_F_ALT, POS_F_ALT, REG_8BIT }, { H_I, POS_I, REG_8BIT }, { H_SP, POS_SP, REG_16BIT },
    { H_BC, POS_BC, REG_16BIT }, { H_DE, POS_DE, REG_16BIT }, { H_HL, POS_HL, REG_16BIT },
    { H_IX, POS_IX, REG_16BIT }, { H_BC_ALT, POS_BC_ALT, REG_16BIT }, { H_DE_ALT, POS_DE_ALT, REG_16BIT },
    { H_HL_ALT, POS_HL_ALT, REG_16BIT }, { H_IY, POS_IY, REG_16BIT }
};
/* the screenshot's 16 colours: 8 normal, 8 bright; each red, green, blue */
static const uint8_t g_aui8_pal[SHOT_COLOURS_4BPP][SHOT_RGB_LEN] =
{
    { 0, 0, 0 }, { 0, 0, LVL_NORMAL }, { LVL_NORMAL, 0, 0 }, { LVL_NORMAL, 0, LVL_NORMAL },
    { 0, LVL_NORMAL, 0 }, { 0, LVL_NORMAL, LVL_NORMAL }, { LVL_NORMAL, LVL_NORMAL, 0 },
    { LVL_NORMAL, LVL_NORMAL, LVL_NORMAL },
    { 0, 0, 0 }, { 0, 0, LVL_BRIGHT }, { LVL_BRIGHT, 0, 0 }, { LVL_BRIGHT, 0, LVL_BRIGHT },
    { 0, LVL_BRIGHT, 0 }, { 0, LVL_BRIGHT, LVL_BRIGHT }, { LVL_BRIGHT, LVL_BRIGHT, 0 },
    { LVL_BRIGHT, LVL_BRIGHT, LVL_BRIGHT }
};
/* RAM pages of a version 1 file's three parts: 4000, 8000, C000 */
static const uint8_t g_aui8_v1_pages[V1_PAGES] = { PAGE_AT_4000, PAGE_AT_8000, 0 };
/* captured state as a .z80 header; loading: the file's header */
static uint8_t g_aui8_hdr[HDR_BUF_LEN];
/* the screen's pixels and attributes, for the screenshot */
static uint8_t g_aui8_scr[SCREEN_BYTES];
/* first error while writing the file */
static int32_t g_i32_wr_err;
/* one-byte SDRAM read cache: address and value */
static uint32_t g_ui32_cache_addr;
static uint8_t g_ui8_cache_val;

#ifndef HOST_TEST
/* the snapshot control register */
static void snap_ctl(uint32_t ui32_value)
{
    SNAPCTL = ui32_value;
}

/* the snapshot status */
static uint32_t snap_status(void)
{
/* local variables */
    uint32_t ui32_status;

    ui32_status = SNAPCTL;
    return ui32_status;
}

/* the time now, in FPGA clocks */
static uint32_t timer_now(void)
{
/* local variables */
    uint32_t ui32_now;

    ui32_now = TIMER;
    return ui32_now;
}

/* one snapshot command with its address and data; returns the data read */
static __attribute__((noinline)) uint32_t snap_cmd(uint32_t ui32_cmd, uint32_t ui32_addr, uint32_t ui32_data)
{
/* local variables */
    uint32_t ui32_result;

    SNAPDAT = ui32_data;
    SNAPCMD = (ui32_cmd << CMD_SHIFT) | ui32_addr;
/* wait until the FPGA has done it */
    while ((SNAPCTL & SNAP_BUSY) != 0)
    {
    }
/* the answer */
    ui32_result = SNAPDAT;
    return ui32_result;
}
#endif

/* store 16 bits, low byte first */
static void put16(uint8_t *pui8_dst, uint32_t ui32_value)
{
    pui8_dst[0] = (uint8_t)ui32_value;
    pui8_dst[NEXT_BYTE] = (uint8_t)(ui32_value >> SHIFT_BYTE);
}

/* 16 bits, low byte first */
static uint32_t get16(const uint8_t *pui8_src)
{
/* local variables */
    uint32_t ui32_value;

    ui32_value = pui8_src[0] | ((uint32_t)pui8_src[NEXT_BYTE] << SHIFT_BYTE);
    return ui32_value;
}

/* stop the CPU between two instructions: SNAP_OK, SNAP_ERUN */
int32_t snap_freeze(void)
{
/* local variables */
    uint32_t ui32_start;
    int32_t i32_result;

/* start values */
    ui32_start = timer_now();
    i32_result = SNAP_OK;
    snap_ctl(CTL_FREEZE);
/* wait for the CPU to reach an instruction boundary */
    while ((i32_result == SNAP_OK) && ((snap_status() & SNAP_FROZEN) == 0))
    {
/* a CPU that is not running never gets there */
        if ((timer_now() - ui32_start) > (FREEZE_MS * CLK_PER_MS))
        {
            snap_ctl(0);
/* released, with an error */
            i32_result = SNAP_ERUN;
        }
    }
    return i32_result;
}

/* saving */

/* read the CPU's state into the header buffer and mute the AY */
void snap_capture(void)
{
/* local variables */
    uint32_t aui32_words[REG_WORDS];
    uint32_t ui32_state;
    uint32_t ui32_pc;
/* R, a register's value, a loop counter */
    uint32_t ui32_r;
    uint32_t ui32_value;
    int32_t i32_index;

/* start values */
    ui32_state = 0;
    ui32_pc = 0;
/* nothing read yet */
    ui32_r = 0;
    ui32_value = 0;
/* the register words and the machine's state */
    for (i32_index = 0; i32_index < REG_WORDS; i32_index++)
    {
        aui32_words[i32_index] = snap_cmd(C_REG, (uint32_t)i32_index, 0);
    }
/* the state word, and the PC */
    ui32_state = snap_cmd(C_STATE, 0, 0);
    ui32_pc = aui32_words[REG_WORD_PC] & PC_MASK;
/* in HALT: PC is past it, run it again */
    if ((ui32_state & ST_HALT) != 0)
    {
        ui32_pc = (ui32_pc - ONE) & PC_MASK;
    }
    ui32_r = (aui32_words[REG_WORD_R] >> R_SHIFT) & R_MASK;
/* the registers of the table into the header */
    u_memset(g_aui8_hdr, 0, sizeof g_aui8_hdr);
    for (i32_index = 0; i32_index < RMAP_ROWS; i32_index++)
    {
        ui32_value = aui32_words[g_aui8_rmap[i32_index][RMAP_POS] >> REG_WORD_SHIFT] >>
                     (g_aui8_rmap[i32_index][RMAP_POS] & REG_BIT_MASK);
/* its low byte */
        g_aui8_hdr[g_aui8_rmap[i32_index][RMAP_HDR]] = (uint8_t)ui32_value;
/* a 16-bit register has a second byte */
        if (g_aui8_rmap[i32_index][RMAP_BYTES] == REG_16BIT)
        {
            g_aui8_hdr[g_aui8_rmap[i32_index][RMAP_HDR] + NEXT_BYTE] = (uint8_t)(ui32_value >> SHIFT_BYTE);
        }
    }
/* R in two parts, with the border beside its bit 7 */
    g_aui8_hdr[H_R] = (uint8_t)(ui32_r & R_LOW_MASK);
    g_aui8_hdr[H_FLAGS] = (uint8_t)((ui32_r >> R_BIT7_SHIFT) |
                                    (((ui32_state >> ST_BORDER_SHIFT) & ST_BORDER_MASK) << FLAGS_BORDER_SHIFT));
/* IFF1, IFF2, IM */
    g_aui8_hdr[H_IFF1] = (uint8_t)((aui32_words[REG_WORD_INT] >> IFF1_SHIFT) & ONE);
    g_aui8_hdr[H_IFF2] = (uint8_t)((aui32_words[REG_WORD_INT] >> IFF2_SHIFT) & ONE);
    g_aui8_hdr[H_IM] = (uint8_t)((aui32_words[REG_WORD_INT] >> IM_SHIFT) & IM_MASK);
/* version 3: the length of the extended header, PC, 128K, 7FFD */
    put16(g_aui8_hdr + H_EXT_LEN, HDR_LEN - HDR_EXT_OFF);
    put16(g_aui8_hdr + H_PC_V2, ui32_pc);
/* a 128K machine, its paging */
    g_aui8_hdr[H_HW_MODE] = HW_MODE_128K;
    g_aui8_hdr[H_7FFD] = (uint8_t)ui32_state;
/* R and LDIR emulation (as usual), AY register select, the AY's registers */
    g_aui8_hdr[H_EMU_FLAGS] = EMU_R_LDIR;
    g_aui8_hdr[H_AY_SELECT] = (uint8_t)(ui32_state >> ST_AY_SELECT_SHIFT);
/* all sixteen */
    for (i32_index = 0; i32_index < AY_REGS; i32_index++)
    {
        g_aui8_hdr[H_AY_REGS + i32_index] = (uint8_t)snap_cmd(C_AYRD, (uint32_t)i32_index, 0);
    }
/* 0000-3FFF is ROM */
    g_aui8_hdr[H_ROM_PAGED_LOW] = ROM_PAGED;
    g_aui8_hdr[H_ROM_PAGED_HIGH] = ROM_PAGED;
/* silence while stopped: the three volumes to 0 */
    for (i32_index = AY_VOLUME_FIRST; i32_index <= AY_VOLUME_LAST; i32_index++)
    {
        snap_cmd(C_AYWR, (uint32_t)i32_index, 0);
    }
    snap_cmd(C_AYSEL, 0, g_aui8_hdr[H_AY_SELECT]);
}

/* AY back, the CPU runs on */
void snap_resume(void)
{
    int32_t i32_index;

/* the three volumes as they were */
    for (i32_index = AY_VOLUME_FIRST; i32_index <= AY_VOLUME_LAST; i32_index++)
    {
        snap_cmd(C_AYWR, (uint32_t)i32_index, g_aui8_hdr[H_AY_REGS + i32_index]);
    }
/* the register select, and the CPU runs */
    snap_cmd(C_AYSEL, 0, g_aui8_hdr[H_AY_SELECT]);
    snap_ctl(0);
}

/* one byte of the Spectrum's memory, through the one-byte cache */
static uint8_t rd(uint32_t ui32_addr)
{
    if (ui32_addr != g_ui32_cache_addr)
    {
        g_ui8_cache_val = (uint8_t)snap_cmd(C_MRD, ui32_addr, 0);
/* remembered */
        g_ui32_cache_addr = ui32_addr;
    }
    return g_ui8_cache_val;
}

/* one byte to the file; after an error nothing more is written */
static void put(uint8_t ui8_byte)
{
    int32_t i32_result;

    i32_result = FAT_OK;
/* only while everything went well */
    if (g_i32_wr_err == 0)
    {
        i32_result = fw_putc(&g_s_fw_file, ui8_byte);
/* the first error is kept */
        if (i32_result != FAT_OK)
        {
            g_i32_wr_err = i32_result;
        }
    }
}

/* compressed length of the page at ui32_base; written too if b_emit */
static uint32_t pack(uint32_t ui32_base, bool b_emit)
{
/* local variables */
    uint32_t ui32_pos;
    uint32_t ui32_len;
    uint32_t ui32_run;
/* a loop counter, the byte */
    uint32_t ui32_index;
    uint8_t ui8_byte;

/* start values */
    ui32_pos = 0;
    ui32_len = 0;
    ui32_run = 0;
/* nothing yet */
    ui32_index = 0;
    ui8_byte = 0;
    while (ui32_pos < PAGE)
    {
/* how often the byte at the position repeats */
        ui8_byte = rd(ui32_base + ui32_pos);
        ui32_run = ONE;
        while (((ui32_pos + ui32_run) < PAGE) && (ui32_run < PACK_RUN_MAX) &&
               (rd(ui32_base + ui32_pos + ui32_run) == ui8_byte))
        {
/* one longer */
            ui32_run++;
        }
        if ((ui32_run >= PACK_RUN_MIN) || ((ui8_byte == PACK_ESCAPE) && (ui32_run >= PACK_RUN_MIN_ESCAPE)))
        {
/* a run: ED ED count byte */
            if (b_emit)
            {
                put(PACK_ESCAPE);
                put(PACK_ESCAPE);
/* how many, and of what */
                put((uint8_t)ui32_run);
                put(ui8_byte);
            }
            ui32_len += PACK_CODE_LEN;
/* past the run */
            ui32_pos += ui32_run;
        }
        else if (ui8_byte == PACK_ESCAPE)
        {
/* single ED: the next byte stays plain */
            if (b_emit)
            {
                put(ui8_byte);
            }
/* counted and passed */
            ui32_len++;
            ui32_pos++;
/* the byte after it, if the page has one */
            if (ui32_pos < PAGE)
            {
                if (b_emit)
                {
                    put(rd(ui32_base + ui32_pos));
                }
/* counted and passed */
                ui32_len++;
                ui32_pos++;
            }
        }
        else
        {
/* a short run is written as it is */
            if (b_emit)
            {
                for (ui32_index = 0; ui32_index < ui32_run; ui32_index++)
                {
                    put(ui8_byte);
                }
            }
/* counted and passed */
            ui32_len += ui32_run;
            ui32_pos += ui32_run;
        }
    }
    return ui32_len;
}

/* write the captured state and the memory as a new file in a folder; FAT_* */
int32_t snap_save(uint32_t ui32_dir, const char ac_name11[FAT_NAME11_LEN])
{
/* local variables */
    uint32_t ui32_page;
    uint32_t ui32_len;
/* a loop counter, the result */
    uint32_t ui32_index;
    int32_t i32_result;

/* start values */
    ui32_page = 0;
    ui32_len = 0;
    ui32_index = 0;
/* the file */
    i32_result = fw_create(&g_s_fw_file, ui32_dir, ac_name11);
    if (i32_result == FAT_OK)
    {
        g_i32_wr_err = 0;
/* nothing cached */
        g_ui32_cache_addr = ADDR_NONE;
/* the header */
        for (ui32_index = 0; ui32_index < HDR_LEN; ui32_index++)
        {
            put(g_aui8_hdr[ui32_index]);
        }
/* the eight pages as blocks 3 to 10 */
        for (ui32_page = 0; (ui32_page < PAGES) && (g_i32_wr_err == 0); ui32_page++)
        {
            ui32_len = pack(ui32_page * PAGE, false);
            if (ui32_len >= PAGE)
            {
/* stored plain: length FFFF */
                put((uint8_t)BLOCK_PLAIN);
                put((uint8_t)(BLOCK_PLAIN >> SHIFT_BYTE));
/* the block number */
                put((uint8_t)(ui32_page + BLOCK_FIRST_128K));
                for (ui32_index = 0; ui32_index < PAGE; ui32_index++)
                {
                    put(rd((ui32_page * PAGE) + ui32_index));
                }
            }
            else
            {
/* compressed: its length, low byte first */
                put((uint8_t)ui32_len);
                put((uint8_t)(ui32_len >> SHIFT_BYTE));
/* the block number, then the packed page */
                put((uint8_t)(ui32_page + BLOCK_FIRST_128K));
                pack(ui32_page * PAGE, true);
            }
        }
/* a failed write leaves no file */
        if (g_i32_wr_err != 0)
        {
            fw_discard(&g_s_fw_file);
            i32_result = g_i32_wr_err;
        }
        else
        {
/* the directory entry is written */
            i32_result = fw_close(&g_s_fw_file);
        }
    }
    return i32_result;
}

/* loading */

/* SDRAM address of a memory block (block number in the file), or NO_BLOCK to skip it */
static int32_t block_addr(uint32_t ui32_block, bool b_128k)
{
/* local variables */
    int32_t i32_addr;

    i32_addr = NO_BLOCK;
    if (b_128k)
    {
/* blocks 3 to 10 are the RAM pages 0 to 7 */
        if ((ui32_block >= BLOCK_FIRST_128K) && (ui32_block <= BLOCK_LAST_128K))
        {
            i32_addr = (int32_t)((ui32_block - BLOCK_FIRST_128K) * PAGE);
        }
    }
    else if (ui32_block == BLOCK_48K_4000)
    {
/* 4000-7FFF */
        i32_addr = (int32_t)(PAGE_AT_4000 * PAGE);
    }
    else if (ui32_block == BLOCK_48K_8000)
    {
/* 8000-BFFF */
        i32_addr = (int32_t)(PAGE_AT_8000 * PAGE);
    }
    else if (ui32_block == BLOCK_48K_C000)
    {
/* C000-FFFF: page 0 */
        i32_addr = 0;
    }
    else
    {
/* a block this machine does not use */
    }
    return i32_addr;
}

/* version 1: one 48K stream for 4000-FFFF; the SDRAM address of an offset in it */
static uint32_t v1_addr(uint32_t ui32_off)
{
/* local variables */
    uint32_t ui32_addr;

    ui32_addr = (g_aui8_v1_pages[ui32_off / PAGE] * PAGE) + (ui32_off % PAGE);
    return ui32_addr;
}

/* one byte into the Spectrum's memory */
static void wr(bool b_v1, uint32_t ui32_base, uint32_t ui32_off, uint32_t ui32_value)
{
    uint32_t ui32_addr;

    ui32_addr = ui32_base + ui32_off;
/* a version 1 stream crosses three pages */
    if (b_v1)
    {
        ui32_addr = v1_addr(ui32_off);
    }
    snap_cmd(C_MWR, ui32_addr, ui32_value);
}

/* ui32_count bytes into memory from at most ui32_avail bytes of the file: UNPACK_OK or UNPACK_BAD */
static __attribute__((noinline)) int32_t unpack(FFILE *ps_file, uint32_t ui32_avail, uint32_t ui32_count, bool b_v1,
                                                uint32_t ui32_base, bool b_packed)
{
/* local variables */
    uint32_t ui32_off;
    uint32_t ui32_used;
    int32_t i32_char;
/* the byte after an ED, a run's count and value */
    int32_t i32_second;
    int32_t i32_run;
    int32_t i32_value;
/* the result */
    int32_t i32_result;

/* start values */
    ui32_off = 0;
    ui32_used = 0;
    i32_char = 0;
/* nothing read yet */
    i32_second = 0;
    i32_run = 0;
    i32_value = 0;
/* no error */
    i32_result = UNPACK_OK;
    while ((ui32_off < ui32_count) && (i32_result == UNPACK_OK))
    {
/* the next byte of the block, if it has one */
        if (ui32_used >= ui32_avail)
        {
            i32_result = UNPACK_BAD;
        }
        else
        {
/* one more of the block's bytes */
            ui32_used++;
            i32_char = ff_getc(ps_file);
        }
        if (i32_result != UNPACK_OK)
        {
/* the block ended too early */
        }
        else if (i32_char < 0)
        {
            i32_result = UNPACK_BAD;
        }
        else if (!b_packed || (i32_char != PACK_ESCAPE))
        {
/* a plain byte */
            wr(b_v1, ui32_base, ui32_off, (uint32_t)i32_char);
            ui32_off++;
        }
        else if (ui32_used >= ui32_avail)
        {
/* an ED as the block's last byte */
            wr(b_v1, ui32_base, ui32_off, PACK_ESCAPE);
            ui32_off++;
        }
        else
        {
/* the byte after an ED decides */
            ui32_used++;
            i32_second = ff_getc(ps_file);
            if (i32_second < 0)
            {
/* the file ended */
                i32_result = UNPACK_BAD;
            }
            else if (i32_second != PACK_ESCAPE)
            {
/* single ED and a plain byte */
                wr(b_v1, ui32_base, ui32_off, PACK_ESCAPE);
                ui32_off++;
/* the plain byte, if the area has room */
                if (ui32_off < ui32_count)
                {
                    wr(b_v1, ui32_base, ui32_off, (uint32_t)i32_second);
                    ui32_off++;
                }
            }
            else
            {
/* ED ED count byte: a run */
                ui32_used += PACK_RUN_MIN_ESCAPE;
                if (ui32_used > ui32_avail)
                {
                    i32_result = UNPACK_BAD;
                }
                else
                {
/* the count */
                    i32_run = ff_getc(ps_file);
/* the value only after a valid count */
                    if (i32_run < 0)
                    {
                        i32_result = UNPACK_BAD;
                    }
                    else
                    {
/* the value */
                        i32_value = ff_getc(ps_file);
                        if (i32_value < 0)
                        {
                            i32_result = UNPACK_BAD;
                        }
                    }
                }
/* the run, cut at the end of the memory area */
                if (i32_result == UNPACK_OK)
                {
                    while ((i32_run > 0) && (ui32_off < ui32_count))
                    {
                        wr(b_v1, ui32_base, ui32_off, (uint32_t)i32_value);
/* next place, one less to write */
                        ui32_off++;
                        i32_run--;
                    }
                }
            }
        }
    }
    return i32_result;
}

/* ui32_count bytes of the file into a buffer: UNPACK_OK or UNPACK_BAD */
static int32_t rd_bytes(FFILE *ps_file, uint8_t *pui8_dst, uint32_t ui32_count)
{
/* local variables */
    int32_t i32_char;
    int32_t i32_result;

/* start values */
    i32_char = 0;
    i32_result = UNPACK_OK;
/* byte by byte */
    while ((ui32_count != 0) && (i32_result == UNPACK_OK))
    {
        i32_char = ff_getc(ps_file);
/* the file ended */
        if (i32_char < 0)
        {
            i32_result = UNPACK_BAD;
        }
        else
        {
/* one more byte */
            *pui8_dst = (uint8_t)i32_char;
            pui8_dst++;
/* one less to read */
            ui32_count--;
        }
    }
    return i32_result;
}

/* length of the data of a memory block from its 3-byte head */
static uint32_t block_len(const uint8_t *pui8_head)
{
    uint32_t ui32_len;

    ui32_len = get16(pui8_head);
/* FFFF = a page stored plain */
    if (ui32_len == BLOCK_PLAIN)
    {
        ui32_len = PAGE;
    }
    return ui32_len;
}

/* versions 2 and 3: the extended header and every memory block inside the file; SNAP_OK or SNAP_EBAD */
static int32_t check_v2(FFILE *ps_file, uint32_t ui32_size, uint32_t *pui32_ext, uint32_t *pui32_pc, bool *pb_128k)
{
/* local variables */
    uint8_t aui8_head[BLOCK_HEAD_LEN];
    uint32_t ui32_ext;
    uint32_t ui32_pos;
/* a block's length, the blocks needed, the blocks seen */
    uint32_t ui32_len;
    uint32_t ui32_need;
    uint32_t ui32_mask;
/* bytes to read, a 128K machine, the result */
    uint32_t ui32_read;
    bool b_128k;
    int32_t i32_result;

/* start values */
    ui32_ext = 0;
    ui32_pos = 0;
    ui32_len = 0;
/* no blocks yet */
    ui32_need = 0;
    ui32_mask = 0;
    ui32_read = 0;
/* a 48K machine, no error */
    b_128k = false;
    i32_result = SNAP_OK;
/* the length of the extended header tells the version */
    if (rd_bytes(ps_file, aui8_head, HDR_EXT_OFF - HDR_V1_LEN) != UNPACK_OK)
    {
        i32_result = SNAP_EBAD;
    }
    else
    {
/* version 2, 3, or 3 with 1FFD */
        ui32_ext = get16(aui8_head);
        if ((ui32_ext != EXT_V2) && (ui32_ext != EXT_V3) && (ui32_ext != EXT_V3_1FFD))
        {
            i32_result = SNAP_EBAD;
        }
    }
/* the extended header, as much of it as the buffer keeps */
    if (i32_result == SNAP_OK)
    {
        ui32_read = ui32_ext;
        if (ui32_read > (HDR_LEN - HDR_EXT_OFF))
        {
/* no more than the buffer holds */
            ui32_read = HDR_LEN - HDR_EXT_OFF;
        }
        if (rd_bytes(ps_file, g_aui8_hdr + HDR_EXT_OFF, ui32_read) != UNPACK_OK)
        {
            i32_result = SNAP_EBAD;
        }
    }
/* the PC and the machine */
    if (i32_result == SNAP_OK)
    {
        *pui32_pc = get16(g_aui8_hdr + H_PC_V2);
/* the hardware mode: which values mean a 128K depends on the version */
        if (ui32_ext == EXT_V2)
        {
            b_128k = g_aui8_hdr[H_HW_MODE] >= HW_V2_128K_MIN;
        }
        else
        {
            b_128k = (g_aui8_hdr[H_HW_MODE] >= HW_V3_128K_MIN) && (g_aui8_hdr[H_HW_MODE] != HW_V3_PENTAGON) &&
                     (g_aui8_hdr[H_HW_MODE] != HW_V3_SCORPION) && (g_aui8_hdr[H_HW_MODE] != HW_V3_TS2068);
        }
/* every block inside the file */
        ui32_pos = HDR_EXT_OFF + ui32_ext;
        while ((ui32_pos < ui32_size) && (i32_result == SNAP_OK))
        {
            ff_seek(ps_file, ui32_pos);
/* its head must be inside the file */
            if (((ui32_pos + BLOCK_HEAD_LEN) > ui32_size) || (rd_bytes(ps_file, aui8_head, BLOCK_HEAD_LEN) != UNPACK_OK))
            {
                i32_result = SNAP_EBAD;
            }
            else
            {
/* and its data too */
                ui32_len = block_len(aui8_head);
                if ((ui32_len == 0) || ((ui32_pos + BLOCK_HEAD_LEN + ui32_len) > ui32_size))
                {
                    i32_result = SNAP_EBAD;
                }
                else
                {
/* remember the blocks this machine uses */
                    if (block_addr(aui8_head[BLOCK_PAGE_OFF], b_128k) >= 0)
                    {
                        ui32_mask |= ONE << aui8_head[BLOCK_PAGE_OFF];
                    }
                    ui32_pos += BLOCK_HEAD_LEN + ui32_len;
                }
            }
        }
    }
/* all pages of the machine must be there */
    if (i32_result == SNAP_OK)
    {
        ui32_need = (ONE << BLOCK_48K_8000) | (ONE << BLOCK_48K_C000) | (ONE << BLOCK_48K_4000);
/* 128K: all eight pages */
        if (b_128k)
        {
            ui32_need = BLOCKS_NEEDED_128K;
        }
        if ((ui32_mask & ui32_need) != ui32_need)
        {
/* a page is missing */
            i32_result = SNAP_EBAD;
        }
    }
/* what the caller needs */
    *pui32_ext = ui32_ext;
    *pb_128k = b_128k;
    return i32_result;
}

/* versions 2 and 3: every memory block of the file into the Spectrum's memory */
static int32_t load_blocks(FFILE *ps_file, uint32_t ui32_size, uint32_t ui32_ext, bool b_128k)
{
/* local variables */
    uint8_t aui8_head[BLOCK_HEAD_LEN];
    uint32_t ui32_pos;
    uint32_t ui32_len;
/* a page's address, the result */
    int32_t i32_addr;
    int32_t i32_bad;

/* start values */
    ui32_pos = HDR_EXT_OFF + ui32_ext;
    ui32_len = 0;
    i32_addr = 0;
/* no error yet */
    i32_bad = UNPACK_OK;
    while ((ui32_pos < ui32_size) && (i32_bad == UNPACK_OK))
    {
        ff_seek(ps_file, ui32_pos);
/* the block's head */
        if (rd_bytes(ps_file, aui8_head, BLOCK_HEAD_LEN) != UNPACK_OK)
        {
            i32_bad = UNPACK_BAD;
        }
        else
        {
/* its length and its page */
            ui32_len = block_len(aui8_head);
            i32_addr = block_addr(aui8_head[BLOCK_PAGE_OFF], b_128k);
/* a block of this machine is unpacked into its page */
            if (i32_addr >= 0)
            {
                i32_bad = unpack(ps_file, ui32_len, PAGE, false, (uint32_t)i32_addr, get16(aui8_head) != BLOCK_PLAIN);
            }
/* the next block */
            ui32_pos += BLOCK_HEAD_LEN + ui32_len;
        }
    }
    return i32_bad;
}

/* AY, ports and registers from the header buffer into the stopped machine, then start it */
static void load_state(bool b_v1, bool b_128k, uint32_t ui32_pc)
{
/* local variables */
    uint32_t aui32_words[REG_WORDS];
    uint32_t ui32_im;
    uint32_t ui32_index;
/* a value, the port word, has an AY */
    uint32_t ui32_value;
    uint32_t ui32_port;
    bool b_ay;

/* start values */
    ui32_im = 0;
    ui32_index = 0;
    ui32_value = 0;
/* a 48K machine's paging */
    ui32_port = PORT_7FFD_48K;
/* AY (48K: silent unless the file says it has one) */
    b_ay = b_128k || (!b_v1 && ((g_aui8_hdr[H_EMU_FLAGS] & EMU_FLAG_AY) != 0));
    for (ui32_index = 0; ui32_index < AY_REGS; ui32_index++)
    {
        ui32_value = 0;
/* its value from the file */
        if (b_ay)
        {
            ui32_value = g_aui8_hdr[H_AY_REGS + ui32_index];
        }
        snap_cmd(C_AYWR, ui32_index, ui32_value);
    }
/* the selected AY register */
    ui32_value = 0;
    if (b_ay)
    {
        ui32_value = g_aui8_hdr[H_AY_SELECT];
    }
/* written */
    snap_cmd(C_AYSEL, 0, ui32_value);
/* ports: 7FFD (a 48K snapshot runs in 48K mode) and the border */
    if (b_128k)
    {
        ui32_port = g_aui8_hdr[H_7FFD];
    }
/* the border */
    ui32_port |= (uint32_t)((g_aui8_hdr[H_FLAGS] >> FLAGS_BORDER_SHIFT) & FLAGS_BORDER_MASK) << PORT_BORDER_SHIFT;
    snap_cmd(C_PORT, 0, ui32_port);
/* registers (cpu_t80 layout); interrupt mode 3 does not exist */
    ui32_im = g_aui8_hdr[H_IM] & IM_MASK;
    if (ui32_im == IM_INVALID)
    {
        ui32_im = IM_2;
    }
/* all words start empty */
    u_memset(aui32_words, 0, sizeof aui32_words);
/* the registers of the table */
    for (ui32_index = 0; ui32_index < RMAP_ROWS; ui32_index++)
    {
        ui32_value = g_aui8_hdr[g_aui8_rmap[ui32_index][RMAP_HDR]];
/* two bytes */
        if (g_aui8_rmap[ui32_index][RMAP_BYTES] == REG_16BIT)
        {
            ui32_value = get16(g_aui8_hdr + g_aui8_rmap[ui32_index][RMAP_HDR]);
        }
/* into its word, at its bit */
        aui32_words[g_aui8_rmap[ui32_index][RMAP_POS] >> REG_WORD_SHIFT] |=
            ui32_value << (g_aui8_rmap[ui32_index][RMAP_POS] & REG_BIT_MASK);
    }
/* R from its two parts, PC, interrupt mode and flip-flops */
    aui32_words[REG_WORD_R] |= (uint32_t)((g_aui8_hdr[H_R] & R_LOW_MASK) |
                                          ((g_aui8_hdr[H_FLAGS] & FLAGS_R7) << R_BIT7_SHIFT)) << R_SHIFT;
    aui32_words[REG_WORD_PC] |= ui32_pc;
/* interrupt mode and the two flip-flops */
    ui32_value = ui32_im << IM_SHIFT;
    if (g_aui8_hdr[H_IFF1] != 0)
    {
        ui32_value |= ONE << IFF1_SHIFT;
    }
/* IFF2 */
    if (g_aui8_hdr[H_IFF2] != 0)
    {
        ui32_value |= ONE << IFF2_SHIFT;
    }
    aui32_words[REG_WORD_INT] |= ui32_value;
/* into the CPU, which then starts at the snapshot's PC */
    for (ui32_index = 0; ui32_index < REG_WORDS; ui32_index++)
    {
        snap_cmd(C_DIR, ui32_index, aui32_words[ui32_index]);
    }
/* LOAD, and the CPU runs */
    snap_cmd(C_LOAD, 0, 0);
    snap_ctl(0);
}

/* load a .z80 file into the machine: SNAP_OK, SNAP_EBAD, SNAP_ERUN */
int32_t snap_load(FFILE *ps_file)
{
/* local variables */
    uint32_t ui32_size;
    uint32_t ui32_ext;
    uint32_t ui32_pc;
/* version 1, a 128K machine */
    bool b_v1;
    bool b_128k;
/* a bad block, the result */
    int32_t i32_bad;
    int32_t i32_result;

/* start values */
    ui32_size = ps_file->ui32_size;
    ui32_ext = 0;
    ui32_pc = 0;
/* not known yet */
    b_v1 = false;
    b_128k = false;
/* no error yet */
    i32_bad = UNPACK_OK;
    i32_result = SNAP_OK;
/* the first 30 bytes are the same in every version */
    u_memset(g_aui8_hdr, 0, sizeof g_aui8_hdr);
    ff_seek(ps_file, 0);
/* too short, or not readable */
    if ((ui32_size < FILE_MIN) || (rd_bytes(ps_file, g_aui8_hdr, HDR_V1_LEN) != UNPACK_OK))
    {
        i32_result = SNAP_EBAD;
    }
/* check the whole file before anything is changed */
    if (i32_result == SNAP_OK)
    {
        if (g_aui8_hdr[H_FLAGS] == FLAGS_UNSET)
        {
            g_aui8_hdr[H_FLAGS] = FLAGS_DEFAULT;
        }
/* a PC of 0 here means version 2 or 3, with the PC in the extended header */
        ui32_pc = get16(g_aui8_hdr + H_PC);
        b_v1 = ui32_pc != 0;
/* the extended header and the blocks are checked */
        if (!b_v1)
        {
            i32_result = check_v2(ps_file, ui32_size, &ui32_ext, &ui32_pc, &b_128k);
        }
    }
/* stop the CPU */
    if (i32_result == SNAP_OK)
    {
        i32_result = snap_freeze();
    }
/* memory, then the state; the CPU starts again even if a block was bad */
    if (i32_result == SNAP_OK)
    {
        if (b_v1)
        {
/* version 1: one block for the 48K */
            ff_seek(ps_file, HDR_V1_LEN);
            i32_bad = unpack(ps_file, ui32_size - HDR_V1_LEN, V1_PAGES * PAGE, true, 0,
                             (g_aui8_hdr[H_FLAGS] & FLAGS_V1_PACKED) != 0);
        }
        else
        {
/* version 2 and 3: block by block */
            i32_bad = load_blocks(ps_file, ui32_size, ui32_ext, b_128k);
        }
/* the state */
        load_state(b_v1, b_128k, ui32_pc);
/* a bad block is reported */
        if (i32_bad != UNPACK_OK)
        {
            i32_result = SNAP_EBAD;
        }
    }
    return i32_result;
}

/* screenshot (Print Screen): the screen shown (page 5 or 7) with the border as a */
/* 320 x 240 BMP; flashing characters as their "off" phase */

/* the colour of one pixel of the Spectrum's screen */
static uint8_t screen_pixel(int32_t i32_x, int32_t i32_y)
{
/* local variables */
    uint8_t ui8_bits;
    uint8_t ui8_attr;
    uint8_t ui8_colour;

/* the pixel byte: the screen's rows are stored in an order of their own */
    ui8_bits = g_aui8_scr[((i32_y & Y_THIRD_MASK) << Y_THIRD_SHIFT) | ((i32_y & Y_LINE_MASK) << Y_LINE_SHIFT) |
                          ((i32_y & Y_ROW_MASK) << Y_ROW_SHIFT) | (i32_x >> X_BYTE_SHIFT)];
    ui8_attr = g_aui8_scr[SCREEN_ATTR_OFF + ((i32_y >> X_BYTE_SHIFT) * SCREEN_ATTR_COLS) + (i32_x >> X_BYTE_SHIFT)];
/* ink or paper */
    if (((ui8_bits >> (X_FIRST_BIT - (i32_x & X_BIT_MASK))) & ONE) != 0)
    {
        ui8_colour = (uint8_t)(ui8_attr & ATTR_INK_MASK);
    }
    else
    {
        ui8_colour = (uint8_t)((ui8_attr >> ATTR_PAPER_SHIFT) & ATTR_INK_MASK);
    }
/* bright colours are the second half of the palette */
    if ((ui8_attr & ATTR_BRIGHT) != 0)
    {
        ui8_colour |= COLOUR_BRIGHT;
    }
    return ui8_colour;
}

/* the screen shown and the border as a 320 x 240 BMP in a folder: SNAP_OK, SNAP_ERUN, FAT_* */
int32_t snap_screenshot(uint32_t ui32_dir, const char ac_name11[FAT_NAME11_LEN])
{
/* local variables */
    uint8_t aui8_row[SHOT_WIDTH];
    uint32_t ui32_state;
    uint32_t ui32_base;
/* a loop counter, the picture's row and column */
    uint32_t ui32_index;
    int32_t i32_y;
    int32_t i32_x;
/* the same on the Spectrum's screen, the border colour */
    int32_t i32_sy;
    int32_t i32_sx;
    int32_t i32_border;
/* the result of closing, the result */
    int32_t i32_end;
    int32_t i32_result;

/* start values */
    ui32_state = 0;
    ui32_base = SCREEN_PAGE_NORMAL * PAGE;
    ui32_index = 0;
/* the bottom row first */
    i32_y = SHOT_LAST_ROW;
    i32_x = 0;
    i32_sy = 0;
/* nothing yet */
    i32_sx = 0;
    i32_border = 0;
    i32_end = FAT_OK;
/* the CPU must stop */
    i32_result = SNAP_OK;
    if (snap_freeze() != SNAP_OK)
    {
        i32_result = SNAP_ERUN;
    }
    else
    {
/* which screen is shown (7FFD bit 3: the screen in page 7), and the border */
        ui32_state = snap_cmd(C_STATE, 0, 0);
        if ((ui32_state & ST_SCREEN_PAGE7) != 0)
        {
            ui32_base = SCREEN_PAGE_SHADOW * PAGE;
        }
/* the border colour */
        i32_border = (int32_t)((ui32_state >> ST_BORDER_SHIFT) & ST_BORDER_MASK);
/* a copy of the screen; then the Spectrum runs on */
        for (ui32_index = 0; ui32_index < SCREEN_BYTES; ui32_index++)
        {
            g_aui8_scr[ui32_index] = (uint8_t)snap_cmd(C_MRD, ui32_base + ui32_index, 0);
        }
        snap_ctl(0);
/* the picture, bottom row first */
        i32_result = shot_begin(ui32_dir, ac_name11, SHOT_WIDTH, SHOT_HEIGHT, g_aui8_pal);
        while ((i32_y >= 0) && (i32_result == FAT_OK))
        {
/* the row on the Spectrum's screen */
            i32_sy = i32_y - SHOT_BORDER_TOP;
            for (i32_x = 0; i32_x < SHOT_WIDTH; i32_x++)
            {
                i32_sx = i32_x - SHOT_BORDER_LEFT;
/* border around the screen */
                if ((i32_sy < 0) || (i32_sy >= SCREEN_HEIGHT) || (i32_sx < 0) || (i32_sx >= SCREEN_WIDTH))
                {
                    aui8_row[i32_x] = (uint8_t)i32_border;
                }
                else
                {
/* a pixel of the screen */
                    aui8_row[i32_x] = screen_pixel(i32_sx, i32_sy);
                }
            }
            i32_result = shot_row(aui8_row);
            i32_y--;
        }
/* the file is closed, or deleted after an error; the first error is the result */
        i32_end = shot_end();
        if (i32_result == FAT_OK)
        {
/* the error of closing */
            i32_result = i32_end;
        }
    }
    return i32_result;
}

/* back to the state after a start: the next machine starts the loader again without an ESP32 */
/* restart (esp_hw.cpp; the Bluetooth connection stays) */
void snap_reset(void)
{
    u_memset(g_aui8_hdr, 0, sizeof g_aui8_hdr);
    g_i32_wr_err = 0;
/* the read cache */
    g_ui32_cache_addr = 0;
    g_ui8_cache_val = 0;
    u_memset(g_aui8_scr, 0, sizeof g_aui8_scr);
}
