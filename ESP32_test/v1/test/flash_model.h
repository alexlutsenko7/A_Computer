/* flash_model.h -- the model both flash tests (c64rom_test.cpp, update_test.cpp) run against: */
/* the tape loader's flash pass-through register, the SPI flash behind it, the link's flash */
/* stream, the modelled time, and the cut-off (an ESP32 restart in the middle of an install) */
#ifndef FLASH_MODEL_H
#define FLASH_MODEL_H

/* the headers this one needs */
#include <stdint.h>
#include <stdbool.h>
#include <setjmp.h>

/* the flash: 8 MB, erased in sectors of 4 KB */
#define FM_FLASH_SIZE 0x800000u
#define FM_SECTOR 4096u
/* fm_cut_at: no cut-off */
#define FM_NO_CUT (-1)
/* microseconds per second */
#define FM_US_PER_S 1000000

/* the flash's contents */
extern uint8_t g_aui8_fm_flash[FM_FLASH_SIZE];
/* where tick() jumps to at the cut-off */
extern jmp_buf g_s_fm_cut;
/* the modelled time */
extern uint64_t g_ui64_fm_now_us;
/* register accesses counted, and the count that ends the run (FM_NO_CUT: none) */
extern int64_t g_i64_fm_accesses;
extern int64_t g_i64_fm_cut_at;
/* sectors erased, RELOAD commands seen */
extern int64_t g_i64_fm_erases;
extern int32_t g_i32_fm_reloads;
/* how long a byte of the pass-through takes */
extern uint32_t g_ui32_fm_busy_us;
/* the menu has the flash stream; streams run; the stream number that drops a byte (0: none) */
extern bool g_b_fm_stream_on;
extern int64_t g_i64_fm_streams;
extern int64_t g_i64_fm_stream_break;

/* the pass-through as after a restart of the ESP32: not busy (the chip select is kept) */
void fm_link_idle(void);
/* the model's clock starts again */
void fm_clock_restart(void);

#endif
