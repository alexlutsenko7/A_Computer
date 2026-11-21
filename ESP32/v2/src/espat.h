/* espat.h -- LNext: the ESP32 as the Spectrum Next's Wi-Fi module. */
/* The Next's programs talk to an ESP8266 with the "AT" firmware on the machine's ESP UART */
/* (115200 8N1). espat.cpp answers those commands; the network itself is the platform's */
/* (espnet.cpp on the ESP32, a model in the PC test ESP32_test/v2/test/espat_test.cpp). */
#ifndef ESPAT_H
#define ESPAT_H

#include <stdint.h>

/* connections at a time (the AT firmware's link numbers 0 to 4) */
#define ESPAT_LINKS 5
/* text buffers: a network's name, its password, an address, a MAC address */
#define ESPAT_SSID_BUF 33
#define ESPAT_PASS_BUF 65
#define ESPAT_IP_BUF 16
#define ESPAT_MAC_BUF 18
/* net_fail: why joining a network failed (the numbers of +CWJAP:n); 0 = it has not failed */
#define ESPAT_JOIN_TIMEOUT 1
#define ESPAT_JOIN_PASSWORD 2
#define ESPAT_JOIN_NO_AP 3
/* net_open: no address for the name, no connection */
#define ESPAT_OPEN_OK 0
#define ESPAT_OPEN_DNS (-1)
#define ESPAT_OPEN_FAIL (-2)

/* a network: the one joined, or one found by a search */
typedef struct
{
/* its name, the access point's address */
    char ac_ssid[ESPAT_SSID_BUF];
    char ac_bssid[ESPAT_MAC_BUF];
/* our addresses in it (the joined one only) */
    char ac_ip[ESPAT_IP_BUF];
    char ac_gateway[ESPAT_IP_BUF];
    char ac_mask[ESPAT_IP_BUF];
/* the name server, our MAC address */
    char ac_dns[ESPAT_IP_BUF];
    char ac_mac[ESPAT_MAC_BUF];
/* channel, signal strength in dBm, encryption (0 open, 1 WEP, 2 WPA, 3 WPA2, 4 WPA / WPA2) */
    int32_t i32_channel;
    int32_t i32_rssi;
    int32_t i32_ecn;
} ESPAT_NET;

/* what the platform gives: the UART to the machine, a clock */

/* bytes to the machine */
void espat_out(const uint8_t *pui8_data, uint32_t ui32_len);
/* the UART's speed from now on (after what was sent is out) */
void espat_baud(uint32_t ui32_baud);
/* milliseconds since the start; wait so many */
uint32_t espat_ms(void);
void espat_wait(uint32_t ui32_ms);

/* what the platform gives: the network */

/* the radio on (0 = ok) and off */
int32_t net_on(void);
void net_off(void);
/* start joining a network (an empty password: an open one); leave it */
void net_begin(const char *pc_ssid, const char *pc_password);
void net_leave(void);
/* 1 = joined, with an address; why joining failed (ESPAT_JOIN_*, 0 = not failed) */
int32_t net_joined(void);
int32_t net_fail(void);
/* the joined network */
void net_info(ESPAT_NET *ps_net);
/* search for networks: how many were found, below 0 = failed; one of them */
int32_t net_scan(void);
void net_scan_item(int32_t i32_index, ESPAT_NET *ps_net);
/* a name's address as text: 0 = ok */
int32_t net_resolve(const char *pc_host, char *pc_ip);
/* a TCP connection on a link: ESPAT_OPEN_* */
int32_t net_open(int32_t i32_link, const char *pc_host, uint32_t ui32_port);
/* send on a link: 0 = ok */
int32_t net_send(int32_t i32_link, const uint8_t *pui8_data, uint32_t ui32_len);
/* bytes that wait on a link; take up to so many: the number taken */
int32_t net_avail(int32_t i32_link);
int32_t net_read(int32_t i32_link, uint8_t *pui8_data, int32_t i32_max);
/* 1 = the link's connection stands; close it */
int32_t net_up(int32_t i32_link);
void net_close(int32_t i32_link);
/* the network remembered for the next start (an empty name: none) */
void net_store_get(char *pc_ssid, char *pc_password);
void net_store_put(const char *pc_ssid, const char *pc_password);

/* the UART's use (espnet.cpp; called by the loader's task, done by the sketch's loop) */

/* 1 = the UART is the machine's (this module), 0 = the Bluetooth part's commands (the F3 menu); */
/* returns when the change is made */
void espnet_mode(int32_t i32_machine);
/* the machine was left: the Bluetooth part's commands again, the module as after power-up, radio off */
void espnet_stop(void);
/* 1 = the UART is the machine's */
int32_t espnet_machine(void);
/* the sketch's loop: the UART's bytes into the module, the module's work */
void espnet_poll(void);
/* console: a line for the module as if the machine had sent it; its answers also go to the USB port */
void espnet_console(const char *pc_line);
void espnet_trace(int32_t i32_on);
/* the sketch's console test: Bluetooth shut down and started again */
void btaudio_pause(void);
void btaudio_resume(void);
#ifdef ARDUINO
class Print;
/* console: the module's state */
void espnet_status(Print &r_out);
#endif

/* the module */

/* as after power-up: no connections, echo on, 115200 baud; the radio goes off */
void espat_reset(void);
/* a byte from the machine */
void espat_rx(uint8_t ui8_byte);
/* often: data that arrived, connections that ended, the radio off after a quiet time */
void espat_poll(void);
/* 1 = the radio is on */
int32_t espat_radio(void);
/* commands taken, bytes sent to the network and received from it, connections open now */
void espat_counts(uint32_t *pui32_commands, uint32_t *pui32_sent, uint32_t *pui32_received, int32_t *pi32_links);

#endif
