/* bt.c -- Bluetooth audio menu (F3)
 *
 * The Bluetooth part of this sketch (esp32_v2.ino) takes text commands over the UART
 * (115200 8N1, register UART) and answers with lines: "OK ...", "ERR ..." and,
 * unasked, "EV ..." events. Used here:
 *   info                 -> OK info <state> <scan|idle> <MAC> <vol> <pin> <i2s|tone> <name>
 *   scan                 drops the link and searches; each device: EV found <n> <MAC> <rssi> <name>
 *   connect <n>          n from EV found; disconnect; forget; pin auto|<code>; vol <0..127>; src i2s|tone
 *   events               EV connecting/connected/disconnected <MAC> <name>, EV discovery on|off,
 *                        EV pairing pin|confirm|failed|next ..., EV paired <name>, EV volume ...
 * The lines are read on every main loop pass (the receive FIFO holds 16 bytes);
 * a line with lost bytes is dropped. While the menu is open, info is asked for
 * every second; two unanswered requests mean the ESP32 is not there.
 */
#include "hw.h"
#include "osd.h"
#include "util.h"
#include "bt.h"

#define BT_DEVS   9                    /* devices shown (rows 12-20) */
#define DEV_NAME  28
#define LINE_MAX  128                  /* the info line is ~100 characters with large counters */
#define N_ITEMS   6                    /* menu items before the device list */
#define ROW_ITEMS 3
#define ROW_DEVS  12

enum { I_SCAN, I_DISC, I_FORGET, I_PIN, I_VOL, I_SRC };
enum { S_DISC, S_CONNECTING, S_CONN };

static char     rx[LINE_MAX + 1];
static int      rx_len, rx_skip;
static int      shown, want_info, miss, have_info;
static uint32_t t_info;
static int      state, scanning, vol, src_tone;
static uint32_t g_under, g_ovf, g_fix;      /* audio: I2S data short, DMA overwritten (skips), drift fixes */
static uint32_t g_i2s_hz, g_bt_hz, g_rfix;  /* measured I2S / A2DP sample rates, rate history entries */
static char     peer[DEV_NAME + 1], pin[17];
static char     dev[BT_DEVS][DEV_NAME + 1];
static int      ndev, cur, edit, elen;
static char     ebuf[17], msg[33];

static void send(const char *s)
{
    for (;; s++) {
        while (UART & UART_BUSY) ;
        if (!*s) break;
        UART = UART_SEND | (uint8_t)*s;
    }
    UART = UART_SEND | '\n';
}

static void send2(const char *a, const char *b)
{
    char cmd[32];
    u_strcpy(u_strcpy(cmd, a), b);
    send(cmd);
}

/* next space-separated word of *pp (terminated in place) */
static char *word(char **pp)
{
    char *p = *pp, *w;
    while (*p == ' ') p++;
    w = p;
    while (*p && *p != ' ') p++;
    if (*p) *p++ = 0;
    *pp = p;
    return w;
}

static char *rest(char *p)
{
    while (*p == ' ') p++;
    return p;
}

static int num(const char *s)
{
    int v = 0;
    while (*s >= '0' && *s <= '9') v = v * 10 + *s++ - '0';
    return v;
}

static int is(const char *a, const char *b) { return u_stricmp(a, b) == 0; }

static int state_of(const char *w)
{
    return is(w, "connected") ? S_CONN : is(w, "connecting") ? S_CONNECTING : S_DISC;
}

static void say(const char *a, const char *b)
{
    u_strncpy(u_strncpy(msg, a, 32), b, 32 - u_strlen(a));
}

static void line(char *p)
{
    char *w = word(&p);

    if (is(w, "OK")) {
        if (!is(word(&p), "info")) return;
        state    = state_of(word(&p));
        scanning = is(word(&p), "scan");
        word(&p);                                           /* MAC */
        vol      = num(word(&p));
        u_strncpy(pin, word(&p), 16);
        src_tone = is(word(&p), "tone");
        g_under  = (uint32_t)num(word(&p));
        g_ovf    = (uint32_t)num(word(&p));
        g_fix    = (uint32_t)num(word(&p));
        g_i2s_hz = (uint32_t)num(word(&p));
        g_bt_hz  = (uint32_t)num(word(&p));
        g_rfix   = (uint32_t)num(word(&p));
        p = rest(p);
        u_strncpy(peer, is(p, "-") ? "" : p, DEV_NAME);
        have_info = 1;
        miss = 0;
        return;
    }
    if (is(w, "ERR")) { say(rest(p), ""); return; }
    if (!is(w, "EV")) return;                               /* boot banner, help text, ... */

    w = word(&p);
    if (is(w, "found")) {
        int n = num(word(&p));
        word(&p);                                           /* MAC, rssi */
        word(&p);
        if (n < BT_DEVS) {
            u_strncpy(dev[n], rest(p), DEV_NAME);
            if (n >= ndev) ndev = n + 1;
        }
    } else if (is(w, "connecting") || is(w, "connected") || is(w, "disconnected") || is(w, "disconnecting")) {
        state = state_of(w);
        if (state == S_CONN) say("Connected", "");
        want_info = 1;
    } else if (is(w, "discovery")) {
        scanning = is(word(&p), "on");
    } else if (is(w, "volume")) {                           /* restored / changed on the speaker */
        want_info = 1;
    } else if (is(w, "paired")) {
        say("Paired", "");
    } else if (is(w, "pairing")) {
        w = word(&p);
        if (is(w, "pin"))         say("Pairing, PIN ", word(&p));
        else if (is(w, "failed")) say("Pairing failed", "");
        else if (is(w, "next")) {                           /* next try with pin <code> */
            word(&p); word(&p); word(&p);
            say("Wrong PIN? Next try: ", word(&p));
        } else                    say("Pairing...", "");
    }
}

int bt_service(void)
{
    uint32_t u;
    int      got = 0, n = 0;

    while (((u = UART) & UART_VALID) && u != 0xFFFFFFFFu && n++ < 512) {   /* all ones: a gone FPGA */
        char c = (char)u;
        UART = UART_POP | (u & UART_OVR ? UART_CLR : 0);
        if (u & UART_OVR) rx_skip = 1;                      /* bytes were lost: drop this line */
        if (c == '\n') {
            rx[rx_len] = 0;
            if (!rx_skip) { line(rx); got = 1; }
            rx_len = rx_skip = 0;
        } else if (c != '\r') {
            if (rx_len < LINE_MAX) rx[rx_len++] = c;
            else rx_skip = 1;
        }
    }
    if (shown && (want_info || TIMER - t_info > 1000 * CLK_PER_MS)) {
        if (!want_info && miss < 2) miss++;
        want_info = 0;
        t_info = TIMER;
        send("info");
    }
    return got;
}

void bt_open(void)
{
    shown = 1;
    edit = 0;
    miss = 0;
    msg[0] = 0;
    want_info = 1;
    osd_clear();
    osd_show(1);
}

void bt_close(void) { shown = 0; }

/* PIN typing; returns 1 if a key was taken (redraw) */
static int pin_edit(void)
{
    uint8_t ev[3], mods;
    int     i, n = raw_events(ev, &mods);

    for (i = 0; i < n; i++) {
        uint8_t c = ev[i];
        char    ch = key_char(c, mods);
        if (c == 0x29) { edit = 0; return 1; }              /* Esc */
        if (c == 0x2A && elen) ebuf[--elen] = 0;            /* Backspace */
        else if (c == 0x28 || c == 0x58) {                  /* Enter: empty = auto */
            u_strcpy(pin, elen ? ebuf : "auto");
            send2("pin ", pin);
            edit = 0;
            return 1;
        } else if (ch && ch != '-' && ch != '_' && elen < 16) {
            ebuf[elen++] = ch;
            ebuf[elen] = 0;
        }
    }
    return n != 0;
}

int bt_keys(uint32_t k)
{
    char t[12];
    int  n = N_ITEMS + ndev;

    if (cur >= n) cur = n - 1;                              /* a new scan found fewer devices */
    if (edit) return pin_edit() ? 2 : 1;
    if (k & (K_BT | K_BACK | K_MENU)) return 0;
    if ((k & K_UP) && cur > 0) cur--;
    if ((k & K_DOWN) && cur < n - 1) cur++;
    if (cur == I_VOL && (k & (K_LEFT | K_RIGHT))) {
        vol += (k & K_RIGHT) ? 8 : -8;
        if (vol < 0) vol = 0;
        if (vol > 127) vol = 127;
        u_utoa(t, (uint32_t)vol);
        send2("vol ", t);
    }
    if (!(k & (K_ENTER | K_F11))) return 1;
    switch (cur) {
    case I_SCAN:
        ndev = 0;
        scanning = 1;
        send("scan");
        say("Searching: pairing mode on", "");
        break;
    case I_DISC:   send("disconnect"); break;
    case I_FORGET: send("forget"); peer[0] = 0; say("Forgotten", ""); break;
    case I_PIN:
        raw_events((uint8_t[3]){0}, (uint8_t[1]){0});       /* keys already held do not count */
        edit = 1;
        elen = 0;
        ebuf[0] = 0;
        break;
    case I_VOL:    break;
    case I_SRC:
        src_tone = !src_tone;
        send(src_tone ? "src tone" : "src i2s");
        break;
    default:
        u_utoa(t, (uint32_t)(cur - N_ITEMS));
        send2("connect ", t);
        say("Connecting: ", dev[cur - N_ITEMS]);
        break;
    }
    want_info = 1;
    return 1;
}

void bt_draw(void)
{
    char l[48], *p;
    int  i, n;

    osd_text(0, 0, " Bluetooth audio", OSD_COLS, 1);
    if (miss >= 2)               p = " No answer from the ESP32";
    else if (!have_info)         p = " Asking the ESP32...";
    else if (state == S_CONNECTING) p = " Connecting...";
    else if (state != S_CONN)    p = " Not connected";
    else { u_strncpy(u_strcpy(l, " Connected: "), peer, 19); p = l; }
    osd_text(1, 0, p, OSD_COLS, 0);
    l[0] = 0;
    if (scanning) u_strcpy(l, " Searching...");
    else if (have_info && state == S_CONN && g_bt_hz) {     /* sample rates: I2S in / Bluetooth out */
        p = u_utoa(u_strcpy(l, " Rate: in "), g_i2s_hz);
        p = u_utoa(u_strcpy(p, " out "), g_bt_hz);
    }
    osd_text(2, 0, l, OSD_COLS, 0);

    for (i = 0; i < N_ITEMS; i++) {
        switch (i) {
        case I_SCAN:   p = u_strcpy(l, " Scan for devices"); break;
        case I_DISC:   p = u_strcpy(l, " Disconnect"); break;
        case I_FORGET: p = u_strcpy(l, " Forget the device"); break;
        case I_PIN:
            p = u_strcpy(u_strcpy(l, " PIN: "), edit ? ebuf : pin[0] ? pin : "auto");
            if (edit) p = u_strcpy(p, "_");
            break;
        case I_VOL:
            p = u_strcpy(u_utoa(u_strcpy(l, " Volume: "), (uint32_t)(vol * 100 + 63) / 127), "%  (Left/Right)");
            break;
        default:       p = u_strcpy(l, src_tone ? " Sound: test tone" : " Sound: Spectrum"); break;
        }
        (void)p;
        osd_text(ROW_ITEMS + i, 0, l, OSD_COLS, i == cur);
    }
    osd_text(ROW_ITEMS + N_ITEMS, 0, "", OSD_COLS, 0);
    osd_text(ROW_DEVS - 2, 0, "", OSD_COLS, 0);
    osd_text(ROW_DEVS - 1, 0, ndev ? " Devices (Enter = connect):" :
             scanning ? " (searching...)" : " Pairing mode on, then Scan", OSD_COLS, 0);
    for (i = 0; i < BT_DEVS; i++) {
        n = N_ITEMS + i;
        l[0] = 0;
        if (i < ndev) u_strcpy(u_strcpy(l, " "), dev[i][0] ? dev[i] : "?");
        osd_text(ROW_DEVS + i, 0, l, OSD_COLS, i < ndev && n == cur);
    }
    l[0] = 0;
    if (have_info && state == S_CONN) {                     /* audio gaps since the ESP32 started */
        p = u_utoa(u_strcpy(l, " Audio: short "), g_under);
        p = u_utoa(u_strcpy(p, " skip "), g_ovf);
        p = u_utoa(u_strcpy(p, " fix "), g_fix);
    }
    osd_text(21, 0, l, OSD_COLS, 0);
    osd_text(22, 0, msg, OSD_COLS, 0);
    osd_text(23, 0, edit ? "Type PIN, Enter (empty = auto)" : "Enter=select  F3/Esc=exit", OSD_COLS, 1);
}

/* back to the state after a start: the next machine starts the loader again without an ESP32
 * restart (esp_hw.cpp; the Bluetooth connection stays) */
void bt_reset(void)
{
    u_memset(&rx, 0, sizeof rx);
    u_memset(&rx_len, 0, sizeof rx_len);
    u_memset(&rx_skip, 0, sizeof rx_skip);
    u_memset(&shown, 0, sizeof shown);
    u_memset(&want_info, 0, sizeof want_info);
    u_memset(&miss, 0, sizeof miss);
    u_memset(&have_info, 0, sizeof have_info);
    u_memset(&t_info, 0, sizeof t_info);
    u_memset(&state, 0, sizeof state);
    u_memset(&scanning, 0, sizeof scanning);
    u_memset(&vol, 0, sizeof vol);
    u_memset(&src_tone, 0, sizeof src_tone);
    u_memset(&g_under, 0, sizeof g_under);
    u_memset(&g_ovf, 0, sizeof g_ovf);
    u_memset(&g_fix, 0, sizeof g_fix);
    u_memset(&g_i2s_hz, 0, sizeof g_i2s_hz);
    u_memset(&g_bt_hz, 0, sizeof g_bt_hz);
    u_memset(&g_rfix, 0, sizeof g_rfix);
    u_memset(&peer, 0, sizeof peer);
    u_memset(&pin, 0, sizeof pin);
    u_memset(&dev, 0, sizeof dev);
    u_memset(&ndev, 0, sizeof ndev);
    u_memset(&cur, 0, sizeof cur);
    u_memset(&edit, 0, sizeof edit);
    u_memset(&elen, 0, sizeof elen);
    u_memset(&ebuf, 0, sizeof ebuf);
    u_memset(&msg, 0, sizeof msg);
}
