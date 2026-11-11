/* Types for Test_wires.ino (in a header so the Arduino prototype generator sees them first) */
#pragma once
/* the sized integer types */
#include <stdint.h>

/* the wires per direction, and the FPGA's inputs counted in a frame */
#define RET_WIRES 4
#define FWD_WIRES 6

/* one wire: the ESP32's pin, and its names on both sides */
struct Wire
{
/* the GPIO number, the ESP32 pin's name */
    int32_t i32_gpio;
    const char *pc_esp;
/* the FPGA's ball, the header pin, the signal */
    const char *pc_fpga;
    const char *pc_u7;
    const char *pc_sig;
};

/* one frame from the FPGA: the output it left on, the levels and edge counts of its inputs */
struct Frame
{
    uint8_t ui8_id;
    uint8_t ui8_lvl;
/* one counter per input */
    uint8_t aui8_cnt[FWD_WIRES];
};

/* what was seen on one sampled line */
struct LineStat
{
/* level changes, samples that were 1 */
    int32_t i32_edges;
    int32_t i32_ones;
/* UART bytes, framing errors, valid frames */
    int32_t i32_bytes;
    int32_t i32_ferr;
    int32_t i32_frames;
/* valid frames per id C1..C4, and with any other id */
    int32_t ai32_id_count[RET_WIRES];
    int32_t i32_other_ids;
/* a frame was seen, and the last one */
    bool b_have;
    Frame s_last;
};
