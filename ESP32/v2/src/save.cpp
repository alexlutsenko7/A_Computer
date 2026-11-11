/* save.c -- recording the Spectrum's SAVE output (MIC, port FE bit 3) into a TAP file */
/* Recording mode is started from the browser ([Save to this folder], name) and */
/* ended with F12: everything the Spectrum saves in between goes into one file. */
/* The recorder (rtl/tape_loader.v) reports every MIC edge with the T-states since */
/* the previous one, and a "gap" event when no edge came for 8000 T-states. While */
/* recording it is armed: the Spectrum is held until each event has been read, so */
/* nothing is lost while the card is written. */
/* Decoding (standard ROM timing, T-states): pilot 2168, sync 667 + 735, bits as two */
/* equal pulses of 855 (0) or 1710 (1). A pulse's length is known only at the next */
/* edge, and the ROM does not always make an edge after the very last pulse, so */
/* each bit is decided by its first pulse; a bit missing its second pulse when the */
/* block ends is completed from the first. A block needs 64 pilot pulses first, */
/* so MIC clicks for sound are ignored. Turbo is on only while a block is saved. */
/* TAP block lengths are written as 0 first and patched when the block ends. */
#ifdef HOST_TEST
#include "../../../ESP32_test/v2/test/host_hw.h"
#else
/* the FPGA's registers */
#include "hw.h"
#endif
#include "hal.h"
/* the card, the recorder's own header, string functions */
#include "fat.h"
#include "save.h"
#include "util.h"

/* pulse lengths in T-states: what counts as a pilot pulse, a sync pulse, half of a bit */
#define PILOT_MIN 1800u
#define PILOT_MAX 2600u
/* a sync pulse */
#define SYNC_MIN 400u
#define SYNC_MAX 1100u
/* half of a bit */
#define HALF_MIN 500u
#define HALF_MAX 2400u
/* between 855 (a 0 bit) and 1710 (a 1 bit) */
#define ONE_HALF 1283u
/* pilot pulses before a block counts */
#define NEXT_PILOT 64
/* events handled in one call of rec_service */
#define EVENTS_PER_CALL 64
/* the pulse length in a recorder event */
#define EVENT_TIME_MASK 0xFFFFFFu
/* a byte, and the second byte of a 16-bit length */
#define BITS_PER_BYTE 8
#define SHIFT_ONE_BIT 1
/* the high byte of a length */
#define SHIFT_BYTE 8
#define LEN_HIGH_BYTE 1u
/* an 8.3 name with its dot and terminator; the name and extension parts of the stored form */
#define FNAME_BUF_LEN 13
#define NAME_PART_LEN 8u
/* the message text, and how long it is shown */
#define MSG_BUF_LEN 40
#define MSG_SHOW_MS 4000u
/* flags as numbers */
#define YES 1
#define ONE_BLOCK 1

/* the decoder's states: looking for a pilot tone, in the pilot, after the first sync pulse, in the data */
enum
{
    D_SEEK,
    D_PILOT,
    D_SYNC,
    D_DATA
};

/* the file's name as shown: 8.3 with its dot */
static char g_ac_fname[FNAME_BUF_LEN];
/* the message for the bottom row */
static char g_ac_msg[MSG_BUF_LEN];
/* F6: no turbo for loading and saving */
int32_t g_i32_slow_mode;
/* recording mode is on */
static int32_t g_i32_on;
/* decoder state, pilot pulses counted */
static int32_t g_i32_state;
static int32_t g_i32_pilot_count;
/* the first pulse of a bit was seen; bits collected in the current byte */
static int32_t g_i32_half;
static int32_t g_i32_nbits;
/* a block is being written; blocks written so far */
static int32_t g_i32_in_block;
static int32_t g_i32_blocks;
/* length of a bit's first pulse; bytes of the block; where the block's length is in the file */
static uint32_t g_ui32_first_half;
static uint32_t g_ui32_blk_len;
static uint32_t g_ui32_len_pos;
/* the byte being collected */
static uint8_t g_ui8_cur;
/* the message is shown until this time (TIMER); 0 = no message */
static uint32_t g_ui32_msg_until;

#ifndef HOST_TEST
/* the next recorder event */
static uint32_t rec_event(void)
{
/* local variables */
    uint32_t ui32_event;

    ui32_event = REC;
    return ui32_event;
}

/* the recorder's control register */
static void rec_ctl(uint32_t ui32_value)
{
    RECCTL = ui32_value;
}

/* the tape control register (turbo) */
static void tape_ctl(uint32_t ui32_value)
{
    TAPE = ui32_value;
}

/* the time now, in FPGA clocks */
static uint32_t timer_now(void)
{
/* local variables */
    uint32_t ui32_now;

/* start values */
    ui32_now = TIMER;
    return ui32_now;
}
#endif

/* a message of two parts for the bottom row, shown for 4 seconds */
static void message(const char *pc_first, const char *pc_second)
{
/* local variables */
    char *pc_end;

    pc_end = u_strcpy(g_ac_msg, pc_first);
    u_strcpy(pc_end, pc_second);
/* shown until then */
    g_ui32_msg_until = timer_now() + (MSG_SHOW_MS * CLK_PER_MS);
}

/* the recorder off */
static void stop_hw(void)
{
    rec_ctl(0);
/* turbo off (the player is not running while recording) */
    tape_ctl(0);
}

/* a card error ends recording mode */
static void fail(void)
{
    message("Save failed: card error", "");
/* recording mode off, the recorder stopped */
    g_i32_on = 0;
    stop_hw();
}

/* one byte to the file */
static void put(uint8_t ui8_byte)
{
/* a card error ends recording mode */
    if ((g_i32_on != 0) && (fw_putc(&g_s_fw_file, ui8_byte) != FAT_OK))
    {
        fail();
    }
}

/* a TAP block starts: its length is written as 0 and patched at the end */
static void begin_block(void)
{
    g_ui32_len_pos = g_s_fw_file.ui32_size;
/* nothing in it yet */
    g_ui32_blk_len = 0;
    g_i32_in_block = YES;
/* no bit in progress */
    g_i32_half = 0;
    g_i32_nbits = 0;
/* the two bytes of the length */
    put(0);
    put(0);
}

/* one bit, decided by the length of its first pulse */
static void bit(uint32_t ui32_first)
{
    uint8_t ui8_bit;

    ui8_bit = 0;
/* a long pulse is a 1 */
    if (ui32_first > ONE_HALF)
    {
        ui8_bit = YES;
    }
/* into the byte, most significant bit first */
    g_ui8_cur = (uint8_t)((g_ui8_cur << SHIFT_ONE_BIT) | ui8_bit);
    g_i32_nbits++;
/* a complete byte goes to the file */
    if (g_i32_nbits == BITS_PER_BYTE)
    {
        g_i32_nbits = 0;
/* one more byte in the block */
        g_ui32_blk_len++;
        put(g_ui8_cur);
    }
}

/* the block ended: complete the last bit and patch the block's length */
static void end_block(void)
{
    if (g_i32_in_block != 0)
    {
/* last pulse without a closing edge */
        if (g_i32_half != 0)
        {
            bit(g_ui32_first_half);
            g_i32_half = 0;
        }
/* the block is complete */
        g_i32_in_block = 0;
        g_i32_blocks++;
/* the length, low byte first */
        if ((g_i32_on != 0) &&
            ((fw_patch(&g_s_fw_file, g_ui32_len_pos, (uint8_t)g_ui32_blk_len) != FAT_OK) ||
             (fw_patch(&g_s_fw_file, g_ui32_len_pos + LEN_HIGH_BYTE, (uint8_t)(g_ui32_blk_len >> SHIFT_BYTE)) != FAT_OK)))
        {
            fail();
        }
    }
}

/* look for the next pilot tone; b_pilot: the pulse just seen already is a pilot pulse */
static void seek(bool b_pilot)
{
    g_i32_state = D_SEEK;
    g_i32_pilot_count = 0;
/* that pulse counts */
    if (b_pilot)
    {
        g_i32_pilot_count = YES;
    }
/* normal speed between blocks */
    tape_ctl(0);
}

/* turbo for a block (28 MHz), unless F6 chose normal speed */
static void block_speed(void)
{
    if (g_i32_slow_mode != 0)
    {
        tape_ctl(0);
    }
    else
    {
/* turbo */
        tape_ctl(TAPE_TURBO);
    }
}

/* one MIC edge, ui32_time T-states after the previous one */
static void edge(uint32_t ui32_time)
{
/* local variables */
    bool b_pilot;
    bool b_sync;

/* start values */
    b_pilot = (ui32_time >= PILOT_MIN) && (ui32_time <= PILOT_MAX);
    b_sync = (ui32_time >= SYNC_MIN) && (ui32_time <= SYNC_MAX);
/* what the pulse means depends on where the decoder is */
    switch (g_i32_state)
    {
    case D_SEEK:
/* count pilot pulses in a row */
        if (b_pilot)
        {
            g_i32_pilot_count++;
        }
        else
        {
            g_i32_pilot_count = 0;
        }
/* enough of them: a block is coming */
        if (g_i32_pilot_count >= NEXT_PILOT)
        {
            g_i32_state = D_PILOT;
/* the block's speed */
            block_speed();
        }
        break;
    case D_PILOT:
/* the pilot ends with the first sync pulse; anything else is noise */
        if (b_sync)
        {
            g_i32_state = D_SYNC;
        }
/* noise: search again */
        else if (!b_pilot)
        {
            seek(false);
        }
        else
        {
/* still the pilot */
        }
        break;
    case D_SYNC:
/* the second sync pulse starts the data */
        if (b_sync)
        {
            g_i32_state = D_DATA;
            begin_block();
        }
        else
        {
/* not a sync pulse: search again */
            seek(b_pilot);
        }
        break;
    default:
/* D_DATA */
        if ((ui32_time < HALF_MIN) || (ui32_time > HALF_MAX))
        {
/* not a bit: the block ended */
            end_block();
            seek(b_pilot);
        }
        else if (g_i32_half == 0)
        {
/* the first pulse of a bit */
            g_ui32_first_half = ui32_time;
            g_i32_half = YES;
        }
        else
        {
/* the second pulse: the bit is complete */
            g_i32_half = 0;
            bit(g_ui32_first_half);
        }
        break;
    }
}

/* start recording mode into a new file: FAT_OK, else FAT_* error */
int32_t rec_start(uint32_t ui32_dir, const char ac_name11[FAT_NAME11_LEN])
{
/* local variables */
    uint32_t ui32_index;
    char *pc_dst;
    int32_t i32_result;

/* start values */
    ui32_index = 0;
    pc_dst = g_ac_fname;
/* the file */
    i32_result = fw_create(&g_s_fw_file, ui32_dir, ac_name11);
    if (i32_result == FAT_OK)
    {
/* the name as shown: the name part, a dot, the extension part */
        while ((ui32_index < NAME_PART_LEN) && (ac_name11[ui32_index] != ' '))
        {
            *pc_dst = ac_name11[ui32_index];
/* both places on */
            pc_dst++;
            ui32_index++;
        }
/* the dot */
        *pc_dst = '.';
        pc_dst++;
/* the extension starts at character 8 */
        ui32_index = NAME_PART_LEN;
        while ((ui32_index < FAT_NAME11_LEN) && (ac_name11[ui32_index] != ' '))
        {
/* one character over */
            *pc_dst = ac_name11[ui32_index];
            pc_dst++;
            ui32_index++;
        }
/* the end of the text */
        *pc_dst = 0;
/* recording mode on, nothing written yet */
        g_i32_on = YES;
        g_i32_blocks = 0;
        g_i32_in_block = 0;
/* search for a pilot, no message */
        seek(false);
        g_ui32_msg_until = 0;
/* drop an old event, then hold the Spectrum for every new one */
        (void)rec_event();
        rec_ctl(REC_ARMED);
    }
    return i32_result;
}

/* call often while recording: decodes MIC edges, appends blocks */
void rec_service(void)
{
/* local variables */
    uint32_t ui32_event;
    int32_t i32_count;
    bool b_more;

/* start values */
    ui32_event = 0;
    i32_count = 0;
    b_more = true;
/* a limited number of events per call, so the caller's other work goes on */
    while ((g_i32_on != 0) && (i32_count < EVENTS_PER_CALL) && b_more)
    {
        ui32_event = rec_event();
        if ((ui32_event & REC_PEND) == 0)
        {
/* no event waiting */
            b_more = false;
        }
        else if ((ui32_event & REC_GAP) != 0)
        {
/* silence: a block in progress ends, and the search starts again */
            if (g_i32_state == D_DATA)
            {
                end_block();
            }
/* back to the search if it had gone anywhere */
            if ((g_i32_state != D_SEEK) || (g_i32_pilot_count != 0))
            {
                seek(false);
            }
        }
        else
        {
/* an edge with its time */
            edge(ui32_event & EVENT_TIME_MASK);
        }
        i32_count++;
    }
}

/* stop recording mode and close the file (an empty file is removed) */
void rec_end(void)
{
    char *pc_end;

    pc_end = g_ac_msg;
/* a block in progress ends here */
    if ((g_i32_on != 0) && (g_i32_in_block != 0))
    {
        end_block();
    }
/* still on: end_block did not fail */
    if (g_i32_on != 0)
    {
        g_i32_on = 0;
        stop_hw();
/* no block at all */
        if (g_i32_blocks == 0)
        {
/* nothing saved: no file */
            if (fw_discard(&g_s_fw_file) == FAT_OK)
            {
                message("Nothing saved", "");
            }
            else
            {
                message("Save failed: card error", "");
            }
        }
/* the file is closed */
        else if (fw_close(&g_s_fw_file) != FAT_OK)
        {
            message("Save failed: card error", "");
        }
        else
        {
/* "Saved NAME.TAP (n blocks)" */
            message("Saved ", g_ac_fname);
            pc_end = g_ac_msg + u_strlen(g_ac_msg);
/* the number of blocks in brackets */
            pc_end = u_strcpy(pc_end, " (");
            pc_end = u_utoa(pc_end, (uint32_t)g_i32_blocks);
/* singular or plural */
            if (g_i32_blocks == ONE_BLOCK)
            {
                u_strcpy(pc_end, " block)");
            }
            else
            {
                u_strcpy(pc_end, " blocks)");
            }
        }
    }
}

/* REC_YES = recording mode is on */
int32_t rec_active(void)
{
/* local variables */
    int32_t i32_result;

    i32_result = g_i32_on;
    return i32_result;
}

/* the speed mode changed: a block being saved changes speed at once */
void rec_speed(void)
{
    if ((g_i32_on != 0) && (g_i32_state != D_SEEK))
    {
        block_speed();
    }
}

/* status for the bottom row into pc_text; 0 = nothing to show */
int32_t rec_status(char *pc_text)
{
/* local variables */
    char *pc_end;
    uint32_t ui32_shown;
    int32_t i32_result;

/* start values */
    pc_end = pc_text;
    ui32_shown = 0;
    i32_result = 0;
/* while recording */
    if (g_i32_on != 0)
    {
/* "Rec NAME.TAP: n F12=stop", the block in progress counted */
        ui32_shown = (uint32_t)g_i32_blocks;
        if (g_i32_in_block != 0)
        {
            ui32_shown++;
        }
/* the text */
        pc_end = u_strcpy(pc_text, "Rec ");
        pc_end = u_strcpy(pc_end, g_ac_fname);
        pc_end = u_strcpy(pc_end, ": ");
/* the number of blocks */
        pc_end = u_utoa(pc_end, ui32_shown);
        u_strcpy(pc_end, " F12=stop");
        i32_result = REC_YES;
    }
/* not recording: the last message, while it is due */
    else if ((g_ui32_msg_until != 0) && ((int32_t)(timer_now() - g_ui32_msg_until) < 0))
    {
/* the last message, while its time runs */
        u_strcpy(pc_text, g_ac_msg);
        i32_result = REC_YES;
    }
    else
    {
/* nothing to show */
        g_ui32_msg_until = 0;
    }
    return i32_result;
}

/* back to the state after a start: the next machine starts the loader again without an ESP32 */
/* restart (esp_hw.cpp; the Bluetooth connection stays) */
void save_reset(void)
{
    g_i32_on = 0;
/* the pilot search */
    g_i32_state = 0;
    g_i32_pilot_count = 0;
/* the bit decoder */
    g_i32_half = 0;
    g_i32_nbits = 0;
/* the blocks */
    g_i32_in_block = 0;
    g_i32_blocks = 0;
/* the block */
    g_ui32_first_half = 0;
    g_ui32_blk_len = 0;
/* where its length is, the byte being built */
    g_ui32_len_pos = 0;
    g_ui8_cur = 0;
/* the texts */
    u_memset(g_ac_fname, 0, sizeof g_ac_fname);
    g_ui32_msg_until = 0;
    u_memset(g_ac_msg, 0, sizeof g_ac_msg);
/* turbo */
    g_i32_slow_mode = 0;
}
