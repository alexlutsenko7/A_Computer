/* sd.h -- SD card in SPI mode (sd_read is declared in hal.h) */
#ifndef SD_H
#define SD_H

#include <stdint.h>

/* results of sd_init */
#define SD_OK 0
#define SD_ERROR (-1)

/* start the card: SD_OK = card ready */
int32_t sd_init(void);
/* 1 = the card is ready */
int32_t sd_ready(void);

#endif
