/* osd.h -- 32 x 24 text overlay on the Spectrum picture */
#ifndef OSD_H
#define OSD_H

#include <stdint.h>

/* the overlay's size in characters */
#define OSD_COLS 32
#define OSD_ROWS 24

/* all rows empty */
void osd_clear(void);
/* text at (row, column), padded with spaces to a width in columns; inverse video if i32_inverse */
void osd_text(int32_t i32_row, int32_t i32_col, const char *pc_text, int32_t i32_width, int32_t i32_inverse);
/* full screen (keyboard goes to the OSD) or bottom row only */
void osd_show(int32_t i32_full);
/* the overlay off */
void osd_hide(void);

#endif
