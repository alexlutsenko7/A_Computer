/* atari.h -- LTari (Atari 800XL / 130XE core): the SIO disk drive D1: for .atr images */
#ifndef ATARI_H
#define ATARI_H

#include <stdint.h>
#include "fat.h"

#define AT_EBAD   -30       /* not a usable .atr / .xex / .car */
#define AT_ETYPE  -31       /* a cartridge type not supported (yet) */
#define AT_ERUN   -32       /* the Atari does not stop (not running) */
#define AT_EMODEL -33       /* snapshot of the other model (800 / 130) */
#define AT_ECART  -34       /* snapshot needs a cartridge that is not in */

/* Insert an .atr into D1: (ro: read only, e.g. the file's read-only attribute). boot = 1: cold-start
 * the Atari (cartridge out), so the OS boots from it; boot = 0: only change the disk (a program asking
 * for the next disk), the Atari runs on. 0, AT_EBAD, FAT_EIO. */
int  at_atr_mount(const FFILE *f, const char *name, int ro, int boot);
/* Run an .xex: served as a read-only boot disk (our loader + the file), Atari cold-started.
 * 0, AT_EBAD (no $FFFF header), FAT_EIO. */
int  at_xex_mount(const FFILE *f, const char *name);
/* Insert a .car cartridge (types 1 / 2: standard 8 / 16 KB; 41: Atarimax 128 KB; 42 / 75: Atarimax 1 MB,
 * old / new) and cold-start into it; an .atr or .xex takes it out again. 0, AT_EBAD, AT_ETYPE, FAT_EIO. */
int  at_car_mount(const FFILE *f, const char *name);
void at_atr_eject(void);
/* main loop: answers the Atari's SIO commands for D1: (status, read, write / put, format) */
void at_service(void);
int  at_status(char *s);   /* "D1: NAME" while a disk is in */
/* Print Screen: the picture (376 x 240, the frame buffer's newest frame) as a 256-colour BMP in
 * dir/name11; the Atari runs on. 0 = ok, FAT_* */
int  at_screenshot(uint32_t dir, const char name11[11]);

/* Snapshots (.A8S): freeze (0 or AT_ERUN), capture, save any number of times, resume.
 * Load: 0, AT_EBAD, AT_EMODEL, AT_ECART (name[] = the cartridge to load first), AT_ERUN, FAT_EIO;
 * on success name[] = the disk the program had in D1: if a different one is in now (else ""). */
int  at_snap_freeze(void);
void at_snap_capture(void);
int  at_snap_save(uint32_t dir, const char name11[11]);
void at_snap_resume(void);
int  at_snap_load(FFILE *f, char *name);

#endif
