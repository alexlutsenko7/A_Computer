/* shot.h -- screenshots: 16-colour BMP files (Print Screen, all machines; LTari: 256 colours) */
#ifndef SHOT_H
#define SHOT_H

/* the headers this one needs */
#include <stdint.h>
#include "fat.h"

/* characters of a short file name: 8 of the name and 3 of the extension, no dot */
#define SHOT_NAME11_LEN 11
/* palette sizes of the two picture formats */
#define SHOT_COLOURS_4BPP 16
#define SHOT_COLOURS_8BPP 256
/* bytes of one palette entry in the caller's table: red, green, blue */
#define SHOT_RGB_LEN 3

/* first free SCRNnnnn.BMP in the folder -> ac_name11 */
/* FAT_OK, FAT_EFULL (all 9999 taken), FAT_EIO */
int32_t shot_name(uint32_t ui32_dir, char ac_name11[SHOT_NAME11_LEN]);

/* a new BMP file in the folder, i32_width x i32_height pixels, 4 bits per pixel, */
/* palette aui8_pal[16] = {r, g, b}; then exactly i32_height calls of shot_row (BOTTOM row */
/* first, i32_width colour indices 0..15 (0..255) each), then shot_end. */
/* FAT_* codes; after an error the file is deleted. */
int32_t shot_begin(uint32_t ui32_dir, const char ac_name11[SHOT_NAME11_LEN], int32_t i32_width, int32_t i32_height,
                   const uint8_t aui8_pal[SHOT_COLOURS_4BPP][SHOT_RGB_LEN]);
/* the same with 8 bits per pixel, palette aui8_pal[256] (LTari) */
int32_t shot_begin8(uint32_t ui32_dir, const char ac_name11[SHOT_NAME11_LEN], int32_t i32_width, int32_t i32_height,
                    const uint8_t aui8_pal[SHOT_COLOURS_8BPP][SHOT_RGB_LEN]);
/* one row of pixels, as colour indices */
int32_t shot_row(const uint8_t *pui8_pixels);
/* close the file, or delete it after an error */
int32_t shot_end(void);

#endif
