/* c64.h -- L64 (Commodore 64 core): ROM install, .prg / .t64 loading, C64 .tap playback */
#ifndef C64_H
#define C64_H

#include <stdint.h>
#include "fat.h"

#define C64_EBAD   -20      /* not a usable file */
#define C64_ERUN   -21      /* the C64 CPU did not stop (ROMs missing, reset) */
#define C64_ENOROM -22      /* no ROM files on the card */
#define C64_EFLASH -23      /* flash verify failed */

/* ROM image in flash (0x200000, rtl/c64_system.v): 1 = present */
int  c64_rom_present(void);        /* 2 = with the 1541 ROM */
int  c64_rom_card_1541(void);      /* 1 = /ROMS/C64/ on the card has all ROMs, the 1541 one too */
/* Install /ROMS/C64/ KERNAL*, BASIC*, CHAR* (8 / 8 / 4 KB) into flash, then reload the C64.
 * progress(text) is called with short status lines. 0 = ok, C64_E*, FAT_EIO. */
int  c64_rom_install(void (*progress)(const char *));

/* Load a .prg (t64 = 0) or the first file of a .t64 (t64 = 1) into the running C64.
 * A BASIC program (loaded at $0801) is started with RUN. info gets "$0801-$1234". */
int  c64_prg_load(FFILE *f, int t64, char *info);

/* C64 .tap (C64-TAPE-RAW, version 0 / 1) -> pulse player commands (tape.h TS_* codes) */
void c64tap_start(FFILE *f);
int  c64tap_pump(void);

/* C64 .tap recording (version 1) from the cassette write line: everything the C64
 * saves goes into one file until c64rec_end. Same use as save.h. */
int  c64rec_start(uint32_t dir, const char name11[11]);
void c64rec_service(void);
void c64rec_end(void);
int  c64rec_active(void);
int  c64rec_status(char *s);

/* .d64 in the 1541 (device 8): mount checks the file and types LOAD"*",8,1;
 * service (main loop) loads the track under the head and writes changed sectors back. */
int  c64_d64_mount(const FFILE *f, const char *name, int ro);   /* ro: the file is read-only */
void c64_d64_service(void);
void c64_d64_eject(void);
int  c64_d64_status(char *s);      /* "Disk: NAME" while a disk is in */

/* F6 (slow_mode): MCTL[2] lets the FPGA run turbo while the cassette or the 1541 motor runs */
void c64_speed(void);

/* Snapshots (.A64): freeze (0 or C64_ERUN), capture, save any number of times, resume;
 * load checks the file, then restores the machine and runs it (0, C64_EBAD, C64_ERUN, FAT_EIO). */
int  c64_snap_freeze(void);
void c64_snap_capture(void);
int  c64_snap_save(uint32_t dir, const char name11[11]);
void c64_snap_resume(void);
int  c64_snap_load(FFILE *f);

/* Screenshot: the picture (the frame buffer's newest frame, 400 x 284) as a BMP (shot.c) in
 * dir/name11; the C64 runs on. 0 = ok, FAT_* */
int  c64_screenshot(uint32_t dir, const char name11[11]);

#endif
