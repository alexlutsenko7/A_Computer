/* tape.c -- TAP / TZX file -> pulse player commands */
/* Every block becomes PULSE / LEVEL / DATA commands (durations in T-states, */
/* see hal.h). Each block starts with CMD_MARK(block index), so the CPU can */
/* tell which block the hardware is playing. */
/* Signal conventions (same as tools/tzxref.py, which the host test compares against): */
/*   - the line starts low (100 ms low lead-in); */
/*   - PULSE n holds the current level for n T-states, then toggles; */
/*   - a pause after a block (or TZX 0x20): if the level is high, 1 ms high first, */
/*     then low for the rest of the pause; */
/*   - TAP: every block is a standard ROM block with a 1000 ms pause. */
/* TZX blocks played: 10 11 12 13 14 15 20 2B; control: 21 22 23 24 25 26 27; */
/* skipped: 18 19 28 2A (this is a 128K) 30 31 32 33 34 35 40 5A and unknown blocks */
/* (by their length field). */
#include <stddef.h>
#include "tape.h"
/* the loader's string functions and the platform */
#include "util.h"
#include "hal.h"

/* T-states in one millisecond (3.5 MHz) */
#define T_MS 3500u
/* the standard ROM block: pilot, the two sync pulses, a 0 bit, a 1 bit */
#define STD_PILOT_LEN 2168u
#define STD_SYNC1_LEN 667u
#define STD_SYNC2_LEN 735u
/* a 0 bit, a 1 bit */
#define STD_ZERO_LEN 855u
#define STD_ONE_LEN 1710u
/* pilot pulses of a header block (flag byte below 0x80) and of a data block */
#define STD_PILOT_HEADER 8063u
#define STD_PILOT_DATA 3223u
#define STD_FLAG_DATA 0x80
/* the pause after a TAP block, and the lead-in before the first block */
#define TAP_PAUSE_MS 1000u
#define LEAD_IN_MS 100u
/* a byte, and what a step may do at most */
#define BITS_PER_BYTE 8
#define STEP_MAX_CMDS 8u
/* no first byte read ahead */
#define NO_BYTE (-1)
/* the last data byte */
#define LAST_BYTE 1u
#define BITS_MIN 1
/* little-endian fields */
#define SHIFT_BYTE 8
#define SHIFT_WORD 16
/* a command's kind is in its top two bits */
#define KIND_SHIFT 30
#define KIND_PULSE 0u
/* set a level, data */
#define KIND_LEVEL 1u
#define KIND_DATA 2u
/* fields of the commands, as emit() reads them back to follow the line's level */
#define LEVEL_BIT 1u
#define SAMPLES_FLAG 0x800u
/* samples: their count, the last one's bit */
#define SAMPLE_COUNT_MASK 7u
#define SAMPLE_LAST_BIT 7u
/* the signal levels */
#define LEVEL_LOW 0
#define LEVEL_HIGH 1
/* flags as numbers */
#define YES 1
#define ONE 1u
/* the TZX file: its header (signature + two version bytes) */
#define TZX_HEADER_LEN 10
#define TZX_SIG_LEN 8
#define TZX_SIG_END 0x1A
/* TZX block IDs */
#define TZX_STD 0x10
#define TZX_TURBO 0x11
#define TZX_TONE 0x12
/* pulse sequence, pure data, direct recording */
#define TZX_PULSES 0x13
#define TZX_PURE_DATA 0x14
#define TZX_DIRECT 0x15
/* pause, group */
#define TZX_PAUSE 0x20
#define TZX_GROUP_START 0x21
#define TZX_GROUP_END 0x22
/* jump, loop */
#define TZX_JUMP 0x23
#define TZX_LOOP_START 0x24
#define TZX_LOOP_END 0x25
/* call sequence, select */
#define TZX_CALL 0x26
#define TZX_RETURN 0x27
#define TZX_SELECT 0x28
/* signal level, texts */
#define TZX_SET_LEVEL 0x2B
#define TZX_TEXT 0x30
#define TZX_MESSAGE 0x31
/* archive info, hardware, emulation info */
#define TZX_ARCHIVE 0x32
#define TZX_HARDWARE 0x33
#define TZX_EMULATION 0x34
/* custom info, snapshot, glue */
#define TZX_CUSTOM 0x35
#define TZX_SNAPSHOT 0x40
#define TZX_GLUE 0x5A
/* TZX block bodies: bytes before a length field, or the whole fixed length */
#define SKIP_STD_PAUSE 2u
#define SKIP_TURBO_HEAD 15u
#define SKIP_TONE 4u
/* pulse sequence, pure data, direct recording */
#define SKIP_PULSE_LEN 2u
#define SKIP_PURE_DATA_HEAD 7u
#define SKIP_DIRECT_HEAD 5u
/* a 16-bit value, a call offset, a message's time */
#define SKIP_WORD 2u
#define SKIP_CALL_ENTRY 2u
#define SKIP_MESSAGE_TIME 1u
/* hardware entry, emulation info, a custom block's ID */
#define SKIP_HARDWARE_ENTRY 3u
#define SKIP_EMULATION 8u
#define SKIP_CUSTOM_ID 10u
/* snapshot type, glue */
#define SKIP_SNAPSHOT_TYPE 1u
#define SKIP_GLUE 9u
/* a jump of 0 would loop for ever: it is taken as 1 */
#define JUMP_MIN 1u
/* loops: the last pass does not jump back */
#define LOOP_LAST_PASS 1u
/* set-level block: its length field counts the level byte */
#define SET_LEVEL_LEN 1u

/* the generator's states; up to G_DIRECT they produce commands */
enum
{
    G_BLOCK,
    G_PILOT,
    G_SYNC,
    G_DATA,
    G_PAUSE,
    G_TONE,
    G_SEQ,
    G_DIRECT,
    G_STOP,
    G_END,
    G_ERR
};

/* "ZXTape!" 0x1A, the start of a TZX file */
static const char g_ac_tzx_sig[TZX_SIG_LEN] = { 'Z', 'X', 'T', 'a', 'p', 'e', '!', TZX_SIG_END };
/* the file being played */
static FFILE *g_ps_file;
/* 1 = TZX; the line's level; the generator's state */
static uint8_t g_ui8_tzx;
static uint8_t g_ui8_level;
static uint8_t g_ui8_state;
/* bits used in the last data byte; the block has sync pulses */
static uint8_t g_ui8_last_bits;
static uint8_t g_ui8_has_sync;
/* index of the next block in the file, and of the block being generated */
static uint32_t g_ui32_blk_next;
static uint32_t g_ui32_blk_cur;
/* the block's pulse lengths and counts */
static uint32_t g_ui32_pilot_len;
static uint32_t g_ui32_pilot_cnt;
/* the two sync pulses */
static uint32_t g_ui32_sync1;
static uint32_t g_ui32_sync2;
/* a 0 bit, a 1 bit */
static uint32_t g_ui32_zero;
static uint32_t g_ui32_one;
/* data bytes left, and the pause after the block in T-states */
static uint32_t g_ui32_data_left;
static uint32_t g_ui32_pause_t;
/* first data byte, already read (NO_BYTE: none) */
static int32_t g_i32_first;
/* pure tone, pulse sequence, direct recording */
static uint32_t g_ui32_tone_len;
static uint32_t g_ui32_tone_cnt;
/* pulses left in a sequence, T-states per sample */
static uint32_t g_ui32_seq_cnt;
static uint32_t g_ui32_dir_tps;
/* loop: passes left, block to jump back to */
static uint32_t g_ui32_loop_cnt;
static uint32_t g_ui32_loop_blk;
/* call sequence: number of calls, the current one, where the list is, the calling block */
static uint32_t g_ui32_call_n;
static uint32_t g_ui32_call_i;
/* where the list is, the calling block */
static uint32_t g_ui32_call_pos;
static uint32_t g_ui32_call_blk;
/* commands emitted so far */
static uint32_t g_ui32_n_emit;

/* one command into the FIFO; the line's level is followed */
static void emit(uint32_t ui32_cmd)
{
/* local variables */
    uint32_t ui32_kind;

/* start values */
    ui32_kind = ui32_cmd >> KIND_SHIFT;
    g_ui32_n_emit++;
    fifo_push(ui32_cmd);
/* a pulse toggles, a level command sets, samples end at their last sample */
    if (ui32_kind == KIND_PULSE)
    {
        g_ui8_level ^= LEVEL_BIT;
    }
/* a level command sets it */
    else if (ui32_kind == KIND_LEVEL)
    {
        g_ui8_level = (uint8_t)((ui32_cmd >> CMD_LEVEL_SHIFT) & LEVEL_BIT);
    }
    else if ((ui32_kind == KIND_DATA) && ((ui32_cmd & SAMPLES_FLAG) != 0))
    {
/* SAMPLES: level of the last sample */
        g_ui8_level = (uint8_t)((ui32_cmd >> (SAMPLE_LAST_BIT - ((ui32_cmd >> CMD_COUNT_SHIFT) & SAMPLE_COUNT_MASK))) & LEVEL_BIT);
    }
    else
    {
/* data bits are pairs of pulses, the other commands make no edge: the level stays */
    }
}

/* ui32_count equal pulses (pilot, pure tone) */
static void emit_pulses(uint32_t ui32_len, uint32_t ui32_count)
{
/* local variables */
    uint32_t ui32_cmd;

    ui32_cmd = CMD_PULSE(ui32_len);
    g_ui32_n_emit += ui32_count;
/* an odd number of pulses changes the level */
    g_ui8_level ^= (uint8_t)(ui32_count & LEVEL_BIT);
    while (ui32_count != 0)
    {
/* one more pulse */
        fifo_push(ui32_cmd);
        ui32_count--;
    }
}

/* next byte of the file; 0 behind its end */
static uint32_t rd8(void)
{
/* local variables */
    int32_t i32_char;
    uint32_t ui32_value;

/* start values */
    i32_char = ff_getc(g_ps_file);
    ui32_value = 0;
/* the end of the file reads as 0 */
    if (i32_char >= 0)
    {
        ui32_value = (uint32_t)i32_char;
    }
    return ui32_value;
}

/* 16 bits, low byte first */
static uint32_t rd16(void)
{
/* local variables */
    uint32_t ui32_value;

/* start values */
    ui32_value = rd8();
    ui32_value |= rd8() << SHIFT_BYTE;
    return ui32_value;
}

/* 24 bits, low byte first */
static uint32_t rd24(void)
{
/* local variables */
    uint32_t ui32_value;

/* start values */
    ui32_value = rd16();
    ui32_value |= rd8() << SHIFT_WORD;
    return ui32_value;
}

/* 32 bits, low byte first */
static uint32_t rd32(void)
{
/* local variables */
    uint32_t ui32_value;

/* start values */
    ui32_value = rd16();
    ui32_value |= rd16() << SHIFT_WORD;
    return ui32_value;
}

/* skip bytes of the file */
static void skip(uint32_t ui32_count)
{
    ff_seek(g_ps_file, ff_tell(g_ps_file) + ui32_count);
}

/* skip the body of a TZX block (the ID byte has been read) */
static void body_skip(uint32_t ui32_id)
{
    switch (ui32_id)
    {
    case TZX_STD:
/* pause, then a 16-bit length and the data */
        skip(SKIP_STD_PAUSE);
        skip(rd16());
        break;
/* turbo block */
    case TZX_TURBO:
/* timings, then a 24-bit length and the data */
        skip(SKIP_TURBO_HEAD);
        skip(rd24());
        break;
/* pure tone: length and count */
    case TZX_TONE:
        skip(SKIP_TONE);
        break;
/* pulse sequence */
    case TZX_PULSES:
/* a count, then that many 16-bit pulse lengths */
        skip(SKIP_PULSE_LEN * rd8());
        break;
/* pure data: its head */
    case TZX_PURE_DATA:
        skip(SKIP_PURE_DATA_HEAD);
/* then a 24-bit length and the data */
        skip(rd24());
        break;
    case TZX_DIRECT:
/* direct recording: the same shape */
        skip(SKIP_DIRECT_HEAD);
        skip(rd24());
        break;
/* pause, jump, loop start */
    case TZX_PAUSE:
    case TZX_JUMP:
    case TZX_LOOP_START:
/* one 16-bit value */
        skip(SKIP_WORD);
        break;
/* group start, text description */
    case TZX_GROUP_START:
    case TZX_TEXT:
/* a length byte and a text */
        skip(rd8());
        break;
/* blocks without a body */
    case TZX_GROUP_END:
    case TZX_LOOP_END:
    case TZX_RETURN:
/* no body */
        break;
    case TZX_CALL:
/* a count, then that many 16-bit offsets */
        skip(SKIP_CALL_ENTRY * rd16());
        break;
/* select block, archive info */
    case TZX_SELECT:
    case TZX_ARCHIVE:
/* a 16-bit length and the body */
        skip(rd16());
        break;
    case TZX_MESSAGE:
/* its time, then a length byte and the text */
        skip(SKIP_MESSAGE_TIME);
        skip(rd8());
        break;
/* hardware type */
    case TZX_HARDWARE:
/* a count, then that many 3-byte entries */
        skip(SKIP_HARDWARE_ENTRY * rd8());
        break;
/* emulation info: fixed length */
    case TZX_EMULATION:
        skip(SKIP_EMULATION);
        break;
/* custom info */
    case TZX_CUSTOM:
/* an ID text, then a 32-bit length and the body */
        skip(SKIP_CUSTOM_ID);
/* the body's length and the body */
        skip(rd32());
        break;
    case TZX_SNAPSHOT:
/* its type, then a 24-bit length and the body */
        skip(SKIP_SNAPSHOT_TYPE);
        skip(rd24());
        break;
/* glue block: fixed length */
    case TZX_GLUE:
        skip(SKIP_GLUE);
        break;
/* any other ID */
    default:
/* 18 19 2A 2B and unknown (TZX 1.10 rule): a 32-bit length and the body */
        skip(rd32());
        break;
    }
}

/* position the file at a block */
static void goto_block(uint32_t ui32_block)
{
/* local variables */
    uint32_t ui32_index;
    int32_t i32_id;
    bool b_end;

/* start values */
    ui32_index = 0;
    i32_id = 0;
    b_end = false;
/* from the first block: behind the header of a TZX file, at the start of a TAP file */
    if (g_ui8_tzx != 0)
    {
        ff_seek(g_ps_file, TZX_HEADER_LEN);
    }
    else
    {
        ff_seek(g_ps_file, 0);
    }
/* skip the blocks before it */
    while ((ui32_index < ui32_block) && !b_end)
    {
        if (g_ui8_tzx != 0)
        {
            i32_id = ff_getc(g_ps_file);
/* the file ends before the block */
            if (i32_id < 0)
            {
                b_end = true;
            }
            else
            {
                body_skip((uint32_t)i32_id);
            }
        }
        else
        {
/* a TAP block: a 16-bit length and the data */
            skip(rd16());
        }
        ui32_index++;
    }
    g_ui32_blk_next = ui32_block;
}

/* a standard ROM block of ui32_len bytes with a pause after it */
static void std_block(uint32_t ui32_len, uint32_t ui32_pause_ms)
{
    g_ui32_pilot_len = STD_PILOT_LEN;
/* the two sync pulses */
    g_ui32_sync1 = STD_SYNC1_LEN;
    g_ui32_sync2 = STD_SYNC2_LEN;
/* the bit lengths */
    g_ui32_zero = STD_ZERO_LEN;
    g_ui32_one = STD_ONE_LEN;
/* whole bytes, with sync pulses */
    g_ui8_last_bits = BITS_PER_BYTE;
    g_ui8_has_sync = YES;
/* the pause and the data */
    g_ui32_pause_t = ui32_pause_ms * T_MS;
    g_ui32_data_left = ui32_len;
/* the flag byte is read below */
    g_i32_first = NO_BYTE;
    if (ui32_len != 0)
    {
/* the flag byte decides the length of the pilot: long for a header, short for data */
        g_i32_first = (int32_t)rd8();
        if ((g_i32_first & STD_FLAG_DATA) != 0)
        {
            g_ui32_pilot_cnt = STD_PILOT_DATA;
        }
        else
        {
/* a header */
            g_ui32_pilot_cnt = STD_PILOT_HEADER;
        }
        g_ui8_state = G_PILOT;
    }
    else
    {
/* an empty block is only its pause */
        g_ui8_state = G_PAUSE;
    }
}

/* a TZX block with the given ID: read its parameters and set the generator up */
static void tzx_block(int32_t i32_id)
{
/* local variables */
    uint32_t ui32_value;
    uint32_t ui32_len;

/* start values */
    ui32_value = 0;
    ui32_len = 0;
/* by the block's ID */
    switch (i32_id)
    {
    case TZX_STD:
/* pause, then the length */
        ui32_value = rd16();
        std_block(rd16(), ui32_value);
        break;
/* turbo speed data */
    case TZX_TURBO:
/* every timing of a standard block is given */
        g_ui32_pilot_len = rd16();
        g_ui32_sync1 = rd16();
        g_ui32_sync2 = rd16();
/* the bit lengths, the pilot's pulse count */
        g_ui32_zero = rd16();
        g_ui32_one = rd16();
        g_ui32_pilot_cnt = rd16();
/* bits of the last byte, pause, length */
        g_ui8_last_bits = (uint8_t)rd8();
        g_ui32_pause_t = rd16() * T_MS;
        g_ui32_data_left = rd24();
/* with sync pulses */
        g_ui8_has_sync = YES;
/* without pilot pulses it starts with the sync */
        if (g_ui32_pilot_cnt != 0)
        {
            g_ui8_state = G_PILOT;
        }
        else
        {
/* straight to the sync */
            g_ui8_state = G_SYNC;
        }
        break;
/* pure tone: pulse length and count */
    case TZX_TONE:
        g_ui32_tone_len = rd16();
        g_ui32_tone_cnt = rd16();
/* played by step() */
        g_ui8_state = G_TONE;
        break;
/* pulse sequence: the count */
    case TZX_PULSES:
        g_ui32_seq_cnt = rd8();
/* its lengths are read one per step */
        g_ui8_state = G_SEQ;
        break;
/* pure data: the two bit lengths */
    case TZX_PURE_DATA:
        g_ui32_zero = rd16();
/* then the bits of the last byte */
        g_ui32_one = rd16();
        g_ui8_last_bits = (uint8_t)rd8();
/* pause, length */
        g_ui32_pause_t = rd16() * T_MS;
        g_ui32_data_left = rd24();
        g_ui8_has_sync = 0;
/* no pilot or sync: just the bit lengths */
        g_ui8_state = G_SYNC;
        break;
/* direct recording: T-states per sample, pause */
    case TZX_DIRECT:
        g_ui32_dir_tps = rd16();
        g_ui32_pause_t = rd16() * T_MS;
/* bits of the last byte, length */
        g_ui8_last_bits = (uint8_t)rd8();
        g_ui32_data_left = rd24();
/* every sample lasts that long */
        emit(CMD_LEN0(g_ui32_dir_tps));
        g_ui8_state = G_DIRECT;
        break;
/* pause, or stop the tape */
    case TZX_PAUSE:
        ui32_value = rd16();
/* a pause of 0 means "stop the tape" */
        if (ui32_value != 0)
        {
            g_ui32_pause_t = ui32_value * T_MS;
            g_ui8_state = G_PAUSE;
        }
        else
        {
/* stop */
            g_ui8_state = G_STOP;
        }
        break;
    case TZX_JUMP:
/* jump (relative) */
        ui32_value = rd16();
        if (ui32_value == 0)
        {
            ui32_value = JUMP_MIN;
        }
/* to the block that many away */
        goto_block(g_ui32_blk_cur + (uint32_t)(int16_t)ui32_value);
        break;
    case TZX_LOOP_START:
/* loop start */
        g_ui32_loop_cnt = rd16();
/* the block the loop comes back to */
        g_ui32_loop_blk = g_ui32_blk_next;
        break;
    case TZX_LOOP_END:
/* loop end */
        if (g_ui32_loop_cnt > LOOP_LAST_PASS)
        {
            g_ui32_loop_cnt--;
/* once more from the loop's start */
            goto_block(g_ui32_loop_blk);
        }
        break;
    case TZX_CALL:
/* call sequence: the list of offsets follows */
        g_ui32_call_n = rd16();
        g_ui32_call_i = 0;
/* where the list is, and the calling block */
        g_ui32_call_pos = ff_tell(g_ps_file);
        g_ui32_call_blk = g_ui32_blk_cur;
/* the first call */
        if (g_ui32_call_n != 0)
        {
/* relative to the call block */
            goto_block(g_ui32_call_blk + (uint32_t)(int16_t)rd16());
        }
        break;
    case TZX_RETURN:
/* return from sequence: the next call, or on behind the call block */
        if (g_ui32_call_n != 0)
        {
            g_ui32_call_i++;
            if (g_ui32_call_i < g_ui32_call_n)
            {
/* the next offset of the list */
                ff_seek(g_ps_file, g_ui32_call_pos + (SKIP_CALL_ENTRY * g_ui32_call_i));
                goto_block(g_ui32_call_blk + (uint32_t)(int16_t)rd16());
            }
            else
            {
/* the sequence is over */
                g_ui32_call_n = 0;
/* on behind the call block */
                goto_block(g_ui32_call_blk + ONE);
            }
        }
        break;
    case TZX_SET_LEVEL:
/* set signal level: a length, the level, and whatever else the length covers */
        ui32_len = rd32();
        ui32_value = rd8();
/* anything beyond the level byte is skipped */
        if (ui32_len > SET_LEVEL_LEN)
        {
            skip(ui32_len - SET_LEVEL_LEN);
        }
/* the level */
        emit(CMD_LEVEL(ui32_value & LEVEL_BIT, 0));
        break;
    default:
/* nothing to play */
        body_skip((uint32_t)i32_id);
        break;
    }
}

/* start the next block of the file */
static void next_block(void)
{
/* local variables */
    int32_t i32_id;
    int32_t i32_low;
    int32_t i32_high;

/* start values */
    i32_id = 0;
    i32_low = 0;
    i32_high = 0;
/* this block and the next one */
    g_ui32_blk_cur = g_ui32_blk_next;
    g_ui32_blk_next++;
    g_i32_first = NO_BYTE;
/* TAP or TZX */
    if (g_ui8_tzx == 0)
    {
/* TAP: a 16-bit length, then a standard block */
        i32_low = ff_getc(g_ps_file);
        i32_high = ff_getc(g_ps_file);
        if ((i32_low < 0) || (i32_high < 0))
        {
/* the end of the file */
            g_ui8_state = G_END;
        }
        else
        {
            emit(CMD_MARK(g_ui32_blk_cur));
            std_block((uint32_t)(i32_low | (i32_high << SHIFT_BYTE)), TAP_PAUSE_MS);
        }
    }
    else
    {
/* TZX: an ID byte, then the block */
        i32_id = ff_getc(g_ps_file);
        if (i32_id < 0)
        {
            g_ui8_state = G_END;
        }
        else
        {
/* mark the block for the display, then read it */
            emit(CMD_MARK(g_ui32_blk_cur));
            tzx_block(i32_id);
        }
    }
}

/* bits of the byte about to be sent: the last byte of a block may be shorter */
static uint32_t byte_bits(void)
{
/* local variables */
    uint32_t ui32_bits;

/* start values */
    ui32_bits = BITS_PER_BYTE;
    if ((g_ui32_data_left == LAST_BYTE) && (g_ui8_last_bits >= BITS_MIN) && (g_ui8_last_bits <= BITS_PER_BYTE))
    {
        ui32_bits = g_ui8_last_bits;
    }
/* 8, or what the last byte has */
    return ui32_bits;
}

/* the pause after a block, in pieces of at most one command's duration */
static void step_pause(void)
{
/* local variables */
    uint32_t ui32_time;
    bool b_low;

    ui32_time = 0;
/* the low part follows, unless the high part used up the pause */
    b_low = true;
    if (g_ui32_pause_t == 0)
    {
        g_ui8_state = G_BLOCK;
/* nothing low to add */
        b_low = false;
    }
    else if (g_ui8_level != 0)
    {
/* 1 ms at the level after the last edge */
        ui32_time = g_ui32_pause_t;
        if (ui32_time > T_MS)
        {
            ui32_time = T_MS;
        }
/* that long high */
        emit(CMD_LEVEL(LEVEL_HIGH, ui32_time));
        g_ui32_pause_t -= ui32_time;
/* a pause shorter than that has no low part */
        if (g_ui32_pause_t == 0)
        {
            b_low = false;
        }
    }
    else
    {
/* the line is low already */
    }
/* then low */
    if (b_low)
    {
        ui32_time = g_ui32_pause_t;
/* at most one command's time */
        if (ui32_time > CMD_MAX_T)
        {
            ui32_time = CMD_MAX_T;
        }
        emit(CMD_LEVEL(LEVEL_LOW, ui32_time));
/* the rest of the pause */
        g_ui32_pause_t -= ui32_time;
    }
}

/* one step: at most 8 commands */
static void step(void)
{
/* local variables */
    uint32_t ui32_byte;
    uint32_t ui32_count;

/* start values */
    ui32_byte = 0;
    ui32_count = 0;
/* by the generator's state */
    switch (g_ui8_state)
    {
    case G_BLOCK:
/* read the next block */
        next_block();
        break;
    case G_PILOT:
/* up to 8 pulses per step */
        ui32_count = g_ui32_pilot_cnt;
        if (ui32_count > STEP_MAX_CMDS)
        {
            ui32_count = STEP_MAX_CMDS;
        }
/* that many pilot pulses */
        emit_pulses(g_ui32_pilot_len, ui32_count);
        g_ui32_pilot_cnt -= ui32_count;
/* the sync follows the pilot */
        if (g_ui32_pilot_cnt == 0)
        {
/* pilot done */
            g_ui8_state = G_SYNC;
        }
        break;
    case G_SYNC:
/* the two sync pulses, if the block has them, then the bit lengths for the data */
        if (g_ui8_has_sync != 0)
        {
            emit(CMD_PULSE(g_ui32_sync1));
            emit(CMD_PULSE(g_ui32_sync2));
        }
/* the bit lengths */
        emit(CMD_LEN0(g_ui32_zero));
        emit(CMD_LEN1(g_ui32_one));
/* the data follows */
        g_ui8_state = G_DATA;
        break;
    case G_DATA:
/* no bytes left: the pause */
        if (g_ui32_data_left == 0)
        {
            g_ui8_state = G_PAUSE;
        }
        else
        {
/* the first byte may have been read already */
            if (g_i32_first >= 0)
            {
                ui32_byte = (uint32_t)g_i32_first;
                g_i32_first = NO_BYTE;
            }
            else
            {
/* read it now */
                ui32_byte = rd8();
            }
/* the byte, with the bits it has */
            emit(CMD_DATA(ui32_byte, byte_bits()));
            g_ui32_data_left--;
        }
        break;
/* the pause after a block */
    case G_PAUSE:
        step_pause();
        break;
/* pure tone */
    case G_TONE:
        if (g_ui32_tone_cnt == 0)
        {
            g_ui8_state = G_BLOCK;
        }
        else
        {
/* up to 8 pulses per step */
            ui32_count = g_ui32_tone_cnt;
            if (ui32_count > STEP_MAX_CMDS)
            {
                ui32_count = STEP_MAX_CMDS;
            }
/* that many pulses */
            emit_pulses(g_ui32_tone_len, ui32_count);
/* the rest of the tone */
            g_ui32_tone_cnt -= ui32_count;
        }
        break;
    case G_SEQ:
/* one pulse of the sequence per step */
        if (g_ui32_seq_cnt == 0)
        {
            g_ui8_state = G_BLOCK;
        }
        else
        {
/* the next pulse length from the file */
            emit(CMD_PULSE(rd16()));
/* one less */
            g_ui32_seq_cnt--;
        }
        break;
    case G_DIRECT:
/* one byte = up to 8 samples */
        if (g_ui32_data_left == 0)
        {
            g_ui8_state = G_PAUSE;
        }
        else
        {
/* the next byte of samples */
            ui32_byte = rd8();
            emit(CMD_SAMP(ui32_byte, byte_bits()));
/* one byte less */
            g_ui32_data_left--;
        }
        break;
    default:
/* stopped, at the end, or in error: nothing to generate */
        break;
    }
}

/* Start generating from a block (0 = start). i32_tzx: 1 = TZX, 0 = TAP. */
void tape_start(FFILE *ps_file, int32_t i32_tzx, uint32_t ui32_block)
{
/* local variables */
    int32_t i32_index;

/* start values */
    i32_index = 0;
    g_ps_file = ps_file;
    g_ui8_tzx = (uint8_t)i32_tzx;
/* the line is low, no loop and no call are open */
    g_ui8_level = 0;
    g_ui32_loop_cnt = 0;
/* no call sequence, the first block next */
    g_ui32_call_n = 0;
    g_ui8_state = G_BLOCK;
/* a TZX file starts with "ZXTape!" 0x1A (then major, minor) */
    if (g_ui8_tzx != 0)
    {
        ff_seek(g_ps_file, 0);
        for (i32_index = 0; (i32_index < TZX_SIG_LEN) && (g_ui8_state != G_ERR); i32_index++)
        {
/* a different byte: not a TZX file */
            if (ff_getc(g_ps_file) != (uint8_t)g_ac_tzx_sig[i32_index])
            {
                g_ui8_state = G_ERR;
            }
        }
    }
/* go to the block and start with the lead-in: 100 ms low */
    if (g_ui8_state != G_ERR)
    {
        goto_block(ui32_block);
        g_ui32_blk_cur = ui32_block;
/* the lead-in */
        emit(CMD_LEVEL(LEVEL_LOW, LEAD_IN_MS * T_MS));
    }
}

/* Generate commands while the FIFO has room; returns TS_*. */
int32_t tape_pump(void)
{
/* local variables */
    uint32_t ui32_room;
    uint32_t ui32_used;
    int32_t i32_result;

/* start values */
    ui32_room = fifo_free();
    ui32_used = 0;
    i32_result = TS_RUN;
/* a step emits at most 8 commands */
    while ((g_ui8_state <= G_DIRECT) && (ui32_room >= STEP_MAX_CMDS))
    {
        ui32_used = g_ui32_n_emit;
        step();
/* the room it used */
        ui32_room -= g_ui32_n_emit - ui32_used;
/* steps that emit nothing: re-check the room */
        if ((g_ui32_n_emit == ui32_used) && (g_ui8_state <= G_DIRECT))
        {
            ui32_room = fifo_free();
        }
    }
/* the generator's state as the caller's result */
    if (g_ui8_state == G_STOP)
    {
        i32_result = TS_STOP;
    }
    else if (g_ui8_state == G_END)
    {
/* the file's end */
        i32_result = TS_END;
    }
    else if (g_ui8_state == G_ERR)
    {
        i32_result = TS_ERR;
    }
    else
    {
/* still generating */
    }
    return i32_result;
}

/* After TS_STOP: go on with the next block. */
void tape_continue(void)
{
    if (g_ui8_state == G_STOP)
    {
        g_ui8_state = G_BLOCK;
    }
}

/* Index of the block being generated. */
uint32_t tape_block(void)
{
/* local variables */
    uint32_t ui32_block;

    ui32_block = g_ui32_blk_cur;
    return ui32_block;
}

/* back to the state after a start: the next machine starts the loader again without an ESP32 */
/* restart (esp_hw.cpp; the Bluetooth connection stays) */
void tape_reset(void)
{
    g_ps_file = NULL;
/* TAP, line low */
    g_ui8_tzx = 0;
    g_ui8_level = 0;
/* the generator */
    g_ui8_state = 0;
    g_ui8_last_bits = 0;
    g_ui8_has_sync = 0;
/* the blocks */
    g_ui32_blk_next = 0;
    g_ui32_blk_cur = 0;
/* the pilot */
    g_ui32_pilot_len = 0;
    g_ui32_pilot_cnt = 0;
/* the pulse lengths */
    g_ui32_sync1 = 0;
    g_ui32_sync2 = 0;
/* the bit lengths */
    g_ui32_zero = 0;
    g_ui32_one = 0;
/* the data */
    g_ui32_data_left = 0;
    g_ui32_pause_t = 0;
    g_i32_first = 0;
/* tone, sequence, direct recording */
    g_ui32_tone_len = 0;
    g_ui32_tone_cnt = 0;
/* the sequence's count, the samples' length */
    g_ui32_seq_cnt = 0;
    g_ui32_dir_tps = 0;
/* loop and call */
    g_ui32_loop_cnt = 0;
    g_ui32_loop_blk = 0;
/* the call sequence */
    g_ui32_call_n = 0;
    g_ui32_call_i = 0;
    g_ui32_call_pos = 0;
/* the calling block, commands emitted */
    g_ui32_call_blk = 0;
    g_ui32_n_emit = 0;
}
