/* snap_test.c -- snap.c + fat.c on the PC against a card image, with a model of the */
/* snapshot hardware (zx_bus.v: frozen CPU, 128K RAM, registers, AY, ports). */
/* */
/*   snap_test IMAGE save DIR NAME8 SEED EXPECTED OUT */
/*       Makes a machine state from SEED (pages with runs, ED bytes, random data; */
/*       random registers; HALT if SEED is odd), writes it to EXPECTED (dump format */
/*       below), saves DIR/NAME8.Z80, checks the machine runs on unchanged (AY */
/*       volumes and select restored, CPU not frozen), copies the file to OUT, then */
/*       loads it into a cleared machine and compares everything. */
/*   snap_test IMAGE load PATH DUMP */
/*       Loads PATH ("/SNAPS/X.Z80") into a machine filled with 0x55 and writes the */
/*       resulting state to DUMP; prints "result N" (snap_load's return value). */
/*   snap_test IMAGE shot OUT.BMP 7FFD */
/*       Takes two screenshots of a random screen and checks every pixel of the second. */
/* */
/* Dump: 128K RAM (pages 0-7), 7 register words (cpu_t80 layout, little endian), */
/* 16 AY registers, AY select, 7FFD, border. Checked by z80ref.py. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
/* bool; the card */
#include <stdbool.h>
#include "../../../ESP32/v1/src/fat.h"
/* the code under test, and its registers on the PC */
#include "../../../ESP32/v1/src/snap.h"
#include "../../../ESP32/v1/src/shot.h"
#include "host_hw.h"

/* bytes of one card sector */
#define SECTOR_SIZE 512
/* results of the card functions */
#define SD_OK 0
#define SD_ERROR (-1)
/* what fifo_free always answers: the whole FIFO */
#define FIFO_ROOM 512
/* the machine: the 18-bit memory window, its RAM part, one page, the pages */
#define MEM_SIZE 0x40000
#define MEM_MASK 0x3FFFF
#define RAM_SIZE 0x20000
/* one page, the pages */
#define PAGE_SIZE 16384
#define PAGES 8
/* the CPU's register words; the one with PC, the one with the mode bits */
#define REG_WORDS 7
#define REG_LAST 6
#define REG_PC 2
/* the mode word; bytes of a word */
#define REG_MISC 6
#define WORD_BYTES 4
/* the halves of a word */
#define LOW16_MASK 0xFFFF
#define HIGH16_MASK 0xFFFF0000u
#define HIGH16_SHIFT 16
/* the mode word: interrupt mode from bit 16, IFF1 bit 18, IFF2 bit 19 */
#define IM_COUNT 3
#define IM_SHIFT 16
/* the two interrupt flip-flops */
#define IFF1_SHIFT 18
#define IFF2_SHIFT 19
/* shifts of the bytes of a word */
#define BYTE1_SHIFT 8
#define BYTE2_SHIFT 16
#define BYTE3_SHIFT 24
/* the AY: registers, and the three volume registers */
#define AY_REGS 16
#define AY_ADDR_MASK 15
/* the volumes */
#define AY_VOL_A 8
#define AY_VOL_B 9
#define AY_VOL_C 10
/* the ports: 7FFD's bits, the border's */
#define P7FFD_MASK 0x3F
#define P7FFD_SCREEN 8
#define BORDER_MASK 7
/* SNAPCTL's freeze bit */
#define CTL_FREEZE 1
/* the snapshot port's commands */
#define CMD_MRD 1
#define CMD_MWR 2
#define CMD_REG 3
/* a word for a LOAD, the LOAD */
#define CMD_DIR 4
#define CMD_LOAD 5
/* the AY */
#define CMD_AYRD 6
#define CMD_AYWR 7
#define CMD_AYSEL 8
/* the ports, the state */
#define CMD_PORT 9
#define CMD_STATE 10
/* the fields of the STATE answer and of the PORT data */
#define STATE_BORDER_SHIFT 8
#define STATE_AYSEL_SHIFT 16
#define STATE_HALT_SHIFT 24
/* the dump's last bytes: AY select, 7FFD, border */
#define TAIL_BYTES 3
#define TAIL_7FFD 1
#define TAIL_BORDER 2
/* the bytes of a word after the lowest */
#define BYTE1 1
#define BYTE2 2
#define BYTE3 3
/* the random generator (the C library's classic one) */
#define RND_MUL 1103515245u
#define RND_ADD 12345u
/* the bits used; the seed's multiplier */
#define RND_SHIFT 8
#define SEED_MUL 2654435761u
/* make_state's page patterns */
#define PATTERNS 8
#define PAT_RANDOM 0
#define PAT_ZERO 1
/* runs and EDs, all EDs, ED and another byte */
#define PAT_RUNS_ED 2
#define PAT_ALL_ED 3
#define PAT_ED_X 4
/* long runs, mostly EDs; the ED byte */
#define PAT_LONG_RUNS 5
#define PAT_MOSTLY_ED 6
#define ED_BYTE 0xED
/* runs + EDs: the divider's range, the mask */
#define RUN_DIV_RANGE 9
#define RUN_MASK 3
/* odd positions; the shift of the other byte */
#define ODD_MASK 1
#define ED_X_SHIFT 3
/* long runs */
#define LONG_PERIOD 300
#define LONG_RUN 280
/* mostly EDs */
#define MOSTLY_A 4
#define MOSTLY_B 3
#define MOSTLY_OTHER 7
/* runs of 5 */
#define FIVE_PERIOD 7
#define FIVE_RUN 5
#define FIVE_BYTE 0x11
/* what a machine is filled with before a load */
#define FILL_MEM 0x55
#define FILL_REGS 0xA5
#define FILL_AY 0x33
/* AY select and the ports */
#define FILL_AYSEL 9
#define FILL_7FFD 0x17
#define FILL_BORDER 5
/* names and paths */
#define NAME8_LEN 8
#define EXT_0 8
/* its other characters */
#define EXT_1 9
#define EXT_2 10
/* buffers */
#define PART_LEN 64
#define PATH_LEN 64
#define WANT_LEN 12
/* the screenshot: the border colour, how many are taken */
#define SHOT_BORDER 3
#define SHOT_COUNT 2
/* the BMP: 118 header bytes, 320 x 240 pixels of 4 bits, bottom row first */
#define BMP_MAX 40000
#define BMP_HEADER 118
#define BMP_WIDTH 320
/* height, bytes of a row, the last row */
#define BMP_HEIGHT 240
#define BMP_ROW_BYTES 160
#define BMP_LAST_ROW 239
/* bits per pixel */
#define BMP_BPP 4
/* the header bytes checked: data offset, width (0x140), height, bits per pixel */
#define HDR_M 1
#define HDR_OFFSET 10
#define HDR_WIDTH_LOW 18
/* the width's high byte, height, bits per pixel */
#define HDR_WIDTH_HIGH 19
#define HDR_HEIGHT 22
#define HDR_BPP 28
/* the width's two bytes */
#define WIDTH_LOW 0x40
#define WIDTH_HIGH 1
/* two pixels in a byte, the left one in the high half */
#define PIXELS_PER_BYTE 2
#define NIBBLE_MASK 15
#define NIBBLE_SHIFT 4
/* the Spectrum screen inside the picture */
#define SCREEN_TOP 24
#define SCREEN_BOTTOM 216
/* left and right */
#define SCREEN_LEFT 32
#define SCREEN_RIGHT 288
/* the screen memory: pages 5 / 7, 6144 bytes of pixels, then the attributes */
#define SCREEN_PAGE_NORMAL 5u
#define SCREEN_PAGE_SHADOW 7u
#define ATTR_OFFSET 6144
/* a character cell, the columns */
#define CELL 8
#define CELL_MASK 7
#define COLUMNS 32
/* a pixel line's address: third * 2048 + line in the cell * 256 + row in the third * 32 */
#define THIRD_SHIFT 6
#define THIRD_BYTES 2048
/* a line inside a cell, the row's shift */
#define LINE_BYTES 256
#define ROW_SHIFT 3
/* an attribute: bright bit, colours of 3 bits; the left pixel's bit */
#define ATTR_BRIGHT 0x40
#define BRIGHT_ADD 8
/* colours; the left pixel's bit */
#define COLOURS 8
#define PIXEL_TOP_BIT 0x80
/* pixel errors listed */
#define PIXEL_ERRORS_SHOWN 5
/* the command line */
#define ARG_IMAGE 1
#define ARG_MODE 2
/* mode load */
#define ARG_LOAD_PATH 3
#define ARG_LOAD_DUMP 4
/* mode save */
#define ARG_SAVE_DIR 3
#define ARG_SAVE_NAME 4
#define ARG_SAVE_SEED 5
/* the two output files */
#define ARG_SAVE_EXPECTED 6
#define ARG_SAVE_OUT 7
/* mode shot */
#define ARG_SHOT_OUT 3
#define ARG_SHOT_7FFD 4
/* the fewest arguments */
#define ARGS_MIN 4
/* the program's results */
#define EXIT_OK 0
#define EXIT_ERRORS 1
#define EXIT_USAGE 2
/* strcmp's "the same" */
#define SAME 0
/* one */
#define ONE 1

/* what find_cb looks for, and what it found */
typedef struct
{
/* the name, where it is, how long */
    const char *pc_want;
    uint32_t ui32_clus;
    uint32_t ui32_size;
/* found; a folder is wanted */
    bool b_hit;
    bool b_dir;
} FIND;

/* the bits each AY register has */
static const uint8_t g_aui8_ay_mask[AY_REGS] = { 0xFF, 0x0F, 0xFF, 0x0F, 0xFF, 0x0F, 0x1F, 0xFF,
                                                 0x1F, 0x1F, 0x1F, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF };
/* machine model: memory, registers, the words written for a LOAD, the AY */
static uint8_t g_aui8_mem[MEM_SIZE];
static uint32_t g_aui32_regs[REG_WORDS];
/* the words for a LOAD, the AY */
static uint32_t g_aui32_dirw[REG_WORDS];
static uint8_t g_aui8_ay[AY_REGS];
/* the state a save must keep: memory, registers, AY */
static uint8_t g_aui8_mem0[RAM_SIZE];
static uint32_t g_aui32_regs0[REG_WORDS];
static uint8_t g_aui8_ay0[AY_REGS];
/* the screenshot read back */
static uint8_t g_aui8_bmp[BMP_MAX];
/* the file being read (too big for the stack) */
static FFILE g_s_file;
/* the card image */
static FILE *g_ps_img;
/* AY select as written, the AY's address, the ports, HALT */
static uint8_t g_ui8_ay_sel;
static uint8_t g_ui8_ay_addr;
static uint8_t g_ui8_p7ffd;
/* the border, HALT */
static uint8_t g_ui8_border;
static uint8_t g_ui8_halt;
/* the same before the save */
static uint8_t g_ui8_sel0;
static uint8_t g_ui8_p7ffd0;
static uint8_t g_ui8_border0;
/* frozen, errors found, LOAD commands seen */
static bool g_b_frozen;
static int32_t g_i32_errors;
static int32_t g_i32_loads;
/* the random generator's state */
static uint32_t g_ui32_rnd = ONE;

/* read one sector of the image */
int32_t sd_read(uint32_t ui32_lba, uint8_t *pui8_buf)
{
    int32_t i32_result;

    i32_result = SD_ERROR;
/* seek, then read: both must work */
    if (fseek(g_ps_img, (long)ui32_lba * SECTOR_SIZE, SEEK_SET) == 0)
    {
        if (fread(pui8_buf, ONE, SECTOR_SIZE, g_ps_img) == SECTOR_SIZE)
        {
            i32_result = SD_OK;
        }
    }
/* SD_OK or SD_ERROR */
    return i32_result;
}

/* write one sector of the image */
int32_t sd_write(uint32_t ui32_lba, const uint8_t *pui8_buf)
{
    int32_t i32_result;

    i32_result = SD_ERROR;
/* seek, then write: both must work */
    if (fseek(g_ps_img, (long)ui32_lba * SECTOR_SIZE, SEEK_SET) == 0)
    {
        if (fwrite(pui8_buf, ONE, SECTOR_SIZE, g_ps_img) == SECTOR_SIZE)
        {
            i32_result = SD_OK;
        }
    }
/* SD_OK or SD_ERROR */
    return i32_result;
}

/* the pulse FIFO is not used: always room, commands dropped */
uint32_t fifo_free(void)
{
    return FIFO_ROOM;
}

/* a command is dropped */
void fifo_push(uint32_t ui32_cmd)
{
    (void)ui32_cmd;
}

/* the timer stands still */
uint32_t timer_now(void)
{
    return 0;
}

/* one more error */
static void err(const char *pc_text)
{
    printf("ERROR: %s\n", pc_text);
    g_i32_errors++;
}

/* SNAPCTL: freeze / release, and its status */
void snap_ctl(uint32_t ui32_value)
{
    g_b_frozen = (ui32_value & CTL_FREEZE) != 0;
}

uint32_t snap_status(void)
{
/* local variables */
    uint32_t ui32_status;

/* start values */
    ui32_status = 0;
    if (g_b_frozen)
    {
/* frozen */
        ui32_status = SNAP_FROZEN;
    }
    return ui32_status;
}

/* one command of the snapshot port, as zx_bus.v executes it */
uint32_t snap_cmd(uint32_t ui32_cmd, uint32_t ui32_addr, uint32_t ui32_data)
{
/* local variables */
    uint32_t ui32_result;

/* start values */
    ui32_result = 0;
    if (!g_b_frozen)
    {
        err("command while not frozen");
    }
    else
    {
/* by the command */
        switch (ui32_cmd)
        {
/* memory read: the whole window */
        case CMD_MRD:
            if (ui32_addr >= MEM_SIZE)
            {
                err("MRD address");
            }
/* the byte */
            ui32_result = g_aui8_mem[ui32_addr & MEM_MASK];
            break;
/* memory write: RAM only */
        case CMD_MWR:
            if (ui32_addr >= RAM_SIZE)
            {
                err("MWR outside RAM");
            }
/* the byte is written */
            g_aui8_mem[ui32_addr & MEM_MASK] = (uint8_t)ui32_data;
            break;
/* a register word read */
        case CMD_REG:
            if (ui32_addr > REG_LAST)
            {
                err("REG word");
            }
/* the word */
            ui32_result = g_aui32_regs[ui32_addr % REG_WORDS];
            break;
/* a register word for the next LOAD */
        case CMD_DIR:
            if (ui32_addr > REG_LAST)
            {
                err("DIR word");
            }
/* kept */
            g_aui32_dirw[ui32_addr % REG_WORDS] = ui32_data;
            break;
/* LOAD: the words become the registers, HALT ends */
        case CMD_LOAD:
            memcpy(g_aui32_regs, g_aui32_dirw, sizeof g_aui32_regs);
            g_ui8_halt = 0;
/* counted */
            g_i32_loads++;
            break;
/* AY read: unused bits read as 0 */
        case CMD_AYRD:
            g_ui8_ay_addr = (uint8_t)(ui32_addr & AY_ADDR_MASK);
/* the register's value */
            ui32_result = g_aui8_ay[g_ui8_ay_addr] & g_aui8_ay_mask[g_ui8_ay_addr];
            break;
/* AY write */
        case CMD_AYWR:
            g_ui8_ay_addr = (uint8_t)(ui32_addr & AY_ADDR_MASK);
/* the value */
            g_aui8_ay[g_ui8_ay_addr] = (uint8_t)ui32_data;
            break;
/* AY select */
        case CMD_AYSEL:
            g_ui8_ay_addr = (uint8_t)(ui32_data & AY_ADDR_MASK);
/* as written */
            g_ui8_ay_sel = (uint8_t)ui32_data;
            break;
/* the ports: 7FFD and the border */
        case CMD_PORT:
            g_ui8_p7ffd = (uint8_t)ui32_data;
/* the border */
            g_ui8_border = (uint8_t)((ui32_data >> STATE_BORDER_SHIFT) & BORDER_MASK);
            break;
/* the ports, AY select and HALT read */
        case CMD_STATE:
            ui32_result = (uint32_t)g_ui8_p7ffd | ((uint32_t)g_ui8_border << STATE_BORDER_SHIFT) |
                          ((uint32_t)g_ui8_ay_sel << STATE_AYSEL_SHIFT) | ((uint32_t)g_ui8_halt << STATE_HALT_SHIFT);
            break;
/* any other number is an error */
        default:
            err("bad command");
            break;
        }
    }
/* 0, or what was read */
    return ui32_result;
}

/* the machine's state into a file */
static void dump(const char *pc_name)
{
/* local variables */
    FILE *ps_out;
    uint8_t aui8_tail[TAIL_BYTES];
    uint8_t aui8_word[WORD_BYTES];
/* a byte, a counter */
    uint8_t ui8_value;
    int32_t i32_index;

/* start values */
    ps_out = fopen(pc_name, "wb");
    ui8_value = 0;
    i32_index = 0;
/* the RAM */
    fwrite(g_aui8_mem, ONE, RAM_SIZE, ps_out);
/* the register words, little endian */
    for (i32_index = 0; i32_index < REG_WORDS; i32_index++)
    {
        aui8_word[0] = (uint8_t)g_aui32_regs[i32_index];
        aui8_word[BYTE1] = (uint8_t)(g_aui32_regs[i32_index] >> BYTE1_SHIFT);
/* the upper two */
        aui8_word[BYTE2] = (uint8_t)(g_aui32_regs[i32_index] >> BYTE2_SHIFT);
        aui8_word[BYTE3] = (uint8_t)(g_aui32_regs[i32_index] >> BYTE3_SHIFT);
        fwrite(aui8_word, ONE, WORD_BYTES, ps_out);
    }
/* the AY registers, as they read */
    for (i32_index = 0; i32_index < AY_REGS; i32_index++)
    {
        ui8_value = g_aui8_ay[i32_index] & g_aui8_ay_mask[i32_index];
        fwrite(&ui8_value, ONE, ONE, ps_out);
    }
/* AY select and the ports */
    aui8_tail[0] = g_ui8_ay_sel;
    aui8_tail[TAIL_7FFD] = g_ui8_p7ffd;
    aui8_tail[TAIL_BORDER] = g_ui8_border;
/* written; the file is complete */
    fwrite(aui8_tail, ONE, TAIL_BYTES, ps_out);
    fclose(ps_out);
}

/* fat_list's callback: stop at the file or folder wanted */
static int32_t find_cb(const DIRENT *ps_entry, void *p_ctx)
{
/* local variables */
    FIND *ps_find;
    int32_t i32_stop;
    bool b_is_dir;

/* start values */
    ps_find = (FIND *)p_ctx;
    i32_stop = 0;
    b_is_dir = (ps_entry->ui8_attr & ATTR_DIR) != 0;
/* the name, and the kind wanted */
    if ((strcmp(ps_entry->ac_name, ps_find->pc_want) == SAME) && (b_is_dir == ps_find->b_dir))
    {
/* found: where it starts and how long it is */
        ps_find->ui32_clus = ps_entry->ui32_clus;
        ps_find->ui32_size = ps_entry->ui32_size;
        ps_find->b_hit = true;
/* the scan ends */
        i32_stop = ONE;
    }
    return i32_stop;
}

/* a file or a folder by its name in one directory */
static bool find(uint32_t ui32_dir, const char *pc_name, bool b_dir, uint32_t *pui32_clus, uint32_t *pui32_size)
{
/* local variables */
    FIND s_find;

/* start values */
    s_find.pc_want = pc_name;
    s_find.ui32_clus = 0;
    s_find.ui32_size = 0;
/* not found yet; a file or a folder; the scan */
    s_find.b_hit = false;
    s_find.b_dir = b_dir;
    fat_list(ui32_dir, find_cb, &s_find);
/* 0 / 0 when there is none */
    *pui32_clus = s_find.ui32_clus;
    *pui32_size = s_find.ui32_size;
    return s_find.b_hit;
}

/* "/A/B.Z80" -> the file opened */
static bool open_path(const char *pc_path, FFILE *ps_file)
{
/* local variables */
    char ac_part[PART_LEN];
    const char *pc_from;
    const char *pc_slash;
/* the folder so far, an entry's place and size */
    uint32_t ui32_dir;
    uint32_t ui32_clus;
    uint32_t ui32_size;
/* still found */
    bool b_ok;

/* start values */
    pc_from = pc_path + ONE;
    pc_slash = strchr(pc_from, '/');
    ui32_dir = 0;
/* the root; nothing found yet */
    ui32_clus = 0;
    ui32_size = 0;
    b_ok = true;
/* down through the folders */
    while (b_ok && (pc_slash != NULL))
    {
        memcpy(ac_part, pc_from, (size_t)(pc_slash - pc_from));
        ac_part[pc_slash - pc_from] = 0;
/* the folder of that name */
        b_ok = find(ui32_dir, ac_part, true, &ui32_clus, &ui32_size);
        if (b_ok)
        {
            ui32_dir = ui32_clus;
/* the next part */
            pc_from = pc_slash + ONE;
            pc_slash = strchr(pc_from, '/');
        }
    }
/* the file itself */
    if (b_ok)
    {
        b_ok = find(ui32_dir, pc_from, false, &ui32_clus, &ui32_size);
    }
/* found: opened */
    if (b_ok)
    {
        ff_open(ps_file, ui32_clus, ui32_size);
    }
    return b_ok;
}

/* the next random number (24 bits) */
static uint32_t next(void)
{
    g_ui32_rnd = (g_ui32_rnd * RND_MUL) + RND_ADD;
    return g_ui32_rnd >> RND_SHIFT;
}

/* one byte of a page of make_state, by the page's pattern */
static uint8_t pattern_byte(uint32_t ui32_pattern, uint32_t ui32_index)
{
/* local variables */
    uint8_t ui8_byte;

    ui8_byte = 0;
    switch (ui32_pattern)
    {
/* incompressible */
    case PAT_RANDOM:
        ui8_byte = (uint8_t)next();
        break;
/* all zeros */
    case PAT_ZERO:
        ui8_byte = 0;
        break;
/* runs + EDs */
    case PAT_RUNS_ED:
        if (((ui32_index / ((next() % RUN_DIV_RANGE) + ONE)) & RUN_MASK) != 0)
        {
            ui8_byte = ED_BYTE;
        }
        else
        {
/* a random byte */
            ui8_byte = (uint8_t)next();
        }
        break;
/* nothing but EDs */
    case PAT_ALL_ED:
        ui8_byte = ED_BYTE;
        break;
/* ED x ED x ... */
    case PAT_ED_X:
        if ((ui32_index & ODD_MASK) != 0)
        {
            ui8_byte = ED_BYTE;
        }
        else
        {
/* the other byte */
            ui8_byte = (uint8_t)(ui32_index >> ED_X_SHIFT);
        }
        break;
/* long runs */
    case PAT_LONG_RUNS:
        if ((ui32_index % LONG_PERIOD) < LONG_RUN)
        {
            ui8_byte = (uint8_t)(ui32_index / LONG_PERIOD);
        }
        else
        {
/* a random byte ends the run */
            ui8_byte = (uint8_t)next();
        }
        break;
/* mostly EDs, now and then another byte */
    case PAT_MOSTLY_ED:
        ui8_byte = ED_BYTE;
        if ((next() % MOSTLY_A) == 0)
        {
/* now and then a 7 */
            if ((next() % MOSTLY_B) == 0)
            {
                ui8_byte = MOSTLY_OTHER;
            }
        }
        break;
/* runs of 5 */
    default:
        if ((ui32_index % FIVE_PERIOD) < FIVE_RUN)
        {
            ui8_byte = FIVE_BYTE;
        }
        else
        {
/* then other bytes */
            ui8_byte = (uint8_t)ui32_index;
        }
        break;
    }
    return ui8_byte;
}

/* a machine state from a seed */
static void make_state(uint32_t ui32_seed)
{
/* local variables */
    uint8_t *pui8_page;
    uint32_t ui32_index;
    uint32_t ui32_page;
/* two random numbers */
    uint32_t ui32_low;
    uint32_t ui32_high;

/* start values */
    pui8_page = NULL;
    ui32_index = 0;
    ui32_page = 0;
/* the generator starts from the seed */
    ui32_low = 0;
    ui32_high = 0;
    g_ui32_rnd = (ui32_seed * SEED_MUL) + ONE;
/* the eight pages, each with its own pattern */
    for (ui32_page = 0; ui32_page < PAGES; ui32_page++)
    {
        pui8_page = g_aui8_mem + (ui32_page * PAGE_SIZE);
/* its bytes */
        for (ui32_index = 0; ui32_index < PAGE_SIZE; ui32_index++)
        {
            pui8_page[ui32_index] = pattern_byte((ui32_page + ui32_seed) % PATTERNS, ui32_index);
        }
    }
/* random registers */
    for (ui32_index = 0; ui32_index < REG_WORDS; ui32_index++)
    {
        ui32_low = next();
        ui32_high = next();
/* 32 bits from the two */
        g_aui32_regs[ui32_index] = ui32_low ^ (ui32_high << HIGH16_SHIFT);
    }
/* the mode word: interrupt mode 0..2, IFF1, IFF2 */
    g_aui32_regs[REG_MISC] = g_aui32_regs[REG_MISC] & LOW16_MASK;
    g_aui32_regs[REG_MISC] |= (next() % IM_COUNT) << IM_SHIFT;
/* the two flip-flops */
    g_aui32_regs[REG_MISC] |= (next() & ODD_MASK) << IFF1_SHIFT;
    g_aui32_regs[REG_MISC] |= (next() & ODD_MASK) << IFF2_SHIFT;
/* the AY and the ports */
    for (ui32_index = 0; ui32_index < AY_REGS; ui32_index++)
    {
        g_aui8_ay[ui32_index] = (uint8_t)next();
    }
/* AY select */
    g_ui8_ay_sel = (uint8_t)(next() & AY_ADDR_MASK);
    g_ui8_ay_addr = g_ui8_ay_sel;
/* the ports */
    g_ui8_p7ffd = (uint8_t)(next() & P7FFD_MASK);
    g_ui8_border = (uint8_t)(next() & BORDER_MASK);
/* HALT if the seed is odd */
    g_ui8_halt = (uint8_t)(ui32_seed & ODD_MASK);
}

/* the exit code after a mode that counted its errors */
static int32_t exit_code(void)
{
/* local variables */
    int32_t i32_exit;

/* start values */
    i32_exit = EXIT_OK;
    if (g_i32_errors != 0)
    {
/* errors */
        i32_exit = EXIT_ERRORS;
    }
    return i32_exit;
}

/* "load": a snapshot file into a filled machine, the result dumped */
static int32_t run_load(char **argv)
{
/* local variables */
    int32_t i32_result;
    int32_t i32_exit;

/* start values */
    i32_result = 0;
    i32_exit = EXIT_OK;
/* a machine with known contents */
    memset(g_aui8_mem, FILL_MEM, sizeof g_aui8_mem);
    memset(g_aui32_regs, FILL_REGS, sizeof g_aui32_regs);
    memset(g_aui8_ay, FILL_AY, sizeof g_aui8_ay);
/* AY select and the ports */
    g_ui8_ay_sel = FILL_AYSEL;
    g_ui8_p7ffd = FILL_7FFD;
    g_ui8_border = FILL_BORDER;
/* running; the file */
    g_ui8_halt = 0;
    if (!open_path(argv[ARG_LOAD_PATH], &g_s_file))
    {
/* no such file */
        printf("ERROR: %s not found\n", argv[ARG_LOAD_PATH]);
        i32_exit = EXIT_ERRORS;
    }
    else
    {
/* load: ok with one LOAD, or a bad file */
        i32_result = snap_load(&g_s_file);
        printf("result %d, loads %d, frozen %d\n", (int)i32_result, (int)g_i32_loads, (int)g_b_frozen);
/* the CPU must run again */
        if (g_b_frozen)
        {
            err("left frozen");
        }
/* a good file is loaded with exactly one LOAD */
        if ((i32_result == SNAP_OK) && (g_i32_loads != ONE))
        {
            err("no LOAD");
        }
/* only these two results are known */
        if ((i32_result != SNAP_OK) && (i32_result != SNAP_EBAD))
        {
            err("unexpected result");
        }
/* the machine's state for z80ref.py */
        dump(argv[ARG_LOAD_DUMP]);
        i32_exit = exit_code();
    }
    return i32_exit;
}

/* are the AY registers (the bits they have) as before the save? one error per register */
static void check_ay(const char *pc_text)
{
    uint32_t ui32_index;

    for (ui32_index = 0; ui32_index < AY_REGS; ui32_index++)
    {
/* unused AY bits read as 0 (as the real one) */
        if ((g_aui8_ay[ui32_index] & g_aui8_ay_mask[ui32_index]) != (g_aui8_ay0[ui32_index] & g_aui8_ay_mask[ui32_index]))
        {
            err(pc_text);
        }
    }
}

/* "save", second half: copy the saved file out, then load it into a cleared machine */
static int32_t save_reload(char **argv)
{
/* local variables */
    char ac_path[PATH_LEN];
    FILE *ps_out;
    uint32_t ui32_index;
/* a byte, the load's result, the exit code */
    int32_t i32_char;
    int32_t i32_result;
    int32_t i32_exit;

/* start values */
    ps_out = NULL;
    ui32_index = 0;
    i32_char = 0;
/* no error */
    i32_result = 0;
    i32_exit = EXIT_OK;
/* the file's path */
    if (strcmp(argv[ARG_SAVE_DIR], "/") != SAME)
    {
        sprintf(ac_path, "/%s/%s.Z80", argv[ARG_SAVE_DIR], argv[ARG_SAVE_NAME]);
    }
    else
    {
        sprintf(ac_path, "/%s.Z80", argv[ARG_SAVE_NAME]);
    }
/* the file must be there */
    if (!open_path(ac_path, &g_s_file))
    {
        printf("ERROR: saved file %s not found\n", ac_path);
        i32_exit = EXIT_ERRORS;
    }
    else
    {
/* a copy for z80ref.py */
        ps_out = fopen(argv[ARG_SAVE_OUT], "wb");
        i32_char = ff_getc(&g_s_file);
        while (i32_char >= 0)
        {
/* byte by byte */
            fputc(i32_char, ps_out);
            i32_char = ff_getc(&g_s_file);
        }
        fclose(ps_out);
/* its size */
        printf("file %s: %u bytes\n", ac_path, (unsigned)g_s_file.ui32_size);
/* a cleared machine, the file from its start */
        memset(g_aui8_mem, 0, sizeof g_aui8_mem);
        memset(g_aui32_regs, 0, sizeof g_aui32_regs);
        memset(g_aui8_ay, 0, sizeof g_aui8_ay);
/* AY select and the ports */
        g_ui8_ay_sel = 0;
        g_ui8_p7ffd = 0;
        g_ui8_border = 0;
/* running; the file is read again */
        g_ui8_halt = 0;
        ff_open(&g_s_file, g_s_file.ui32_first, g_s_file.ui32_size);
        i32_result = snap_load(&g_s_file);
/* it must load */
        if (i32_result != SNAP_OK)
        {
            printf("ERROR: load result %d\n", (int)i32_result);
            i32_exit = EXIT_ERRORS;
        }
    }
/* loaded */
    if (i32_exit == EXIT_OK)
    {
/* everything must be back */
        if (memcmp(g_aui8_mem, g_aui8_mem0, sizeof g_aui8_mem0) != SAME)
        {
            err("RAM differs after save + load");
        }
/* the registers, word by word when they differ */
        if (memcmp(g_aui32_regs, g_aui32_regs0, sizeof g_aui32_regs) != SAME)
        {
            for (ui32_index = 0; ui32_index < REG_WORDS; ui32_index++)
            {
                printf("  word %u: %08x / %08x\n", (unsigned)ui32_index, (unsigned)g_aui32_regs[ui32_index],
                       (unsigned)g_aui32_regs0[ui32_index]);
            }
/* the AY, the ports */
            err("registers differ after save + load");
        }
        check_ay("AY differs");
        if ((g_ui8_ay_sel != g_ui8_sel0) || (g_ui8_p7ffd != g_ui8_p7ffd0) || (g_ui8_border != g_ui8_border0))
        {
/* an error; then the exit code */
            err("ports differ after save + load");
        }
        i32_exit = exit_code();
    }
    return i32_exit;
}

/* "save": a machine state saved as a snapshot, the machine unchanged, then save_reload */
static int32_t run_save(char **argv)
{
/* local variables */
    char ac_name11[FAT_NAME11_LEN];
    uint32_t ui32_dir;
    uint32_t ui32_size;
/* a counter, the program counter */
    uint32_t ui32_index;
    uint32_t ui32_pc;
/* the save's result, the exit code */
    int32_t i32_result;
    int32_t i32_exit;

/* start values */
    ui32_dir = 0;
    ui32_size = 0;
    ui32_index = 0;
/* no error */
    ui32_pc = 0;
    i32_result = 0;
    i32_exit = EXIT_OK;
/* the machine from the seed; the folder */
    make_state((uint32_t)atoi(argv[ARG_SAVE_SEED]));
    if ((strcmp(argv[ARG_SAVE_DIR], "/") != SAME) && !find(0, argv[ARG_SAVE_DIR], true, &ui32_dir, &ui32_size))
    {
/* no such folder */
        printf("ERROR: folder\n");
        i32_exit = EXIT_ERRORS;
    }
    else
    {
/* expected state: as saved, PC one back in HALT */
        ui32_pc = g_aui32_regs[REG_PC] & LOW16_MASK;
        memcpy(g_aui32_regs0, g_aui32_regs, sizeof g_aui32_regs);
/* in HALT the PC saved is one back */
        if (g_ui8_halt != 0)
        {
            g_aui32_regs0[REG_PC] = (g_aui32_regs0[REG_PC] & HIGH16_MASK) | ((ui32_pc - ONE) & LOW16_MASK);
        }
/* memory and AY as they are */
        memcpy(g_aui8_mem0, g_aui8_mem, sizeof g_aui8_mem0);
        memcpy(g_aui8_ay0, g_aui8_ay, sizeof g_aui8_ay0);
/* AY select and the ports */
        g_ui8_sel0 = g_ui8_ay_sel;
        g_ui8_p7ffd0 = g_ui8_p7ffd;
        g_ui8_border0 = g_ui8_border;
/* dumped with the expected registers, then the CPU's own PC again */
        memcpy(g_aui32_regs, g_aui32_regs0, sizeof g_aui32_regs);
        dump(argv[ARG_SAVE_EXPECTED]);
        g_aui32_regs[REG_PC] = (g_aui32_regs[REG_PC] & HIGH16_MASK) | ui32_pc;
/* the file's 8.3 name */
        for (ui32_index = 0; ui32_index < NAME8_LEN; ui32_index++)
        {
            ac_name11[ui32_index] = ' ';
/* the name's characters */
            if (ui32_index < strlen(argv[ARG_SAVE_NAME]))
            {
                ac_name11[ui32_index] = argv[ARG_SAVE_NAME][ui32_index];
            }
        }
/* the extension */
        ac_name11[EXT_0] = 'Z';
        ac_name11[EXT_1] = '8';
        ac_name11[EXT_2] = '0';
/* the CPU must stop */
        if (snap_freeze() != SNAP_OK)
        {
            printf("ERROR: freeze\n");
            i32_exit = EXIT_ERRORS;
        }
    }
/* stopped */
    if (i32_exit == EXIT_OK)
    {
/* stopped: the AY must be silent */
        snap_capture();
        if ((g_aui8_ay[AY_VOL_A] != 0) || (g_aui8_ay[AY_VOL_B] != 0) || (g_aui8_ay[AY_VOL_C] != 0))
        {
            err("AY not muted while stopped");
        }
/* saved; the machine runs again */
        i32_result = snap_save(ui32_dir, ac_name11);
        snap_resume();
        printf("save result %d\n", (int)i32_result);
/* saved, running again, nothing changed */
        if (i32_result != FAT_OK)
        {
            err("save");
        }
/* the CPU */
        if (g_b_frozen)
        {
            err("left frozen");
        }
        check_ay("AY not restored");
/* the AY's select */
        if ((g_ui8_ay_sel != g_ui8_sel0) || (g_ui8_ay_addr != (g_ui8_sel0 & AY_ADDR_MASK)))
        {
            err("AY select not restored");
        }
/* memory and ports */
        if ((memcmp(g_aui8_mem, g_aui8_mem0, sizeof g_aui8_mem0) != SAME) || (g_ui8_p7ffd != g_ui8_p7ffd0) ||
            (g_ui8_border != g_ui8_border0))
        {
            err("machine changed by saving");
        }
/* the second half */
        i32_exit = save_reload(argv);
    }
    return i32_exit;
}

/* the colour (0..15) the screenshot must have at one pixel */
static int32_t pixel_expected(int32_t i32_x, int32_t i32_y, uint32_t ui32_base)
{
/* local variables */
    uint32_t ui32_line;
    uint8_t ui8_attr;
    int32_t i32_sx;
/* the Spectrum's row, the colour, the pixel's bit */
    int32_t i32_sy;
    int32_t i32_colour;
    bool b_on;

/* start values */
    ui32_line = 0;
    ui8_attr = 0;
    i32_sx = i32_x - SCREEN_LEFT;
/* the border colour unless the pixel is inside */
    i32_sy = i32_y - SCREEN_TOP;
    i32_colour = g_ui8_border;
    b_on = false;
/* inside the screen? */
    if ((i32_y >= SCREEN_TOP) && (i32_y < SCREEN_BOTTOM) && (i32_x >= SCREEN_LEFT) && (i32_x < SCREEN_RIGHT))
    {
/* inside the screen: the pixel's line, its attribute, its bit */
        ui32_line = (uint32_t)(((i32_sy >> THIRD_SHIFT) * THIRD_BYTES) + ((i32_sy & CELL_MASK) * LINE_BYTES) +
                               (((i32_sy >> ROW_SHIFT) & CELL_MASK) * COLUMNS));
        ui8_attr = g_aui8_mem[ui32_base + ATTR_OFFSET + (uint32_t)(((i32_sy / CELL) * COLUMNS) + (i32_sx / CELL))];
        b_on = (g_aui8_mem[ui32_base + ui32_line + (uint32_t)(i32_sx / CELL)] & (PIXEL_TOP_BIT >> (i32_sx % CELL))) != 0;
/* ink or paper, with the bright bit */
        if (b_on)
        {
            i32_colour = ui8_attr % COLOURS;
        }
        else
        {
            i32_colour = (ui8_attr / COLOURS) % COLOURS;
        }
/* bright */
        if ((ui8_attr & ATTR_BRIGHT) != 0)
        {
            i32_colour += BRIGHT_ADD;
        }
    }
    return i32_colour;
}

/* the screenshot read back: its size, its header, every pixel */
static void check_bmp(uint32_t ui32_count)
{
/* local variables */
    uint32_t ui32_base;
    int32_t i32_x;
    int32_t i32_y;
/* the colour wanted, the colour found */
    int32_t i32_want;
    int32_t i32_got;

/* start values */
    ui32_base = SCREEN_PAGE_NORMAL * PAGE_SIZE;
    i32_x = 0;
    i32_y = 0;
/* nothing compared yet */
    i32_want = 0;
    i32_got = 0;
/* the file's size */
    if (ui32_count != (BMP_HEADER + (BMP_ROW_BYTES * BMP_HEIGHT)))
    {
        err("BMP size");
    }
/* the header's bytes */
    if ((g_aui8_bmp[0] != 'B') || (g_aui8_bmp[HDR_M] != 'M') || (g_aui8_bmp[HDR_OFFSET] != BMP_HEADER) ||
        (g_aui8_bmp[HDR_WIDTH_LOW] != WIDTH_LOW) || (g_aui8_bmp[HDR_WIDTH_HIGH] != WIDTH_HIGH) ||
        (g_aui8_bmp[HDR_HEIGHT] != BMP_HEIGHT) || (g_aui8_bmp[HDR_BPP] != BMP_BPP))
    {
        err("BMP header");
    }
/* the screen shown: page 7 with 7FFD bit 3 */
    if ((g_ui8_p7ffd & P7FFD_SCREEN) != 0)
    {
        ui32_base = SCREEN_PAGE_SHADOW * PAGE_SIZE;
    }
/* pixel by pixel */
    for (i32_y = 0; i32_y < BMP_HEIGHT; i32_y++)
    {
        for (i32_x = 0; i32_x < BMP_WIDTH; i32_x++)
        {
            i32_want = pixel_expected(i32_x, i32_y, ui32_base);
/* the file has the bottom row first, two pixels per byte */
            i32_got = g_aui8_bmp[BMP_HEADER + ((BMP_LAST_ROW - i32_y) * BMP_ROW_BYTES) + (i32_x / PIXELS_PER_BYTE)];
            if ((i32_x % PIXELS_PER_BYTE) != 0)
            {
                i32_got = i32_got & NIBBLE_MASK;
            }
            else
            {
/* the left pixel is in the high half */
                i32_got = i32_got >> NIBBLE_SHIFT;
            }
/* a wrong pixel: the first few are listed */
            if (i32_got != i32_want)
            {
                if (g_i32_errors < PIXEL_ERRORS_SHOWN)
                {
                    printf("  pixel %d,%d: %d, expected %d\n", (int)i32_x, (int)i32_y, (int)i32_got, (int)i32_want);
                }
/* all are counted */
                g_i32_errors++;
            }
        }
    }
}

/* "shot": two screenshots of a random screen, the second one checked */
static int32_t run_shot(char **argv)
{
/* local variables */
    char ac_name11[FAT_NAME11_LEN];
    char ac_want[WANT_LEN];
    FILE *ps_out;
/* counters */
    uint32_t ui32_index;
    uint32_t ui32_count;
    int32_t i32_shot;
/* results, a byte, the exit code */
    int32_t i32_result;
    int32_t i32_char;
    int32_t i32_exit;

/* start values */
    ps_out = NULL;
    ui32_index = 0;
    ui32_count = 0;
/* the first screenshot */
    i32_shot = ONE;
    i32_result = 0;
/* nothing read, no error */
    i32_char = 0;
    i32_exit = EXIT_OK;
/* a random machine */
    for (ui32_index = 0; ui32_index < sizeof g_aui8_mem; ui32_index++)
    {
        g_aui8_mem[ui32_index] = (uint8_t)next();
    }
/* the screen shown, the border */
    g_ui8_p7ffd = (uint8_t)atoi(argv[ARG_SHOT_7FFD]);
    g_ui8_border = SHOT_BORDER;
    while ((i32_exit == EXIT_OK) && (i32_shot <= SHOT_COUNT))
    {
/* the next free name must be SCRN0001, then SCRN0002 */
        if (shot_name(0, ac_name11) != 0)
        {
            err("shot_name");
            i32_exit = EXIT_ERRORS;
        }
        else
        {
/* the name it must be */
            sprintf(ac_want, "SCRN%04dBMP", (int)i32_shot);
            if (memcmp(ac_name11, ac_want, FAT_NAME11_LEN) != SAME)
            {
                err("screenshot name");
            }
/* the screenshot */
            i32_result = snap_screenshot(0, ac_name11);
            if (i32_result != SNAP_OK)
            {
                printf("ERROR: screenshot result %d\n", (int)i32_result);
/* an error; the CPU must run again */
                i32_exit = EXIT_ERRORS;
            }
            else if (g_b_frozen)
            {
                err("left frozen");
            }
            else
            {
/* taken, the machine runs */
            }
        }
        i32_shot++;
    }
/* the second screenshot must be on the card */
    if ((i32_exit == EXIT_OK) && !open_path("/SCRN0002.BMP", &g_s_file))
    {
        printf("ERROR: SCRN0002.BMP not found\n");
        i32_exit = EXIT_ERRORS;
    }
/* found */
    if (i32_exit == EXIT_OK)
    {
/* the second file read back */
        i32_char = ff_getc(&g_s_file);
        while ((i32_char >= 0) && (ui32_count < sizeof g_aui8_bmp))
        {
            g_aui8_bmp[ui32_count] = (uint8_t)i32_char;
/* next byte */
            ui32_count++;
            i32_char = ff_getc(&g_s_file);
        }
/* a copy for fatcheck.py */
        ps_out = fopen(argv[ARG_SHOT_OUT], "wb");
        fwrite(g_aui8_bmp, ONE, ui32_count, ps_out);
        fclose(ps_out);
/* its size; then every pixel */
        printf("SCRN0002.BMP: %u bytes\n", (unsigned)ui32_count);
        check_bmp(ui32_count);
        i32_exit = exit_code();
    }
/* the exit code */
    return i32_exit;
}

int main(int argc, char **argv)
{
/* the exit code */
    int32_t i32_exit;

    i32_exit = EXIT_OK;
    if (argc < ARGS_MIN)
    {
/* too few arguments */
        fprintf(stderr, "usage: see snap_test.c\n");
        i32_exit = EXIT_USAGE;
    }
    else
    {
/* the card image, mounted */
        g_ps_img = fopen(argv[ARG_IMAGE], "r+b");
        if ((g_ps_img == NULL) || (fat_mount() != FAT_OK))
        {
/* no image, or no file system */
            printf("ERROR: mount\n");
            i32_exit = EXIT_ERRORS;
        }
/* the three modes */
        else if (strcmp(argv[ARG_MODE], "load") == SAME)
        {
            i32_exit = run_load(argv);
        }
        else if (strcmp(argv[ARG_MODE], "save") == SAME)
        {
/* save, shot */
            i32_exit = run_save(argv);
        }
        else if (strcmp(argv[ARG_MODE], "shot") == SAME)
        {
            i32_exit = run_shot(argv);
        }
        else
        {
/* no such mode */
            fprintf(stderr, "unknown mode\n");
            i32_exit = EXIT_USAGE;
        }
    }
    return i32_exit;
}
