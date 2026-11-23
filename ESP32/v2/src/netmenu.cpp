/* netmenu.cpp -- the machine menu's F4 screens: the SD card over Wi-Fi (netmenu.h). */
/* */
/* The network: the one remembered (the same one LNext's Wi-Fi uses, espnet.cpp) is joined; */
/* without one, or when joining fails, the networks in reach are listed, one is chosen and its */
/* password typed. Then the card's file system is mounted and the FTP server (ftp.cpp) runs: */
/* the screen shows the address to open on the computer and what the server does. Leaving the */
/* screen stops the server, unmounts the card and switches the radio off. */
/* */
/* All of it runs in the loader's task, which is also the only user of the card. No machine */
/* runs meanwhile (the menu takes no keys while the OSD is on), so nothing else needs the card. */
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
/* texts; the FPGA's registers, the screen */
#include <string.h>
#include "hw.h"
#include "osd.h"
/* the card, the keyboard's raw report and the Bluetooth part's lines */
#include "sd.h"
#include "bt.h"
/* the network, the server, this module's header */
#include "espat.h"
#include "ftp.h"
#include "netmenu.h"

/* flags as numbers */
#define YES 1
/* screen rows: title, three message lines, key help */
#define ROW_TITLE 0
#define ROW_LINE1 4
#define ROW_LINE2 6
/* the last message line, the bottom row */
#define ROW_LINE3 8
#define ROW_HELP 23
/* the list of networks: its question, its first row, the entries it holds */
#define ROW_ASK 2
#define ROW_LIST 4
#define LIST_MAX 16
/* a search that fails is tried again so many times, after this rest */
#define SCAN_TRIES 3
#define SCAN_RETRY_MS 700u
/* a list entry on the screen: the name's width, the line with its terminator */
#define LIST_NAME_WIDTH 24
#define LIST_LINE_BUF 40
/* the password screen: the name's row, the typed text's row, the characters shown of it */
#define ROW_PASS_NAME 4
#define ROW_PASS_TEXT 6
#define PASS_SHOWN 29
/* the longest password, a text line of the screen */
#define PASS_MAX 63
#define TEXT_BUF 80
/* the server's screen */
#define ROW_NET 2
#define ROW_SIGNAL 3
#define ROW_OPEN 5
/* the address, the note about the password, the clients */
#define ROW_ADDRESS 8
#define ROW_USER 10
#define ROW_CLIENTS 12
/* files received and sent, the last action */
#define ROW_IN 13
#define ROW_OUT 14
#define ROW_LAST 16
/* the clock's row, the row that tells the time zone's keys */
#define ROW_TIME 18
#define ROW_ZONE 19
/* the time zone's steps in seconds: an hour, a quarter of an hour */
#define ZONE_HOUR_S 3600
#define ZONE_QUARTER_S 900
/* keys that leave a screen: F4, Esc / Backspace, F12; those and Enter must be let go before the next screen */
#define LEAVE_KEYS (K_JOY | K_BACK | K_MENU)
#define RELEASE_KEYS (K_JOY | K_BACK | K_MENU | K_ENTER | K_F11)
/* a message stays this long; joining a network may take this long */
#define MSG_MS 4000u
#define JOIN_MS 20000u
/* a join that fails is tried so many times in all (a right password is sometimes refused once) */
#define JOIN_TRIES 2
/* the rest between two looks at the keys; the server's screen is drawn again after this time */
#define STEP_MS 20u
#define DRAW_MS 500u
/* the server works at most this long before the keys are looked at; its rest without work */
#define BURST_MS 100u
#define IDLE_MS 5u
/* results of join() */
#define JOIN_OK 0
#define JOIN_FAILED 1
#define JOIN_CANCEL 2
/* pick(): nothing chosen */
#define PICK_CANCEL (-1)
/* run(): the screen is left, another network is asked for */
#define RUN_LEAVE 0
#define RUN_NETWORK 1
/* the steps of net_menu */
#define STEP_PICK 0
#define STEP_PASS 1
#define STEP_JOIN 2
/* the server runs; the screens are left */
#define STEP_RUN 3
#define STEP_END 4
/* USB keyboard codes: letters, the digit row, Enter, Esc, Backspace */
#define HID_A 0x04
#define HID_Z 0x1D
/* the digit row's ends */
#define HID_1 0x1E
#define HID_0 0x27
/* the keys that end or correct the typing */
#define HID_ENTER 0x28
#define HID_ESC 0x29
#define HID_BACKSPACE 0x2A
/* space to slash (the keys with two signs), keypad Enter, the keypad's digits */
#define HID_SPACE 0x2C
#define HID_SLASH 0x38
#define HID_KP_ENTER 0x58
/* keypad 1 to 9, keypad 0 */
#define HID_KP_1 0x59
#define HID_KP_9 0x61
#define HID_KP_0 0x62
/* either Shift key in the report's modifiers */
#define MOD_SHIFTS 0x22

/* the signs of the digit row and of the keys from space to slash, without and with Shift (US layout) */
static const char g_ac_digit[] = "1234567890";
static const char g_ac_digit_shift[] = "!@#$%^&*()";
/* space to slash */
static const char g_ac_sign[] = " -=[]\\#;'`,./";
static const char g_ac_sign_shift[] = " _+{}|~:\"~<>?";

/* a network of the list */
typedef struct
{
/* its name, its strength in dBm, 1 = it wants a password */
    char ac_ssid[ESPAT_SSID_BUF];
    int32_t i32_rssi;
    int32_t i32_locked;
} NET_ITEM;

/* a screen: the title, three lines, the key help (empty: none) */
static void screen(const char *pc_line1, const char *pc_line2, const char *pc_line3, const char *pc_help)
{
    osd_clear();
    osd_text(ROW_TITLE, 0, " SD card over Wi-Fi (FTP)", OSD_COLS, YES);
/* the three lines */
    osd_text(ROW_LINE1, YES, pc_line1, OSD_COLS - YES, 0);
    osd_text(ROW_LINE2, YES, pc_line2, OSD_COLS - YES, 0);
    osd_text(ROW_LINE3, YES, pc_line3, OSD_COLS - YES, 0);
/* the keys */
    if (pc_help[0] != 0)
    {
        osd_text(ROW_HELP, 0, pc_help, OSD_COLS, YES);
    }
    osd_show(YES);
}

/* the key that ended a screen must not reach the next one */
static void release(void)
{
    while ((menu_present() != 0) && ((KEYS & RELEASE_KEYS) != 0))
    {
    }
/* the presses seen so far are used up */
    (void)loader_keys();
}

/* a message, shown for some seconds or until a key */
static void message(const char *pc_line1, const char *pc_line2, const char *pc_line3)
{
/* local variables */
    uint32_t ui32_start;
    bool b_wait;

/* start values */
    ui32_start = espat_ms();
    b_wait = true;
/* the text, and the key that brought it is let go */
    screen(pc_line1, pc_line2, pc_line3, "");
    release();
    while (b_wait)
    {
/* long enough */
        if ((espat_ms() - ui32_start) >= MSG_MS)
        {
            b_wait = false;
        }
/* the menu is gone, or a key */
        else if ((menu_present() == 0) || (loader_keys() != 0))
        {
            b_wait = false;
        }
        else
        {
/* a rest, then again */
            espat_wait(STEP_MS);
        }
    }
    release();
}

/* the character of a key for a password (US layout); 0 = none */
static char type_char(uint8_t ui8_code, uint8_t ui8_mods)
{
/* local variables */
    char c_char;
    bool b_shift;

/* start values */
    c_char = 0;
    b_shift = (ui8_mods & MOD_SHIFTS) != 0;
/* letters */
    if ((ui8_code >= HID_A) && (ui8_code <= HID_Z))
    {
        c_char = (char)(('a' + ui8_code) - HID_A);
        if (b_shift)
        {
/* a capital */
            c_char = (char)(('A' + ui8_code) - HID_A);
        }
    }
/* the digit row */
    else if ((ui8_code >= HID_1) && (ui8_code <= HID_0))
    {
        c_char = g_ac_digit[ui8_code - HID_1];
        if (b_shift)
        {
/* the sign above the digit */
            c_char = g_ac_digit_shift[ui8_code - HID_1];
        }
    }
/* space and the keys with two signs */
    else if ((ui8_code >= HID_SPACE) && (ui8_code <= HID_SLASH))
    {
        c_char = g_ac_sign[ui8_code - HID_SPACE];
        if (b_shift)
        {
/* the key's upper sign */
            c_char = g_ac_sign_shift[ui8_code - HID_SPACE];
        }
    }
/* the keypad's digits */
    else if ((ui8_code >= HID_KP_1) && (ui8_code <= HID_KP_9))
    {
        c_char = (char)(('1' + ui8_code) - HID_KP_1);
    }
    else if (ui8_code == HID_KP_0)
    {
/* 0 comes after 9 on the keypad */
        c_char = '0';
    }
    else
    {
/* a key without a character */
    }
    return c_char;
}

/* a network's password is typed: YES = Enter (pc_pass filled), 0 = Esc or the menu is gone */
static int32_t password(const char *pc_ssid, char *pc_pass)
{
/* local variables */
    uint8_t aui8_events[RAW_EVENTS_MAX];
    char ac_text[TEXT_BUF];
/* the report's modifiers, a key's code */
    uint8_t ui8_mods;
    uint8_t ui8_code;
/* a typed character, the text's length, counters */
    char c_char;
    int32_t i32_len;
/* keys in a report, the loop's counter */
    int32_t i32_count;
    int32_t i32_index;
/* the result; running, redraw */
    int32_t i32_result;
    bool b_run;
    bool b_draw;

/* start values */
    ui8_mods = 0;
    ui8_code = 0;
    c_char = 0;
/* nothing typed yet */
    i32_len = 0;
    i32_count = 0;
    i32_index = 0;
/* not confirmed */
    i32_result = 0;
/* the first picture */
    b_run = true;
    b_draw = true;
/* an empty password */
    pc_pass[0] = 0;
    snprintf(ac_text, sizeof ac_text, "Password for %s:", pc_ssid);
    screen(ac_text, "", "Capitals and signs with Shift.", "Enter=join  Esc=other network");
/* the keys held now are not typed */
    (void)raw_events(aui8_events, &ui8_mods);
    while (b_run)
    {
        if (b_draw)
        {
/* the text's end with a cursor; a long text shows its last part */
            i32_index = 0;
            if (i32_len > PASS_SHOWN)
            {
                i32_index = i32_len - PASS_SHOWN;
            }
/* the line with the cursor */
            snprintf(ac_text, sizeof ac_text, "%s_", pc_pass + i32_index);
            osd_text(ROW_PASS_TEXT, YES, ac_text, OSD_COLS - YES, 0);
            b_draw = false;
        }
/* the keys since the last look */
        i32_count = raw_events(aui8_events, &ui8_mods);
/* key by key */
        for (i32_index = 0; i32_index < i32_count; i32_index++)
        {
            ui8_code = aui8_events[i32_index];
            c_char = type_char(ui8_code, ui8_mods);
/* Esc: back to the list */
            if (ui8_code == HID_ESC)
            {
                b_run = false;
            }
/* Enter: the text stands */
            else if ((ui8_code == HID_ENTER) || (ui8_code == HID_KP_ENTER))
            {
                i32_result = YES;
/* the screen ends */
                b_run = false;
            }
            else if (ui8_code == HID_BACKSPACE)
            {
/* the last character goes */
                if (i32_len != 0)
                {
                    i32_len--;
/* the text ends one earlier */
                    pc_pass[i32_len] = 0;
                }
            }
            else if ((c_char != 0) && (i32_len < PASS_MAX))
            {
/* one more character */
                pc_pass[i32_len] = c_char;
                i32_len++;
/* the new end */
                pc_pass[i32_len] = 0;
            }
            else
            {
/* a key that means nothing here */
            }
            b_draw = true;
        }
/* the menu is gone */
        if (menu_present() == 0)
        {
            i32_result = 0;
            b_run = false;
        }
/* nothing typed: a rest */
        if (b_run && (i32_count == 0))
        {
            espat_wait(STEP_MS);
        }
    }
/* Enter or Esc must be let go */
    release();
    return i32_result;
}

/* the networks in reach: one is chosen (its name and whether it wants a password are given */
/* back): its number in the list, or PICK_CANCEL */
static int32_t pick(char *pc_ssid, int32_t *pi32_locked)
{
/* local variables */
    NET_ITEM as_item[LIST_MAX];
    ESPAT_NET s_net;
    char ac_line[LIST_LINE_BUF];
/* the keys pressed */
    uint32_t ui32_keys;
/* networks found, entries of the list (the last one searches again), counters */
    int32_t i32_found;
    int32_t i32_count;
    int32_t i32_index;
/* an entry of the same name */
    int32_t i32_same;
/* the cursor, the result; running, search, redraw */
    int32_t i32_cursor;
    int32_t i32_result;
/* the loop's flags */
    bool b_run;
    bool b_scan;
    bool b_draw;

/* start values */
    ui32_keys = 0;
    i32_found = 0;
    i32_count = 0;
/* the two counters */
    i32_index = 0;
    i32_same = 0;
/* nothing chosen */
    i32_cursor = 0;
    i32_result = PICK_CANCEL;
/* the first pass searches; drawn after it */
    b_run = true;
    b_scan = true;
    b_draw = false;
/* until a network is chosen or the screen is left */
    while (b_run)
    {
        if (b_scan)
        {
/* the search takes some seconds */
            screen("Searching for networks ...", "", "", "");
/* a radio that is still trying to join cannot search: it is stopped first, and the search is tried again */
            net_leave();
            i32_found = net_scan();
            for (i32_index = 0; (i32_index < SCAN_TRIES) && (i32_found < 0); i32_index++)
            {
/* a rest, then once more */
                espat_wait(SCAN_RETRY_MS);
                i32_found = net_scan();
            }
/* for the console */
            snprintf(ac_line, sizeof ac_line, "ftp: network list, %d found", (int)i32_found);
            log_line(ac_line);
            i32_count = 0;
/* strongest first, as the search gives them; no nameless ones, each name once */
            for (i32_index = 0; (i32_index < i32_found) && (i32_count < (LIST_MAX - YES)); i32_index++)
            {
                net_scan_item(i32_index, &s_net);
/* is the name in the list already? */
                i32_same = 0;
                while ((i32_same < i32_count) && (strcmp(as_item[i32_same].ac_ssid, s_net.ac_ssid) != 0))
                {
                    i32_same++;
                }
/* a new name */
                if ((s_net.ac_ssid[0] != 0) && (i32_same == i32_count))
                {
                    strcpy(as_item[i32_count].ac_ssid, s_net.ac_ssid);
/* its strength, its lock */
                    as_item[i32_count].i32_rssi = s_net.i32_rssi;
                    as_item[i32_count].i32_locked = s_net.i32_ecn != 0;
                    i32_count++;
                }
            }
/* the list's screen */
            osd_clear();
            osd_text(ROW_TITLE, 0, " SD card over Wi-Fi (FTP)", OSD_COLS, YES);
/* the question, the keys */
            osd_text(ROW_ASK, YES, (i32_count != 0) ? "Which network?" : "No network found.", OSD_COLS - YES, 0);
            osd_text(ROW_HELP, 0, "Enter=choose  F4/Esc=leave", OSD_COLS, YES);
            osd_show(YES);
/* the cursor on the strongest */
            i32_cursor = 0;
            b_scan = false;
            b_draw = true;
/* the keys of the screen before are let go */
            release();
        }
        if (b_draw)
        {
/* name, "*" for a password, strength; then the entry that searches again */
            for (i32_index = 0; i32_index < i32_count; i32_index++)
            {
                snprintf(ac_line, sizeof ac_line, " %-*.*s%c%4d", LIST_NAME_WIDTH, LIST_NAME_WIDTH,
                         as_item[i32_index].ac_ssid, (as_item[i32_index].i32_locked != 0) ? '*' : ' ',
                         (int)as_item[i32_index].i32_rssi);
                osd_text(ROW_LIST + i32_index, 0, ac_line, OSD_COLS, i32_index == i32_cursor);
            }
/* below them */
            osd_text(ROW_LIST + i32_count, 0, " (search again)", OSD_COLS, i32_cursor == i32_count);
            b_draw = false;
        }
        ui32_keys = loader_keys();
/* the menu is gone, or the screen is left */
        if ((menu_present() == 0) || ((ui32_keys & LEAVE_KEYS) != 0) || (loader_ftp_asked() != 0))
        {
            b_run = false;
        }
        else if ((ui32_keys & K_ENTER) != 0)
        {
/* the last entry: search again */
            if (i32_cursor == i32_count)
            {
                b_scan = true;
            }
            else
            {
/* this one */
                strcpy(pc_ssid, as_item[i32_cursor].ac_ssid);
                *pi32_locked = as_item[i32_cursor].i32_locked;
/* its number ends the screen */
                i32_result = i32_cursor;
                b_run = false;
            }
        }
/* up */
        else if (((ui32_keys & K_UP) != 0) && (i32_cursor != 0))
        {
            i32_cursor--;
            b_draw = true;
        }
/* down, as far as the entry that searches again */
        else if (((ui32_keys & K_DOWN) != 0) && (i32_cursor != i32_count))
        {
            i32_cursor++;
/* the cursor has moved */
            b_draw = true;
        }
        else
        {
            espat_wait(STEP_MS);
        }
    }
/* the key that ended the list is let go */
    release();
    return i32_result;
}

/* join a network: JOIN_OK, JOIN_FAILED (said on the screen), JOIN_CANCEL (a key, or the menu is gone) */
static int32_t join(const char *pc_ssid, const char *pc_pass)
{
/* local variables */
    char ac_text[TEXT_BUF];
    uint32_t ui32_start;
/* the reason of a failure, the result, running */
    int32_t i32_fail;
/* tries left */
    int32_t i32_tries;
    int32_t i32_result;
    bool b_run;

/* start values */
    i32_tries = JOIN_TRIES;
    ui32_start = espat_ms();
    i32_fail = 0;
/* failed unless joined or cancelled */
    i32_result = JOIN_FAILED;
    b_run = true;
/* the screen and the console say what happens */
    snprintf(ac_text, sizeof ac_text, "Joining %s ...", pc_ssid);
    screen(ac_text, "", "", "F4/Esc=other network");
    log_line(ac_text);
/* the radio starts joining */
    release();
    net_begin(pc_ssid, pc_pass);
/* until joined, refused, too late or cancelled */
    while (b_run)
    {
        i32_fail = net_fail();
        if (net_joined() != 0)
        {
/* the network has let us in */
            i32_result = JOIN_OK;
            b_run = false;
        }
/* the network says no, or does not answer in time: once more, then it is given up */
        else if ((i32_fail != 0) || ((espat_ms() - ui32_start) > JOIN_MS))
        {
            i32_tries--;
            if (i32_tries != 0)
            {
/* from the start */
                net_begin(pc_ssid, pc_pass);
                ui32_start = espat_ms();
            }
            else
            {
/* that was the last try */
                b_run = false;
            }
        }
        else if ((menu_present() == 0) || ((loader_keys() & LEAVE_KEYS) != 0))
        {
/* given up by the user */
            i32_result = JOIN_CANCEL;
            b_run = false;
        }
        else
        {
/* a rest, then again */
            espat_wait(STEP_MS);
        }
    }
/* why it failed */
    if (i32_result == JOIN_FAILED)
    {
        snprintf(ac_text, sizeof ac_text, "ftp: not joined, reason %d after %u ms", (int)i32_fail,
                 (unsigned)(espat_ms() - ui32_start));
        log_line(ac_text);
/* the radio stops trying; the screen says why */
        snprintf(ac_text, sizeof ac_text, "Joining %s ...", pc_ssid);
        net_leave();
        if (i32_fail == ESPAT_JOIN_NO_AP)
        {
/* no network of that name answered */
            message(ac_text, "The network was not found.", "");
        }
        else
        {
/* refused, or no answer */
            message(ac_text, "That did not work.", "Is the password right?");
        }
    }
    else
    {
/* the keys are let go */
        release();
    }
    return i32_result;
}

/* the server's screen: the network, the address to open, what the server did */
static void run_draw(void)
{
/* local variables */
    ESPAT_NET s_net;
    FTP_INFO s_info;
    char ac_text[TEXT_BUF];
/* the clock as text */
    char ac_time[NET_TIME_BUF];

/* what the server did */
    ftp_info(&s_info);
    if (net_joined() == 0)
    {
/* the radio joins again by itself */
        osd_text(ROW_NET, YES, "Network lost, joining again ...", OSD_COLS - YES, 0);
        osd_text(ROW_SIGNAL, YES, "", OSD_COLS - YES, 0);
    }
    else
    {
/* the network's name */
        net_info(&s_net);
        snprintf(ac_text, sizeof ac_text, "Network: %s", s_net.ac_ssid);
        osd_text(ROW_NET, YES, ac_text, OSD_COLS - YES, 0);
/* its strength */
        snprintf(ac_text, sizeof ac_text, "Signal:  %d dBm", (int)s_net.i32_rssi);
        osd_text(ROW_SIGNAL, YES, ac_text, OSD_COLS - YES, 0);
/* the address */
        snprintf(ac_text, sizeof ac_text, "  ftp://%s", s_net.ac_ip);
        osd_text(ROW_ADDRESS, YES, ac_text, OSD_COLS - YES, 0);
    }
/* the server's counters */
    snprintf(ac_text, sizeof ac_text, "Connected: %d", (int)s_info.i32_clients);
    osd_text(ROW_CLIENTS, YES, ac_text, OSD_COLS - YES, 0);
/* received */
    snprintf(ac_text, sizeof ac_text, "Received:  %u files, %u KB", (unsigned)s_info.ui32_files_in,
             (unsigned)s_info.ui32_kb_in);
    osd_text(ROW_IN, YES, ac_text, OSD_COLS - YES, 0);
/* sent, and the last action */
    snprintf(ac_text, sizeof ac_text, "Sent:      %u files, %u KB", (unsigned)s_info.ui32_files_out,
             (unsigned)s_info.ui32_kb_out);
    osd_text(ROW_OUT, YES, ac_text, OSD_COLS - YES, 0);
    osd_text(ROW_LAST, YES, s_info.ac_last, OSD_COLS - YES, 0);
/* the clock, which gives the new files their dates */
    net_time_text(ac_time);
    snprintf(ac_text, sizeof ac_text, "Time: %s", (ac_time[0] != 0) ? ac_time : "unavailable");
    osd_text(ROW_TIME, YES, ac_text, OSD_COLS - YES, 0);
}

/* the time zone's keys on the server's screen */
static void zone_keys(uint32_t ui32_keys)
{
    if ((ui32_keys & K_LEFT) != 0)
    {
        net_zone_step(-ZONE_HOUR_S);
    }
/* later zones to the right */
    if ((ui32_keys & K_RIGHT) != 0)
    {
        net_zone_step(ZONE_HOUR_S);
    }
/* the zones between the hours */
    if ((ui32_keys & K_PGDN) != 0)
    {
        net_zone_step(-ZONE_QUARTER_S);
    }
/* a quarter later */
    if ((ui32_keys & K_PGUP) != 0)
    {
        net_zone_step(ZONE_QUARTER_S);
    }
}

/* the server runs until a key: RUN_LEAVE (F4 / Esc, or the menu is gone) or RUN_NETWORK (Enter) */
static int32_t run(void)
{
/* local variables */
    ESPAT_NET s_net;
    char ac_text[TEXT_BUF];
    uint32_t ui32_keys;
/* a burst's start, the last drawing, 1 = the server had work */
    uint32_t ui32_start;
    uint32_t ui32_draw;
    int32_t i32_work;
/* the result, running */
    int32_t i32_result;
    bool b_run;

/* start values */
    ui32_keys = 0;
    ui32_start = 0;
    i32_work = 0;
/* left unless Enter asks for another network */
    i32_result = RUN_LEAVE;
    b_run = true;
/* the clock first: new files get their dates from it (without internet they get 1980) */
    screen("Getting the time ...", "", "", "");
    if (net_time_sync() != 0)
    {
        log_line("ftp: no time from the internet");
/* said for some seconds; the server starts all the same */
        message("The clock (RTC) is unavailable:", "no answer from the internet.", "New files get the date 1980.");
    }
/* the time zone that was set earlier: the files' dates are local time */
    net_zone_load();
/* then the server */
    if (ftp_start(SD_FS_ROOT, FTP_PORT) != 0)
    {
/* no memory or no socket */
        message("The server did not start.", "", "");
        b_run = false;
    }
    else
    {
/* the lines that do not change */
        osd_clear();
        osd_text(ROW_TITLE, 0, " SD card over Wi-Fi (FTP)", OSD_COLS, YES);
/* how to get in */
        osd_text(ROW_OPEN, YES, "Use this address in Explorer", OSD_COLS - YES, 0);
        osd_text(ROW_OPEN + YES, YES, "or an FTP program (FileZilla):", OSD_COLS - YES, 0);
        osd_text(ROW_ZONE, YES, "Zone: Left/Right, PgUp/PgDn 15m", OSD_COLS - YES, 0);
/* no log-in; the keys */
        osd_text(ROW_USER, YES, "No user name, no password.", OSD_COLS - YES, 0);
        osd_text(ROW_HELP, 0, "Enter=network  F4/Esc=stop", OSD_COLS, YES);
/* the others, now */
        run_draw();
        osd_show(YES);
/* the address on the console too */
        net_info(&s_net);
        snprintf(ac_text, sizeof ac_text, "ftp: server started, ftp://%s", s_net.ac_ip);
        log_line(ac_text);
    }
/* drawn just now */
    ui32_draw = espat_ms();
    while (b_run)
    {
/* the server works on while it has work, but the keys are looked at in time */
        ui32_start = espat_ms();
        do
        {
/* a piece of every transfer */
            i32_work = ftp_poll();
        } while ((i32_work != 0) && ((espat_ms() - ui32_start) < BURST_MS));
        ui32_keys = loader_keys();
/* the Bluetooth part's lines are taken so that none is cut when its menu is opened later */
        (void)bt_service();
        if ((menu_present() == 0) || ((ui32_keys & LEAVE_KEYS) != 0) || (loader_ftp_asked() != 0))
        {
/* the screen is left */
            b_run = false;
        }
/* the time zone: Left / Right one hour, Page Up / Page Down a quarter of an hour */
        else if ((ui32_keys & (K_LEFT | K_RIGHT | K_PGUP | K_PGDN)) != 0)
        {
            zone_keys(ui32_keys);
            run_draw();
        }
/* Enter */
        else if ((ui32_keys & K_ENTER) != 0)
        {
/* Enter: another network */
            i32_result = RUN_NETWORK;
            b_run = false;
        }
        else
        {
/* the screen, twice a second */
            if ((espat_ms() - ui32_draw) >= DRAW_MS)
            {
                run_draw();
                ui32_draw = espat_ms();
            }
/* nothing to do: a short rest */
            if (i32_work == 0)
            {
                espat_wait(IDLE_MS);
            }
        }
    }
/* all connections and files are closed */
    ftp_stop();
/* a changed time zone is remembered */
    net_zone_save();
    release();
    return i32_result;
}

/* the steps from the network to the running server, until the screens are left */
static void steps(void)
{
/* local variables */
    char ac_ssid[ESPAT_SSID_BUF];
    char ac_pass[ESPAT_PASS_BUF];
/* the remembered network */
    char ac_old_ssid[ESPAT_SSID_BUF];
    char ac_old_pass[ESPAT_PASS_BUF];
/* the chosen network wants a password; the step; a step's result */
    int32_t i32_locked;
    int32_t i32_step;
    int32_t i32_result;

/* start values */
    i32_locked = 0;
    i32_step = STEP_PICK;
    i32_result = 0;
/* the remembered network is joined without asking */
    net_store_get(ac_old_ssid, ac_old_pass);
    strcpy(ac_ssid, ac_old_ssid);
    strcpy(ac_pass, ac_old_pass);
/* there is one */
    if (ac_ssid[0] != 0)
    {
        i32_step = STEP_JOIN;
    }
/* step by step */
    while ((i32_step != STEP_END) && (menu_present() != 0))
    {
        if (i32_step == STEP_PICK)
        {
/* no password unless one is typed */
            ac_pass[0] = 0;
            i32_step = STEP_JOIN;
/* nothing chosen: the screens are left; a network with a password: it is asked for */
            if (pick(ac_ssid, &i32_locked) == PICK_CANCEL)
            {
                i32_step = STEP_END;
            }
            else if (i32_locked != 0)
            {
/* its password first */
                i32_step = STEP_PASS;
            }
            else
            {
/* an open network */
            }
        }
        else if (i32_step == STEP_PASS)
        {
/* Esc goes back to the list */
            i32_step = STEP_PICK;
            if (password(ac_ssid, ac_pass) != 0)
            {
/* typed */
                i32_step = STEP_JOIN;
            }
        }
        else if (i32_step == STEP_JOIN)
        {
/* a failure goes back to the list */
            i32_step = STEP_PICK;
            if (join(ac_ssid, ac_pass) == JOIN_OK)
            {
/* a new network, or a new password, is remembered */
                if ((strcmp(ac_ssid, ac_old_ssid) != 0) || (strcmp(ac_pass, ac_old_pass) != 0))
                {
                    net_store_put(ac_ssid, ac_pass);
/* and is the one to compare with from now on */
                    strcpy(ac_old_ssid, ac_ssid);
                    strcpy(ac_old_pass, ac_pass);
                }
/* the server can run */
                i32_step = STEP_RUN;
            }
        }
        else
        {
/* the server */
            i32_result = run();
            i32_step = STEP_END;
/* Enter: the network is left and the list comes */
            if (i32_result == RUN_NETWORK)
            {
                net_leave();
                i32_step = STEP_PICK;
            }
        }
    }
}

/* netmenu.h */

/* F4 in the machine menu */
void net_menu(void)
{
    if (sd_init() != SD_OK)
    {
/* without a card there is nothing to serve */
        message("No SD card (or it cannot be", "read).", "");
    }
    else if (sd_fs_mount() != SD_OK)
    {
/* nothing the server could read */
        message("The card's file system is not", "FAT16 or FAT32.", "");
    }
    else
    {
/* the radio is Wi-Fi's alone: Bluetooth goes off until the screens are left (a Bluetooth part */
/* that keeps calling its headphones leaves Wi-Fi too little air time to join a network) */
        screen("Starting Wi-Fi ...", "", "", "");
        btaudio_ask(YES);
/* the radio */
        if (net_on() != 0)
        {
            message("Wi-Fi did not start.", "", "");
        }
        else
        {
/* the screens */
            steps();
        }
/* the radio off, the card back to the loader, Bluetooth on again */
        net_off();
        sd_fs_unmount();
        btaudio_ask(0);
/* on the console */
        log_line("ftp: server stopped");
    }
/* the menu's own screen again */
    osd_clear();
    osd_hide();
    release();
}
