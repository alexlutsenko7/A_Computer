/* sd.h -- SD card in SPI mode (sd_read is declared in hal.h) */
#ifndef SD_H
#define SD_H

int sd_init(void);      /* 0 = card ready */
int sd_ready(void);

#endif
