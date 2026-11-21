/* espat.cpp -- LNext: the ESP32 as the Spectrum Next's Wi-Fi module (see espat.h). */
/* */
/* The Next's network programs (.http, .nxtp, NXtel, the ESPAT driver, WIFI.BAS ...) send the */
/* ESP8266 AT firmware's commands and read its answers. This file answers the ones they use: */
/*   AT  ATE0/1  AT+GMR  AT+RST  AT+RESTORE  AT+UART / _CUR / _DEF (the speed really changes) */
/*   AT+CWMODE  AT+CWJAP (join, remembered)  AT+CWQAP  AT+CWLAP  AT+CWAUTOCONN */
/*   AT+CIFSR  AT+CIPSTA?  AT+CIPDNS?  AT+CIPSTATUS  AT+CIPDOMAIN */
/*   AT+CIPMUX  AT+CIPSTART (TCP)  AT+CIPSEND=n  AT+CIPCLOSE, received data as +IPD */
/* Not there (answered with ERROR): UDP, SSL, the server mode, the transparent mode, fixed */
/* addresses, the module's own firmware update. */
/* */
/* The radio is off until the machine sends its first command; then it joins the remembered */
/* network without being asked, as the real module does at power-up. It goes off again after */
/* RADIO_IDLE_MS without a byte from the machine and without a connection (Bluetooth audio is */
/* off while the radio is on, see espnet.cpp). */
#include <stdio.h>
#include <string.h>
#include "espat.h"

/* flags as numbers */
#define YES 1
/* the command line, the data of one send or one +IPD, a line of an answer */
#define LINE_BUF 256
#define DATA_MAX 2048
#define TEXT_BUF 192
/* received data goes to the machine in pieces of so many bytes */
#define IPD_MAX 1024
/* the speed after power-up and its limits */
#define BAUD_DEFAULT 115200u
#define BAUD_MIN 1200u
#define BAUD_MAX 2000000u
/* joining a network: the longest wait for a join that was asked for, for one that runs when a */
/* connection is wanted, and the step of the waiting */
#define JOIN_MS 15000u
#define JOIN_BUSY_MS 10000u
#define JOIN_STEP_MS 50u
/* data of a send that does not arrive: the send is given up */
#define SEND_IDLE_MS 30000u
/* the radio goes off after this long without a byte from the machine */
#define RADIO_IDLE_MS 60000u
/* AT+CWMODE: station; the highest value taken */
#define MODE_STATION 1
#define MODE_MAX 3
/* AT+CIPSTATUS: joined, a connection is open, not joined */
#define STATUS_JOINED 2
#define STATUS_LINKED 3
#define STATUS_NO_AP 5
/* AT+CIPCLOSE: this link number closes all */
#define LINK_ALL ESPAT_LINKS
/* no link */
#define LINK_NONE (-1)
/* the suffix of a command's name: _CUR, _DEF */
#define SUFFIX_LEN 4
/* decimal */
#define TEN 10u
/* the two letters every command starts with */
#define AT_LEN 2
/* cmd_addresses: AT+CIFSR is 0, AT+CIPSTA?, AT+CIPDNS? */
#define WHAT_STA 1
#define WHAT_DNS 2

/* the command line; the data of a send or of a +IPD; an answer's line */
static char g_ac_line[LINE_BUF];
static uint8_t g_aui8_data[DATA_MAX];
static char g_ac_text[TEXT_BUF];
/* the command's name as it was typed (after AT, to the = or ?), for the answers */
static char g_ac_name[LINE_BUF];
/* the links: open */
static int32_t g_ai32_open[ESPAT_LINKS];
/* characters of the line so far */
static int32_t g_i32_line_len;
/* echo, several links, AT+CWMODE's value */
static int32_t g_i32_echo = YES;
static int32_t g_i32_mux;
static int32_t g_i32_mode = MODE_STATION;
/* the radio is on; a join was started */
static int32_t g_i32_radio;
static int32_t g_i32_joining;
/* a send: its link (LINK_NONE: none), its length, the bytes there */
static int32_t g_i32_send_link = LINK_NONE;
static uint32_t g_ui32_send_len;
static uint32_t g_ui32_send_got;
/* the UART's speed; when the last byte came */
static uint32_t g_ui32_baud = BAUD_DEFAULT;
static uint32_t g_ui32_rx_ms;
/* counters for the console */
static uint32_t g_ui32_commands;
static uint32_t g_ui32_sent;
static uint32_t g_ui32_received;

/* text to the machine */
static void out(const char *pc_text)
{
    espat_out((const uint8_t *)pc_text, (uint32_t)strlen(pc_text));
}

/* the two usual endings */
static void out_ok(void)
{
    out("\r\nOK\r\n");
}

/* a command that failed or is not known */
static void out_error(void)
{
    out("\r\nERROR\r\n");
}

/* "0," before a link's message when several links are allowed */
static void out_link(int32_t i32_link)
{
    if (g_i32_mux != 0)
    {
        snprintf(g_ac_text, sizeof g_ac_text, "%d,", (int)i32_link);
        out(g_ac_text);
    }
}

/* links open now */
static int32_t links_open(void)
{
/* local variables */
    int32_t i32_link;
    int32_t i32_count;

/* start values */
    i32_link = 0;
    i32_count = 0;
    for (i32_link = 0; i32_link < ESPAT_LINKS; i32_link++)
    {
        if (g_ai32_open[i32_link] != 0)
        {
            i32_count++;
        }
    }
    return i32_count;
}

/* close every link, without a message */
static void close_all(void)
{
/* local variables */
    int32_t i32_link;

/* start values */
    i32_link = 0;
    for (i32_link = 0; i32_link < ESPAT_LINKS; i32_link++)
    {
        if (g_ai32_open[i32_link] != 0)
        {
/* this one */
            net_close(i32_link);
            g_ai32_open[i32_link] = 0;
        }
    }
    g_i32_send_link = LINK_NONE;
}

/* the radio on, and the remembered network joined in the background */
static void radio_need(void)
{
/* local variables */
    char ac_ssid[ESPAT_SSID_BUF];
    char ac_password[ESPAT_PASS_BUF];

    if (g_i32_radio == 0)
    {
/* on, if the platform can */
        if (net_on() == 0)
        {
            g_i32_radio = YES;
            g_i32_joining = 0;
/* the network of the last AT+CWJAP */
            net_store_get(ac_ssid, ac_password);
            if (ac_ssid[0] != 0)
            {
                net_begin(ac_ssid, ac_password);
                g_i32_joining = YES;
            }
        }
    }
}

/* wait until the network is joined, the join failed or the time is over: 1 = joined */
static int32_t join_wait(uint32_t ui32_ms)
{
/* local variables */
    uint32_t ui32_start;
    int32_t i32_joined;

/* start values */
    ui32_start = espat_ms();
    i32_joined = net_joined();
    while ((i32_joined == 0) && (net_fail() == 0) && ((espat_ms() - ui32_start) < ui32_ms))
    {
/* a little later */
        espat_wait(JOIN_STEP_MS);
        i32_joined = net_joined();
    }
    return i32_joined;
}

/* a number at the text's start: 1 = there was one; the text moves behind it */
static int32_t get_number(const char **ppc_text, uint32_t *pui32_value)
{
/* local variables */
    const char *pc_text;
    uint32_t ui32_value;
    int32_t i32_found;

/* start values */
    pc_text = *ppc_text;
    ui32_value = 0;
    i32_found = 0;
/* digit by digit */
    while ((*pc_text >= '0') && (*pc_text <= '9'))
    {
        ui32_value = (ui32_value * TEN) + (uint32_t)(*pc_text - '0');
        pc_text++;
        i32_found = YES;
    }
/* where it ended, what it was */
    *ppc_text = pc_text;
    *pui32_value = ui32_value;
    return i32_found;
}

/* a text in quotes at the text's start (\" \, \\ are the characters themselves): 1 = there was */
/* one and it fits; the text moves behind it */
static int32_t get_text(const char **ppc_text, char *pc_out, int32_t i32_size)
{
/* local variables */
    const char *pc_text;
    int32_t i32_len;
    int32_t i32_found;

/* start values */
    pc_text = *ppc_text;
    i32_len = 0;
    i32_found = 0;
    if (*pc_text == '"')
    {
        pc_text++;
        i32_found = YES;
/* to the closing quote */
        while ((*pc_text != '"') && (*pc_text != 0))
        {
/* an escaped character */
            if ((*pc_text == '\\') && (pc_text[YES] != 0))
            {
                pc_text++;
            }
            if (i32_len < (i32_size - YES))
            {
/* kept */
                pc_out[i32_len] = *pc_text;
                i32_len++;
            }
            else
            {
/* too long */
                i32_found = 0;
            }
            pc_text++;
        }
/* the closing quote must be there */
        if (*pc_text == '"')
        {
            pc_text++;
        }
        else
        {
            i32_found = 0;
        }
    }
/* terminated */
    pc_out[i32_len] = 0;
    *ppc_text = pc_text;
    return i32_found;
}

/* a comma at the text's start: 1 = there was one; the text moves behind it */
static int32_t get_comma(const char **ppc_text)
{
/* local variables */
    int32_t i32_found;

/* start values */
    i32_found = 0;
    if (**ppc_text == ',')
    {
        (*ppc_text)++;
        i32_found = YES;
    }
    return i32_found;
}

/* a link number at the start of the arguments when several links are allowed (then it must be */
/* there, with its comma): the link, LINK_NONE = wrong */
static int32_t get_link(const char **ppc_text)
{
/* local variables */
    uint32_t ui32_value;
    int32_t i32_link;

/* start values */
    ui32_value = 0;
    i32_link = 0;
    if (g_i32_mux != 0)
    {
        i32_link = LINK_NONE;
/* the number and the comma behind it */
        if ((get_number(ppc_text, &ui32_value) != 0) && (ui32_value < ESPAT_LINKS) && (get_comma(ppc_text) != 0))
        {
            i32_link = (int32_t)ui32_value;
        }
    }
    return i32_link;
}

/* AT+RST, and the start: the module's state after power-up; the radio stays as it is */
static void module_start(void)
{
    close_all();
    g_i32_echo = YES;
    g_i32_mux = 0;
/* station mode, an empty line */
    g_i32_mode = MODE_STATION;
    g_i32_line_len = 0;
    if (g_ui32_baud != BAUD_DEFAULT)
    {
/* the speed too */
        g_ui32_baud = BAUD_DEFAULT;
        espat_baud(BAUD_DEFAULT);
    }
}

/* AT+RST: the answer, the restart, and the lines the module prints while it starts */
static void cmd_reset(void)
{
    out_ok();
    module_start();
    out("\r\nready\r\n");
/* the remembered network, as the real module joins it after a restart */
    radio_need();
    if ((g_i32_joining != 0) && (join_wait(JOIN_BUSY_MS) != 0))
    {
        out("WIFI CONNECTED\r\nWIFI GOT IP\r\n");
    }
}

/* AT+UART=<speed>,...: the answer at the old speed, then the new one */
static void cmd_uart(const char *pc_args)
{
/* local variables */
    uint32_t ui32_baud;

/* start values */
    ui32_baud = 0;
    if ((get_number(&pc_args, &ui32_baud) != 0) && (ui32_baud >= BAUD_MIN) && (ui32_baud <= BAUD_MAX))
    {
        out_ok();
        g_ui32_baud = ui32_baud;
        espat_baud(ui32_baud);
    }
    else
    {
        out_error();
    }
}

/* AT+CWJAP="name","password": join, and remember the network when it is not the _CUR form */
static void cmd_join(const char *pc_args, int32_t i32_keep)
{
/* local variables */
    char ac_ssid[ESPAT_SSID_BUF];
    char ac_password[ESPAT_PASS_BUF];
    int32_t i32_code;

/* start values */
    i32_code = 0;
    if ((get_text(&pc_args, ac_ssid, sizeof ac_ssid) != 0) && (get_comma(&pc_args) != 0) &&
        (get_text(&pc_args, ac_password, sizeof ac_password) != 0))
    {
        radio_need();
        if (g_i32_radio != 0)
        {
/* the connections of the old network end */
            close_all();
            net_begin(ac_ssid, ac_password);
            g_i32_joining = YES;
        }
        if ((g_i32_radio != 0) && (join_wait(JOIN_MS) != 0))
        {
            out("WIFI CONNECTED\r\nWIFI GOT IP\r\n");
            out_ok();
/* for the next start */
            if (i32_keep != 0)
            {
                net_store_put(ac_ssid, ac_password);
            }
        }
        else
        {
/* why not */
            i32_code = net_fail();
            if (i32_code == 0)
            {
                i32_code = ESPAT_JOIN_TIMEOUT;
            }
            snprintf(g_ac_text, sizeof g_ac_text, "+CWJAP:%d\r\n\r\nFAIL\r\n", (int)i32_code);
            out(g_ac_text);
        }
    }
    else
    {
        out_error();
    }
}

/* AT+CWJAP?: the joined network */
static void cmd_joined(void)
{
/* local variables */
    ESPAT_NET s_net;

    radio_need();
/* a join that runs is waited for */
    if ((g_i32_joining != 0) && (join_wait(JOIN_BUSY_MS) != 0))
    {
        net_info(&s_net);
        snprintf(g_ac_text, sizeof g_ac_text, "%s:\"%s\",\"%s\",%d,%d\r\n", g_ac_name, s_net.ac_ssid, s_net.ac_bssid,
                 (int)s_net.i32_channel, (int)s_net.i32_rssi);
        out(g_ac_text);
    }
    else
    {
        out("No AP\r\n");
    }
    out_ok();
}

/* AT+CWLAP: the networks in reach */
static void cmd_scan(void)
{
/* local variables */
    ESPAT_NET s_net;
    int32_t i32_count;
    int32_t i32_index;

/* start values */
    i32_count = 0;
    i32_index = 0;
    radio_need();
    if (g_i32_radio != 0)
    {
        i32_count = net_scan();
    }
    else
    {
        i32_count = LINK_NONE;
    }
/* one line each */
    if (i32_count >= 0)
    {
        for (i32_index = 0; i32_index < i32_count; i32_index++)
        {
            net_scan_item(i32_index, &s_net);
            snprintf(g_ac_text, sizeof g_ac_text, "+CWLAP:(%d,\"%s\",%d,\"%s\",%d)\r\n", (int)s_net.i32_ecn, s_net.ac_ssid,
                     (int)s_net.i32_rssi, s_net.ac_bssid, (int)s_net.i32_channel);
            out(g_ac_text);
        }
        out_ok();
    }
    else
    {
        out_error();
    }
}

/* AT+CIFSR, AT+CIPSTA?, AT+CIPDNS?: our addresses (zeros while no network is joined) */
static void cmd_addresses(int32_t i32_what)
{
/* local variables */
    ESPAT_NET s_net;

    radio_need();
/* a join that runs is waited for */
    if (g_i32_joining != 0)
    {
        (void)join_wait(JOIN_BUSY_MS);
    }
    net_info(&s_net);
    if (i32_what == 0)
    {
/* AT+CIFSR */
        snprintf(g_ac_text, sizeof g_ac_text, "+CIFSR:STAIP,\"%s\"\r\n+CIFSR:STAMAC,\"%s\"\r\n", s_net.ac_ip, s_net.ac_mac);
    }
    else if (i32_what == WHAT_STA)
    {
/* AT+CIPSTA? */
        snprintf(g_ac_text, sizeof g_ac_text, "%s:ip:\"%s\"\r\n%s:gateway:\"%s\"\r\n%s:netmask:\"%s\"\r\n", g_ac_name,
                 s_net.ac_ip, g_ac_name, s_net.ac_gateway, g_ac_name, s_net.ac_mask);
    }
    else
    {
/* AT+CIPDNS? */
        snprintf(g_ac_text, sizeof g_ac_text, "%s:%s\r\n", g_ac_name, s_net.ac_dns);
    }
    out(g_ac_text);
    out_ok();
}

/* AT+CIPSTATUS */
static void cmd_status(void)
{
/* local variables */
    int32_t i32_status;

/* start values */
    i32_status = STATUS_NO_AP;
    if ((g_i32_radio != 0) && (net_joined() != 0))
    {
        i32_status = STATUS_JOINED;
/* with a connection */
        if (links_open() != 0)
        {
            i32_status = STATUS_LINKED;
        }
    }
    snprintf(g_ac_text, sizeof g_ac_text, "STATUS:%d\r\n", (int)i32_status);
    out(g_ac_text);
    out_ok();
}

/* AT+CIPDOMAIN="name": its address */
static void cmd_domain(const char *pc_args)
{
/* local variables */
    char ac_host[TEXT_BUF];
    char ac_ip[ESPAT_IP_BUF];
    int32_t i32_ok;

/* start values */
    i32_ok = get_text(&pc_args, ac_host, sizeof ac_host);
    if (i32_ok != 0)
    {
        radio_need();
        i32_ok = ((g_i32_joining != 0) && (join_wait(JOIN_BUSY_MS) != 0)) ? YES : 0;
    }
/* asked */
    if ((i32_ok != 0) && (net_resolve(ac_host, ac_ip) == 0))
    {
        snprintf(g_ac_text, sizeof g_ac_text, "+CIPDOMAIN:%s\r\n", ac_ip);
        out(g_ac_text);
        out_ok();
    }
    else
    {
        out("DNS Fail\r\n");
        out_error();
    }
}

/* AT+CIPSTART=[link,]"TCP","host",port */
static void cmd_open(const char *pc_args)
{
/* local variables */
    char ac_type[ESPAT_IP_BUF];
    char ac_host[TEXT_BUF];
    uint32_t ui32_port;
/* the link, the result of the connection, the arguments are right */
    int32_t i32_link;
    int32_t i32_result;
    int32_t i32_ok;

/* start values */
    ui32_port = 0;
    i32_link = get_link(&pc_args);
    i32_result = ESPAT_OPEN_FAIL;
    i32_ok = 0;
/* the arguments: type, host, port */
    if (i32_link != LINK_NONE)
    {
        i32_ok = get_text(&pc_args, ac_type, sizeof ac_type);
    }
    if (i32_ok != 0)
    {
        i32_ok = ((get_comma(&pc_args) != 0) && (get_text(&pc_args, ac_host, sizeof ac_host) != 0)) ? YES : 0;
    }
/* the port */
    if (i32_ok != 0)
    {
        i32_ok = ((get_comma(&pc_args) != 0) && (get_number(&pc_args, &ui32_port) != 0)) ? YES : 0;
    }
/* TCP only */
    if ((i32_ok != 0) && (strcmp(ac_type, "TCP") != 0))
    {
        i32_ok = 0;
    }
    if (i32_ok == 0)
    {
        out_error();
    }
    else if (g_ai32_open[i32_link] != 0)
    {
/* the link is in use */
        out("ALREADY CONNECTED\r\n");
        out_error();
    }
    else
    {
/* the network must be there; a join that runs is waited for */
        radio_need();
        if ((g_i32_joining == 0) || (join_wait(JOIN_BUSY_MS) == 0))
        {
            out("no ip\r\n");
            out_error();
        }
        else
        {
            i32_result = net_open(i32_link, ac_host, ui32_port);
            if (i32_result == ESPAT_OPEN_OK)
            {
/* connected */
                g_ai32_open[i32_link] = YES;
                out_link(i32_link);
                out("CONNECT\r\n");
                out_ok();
            }
            else if (i32_result == ESPAT_OPEN_DNS)
            {
/* no such name */
                out("DNS Fail\r\n");
                out_error();
            }
            else
            {
/* nobody answers there */
                out_error();
                out_link(i32_link);
                out("CLOSED\r\n");
            }
        }
    }
}

/* AT+CIPSEND=[link,]length: the prompt; the data follows (espat_rx) */
static void cmd_send(const char *pc_args)
{
/* local variables */
    uint32_t ui32_len;
    int32_t i32_link;

/* start values */
    ui32_len = 0;
    i32_link = get_link(&pc_args);
    if ((i32_link == LINK_NONE) || (get_number(&pc_args, &ui32_len) == 0) || (ui32_len == 0) || (ui32_len > DATA_MAX))
    {
        out_error();
    }
    else if (g_ai32_open[i32_link] == 0)
    {
/* nothing is connected there */
        out("link is not valid\r\n");
        out_error();
    }
    else
    {
/* the data may come */
        g_i32_send_link = i32_link;
        g_ui32_send_len = ui32_len;
        g_ui32_send_got = 0;
        out_ok();
        out("> ");
    }
}

/* the data of a send is complete: out it goes */
static void send_now(void)
{
/* local variables */
    int32_t i32_link;

/* start values */
    i32_link = g_i32_send_link;
    g_i32_send_link = LINK_NONE;
    snprintf(g_ac_text, sizeof g_ac_text, "\r\nRecv %u bytes\r\n", (unsigned)g_ui32_send_len);
    out(g_ac_text);
/* sent, or the connection is gone */
    if ((g_ai32_open[i32_link] != 0) && (net_send(i32_link, g_aui8_data, g_ui32_send_len) == 0))
    {
        g_ui32_sent += g_ui32_send_len;
        out("\r\nSEND OK\r\n");
    }
    else
    {
        out("\r\nSEND FAIL\r\n");
    }
}

/* one link closed, with its message */
static void close_link(int32_t i32_link)
{
    net_close(i32_link);
    g_ai32_open[i32_link] = 0;
/* said */
    out_link(i32_link);
    out("CLOSED\r\n");
}

/* AT+CIPCLOSE, AT+CIPCLOSE=link (link 5: all) */
static void cmd_close(const char *pc_args, int32_t i32_has_args)
{
/* local variables */
    uint32_t ui32_value;
    int32_t i32_link;
    int32_t i32_closed;

/* start values */
    ui32_value = 0;
    i32_link = 0;
    i32_closed = 0;
/* which link */
    if (g_i32_mux != 0)
    {
        i32_link = LINK_NONE;
        if ((i32_has_args != 0) && (get_number(&pc_args, &ui32_value) != 0) && (ui32_value <= LINK_ALL))
        {
            i32_link = (int32_t)ui32_value;
        }
    }
    if (i32_link == LINK_ALL)
    {
/* all of them */
        for (i32_link = 0; i32_link < ESPAT_LINKS; i32_link++)
        {
            if (g_ai32_open[i32_link] != 0)
            {
                close_link(i32_link);
            }
        }
        i32_closed = YES;
    }
    else if ((i32_link != LINK_NONE) && (g_ai32_open[i32_link] != 0))
    {
/* this one */
        close_link(i32_link);
        i32_closed = YES;
    }
    else
    {
/* nothing to close */
    }
    if (i32_closed != 0)
    {
        out_ok();
    }
    else
    {
        out_error();
    }
}

/* a value of 0 .. max for a setting: 1 = taken */
static int32_t set_value(const char *pc_args, uint32_t ui32_max, int32_t *pi32_value)
{
/* local variables */
    uint32_t ui32_value;
    int32_t i32_ok;

/* start values */
    ui32_value = 0;
    i32_ok = 0;
    if ((get_number(&pc_args, &ui32_value) != 0) && (ui32_value <= ui32_max))
    {
        *pi32_value = (int32_t)ui32_value;
        i32_ok = YES;
    }
    return i32_ok;
}

/* the answer to a query of a setting: its name as typed and the value */
static void out_value(int32_t i32_value)
{
    snprintf(g_ac_text, sizeof g_ac_text, "%s:%d\r\n", g_ac_name, (int)i32_value);
    out(g_ac_text);
    out_ok();
}

/* the commands of the network: 1 = it was one of them. pc_base is the name without _CUR / _DEF, */
/* c_kind '?' a query, '=' a setting with arguments, 0 neither; i32_keep: not the _CUR form */
static int32_t run_network(const char *pc_base, char c_kind, const char *pc_args, int32_t i32_keep)
{
/* local variables */
    int32_t i32_known;
    int32_t i32_value;

/* start values */
    i32_known = YES;
    i32_value = 0;
    if ((strcmp(pc_base, "+CWJAP") == 0) && (c_kind == '='))
    {
        cmd_join(pc_args, i32_keep);
    }
    else if ((strcmp(pc_base, "+CWJAP") == 0) && (c_kind == '?'))
    {
        cmd_joined();
    }
    else if ((strcmp(pc_base, "+CWQAP") == 0) && (c_kind == 0))
    {
/* leave the network */
        close_all();
        net_leave();
        g_i32_joining = 0;
        out_ok();
        out("WIFI DISCONNECT\r\n");
    }
    else if ((strcmp(pc_base, "+CWLAP") == 0) && (c_kind == 0))
    {
        cmd_scan();
    }
    else if ((strcmp(pc_base, "+CIFSR") == 0) && (c_kind == 0))
    {
        cmd_addresses(0);
    }
    else if ((strcmp(pc_base, "+CIPSTA") == 0) && (c_kind == '?'))
    {
        cmd_addresses(WHAT_STA);
    }
    else if ((strcmp(pc_base, "+CIPDNS") == 0) && (c_kind == '?'))
    {
        cmd_addresses(WHAT_DNS);
    }
    else if ((strcmp(pc_base, "+CIPDNS") == 0) && (c_kind == '='))
    {
/* only "automatic" can be set */
        if ((set_value(pc_args, 0, &i32_value) != 0))
        {
            out_ok();
        }
        else
        {
            out_error();
        }
    }
    else if ((strcmp(pc_base, "+CIPSTATUS") == 0) && (c_kind == 0))
    {
        cmd_status();
    }
    else if ((strcmp(pc_base, "+CIPDOMAIN") == 0) && (c_kind == '='))
    {
        cmd_domain(pc_args);
    }
    else if ((strcmp(pc_base, "+CIPSTART") == 0) && (c_kind == '='))
    {
        cmd_open(pc_args);
    }
    else if ((strcmp(pc_base, "+CIPSEND") == 0) && (c_kind == '='))
    {
        cmd_send(pc_args);
    }
    else if ((strcmp(pc_base, "+CIPCLOSE") == 0) && (c_kind != '?'))
    {
        cmd_close(pc_args, (c_kind == '=') ? YES : 0);
    }
    else
    {
/* not one of these */
        i32_known = 0;
    }
    return i32_known;
}

/* the commands of the module itself: 1 = it was one of them */
static int32_t run_module(const char *pc_base, char c_kind, const char *pc_args)
{
/* local variables */
    int32_t i32_known;
    int32_t i32_value;

/* start values */
    i32_known = YES;
    i32_value = 0;
    if ((pc_base[0] == 0) && (c_kind == 0))
    {
/* AT */
        out_ok();
    }
    else if (((strcmp(pc_base, "E0") == 0) || (strcmp(pc_base, "E1") == 0)) && (c_kind == 0))
    {
/* echo off, on */
        g_i32_echo = (pc_base[YES] == '1') ? YES : 0;
        out_ok();
    }
    else if ((strcmp(pc_base, "+GMR") == 0) && (c_kind == 0))
    {
/* line for line the text of the ESP8266 AT firmware 1.7.4: programs take it apart (NXtel hung on */
/* a text of our own here) */
        out("AT version:1.7.4.0(May 11 2020 19:13:04)\r\nSDK version:3.0.4(9532ceb)\r\n");
        out("compile time:May 27 2020 10:12:17\r\nBin version(Wroom 02):1.7.4\r\nOK\r\n");
    }
    else if ((strcmp(pc_base, "+RST") == 0) && (c_kind == 0))
    {
        cmd_reset();
    }
    else if ((strcmp(pc_base, "+RESTORE") == 0) && (c_kind == 0))
    {
/* the remembered network is forgotten too */
        net_store_put("", "");
        net_leave();
        g_i32_joining = 0;
        cmd_reset();
    }
    else if (((strcmp(pc_base, "+UART") == 0) || (strcmp(pc_base, "+CIOBAUD") == 0)) && (c_kind == '='))
    {
        cmd_uart(pc_args);
    }
    else if (((strcmp(pc_base, "+UART") == 0) || (strcmp(pc_base, "+CIOBAUD") == 0)) && (c_kind == '?'))
    {
/* 8 data bits, 1 stop bit, no parity, no flow control */
        snprintf(g_ac_text, sizeof g_ac_text, "%s:%u,8,1,0,0\r\n", g_ac_name, (unsigned)g_ui32_baud);
        out(g_ac_text);
        out_ok();
    }
    else if ((strcmp(pc_base, "+CWMODE") == 0) && (c_kind == '?'))
    {
        out_value(g_i32_mode);
    }
    else if ((strcmp(pc_base, "+CWMODE") == 0) && (c_kind == '='))
    {
/* 1 to 3 are taken; the module is a station in all of them */
        if ((set_value(pc_args, MODE_MAX, &i32_value) != 0) && (i32_value != 0))
        {
            g_i32_mode = i32_value;
            out_ok();
        }
        else
        {
            out_error();
        }
    }
    else if ((strcmp(pc_base, "+CIPMUX") == 0) && (c_kind == '?'))
    {
        out_value(g_i32_mux);
    }
    else if ((strcmp(pc_base, "+CIPMUX") == 0) && (c_kind == '='))
    {
/* not while a connection is open */
        if ((links_open() == 0) && (set_value(pc_args, YES, &i32_value) != 0))
        {
            g_i32_mux = i32_value;
            out_ok();
        }
        else
        {
            out_error();
        }
    }
    else if ((strcmp(pc_base, "+CWAUTOCONN") == 0) && (c_kind == '?'))
    {
        out_value(YES);
    }
    else if (((strcmp(pc_base, "+CIPMODE") == 0) || (strcmp(pc_base, "+CIPRECVMODE") == 0)) && (c_kind == '?'))
    {
        out_value(0);
    }
    else if (((strcmp(pc_base, "+CIPMODE") == 0) || (strcmp(pc_base, "+CIPRECVMODE") == 0)) && (c_kind == '='))
    {
/* only the normal mode */
        if ((set_value(pc_args, 0, &i32_value) != 0))
        {
            out_ok();
        }
        else
        {
            out_error();
        }
    }
    else if (((strcmp(pc_base, "+CWAUTOCONN") == 0) || (strcmp(pc_base, "+CIPDINFO") == 0) ||
              (strcmp(pc_base, "+CIPSTO") == 0) || (strcmp(pc_base, "+SLEEP") == 0) ||
              (strcmp(pc_base, "+RFPOWER") == 0)) && (c_kind == '='))
    {
/* settings that change nothing here */
        out_ok();
    }
    else
    {
/* not one of these */
        i32_known = 0;
    }
    return i32_known;
}

/* a complete command line (without its line end) */
static void run_line(void)
{
/* local variables */
    char ac_base[LINE_BUF];
    const char *pc_args;
    char c_kind;
/* lengths of the name; not the _CUR form; the command is known */
    int32_t i32_len;
    int32_t i32_keep;
    int32_t i32_known;

/* start values */
    pc_args = "";
    c_kind = 0;
    i32_len = 0;
    i32_keep = YES;
    i32_known = 0;
    if ((g_ac_line[0] == 'A') && (g_ac_line[YES] == 'T'))
    {
        g_ui32_commands++;
/* the name: to the = or ? */
        while ((g_ac_line[i32_len + AT_LEN] != 0) && (g_ac_line[i32_len + AT_LEN] != '=') &&
               (g_ac_line[i32_len + AT_LEN] != '?'))
        {
            g_ac_name[i32_len] = g_ac_line[i32_len + AT_LEN];
            i32_len++;
        }
        g_ac_name[i32_len] = 0;
/* a query, or a setting with its arguments */
        c_kind = g_ac_line[i32_len + AT_LEN];
        if (c_kind != 0)
        {
            pc_args = &g_ac_line[i32_len + AT_LEN + YES];
        }
/* the name without _CUR / _DEF */
        strcpy(ac_base, g_ac_name);
        if ((i32_len > SUFFIX_LEN) && (strcmp(&ac_base[i32_len - SUFFIX_LEN], "_CUR") == 0))
        {
            ac_base[i32_len - SUFFIX_LEN] = 0;
            i32_keep = 0;
        }
        else if ((i32_len > SUFFIX_LEN) && (strcmp(&ac_base[i32_len - SUFFIX_LEN], "_DEF") == 0))
        {
            ac_base[i32_len - SUFFIX_LEN] = 0;
        }
        else
        {
/* no suffix */
        }
        i32_known = run_module(ac_base, c_kind, pc_args);
        if (i32_known == 0)
        {
            i32_known = run_network(ac_base, c_kind, pc_args, i32_keep);
        }
    }
/* anything else */
    if (i32_known == 0)
    {
        out_error();
    }
}

/* as after power-up: no connections, echo on, 115200 baud; the radio goes off */
void espat_reset(void)
{
    module_start();
    if (g_i32_radio != 0)
    {
        net_off();
        g_i32_radio = 0;
    }
    g_i32_joining = 0;
}

/* a byte from the machine */
void espat_rx(uint8_t ui8_byte)
{
    g_ui32_rx_ms = espat_ms();
    if (g_i32_send_link != LINK_NONE)
    {
/* the data of a send */
        g_aui8_data[g_ui32_send_got] = ui8_byte;
        g_ui32_send_got++;
        if (g_ui32_send_got == g_ui32_send_len)
        {
            send_now();
        }
    }
    else
    {
/* a command's character, echoed */
        if (g_i32_echo != 0)
        {
            espat_out(&ui8_byte, YES);
        }
        if (ui8_byte == '\n')
        {
/* the line is complete; an empty one is nothing */
            g_ac_line[g_i32_line_len] = 0;
            g_i32_line_len = 0;
            if (g_ac_line[0] != 0)
            {
                run_line();
            }
        }
        else if (ui8_byte == '\r')
        {
/* the line feed follows */
        }
        else if (g_i32_line_len < (LINE_BUF - YES))
        {
            g_ac_line[g_i32_line_len] = (char)ui8_byte;
            g_i32_line_len++;
        }
        else
        {
/* too long: the line will be an unknown command */
        }
    }
}

/* often: data that arrived, connections that ended, the radio off after a quiet time */
void espat_poll(void)
{
/* local variables */
    int32_t i32_link;
    int32_t i32_count;

/* start values */
    i32_link = 0;
    i32_count = 0;
    if (g_i32_send_link != LINK_NONE)
    {
/* a send whose data does not come is given up */
        if ((espat_ms() - g_ui32_rx_ms) > SEND_IDLE_MS)
        {
            g_i32_send_link = LINK_NONE;
            out_error();
        }
    }
    else if (g_i32_radio != 0)
    {
        for (i32_link = 0; i32_link < ESPAT_LINKS; i32_link++)
        {
            if (g_ai32_open[i32_link] != 0)
            {
/* what arrived, a piece at a time */
                i32_count = net_avail(i32_link);
                if (i32_count > IPD_MAX)
                {
                    i32_count = IPD_MAX;
                }
                if (i32_count > 0)
                {
                    i32_count = net_read(i32_link, g_aui8_data, i32_count);
                }
/* to the machine: +IPD,[link,]length:data */
                if (i32_count > 0)
                {
                    g_ui32_received += (uint32_t)i32_count;
                    out("\r\n+IPD,");
                    out_link(i32_link);
                    snprintf(g_ac_text, sizeof g_ac_text, "%d:", (int)i32_count);
                    out(g_ac_text);
                    espat_out(g_aui8_data, (uint32_t)i32_count);
                }
                else if (net_up(i32_link) == 0)
                {
/* the other side closed, and everything was read */
                    close_link(i32_link);
                }
                else
                {
/* nothing new */
                }
            }
        }
/* nobody uses the radio */
        if ((links_open() == 0) && ((espat_ms() - g_ui32_rx_ms) > RADIO_IDLE_MS))
        {
            net_off();
            g_i32_radio = 0;
            g_i32_joining = 0;
        }
    }
    else
    {
/* the radio is off: nothing to do */
    }
}

/* 1 = the radio is on */
int32_t espat_radio(void)
{
/* local variables */
    int32_t i32_radio;

    i32_radio = g_i32_radio;
    return i32_radio;
}

/* commands taken, bytes sent to the network and received from it, connections open now */
void espat_counts(uint32_t *pui32_commands, uint32_t *pui32_sent, uint32_t *pui32_received, int32_t *pi32_links)
{
    *pui32_commands = g_ui32_commands;
    *pui32_sent = g_ui32_sent;
/* from the network, open links */
    *pui32_received = g_ui32_received;
    *pi32_links = links_open();
}
