/* nextshot.h -- LNext: Print Screen, the Spectrum Next's picture as a BMP file */
#ifndef NEXTSHOT_H
#define NEXTSHOT_H

/* the headers this one needs */
#include <stdint.h>
#include "fat.h"

/* next_screenshot: the machine gave no picture (an older machine file without the grabber, */
/* or no memory for the picture) */
#define NEXT_ESHOT (-61)

/* The picture on the Next's video output into a new 24-bit BMP file of the folder. The CPU */
/* waits and the monitor shows black while the picture is taken (one to two seconds); the */
/* file is written after the machine runs again. FAT_OK, NEXT_ESHOT, FAT_* codes. */
int32_t next_screenshot(uint32_t ui32_dir, const char ac_name11[FAT_NAME11_LEN]);
/* what the last picture was: lines and pixels taken, milliseconds the machine waited */
void next_shot_info(int32_t *pi32_lines, int32_t *pi32_width, uint32_t *pui32_ms);

#endif
