/* nes.h -- LNES (the NES core): cartridge files (.nes), battery RAM (.sav), screenshot */
#ifndef NES_H
#define NES_H

/* the headers this one needs */
#include <stdint.h>
#include "fat.h"

/* everything went well */
#define NES_OK 0
/* not a usable .nes file */
#define NES_EBAD (-40)
/* a cartridge type (mapper) the core does not have */
#define NES_EMAPPER (-41)
/* program or picture data larger than the core takes */
#define NES_ESIZE (-42)
/* nes_status: a cartridge is in */
#define NES_CART_IN 1

/* Load a .nes file from folder ui32_dir into the machine and start it. The battery RAM of a game */
/* that has one is read from its .sav file in the same folder (zeros if there is none) and written */
/* back there by nes_service. *pui32_mapper = the mapper number of the file (also on NES_EMAPPER). */
/* NES_OK, NES_EBAD, NES_EMAPPER, NES_ESIZE, FAT_EIO. */
int32_t nes_load(const FFILE *ps_file, const char *pc_name, uint32_t ui32_dir, uint32_t *pui32_mapper);
/* main loop: saves the battery RAM to the card a moment after the game wrote it */
void nes_service(void);
/* the cartridge's name into pc_text while one is in: NES_CART_IN, else 0 */
int32_t nes_status(char *pc_text);
/* Print Screen: the picture (256 x 240, the frame buffer's newest frame) as a 256-colour BMP in */
/* a folder; the machine runs on. NES_OK, FAT_* */
int32_t nes_screenshot(uint32_t ui32_dir, const char ac_name11[FAT_NAME11_LEN]);
/* back to the state after a start (esp_hw.cpp, when the machine was left) */
void nes_reset(void);

#endif
