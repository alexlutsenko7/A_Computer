/* flash.h -- the configuration flash (W25Q64 / EPCS64) through the FPGA's pass-through register
 * FLASH (rtl/tape_loader.v): SPI mode 0, one byte per register write. Used by the C64 ROM install
 * (c64.cpp) and the flash update (update.cpp). */
#ifndef FLASH_H
#define FLASH_H

#include <stdint.h>

void    fl_send(uint8_t b);                 /* chip select on, send one byte */
uint8_t fl_xfer(uint8_t b);                 /* send one byte, return the byte received */
void    fl_end(void);                       /* chip select off, the pins stay with the port */
void    fl_cmd(uint8_t c);                  /* chip select off, then on with command c */
void    fl_addr(uint8_t cmd, uint32_t a);   /* command + 24-bit address */
int     fl_wait(uint32_t ms);               /* wait while busy: 0, or -1 after ms */
void    fl_wren(void);                      /* write enable */
void    fl_read(uint32_t a, uint8_t *d, uint32_t n);
void    fl_release(void);                   /* give the pins back (FLASH = 0) */

#endif
