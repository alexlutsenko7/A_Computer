/* shot.c -- screenshots as 16-colour BMP files (Windows bitmap, 4 bits per pixel, */
/* uncompressed, bottom-up rows): every PC viewer opens them, and the machines' 16 */
/* colours are stored exactly. LTari's 256 colours: 8 bits per pixel. The file goes */
/* through fat.c's file writer (g_s_fw_file). */
#include "shot.h"
#include "util.h"

/* bits per pixel of the two formats */
#define BPP_4 4
#define BPP_8 8
/* one nibble: a pixel of the 4-bit format */
#define NIBBLE_MASK 15
#define NIBBLE_SHIFT 4
/* pixels in one byte of the 4-bit format */
#define PIXELS_PER_BYTE_4BPP 2
/* next pixel of a pair */
#define NEXT_PIXEL 1
/* rows are padded to a multiple of 4 bytes */
#define ROW_ALIGN_ADD 3u
#define ROW_ALIGN_MASK (~3u)
/* rounding up when two pixels share a byte */
#define ROUND_UP_HALF 1u
/* the BMP file: sizes of the two headers and of one palette entry */
#define BMP_FILE_HEADER_LEN 14u
#define BMP_INFO_HEADER_LEN 40u
#define BMP_PALETTE_ENTRY_LEN 4u
/* the BMP file: one colour plane, 72 dots per inch in pixels per metre */
#define BMP_PLANES 1u
#define BMP_PIXELS_PER_METRE 2835u
/* the caller's palette entries: red, green, blue */
#define RGB_RED 0
#define RGB_GREEN 1
#define RGB_BLUE 2
/* little-endian output of 16 and 32 bits */
#define SHIFT_BYTE 8
#define SHIFT_WORD 16
#define WORD_MASK 0xFFFFu
/* file names SCRN0001.BMP to SCRN9999.BMP */
#define SHOT_NUMBER_FIRST 1
#define SHOT_NUMBER_END 10000
/* places of the four digits in the name, and their decimal weights */
#define NAME_DIGIT_THOUSANDS 4
#define NAME_DIGIT_HUNDREDS 5
/* the last two */
#define NAME_DIGIT_TENS 6
#define NAME_DIGIT_ONES 7
/* the weights */
#define THOUSAND 1000
#define HUNDRED 100
#define TEN 10

/* width of the picture in pixels */
static int32_t g_i32_width;
/* first error of the file being written, FAT_OK if none */
static int32_t g_i32_error;
/* bits per pixel of the file being written */
static int32_t g_i32_bpp;
/* bytes of one stored row, with its padding */
static uint32_t g_ui32_row_bytes;

/* one byte to the file; after an error nothing more is written */
static void put(uint8_t ui8_byte)
{
    int32_t i32_result;

    i32_result = FAT_OK;
/* only while everything went well */
    if (g_i32_error == FAT_OK)
    {
        i32_result = fw_putc(&g_s_fw_file, ui8_byte);
/* remember the first error */
        if (i32_result != FAT_OK)
        {
            g_i32_error = i32_result;
        }
    }
}

/* 16 bits, low byte first */
static void put16(uint32_t ui32_value)
{
    put((uint8_t)ui32_value);
    put((uint8_t)(ui32_value >> SHIFT_BYTE));
}

/* 32 bits, low byte first */
static void put32(uint32_t ui32_value)
{
    put16(ui32_value & WORD_MASK);
    put16(ui32_value >> SHIFT_WORD);
}

/* first free SCRNnnnn.BMP in the folder: FAT_OK, FAT_EFULL (all taken), FAT_EIO */
int32_t shot_name(uint32_t ui32_dir, char ac_name11[SHOT_NAME11_LEN])
{
/* local variables */
    int32_t i32_number;
    int32_t i32_exists;
/* the result, and the end of the search */
    int32_t i32_result;
    bool b_done;

/* start values */
    i32_number = SHOT_NUMBER_FIRST;
    i32_exists = 0;
/* full, unless a free number is found */
    i32_result = FAT_EFULL;
    b_done = false;
/* try the numbers in order */
    while ((i32_number < SHOT_NUMBER_END) && !b_done)
    {
        u_memcpy(ac_name11, "SCRN0000BMP", SHOT_NAME11_LEN);
/* the number as four digits */
        ac_name11[NAME_DIGIT_THOUSANDS] = (char)('0' + (i32_number / THOUSAND));
        ac_name11[NAME_DIGIT_HUNDREDS] = (char)('0' + ((i32_number / HUNDRED) % TEN));
/* tens and ones */
        ac_name11[NAME_DIGIT_TENS] = (char)('0' + ((i32_number / TEN) % TEN));
        ac_name11[NAME_DIGIT_ONES] = (char)('0' + (i32_number % TEN));
/* 0 = no such file, below 0 = the card failed */
        i32_exists = fat_exists(ui32_dir, ac_name11);
        if (i32_exists == 0)
        {
/* a free name */
            i32_result = FAT_OK;
            b_done = true;
        }
/* the card failed */
        else if (i32_exists < 0)
        {
/* the card could not be read */
            i32_result = FAT_EIO;
            b_done = true;
        }
        else
        {
/* taken: the next number */
            i32_number++;
        }
    }
    return i32_result;
}

/* create the file and write its headers and palette */
static int32_t begin(uint32_t ui32_dir, const char ac_name11[SHOT_NAME11_LEN], int32_t i32_width, int32_t i32_height,
                     const uint8_t (*paui8_pal)[SHOT_RGB_LEN], int32_t i32_bpp)
{
/* local variables */
    uint32_t ui32_data_len;
    uint32_t ui32_colours;
    uint32_t ui32_row_pixels_bytes;
/* the headers' length, a loop counter, the result */
    uint32_t ui32_headers_len;
    int32_t i32_index;
    int32_t i32_result;

/* start values */
    ui32_data_len = 0;
/* the palette's size and the bytes one row's pixels take follow from the format */
    ui32_colours = SHOT_COLOURS_4BPP;
    ui32_row_pixels_bytes = ((uint32_t)i32_width + ROUND_UP_HALF) / PIXELS_PER_BYTE_4BPP;
/* 8 bits per pixel: 256 colours, one byte each */
    if (i32_bpp == BPP_8)
    {
        ui32_colours = SHOT_COLOURS_8BPP;
        ui32_row_pixels_bytes = (uint32_t)i32_width;
    }
/* both headers and the palette come before the pixels */
    ui32_headers_len = BMP_FILE_HEADER_LEN + BMP_INFO_HEADER_LEN + (BMP_PALETTE_ENTRY_LEN * ui32_colours);
    i32_index = 0;
    i32_result = fw_create(&g_s_fw_file, ui32_dir, ac_name11);
/* nothing is written if the file could not be created */
    if (i32_result == FAT_OK)
    {
        g_i32_error = FAT_OK;
        g_i32_width = i32_width;
/* what shot_row needs to know */
        g_i32_bpp = i32_bpp;
/* rows padded to 4 bytes */
        g_ui32_row_bytes = (ui32_row_pixels_bytes + ROW_ALIGN_ADD) & ROW_ALIGN_MASK;
        ui32_data_len = g_ui32_row_bytes * (uint32_t)i32_height;
/* file header: signature, file size, reserved, offset of the pixels */
        put('B');
        put('M');
        put32(ui32_headers_len + ui32_data_len);
/* reserved, then where the pixels start */
        put32(0);
        put32(ui32_headers_len);
/* BITMAPINFOHEADER: its size, width, height, planes, bits per pixel */
        put32(BMP_INFO_HEADER_LEN);
        put32((uint32_t)i32_width);
        put32((uint32_t)i32_height);
/* one plane, 4 or 8 bits per pixel */
        put16(BMP_PLANES);
        put16((uint32_t)i32_bpp);
/* not compressed (BI_RGB), size of the pixels, 72 dpi both ways, colours used and important */
        put32(0);
        put32(ui32_data_len);
/* 72 dpi both ways */
        put32(BMP_PIXELS_PER_METRE);
        put32(BMP_PIXELS_PER_METRE);
/* every colour used, every colour important */
        put32(ui32_colours);
        put32(ui32_colours);
/* the palette: blue, green, red, 0 */
        for (i32_index = 0; i32_index < (int32_t)ui32_colours; i32_index++)
        {
            put(paui8_pal[i32_index][RGB_BLUE]);
            put(paui8_pal[i32_index][RGB_GREEN]);
/* red, then the unused byte */
            put(paui8_pal[i32_index][RGB_RED]);
            put(0);
        }
/* an error of any byte above */
        i32_result = g_i32_error;
    }
    return i32_result;
}

/* a new file with 4 bits per pixel */
int32_t shot_begin(uint32_t ui32_dir, const char ac_name11[SHOT_NAME11_LEN], int32_t i32_width, int32_t i32_height,
                   const uint8_t aui8_pal[SHOT_COLOURS_4BPP][SHOT_RGB_LEN])
{
/* local variables */
    int32_t i32_result;

    i32_result = begin(ui32_dir, ac_name11, i32_width, i32_height, aui8_pal, BPP_4);
    return i32_result;
}

/* a new file with 8 bits per pixel */
int32_t shot_begin8(uint32_t ui32_dir, const char ac_name11[SHOT_NAME11_LEN], int32_t i32_width, int32_t i32_height,
                    const uint8_t aui8_pal[SHOT_COLOURS_8BPP][SHOT_RGB_LEN])
{
/* local variables */
    int32_t i32_result;

    i32_result = begin(ui32_dir, ac_name11, i32_width, i32_height, aui8_pal, BPP_8);
    return i32_result;
}

/* one row of pixels (colour indices), padded to the stored row length */
int32_t shot_row(const uint8_t *pui8_pixels)
{
/* local variables */
    uint32_t ui32_written;
    int32_t i32_x;
    uint8_t ui8_right;

/* start values */
    ui32_written = 0;
    i32_x = 0;
    ui8_right = 0;
/* one byte per pixel, or two pixels per byte */
    if (g_i32_bpp == BPP_8)
    {
        for (i32_x = 0; i32_x < g_i32_width; i32_x++)
        {
            put(pui8_pixels[i32_x]);
        }
/* bytes written so far */
        ui32_written = (uint32_t)g_i32_width;
    }
    else
    {
/* left pixel in the high nibble */
        for (i32_x = 0; i32_x < g_i32_width; i32_x += PIXELS_PER_BYTE_4BPP)
        {
/* an odd width has no right pixel in its last byte */
            ui8_right = 0;
            if ((i32_x + NEXT_PIXEL) < g_i32_width)
            {
                ui8_right = (uint8_t)(pui8_pixels[i32_x + NEXT_PIXEL] & NIBBLE_MASK);
            }
/* the left pixel in the high half */
            put((uint8_t)(((pui8_pixels[i32_x] & NIBBLE_MASK) << NIBBLE_SHIFT) | ui8_right));
        }
        ui32_written = ((uint32_t)g_i32_width + ROUND_UP_HALF) / PIXELS_PER_BYTE_4BPP;
    }
/* the padding */
    while (ui32_written < g_ui32_row_bytes)
    {
        put(0);
        ui32_written++;
    }
/* FAT_OK, or the first error of the picture */
    return g_i32_error;
}

/* close the file; after an error it is deleted and the error returned */
int32_t shot_end(void)
{
    int32_t i32_result;

    i32_result = g_i32_error;
/* a failed picture leaves no file */
    if (g_i32_error != FAT_OK)
    {
        fw_discard(&g_s_fw_file);
    }
    else
    {
/* complete: the directory entry is written */
        i32_result = fw_close(&g_s_fw_file);
    }
    return i32_result;
}

/* back to the state after a start: the next machine starts the loader again without an ESP32 */
/* restart (esp_hw.cpp; the Bluetooth connection stays) */
void shot_reset(void)
{
    g_i32_width = 0;
    g_i32_error = 0;
/* no file is being written */
    g_i32_bpp = 0;
    g_ui32_row_bytes = 0;
}
