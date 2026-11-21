/* nextshot.cpp -- LNext: Print Screen. */
/* */
/* The Next's picture is mixed from its layers on the way to the monitor and stored nowhere, */
/* so it is taken from the video output's line buffer (LNext/10cl025/rtl/next_grab.v and */
/* next_video.v), one line at a time: the FPGA is told a line's number, holds that line in */
/* the buffer when it has gone by, and the pixels are read with memory read commands (bursts */
/* on the link). The CPU waits meanwhile, so all lines belong to one picture, and the monitor */
/* shows black. A line takes a few milliseconds, in which the picture goes on by several dozen */
/* lines: the next line taken is therefore the first missing one that the picture has not */
/* reached yet (worked out from the time the reading took), several per frame. */
/* */
/* A pixel is 9 bits (3 per colour) at 14 MHz, the Next's finest pixel. Pictures of the usual */
/* 7 MHz pixels have every pixel twice: those are written with half the width; the others */
/* with every line twice, so that both kinds keep their shape. The picture is kept in the */
/* PSRAM until the machine runs again, then written as a 24-bit BMP file (shot.cpp). */
/* Not right in the picture: what changes by itself while the lines are taken (flashing */
/* characters may come out in stripes). */
#include <stdlib.h>
#include "hw.h"
#include "hal.h"
/* this module's header, the BMP writer */
#include "nextshot.h"
#include "shot.h"
#include "util.h"

/* yes */
#define YES 1
/* memory commands (next_grab.v): read, the grabber's order, its state */
#define C_MRD 1u
#define C_GRAB 3u
#define C_STATE 4u
/* where a command's number is in SNAPCMD */
#define CMD_SHIFT 28
/* GRAB: the CPU waits and the monitor is black; hold the line of this number */
#define G_ON 0x8000u
#define G_ARM 0x4000u
/* STATE: the line is held, it lies in the vertical blanking; the fields' width and places */
#define S_HELD 0x80000000u
#define S_VBL 0x40000000u
#define S_FIELD_MASK 0x3FFu
#define S_END_SHIFT 10
#define S_LINES_SHIFT 20
/* a pixel's address: the grabber's space, two bytes per pixel, the second one */
#define A_GRAB 0x20000u
#define A_PIXEL_SHIFT 1
#define A_HIGH 1u
/* a pixel: the second byte's place, its bit */
#define PX_HIGH_SHIFT 8
#define PX_HIGH_MASK 1u
/* what a picture may be: lines of a frame, pixels of a line */
#define LINES_MIN 200
#define LINES_MAX 400
#define WIDTH_MIN 256
#define WIDTH_MAX 1000
/* a line's time in the loader's clock (912 pixels of 14 MHz at 56 MHz), and how many lines */
/* ahead of where the picture is now the next line is asked for */
#define LINE_TICKS 3648u
#define LINES_AHEAD 6
/* a line's kind: of the vertical blanking, of the picture, not taken yet */
#define KIND_TODO 2
/* a line must be held within this time (a frame takes 20 ms) */
#define HELD_MS 200u
/* bytes of a pixel in the picture's memory and in a BMP row */
#define PX_BYTES 2u
#define BMP_PX_BYTES 3u
/* a colour: 3 bits each, their places, 3 bits to 8 */
#define C3_MASK 7u
#define C3_RED_SHIFT 6
#define C3_GREEN_SHIFT 3
#define C3_UP 5
#define C3_MID 2
#define C3_DOWN 1
/* a row's colours in order */
#define ROW_RED 0
#define ROW_GREEN 1
#define ROW_BLUE 2
/* the two pixels of a pair, the times a line is written */
#define PAIR 2
#define SECOND 1
#define TWICE 2
#ifdef NEXT_SHOT_DUMP
/* test option: the picture as taken goes to the console too, as lines of */
/* "D <line> <first pixel> <3 hexadecimal digits per pixel>" (DUMP_PIXELS pixels each) */
#define DUMP_PIXELS 32
#define DUMP_LINE_BUF 128
#define DUMP_DIGITS 3
#define DUMP_DIGIT_BITS 4
#define DUMP_DIGIT_MASK 15u
#endif

/* the last picture: lines, pixels of a line, the time the machine waited */
static int32_t g_i32_shot_lines;
static int32_t g_i32_shot_width;
static uint32_t g_ui32_shot_ms;

/* a memory command */
static uint32_t grab_cmd(uint32_t ui32_cmd, uint32_t ui32_addr, uint32_t ui32_data)
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

/* 3 bits of a colour as 8 */
static uint8_t c3_to_8(uint32_t ui32_c3)
{
/* local variables */
    uint32_t ui32_value;

    ui32_value = ui32_c3 & C3_MASK;
    ui32_value = (ui32_value << C3_UP) | (ui32_value << C3_MID) | (ui32_value >> C3_DOWN);
    return (uint8_t)ui32_value;
}

/* take one line: 1 = it is a picture line and its pixels are in pui16_row, 0 = a line of the */
/* vertical blanking, below 0 = the FPGA did not hold it */
/* *pui32_held: the time it was held */
static int32_t grab_line(int32_t i32_line, int32_t i32_first, int32_t i32_width, uint16_t *pui16_row, uint32_t *pui32_held)
{
/* local variables */
    uint32_t ui32_state;
    uint32_t ui32_start;
    uint32_t ui32_addr;
/* a pixel's two bytes, a counter, the result */
    uint32_t ui32_low;
    uint32_t ui32_high;
    int32_t i32_x;
    int32_t i32_result;

/* start values */
    ui32_state = 0;
    ui32_start = TIMER;
    ui32_addr = 0;
    ui32_low = 0;
    ui32_high = 0;
    i32_x = 0;
/* not held */
    i32_result = -YES;
/* the order lets the line before go; then the FPGA waits for this one */
    grab_cmd(C_GRAB, 0, G_ON | G_ARM | (uint32_t)i32_line);
    ui32_state = grab_cmd(C_STATE, 0, 0);
    while (((ui32_state & S_HELD) == 0) && ((TIMER - ui32_start) < (HELD_MS * CLK_PER_MS)))
    {
        ui32_state = grab_cmd(C_STATE, 0, 0);
    }
    *pui32_held = TIMER;
    if ((ui32_state & S_HELD) != 0)
    {
        i32_result = 0;
/* a picture line: its pixels, two bytes each */
        if ((ui32_state & S_VBL) == 0)
        {
            i32_result = YES;
            for (i32_x = 0; i32_x < i32_width; i32_x++)
            {
                ui32_addr = A_GRAB | ((uint32_t)(i32_first + i32_x) << A_PIXEL_SHIFT);
                ui32_low = grab_cmd(C_MRD, ui32_addr, 0);
                ui32_high = grab_cmd(C_MRD, ui32_addr | A_HIGH, 0);
/* 9 bits of colour */
                pui16_row[i32_x] = (uint16_t)(ui32_low | ((ui32_high & PX_HIGH_MASK) << PX_HIGH_SHIFT));
            }
        }
    }
    return i32_result;
}

/* 1 = every pixel of the picture is there twice (7 MHz pixels) */
static int32_t pairs_equal(const uint16_t *pui16_pic, const uint8_t *pui8_kind, int32_t i32_lines, int32_t i32_width)
{
/* local variables */
    const uint16_t *pui16_row;
    int32_t i32_y;
    int32_t i32_x;
    int32_t i32_result;

/* start values */
    pui16_row = pui16_pic;
    i32_y = 0;
    i32_x = 0;
/* an odd width has no pairs */
    i32_result = ((i32_width % PAIR) == 0) ? YES : 0;
    while ((i32_y < i32_lines) && (i32_result != 0))
    {
        if (pui8_kind[i32_y] != 0)
        {
            pui16_row = pui16_pic + ((uint32_t)i32_y * (uint32_t)i32_width);
            for (i32_x = 0; i32_x < i32_width; i32_x += PAIR)
            {
                if (pui16_row[i32_x] != pui16_row[i32_x + SECOND])
                {
                    i32_result = 0;
                }
            }
        }
        i32_y++;
    }
    return i32_result;
}

#ifdef NEXT_SHOT_DUMP
/* test option: the picture to the console */
static void dump(const uint16_t *pui16_pic, const uint8_t *pui8_kind, int32_t i32_lines, int32_t i32_width)
{
/* local variables */
    static const char ac_hex[] = "0123456789ABCDEF";
    char ac_line[DUMP_LINE_BUF];
    char *pc_end;
    int32_t i32_y;
    int32_t i32_x;
/* counters, a pixel */
    int32_t i32_n;
    int32_t i32_digit;
    uint32_t ui32_px;

/* start values */
    pc_end = ac_line;
    i32_x = 0;
    i32_n = 0;
    i32_digit = 0;
    ui32_px = 0;
    for (i32_y = 0; i32_y < i32_lines; i32_y++)
    {
        for (i32_x = 0; (i32_x < i32_width) && (pui8_kind[i32_y] != 0); i32_x += DUMP_PIXELS)
        {
            pc_end = u_strcpy(ac_line, "D ");
            pc_end = u_utoa(pc_end, (uint32_t)i32_y);
            pc_end = u_strcpy(pc_end, " ");
            pc_end = u_utoa(pc_end, (uint32_t)i32_x);
            pc_end = u_strcpy(pc_end, " ");
            for (i32_n = 0; (i32_n < DUMP_PIXELS) && ((i32_x + i32_n) < i32_width); i32_n++)
            {
                ui32_px = pui16_pic[((uint32_t)i32_y * (uint32_t)i32_width) + (uint32_t)(i32_x + i32_n)];
                for (i32_digit = DUMP_DIGITS - YES; i32_digit >= 0; i32_digit--)
                {
                    *pc_end = ac_hex[(ui32_px >> (i32_digit * DUMP_DIGIT_BITS)) & DUMP_DIGIT_MASK];
                    pc_end++;
                }
            }
            *pc_end = 0;
            log_line(ac_line);
        }
/* a register read per line: the loader is seen to be alive (esp_hw.cpp's watch) */
        ui32_px = KEYS;
    }
    log_line("D end");
}
#endif

/* the picture into the file: FAT_* codes */
static int32_t write_file(uint32_t ui32_dir, const char ac_name11[FAT_NAME11_LEN], const uint16_t *pui16_pic,
                          const uint8_t *pui8_kind, int32_t i32_lines, int32_t i32_width, uint8_t *pui8_bmp_row)
{
/* local variables */
    const uint16_t *pui16_row;
    int32_t i32_rows;
    int32_t i32_step;
    int32_t i32_times;
/* counters, the file's size in pixels */
    int32_t i32_y;
    int32_t i32_x;
    int32_t i32_n;
    int32_t i32_out;
/* a pixel, the results */
    uint32_t ui32_px;
    int32_t i32_result;
    int32_t i32_end;

/* start values */
    pui16_row = pui16_pic;
    i32_rows = 0;
/* pixels in pairs: every second one, a line once; else every pixel, a line twice */
    i32_step = PAIR;
    i32_times = YES;
    if (pairs_equal(pui16_pic, pui8_kind, i32_lines, i32_width) == 0)
    {
        i32_step = YES;
        i32_times = TWICE;
    }
    i32_x = 0;
    i32_n = 0;
    i32_out = 0;
    ui32_px = 0;
    i32_end = FAT_OK;
/* the picture's lines */
    for (i32_y = 0; i32_y < i32_lines; i32_y++)
    {
        if (pui8_kind[i32_y] != 0)
        {
            i32_rows++;
        }
    }
    i32_result = shot_begin24(ui32_dir, ac_name11, i32_width / i32_step, i32_rows * i32_times);
/* a BMP file has its bottom row first */
    i32_y = i32_lines - YES;
    while ((i32_y >= 0) && (i32_result == FAT_OK))
    {
        if (pui8_kind[i32_y] != 0)
        {
            pui16_row = pui16_pic + ((uint32_t)i32_y * (uint32_t)i32_width);
            i32_out = 0;
            for (i32_x = 0; i32_x < i32_width; i32_x += i32_step)
            {
                ui32_px = pui16_row[i32_x];
/* red, green, blue */
                pui8_bmp_row[i32_out + ROW_RED] = c3_to_8(ui32_px >> C3_RED_SHIFT);
                pui8_bmp_row[i32_out + ROW_GREEN] = c3_to_8(ui32_px >> C3_GREEN_SHIFT);
                pui8_bmp_row[i32_out + ROW_BLUE] = c3_to_8(ui32_px);
                i32_out += (int32_t)BMP_PX_BYTES;
            }
            for (i32_n = 0; (i32_n < i32_times) && (i32_result == FAT_OK); i32_n++)
            {
                i32_result = shot_row(pui8_bmp_row);
            }
        }
        i32_y--;
    }
/* the file is closed, or deleted after an error */
    i32_end = shot_end();
    if (i32_result == FAT_OK)
    {
        i32_result = i32_end;
    }
    return i32_result;
}

/* Print Screen: the Next's picture into a new file */
int32_t next_screenshot(uint32_t ui32_dir, const char ac_name11[FAT_NAME11_LEN])
{
/* local variables */
    uint32_t ui32_state;
    uint32_t ui32_start;
    int32_t i32_first;
    int32_t i32_width;
/* the frame's lines, counters, a line's kind */
    int32_t i32_lines;
    int32_t i32_left;
    int32_t i32_y;
    int32_t i32_kind;
/* when the line was held */
    uint32_t ui32_held;
/* the memory: the picture, a kind per line (1 = picture), a BMP row */
    uint8_t *pui8_mem;
    uint16_t *pui16_pic;
    uint8_t *pui8_kind;
    uint8_t *pui8_bmp_row;
/* its size, the result */
    uint32_t ui32_pic_bytes;
    int32_t i32_result;

/* start values */
    ui32_start = TIMER;
    i32_left = 0;
    i32_y = 0;
    i32_kind = 0;
    ui32_held = 0;
    pui8_mem = NULL;
    pui16_pic = NULL;
    pui8_kind = NULL;
    pui8_bmp_row = NULL;
    ui32_pic_bytes = 0;
    i32_result = NEXT_ESHOT;
/* the machine stops and says where its picture is in a line and how many lines a frame has */
    ui32_state = grab_cmd(C_GRAB, 0, G_ON);
    i32_first = (int32_t)(ui32_state & S_FIELD_MASK);
    i32_width = (int32_t)((ui32_state >> S_END_SHIFT) & S_FIELD_MASK) - i32_first;
    i32_lines = (int32_t)((ui32_state >> S_LINES_SHIFT) & S_FIELD_MASK);
/* a machine without the grabber answers 0 */
    if ((i32_width >= WIDTH_MIN) && (i32_width <= WIDTH_MAX) && (i32_lines >= LINES_MIN) && (i32_lines <= LINES_MAX))
    {
        ui32_pic_bytes = (uint32_t)i32_lines * (uint32_t)i32_width * PX_BYTES;
        pui8_mem = (uint8_t *)ext_alloc(ui32_pic_bytes + (uint32_t)i32_lines + ((uint32_t)i32_width * BMP_PX_BYTES));
    }
    if (pui8_mem != NULL)
    {
        pui16_pic = (uint16_t *)pui8_mem;
        pui8_kind = pui8_mem + ui32_pic_bytes;
        pui8_bmp_row = pui8_kind + i32_lines;
        i32_result = FAT_OK;
/* no line is taken yet */
        u_memset(pui8_kind, KIND_TODO, (uint32_t)i32_lines);
        i32_left = i32_lines;
        while ((i32_left > 0) && (i32_result == FAT_OK))
        {
            i32_kind = grab_line(i32_y, i32_first, i32_width, pui16_pic + ((uint32_t)i32_y * (uint32_t)i32_width), &ui32_held);
            if (i32_kind < 0)
            {
                i32_result = NEXT_ESHOT;
            }
            else
            {
                pui8_kind[i32_y] = (uint8_t)i32_kind;
                i32_left--;
            }
/* the next one: where the picture is by now, a few lines on, then the first missing line */
            if ((i32_left > 0) && (i32_result == FAT_OK))
            {
                i32_y = (i32_y + LINES_AHEAD + (int32_t)((TIMER - ui32_held) / LINE_TICKS)) % i32_lines;
                while (pui8_kind[i32_y] != KIND_TODO)
                {
                    i32_y = (i32_y + YES) % i32_lines;
                }
            }
        }
    }
/* the machine runs again */
    grab_cmd(C_GRAB, 0, 0);
    g_i32_shot_lines = i32_lines;
    g_i32_shot_width = i32_width;
    g_ui32_shot_ms = (TIMER - ui32_start) / CLK_PER_MS;
/* the file */
    if (pui8_mem != NULL)
    {
#ifdef NEXT_SHOT_DUMP
        if (i32_result == FAT_OK)
        {
            dump(pui16_pic, pui8_kind, i32_lines, i32_width);
        }
#endif
        if (i32_result == FAT_OK)
        {
            i32_result = write_file(ui32_dir, ac_name11, pui16_pic, pui8_kind, i32_lines, i32_width, pui8_bmp_row);
        }
        free(pui8_mem);
    }
    return i32_result;
}

/* what the last picture was */
void next_shot_info(int32_t *pi32_lines, int32_t *pi32_width, uint32_t *pui32_ms)
{
    *pi32_lines = g_i32_shot_lines;
    *pi32_width = g_i32_shot_width;
    *pui32_ms = g_ui32_shot_ms;
}
