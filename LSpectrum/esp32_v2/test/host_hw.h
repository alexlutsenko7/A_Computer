/* host_hw.h -- PC stand-ins for the loader CPU registers used by save.c and snap.c (HOST_TEST) */
#ifndef HOST_HW_H
#define HOST_HW_H

#include <stdint.h>

#define CLK_PER_MS  56000u
#define TAPE_TURBO  2u
#define REC_PEND    0x80000000u
#define REC_GAP     0x40000000u
#define REC_ARMED   1u
#define REC_HOLD    2u

uint32_t rec_event(void);       /* next recorder event (REC) */
uint32_t rec_since(void);       /* T-states since the last edge (RECCTL read) */
void     rec_ctl(uint32_t v);   /* RECCTL write */
void     tape_ctl(uint32_t v);  /* TAPE write */
uint32_t timer_now(void);       /* TIMER */

/* snapshot port (snap.c), modelled by snap_test.c */
#define SNAP_FROZEN 1u
void     snap_ctl(uint32_t v);                              /* SNAPCTL write */
uint32_t snap_status(void);                                 /* SNAPCTL read */
uint32_t snap_cmd(uint32_t c, uint32_t a, uint32_t d);      /* SNAPDAT, SNAPCMD, wait, SNAPDAT */

#endif
