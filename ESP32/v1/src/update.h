/* update.h -- flash update from the SD card (LUPDATE.BIN in the root folder), run by the machine */
/* menu image (AMenu); also: are any machines installed? */
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
/* UPD_PRESENT = at least one machine image is in the flash */
int32_t upd_machines_present(void);
/* diagnostics: the 4 bytes at a slot's image start (+0x20; slot 0 the menu, 1-4 the machines): */
/* 56 EF EF EF where an image is (its sync byte 6A, LSB first) */
void upd_slot_bytes(int32_t i32_slot, uint8_t aui8_bytes[UPD_SLOT_BYTES]);

#endif
