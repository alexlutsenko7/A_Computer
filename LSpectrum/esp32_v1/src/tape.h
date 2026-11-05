/* tape.h -- TAP / TZX file -> pulse player commands */
#ifndef TAPE_H
#define TAPE_H

#include <stdint.h>
#include "fat.h"

#define TS_RUN   0      /* generating */
#define TS_STOP  1      /* "stop the tape" block (TZX 0x20 with pause 0): wait for the user */
#define TS_END   2      /* end of the file */
#define TS_ERR   3      /* not a TZX file / read error */

/* Start generating from block `block` (0 = start). tzx: 1 = TZX, 0 = TAP. */
void     tape_start(FFILE *f, int tzx, uint32_t block);
/* Generate commands while the FIFO has room; returns TS_*. */
int      tape_pump(void);
/* After TS_STOP: go on with the next block. */
void     tape_continue(void);
/* Index of the block being generated, and the number of the last block generated. */
uint32_t tape_block(void);

#endif
