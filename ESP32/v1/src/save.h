/* save.h -- recording the Spectrum's SAVE output (MIC) into a TAP file */
#ifndef SAVE_H
#define SAVE_H

/* the headers this one needs */
#include <stdint.h>
#include "fat.h"

/* rec_active / rec_status: yes */
#define REC_YES 1

/* 1 = load and save at normal speed (F6), 0 = turbo (default) */
extern int32_t g_i32_slow_mode;

/* start recording mode into a new file in a folder (8.3 name, space padded): FAT_OK, else FAT_* error */
int32_t rec_start(uint32_t ui32_dir, const char ac_name11[FAT_NAME11_LEN]);
/* call often while recording: decodes MIC edges, appends blocks */
void rec_service(void);
/* stop recording mode and close the file (an empty file is removed) */
void rec_end(void);
/* REC_YES = recording mode is on */
int32_t rec_active(void);
/* the speed mode changed: a block being saved changes speed at once */
void rec_speed(void);
/* status for the bottom row into pc_text; 0 = nothing to show */
int32_t rec_status(char *pc_text);

#endif
