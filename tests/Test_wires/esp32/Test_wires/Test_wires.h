// Types for Test_wires.ino (in a header so the Arduino prototype generator sees them first)
#pragma once
#include <stdint.h>

struct Wire {
    int gpio;
    const char *esp, *fpga, *u7, *sig;
};

struct Frame {
    uint8_t id, lvl, cnt[6];
};
struct LineStat {
    int edges, ones, bytes, ferr, frames;
    int id_count[4];                                // valid frames per id C1..C4
    int other_ids;
    bool have;
    Frame last;
};
