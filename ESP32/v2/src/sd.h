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

/* the folder under which the card's files are reached with the C library's file calls */
#define SD_FS_ROOT "/sd"
/* The card's file system for the C library's file calls (the core's FatFs: FAT16 / FAT32 with */
/* long names; the FTP server uses it): SD_OK = mounted. The card must be ready (sd_init). While */
/* it is mounted, fat.cpp must not be used: both would keep their own copy of the card's tables. */
int32_t sd_fs_mount(void);
/* the file system is given back; the card stays ready for fat.cpp */
void sd_fs_unmount(void);

#endif
