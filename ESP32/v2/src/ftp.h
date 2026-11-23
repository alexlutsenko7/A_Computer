/* ftp.h -- an FTP server for the SD card (the machine menu's F4 screen, netmenu.cpp). */
/* Anonymous: any user name and any password are taken, and none is needed. Passive and active */
/* data connections, binary transfers, several clients at a time. The files are reached with the */
/* C library's calls under a root folder (the mounted card on the ESP32, a folder on the PC for */
/* the test ESP32_test/v2/test/ftp_test.cpp), the network with sockets. */
#ifndef FTP_H
#define FTP_H

#include <stdint.h>

/* clients at a time (FileZilla uses one connection to browse and two to transfer) */
#define FTP_SESSIONS 3
/* the port of the control connections */
#define FTP_PORT 21u
/* ftp_info: the text of the last action, with its terminator */
#define FTP_TEXT_BUF 31

/* what the server did so far */
typedef struct
{
/* clients connected now */
    int32_t i32_clients;
/* files received and sent, and their kilobytes */
    uint32_t ui32_files_in;
    uint32_t ui32_files_out;
/* the kilobytes received and sent */
    uint32_t ui32_kb_in;
    uint32_t ui32_kb_out;
/* the last action ("Received NAME", "Sent NAME", "Deleted NAME", ...) */
    char ac_last[FTP_TEXT_BUF];
} FTP_INFO;

/* what the platform gives: milliseconds since the start */
uint32_t ftp_ms(void);

/* start the server: the folder that the clients see as "/" (no "/" at its end), the control */
/* port; 0 = ok */
int32_t ftp_start(const char *pc_root, uint32_t ui32_port);
/* stop it: all connections and files are closed */
void ftp_stop(void);
/* often: new clients, commands, a piece of every transfer; 1 = there was work (call again soon) */
int32_t ftp_poll(void);
/* what it did so far */
void ftp_info(FTP_INFO *ps_info);

#endif
