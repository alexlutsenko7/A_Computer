/* save.c -- recording the Spectrum's SAVE output (MIC, port FE bit 3) into a TAP file
 *
 * Recording mode is started from the browser ([Save to this folder], name) and
 * ended with F12: everything the Spectrum saves in between goes into one file.
 *
 * The recorder (rtl/tape_loader.v) reports every MIC edge with the T-states since
 * the previous one, and a "gap" event when no edge came for 8000 T-states. While
 * recording it is armed: the Spectrum is held until each event has been read, so
 * nothing is lost while the card is written.
 *
 * Decoding (standard ROM timing, T-states): pilot 2168, sync 667 + 735, bits as two
 * equal pulses of 855 (0) or 1710 (1). A pulse's length is known only at the next
 * edge, and the ROM does not always make an edge after the very last pulse, so
 * each bit is decided by its first pulse; a bit missing its second pulse when the
 * block ends is completed from the first. A block needs 64 pilot pulses first,
 * so MIC clicks for sound are ignored. Turbo is on only while a block is saved.
 * TAP block lengths are written as 0 first and patched when the block ends.
 */
#ifdef HOST_TEST
#include "../test/host_hw.h"
#else
#include "hw.h"
#endif
#include "hal.h"
#include "fat.h"
#include "save.h"
#include "util.h"

#define PILOT_MIN   1800u
#define PILOT_MAX   2600u
#define SYNC_MIN    400u
#define SYNC_MAX    1100u
#define HALF_MIN    500u
#define HALF_MAX    2400u
#define ONE_HALF    1283u           /* between 855 (0) and 1710 (1) */
#define NEXT_PILOT  64              /* pilot pulses before a block counts */

#ifndef HOST_TEST
static uint32_t rec_event(void)       { return REC; }
static void     rec_ctl(uint32_t v)   { RECCTL = v; }
static void     tape_ctl(uint32_t v)  { TAPE = v; }
static uint32_t timer_now(void)       { return TIMER; }
#endif

enum { D_SEEK, D_PILOT, D_SYNC, D_DATA };

int slow_mode;                          /* F6: no turbo for loading and saving */

static int      on, dst, pc, half, nbits, in_block, blocks;
static uint32_t first_half, blk_len, len_pos;
static uint8_t  cur;
#define wf fw_file                       /* shared with snap.c (fat.h) */
static char     fname[13];
static uint32_t msg_t;                  /* message shown until then (TIMER) */
static char     msg[40];

static void message(const char *a, const char *b)
{
    char *p = u_strcpy(msg, a);
    u_strcpy(p, b);
    msg_t = timer_now() + 4000 * CLK_PER_MS;
}

static void stop_hw(void)
{
    rec_ctl(0);
    tape_ctl(0);                        /* turbo off (the player is not running while recording) */
}

static void fail(void)
{
    message("Save failed: card error", "");
    on = 0;
    stop_hw();
}

static void put(uint8_t b)
{
    if (on && fw_putc(&wf, b) != FAT_OK) fail();
}

static void begin_block(void)
{
    len_pos  = wf.size;
    blk_len  = 0;
    in_block = 1;
    half = nbits = 0;
    put(0);                                             /* TAP length, patched at the end */
    put(0);
}

static void bit(uint32_t first)
{
    cur = (uint8_t)((cur << 1) | (first > ONE_HALF));
    if (++nbits == 8) {
        nbits = 0;
        blk_len++;
        put(cur);
    }
}

static void end_block(void)
{
    if (!in_block) return;
    if (half) { bit(first_half); half = 0; }           /* last pulse without a closing edge */
    in_block = 0;
    blocks++;
    if (on && (fw_patch(&wf, len_pos, (uint8_t)blk_len) != FAT_OK ||
               fw_patch(&wf, len_pos + 1, (uint8_t)(blk_len >> 8)) != FAT_OK))
        fail();
}

static void seek(int pilot)
{
    dst = D_SEEK;
    pc = pilot ? 1 : 0;
    tape_ctl(0);                                        /* normal speed between blocks */
}

static void edge(uint32_t d)
{
    int pilot = d >= PILOT_MIN && d <= PILOT_MAX;
    int sync  = d >= SYNC_MIN && d <= SYNC_MAX;

    switch (dst) {
    case D_SEEK:
        pc = pilot ? pc + 1 : 0;
        if (pc >= NEXT_PILOT) {
            dst = D_PILOT;
            tape_ctl(slow_mode ? 0 : TAPE_TURBO);       /* this block at 28 MHz (unless F6) */
        }
        break;
    case D_PILOT:
        if (sync) dst = D_SYNC;
        else if (!pilot) seek(0);
        break;
    case D_SYNC:
        if (sync) { dst = D_DATA; begin_block(); }
        else      seek(pilot);
        break;
    default:                                            /* D_DATA */
        if (d < HALF_MIN || d > HALF_MAX) {             /* not a bit: the block ended */
            end_block();
            seek(pilot);
            break;
        }
        if (!half) { first_half = d; half = 1; break; }
        half = 0;
        bit(first_half);
        break;
    }
}

int rec_start(uint32_t dir, const char name11[11])
{
    uint32_t i;
    char *p = fname;
    int r = fw_create(&wf, dir, name11);
    if (r != FAT_OK) return r;
    for (i = 0; i < 8 && name11[i] != ' '; i++) *p++ = name11[i];
    *p++ = '.';
    for (i = 8; i < 11 && name11[i] != ' '; i++) *p++ = name11[i];
    *p = 0;
    on = 1;
    blocks = in_block = 0;
    seek(0);
    msg_t = 0;
    (void)rec_event();                                  /* drop an old event */
    rec_ctl(REC_ARMED);
    return FAT_OK;
}

void rec_service(void)
{
    uint32_t e;
    int n;

    for (n = 0; on && n < 64; n++) {
        e = rec_event();
        if (!(e & REC_PEND)) break;
        if (e & REC_GAP) {
            if (dst == D_DATA) end_block();
            if (dst != D_SEEK || pc) seek(0);
        } else
            edge(e & 0xFFFFFFu);
    }
}

void rec_end(void)
{
    char *p;
    if (!on) return;
    if (in_block) end_block();
    if (!on) return;                                    /* end_block failed */
    on = 0;
    stop_hw();
    if (blocks == 0) {                                  /* nothing saved: no file */
        message(fw_discard(&wf) == FAT_OK ? "Nothing saved" : "Save failed: card error", "");
        return;
    }
    if (fw_close(&wf) != FAT_OK) { message("Save failed: card error", ""); return; }
    message("Saved ", fname);
    p = msg + u_strlen(msg);
    p = u_strcpy(p, " (");
    p = u_utoa(p, (uint32_t)blocks);
    u_strcpy(p, blocks == 1 ? " block)" : " blocks)");
}

int rec_active(void) { return on; }

void rec_speed(void)
{
    if (on && dst != D_SEEK) tape_ctl(slow_mode ? 0 : TAPE_TURBO);
}

int rec_status(char *s)
{
    char *p;
    if (on) {
        p = u_strcpy(s, "Rec ");
        p = u_strcpy(p, fname);
        p = u_strcpy(p, ": ");
        p = u_utoa(p, (uint32_t)blocks + (in_block ? 1 : 0));
        u_strcpy(p, " F12=stop");
        return 1;
    }
    if (msg_t && (int32_t)(timer_now() - msg_t) < 0) { u_strcpy(s, msg); return 1; }
    msg_t = 0;
    return 0;
}
