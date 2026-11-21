/* espat_test.cpp -- PC test of LNext's Wi-Fi module (ESP32/v2/src/espat.cpp, compiled as C++) */
/* */
/* The platform is a model here: the UART's output is collected, the clock is a counter, and the */
/* network knows one access point ("home", password "secret12"), three hosts (server.test */
/* answers, dead.test does not, any other name is unknown) and keeps what is sent on a link and */
/* what the test puts there to be received. The test plays a Next program: */
/*   the module's own commands, echo, an unknown command */
/*   a search, joining with a wrong password, an unknown network, the right one (remembered) */
/*   a connection: open, send, receive in pieces, the other side closes */
/*   several links (AT+CIPMUX=1) */
/*   the UART's speed, AT+RST */
/*   the radio goes off after a quiet minute and comes back, with the network, for the next command */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
/* the code under test */
#include "../../../ESP32/v2/src/espat.h"

/* flags as numbers */
#define YES 1
/* the module's output kept for a check */
#define OUT_BUF 16384
/* bytes kept per link in each direction */
#define LINK_BUF 8192
/* the model's network: joining takes this long, a failure shows after this long */
#define JOIN_TAKES_MS 800u
#define FAIL_TAKES_MS 400u
/* networks a search finds */
#define SCAN_COUNT 2
/* the test's data: a send, a received block and its pieces */
#define SEND_LEN 5
#define RX_LEN 3000
#define PIECE 1024
#define PIECE_LAST 952
/* the byte pattern of the received block */
#define PAT_MUL 7
#define PAT_ADD 3
#define BYTE_MASK 0xFF
/* the link used with several links */
#define MUX_LINK 2
#define MUX_SEND 3
/* speeds */
#define BAUD_DEFAULT 115200u
#define BAUD_OTHER 57600u
/* the quiet time after which the radio goes off, with a margin */
#define QUIET_MS 61000u
/* a text buffer */
#define TEXT_BUF 64
/* the encryption of the networks found: WPA2 */
#define ECN_WPA2 3

/* the module's output */
static char g_ac_out[OUT_BUF];
/* the model's links: bytes sent by the module, bytes to be received by it */
static uint8_t g_aui8_tx[ESPAT_LINKS][LINK_BUF];
static uint8_t g_aui8_rx[ESPAT_LINKS][LINK_BUF];
/* the remembered network; the one being joined */
static char g_ac_store_ssid[ESPAT_SSID_BUF];
static char g_ac_store_pass[ESPAT_PASS_BUF];
static char g_ac_ssid[ESPAT_SSID_BUF];
static char g_ac_pass[ESPAT_PASS_BUF];
/* per link: connected, bytes sent, bytes waiting, bytes already read */
static int32_t g_ai32_up[ESPAT_LINKS];
static int32_t g_ai32_tx_len[ESPAT_LINKS];
static int32_t g_ai32_rx_len[ESPAT_LINKS];
static int32_t g_ai32_rx_pos[ESPAT_LINKS];
/* the output's length; the clock; the UART's speed */
static int32_t g_i32_out_len;
static uint32_t g_ui32_ms;
static uint32_t g_ui32_baud = BAUD_DEFAULT;
/* the radio is on; a join runs since; how often the radio went on */
static int32_t g_i32_radio;
static int32_t g_i32_begun;
static uint32_t g_ui32_begin_ms;
static int32_t g_i32_radio_ons;
/* failed checks */
static int32_t g_i32_errors;

/* the platform: the UART and the clock */

/* bytes to the machine */
void espat_out(const uint8_t *pui8_data, uint32_t ui32_len)
{
    if ((g_i32_out_len + (int32_t)ui32_len) < (OUT_BUF - YES))
    {
        memcpy(&g_ac_out[g_i32_out_len], pui8_data, ui32_len);
        g_i32_out_len += (int32_t)ui32_len;
        g_ac_out[g_i32_out_len] = 0;
    }
}

/* the UART's speed */
void espat_baud(uint32_t ui32_baud)
{
    g_ui32_baud = ui32_baud;
}

/* the clock */
uint32_t espat_ms(void)
{
/* local variables */
    uint32_t ui32_ms;

    ui32_ms = g_ui32_ms;
    return ui32_ms;
}

/* waiting moves the clock */
void espat_wait(uint32_t ui32_ms)
{
    g_ui32_ms += ui32_ms;
}

/* the platform: the network */

/* the radio on */
int32_t net_on(void)
{
/* local variables */
    int32_t i32_result;

    i32_result = 0;
    g_i32_radio = YES;
    g_i32_begun = 0;
    g_i32_radio_ons++;
    return i32_result;
}

/* the radio off: every connection ends */
void net_off(void)
{
    g_i32_radio = 0;
    g_i32_begun = 0;
    memset(g_ai32_up, 0, sizeof g_ai32_up);
}

/* start joining */
void net_begin(const char *pc_ssid, const char *pc_password)
{
    strcpy(g_ac_ssid, pc_ssid);
    strcpy(g_ac_pass, pc_password);
    g_i32_begun = YES;
    g_ui32_begin_ms = g_ui32_ms;
}

/* leave */
void net_leave(void)
{
    g_i32_begun = 0;
}

/* joined: the right network, the right password, after its time */
int32_t net_joined(void)
{
/* local variables */
    int32_t i32_joined;

/* start values */
    i32_joined = 0;
    if ((g_i32_radio != 0) && (g_i32_begun != 0) && (strcmp(g_ac_ssid, "home") == 0) &&
        (strcmp(g_ac_pass, "secret12") == 0) && ((g_ui32_ms - g_ui32_begin_ms) >= JOIN_TAKES_MS))
    {
        i32_joined = YES;
    }
    return i32_joined;
}

/* why joining failed */
int32_t net_fail(void)
{
/* local variables */
    int32_t i32_code;

/* start values */
    i32_code = 0;
    if ((g_i32_begun != 0) && ((g_ui32_ms - g_ui32_begin_ms) >= FAIL_TAKES_MS))
    {
        if (strcmp(g_ac_ssid, "home") != 0)
        {
            i32_code = ESPAT_JOIN_NO_AP;
        }
        else if (strcmp(g_ac_pass, "secret12") != 0)
        {
            i32_code = ESPAT_JOIN_PASSWORD;
        }
        else
        {
/* the right one: it will join */
        }
    }
    return i32_code;
}

/* the joined network */
void net_info(ESPAT_NET *ps_net)
{
    memset(ps_net, 0, sizeof *ps_net);
    strcpy(ps_net->ac_ssid, "home");
    strcpy(ps_net->ac_bssid, "aa:bb:cc:dd:ee:ff");
/* addresses only when joined */
    strcpy(ps_net->ac_ip, (net_joined() != 0) ? "192.168.1.77" : "0.0.0.0");
    strcpy(ps_net->ac_gateway, "192.168.1.1");
    strcpy(ps_net->ac_mask, "255.255.255.0");
/* the rest */
    strcpy(ps_net->ac_dns, "192.168.1.1");
    strcpy(ps_net->ac_mac, "11:22:33:44:55:66");
    ps_net->i32_channel = SCAN_COUNT;
    ps_net->i32_rssi = -SCAN_COUNT;
}

/* a search */
int32_t net_scan(void)
{
/* local variables */
    int32_t i32_count;

    i32_count = SCAN_COUNT;
    return i32_count;
}

/* one of the networks found */
void net_scan_item(int32_t i32_index, ESPAT_NET *ps_net)
{
    memset(ps_net, 0, sizeof *ps_net);
    strcpy(ps_net->ac_ssid, (i32_index == 0) ? "home" : "other");
    strcpy(ps_net->ac_bssid, "aa:bb:cc:dd:ee:ff");
    ps_net->i32_channel = i32_index + YES;
/* WPA2 */
    ps_net->i32_ecn = ECN_WPA2;
}

/* the hosts the model knows */
int32_t net_resolve(const char *pc_host, char *pc_ip)
{
/* local variables */
    int32_t i32_result;

/* start values */
    i32_result = -YES;
    pc_ip[0] = 0;
    if ((strcmp(pc_host, "server.test") == 0) || (strcmp(pc_host, "dead.test") == 0))
    {
        strcpy(pc_ip, "10.0.0.5");
        i32_result = 0;
    }
    return i32_result;
}

/* a connection */
int32_t net_open(int32_t i32_link, const char *pc_host, uint32_t ui32_port)
{
/* local variables */
    char ac_ip[ESPAT_IP_BUF];
    int32_t i32_result;

/* start values */
    i32_result = ESPAT_OPEN_DNS;
    (void)ui32_port;
    if (net_resolve(pc_host, ac_ip) == 0)
    {
        i32_result = ESPAT_OPEN_FAIL;
/* only one host answers */
        if (strcmp(pc_host, "server.test") == 0)
        {
            g_ai32_up[i32_link] = YES;
            g_ai32_tx_len[i32_link] = 0;
            g_ai32_rx_len[i32_link] = 0;
            g_ai32_rx_pos[i32_link] = 0;
            i32_result = ESPAT_OPEN_OK;
        }
    }
    return i32_result;
}

/* sent bytes are kept */
int32_t net_send(int32_t i32_link, const uint8_t *pui8_data, uint32_t ui32_len)
{
/* local variables */
    int32_t i32_result;

/* start values */
    i32_result = -YES;
    if ((g_ai32_up[i32_link] != 0) && ((g_ai32_tx_len[i32_link] + (int32_t)ui32_len) <= LINK_BUF))
    {
        memcpy(&g_aui8_tx[i32_link][g_ai32_tx_len[i32_link]], pui8_data, ui32_len);
        g_ai32_tx_len[i32_link] += (int32_t)ui32_len;
        i32_result = 0;
    }
    return i32_result;
}

/* bytes that wait */
int32_t net_avail(int32_t i32_link)
{
/* local variables */
    int32_t i32_count;

    i32_count = g_ai32_rx_len[i32_link] - g_ai32_rx_pos[i32_link];
    return i32_count;
}

/* take some */
int32_t net_read(int32_t i32_link, uint8_t *pui8_data, int32_t i32_max)
{
/* local variables */
    int32_t i32_count;

/* start values */
    i32_count = net_avail(i32_link);
    if (i32_count > i32_max)
    {
        i32_count = i32_max;
    }
    memcpy(pui8_data, &g_aui8_rx[i32_link][g_ai32_rx_pos[i32_link]], (size_t)i32_count);
    g_ai32_rx_pos[i32_link] += i32_count;
    return i32_count;
}

/* the connection stands */
int32_t net_up(int32_t i32_link)
{
/* local variables */
    int32_t i32_up;

    i32_up = g_ai32_up[i32_link];
    return i32_up;
}

/* close */
void net_close(int32_t i32_link)
{
    g_ai32_up[i32_link] = 0;
}

/* the remembered network */
void net_store_get(char *pc_ssid, char *pc_password)
{
    strcpy(pc_ssid, g_ac_store_ssid);
    strcpy(pc_password, g_ac_store_pass);
}

/* remember one */
void net_store_put(const char *pc_ssid, const char *pc_password)
{
    strcpy(g_ac_store_ssid, pc_ssid);
    strcpy(g_ac_store_pass, pc_password);
}

/* the test */

/* a line from the machine, with its line end; the output starts empty */
static void say(const char *pc_line)
{
    g_i32_out_len = 0;
    g_ac_out[0] = 0;
    while (*pc_line != 0)
    {
        espat_rx((uint8_t)*pc_line);
        pc_line++;
    }
/* the line's end */
    espat_rx('\r');
    espat_rx('\n');
}

/* a check: said when it fails */
static void check(int32_t i32_ok, const char *pc_what)
{
    if (i32_ok == 0)
    {
        g_i32_errors++;
        printf("  FAIL: %s\n  output: [%s]\n", pc_what, g_ac_out);
    }
}

/* the output holds a text */
static int32_t has(const char *pc_text)
{
/* local variables */
    int32_t i32_found;

/* start values */
    i32_found = 0;
    if (strstr(g_ac_out, pc_text) != NULL)
    {
        i32_found = YES;
    }
    return i32_found;
}

/* the module's own commands */
static void test_module(void)
{
    say("AT");
    check(has("AT\r\n") && has("\r\nOK\r\n"), "AT: echo and OK");
    say("ATE0");
    check(has("OK"), "ATE0");
/* no echo from here on */
    say("AT");
    check((strcmp(g_ac_out, "\r\nOK\r\n") == 0) ? YES : 0, "AT without echo");
    say("AT+GMR");
    check(has("AT version:") && has("OK"), "AT+GMR");
/* settings */
    say("AT+CWMODE=1");
    check(has("OK"), "AT+CWMODE=1");
    say("AT+CWMODE_CUR?");
    check(has("+CWMODE_CUR:1"), "AT+CWMODE_CUR?");
/* things that are not there */
    say("AT+NOSUCH");
    check(has("ERROR"), "an unknown command");
    say("hello");
    check(has("ERROR"), "a line that is no command");
    say("AT+CIPMODE=1");
    check(has("ERROR"), "the transparent mode is refused");
    check((g_i32_radio == 0) ? YES : 0, "the radio is still off");
}

/* searching and joining */
static void test_join(void)
{
    say("AT+CWJAP?");
    check(has("No AP") && has("OK"), "AT+CWJAP? without a network");
    check((g_i32_radio != 0) ? YES : 0, "the radio is on after a network command");
    say("AT+CWLAP");
    check(has("+CWLAP:(3,\"home\"") && has("\"other\"") && has("OK"), "AT+CWLAP");
/* a wrong password, an unknown network */
    say("AT+CWJAP=\"home\",\"wrong\"");
    check(has("+CWJAP:2") && has("FAIL"), "a wrong password");
    say("AT+CWJAP=\"nowhere\",\"secret12\"");
    check(has("+CWJAP:3") && has("FAIL"), "an unknown network");
    check((g_ac_store_ssid[0] == 0) ? YES : 0, "a failed join is not remembered");
/* the right one */
    say("AT+CWJAP=\"home\",\"secret12\"");
    check(has("WIFI GOT IP") && has("\r\nOK\r\n"), "joining");
    check((strcmp(g_ac_store_ssid, "home") == 0) ? YES : 0, "the network is remembered");
    say("AT+CWJAP?");
    check(has("+CWJAP:\"home\",\"aa:bb:cc:dd:ee:ff\""), "AT+CWJAP? with a network");
/* our addresses */
    say("AT+CIFSR");
    check(has("+CIFSR:STAIP,\"192.168.1.77\""), "AT+CIFSR");
    say("AT+CIPSTA?");
    check(has("+CIPSTA:gateway:\"192.168.1.1\""), "AT+CIPSTA?");
    say("AT+CIPSTATUS");
    check(has("STATUS:2"), "AT+CIPSTATUS");
}

/* one connection: open, send, receive, closed by the other side */
static void test_link(void)
{
/* local variables */
    char ac_text[TEXT_BUF];
    const char *pc_piece;
    int32_t i32_index;
    int32_t i32_ok;

/* start values */
    pc_piece = NULL;
    i32_index = 0;
    i32_ok = YES;
    say("AT+CIPSTART=\"UDP\",\"server.test\",80");
    check(has("ERROR"), "UDP is refused");
    say("AT+CIPSTART=\"TCP\",\"unknown.test\",80");
    check(has("DNS Fail") && has("ERROR"), "an unknown host");
/* a host that does not answer, one that does */
    say("AT+CIPSTART=\"TCP\",\"dead.test\",80");
    check(has("ERROR") && has("CLOSED"), "a host that does not answer");
    say("AT+CIPSTART=\"TCP\",\"server.test\",80");
    check(has("CONNECT\r\n") && has("\r\nOK\r\n"), "a connection");
    say("AT+CIPSTART=\"TCP\",\"server.test\",80");
    check(has("ALREADY CONNECTED"), "a second connection on the link");
/* a send */
    say("AT+CIPSEND=5");
    check(has("OK") && has("> "), "the send prompt");
    g_i32_out_len = 0;
    g_ac_out[0] = 0;
    for (i32_index = 0; i32_index < SEND_LEN; i32_index++)
    {
        espat_rx((uint8_t)("HELLO"[i32_index]));
    }
    check(has("Recv 5 bytes") && has("SEND OK"), "the send's end");
    check(((g_ai32_tx_len[0] == SEND_LEN) && (memcmp(g_aui8_tx[0], "HELLO", SEND_LEN) == 0)) ? YES : 0, "the bytes sent");
/* 3000 bytes arrive: three pieces */
    for (i32_index = 0; i32_index < RX_LEN; i32_index++)
    {
        g_aui8_rx[0][i32_index] = (uint8_t)(((i32_index * PAT_MUL) + PAT_ADD) & BYTE_MASK);
    }
    g_ai32_rx_len[0] = RX_LEN;
    g_i32_out_len = 0;
    espat_poll();
/* the first piece: its header and its bytes */
    snprintf(ac_text, sizeof ac_text, "\r\n+IPD,%d:", PIECE);
    check((strncmp(g_ac_out, ac_text, strlen(ac_text)) == 0) ? YES : 0, "the first +IPD header");
    pc_piece = &g_ac_out[strlen(ac_text)];
    i32_ok = ((g_i32_out_len == (int32_t)(strlen(ac_text) + PIECE)) && (memcmp(pc_piece, g_aui8_rx[0], PIECE) == 0)) ? YES : 0;
    check(i32_ok, "the first piece's bytes");
/* the others */
    g_i32_out_len = 0;
    espat_poll();
    espat_poll();
    snprintf(ac_text, sizeof ac_text, "+IPD,%d:", PIECE_LAST);
    check((g_i32_out_len == (int32_t)((PIECE + PIECE_LAST) + (strlen("\r\n+IPD,1024:") + strlen(ac_text) + strlen("\r\n")))) ? YES : 0,
          "the other two pieces' length");
    check((g_ai32_rx_pos[0] == RX_LEN) ? YES : 0, "everything was read");
/* the other side closes */
    g_ai32_up[0] = 0;
    g_i32_out_len = 0;
    g_ac_out[0] = 0;
    espat_poll();
    check((strcmp(g_ac_out, "CLOSED\r\n") == 0) ? YES : 0, "closed by the other side");
    say("AT+CIPSEND=5");
    check(has("link is not valid"), "no send on a closed link");
}

/* several links */
static void test_mux(void)
{
/* local variables */
    int32_t i32_index;

/* start values */
    i32_index = 0;
    say("AT+CIPMUX=1");
    check(has("OK"), "AT+CIPMUX=1");
    say("AT+CIPSTART=\"TCP\",\"server.test\",23");
    check(has("ERROR"), "a link number is needed now");
    say("AT+CIPSTART=2,\"TCP\",\"server.test\",23");
    check(has("2,CONNECT"), "a connection on link 2");
/* not while a link is open */
    say("AT+CIPMUX=0");
    check(has("ERROR"), "AT+CIPMUX with a link open");
    say("AT+CIPSEND=2,3");
    check(has("> "), "the send prompt on link 2");
    for (i32_index = 0; i32_index < MUX_SEND; i32_index++)
    {
        espat_rx((uint8_t)("abc"[i32_index]));
    }
    check(((g_ai32_tx_len[MUX_LINK] == MUX_SEND) && has("SEND OK")) ? YES : 0, "the send on link 2");
/* received there */
    memcpy(g_aui8_rx[MUX_LINK], "xyz", MUX_SEND);
    g_ai32_rx_len[MUX_LINK] = MUX_SEND;
    g_i32_out_len = 0;
    g_ac_out[0] = 0;
    espat_poll();
    check((strcmp(g_ac_out, "\r\n+IPD,2,3:xyz") == 0) ? YES : 0, "+IPD with the link number");
    say("AT+CIPSTATUS");
    check(has("STATUS:3"), "AT+CIPSTATUS with a link");
/* closed by the machine */
    say("AT+CIPCLOSE=2");
    check(has("2,CLOSED") && has("OK") && (g_ai32_up[MUX_LINK] == 0), "AT+CIPCLOSE=2");
    say("AT+CIPCLOSE=2");
    check(has("ERROR"), "closing a closed link");
    say("AT+CIPMUX=0");
    check(has("OK"), "AT+CIPMUX=0");
}

/* the UART's speed, the restart, the quiet time */
static void test_rest(void)
{
/* local variables */
    int32_t i32_ons;

/* start values */
    i32_ons = 0;
    say("AT+UART_CUR=57600,8,1,0,0");
    check((has("OK") && (g_ui32_baud == BAUD_OTHER)) ? YES : 0, "AT+UART_CUR");
    say("AT+UART_CUR?");
    check(has("+UART_CUR:57600,8,1,0,0"), "AT+UART_CUR?");
    say("AT+UART=5,8,1,0,0");
    check(has("ERROR"), "a speed that is too low");
/* the restart: the default speed, echo on again, the network joined again */
    say("AT+RST");
    check(has("OK") && has("ready") && has("WIFI GOT IP") && (g_ui32_baud == BAUD_DEFAULT), "AT+RST");
    say("AT");
    check(has("AT\r\n"), "echo is on after AT+RST");
    say("ATE0");
/* a quiet minute: the radio goes off */
    g_ui32_ms += QUIET_MS;
    espat_poll();
    check((g_i32_radio == 0) ? YES : 0, "the radio is off after a quiet minute");
    i32_ons = g_i32_radio_ons;
/* the next connection brings it back, with the remembered network */
    say("AT+CIPSTART=\"TCP\",\"server.test\",80");
    check((has("CONNECT") && (g_i32_radio != 0) && (g_i32_radio_ons == (i32_ons + YES))) ? YES : 0,
          "the radio and the network come back for a connection");
/* a link keeps the radio on */
    g_ui32_ms += QUIET_MS;
    espat_poll();
    check((g_i32_radio != 0) ? YES : 0, "an open link keeps the radio on");
    say("AT+CIPCLOSE");
    check(has("CLOSED") && has("OK"), "AT+CIPCLOSE");
/* the machine is left */
    espat_reset();
    check((g_i32_radio == 0) ? YES : 0, "the radio is off after a reset");
}

int main(void)
{
/* local variables */
    int32_t i32_result;

/* start values */
    i32_result = 0;
    test_module();
    test_join();
    test_link();
    test_mux();
    test_rest();
/* the result */
    printf("  errors %d\n", (int)g_i32_errors);
    if (g_i32_errors == 0)
    {
        printf("  RESULT: PASS\n");
    }
    else
    {
        printf("  RESULT: FAIL\n");
        i32_result = YES;
    }
    return i32_result;
}
