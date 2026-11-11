/* reset.h -- every loader module back to its state after a start, so the loader can run again for */
/* the next machine without an ESP32 restart (the Bluetooth connection stays): esp_hw.cpp calls */
/* loader_reset_all() (main.cpp) when the machine on the link changed */
#ifndef RESET_H
#define RESET_H

/* all modules */
void loader_reset_all(void);
/* each module */
void at_reset(void);
void c64_reset(void);
void save_reset(void);
/* the screenshot, snapshot and tape modules */
void shot_reset(void);
void snap_reset(void);
void tape_reset(void);
/* the Bluetooth menu and the file system */
void bt_reset(void);
void fat_reset(void);

#endif
