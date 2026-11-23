/* netmenu.h -- the machine menu's F4 screens: the SD card over Wi-Fi. A network is chosen (or the */
/* remembered one joined) and the FTP server (ftp.h) runs on the card until the screen is left. */
#ifndef NETMENU_H
#define NETMENU_H

#include <stdint.h>

/* F4 in the machine menu: returns when the screens are left (the server stopped, the radio off) */
void net_menu(void);

/* main.cpp: new presses of the loader's keys (K_*), with auto-repeat for the movement keys */
uint32_t loader_keys(void);
/* main.cpp: 1 = the console's "ftp" was given since the last call (it starts and stops the server as F4 does) */
int32_t loader_ftp_asked(void);

#endif
