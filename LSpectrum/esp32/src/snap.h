/* snap.h -- .z80 snapshots: saving the running Spectrum, loading a file into it */
#ifndef SNAP_H
#define SNAP_H

#include <stdint.h>
#include "fat.h"

#define SNAP_ERUN  -10      /* the Spectrum CPU did not stop (not running: ROMs loading, reset) */
#define SNAP_EBAD  -11      /* not a .z80 file this machine can load */

/* Saving: snap_freeze, snap_capture (state read, AY muted), then snap_save any number
 * of times (or not at all), then snap_resume (AY back, CPU runs on). */
int  snap_freeze(void);                                     /* 0 = ok, SNAP_ERUN */
void snap_capture(void);
int  snap_save(uint32_t dir, const char name11[11]);        /* new file dir/name11; FAT_* */
void snap_resume(void);

/* Loading: checks the whole file first (nothing changes if it is bad), then stops
 * the CPU, loads memory, AY, ports and registers, and starts the CPU at the
 * snapshot's PC. 0 = ok, SNAP_EBAD, SNAP_ERUN, FAT_EIO. */
int  snap_load(FFILE *f);

/* Screenshot: the screen shown and the border as a 320 x 240 BMP (shot.c) in dir/name11;
 * the Spectrum stops for a moment. 0 = ok, SNAP_ERUN, FAT_* */
int  snap_screenshot(uint32_t dir, const char name11[11]);

#endif
