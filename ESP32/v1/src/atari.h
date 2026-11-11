/* atari.h -- LTari (Atari 800XL / 130XE core): the SIO disk drive D1: for .atr images */
#ifndef ATARI_H
#define ATARI_H

/* the headers this one needs */
#include <stdint.h>
#include "fat.h"

/* everything went well */
#define AT_OK 0
/* not a usable .atr / .xex / .car */
#define AT_EBAD (-30)
/* a cartridge type not supported (yet) */
#define AT_ETYPE (-31)
/* the Atari does not stop (not running) */
#define AT_ERUN (-32)
/* snapshot of the other model (800 / 130) */
#define AT_EMODEL (-33)
/* snapshot needs a cartridge that is not in */
#define AT_ECART (-34)
/* at_status: a disk is in */
#define AT_DISK_IN 1

/* Insert an .atr into D1: (i32_ro: read only, e.g. the file's read-only attribute). i32_boot = 1: */
/* cold-start the Atari (cartridge out), so the OS boots from it, with BASIC if i32_basic, else with */
/* OPTION held until the first SIO command; i32_boot = 0: only change the disk (a program asking for */
/* the next disk), the Atari runs on. AT_OK, AT_EBAD, FAT_EIO. */
int32_t at_atr_mount(const FFILE *ps_file, const char *pc_name, int32_t i32_ro, int32_t i32_boot, int32_t i32_basic);
/* Run an .xex: served as a read-only boot disk (our loader + the file), Atari cold-started. */
/* AT_OK, AT_EBAD (no $FFFF header), FAT_EIO. */
int32_t at_xex_mount(const FFILE *ps_file, const char *pc_name);
/* Insert a .car cartridge (types 1 / 2: standard 8 / 16 KB; 41: Atarimax 128 KB; 42 / 75: Atarimax */
/* 1 MB, old / new) and cold-start into it; an .atr or .xex takes it out again. */
/* AT_OK, AT_EBAD, AT_ETYPE, FAT_EIO. */
int32_t at_car_mount(const FFILE *ps_file, const char *pc_name);
/* take the disk out */
void at_atr_eject(void);
/* main loop: answers the Atari's SIO commands for D1: (status, read, write / put, format) */
void at_service(void);
/* "D1: NAME" into pc_text while a disk is in: AT_DISK_IN, else 0 */
int32_t at_status(char *pc_text);
/* Print Screen: the picture (376 x 240, the frame buffer's newest frame) as a 256-colour BMP in */
/* a folder; the Atari runs on. AT_OK, FAT_* */
int32_t at_screenshot(uint32_t ui32_dir, const char ac_name11[FAT_NAME11_LEN]);

/* Snapshots (.A8S): freeze (AT_OK or AT_ERUN), capture, save any number of times, resume. */
/* Load: AT_OK, AT_EBAD, AT_EMODEL, AT_ECART (pc_name = the cartridge to load first), AT_ERUN, */
/* FAT_EIO; on success pc_name = the disk the program had in D1: if a different one is in now */
/* (else ""). */
int32_t at_snap_freeze(void);
void at_snap_capture(void);
int32_t at_snap_save(uint32_t ui32_dir, const char ac_name11[FAT_NAME11_LEN]);
/* running again, and the way back: a file into the machine */
void at_snap_resume(void);
int32_t at_snap_load(FFILE *ps_file, char *pc_name);

#endif
