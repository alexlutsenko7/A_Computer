/* cart.h -- what the cartridge machines (LNES, LMega) share: a game file into the FPGA's SDRAM, */
/* and the battery RAM of a game as a .sav file beside it */
#ifndef CART_H
#define CART_H

/* the headers this one needs */
#include <stdint.h>
#include "fat.h"

/* Memory access goes through the memory commands of the snapshot port, 256 KB pages at a time: */
/* the page number is a field of the machine's MCTL word. cart_begin tells where that field is */
/* (ui32_page_lsb) and what the rest of the word is while memory is written (ui32_state: 0 = the */
/* machine is stopped; the running machine's word when it runs). */
void cart_begin(uint32_t ui32_page_lsb, uint32_t ui32_state);
/* one byte out of / into the SDRAM */
uint8_t cart_peek(uint32_t ui32_addr);
void cart_poke(uint32_t ui32_addr, uint8_t ui8_value);
/* ui32_count bytes of a file from its read position into the SDRAM at ui32_addr: FAT_OK, FAT_EIO */
int32_t cart_load(FFILE *ps_file, uint32_t ui32_addr, uint32_t ui32_count);
/* ui32_count bytes of one value into the SDRAM at ui32_addr */
void cart_fill(uint32_t ui32_addr, uint32_t ui32_count, uint8_t ui8_value);

/* Battery RAM. cart_sav_setup: the game's folder and name (the file is NAMEhhhh.SAV: four */
/* characters of the name and a check value of the whole name), the RAM's place in the SDRAM and */
/* its length; ui32_len = 0: the game has none. cart_sav_start fills the RAM from the file, or */
/* with ui8_fill when there is no file (machine stopped). cart_sav_service (main loop, machine */
/* running) writes the file when the game has stopped writing for a moment, or every few */
/* seconds while it keeps writing; cart_sav_flush writes it now if something is not saved yet. */
void cart_sav_setup(uint32_t ui32_dir, const char *pc_name, uint32_t ui32_addr, uint32_t ui32_len);
void cart_sav_start(uint8_t ui8_fill);
void cart_sav_service(void);
/* what is not saved yet goes to the card now */
void cart_sav_flush(void);
/* back to the state after a start */
void cart_reset(void);

#endif
