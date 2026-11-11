/* host_hw.h -- PC stand-ins for the loader CPU registers used by save.c and snap.c (HOST_TEST) */
#ifndef HOST_HW_H
#define HOST_HW_H

#include <stdint.h>

/* clocks of the loader's 56 MHz per millisecond */
#define CLK_PER_MS 56000u
/* TAPE register: turbo */
#define TAPE_TURBO 2u
/* a recorder event: valid, a gap */
#define REC_PEND 0x80000000u
#define REC_GAP 0x40000000u
/* RECCTL bits */
#define REC_ARMED 1u
#define REC_HOLD 2u
/* snapshot port (snap.c), modelled by snap_test.c: the CPU is frozen */
#define SNAP_FROZEN 1u

/* next recorder event (REC) */
uint32_t rec_event(void);
/* T-states since the last edge (RECCTL read) */
uint32_t rec_since(void);
/* RECCTL write */
void rec_ctl(uint32_t ui32_value);
/* TAPE write */
void tape_ctl(uint32_t ui32_value);
/* TIMER */
uint32_t timer_now(void);

/* SNAPCTL write */
void snap_ctl(uint32_t ui32_value);
/* SNAPCTL read */
uint32_t snap_status(void);
/* SNAPDAT, SNAPCMD, wait, SNAPDAT */
uint32_t snap_cmd(uint32_t ui32_cmd, uint32_t ui32_addr, uint32_t ui32_data);

#endif
