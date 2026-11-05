/* osd.h -- 32 x 24 text overlay on the Spectrum picture */
#ifndef OSD_H
#define OSD_H

#define OSD_COLS 32
#define OSD_ROWS 24

void osd_clear(void);
/* text at (row, col), padded with spaces to `width` columns; inverse video if inv */
void osd_text(int row, int col, const char *s, int width, int inv);
void osd_show(int full);    /* full screen (keyboard goes to the OSD) or bottom row only */
void osd_hide(void);

#endif
