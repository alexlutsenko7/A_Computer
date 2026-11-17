/* md.h -- LMega (the Sega Mega Drive core): cartridge files, battery RAM (.sav) */
#ifndef MD_H
#define MD_H

/* the headers this one needs */
#include <stdint.h>
#include "fat.h"

/* everything went well */
#define MD_OK 0
/* not a usable cartridge file */
#define MD_EBAD (-50)
/* larger than the core takes (4 MB) */
#define MD_ESIZE (-51)
/* md_status: a cartridge is in */
#define MD_CART_IN 1

/* Load a cartridge file (.md / .gen / .bin: the plain ROM; .smd: 512-byte header and interleaved */
/* 16 KB blocks) from folder ui32_dir into the machine and start it. The console's region is taken */
/* from the cartridge's header (America first, then Europe, then Japan). The battery RAM of a game */
/* that has one is read from its .sav file in the same folder and written back there by md_service. */
/* MD_OK, MD_EBAD, MD_ESIZE, FAT_EIO. */
int32_t md_load(const FFILE *ps_file, const char *pc_name, uint32_t ui32_dir);
/* main loop: saves the battery RAM to the card a moment after the game wrote it */
void md_service(void);
/* the cartridge's name into pc_text while one is in: MD_CART_IN, else 0 */
int32_t md_status(char *pc_text);
/* back to the state after a start (esp_hw.cpp, when the machine was left) */
void md_reset(void);

#endif
