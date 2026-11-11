/* tape.h -- TAP / TZX file -> pulse player commands */
#ifndef TAPE_H
#define TAPE_H

/* the headers this one needs */
#include <stdint.h>
#include "fat.h"

/* results of tape_pump */
/* generating */
#define TS_RUN 0
/* "stop the tape" block (TZX 0x20 with pause 0): wait for the user */
#define TS_STOP 1
/* end of the file */
#define TS_END 2
/* not a TZX file / read error */
#define TS_ERR 3

/* Start generating from a block (0 = start). i32_tzx: 1 = TZX, 0 = TAP. */
void tape_start(FFILE *ps_file, int32_t i32_tzx, uint32_t ui32_block);
/* Generate commands while the FIFO has room; returns TS_*. */
int32_t tape_pump(void);
/* After TS_STOP: go on with the next block. */
void tape_continue(void);
/* Index of the block being generated. */
uint32_t tape_block(void);

#endif
