/* hw.h -- the FPGA's tape loader registers (rtl/tape_loader.v) as seen by the loader firmware.
 *
 * Each register is a small proxy object whose reads and writes go over the SPI link
 * (rtl/esp_link.v), see esp_hw.cpp. TIMER is the ESP32's own clock, scaled to the FPGA's
 * 56 MHz. The SD card is the ESP32's own (sd.h).
 */
#ifndef HW_H
#define HW_H

#include <stdint.h>

uint32_t hw_rd(uint8_t r);
void     hw_wr(uint8_t r, uint32_t v);

struct HwReg {
    uint8_t r;
    operator uint32_t() const { return hw_rd(r); }
    const HwReg &operator=(uint32_t v) const { hw_wr(r, v); return *this; }
    const HwReg &operator^=(uint32_t v) const { hw_wr(r, hw_rd(r) ^ v); return *this; }
    const HwReg &operator|=(uint32_t v) const { hw_wr(r, hw_rd(r) | v); return *this; }
    const HwReg &operator&=(uint32_t v) const { hw_wr(r, hw_rd(r) & v); return *this; }
};

/* the machine on the link (esp_hw.cpp probe): machine_c64 = 1: L64 (C64); machine_atari = 1:
 * LTari (Atari 800XL / 130XE); both 0: LSpectrum (ZX Spectrum 128K) */
extern int machine_c64;
extern int machine_atari;
extern int machine_menu;
void log_line(const char *s);   /* one line to the ESP32's USB serial port (diagnostics) */
void *ext_alloc(uint32_t n);   /* n bytes in the PSRAM (WROVER module), 0 if there is none */
int  menu_present(void);        /* machine menu: 0 once the FPGA was reconfigured into a machine (the menu loop ends) */    /* the machine menu (AMenu): only the flash update / "no machines" screen */

/* 1 = that machine still answers on the link (core ID, the IRQ mask set at start): reads
 * from a reconfiguring or reset FPGA return all ones, which must not be taken as data */
int link_alive(void);

/* main.c's main() is the loader task (esp_hw.cpp) */
#define main loader_main

#define CLK_HZ      56000000u
#define CLK_PER_MS  56000u

#define IO(o)       (HwReg{(uint8_t)(o)})
#define KEYS        IO(0x08)
#define FIFO        IO(0x0C)    /* R only: pushes go through fifo_push() (hal.h), sent in bursts */
#define TAPE        IO(0x10)
#define OSDC        IO(0x14)
#define TIMER       IO(0x18)    /* local */
#define MARKER      IO(0x1C)
#define REC         IO(0x20)
#define RECCTL      IO(0x24)
#define KEYRAW      IO(0x28)
#define SNAPCTL     IO(0x2C)
#define SNAPCMD     IO(0x30)    /* memory reads / writes become link MRD / MWR bursts */
#define SNAPDAT     IO(0x34)
#define INTPOS      IO(0x38)
#define INT_NOCONT  0x80000000u
#define INT_JOY     0x30000000u /* joystick mode (rtl/zx_system.v): 0 Kempston, 1 Kempston + Cursor, 2 Sinclair 1 + 2 */
#define INT_JOY_SH  28
#define UART        IO(0x3C)    /* FPGA UART to the ESP32's own UART2 (the Bluetooth part of this sketch) */
#define FLASH       IO(0x40)    /* L64: configuration flash pass-through (C64 ROM install, c64.cpp) */
#define FL_START    0x100u
#define FL_CS       0x200u
#define FL_EN       0x400u
#define FL_BUSY     0x100u
#define RELOAD      IO(0x44)    /* L64: 1 = reload the ROMs from flash and restart the C64 */
#define INT_SID8580 INT_NOCONT  /* L64: INTPOS[31] selects the 8580 SID (LSpectrum: contention off) */
#define MCTL        IO(0x48)    /* L64 1541: W [0] disk, [1] read only, [2] turbo allowed (F6), [13:8] track in the buffer, [23:16] id1, [31:24] id2
                                   R (MSTAT): [5:0] head track, [6] motor, [7] LED, [28:8] dirty sectors */
#define MCLR        IO(0x4C)    /* L64 1541: clear dirty sector bits */
#define UART_SEND   0x100u
#define UART_POP    0x200u
#define UART_CLR    0x400u
#define UART_VALID  0x100u
#define UART_BUSY   0x200u
#define UART_OVR    0x400u

#define FIFO_DEPTH  512u
#define FIFO_IDLE   0x10000u
#define TAPE_ON     1u
#define TAPE_TURBO  2u
#define TAPE_FLUSH  4u
#define OSD_ON      1u
#define OSD_FULL    2u
#define REC_PEND    0x80000000u
#define REC_GAP     0x40000000u
#define REC_LOST    0x20000000u
#define REC_ARMED   1u
#define REC_HOLD    2u
#define SNAP_FROZEN 1u
#define SNAP_BUSY   2u

#define K_MENU      (1u << 0)
#define K_UP        (1u << 1)
#define K_DOWN      (1u << 2)
#define K_LEFT      (1u << 3)
#define K_RIGHT     (1u << 4)
#define K_ENTER     (1u << 5)
#define K_F11       (1u << 6)
#define K_KP5       (1u << 7)
#define K_REW       (1u << 8)
#define K_BACK      (1u << 9)
#define K_STOP      (1u << 10)
#define K_SPEED     (1u << 11)
#define K_SNAP      (1u << 12)
#define K_PGUP      (1u << 13)
#define K_PGDN      (1u << 14)
#define K_CONT      (1u << 15)
#define K_BT        (1u << 16)
#define K_JOY       (1u << 17)

#endif
