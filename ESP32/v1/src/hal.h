/* hal.h -- what the portable code (fat.c, tape.c) needs from the platform. */
/* Implemented by esp_hw.cpp + main.cpp on the ESP32 and by test/host_test.c on the PC. */
#ifndef HAL_H
#define HAL_H

#include <stdint.h>

/* Pulse player commands (see docs/SD_TAPE_LOADER.md and rtl/tape_loader.v). */
/* Durations are Z80 T-states (CPU clock-enable ticks), so a file plays at the */
/* right speed in normal and turbo mode. */
/* the command's kind in the top bits */
#define CMD_KIND_LEVEL 0x40000000u
#define CMD_KIND_DATA 0x80000000u
/* data as bits, data as samples */
#define CMD_KIND_SAMP 0x80000800u
#define CMD_KIND_LEN0 0xC0000000u
/* the two pulse lengths, the marker */
#define CMD_KIND_LEN1 0xD0000000u
#define CMD_KIND_MARK 0xE0000000u
/* the fields: a duration of 24 bits, a level bit, a count of bits, a byte, a 16-bit value */
#define CMD_TIME_MASK 0xFFFFFFu
#define CMD_LEVEL_MASK 1u
/* where the level bit and the bit count are */
#define CMD_LEVEL_SHIFT 24
#define CMD_COUNT_SHIFT 8
#define CMD_COUNT_BIAS 1u
/* a byte, a 16-bit value */
#define CMD_BYTE_MASK 0xFFu
#define CMD_WORD_MASK 0xFFFFu
/* the longest duration of one command */
#define CMD_MAX_T 0xFFFFFFu

/* hold n T-states, then toggle */
#define CMD_PULSE(n) ((uint32_t)(n) & CMD_TIME_MASK)
/* set the level, hold n T-states */
#define CMD_LEVEL(l, n) \
    (CMD_KIND_LEVEL | ((uint32_t)((l) & CMD_LEVEL_MASK) << CMD_LEVEL_SHIFT) | ((uint32_t)(n) & CMD_TIME_MASK))
/* nb bits of byte b, MSB first, 2 pulses each */
#define CMD_DATA(b, nb) (CMD_KIND_DATA | ((uint32_t)((nb) - CMD_COUNT_BIAS) << CMD_COUNT_SHIFT) | ((b) & CMD_BYTE_MASK))
/* nb samples of byte b, MSB first, the length of a 0 bit each */
#define CMD_SAMP(b, nb) (CMD_KIND_SAMP | ((uint32_t)((nb) - CMD_COUNT_BIAS) << CMD_COUNT_SHIFT) | ((b) & CMD_BYTE_MASK))
/* pulse length of a 0 bit */
#define CMD_LEN0(n) (CMD_KIND_LEN0 | ((uint32_t)(n) & CMD_WORD_MASK))
/* pulse length of a 1 bit */
#define CMD_LEN1(n) (CMD_KIND_LEN1 | ((uint32_t)(n) & CMD_WORD_MASK))
/* MARKER register <= n */
#define CMD_MARK(n) (CMD_KIND_MARK | ((uint32_t)(n) & CMD_WORD_MASK))

/* read one 512-byte sector: 0 = ok */
int32_t sd_read(uint32_t ui32_lba, uint8_t *pui8_buf);
/* write one 512-byte sector: 0 = ok */
int32_t sd_write(uint32_t ui32_lba, const uint8_t *pui8_buf);
/* free entries in the pulse FIFO */
uint32_t fifo_free(void);
/* one command into the pulse FIFO; only called when fifo_free() > 0 */
void fifo_push(uint32_t ui32_cmd);

#endif
