/* nextshot_test.cpp -- PC test of LNext's Print Screen (nextshot.cpp, with shot.cpp and fat.cpp) */
/* */
/* The FPGA is a model of the screenshot grabber as the firmware sees it (LNext/10cl025/rtl/ */
/* next_grab.v): the GRAB and STATE commands and the pixel reads. Its picture is made up: a */
/* frame of 311 lines, 303 of them picture, 720 pixels wide from pixel 100 of a line; a pixel's */
/* colour follows from its place. The model holds a line only after a few STATE readings, and */
/* counts as errors: a pixel read while no line is held or outside the picture, a line taken */
/* twice, a machine that is not let go at the end. */
/* Two pictures are taken onto a card image (the argument; FAT32, made by run_host_test.sh): */
/*   every pixel twice (the usual 7 MHz pixels): the file must be 360 x 303 */
/*   single pixels (14 MHz): the file must be 720 x 606, every line twice */
/* and the files are read back from the card: the BMP header, and every pixel against the */
/* picture. A model without a grabber (an older machine file) must give NEXT_ESHOT and no file. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
/* the registers and the platform */
#include "../../../ESP32/v2/src/hw.h"
#include "../../../ESP32/v2/src/hal.h"
/* the code under test, the card's files */
#include "../../../ESP32/v2/src/nextshot.h"
#include "../../../ESP32/v2/src/fat.h"

/* hw.h: main is the ESP32 loader task */
#undef main

/* yes */
#define YES 1
/* a sector's bytes */
#define SECTOR 512u
/* registers (rtl/tape_loader.v) */
#define R_TIMER 0x18
#define R_SNAPCMD 0x30
#define R_SNAPDAT 0x34
/* a memory command: its number's place, the address, the commands */
#define CMD_SHIFT 28
#define ADDR_MASK 0x3FFFFu
#define C_MRD 1u
#define C_GRAB 3u
#define C_STATE 4u
/* GRAB's bits and STATE's */
#define G_ON 0x8000u
#define G_ARM 0x4000u
#define G_LINE_MASK 0x3FFu
#define S_HELD 0x80000000u
#define S_VBL 0x40000000u
#define S_END_SHIFT 10
#define S_LINES_SHIFT 20
/* a pixel read: the grabber's space, the pixel's place, the colour's second byte */
#define A_GRAB 0x20000u
#define A_PIXEL_SHIFT 1
#define A_PIXEL_MASK 0x3FFu
#define A_HIGH 1u
#define PX_LOW_MASK 0xFFu
#define PX_HIGH_SHIFT 8
/* the made-up picture: a frame's lines, the picture's first line and the first one after it, */
/* its first pixel in a line and the first one after it */
#define FRAME_LINES 311
#define PIC_FIRST_LINE 7
#define PIC_END_LINE 310
#define PIC_FIRST_PIXEL 100
#define PIC_END_PIXEL 820
#define PIC_WIDTH 720
#define PIC_ROWS 303
/* its colours: 9 bits; factors of the place */
#define COLOUR_MASK 0x1FFu
#define COLOUR_X 5u
#define COLOUR_Y 3u
/* STATE readings before a line is held; the clock's step per reading */
#define HOLD_POLLS 3
#define TIMER_STEP 5000u
/* the BMP file: header fields, bytes per pixel, the row's padding */
#define BMP_HEADER 54u
#define BMP_SIZE_OFF 2
#define BMP_WIDTH_OFF 18
#define BMP_HEIGHT_OFF 22
#define BMP_BPP_OFF 28
#define BMP_BPP 24u
#define BMP_PX 3u
#define ROW_ALIGN 3u
/* colours in a BMP pixel */
#define BMP_BLUE 0
#define BMP_GREEN 1
#define BMP_RED 2
/* 3 bits of a colour: mask, places, as 8 bits */
#define C3_MASK 7u
#define C3_RED_SHIFT 6
#define C3_GREEN_SHIFT 3
#define C3_UP 5
#define C3_MID 2
#define C3_DOWN 1
/* numbers: bytes, shifts */
#define BYTE_1 1
#define BYTE_2 2
#define BYTE_3 3
#define SHIFT_8 8
#define SHIFT_16 16
#define SHIFT_24 24
/* the largest card image, the program's arguments */
#define IMAGE_MAX_SECTORS 262144u
#define ARG_IMAGE 1
#define ARGS 2
/* the pictures' kinds, lines written twice */
#define KIND_PAIRS 0
#define KIND_SINGLE 1
#define TWICE 2
#define PAIR 2

/* hw.h: the machine on the link */
int32_t g_i32_machine_c64;
int32_t g_i32_machine_atari;
int32_t g_i32_machine_nes;
int32_t g_i32_machine_md;
int32_t g_i32_machine_next;
int32_t g_i32_machine_menu;
int32_t g_i32_menu_positions;
/* the card */
static uint8_t *g_pui8_card;
static uint32_t g_ui32_card_sectors;
/* the model: data register, the clock, there is a grabber, the picture's kind */
static uint32_t g_ui32_dat;
static uint32_t g_ui32_timer;
static int32_t g_i32_grabber;
static int32_t g_i32_kind;
/* the grabber: on, a line is waited for / held, its number, readings until it is held */
static int32_t g_i32_on;
static int32_t g_i32_armed;
static int32_t g_i32_held;
static int32_t g_i32_line;
static int32_t g_i32_polls;
/* how often each line was taken */
static uint8_t g_aui8_taken[FRAME_LINES];
/* a file found on the card */
static uint32_t g_ui32_found_clus;
static uint32_t g_ui32_found_size;
static FFILE g_s_file;
/* errors found */
static int32_t g_i32_errors;

/* an error is counted and said */
static void error(const char *pc_text, uint32_t ui32_value)
{
    printf("ERROR: %s (%lu)\n", pc_text, (unsigned long)ui32_value);
    g_i32_errors++;
}

/* the picture: the colour of pixel i32_x (counted from the picture's first) of line i32_line */
static uint32_t colour(int32_t i32_line, int32_t i32_x)
{
/* local variables */
    uint32_t ui32_x;

    ui32_x = (uint32_t)i32_x;
/* 7 MHz pixels: two of the same */
    if (g_i32_kind == KIND_PAIRS)
    {
        ui32_x = ui32_x / PAIR;
    }
    return ((ui32_x * COLOUR_X) + ((uint32_t)i32_line * COLOUR_Y)) & COLOUR_MASK;
}

/* hal.h: the card */
int32_t sd_read(uint32_t ui32_lba, uint8_t *pui8_buf)
{
/* local variables */
    int32_t i32_result;

    i32_result = -YES;
    if (ui32_lba < g_ui32_card_sectors)
    {
        memcpy(pui8_buf, g_pui8_card + (ui32_lba * SECTOR), SECTOR);
        i32_result = 0;
    }
    return i32_result;
}

int32_t sd_write(uint32_t ui32_lba, const uint8_t *pui8_buf)
{
/* local variables */
    int32_t i32_result;

    i32_result = -YES;
    if (ui32_lba < g_ui32_card_sectors)
    {
        memcpy(g_pui8_card + (ui32_lba * SECTOR), pui8_buf, SECTOR);
        i32_result = 0;
    }
    return i32_result;
}

/* hw.h: the picture's memory, a line for the console */
void *ext_alloc(uint32_t ui32_size)
{
    return malloc(ui32_size);
}

void log_line(const char *pc_text)
{
    printf("  log: %s\n", pc_text);
}

/* hw.h: a register is read */
uint32_t hw_rd(uint8_t ui8_reg)
{
/* local variables */
    uint32_t ui32_value;

    ui32_value = 0;
    if (ui8_reg == R_TIMER)
    {
/* the clock goes on with every reading */
        g_ui32_timer += TIMER_STEP;
        ui32_value = g_ui32_timer;
    }
    else if (ui8_reg == R_SNAPDAT)
    {
        ui32_value = g_ui32_dat;
    }
    else
    {
/* SNAPCTL: never busy; nothing else is read */
    }
    return ui32_value;
}

/* the grabber's state word */
static uint32_t state(void)
{
/* local variables */
    uint32_t ui32_value;

    ui32_value = (uint32_t)PIC_FIRST_PIXEL | ((uint32_t)PIC_END_PIXEL << S_END_SHIFT) | ((uint32_t)FRAME_LINES << S_LINES_SHIFT);
    if (g_i32_held != 0)
    {
        ui32_value |= S_HELD;
/* a line outside the picture */
        if ((g_i32_line < PIC_FIRST_LINE) || (g_i32_line >= PIC_END_LINE))
        {
            ui32_value |= S_VBL;
        }
    }
    return ui32_value;
}

/* hw.h: a register is written */
void hw_wr(uint8_t ui8_reg, uint32_t ui32_value)
{
/* local variables */
    uint32_t ui32_cmd;
    uint32_t ui32_addr;
    int32_t i32_x;
    uint32_t ui32_px;

/* start values */
    ui32_cmd = ui32_value >> CMD_SHIFT;
    ui32_addr = ui32_value & ADDR_MASK;
    i32_x = 0;
    ui32_px = 0;
    if (ui8_reg == R_SNAPDAT)
    {
        g_ui32_dat = ui32_value;
    }
    else if ((ui8_reg == R_SNAPCMD) && (g_i32_grabber == 0))
    {
/* a machine without the grabber answers 0 to everything */
        g_ui32_dat = 0;
    }
    else if (ui8_reg == R_SNAPCMD)
    {
        if (ui32_cmd == C_GRAB)
        {
/* the line before is let go; a new one is waited for */
            g_i32_on = ((g_ui32_dat & G_ON) != 0) ? YES : 0;
            g_i32_armed = ((g_ui32_dat & G_ARM) != 0) ? YES : 0;
            g_i32_held = 0;
            g_i32_line = (int32_t)(g_ui32_dat & G_LINE_MASK);
            g_i32_polls = HOLD_POLLS;
            g_ui32_dat = state();
        }
        else if (ui32_cmd == C_STATE)
        {
/* the line goes by after a few readings */
            if (g_i32_armed != 0)
            {
                g_i32_polls--;
                if (g_i32_polls == 0)
                {
                    g_i32_armed = 0;
                    g_i32_held = YES;
                    if (g_i32_line < FRAME_LINES)
                    {
                        g_aui8_taken[g_i32_line]++;
                    }
                    else
                    {
                        error("a line outside the frame", (uint32_t)g_i32_line);
                    }
                }
            }
            g_ui32_dat = state();
        }
        else if ((ui32_cmd == C_MRD) && ((ui32_addr & A_GRAB) != 0))
        {
            i32_x = (int32_t)((ui32_addr >> A_PIXEL_SHIFT) & A_PIXEL_MASK);
            if ((g_i32_held == 0) || (g_i32_on == 0))
            {
                error("pixel read while no line is held", ui32_addr);
            }
/* the link reads ahead, but the firmware asks for the picture's pixels only */
            if ((i32_x < PIC_FIRST_PIXEL) || (i32_x >= PIC_END_PIXEL))
            {
                error("pixel read outside the picture", (uint32_t)i32_x);
            }
            ui32_px = colour(g_i32_line, i32_x - PIC_FIRST_PIXEL);
            g_ui32_dat = ((ui32_addr & A_HIGH) != 0) ? (ui32_px >> PX_HIGH_SHIFT) : (ui32_px & PX_LOW_MASK);
        }
        else
        {
            error("unexpected command", ui32_cmd);
        }
    }
    else
    {
/* nothing else is written */
    }
}

/* fat_list: the file of the name in p_ctx */
static int32_t find_cb(const DIRENT *ps_entry, void *p_ctx)
{
/* local variables */
    int32_t i32_stop;

    i32_stop = 0;
    if (memcmp(ps_entry->ac_sname, p_ctx, FAT_NAME11_LEN) == 0)
    {
        g_ui32_found_clus = ps_entry->ui32_clus;
        g_ui32_found_size = ps_entry->ui32_size;
        i32_stop = YES;
    }
    return i32_stop;
}

/* 3 bits of a colour as 8 */
static uint32_t c3_to_8(uint32_t ui32_c3)
{
/* local variables */
    uint32_t ui32_value;

    ui32_value = ui32_c3 & C3_MASK;
    return ((ui32_value << C3_UP) | (ui32_value << C3_MID) | (ui32_value >> C3_DOWN)) & PX_LOW_MASK;
}

/* a 32-bit number of the file's header */
static uint32_t rd32(const uint8_t *pui8_src)
{
    return (uint32_t)pui8_src[0] | ((uint32_t)pui8_src[BYTE_1] << SHIFT_8) | ((uint32_t)pui8_src[BYTE_2] << SHIFT_16) |
           ((uint32_t)pui8_src[BYTE_3] << SHIFT_24);
}

/* take a picture of a kind into the file and check the file */
static void test_picture(int32_t i32_kind, const char *pc_name11)
{
/* local variables */
    uint8_t aui8_header[BMP_HEADER];
    uint8_t aui8_px[BMP_PX];
    int32_t i32_result;
    int32_t i32_width;
/* the file's size in pixels, counters */
    int32_t i32_height;
    int32_t i32_step;
    int32_t i32_times;
    int32_t i32_row;
    int32_t i32_x;
    int32_t i32_line;
/* a pixel, bytes, bad pixels */
    uint32_t ui32_px;
    uint32_t ui32_index;
    uint32_t ui32_row_bytes;
    int32_t i32_bad;

/* start values */
    i32_step = (i32_kind == KIND_PAIRS) ? PAIR : YES;
    i32_times = (i32_kind == KIND_PAIRS) ? YES : TWICE;
    i32_width = PIC_WIDTH / i32_step;
    i32_height = PIC_ROWS * i32_times;
    i32_bad = 0;
    ui32_px = 0;
    ui32_row_bytes = (((uint32_t)i32_width * BMP_PX) + ROW_ALIGN) & ~ROW_ALIGN;
/* the picture */
    g_i32_kind = i32_kind;
    g_i32_grabber = YES;
    memset(g_aui8_taken, 0, sizeof g_aui8_taken);
    i32_result = next_screenshot(0, pc_name11);
    if (i32_result != FAT_OK)
    {
        error("next_screenshot failed", (uint32_t)(-i32_result));
    }
/* the machine runs again, every line was taken once */
    if ((g_i32_on != 0) || (g_i32_armed != 0))
    {
        error("the machine was not let go", 0);
    }
    for (i32_line = 0; i32_line < FRAME_LINES; i32_line++)
    {
        if (g_aui8_taken[i32_line] != YES)
        {
            error("a line was not taken exactly once", (uint32_t)i32_line);
            i32_line = FRAME_LINES;
        }
    }
/* the file */
    g_ui32_found_size = 0;
    fat_list(0, find_cb, (void *)pc_name11);
    if (g_ui32_found_size != (BMP_HEADER + (ui32_row_bytes * (uint32_t)i32_height)))
    {
        error("file size", g_ui32_found_size);
    }
    else
    {
        ff_open(&g_s_file, g_ui32_found_clus, g_ui32_found_size);
        for (ui32_index = 0; ui32_index < BMP_HEADER; ui32_index++)
        {
            aui8_header[ui32_index] = (uint8_t)ff_getc(&g_s_file);
        }
/* the header's fields */
        if ((aui8_header[0] != 'B') || (aui8_header[BYTE_1] != 'M') || (rd32(aui8_header + BMP_SIZE_OFF) != g_ui32_found_size) ||
            (rd32(aui8_header + BMP_WIDTH_OFF) != (uint32_t)i32_width) || (rd32(aui8_header + BMP_HEIGHT_OFF) != (uint32_t)i32_height) ||
            (aui8_header[BMP_BPP_OFF] != BMP_BPP))
        {
            error("BMP header", rd32(aui8_header + BMP_WIDTH_OFF));
        }
/* the rows, the bottom one first */
        for (i32_row = i32_height - YES; i32_row >= 0; i32_row--)
        {
            i32_line = PIC_FIRST_LINE + (i32_row / i32_times);
            for (i32_x = 0; i32_x < i32_width; i32_x++)
            {
                aui8_px[BMP_BLUE] = (uint8_t)ff_getc(&g_s_file);
                aui8_px[BMP_GREEN] = (uint8_t)ff_getc(&g_s_file);
                aui8_px[BMP_RED] = (uint8_t)ff_getc(&g_s_file);
                ui32_px = colour(i32_line, i32_x * i32_step);
                if ((aui8_px[BMP_RED] != c3_to_8(ui32_px >> C3_RED_SHIFT)) || (aui8_px[BMP_GREEN] != c3_to_8(ui32_px >> C3_GREEN_SHIFT)) ||
                    (aui8_px[BMP_BLUE] != c3_to_8(ui32_px)))
                {
                    i32_bad++;
                }
            }
/* the row's padding */
            for (ui32_index = (uint32_t)i32_width * BMP_PX; ui32_index < ui32_row_bytes; ui32_index++)
            {
                ff_getc(&g_s_file);
            }
        }
        if (i32_bad != 0)
        {
            error("wrong pixels in the file", (uint32_t)i32_bad);
        }
    }
    printf("  picture %d x %d: %s\n", i32_width, i32_height, (g_i32_errors == 0) ? "ok" : "errors");
}

int main(int argc, char **argv)
{
/* local variables */
    FILE *ps_image;
    int32_t i32_result;

/* start values */
    ps_image = NULL;
    i32_result = 0;
    if (argc >= ARGS)
    {
        ps_image = fopen(argv[ARG_IMAGE], "rb");
    }
    g_pui8_card = (uint8_t *)malloc(IMAGE_MAX_SECTORS * SECTOR);
    if ((ps_image == NULL) || (g_pui8_card == NULL))
    {
        error("no card image", 0);
    }
    else
    {
        g_ui32_card_sectors = (uint32_t)(fread(g_pui8_card, SECTOR, IMAGE_MAX_SECTORS, ps_image));
        fclose(ps_image);
        if (fat_mount() != FAT_OK)
        {
            error("the card image has no file system", 0);
        }
/* as the firmware does it for LNext */
        fat_alloc_high();
        test_picture(KIND_PAIRS, "SCRN0001BMP");
        test_picture(KIND_SINGLE, "SCRN0002BMP");
/* an older machine file: no picture, no file */
        g_i32_grabber = 0;
        i32_result = next_screenshot(0, "SCRN0003BMP");
        if ((i32_result != NEXT_ESHOT) || (fat_exists(0, "SCRN0003BMP") != 0))
        {
            error("a machine without the grabber gave a picture", (uint32_t)(-i32_result));
        }
        printf("  no grabber: %s\n", (i32_result == NEXT_ESHOT) ? "no picture, as it must be" : "wrong");
    }
    printf("RESULT: %s\n", (g_i32_errors == 0) ? "PASS" : "FAIL");
    return (g_i32_errors == 0) ? 0 : YES;
}
