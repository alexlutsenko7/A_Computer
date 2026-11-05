/* update.h -- flash update from the SD card (LUPDATE.BIN in the root folder), run by the machine
 * menu image (AMenu); also: are any machines installed? */
#ifndef UPDATE_H
#define UPDATE_H

#include <stdint.h>
#include "fat.h"

#define UPD_EBAD    -40     /* not a valid update file (header, size or checksum) */
#define UPD_EFLASH  -41     /* the flash did not take the data (erase / program / verify) */

#define UPD_NAME11  "LUPDATE BIN"

/* LUPDATE.BIN in the root folder: 1 (d filled), 0 = none, < 0 = card error */
int  upd_find(DIRENT *d);
/* the update's label (after upd_check: "L 2026-10-30 ...") */
const char *upd_label(void);
/* check the file: header, size, CRC-32 of the whole image. 0, UPD_EBAD, FAT_EIO */
int  upd_check(const DIRENT *d, void (*progress)(uint32_t done, uint32_t total));
/* write the sectors that differ (the menu's last, the C64 ROM area never), verify, delete the
 * file. *menu_changed = 1 if the menu's own sectors were rewritten (power cycle needed).
 * 0, UPD_EFLASH, FAT_EIO */
int  upd_run(const DIRENT *d, void (*progress)(uint32_t done, uint32_t total), int *menu_changed,
             uint32_t *written);
/* 1 = at least one machine image is in the flash */
int  upd_machines_present(void);
/* diagnostics: the 4 bytes at slot k's image start (+0x20; k = 0 the menu, 1-4 the machines):
 * 56 EF EF EF where an image is (its sync byte 6A, LSB first) */
void upd_slot_bytes(int k, uint8_t b[4]);

#endif
