/* espupd.h -- the ESP32's own firmware from the SD card (LESP32.BIN in the root folder), run by
 * the machine menu mode before the flash update (LUPDATE.BIN) */
#ifndef ESPUPD_H
#define ESPUPD_H

#include <stdint.h>
#include "fat.h"

#define ESPUPD_EBAD    -50     /* not an ESP32 application image (magic, chip, size) */
#define ESPUPD_EWRITE  -51     /* the firmware slot did not take it, or the image did not verify */

#define ESPUPD_NAME11  "LESP32  BIN"

/* LESP32.BIN in the root folder: 1 (d filled), 0 = none, < 0 = card error */
int espupd_find(DIRENT *d);
/* write it into the unused firmware slot, verify it, make that slot the one that boots, delete
 * the file. 0 (the caller restarts the ESP32), ESPUPD_EBAD, ESPUPD_EWRITE, FAT_EIO */
int espupd_run(const DIRENT *d, void (*progress)(uint32_t done, uint32_t total));

/* the platform (esp_hw.cpp): the ESP32's firmware slots */
int  ota_begin(uint32_t size);                       /* 0 = ok */
int  ota_write(const uint8_t *d, uint32_t n);        /* 0 = ok */
int  ota_end(void);                                  /* verify + select the new slot, 0 = ok */
void ota_abort(void);
void esp_reboot(void);

#endif
