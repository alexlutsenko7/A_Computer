/* bt.h -- Bluetooth audio menu (F3): drives the Bluetooth part (esp32.ino) through the FPGA's UART */
#ifndef BT_H
#define BT_H

#include <stdint.h>

int  bt_service(void);          /* every main loop pass: reads the ESP32's lines; 1 = a line came */
void bt_open(void);             /* the menu is shown (full-screen OSD) */
void bt_close(void);
int  bt_keys(uint32_t k);       /* loader key presses; 0 = close the menu, 2 = redraw (PIN typed) */
void bt_draw(void);

/* main.c: new key presses from the raw keyboard report, and their characters */
int  raw_events(uint8_t ev[3], uint8_t *mods);
char key_char(uint8_t c, uint8_t mods);

#endif
