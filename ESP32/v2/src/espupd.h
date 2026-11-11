/* espupd.h -- the ESP32's own firmware from the SD card (LESP32.BIN in the root folder), run by */
/* the machine menu mode before the flash update (LUPDATE.BIN) */
#ifndef ESPUPD_H
#define ESPUPD_H

/* the headers this one needs */
#include <stdint.h>
#include "fat.h"

/* everything went well */
#define ESPUPD_OK 0
/* not an ESP32 application image (magic, chip, size) */
#define ESPUPD_EBAD (-50)
/* the firmware slot did not take it, or the image did not verify */
#define ESPUPD_EWRITE (-51)
/* espupd_find: the file is there */
#define ESPUPD_FOUND 1
/* the file's 8.3 name as stored */
#define ESPUPD_NAME11 "LESP32  BIN"

/* LESP32.BIN in the root folder: ESPUPD_FOUND (entry filled), 0 = none, below 0 = card error */
int32_t espupd_find(DIRENT *ps_entry);
/* write it into the unused firmware slot, verify it, make that slot the one that boots, delete */
/* the file. ESPUPD_OK (the caller restarts the ESP32), ESPUPD_EBAD, ESPUPD_EWRITE, FAT_EIO */
int32_t espupd_run(const DIRENT *ps_entry, void (*pf_progress)(uint32_t ui32_done, uint32_t ui32_total));

/* the platform (esp_hw.cpp): the ESP32's firmware slots */
/* start writing an image of this size: 0 = ok */
int32_t ota_begin(uint32_t ui32_size);
/* the next bytes of the image: 0 = ok */
int32_t ota_write(const uint8_t *pui8_data, uint32_t ui32_count);
/* verify + select the new slot: 0 = ok */
int32_t ota_end(void);
/* give up: the running firmware stays */
void ota_abort(void);
/* restart the ESP32 */
void esp_reboot(void);

#endif
