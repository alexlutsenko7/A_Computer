/* espnet.cpp -- LNext's Wi-Fi module (espat.cpp) on the ESP32: the network (Arduino WiFi), the */
/* remembered network (NVS, namespace "wifi") and the UART to the machine. */
/* */
/* The UART is the sketch's Serial2, the one the FPGA's loader uses for the F3 Bluetooth menu: */
/* in LNext the FPGA gives its pins to the Next's ESP UART while the machine word's bit 2 is set */
/* (LNext.v). The loader's task asks for the change with espnet_mode(); the sketch's loop makes */
/* it in espnet_poll() and, while the UART is the machine's, feeds the module from it. The */
/* Bluetooth part does not read or write the UART then (v2.ino). */
/* */
/* Wi-Fi and Bluetooth run together: the sketch sends all but the small memory blocks to the */
/* PSRAM (PSRAM_MALLOC_MIN in v2.ino), which leaves the internal memory for both. */
#include <Arduino.h>
#include <WiFi.h>
#include <Preferences.h>
#include <esp_heap_caps.h>
#include <esp_wifi.h>
#include <time.h>
#include <sys/time.h>
#include "espat.h"
#include "ftp.h"

/* flags as numbers */
#define YES 1
/* the UART's normal speed (the Bluetooth part's commands, the module after power-up) */
#define UART_BAUD 115200u
/* espnet_mode: the longest wait for the loop to make the change, and its step */
#define MODE_WAIT_MS 2000u
#define MODE_STEP_MS 1u
/* bytes taken from the UART in one pass of the loop */
#define RX_PER_PASS 2048
/* a TCP connection must stand within this time */
#define CONNECT_MS 5000
/* after a join was started its old result is not looked at for this long */
#define FAIL_GUARD_MS 500u
/* a failure that the radio's state showed from the join's start on (it may be the last join's) is */
/* believed after this time */
#define FAIL_STALE_MS 12000u
/* after the joining is stopped, the radio gets this long before a search or a new join */
#define SCAN_SETTLE_MS 200u
/* encryption as the AT firmware numbers it */
#define ECN_OPEN 0
#define ECN_WEP 1
#define ECN_WPA 2
/* WPA2, and both */
#define ECN_WPA2 3
#define ECN_WPA_WPA2 4
/* the clock from web servers: how many are tried in turn, their port */
#define TIME_HOSTS 3
#define HTTP_PORT 80
/* seconds and minutes */
#define SECONDS_PER_MINUTE 60
#define MINUTES_PER_HOUR 60
/* the offsets a time zone can have: UTC-12 to UTC+14 */
#define ZONE_MIN_S (-43200)
#define ZONE_MAX_S 50400
/* all tries together take at most this long; a try's connection gets at least this long */
#define TIME_TOTAL_MS 5000u
#define TIME_CONNECT_MIN_MS 300u
/* a header line of the answer; the parts of a "Date:" line; letters of a month's name */
#define TIME_LINE_BUF 128
#define DATE_PARTS 6
#define DATE_WORD 5
#define MONTH_LETTERS 3
#define MONTH_BUF 4
/* struct tm counts years from 1900 */
#define TM_YEAR_BASE 1900
/* a clock before this (2025-01-01 00:00 UTC) was never set */
#define CLOCK_SET_MIN 1735689600
/* the bytes of an address */
#define IP_BYTE_1 1
#define IP_BYTE_2 2
#define IP_BYTE_3 3

/* web servers asked for the time, in this order (plain HTTP; any answer carries the date) */
static const char *const g_apc_time_host[TIME_HOSTS] = { "www.google.com", "www.cloudflare.com", "www.microsoft.com" };
/* the months as a "Date:" line names them */
static const char g_ac_months[] = "JanFebMarAprMayJunJulAugSepOctNovDec";
/* the connections */
static WiFiClient g_as_client[ESPAT_LINKS];
/* the UART's use: wanted (set by the loader's task) and made (by the loop) */
static volatile int32_t g_i32_want;
static volatile int32_t g_i32_mode;
/* the machine was left; the module's answers also go to the USB port */
static volatile int32_t g_i32_stop;
static int32_t g_i32_trace;
/* the UART's speed while it is the machine's; when the last join was started */
static uint32_t g_ui32_baud = UART_BAUD;
static uint32_t g_ui32_begin_ms;
/* the time zone: its offset from UTC in seconds, how much of it the clock holds, the offset in the NVS, */
/* 1 = that one was read since power-up */
static int32_t g_i32_zone_s;
static int32_t g_i32_zone_in_clock;
static int32_t g_i32_zone_saved;
static bool g_b_zone_loaded;
/* since the last join was started the radio's state was seen without a failure in it */
static bool g_b_fail_fresh;
/* bytes from the machine and to it (console) */
static uint32_t g_ui32_rx_bytes;
static uint32_t g_ui32_tx_bytes;

/* the module's platform functions: the UART, the clock */

/* bytes to the machine */
void espat_out(const uint8_t *pui8_data, uint32_t ui32_len)
{
    if (g_i32_mode != 0)
    {
        Serial2.write(pui8_data, ui32_len);
        g_ui32_tx_bytes += ui32_len;
    }
/* the console's copy */
    if (g_i32_trace != 0)
    {
        Serial.write(pui8_data, ui32_len);
    }
}

/* the UART's speed from now on (after what was sent is out) */
void espat_baud(uint32_t ui32_baud)
{
    g_ui32_baud = ui32_baud;
    if (g_i32_mode != 0)
    {
        Serial2.flush();
        Serial2.updateBaudRate(ui32_baud);
    }
}

/* milliseconds since the start */
uint32_t espat_ms(void)
{
/* local variables */
    uint32_t ui32_ms;

    ui32_ms = millis();
    return ui32_ms;
}

/* wait */
void espat_wait(uint32_t ui32_ms)
{
    delay(ui32_ms);
}

/* the FTP server's clock (ftp.h) */
uint32_t ftp_ms(void)
{
/* local variables */
    uint32_t ui32_ms;

    ui32_ms = millis();
    return ui32_ms;
}

/* the module's platform functions: the network */

/* an address as text */
static void ip_text(IPAddress s_ip, char *pc_out)
{
    snprintf(pc_out, ESPAT_IP_BUF, "%u.%u.%u.%u", (unsigned)s_ip[0], (unsigned)s_ip[IP_BYTE_1],
             (unsigned)s_ip[IP_BYTE_2], (unsigned)s_ip[IP_BYTE_3]);
}

/* the radio on: 0 = ok */
int32_t net_on(void)
{
/* local variables */
    int32_t i32_result;

/* start values */
    i32_result = 0;
/* nothing of Wi-Fi's own goes into the flash; a lost network is joined again */
    WiFi.persistent(false);
    WiFi.setAutoReconnect(true);
    if (!WiFi.mode(WIFI_STA))
    {
        i32_result = -YES;
    }
    return i32_result;
}

/* the radio off */
void net_off(void)
{
/* local variables */
    int32_t i32_link;

/* start values */
    i32_link = 0;
    for (i32_link = 0; i32_link < ESPAT_LINKS; i32_link++)
    {
        g_as_client[i32_link].stop();
    }
/* the search's list, the network, the radio */
    WiFi.scanDelete();
    WiFi.disconnect(true, false);
    WiFi.mode(WIFI_OFF);
}

/* start joining a network (an empty password: an open one) */
void net_begin(const char *pc_ssid, const char *pc_password)
{
/* A network that is still being tried (one out of reach is tried again and again) must be let */
/* go first: the radio takes no new network while it is joining one. */
    WiFi.setAutoReconnect(false);
    WiFi.disconnect(false, false);
/* the library's call does nothing while no network is joined: the radio is told itself */
    (void)esp_wifi_disconnect();
    delay(SCAN_SETTLE_MS);
    WiFi.setAutoReconnect(true);
    if (pc_password[0] != 0)
    {
        WiFi.begin(pc_ssid, pc_password);
    }
    else
    {
/* an open network */
        WiFi.begin(pc_ssid);
    }
    g_ui32_begin_ms = millis();
    g_b_fail_fresh = false;
}

/* leave the network */
void net_leave(void)
{
    WiFi.disconnect(false, false);
}

/* 1 = joined, with an address */
int32_t net_joined(void)
{
/* local variables */
    int32_t i32_joined;

/* start values */
    i32_joined = 0;
    if (WiFi.status() == WL_CONNECTED)
    {
        i32_joined = YES;
    }
    return i32_joined;
}

/* why joining failed (ESPAT_JOIN_*, 0 = it has not failed) */
int32_t net_fail(void)
{
/* local variables */
    wl_status_t e_status;
    int32_t i32_code;

/* start values */
    e_status = WiFi.status();
    i32_code = 0;
/* The library keeps the last join's result until this join has one of its own: a failure counts */
/* only after the state was seen without one, or when it has stood for a long time. */
    if ((e_status != WL_NO_SSID_AVAIL) && (e_status != WL_CONNECT_FAILED))
    {
        g_b_fail_fresh = true;
    }
    if (((millis() - g_ui32_begin_ms) > FAIL_GUARD_MS) &&
        (g_b_fail_fresh || ((millis() - g_ui32_begin_ms) > FAIL_STALE_MS)))
    {
        if (e_status == WL_NO_SSID_AVAIL)
        {
            i32_code = ESPAT_JOIN_NO_AP;
        }
        else if (e_status == WL_CONNECT_FAILED)
        {
            i32_code = ESPAT_JOIN_PASSWORD;
        }
        else
        {
/* still trying, or joined */
        }
    }
    return i32_code;
}

/* the joined network */
void net_info(ESPAT_NET *ps_net)
{
    memset(ps_net, 0, sizeof *ps_net);
    strlcpy(ps_net->ac_ssid, WiFi.SSID().c_str(), sizeof ps_net->ac_ssid);
    strlcpy(ps_net->ac_bssid, WiFi.BSSIDstr().c_str(), sizeof ps_net->ac_bssid);
/* our addresses */
    ip_text(WiFi.localIP(), ps_net->ac_ip);
    ip_text(WiFi.gatewayIP(), ps_net->ac_gateway);
    ip_text(WiFi.subnetMask(), ps_net->ac_mask);
/* the name server, our MAC address */
    ip_text(WiFi.dnsIP(), ps_net->ac_dns);
    strlcpy(ps_net->ac_mac, WiFi.macAddress().c_str(), sizeof ps_net->ac_mac);
    ps_net->i32_channel = WiFi.channel();
    ps_net->i32_rssi = WiFi.RSSI();
}

/* search for networks: how many were found, below 0 = failed */
int32_t net_scan(void)
{
/* local variables */
    int32_t i32_count;
    bool b_idle;

/* start values */
    b_idle = WiFi.status() != WL_CONNECTED;
/* A radio that is trying to join (a network out of reach is tried again and again) cannot */
/* search: the trying is stopped for the search. A joined network stays. */
    if (b_idle)
    {
        WiFi.setAutoReconnect(false);
        WiFi.disconnect(false, false);
/* the library's call does nothing while no network is joined: the radio is told itself */
        (void)esp_wifi_disconnect();
        delay(SCAN_SETTLE_MS);
    }
    i32_count = WiFi.scanNetworks();
    if (b_idle)
    {
        WiFi.setAutoReconnect(true);
    }
    return i32_count;
}

/* one of the networks found */
void net_scan_item(int32_t i32_index, ESPAT_NET *ps_net)
{
/* local variables */
    wifi_auth_mode_t e_auth;

/* start values */
    e_auth = WiFi.encryptionType(i32_index);
    memset(ps_net, 0, sizeof *ps_net);
    strlcpy(ps_net->ac_ssid, WiFi.SSID(i32_index).c_str(), sizeof ps_net->ac_ssid);
    strlcpy(ps_net->ac_bssid, WiFi.BSSIDstr(i32_index).c_str(), sizeof ps_net->ac_bssid);
/* channel and strength */
    ps_net->i32_channel = WiFi.channel(i32_index);
    ps_net->i32_rssi = WiFi.RSSI(i32_index);
/* the encryption's number */
    ps_net->i32_ecn = ECN_WPA2;
    if (e_auth == WIFI_AUTH_OPEN)
    {
        ps_net->i32_ecn = ECN_OPEN;
    }
    else if (e_auth == WIFI_AUTH_WEP)
    {
        ps_net->i32_ecn = ECN_WEP;
    }
    else if (e_auth == WIFI_AUTH_WPA_PSK)
    {
        ps_net->i32_ecn = ECN_WPA;
    }
    else if (e_auth == WIFI_AUTH_WPA_WPA2_PSK)
    {
        ps_net->i32_ecn = ECN_WPA_WPA2;
    }
    else
    {
/* WPA2 and newer */
    }
}

/* a name's address as text: 0 = ok */
int32_t net_resolve(const char *pc_host, char *pc_ip)
{
/* local variables */
    IPAddress s_ip;
    int32_t i32_result;

/* start values */
    i32_result = -YES;
    pc_ip[0] = 0;
    if (WiFi.hostByName(pc_host, s_ip) == YES)
    {
        ip_text(s_ip, pc_ip);
        i32_result = 0;
    }
    return i32_result;
}

/* a TCP connection on a link: ESPAT_OPEN_* */
int32_t net_open(int32_t i32_link, const char *pc_host, uint32_t ui32_port)
{
/* local variables */
    IPAddress s_ip;
    int32_t i32_result;

/* start values */
    i32_result = ESPAT_OPEN_DNS;
    if (WiFi.hostByName(pc_host, s_ip) == YES)
    {
        i32_result = ESPAT_OPEN_FAIL;
/* the connection, without collecting small writes */
        if (g_as_client[i32_link].connect(s_ip, (uint16_t)ui32_port, CONNECT_MS) != 0)
        {
            g_as_client[i32_link].setNoDelay(true);
            i32_result = ESPAT_OPEN_OK;
        }
    }
    return i32_result;
}

/* send on a link: 0 = ok */
int32_t net_send(int32_t i32_link, const uint8_t *pui8_data, uint32_t ui32_len)
{
/* local variables */
    int32_t i32_result;

/* start values */
    i32_result = -YES;
    if (g_as_client[i32_link].write(pui8_data, ui32_len) == ui32_len)
    {
        i32_result = 0;
    }
    return i32_result;
}

/* bytes that wait on a link */
int32_t net_avail(int32_t i32_link)
{
/* local variables */
    int32_t i32_count;

    i32_count = g_as_client[i32_link].available();
    return i32_count;
}

/* take up to so many: the number taken */
int32_t net_read(int32_t i32_link, uint8_t *pui8_data, int32_t i32_max)
{
/* local variables */
    int32_t i32_count;

    i32_count = g_as_client[i32_link].read(pui8_data, (size_t)i32_max);
    return i32_count;
}

/* 1 = the link's connection stands */
int32_t net_up(int32_t i32_link)
{
/* local variables */
    int32_t i32_up;

/* start values */
    i32_up = 0;
    if (g_as_client[i32_link].connected())
    {
        i32_up = YES;
    }
    return i32_up;
}

/* close a link */
void net_close(int32_t i32_link)
{
    g_as_client[i32_link].stop();
}

/* the clock */

/* a header line "Date: Mon, 23 Nov 2026 16:40:12 GMT" as seconds since 1970 (UTC); 0 = not such a line */
static uint32_t date_seconds(const char *pc_line)
{
/* local variables */
    struct tm s_tm;
    char ac_month[MONTH_BUF];
    const char *pc_month;
/* day, year, hours, minutes, seconds */
    long al_part[DATE_PARTS - YES];
    uint32_t ui32_seconds;

/* start values */
    memset(&s_tm, 0, sizeof s_tm);
    pc_month = NULL;
    ui32_seconds = 0;
    if (strncasecmp(pc_line, "Date:", DATE_WORD) == 0)
    {
/* the day's name is passed over */
        if (sscanf(pc_line + DATE_WORD, " %*3s, %ld %3s %ld %ld:%ld:%ld", &al_part[0], ac_month, &al_part[IP_BYTE_1],
                   &al_part[IP_BYTE_2], &al_part[IP_BYTE_3], &al_part[DATE_PARTS - YES - YES]) == DATE_PARTS)
        {
            pc_month = strstr(g_ac_months, ac_month);
        }
    }
/* a month we know: the date as the C library's time (the ESP32's time zone is UTC) */
    if (pc_month != NULL)
    {
        s_tm.tm_mday = (int)al_part[0];
        s_tm.tm_mon = (int)((pc_month - g_ac_months) / MONTH_LETTERS);
        s_tm.tm_year = (int)al_part[IP_BYTE_1] - TM_YEAR_BASE;
/* the time of day */
        s_tm.tm_hour = (int)al_part[IP_BYTE_2];
        s_tm.tm_min = (int)al_part[IP_BYTE_3];
        s_tm.tm_sec = (int)al_part[DATE_PARTS - YES - YES];
        ui32_seconds = (uint32_t)mktime(&s_tm);
    }
    return ui32_seconds;
}

/* Ask a web server (plain HTTP) and look through its answer line by line, for at most so many */
/* milliseconds: the first value other than 0 that the line function gives, 0 = none. The line */
/* function gets each line and whether it is of the body (after the head's empty line). */
static uint32_t http_ask(const char *pc_host, const char *pc_request, uint32_t ui32_ms,
                         uint32_t (*pf_line)(const char *pc_line, int32_t i32_body))
{
/* local variables */
    WiFiClient s_client;
    char ac_line[TIME_LINE_BUF];
    uint32_t ui32_start;
    uint32_t ui32_value;
/* the line's length, a byte of the answer, 1 = the head is over */
    int32_t i32_len;
    int32_t i32_byte;
    int32_t i32_body;
    bool b_run;

/* start values */
    ui32_start = millis();
    ui32_value = 0;
    i32_len = 0;
    i32_byte = 0;
    i32_body = 0;
    b_run = false;
/* the request; the server closes the connection after its answer */
    if (s_client.connect(pc_host, HTTP_PORT, (int32_t)ui32_ms) != 0)
    {
        s_client.printf("%s HTTP/1.0\r\nHost: %s\r\nConnection: close\r\n\r\n", pc_request, pc_host);
        b_run = true;
    }
/* line by line until a value, the connection's end or the time's end */
    while (b_run)
    {
        i32_byte = s_client.read();
        if (i32_byte < 0)
        {
            b_run = s_client.connected() && ((millis() - ui32_start) < ui32_ms);
            delay(YES);
        }
        else if (i32_byte == '\n')
        {
/* a whole line; the empty one ends the head */
            ac_line[i32_len] = 0;
            ui32_value = pf_line(ac_line, i32_body);
            if (i32_len == 0)
            {
                i32_body = YES;
            }
            b_run = ui32_value == 0;
            i32_len = 0;
        }
        else if ((i32_byte != '\r') && (i32_len < (TIME_LINE_BUF - YES)))
        {
            ac_line[i32_len] = (char)i32_byte;
            i32_len++;
        }
        else
        {
/* a carriage return, or more than a line holds */
        }
    }
/* an answer may end without a line end */
    if ((ui32_value == 0) && (i32_len != 0))
    {
        ac_line[i32_len] = 0;
        ui32_value = pf_line(ac_line, i32_body);
    }
    s_client.stop();
    return ui32_value;
}

/* a line of an answer's head as the date it may carry (http_ask's line function) */
static uint32_t date_line(const char *pc_line, int32_t i32_body)
{
/* local variables */
    uint32_t ui32_seconds;

/* start values */
    ui32_seconds = 0;
    if (i32_body == 0)
    {
        ui32_seconds = date_seconds(pc_line);
    }
    return ui32_seconds;
}

/* what is left of a time span that began at a moment */
static uint32_t time_left(uint32_t ui32_start, uint32_t ui32_total)
{
/* local variables */
    uint32_t ui32_left;

/* start values */
    ui32_left = 0;
    if ((millis() - ui32_start) < ui32_total)
    {
        ui32_left = ui32_total - (millis() - ui32_start);
    }
    return ui32_left;
}

/* the clock from web servers: 0 = it is set (now, or already before), below 0 = no server answered */
int32_t net_time_sync(void)
{
/* local variables */
    struct timeval s_now;
    uint32_t ui32_seconds;
/* when the tries began, the time that is left */
    uint32_t ui32_start;
    uint32_t ui32_left;
    int32_t i32_host;
    int32_t i32_result;

/* start values */
    ui32_seconds = 0;
    ui32_start = millis();
    ui32_left = TIME_TOTAL_MS;
    i32_host = 0;
    i32_result = -YES;
/* a clock that was set keeps running until the power goes */
    if (time(NULL) >= CLOCK_SET_MIN)
    {
        i32_result = 0;
    }
/* the servers in turn, again and again, until one answers or the time is over */
    while ((i32_result != 0) && (ui32_left >= TIME_CONNECT_MIN_MS))
    {
        ui32_seconds = http_ask(g_apc_time_host[i32_host % TIME_HOSTS], "HEAD /", ui32_left, date_line);
        if (ui32_seconds >= CLOCK_SET_MIN)
        {
/* this one answered */
            s_now.tv_sec = (time_t)ui32_seconds;
            s_now.tv_usec = 0;
            settimeofday(&s_now, NULL);
            i32_result = 0;
        }
        i32_host++;
        ui32_left = time_left(ui32_start, TIME_TOTAL_MS);
    }
    return i32_result;
}

/* The time zone is the user's setting (the machine menu's FTP screen), kept in the NVS; never set: */
/* UTC. The clock itself is moved by the offset, so it shows local time and files get local dates, */
/* as the card's file system wants them. */

/* the clock is moved to the offset wanted (it holds g_i32_zone_in_clock of it already) */
static void zone_apply(void)
{
/* local variables */
    struct timeval s_now;

    if ((time(NULL) >= CLOCK_SET_MIN) && (g_i32_zone_in_clock != g_i32_zone_s))
    {
        s_now.tv_sec = time(NULL) + (g_i32_zone_s - g_i32_zone_in_clock);
        s_now.tv_usec = 0;
/* the clock holds this offset now */
        settimeofday(&s_now, NULL);
        g_i32_zone_in_clock = g_i32_zone_s;
    }
}

/* the remembered offset is read (once since power-up) and the clock moved to it; call after net_time_sync */
void net_zone_load(void)
{
/* local variables */
    Preferences s_prefs;

    if (!g_b_zone_loaded)
    {
/* read only; nothing remembered: UTC */
        if (s_prefs.begin("wifi", true))
        {
            g_i32_zone_s = s_prefs.getInt("zone", 0);
            s_prefs.end();
        }
        g_i32_zone_saved = g_i32_zone_s;
        g_b_zone_loaded = true;
    }
    zone_apply();
}

/* the offset from UTC in seconds */
int32_t net_zone_get(void)
{
/* local variables */
    int32_t i32_zone;

    i32_zone = g_i32_zone_s;
    return i32_zone;
}

/* the offset is changed by so many seconds, inside what a time zone can be; the clock follows */
void net_zone_step(int32_t i32_seconds)
{
/* local variables */
    int32_t i32_zone;

/* start values */
    i32_zone = g_i32_zone_s + i32_seconds;
    if ((i32_zone >= ZONE_MIN_S) && (i32_zone <= ZONE_MAX_S))
    {
        g_i32_zone_s = i32_zone;
        zone_apply();
    }
}

/* the offset is remembered for the next power-up (written only when it changed) */
void net_zone_save(void)
{
/* local variables */
    Preferences s_prefs;

    if (g_b_zone_loaded && (g_i32_zone_s != g_i32_zone_saved))
    {
        if (s_prefs.begin("wifi", false))
        {
            s_prefs.putInt("zone", g_i32_zone_s);
            s_prefs.end();
            g_i32_zone_saved = g_i32_zone_s;
        }
    }
}

/* the clock as text with its offset from UTC ("2026-11-23 11:40 UTC-5"); empty while it is not set */
void net_time_text(char *pc_text)
{
/* local variables */
    struct tm s_tm;
    time_t s_now;
    int32_t i32_minutes;
    int32_t i32_len;

/* start values */
    s_now = time(NULL);
    i32_minutes = g_i32_zone_s / SECONDS_PER_MINUTE;
    i32_len = 0;
    pc_text[0] = 0;
    if (s_now >= CLOCK_SET_MIN)
    {
        localtime_r(&s_now, &s_tm);
        i32_len = snprintf(pc_text, NET_TIME_BUF, "%04d-%02d-%02d %02d:%02d UTC", s_tm.tm_year + TM_YEAR_BASE,
                           s_tm.tm_mon + YES, s_tm.tm_mday, s_tm.tm_hour, s_tm.tm_min);
/* the offset: hours, and minutes where a zone has them */
        if (i32_minutes != 0)
        {
            i32_len += snprintf(pc_text + i32_len, NET_TIME_BUF - i32_len, "%c%d", (i32_minutes < 0) ? '-' : '+',
                                (int)(abs(i32_minutes) / MINUTES_PER_HOUR));
            if ((abs(i32_minutes) % MINUTES_PER_HOUR) != 0)
            {
                snprintf(pc_text + i32_len, NET_TIME_BUF - i32_len, ":%02d", (int)(abs(i32_minutes) % MINUTES_PER_HOUR));
            }
        }
    }
}

/* the network remembered for the next start (an empty name: none) */
void net_store_get(char *pc_ssid, char *pc_password)
{
/* local variables */
    Preferences s_prefs;

    pc_ssid[0] = 0;
    pc_password[0] = 0;
/* read only */
    if (s_prefs.begin("wifi", true))
    {
        strlcpy(pc_ssid, s_prefs.getString("ssid", "").c_str(), ESPAT_SSID_BUF);
        strlcpy(pc_password, s_prefs.getString("pass", "").c_str(), ESPAT_PASS_BUF);
        s_prefs.end();
    }
}

/* remember a network */
void net_store_put(const char *pc_ssid, const char *pc_password)
{
/* local variables */
    Preferences s_prefs;

    if (s_prefs.begin("wifi", false))
    {
        s_prefs.putString("ssid", pc_ssid);
        s_prefs.putString("pass", pc_password);
        s_prefs.end();
    }
}

/* the UART's use */

/* 1 = the UART is the machine's, 0 = the Bluetooth part's commands; returns when the change is made */
void espnet_mode(int32_t i32_machine)
{
/* local variables */
    uint32_t ui32_start;

/* start values */
    ui32_start = millis();
    g_i32_want = i32_machine;
/* the loop makes it; a loop that is busy with the network is not waited for */
    while ((g_i32_mode != i32_machine) && ((millis() - ui32_start) < MODE_WAIT_MS))
    {
        delay(MODE_STEP_MS);
    }
}

/* the machine was left */
void espnet_stop(void)
{
    g_i32_want = 0;
    g_i32_stop = YES;
}

/* 1 = the UART is the machine's */
int32_t espnet_machine(void)
{
/* local variables */
    int32_t i32_machine;

    i32_machine = g_i32_mode;
    return i32_machine;
}

/* the sketch's loop: the UART's use, its bytes into the module, the module's work */
void espnet_poll(void)
{
/* local variables */
    int32_t i32_want;
    int32_t i32_count;

/* start values */
    i32_want = g_i32_want;
    i32_count = 0;
    if (i32_want != g_i32_mode)
    {
/* what was sent goes out at the old speed; what came in belongs to the old use */
        Serial2.flush();
        if (g_ui32_baud != UART_BAUD)
        {
            Serial2.updateBaudRate((i32_want != 0) ? g_ui32_baud : UART_BAUD);
        }
        while (Serial2.available())
        {
            (void)Serial2.read();
        }
        g_i32_mode = i32_want;
    }
/* the machine was left: the module as after power-up, the radio off */
    if (g_i32_stop != 0)
    {
        g_i32_stop = 0;
        espat_reset();
        g_ui32_baud = UART_BAUD;
    }
    if (g_i32_mode != 0)
    {
/* the machine's bytes */
        while ((i32_count < RX_PER_PASS) && Serial2.available())
        {
            espat_rx((uint8_t)Serial2.read());
            i32_count++;
        }
        g_ui32_rx_bytes += (uint32_t)i32_count;
    }
/* the module's work; from the console it can be tried without the machine */
    if ((g_i32_mode != 0) || (g_i32_trace != 0))
    {
        espat_poll();
    }
}

/* console: a line for the module as if the machine had sent it */
void espnet_console(const char *pc_line)
{
    while (*pc_line != 0)
    {
        espat_rx((uint8_t)*pc_line);
        pc_line++;
    }
/* the line's end */
    espat_rx('\r');
    espat_rx('\n');
}

/* console: the module's answers also go to the USB port */
void espnet_trace(int32_t i32_on)
{
    g_i32_trace = i32_on;
}

/* console: the module's state */
void espnet_status(Print &r_out)
{
/* local variables */
    ESPAT_NET s_net;
    uint32_t ui32_commands;
    uint32_t ui32_sent;
/* bytes from the network, open links */
    uint32_t ui32_received;
    int32_t i32_links;

/* start values */
    ui32_commands = 0;
    ui32_sent = 0;
    ui32_received = 0;
    i32_links = 0;
    espat_counts(&ui32_commands, &ui32_sent, &ui32_received, &i32_links);
    r_out.printf("wifi module (LNext): uart=%s %u baud, from the machine %u bytes, to it %u, commands %u\r\n",
                 (g_i32_mode != 0) ? "machine" : "bluetooth menu", (unsigned)g_ui32_baud, (unsigned)g_ui32_rx_bytes,
                 (unsigned)g_ui32_tx_bytes, (unsigned)ui32_commands);
/* the radio and the network */
    if (espat_radio() == 0)
    {
        r_out.print("   radio off\r\n");
    }
    else if (net_joined() == 0)
    {
        r_out.print("   radio on, no network joined\r\n");
    }
    else
    {
        net_info(&s_net);
        r_out.printf("   radio on, network \"%s\" channel %d, %d dBm, address %s, links %d, sent %u, received %u\r\n",
                     s_net.ac_ssid, (int)s_net.i32_channel, (int)s_net.i32_rssi, s_net.ac_ip, (int)i32_links,
                     (unsigned)ui32_sent, (unsigned)ui32_received);
    }
/* the memory both radios share */
    r_out.printf("   internal heap free %u, largest block %u\r\n",
                 (unsigned)heap_caps_get_free_size(MALLOC_CAP_8BIT | MALLOC_CAP_INTERNAL),
                 (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_8BIT | MALLOC_CAP_INTERNAL));
}
