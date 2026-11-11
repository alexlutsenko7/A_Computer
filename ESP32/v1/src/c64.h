/* c64.h -- L64 (Commodore 64 core): ROM install, .prg / .t64 loading, C64 .tap playback */
#ifndef C64_H
#define C64_H

/* the headers this one needs */
#include <stdint.h>
#include "fat.h"

/* everything went well */
#define C64_OK 0
/* not a usable file */
#define C64_EBAD (-20)
/* the C64 CPU did not stop (ROMs missing, reset) */
#define C64_ERUN (-21)
/* no ROM files on the card */
#define C64_ENOROM (-22)
/* flash verify failed */
#define C64_EFLASH (-23)
/* c64_rom_present: no image, an image, an image with the 1541 ROM */
#define C64_ROM_NONE 0
#define C64_ROM_PRESENT 1
#define C64_ROM_WITH_1541 2
/* yes, for the functions that answer a question */
#define C64_YES 1

/* ROM image in flash (0x580000, rtl/c64_system.v): C64_ROM_NONE / C64_ROM_PRESENT / C64_ROM_WITH_1541 */
int32_t c64_rom_present(void);
/* C64_YES = /ROMS/C64/ on the card has all ROMs, the 1541 one too */
int32_t c64_rom_card_1541(void);
/* Install /ROMS/C64/ KERNAL*, BASIC*, CHAR* (8 / 8 / 4 KB) into flash, then reload the C64. */
/* pf_progress(text) is called with short status lines. C64_OK, C64_E*, FAT_EIO. */
int32_t c64_rom_install(void (*pf_progress)(const char *pc_text));

/* Load a .prg (i32_t64 = 0) or the first file of a .t64 (i32_t64 = 1) into the running C64. */
/* A BASIC program (loaded at $0801) is started with RUN. pc_info gets "$0801-$1234". */
int32_t c64_prg_load(FFILE *ps_file, int32_t i32_t64, char *pc_info);

/* C64 .tap (C64-TAPE-RAW, version 0 / 1) -> pulse player commands (tape.h TS_* codes) */
void c64tap_start(FFILE *ps_file);
int32_t c64tap_pump(void);

/* C64 .tap recording (version 1) from the cassette write line: everything the C64 */
/* saves goes into one file until c64rec_end. Same use as save.h. */
int32_t c64rec_start(uint32_t ui32_dir, const char ac_name11[FAT_NAME11_LEN]);
void c64rec_service(void);
void c64rec_end(void);
/* is a recording open, and its status line */
int32_t c64rec_active(void);
int32_t c64rec_status(char *pc_text);

/* .d64 in the 1541 (device 8): mount checks the file and types LOAD"*",8,1; */
/* service (main loop) loads the track under the head and writes changed sectors back. */
/* i32_ro: the file is read-only */
int32_t c64_d64_mount(const FFILE *ps_file, const char *pc_name, int32_t i32_ro);
void c64_d64_service(void);
void c64_d64_eject(void);
/* "Disk: NAME" into pc_text while a disk is in: C64_YES, else 0 */
int32_t c64_d64_status(char *pc_text);

/* F6 (the speed mode): MCTL[2] lets the FPGA run turbo while the cassette or the 1541 motor runs */
void c64_speed(void);

/* Snapshots (.A64): freeze (C64_OK or C64_ERUN), capture, save any number of times, resume; */
/* load checks the file, then restores the machine and runs it (C64_OK, C64_EBAD, C64_ERUN, FAT_EIO). */
int32_t c64_snap_freeze(void);
void c64_snap_capture(void);
int32_t c64_snap_save(uint32_t ui32_dir, const char ac_name11[FAT_NAME11_LEN]);
/* running again, and the way back: a file into the machine */
void c64_snap_resume(void);
int32_t c64_snap_load(FFILE *ps_file);

/* Screenshot: the picture (the frame buffer's newest frame, 400 x 284) as a BMP (shot.c) in */
/* a folder; the C64 runs on. C64_OK, FAT_* */
int32_t c64_screenshot(uint32_t ui32_dir, const char ac_name11[FAT_NAME11_LEN]);

#endif
