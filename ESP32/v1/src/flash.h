/* flash.h -- the configuration flash (W25Q64 / EPCS64) through the FPGA's pass-through register */
/* FLASH (rtl/tape_loader.v): SPI mode 0, one byte per register write. Used by the C64 ROM install */
/* (c64.cpp) and the flash update (update.cpp). */
#ifndef FLASH_H
#define FLASH_H

/* the headers this one needs */
#include <stdint.h>
#include <stdbool.h>

/* the largest data part of one flash stream (fl_stream) */
#define FL_STREAM_MAX 4096u
/* results of the functions that can fail */
#define FL_OK 0
#define FL_ERROR (-1)

/* chip select on, send one byte */
void fl_send(uint8_t ui8_byte);
/* send one byte, return the byte received */
uint8_t fl_xfer(uint8_t ui8_byte);
/* chip select off, the pins stay with the port */
void fl_end(void);
/* chip select off, then on with command ui8_cmd */
void fl_cmd(uint8_t ui8_cmd);
/* command + 24-bit address */
void fl_addr(uint8_t ui8_cmd, uint32_t ui32_addr);
/* wait while the flash is busy: FL_OK, or FL_ERROR after ui32_ms */
int32_t fl_wait(uint32_t ui32_ms);
/* write enable */
void fl_wren(void);
/* read ui32_count bytes from ui32_addr */
void fl_read(uint32_t ui32_addr, uint8_t *pui8_dst, uint32_t ui32_count);
/* write enable + page program of 256 bytes (no wait) */
void fl_prog(uint32_t ui32_addr, const uint8_t *pui8_src);
/* give the pins back (FLASH = 0) */
void fl_release(void);

/* Flash stream (link frame FLS, esp_hw.cpp; only the machine menu, link version 2, has it): chip */
/* select on, the header bytes then ui32_count data bytes (zeros if pui8_data is NULL) out on the */
/* flash, chip select stays on (fl_end). pui8_rx: the flash's byte for each data byte (two more */
/* zeros are clocked out for them). FL_ERROR: no stream here or a link error; the stream is then */
/* not used again and the caller does the same the byte-wise way (a write may have been done */
/* partly: the caller verifies). ui32_count <= FL_STREAM_MAX. */
int32_t fl_stream(const uint8_t *pui8_hdr, uint32_t ui32_hdr_len, const uint8_t *pui8_data, uint8_t *pui8_rx,
                  uint32_t ui32_count);

#endif
