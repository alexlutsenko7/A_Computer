/* shot.h -- screenshots: 16-colour BMP files (Print Screen, all machines; LTari: 256 colours) */
#ifndef SHOT_H
#define SHOT_H

#include <stdint.h>
#include "fat.h"

/* first free SCRNnnnn.BMP in dir -> name11; 0 = ok, FAT_EFULL (all 9999 taken), FAT_EIO */
int shot_name(uint32_t dir, char name11[11]);

/* a new BMP file dir/name11, w x h pixels, 4 bits per pixel, palette pal[16] = {r, g, b};
 * then exactly h calls of shot_row (BOTTOM row first, w colour indices 0..15 (0..255) each),
 * then shot_end. FAT_* codes; after an error the file is deleted. */
int shot_begin(uint32_t dir, const char name11[11], int w, int h, const uint8_t pal[16][3]);
/* the same with 8 bits per pixel, palette pal[256] (LTari) */
int shot_begin8(uint32_t dir, const char name11[11], int w, int h, const uint8_t pal[256][3]);
int shot_row(const uint8_t *px);
int shot_end(void);

#endif
