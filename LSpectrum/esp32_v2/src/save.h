/* save.h -- recording the Spectrum's SAVE output (MIC) into a TAP file */
#ifndef SAVE_H
#define SAVE_H

#include <stdint.h>

/* start recording mode into a new file dir/name11 (8.3, space padded). 0 = ok, else FAT_* error */
int  rec_start(uint32_t dir, const char name11[11]);
/* call often while recording: decodes MIC edges, appends blocks */
void rec_service(void);
/* stop recording mode and close the file (an empty file is removed) */
void rec_end(void);
/* recording mode is on */
int  rec_active(void);
/* 1 = load and save at normal speed (F6), 0 = turbo (default) */
extern int slow_mode;
/* slow_mode changed: a block being saved changes speed at once */
void rec_speed(void);
/* status for the bottom row; 0 = nothing to show */
int  rec_status(char *s);

#endif
