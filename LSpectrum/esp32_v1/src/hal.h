/* hal.h -- what the portable code (fat.c, tape.c) needs from the platform.
 * Implemented by esp_hw.cpp + main.cpp on the ESP32 and by test/host_test.c on the PC. */
#ifndef HAL_H
#define HAL_H

#include <stdint.h>

int      sd_read(uint32_t lba, uint8_t *buf);   /* one 512-byte sector, 0 = ok */
int      sd_write(uint32_t lba, const uint8_t *buf);
uint32_t fifo_free(void);                       /* free entries in the pulse FIFO */
void     fifo_push(uint32_t cmd);               /* only called when fifo_free() > 0 */

/* Pulse player commands (see docs/SD_TAPE_LOADER.md and rtl/tape_loader.v).
 * Durations are Z80 T-states (CPU clock-enable ticks), so a file plays at the
 * right speed in normal and turbo mode. */
#define CMD_PULSE(n)    ((uint32_t)(n) & 0xFFFFFFu)                                 /* hold n, then toggle */
#define CMD_LEVEL(l, n) (0x40000000u | ((uint32_t)((l) & 1) << 24) | ((uint32_t)(n) & 0xFFFFFFu)) /* set level, hold n */
#define CMD_DATA(b, nb) (0x80000000u | ((uint32_t)((nb) - 1) << 8) | ((b) & 0xFFu))  /* nb bits MSB first, 2 pulses each */
#define CMD_SAMP(b, nb) (0x80000800u | ((uint32_t)((nb) - 1) << 8) | ((b) & 0xFFu))  /* nb samples MSB first, len0 each */
#define CMD_LEN0(n)     (0xC0000000u | ((uint32_t)(n) & 0xFFFFu))                   /* pulse length of a 0 bit */
#define CMD_LEN1(n)     (0xD0000000u | ((uint32_t)(n) & 0xFFFFu))                   /* pulse length of a 1 bit */
#define CMD_MARK(n)     (0xE0000000u | ((uint32_t)(n) & 0xFFFFu))                   /* MARKER register <= n */
#define CMD_MAX_T       0xFFFFFFu

#endif
