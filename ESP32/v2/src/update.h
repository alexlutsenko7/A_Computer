/* update.h -- flash update from the SD card (LUPDATE.BIN in the root folder: the machine menu), run by */
/* the machine menu image (AMenu); and the machines: three positions of 2 MB in the flash, which machine */
/* is in which position, installing a machine file (an .LMC file of the folder MACHINES) into a position */
#ifndef UPDATE_H
#define UPDATE_H

/* the headers this one needs */
#include <stdint.h>
#include "fat.h"

/* everything went well */
#define UPD_OK 0
/* not a valid update file (header, size or checksum) */
#define UPD_EBAD (-40)
/* the flash did not take the data (erase / program / verify) */
#define UPD_EFLASH (-41)
/* upd_find: the file is there; upd_machines_present: at least one machine is installed */
#define UPD_FOUND 1
#define UPD_PRESENT 1
/* the file's 8.3 name as stored */
#define UPD_NAME11 "LUPDATE BIN"
/* bytes that upd_slot_bytes reads */
#define UPD_SLOT_BYTES 4
/* the machine file is made for the other core board */
#define MCH_EBOARD (-42)
/* positions of the flash that hold a machine (2 MB each: bitstream, then the ROM area) */
#define MCH_POSITIONS 3
/* mch_find: no position holds that machine */
#define MCH_NONE (-1)
/* mch_position: a machine is installed there */
#define MCH_PRESENT 1
/* a machine's menu line, and the line with its terminator */
#define MCH_LINE_LEN 29
#define MCH_LINE_BUF 30
/* machine files that the list holds */
#define MCH_FILES_MAX 12
/* the machine byte of a ROM area's tag (A5 5A byte ~byte): LSpectrum, L64, LTari */
#define MCH_BYTE_ZX 0x18
#define MCH_BYTE_C64 0x24
#define MCH_BYTE_ATARI 0x42
/* the ROM image inside a ROM area (the first sector is the info sector) */
#define MCH_ROM_OFFSET 0x1000u

/* a machine file on the card */
typedef struct
{
/* the file */
    DIRENT s_entry;
/* its menu line */
    char ac_line[MCH_LINE_BUF];
} MCH_FILE;

/* LUPDATE.BIN in the root folder: UPD_FOUND (entry filled), 0 = none, below 0 = card error */
int32_t upd_find(DIRENT *ps_entry);
/* the update's label (after upd_check: "L 2026-10-30 ...") */
const char *upd_label(void);
/* check the file: header, size, CRC-32 of the whole image. UPD_OK, UPD_EBAD, FAT_EIO */
int32_t upd_check(const DIRENT *ps_entry, void (*pf_progress)(uint32_t ui32_done, uint32_t ui32_total));
/* write the sectors that differ (the menu's last, the C64 ROM area never), verify, delete the */
/* file. *pi32_menu_changed = 1 if the menu's own sectors were rewritten (power cycle needed). */
/* UPD_OK, UPD_EFLASH, FAT_EIO */
int32_t upd_run(const DIRENT *ps_entry, void (*pf_progress)(uint32_t ui32_done, uint32_t ui32_total),
                int32_t *pi32_menu_changed, uint32_t *pui32_written);
/* UPD_PRESENT = at least one machine is installed (a position with an info sector) */
int32_t upd_machines_present(void);
/* diagnostics: the 4 bytes at an image start (+0x20; 0 the menu, 1-3 the machine positions): */
/* 56 EF EF EF where an image is (its sync byte 6A, LSB first) */
void upd_slot_bytes(int32_t i32_slot, uint8_t aui8_bytes[UPD_SLOT_BYTES]);

/* the flash address of a position's ROM area (position 0 to MCH_POSITIONS - 1) */
uint32_t mch_rom_area(int32_t i32_pos);
/* what is in a position: MCH_PRESENT (menu line and machine byte filled) or 0 = empty. The flash */
/* pins are given back. */
int32_t mch_position(int32_t i32_pos, char ac_line[MCH_LINE_BUF], uint8_t *pui8_machine);
/* the first position that holds the machine with this tag byte, or MCH_NONE */
int32_t mch_find(uint8_t ui8_machine);
/* the machine files for this core board in the card's /MACHINES folder: their number (0 = none, or */
/* no such folder; *pps_files = the list), below 0 = card error */
int32_t mch_list(uint32_t ui32_board, const MCH_FILE **pps_files);
/* check a machine file: header, board, sizes, the three checksums. UPD_OK, UPD_EBAD, MCH_EBOARD, FAT_EIO */
int32_t mch_check(const DIRENT *ps_entry, uint32_t ui32_board,
                  void (*pf_progress)(uint32_t ui32_done, uint32_t ui32_total));
/* install a checked machine file into a position: the position's info sector is erased first (the */
/* position is empty until everything is in), then the bitstream and the ROMs are written where they */
/* differ, and the info sector last. A machine without ROMs in its file (the user's own, installed */
/* later) keeps the ROMs of the same machine and loses another machine's. UPD_OK, UPD_EFLASH, FAT_EIO */
int32_t mch_install(const DIRENT *ps_entry, int32_t i32_pos,
                    void (*pf_progress)(uint32_t ui32_done, uint32_t ui32_total), uint32_t *pui32_written);

#endif
