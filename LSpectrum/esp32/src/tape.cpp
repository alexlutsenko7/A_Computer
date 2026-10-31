/* tape.c -- TAP / TZX file -> pulse player commands
 *
 * Every block becomes PULSE / LEVEL / DATA commands (durations in T-states,
 * see hal.h). Each block starts with CMD_MARK(block index), so the CPU can
 * tell which block the hardware is playing.
 *
 * Signal conventions (same as tools/tzxref.py, which the host test compares against):
 *   - the line starts low (100 ms low lead-in);
 *   - PULSE n holds the current level for n T-states, then toggles;
 *   - a pause after a block (or TZX 0x20): if the level is high, 1 ms high first,
 *     then low for the rest of the pause;
 *   - TAP: every block is a standard ROM block with a 1000 ms pause.
 *
 * TZX blocks played: 10 11 12 13 14 15 20 2B; control: 21 22 23 24 25 26 27;
 * skipped: 18 19 28 2A (this is a 128K) 30 31 32 33 34 35 40 5A and unknown blocks
 * (by their length field).
 */
#include "tape.h"
#include "hal.h"

#define T_MS   3500u

enum { G_BLOCK, G_PILOT, G_SYNC, G_DATA, G_PAUSE, G_TONE, G_SEQ, G_DIRECT, G_STOP, G_END, G_ERR };

static FFILE   *f;
static uint8_t  tzx, lvl, g, last_bits, has_sync;
static uint32_t blk_next, blk_cur;
static uint32_t pilot_len, pilot_cnt, sync1, sync2, zero, one, data_left, pause_t;
static int      first;                          /* first data byte, already read (-1: none) */
static uint32_t tone_len, tone_cnt, seq_cnt, dir_tps;
static uint32_t loop_cnt, loop_blk;
static uint32_t call_n, call_i, call_pos, call_blk;

static uint32_t n_emit;                         /* commands emitted so far */

static void emit(uint32_t c)
{
    n_emit++;
    fifo_push(c);
    if ((c >> 30) == 0)      lvl ^= 1;
    else if ((c >> 30) == 1) lvl = (c >> 24) & 1;
    else if ((c >> 30) == 2 && (c & 0x800))                /* SAMPLES: level of the last sample */
        lvl = (c >> (7 - ((c >> 8) & 7))) & 1;
}

/* n equal pulses (pilot, pure tone) */
static void emit_pulses(uint32_t len, uint32_t n)
{
    uint32_t c = CMD_PULSE(len);
    n_emit += n;
    lvl ^= n & 1;
    while (n--) fifo_push(c);
}

static uint32_t rd8(void)  { int c = ff_getc(f); return c < 0 ? 0 : (uint32_t)c; }
static uint32_t rd16(void) { uint32_t v = rd8(); return v | (rd8() << 8); }
static uint32_t rd24(void) { uint32_t v = rd16(); return v | (rd8() << 16); }
static uint32_t rd32(void) { uint32_t v = rd16(); return v | (rd16() << 16); }
static void     skip(uint32_t n) { ff_seek(f, ff_tell(f) + n); }

/* skip the body of a TZX block (the ID byte has been read) */
static void body_skip(uint32_t id)
{
    switch (id) {
    case 0x10: skip(2); skip(rd16());        break;
    case 0x11: skip(15); skip(rd24());       break;
    case 0x12: skip(4);                      break;
    case 0x13: skip(2 * rd8());              break;
    case 0x14: skip(7); skip(rd24());        break;
    case 0x15: skip(5); skip(rd24());        break;
    case 0x20: case 0x23: case 0x24: skip(2); break;
    case 0x21: case 0x30: skip(rd8());       break;
    case 0x22: case 0x25: case 0x27:         break;
    case 0x26: skip(2 * rd16());             break;
    case 0x28: case 0x32: skip(rd16());      break;
    case 0x31: skip(1); skip(rd8());         break;
    case 0x33: skip(3 * rd8());              break;
    case 0x34: skip(8);                      break;
    case 0x35: skip(10); skip(rd32());       break;
    case 0x40: skip(1); skip(rd24());        break;
    case 0x5A: skip(9);                      break;
    default:   skip(rd32());                 break;  /* 18 19 2A 2B and unknown (TZX 1.10 rule) */
    }
}

/* position the file at block n */
static void goto_block(uint32_t n)
{
    uint32_t i;
    ff_seek(f, tzx ? 10 : 0);
    for (i = 0; i < n; i++) {
        if (tzx) {
            int id = ff_getc(f);
            if (id < 0) break;
            body_skip((uint32_t)id);
        } else {
            skip(rd16());
        }
    }
    blk_next = n;
}

static void std_block(uint32_t len, uint32_t pause_ms)
{
    pilot_len = 2168; sync1 = 667; sync2 = 735; zero = 855; one = 1710;
    last_bits = 8;
    has_sync  = 1;
    pause_t   = pause_ms * T_MS;
    data_left = len;
    first     = -1;
    if (len) {
        first     = (int)rd8();
        pilot_cnt = (first & 0x80) ? 3223 : 8063;
        g = G_PILOT;
    } else
        g = G_PAUSE;
}

static void next_block(void)
{
    int      id;
    uint32_t n, l;

    blk_cur = blk_next++;
    first = -1;
    if (!tzx) {
        int lo = ff_getc(f), hi = ff_getc(f);
        if (lo < 0 || hi < 0) { g = G_END; return; }
        emit(CMD_MARK(blk_cur));
        std_block((uint32_t)(lo | (hi << 8)), 1000);
        return;
    }
    id = ff_getc(f);
    if (id < 0) { g = G_END; return; }
    emit(CMD_MARK(blk_cur));
    switch (id) {
    case 0x10:
        n = rd16();
        std_block(rd16(), n);
        break;
    case 0x11:
        pilot_len = rd16(); sync1 = rd16(); sync2 = rd16();
        zero = rd16(); one = rd16(); pilot_cnt = rd16();
        last_bits = (uint8_t)rd8(); pause_t = rd16() * T_MS; data_left = rd24();
        has_sync = 1;
        g = pilot_cnt ? G_PILOT : G_SYNC;
        break;
    case 0x12:
        tone_len = rd16(); tone_cnt = rd16();
        g = G_TONE;
        break;
    case 0x13:
        seq_cnt = rd8();
        g = G_SEQ;
        break;
    case 0x14:
        zero = rd16(); one = rd16(); last_bits = (uint8_t)rd8();
        pause_t = rd16() * T_MS; data_left = rd24();
        has_sync = 0;
        g = G_SYNC;                                     /* no pilot or sync: just the bit lengths */
        break;
    case 0x15:
        dir_tps = rd16(); pause_t = rd16() * T_MS; last_bits = (uint8_t)rd8(); data_left = rd24();
        emit(CMD_LEN0(dir_tps));
        g = G_DIRECT;
        break;
    case 0x20:
        n = rd16();
        if (n) { pause_t = n * T_MS; g = G_PAUSE; }
        else   g = G_STOP;
        break;
    case 0x23:                                          /* jump (relative) */
        n = rd16();
        if (n == 0) n = 1;
        goto_block(blk_cur + (uint32_t)(int16_t)n);
        break;
    case 0x24:                                          /* loop start */
        loop_cnt = rd16();
        loop_blk = blk_next;
        break;
    case 0x25:                                          /* loop end */
        if (loop_cnt > 1) { loop_cnt--; goto_block(loop_blk); }
        break;
    case 0x26:                                          /* call sequence */
        call_n = rd16(); call_i = 0; call_pos = ff_tell(f); call_blk = blk_cur;
        if (call_n) goto_block(call_blk + (uint32_t)(int16_t)rd16());
        break;
    case 0x27:                                          /* return from sequence */
        if (call_n) {
            if (++call_i < call_n) {
                ff_seek(f, call_pos + 2 * call_i);
                goto_block(call_blk + (uint32_t)(int16_t)rd16());
            } else {
                call_n = 0;
                goto_block(call_blk + 1);
            }
        }
        break;
    case 0x2B:                                          /* set signal level */
        l = rd32();
        n = rd8();
        if (l > 1) skip(l - 1);
        emit(CMD_LEVEL(n & 1, 0));
        break;
    default:
        body_skip((uint32_t)id);
        break;
    }
}

/* one step: at most 8 commands */
static void step(void)
{
    uint32_t b, bits, t;

    switch (g) {
    case G_BLOCK:
        next_block();
        break;
    case G_PILOT:                                       /* up to 8 pulses per step */
        t = pilot_cnt < 8 ? pilot_cnt : 8;
        emit_pulses(pilot_len, t);
        pilot_cnt -= t;
        if (!pilot_cnt) g = G_SYNC;
        break;
    case G_SYNC:
        if (has_sync) {
            emit(CMD_PULSE(sync1));
            emit(CMD_PULSE(sync2));
        }
        emit(CMD_LEN0(zero));
        emit(CMD_LEN1(one));
        g = G_DATA;
        break;
    case G_DATA:
        if (!data_left) { g = G_PAUSE; break; }
        if (first >= 0) { b = (uint32_t)first; first = -1; }
        else            b = rd8();
        bits = (data_left == 1 && last_bits >= 1 && last_bits <= 8) ? last_bits : 8;
        emit(CMD_DATA(b, bits));
        data_left--;
        break;
    case G_PAUSE:
        if (pause_t == 0) { g = G_BLOCK; break; }
        if (lvl) {                                      /* 1 ms at the level after the last edge */
            t = pause_t < T_MS ? pause_t : T_MS;
            emit(CMD_LEVEL(1, t));
            pause_t -= t;
            if (!pause_t) break;
        }
        t = pause_t < CMD_MAX_T ? pause_t : CMD_MAX_T;  /* then low */
        emit(CMD_LEVEL(0, t));
        pause_t -= t;
        break;
    case G_TONE:
        if (!tone_cnt) { g = G_BLOCK; break; }
        t = tone_cnt < 8 ? tone_cnt : 8;
        emit_pulses(tone_len, t);
        tone_cnt -= t;
        break;
    case G_SEQ:
        if (!seq_cnt) { g = G_BLOCK; break; }
        emit(CMD_PULSE(rd16()));
        seq_cnt--;
        break;
    case G_DIRECT:                                      /* one byte = up to 8 samples */
        if (!data_left) { g = G_PAUSE; break; }
        b = rd8();
        bits = (data_left == 1 && last_bits >= 1 && last_bits <= 8) ? last_bits : 8;
        emit(CMD_SAMP(b, bits));
        data_left--;
        break;
    default:
        break;
    }
}

void tape_start(FFILE *file, int is_tzx, uint32_t block)
{
    f = file;
    tzx = (uint8_t)is_tzx;
    lvl = 0;
    loop_cnt = 0;
    call_n = 0;
    g = G_BLOCK;
    if (tzx) {                                          /* "ZXTape!" 0x1A major minor */
        static const char sig[8] = { 'Z', 'X', 'T', 'a', 'p', 'e', '!', 0x1A };
        int i;
        ff_seek(f, 0);
        for (i = 0; i < 8; i++)
            if (ff_getc(f) != (uint8_t)sig[i]) { g = G_ERR; return; }
    }
    goto_block(block);
    blk_cur = block;
    emit(CMD_LEVEL(0, 100 * T_MS));                     /* lead-in: 100 ms low */
}

int tape_pump(void)
{
    uint32_t room = fifo_free(), used;
    while (g <= G_DIRECT && room >= 8) {               /* a step emits at most 8 commands */
        used = n_emit;
        step();
        room -= n_emit - used;
        if (n_emit == used && g <= G_DIRECT)            /* steps that emit nothing: re-check */
            room = fifo_free();
    }
    if (g == G_STOP) return TS_STOP;
    if (g == G_END)  return TS_END;
    if (g == G_ERR)  return TS_ERR;
    return TS_RUN;
}

void tape_continue(void)
{
    if (g == G_STOP) g = G_BLOCK;
}

uint32_t tape_block(void) { return blk_cur; }
