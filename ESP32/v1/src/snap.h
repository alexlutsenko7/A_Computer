/* snap.h -- .z80 snapshots: saving the running Spectrum, loading a file into it */
#ifndef SNAP_H
#define SNAP_H

/* the headers this one needs */
#include <stdint.h>
#include "fat.h"

/* everything went well */
#define SNAP_OK 0
/* the Spectrum CPU did not stop (not running: ROMs loading, reset) */
#define SNAP_ERUN (-10)
/* not a .z80 file this machine can load */
#define SNAP_EBAD (-11)

/* Saving: snap_freeze, snap_capture (state read, AY muted), then snap_save any number */
/* of times (or not at all), then snap_resume (AY back, CPU runs on). */
/* stop the CPU between two instructions: SNAP_OK, SNAP_ERUN */
int32_t snap_freeze(void);
/* read the CPU's state into the header buffer and mute the AY */
void snap_capture(void);
/* write the captured state and the memory as a new file in a folder; FAT_* */
int32_t snap_save(uint32_t ui32_dir, const char ac_name11[FAT_NAME11_LEN]);
/* AY back, the CPU runs on */
void snap_resume(void);

/* Loading: checks the whole file first (nothing changes if it is bad), then stops */
/* the CPU, loads memory, AY, ports and registers, and starts the CPU at the */
/* snapshot's PC. SNAP_OK, SNAP_EBAD, SNAP_ERUN, FAT_EIO. */
int32_t snap_load(FFILE *ps_file);

/* Screenshot: the screen shown and the border as a 320 x 240 BMP (shot.c) in a folder; */
/* the Spectrum stops for a moment. SNAP_OK, SNAP_ERUN, FAT_* */
int32_t snap_screenshot(uint32_t ui32_dir, const char ac_name11[FAT_NAME11_LEN]);

#endif
