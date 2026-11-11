/* bt.h -- Bluetooth audio menu (F3): drives the Bluetooth part (v2.ino) through the FPGA's UART */
#ifndef BT_H
#define BT_H

#include <stdint.h>

/* results of bt_keys */
#define BT_KEYS_CLOSE 0
#define BT_KEYS_STAY 1
#define BT_KEYS_REDRAW 2
/* bt_service: a line came */
#define BT_LINE 1
/* key events in one raw keyboard report */
#define RAW_EVENTS_MAX 3

/* every main loop pass: reads the ESP32's lines; BT_LINE = a line came */
int32_t bt_service(void);
/* the menu is shown (full-screen OSD) */
void bt_open(void);
/* the menu is closed */
void bt_close(void);
/* loader key presses; BT_KEYS_CLOSE = close the menu, BT_KEYS_REDRAW = redraw (PIN typed) */
int32_t bt_keys(uint32_t ui32_keys);
/* draw the menu */
void bt_draw(void);

/* main.c: new key presses from the raw keyboard report, and their characters */
int32_t raw_events(uint8_t aui8_events[RAW_EVENTS_MAX], uint8_t *pui8_mods);
char key_char(uint8_t ui8_code, uint8_t ui8_mods);

#endif
