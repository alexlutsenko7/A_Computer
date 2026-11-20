/* next.h -- LNext (the ZX Spectrum Next core): the SD card's sectors for the machine */
#ifndef NEXT_H
#define NEXT_H

/* the headers this one needs */
#include <stdint.h>

/* next_start: the card is in the machine */
#define NEXT_OK 0
/* no card, or it does not answer */
#define NEXT_ENOCARD (-60)

/* Put the card into the machine: the folder ZXNEXT is looked for, the card's size goes to the core's SD card of logic and the machine */
/* leaves its reset (it starts from the card: TBBLUE.FW, the ROMs, NextZXOS). NEXT_OK, NEXT_ENOCARD. */
int32_t next_start(void);
/* main loop: moves the sectors the machine asks for between it and the card. It stays inside */
/* while requests follow each other. Returns the number of sectors moved. */
uint32_t next_service(void);
/* sectors read and written since the start (the console's "status") */
void next_counts(uint32_t *pui32_read, uint32_t *pui32_written);
/* 1 = the machine works in the card's folder ZXNEXT (shown to it as the root directory), */
/* 0 = in the card's root directory (a card without the folder, or not FAT32) */
int32_t next_in_folder(void);
/* back to the state after a start (esp_hw.cpp, when the machine was left) */
void next_reset(void);

#endif
