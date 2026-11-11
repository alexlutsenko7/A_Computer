/* bt.c -- Bluetooth audio menu (F3) */
/* The Bluetooth part of this sketch (v1.ino) takes text commands over the UART */
/* (115200 8N1, register UART) and answers with lines: "OK ...", "ERR ..." and, */
/* unasked, "EV ..." events. Used here: */
/*   info                 -> OK info <state> <scan|idle> <MAC> <vol> <pin> <i2s|tone> <name> */
/*   scan                 drops the link and searches; each device: EV found <n> <MAC> <rssi> <name> */
/*   connect <n>          n from EV found; disconnect; forget; pin auto|<code>; vol <0..127>; src i2s|tone */
/*   events               EV connecting/connected/disconnected <MAC> <name>, EV discovery on|off, */
/*                        EV pairing pin|confirm|failed|next ..., EV paired <name>, EV volume ... */
/* The lines are read on every main loop pass (the receive FIFO holds 16 bytes); */
/* a line with lost bytes is dropped. While the menu is open, info is asked for */
/* every second; two unanswered requests mean the ESP32 is not there. */
#include "hw.h"
#include "osd.h"
/* string functions, this module's header */
#include "util.h"
#include "bt.h"

/* devices shown (rows 12-20) */
#define BT_DEVS 9
/* characters kept of a device's name, and the buffer with its terminator */
#define DEV_NAME 28
#define DEV_NAME_BUF 29
/* the info line is ~100 characters with large counters */
#define LINE_MAX 128
#define LINE_BUF 129
/* menu items before the device list */
#define N_ITEMS 6
/* screen rows */
#define ROW_TITLE 0
#define ROW_STATE 1
#define ROW_RATE 2
/* the menu's items */
#define ROW_ITEMS 3
/* the device list */
#define ROW_DEVS_GAP 10
#define ROW_DEVS_TITLE 11
#define ROW_DEVS 12
/* audio counters, message, key help */
#define ROW_AUDIO 21
#define ROW_MSG 22
#define ROW_HELP 23
/* the PIN: characters, and the buffer with its terminator */
#define PIN_MAX 16
#define PIN_BUF 17
/* the message line: characters, and the buffer with its terminator */
#define MSG_MAX 32
#define MSG_BUF 33
/* buffers for a command, a number and a screen line */
#define CMD_BUF 32
#define NUM_BUF 12
#define ROW_BUF 48
/* characters of the peer's name that fit behind " Connected: " */
#define PEER_SHOWN 19
/* the volume: its range, one key step, and its display in percent */
#define VOL_MAX 127
#define VOL_STEP 8
/* percent, and its rounding */
#define VOL_PERCENT 100
#define VOL_ROUND 63
/* decimal numbers */
#define DECIMAL_BASE 10
/* the ESP32 is taken as gone after this many unanswered requests; one request per second */
#define MISS_MAX 2
#define INFO_PERIOD_MS 1000u
/* bytes read from the UART in one call */
#define RX_PER_CALL 512
/* a register read from a gone FPGA */
#define ALL_ONES 0xFFFFFFFFu
/* USB HID key codes */
#define HID_ENTER 0x28
#define HID_ESC 0x29
/* backspace, the numpad's Enter */
#define HID_BACKSPACE 0x2A
#define HID_KP_ENTER 0x58
/* flags as numbers */
#define YES 1
#define OSD_FULL_SCREEN 1
/* inverse and normal text */
#define OSD_INVERSE 1
#define OSD_NORMAL 0

/* the menu's items, in screen order */
enum
{
    I_SCAN,
    I_DISC,
    I_FORGET,
    I_PIN,
    I_VOL,
    I_SRC
};

/* the link's state */
enum
{
    S_DISC,
    S_CONNECTING,
    S_CONN
};

/* the line being received */
static char g_ac_rx[LINE_BUF];
/* the connected (or remembered) device, and the PIN in use */
static char g_ac_peer[DEV_NAME_BUF];
static char g_ac_pin[PIN_BUF];
/* the devices found by a scan */
static char g_ac_dev[BT_DEVS][DEV_NAME_BUF];
/* the PIN being typed, and the message line */
static char g_ac_edit[PIN_BUF];
static char g_ac_msg[MSG_BUF];
/* characters received of the line; the line lost bytes and is dropped */
static int32_t g_i32_rx_len;
static int32_t g_i32_rx_skip;
/* the menu is shown; info is wanted now; unanswered requests; an answer came at least once */
static int32_t g_i32_shown;
static int32_t g_i32_want_info;
/* requests without an answer, and whether one ever came */
static int32_t g_i32_miss;
static int32_t g_i32_have_info;
/* when info was asked for last */
static uint32_t g_ui32_info_time;
/* the link: state, searching, volume, test tone instead of the machine's sound */
static int32_t g_i32_state;
static int32_t g_i32_scanning;
/* volume, test tone */
static int32_t g_i32_vol;
static int32_t g_i32_src_tone;
/* audio: I2S data short, DMA overwritten (skips), drift fixes */
static uint32_t g_ui32_under;
static uint32_t g_ui32_ovf;
static uint32_t g_ui32_fix;
/* measured I2S / A2DP sample rates, rate history entries */
static uint32_t g_ui32_i2s_hz;
static uint32_t g_ui32_bt_hz;
static uint32_t g_ui32_rfix;
/* devices in the list, the selected line, PIN typing is on, characters typed */
static int32_t g_i32_ndev;
static int32_t g_i32_cur;
/* PIN typing */
static int32_t g_i32_edit;
static int32_t g_i32_edit_len;

/* wait until the UART can take a byte */
static void uart_wait(void)
{
    while ((UART & UART_BUSY) != 0)
    {
    }
}

/* one command line to the Bluetooth part */
static void send(const char *pc_text)
{
/* the characters */
    while (*pc_text != 0)
    {
        uart_wait();
        UART = UART_SEND | (uint8_t)*pc_text;
/* next character */
        pc_text++;
    }
/* the end of the line */
    uart_wait();
    UART = UART_SEND | '\n';
}

/* a command of two parts */
static void send2(const char *pc_first, const char *pc_second)
{
/* local variables */
    char ac_cmd[CMD_BUF];

    u_strcpy(u_strcpy(ac_cmd, pc_first), pc_second);
    send(ac_cmd);
}

/* next space-separated word of *ppc_text (terminated in place) */
static char *word(char **ppc_text)
{
/* local variables */
    char *pc_pos;
    char *pc_word;

    pc_pos = *ppc_text;
/* spaces before the word */
    while (*pc_pos == ' ')
    {
        pc_pos++;
    }
    pc_word = pc_pos;
/* the word */
    while ((*pc_pos != 0) && (*pc_pos != ' '))
    {
        pc_pos++;
    }
/* terminate it, and go on behind it */
    if (*pc_pos != 0)
    {
        *pc_pos = 0;
        pc_pos++;
    }
/* the caller's pointer moves on */
    *ppc_text = pc_pos;
    return pc_word;
}

/* the rest of a line, without the spaces before it */
static char *rest(char *pc_text)
{
    while (*pc_text == ' ')
    {
        pc_text++;
    }
/* the first character that is not a space */
    return pc_text;
}

/* a decimal number at the start of a text */
static int32_t num(const char *pc_text)
{
    int32_t i32_value;

    i32_value = 0;
/* digit by digit */
    while ((*pc_text >= '0') && (*pc_text <= '9'))
    {
        i32_value = ((i32_value * DECIMAL_BASE) + *pc_text) - '0';
        pc_text++;
    }
/* 0 if there was no digit */
    return i32_value;
}

/* are two words the same, without regard to case? */
static bool is(const char *pc_a, const char *pc_b)
{
/* local variables */
    bool b_same;

    b_same = u_stricmp(pc_a, pc_b) == 0;
    return b_same;
}

/* the link's state from its name */
static int32_t state_of(const char *pc_word)
{
/* local variables */
    int32_t i32_state;

/* start values */
    i32_state = S_DISC;
    if (is(pc_word, "connected"))
    {
        i32_state = S_CONN;
    }
/* on the way */
    else if (is(pc_word, "connecting"))
    {
        i32_state = S_CONNECTING;
    }
    else
    {
/* anything else: not connected */
    }
    return i32_state;
}

/* the message line, of two parts */
static void say(const char *pc_first, const char *pc_second)
{
    u_strncpy(u_strncpy(g_ac_msg, pc_first, MSG_MAX), pc_second, MSG_MAX - u_strlen(pc_first));
}

/* the answer to "info": the whole state of the Bluetooth part */
static void line_info(char *pc_text)
{
    g_i32_state = state_of(word(&pc_text));
/* is a search running? */
    g_i32_scanning = 0;
    if (is(word(&pc_text), "scan"))
    {
        g_i32_scanning = YES;
    }
/* the MAC address is not used */
    word(&pc_text);
    g_i32_vol = num(word(&pc_text));
    u_strncpy(g_ac_pin, word(&pc_text), PIN_MAX);
/* the sound's source */
    g_i32_src_tone = 0;
    if (is(word(&pc_text), "tone"))
    {
        g_i32_src_tone = YES;
    }
/* the audio counters and the measured rates */
    g_ui32_under = (uint32_t)num(word(&pc_text));
    g_ui32_ovf = (uint32_t)num(word(&pc_text));
    g_ui32_fix = (uint32_t)num(word(&pc_text));
/* the two rates, the rate corrections */
    g_ui32_i2s_hz = (uint32_t)num(word(&pc_text));
    g_ui32_bt_hz = (uint32_t)num(word(&pc_text));
    g_ui32_rfix = (uint32_t)num(word(&pc_text));
/* the device's name is the rest of the line; "-" = none */
    pc_text = rest(pc_text);
    if (is(pc_text, "-"))
    {
        u_strncpy(g_ac_peer, "", DEV_NAME);
    }
    else
    {
/* its name */
        u_strncpy(g_ac_peer, pc_text, DEV_NAME);
    }
    g_i32_have_info = YES;
    g_i32_miss = 0;
}

/* a pairing event */
static void line_pairing(char *pc_text)
{
/* local variables */
    char *pc_word;

/* start values */
    pc_word = word(&pc_text);
    if (is(pc_word, "pin"))
    {
        say("Pairing, PIN ", word(&pc_text));
    }
/* failed */
    else if (is(pc_word, "failed"))
    {
        say("Pairing failed", "");
    }
    else if (is(pc_word, "next"))
    {
/* next try with pin <code>: three words before the code */
        word(&pc_text);
        word(&pc_text);
        word(&pc_text);
/* the code */
        say("Wrong PIN? Next try: ", word(&pc_text));
    }
    else
    {
        say("Pairing...", "");
    }
}

/* an "EV" line: something happened without being asked for */
static void line_event(char *pc_text)
{
/* local variables */
    char *pc_word;
    int32_t i32_index;

/* start values */
    pc_word = word(&pc_text);
    i32_index = 0;
    if (is(pc_word, "found"))
    {
/* a device of the scan: its number, MAC and rssi (not used), its name */
        i32_index = num(word(&pc_text));
        word(&pc_text);
        word(&pc_text);
/* into the list, if it has room */
        if (i32_index < BT_DEVS)
        {
            u_strncpy(g_ac_dev[i32_index], rest(pc_text), DEV_NAME);
/* the list grows to that number */
            if (i32_index >= g_i32_ndev)
            {
                g_i32_ndev = i32_index + YES;
            }
        }
    }
    else if (is(pc_word, "connecting") || is(pc_word, "connected") || is(pc_word, "disconnected") ||
             is(pc_word, "disconnecting"))
    {
/* the link changed */
        g_i32_state = state_of(pc_word);
        if (g_i32_state == S_CONN)
        {
            say("Connected", "");
        }
/* ask for the whole state */
        g_i32_want_info = YES;
    }
    else if (is(pc_word, "discovery"))
    {
/* the search started or ended */
        g_i32_scanning = 0;
        if (is(word(&pc_text), "on"))
        {
            g_i32_scanning = YES;
        }
    }
/* the volume */
    else if (is(pc_word, "volume"))
    {
/* restored / changed on the speaker */
        g_i32_want_info = YES;
    }
    else if (is(pc_word, "paired"))
    {
        say("Paired", "");
    }
/* pairing in progress */
    else if (is(pc_word, "pairing"))
    {
        line_pairing(pc_text);
    }
    else
    {
/* an event the menu does not show */
    }
}

/* one received line */
static void line(char *pc_text)
{
/* local variables */
    char *pc_word;

    pc_word = word(&pc_text);
    if (is(pc_word, "OK"))
    {
/* only the answer to "info" is used */
        if (is(word(&pc_text), "info"))
        {
            line_info(pc_text);
        }
    }
    else if (is(pc_word, "ERR"))
    {
/* the error's text is shown */
        say(rest(pc_text), "");
    }
    else if (is(pc_word, "EV"))
    {
        line_event(pc_text);
    }
    else
    {
/* boot banner, help text, ... */
    }
}

/* every main loop pass: reads the ESP32's lines; BT_LINE = a line came */
int32_t bt_service(void)
{
/* local variables */
    uint32_t ui32_reg;
    char c_char;
    int32_t i32_got;
/* bytes taken in this call, more to do */
    int32_t i32_count;
    bool b_more;

/* start values */
    ui32_reg = 0;
    c_char = 0;
    i32_got = 0;
/* nothing taken yet */
    i32_count = 0;
    b_more = true;
    while (b_more)
    {
/* the UART's register */
        ui32_reg = UART;
/* nothing received, a gone FPGA (all ones), or enough for this call */
        if (((ui32_reg & UART_VALID) == 0) || (ui32_reg == ALL_ONES) || (i32_count >= RX_PER_CALL))
        {
            b_more = false;
        }
        else
        {
/* one more byte */
            i32_count++;
            c_char = (char)ui32_reg;
/* take the byte; an overrun is cleared, and the line it hit is dropped */
            if ((ui32_reg & UART_OVR) != 0)
            {
                UART = UART_POP | UART_CLR;
                g_i32_rx_skip = YES;
            }
            else
            {
/* taken */
                UART = UART_POP;
            }
            if (c_char == '\n')
            {
/* a complete line */
                g_ac_rx[g_i32_rx_len] = 0;
                if (g_i32_rx_skip == 0)
                {
/* handled, unless an overrun hit it */
                    line(g_ac_rx);
                    i32_got = BT_LINE;
                }
                g_i32_rx_len = 0;
/* a new line */
                g_i32_rx_skip = 0;
            }
            else if (c_char != '\r')
            {
/* one more character; a line that is too long is dropped */
                if (g_i32_rx_len < LINE_MAX)
                {
                    g_ac_rx[g_i32_rx_len] = c_char;
                    g_i32_rx_len++;
                }
                else
                {
/* too long */
                    g_i32_rx_skip = YES;
                }
            }
            else
            {
/* carriage returns are ignored */
            }
        }
    }
/* while the menu is open: ask for info when it is wanted, and every second */
    if ((g_i32_shown != 0) && ((g_i32_want_info != 0) || ((TIMER - g_ui32_info_time) > (INFO_PERIOD_MS * CLK_PER_MS))))
    {
/* a request by the clock means the last one got no answer */
        if ((g_i32_want_info == 0) && (g_i32_miss < MISS_MAX))
        {
            g_i32_miss++;
        }
/* ask again */
        g_i32_want_info = 0;
        g_ui32_info_time = TIMER;
        send("info");
    }
/* a line was handled, or not */
    return i32_got;
}

/* the menu is shown (full-screen OSD) */
void bt_open(void)
{
    g_i32_shown = YES;
/* no PIN typing, nothing missed */
    g_i32_edit = 0;
    g_i32_miss = 0;
/* no message, and the state is asked for at once */
    g_ac_msg[0] = 0;
    g_i32_want_info = YES;
/* the full-screen OSD, empty */
    osd_clear();
    osd_show(OSD_FULL_SCREEN);
}

/* the menu is closed */
void bt_close(void)
{
    g_i32_shown = 0;
}

/* PIN typing; returns YES if a key was taken (redraw) */
static int32_t pin_edit(void)
{
/* local variables */
    uint8_t aui8_events[RAW_EVENTS_MAX];
    uint8_t ui8_mods;
    uint8_t ui8_code;
/* a typed character, a loop counter, the number of events */
    char c_char;
    int32_t i32_index;
    int32_t i32_count;
/* typing ended, the result */
    bool b_end;
    int32_t i32_result;

/* start values */
    ui8_mods = 0;
    ui8_code = 0;
    c_char = 0;
/* the keys pressed since the last call */
    i32_index = 0;
    i32_count = raw_events(aui8_events, &ui8_mods);
/* not ended, nothing to redraw */
    b_end = false;
    i32_result = 0;
/* any key press is a reason to redraw */
    if (i32_count != 0)
    {
        i32_result = YES;
    }
/* key by key */
    while ((i32_index < i32_count) && !b_end)
    {
        ui8_code = aui8_events[i32_index];
        c_char = key_char(ui8_code, ui8_mods);
/* Esc */
        if (ui8_code == HID_ESC)
        {
/* Esc: the PIN stays as it was */
            g_i32_edit = 0;
            b_end = true;
        }
        else if ((ui8_code == HID_BACKSPACE) && (g_i32_edit_len != 0))
        {
/* Backspace */
            g_i32_edit_len--;
            g_ac_edit[g_i32_edit_len] = 0;
        }
        else if ((ui8_code == HID_ENTER) || (ui8_code == HID_KP_ENTER))
        {
/* Enter: empty = auto */
            if (g_i32_edit_len != 0)
            {
                u_strcpy(g_ac_pin, g_ac_edit);
            }
            else
            {
/* auto */
                u_strcpy(g_ac_pin, "auto");
            }
            send2("pin ", g_ac_pin);
            g_i32_edit = 0;
/* typing is over */
            b_end = true;
        }
        else if ((c_char != 0) && (c_char != '-') && (c_char != '_') && (g_i32_edit_len < PIN_MAX))
        {
/* one more character */
            g_ac_edit[g_i32_edit_len] = c_char;
            g_i32_edit_len++;
            g_ac_edit[g_i32_edit_len] = 0;
        }
        else
        {
/* a key that means nothing here */
        }
        i32_index++;
    }
    return i32_result;
}

/* Enter on the selected line */
static void select_item(void)
{
/* local variables */
    uint8_t aui8_events[RAW_EVENTS_MAX];
    uint8_t ui8_mods;
    char ac_num[NUM_BUF];

/* start values */
    ui8_mods = 0;
    switch (g_i32_cur)
    {
    case I_SCAN:
/* a new search: the list is empty again */
        g_i32_ndev = 0;
        g_i32_scanning = YES;
        send("scan");
/* what the user has to do */
        say("Searching: pairing mode on", "");
        break;
/* disconnect */
    case I_DISC:
        send("disconnect");
        break;
/* forget the device */
    case I_FORGET:
        send("forget");
        g_ac_peer[0] = 0;
/* shown at once */
        say("Forgotten", "");
        break;
    case I_PIN:
/* keys already held do not count */
        raw_events(aui8_events, &ui8_mods);
        g_i32_edit = YES;
        g_i32_edit_len = 0;
/* no characters yet */
        g_ac_edit[0] = 0;
        break;
    case I_VOL:
/* the volume is changed with Left / Right */
        break;
    case I_SRC:
/* the machine's sound, or the test tone */
        if (g_i32_src_tone != 0)
        {
            g_i32_src_tone = 0;
            send("src i2s");
        }
        else
        {
/* the test tone */
            g_i32_src_tone = YES;
            send("src tone");
        }
        break;
/* any other line */
    default:
/* a device of the list */
        u_utoa(ac_num, (uint32_t)(g_i32_cur - N_ITEMS));
        send2("connect ", ac_num);
/* shown at once */
        say("Connecting: ", g_ac_dev[g_i32_cur - N_ITEMS]);
        break;
    }
}

/* loader key presses; BT_KEYS_CLOSE = close the menu, BT_KEYS_REDRAW = redraw (PIN typed) */
int32_t bt_keys(uint32_t ui32_keys)
{
/* local variables */
    char ac_num[NUM_BUF];
    int32_t i32_lines;
    int32_t i32_result;

/* start values */
    i32_lines = N_ITEMS + g_i32_ndev;
    i32_result = BT_KEYS_STAY;
/* a new scan found fewer devices */
    if (g_i32_cur >= i32_lines)
    {
        g_i32_cur = i32_lines - YES;
    }
    if (g_i32_edit != 0)
    {
/* while the PIN is typed, the keys are characters */
        if (pin_edit() != 0)
        {
            i32_result = BT_KEYS_REDRAW;
        }
    }
/* F3, back or the menu key close the menu */
    else if ((ui32_keys & (K_BT | K_BACK | K_MENU)) != 0)
    {
        i32_result = BT_KEYS_CLOSE;
    }
    else
    {
/* up and down move the selection */
        if (((ui32_keys & K_UP) != 0) && (g_i32_cur > 0))
        {
            g_i32_cur--;
        }
/* down */
        if (((ui32_keys & K_DOWN) != 0) && (g_i32_cur < (i32_lines - YES)))
        {
            g_i32_cur++;
        }
/* left and right change the volume */
        if ((g_i32_cur == I_VOL) && ((ui32_keys & (K_LEFT | K_RIGHT)) != 0))
        {
            if ((ui32_keys & K_RIGHT) != 0)
            {
                g_i32_vol += VOL_STEP;
            }
            else
            {
/* left: quieter */
                g_i32_vol -= VOL_STEP;
            }
/* inside its range */
            if (g_i32_vol < 0)
            {
                g_i32_vol = 0;
            }
/* not above the maximum */
            if (g_i32_vol > VOL_MAX)
            {
                g_i32_vol = VOL_MAX;
            }
/* sent to the ESP32 */
            u_utoa(ac_num, (uint32_t)g_i32_vol);
            send2("vol ", ac_num);
        }
/* Enter does what the line says, and the state is asked for again */
        if ((ui32_keys & (K_ENTER | K_F11)) != 0)
        {
            select_item();
/* the state is asked for again */
            g_i32_want_info = YES;
        }
    }
    return i32_result;
}

/* the text of one menu item into ac_row */
static void item_text(int32_t i32_item, char ac_row[ROW_BUF])
{
/* local variables */
    char *pc_end;

/* start values */
    pc_end = ac_row;
    switch (i32_item)
    {
/* the fixed texts */
    case I_SCAN:
        u_strcpy(ac_row, " Scan for devices");
        break;
/* disconnect */
    case I_DISC:
        u_strcpy(ac_row, " Disconnect");
        break;
/* forget */
    case I_FORGET:
        u_strcpy(ac_row, " Forget the device");
        break;
/* the PIN */
    case I_PIN:
/* the PIN being typed with a cursor, or the PIN in use, or "auto" */
        pc_end = u_strcpy(ac_row, " PIN: ");
        if (g_i32_edit != 0)
        {
/* with a cursor */
            pc_end = u_strcpy(pc_end, g_ac_edit);
            u_strcpy(pc_end, "_");
        }
        else if (g_ac_pin[0] != 0)
        {
/* the PIN in use */
            u_strcpy(pc_end, g_ac_pin);
        }
        else
        {
/* none: the usual ones are tried */
            u_strcpy(pc_end, "auto");
        }
        break;
    case I_VOL:
/* the volume in percent */
        pc_end = u_strcpy(ac_row, " Volume: ");
        pc_end = u_utoa(pc_end, (uint32_t)((g_i32_vol * VOL_PERCENT) + VOL_ROUND) / VOL_MAX);
/* and the keys that change it */
        u_strcpy(pc_end, "%  (Left/Right)");
        break;
    default:
/* I_SRC */
        if (g_i32_src_tone != 0)
        {
            u_strcpy(ac_row, " Sound: test tone");
        }
        else
        {
/* the machine's sound */
            u_strcpy(ac_row, " Sound: Spectrum");
        }
        break;
    }
}

/* draw the menu */
void bt_draw(void)
{
/* local variables */
    char ac_row[ROW_BUF];
    const char *pc_text;
    char *pc_end;
/* a loop counter, inverse or normal */
    int32_t i32_index;
    int32_t i32_inverse;

/* start values */
    pc_text = "";
    pc_end = ac_row;
    i32_index = 0;
/* normal text; the title */
    i32_inverse = OSD_NORMAL;
    osd_text(ROW_TITLE, 0, " Bluetooth audio", OSD_COLS, OSD_INVERSE);
/* the link's state */
    if (g_i32_miss >= MISS_MAX)
    {
        pc_text = " No answer from the ESP32";
    }
/* no answer yet */
    else if (g_i32_have_info == 0)
    {
        pc_text = " Asking the ESP32...";
    }
/* on the way */
    else if (g_i32_state == S_CONNECTING)
    {
        pc_text = " Connecting...";
    }
/* no link */
    else if (g_i32_state != S_CONN)
    {
        pc_text = " Not connected";
    }
    else
    {
/* connected: with the device's name */
        u_strncpy(u_strcpy(ac_row, " Connected: "), g_ac_peer, PEER_SHOWN);
        pc_text = ac_row;
    }
    osd_text(ROW_STATE, 0, pc_text, OSD_COLS, OSD_NORMAL);
/* searching, or the sample rates: I2S in / Bluetooth out */
    ac_row[0] = 0;
    if (g_i32_scanning != 0)
    {
        u_strcpy(ac_row, " Searching...");
    }
/* connected and measured */
    else if ((g_i32_have_info != 0) && (g_i32_state == S_CONN) && (g_ui32_bt_hz != 0))
    {
        pc_end = u_utoa(u_strcpy(ac_row, " Rate: in "), g_ui32_i2s_hz);
        u_utoa(u_strcpy(pc_end, " out "), g_ui32_bt_hz);
    }
    else
    {
/* nothing to show in this row */
    }
    osd_text(ROW_RATE, 0, ac_row, OSD_COLS, OSD_NORMAL);
/* the items, the selected one inverse */
    for (i32_index = 0; i32_index < N_ITEMS; i32_index++)
    {
        item_text(i32_index, ac_row);
/* inverse if selected */
        i32_inverse = OSD_NORMAL;
        if (i32_index == g_i32_cur)
        {
            i32_inverse = OSD_INVERSE;
        }
/* shown */
        osd_text(ROW_ITEMS + i32_index, 0, ac_row, OSD_COLS, i32_inverse);
    }
/* two empty rows, then the title of the device list */
    osd_text(ROW_ITEMS + N_ITEMS, 0, "", OSD_COLS, OSD_NORMAL);
    osd_text(ROW_DEVS_GAP, 0, "", OSD_COLS, OSD_NORMAL);
/* devices found */
    if (g_i32_ndev != 0)
    {
        pc_text = " Devices (Enter = connect):";
    }
    else if (g_i32_scanning != 0)
    {
/* none yet */
        pc_text = " (searching...)";
    }
    else
    {
        pc_text = " Pairing mode on, then Scan";
    }
    osd_text(ROW_DEVS_TITLE, 0, pc_text, OSD_COLS, OSD_NORMAL);
/* the devices found; a device without a name is shown as "?" */
    for (i32_index = 0; i32_index < BT_DEVS; i32_index++)
    {
        ac_row[0] = 0;
        i32_inverse = OSD_NORMAL;
/* a device */
        if (i32_index < g_i32_ndev)
        {
            pc_end = u_strcpy(ac_row, " ");
            if (g_ac_dev[i32_index][0] != 0)
            {
/* its name */
                u_strcpy(pc_end, g_ac_dev[i32_index]);
            }
            else
            {
                u_strcpy(pc_end, "?");
            }
/* the selected device */
            if ((N_ITEMS + i32_index) == g_i32_cur)
            {
                i32_inverse = OSD_INVERSE;
            }
        }
        osd_text(ROW_DEVS + i32_index, 0, ac_row, OSD_COLS, i32_inverse);
    }
/* audio gaps since the ESP32 started */
    ac_row[0] = 0;
    if ((g_i32_have_info != 0) && (g_i32_state == S_CONN))
    {
        pc_end = u_utoa(u_strcpy(ac_row, " Audio: short "), g_ui32_under);
/* skipped, corrected */
        pc_end = u_utoa(u_strcpy(pc_end, " skip "), g_ui32_ovf);
        u_utoa(u_strcpy(pc_end, " fix "), g_ui32_fix);
    }
    osd_text(ROW_AUDIO, 0, ac_row, OSD_COLS, OSD_NORMAL);
/* the message, and the keys */
    osd_text(ROW_MSG, 0, g_ac_msg, OSD_COLS, OSD_NORMAL);
    if (g_i32_edit != 0)
    {
        pc_text = "Type PIN, Enter (empty = auto)";
    }
    else
    {
/* the menu's keys */
        pc_text = "Enter=select  F3/Esc=exit";
    }
    osd_text(ROW_HELP, 0, pc_text, OSD_COLS, OSD_INVERSE);
}

/* back to the state after a start: the next machine starts the loader again without an ESP32 */
/* restart (esp_hw.cpp; the Bluetooth connection stays) */
void bt_reset(void)
{
    u_memset(g_ac_rx, 0, sizeof g_ac_rx);
/* the line being received */
    g_i32_rx_len = 0;
    g_i32_rx_skip = 0;
/* the menu */
    g_i32_shown = 0;
    g_i32_want_info = 0;
    g_i32_miss = 0;
/* no answer yet */
    g_i32_have_info = 0;
    g_ui32_info_time = 0;
/* the link */
    g_i32_state = 0;
    g_i32_scanning = 0;
/* volume, test tone */
    g_i32_vol = 0;
    g_i32_src_tone = 0;
/* the audio counters */
    g_ui32_under = 0;
    g_ui32_ovf = 0;
    g_ui32_fix = 0;
/* the rates */
    g_ui32_i2s_hz = 0;
    g_ui32_bt_hz = 0;
    g_ui32_rfix = 0;
/* the texts */
    u_memset(g_ac_peer, 0, sizeof g_ac_peer);
    u_memset(g_ac_pin, 0, sizeof g_ac_pin);
    u_memset(g_ac_dev, 0, sizeof g_ac_dev);
/* the list and the PIN typing */
    g_i32_ndev = 0;
    g_i32_cur = 0;
    g_i32_edit = 0;
/* nothing typed, no message */
    g_i32_edit_len = 0;
    u_memset(g_ac_edit, 0, sizeof g_ac_edit);
    u_memset(g_ac_msg, 0, sizeof g_ac_msg);
}
