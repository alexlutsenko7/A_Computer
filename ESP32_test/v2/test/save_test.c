/* save_test.c -- save.c + fat.c (writing) on the PC against a card image. */
/* */
/*   save_test IMAGE save  TAPFILE DIR NAME8 [noise] [empty] */
/*       Starts recording into DIR ("/" or a folder name in the root) / NAME8.TAP, */
/*       feeds the MIC pulse train the ROM SAVE routine makes for TAPFILE (pilot */
/*       8063/3223 x 2168, sync 667 + 735, 2 x 855 / 1710 per bit, 1 s in turbo */
/*       between blocks, +-15 T-states of jitter, no closing edge after the last */
/*       pulse of a block) and stops recording. */
/*       noise: random MIC clicks and a too-short pilot first (must be ignored). */
/*       empty: nothing saved: the file must be removed. */
/*   save_test IMAGE many DIR COUNT */
/*       Creates COUNT small files in DIR (directory growth beyond one cluster). */
/* */
/* The result is checked by tools/fatcheck.py. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
/* bool, and the platform the code under test needs */
#include <stdbool.h>
#include "../../../ESP32/v2/src/hal.h"
/* the code under test, and its registers on the PC */
#include "../../../ESP32/v2/src/fat.h"
#include "../../../ESP32/v2/src/save.h"
#include "host_hw.h"

/* bytes of one card sector */
#define SECTOR_SIZE 512
/* results of the card functions */
#define SD_OK 0
#define SD_ERROR (-1)
/* what fifo_free always answers: the whole FIFO */
#define FIFO_ROOM 512
/* the event queue: its first size, and how it grows */
#define QUEUE_FIRST 65536
#define QUEUE_GROW 2
/* recorder events: an edge after n T-states, a gap */
#define EV_EDGE 0x80000000u
#define EV_GAP 0xC0000000u
/* the longest time, a gap's time */
#define EV_TIME_MAX 0xFFFFFF
#define GAP_TIME 8000
/* the jitter generator (the C library's classic one): +-15 T-states */
#define RND_SEED 12345
#define RND_MUL 1103515245u
#define RND_ADD 12345u
/* the bits used; the range and its middle */
#define RND_SHIFT 16
#define JIT_RANGE 31
#define JIT_HALF 15
/* the ROM's SAVE signal, in T-states: pilot pulses of a header / a data block, */
#define FLAG_DATA_BIT 0x80
#define PILOT_HEADER 8063
#define PILOT_DATA 3223
/* the pilot pulse, the two sync pulses, the pulse of a 0 and of a 1 bit */
#define T_PILOT 2168
#define T_SYNC1 667
#define T_SYNC2 735
/* a 0 bit, a 1 bit */
#define T_BIT0 855
#define T_BIT1 1710
/* bits of a byte, and the first one sent */
#define BYTE_BITS 8
#define TOP_BIT 7
#define BIT_MASK 1
/* the pause before the first block, and between blocks (1 s in turbo) */
#define PAUSE_FIRST 100000
#define PAUSE_BLOCK 28000000
/* the noise: clicks of 50..1250 T-states, a pilot of only 50 pulses, a long pause */
#define NOISE_CLICKS 300
#define NOISE_BASE 50
#define NOISE_STEP 40
/* the short pilot, the pause */
#define NOISE_PILOT 50
#define NOISE_PAUSE 30000
/* an 8.3 name: 8 characters, then the extension */
#define NAME8_LEN 8
#define NAME8_BUF 12
#define EXT_0 8
/* its other two characters */
#define EXT_1 9
#define EXT_2 10
/* the files of "many": 100 bytes and one more each */
#define MANY_BASE 100
/* a TAP file: at most 1 MB; each block has a 2-byte length */
#define TAP_MAX 0x100000
#define TAP_LEN_BYTES 2
/* the high byte of a length */
#define TAP_LEN_HIGH 1
#define HIGH_SHIFT 8
/* rec_status's text */
#define STATUS_LEN 48
/* the command line */
#define ARG_IMAGE 1
#define ARG_MODE 2
/* mode many */
#define ARG_MANY_DIR 3
#define ARG_MANY_COUNT 4
/* mode save */
#define ARG_TAP 3
#define ARG_DIR 4
#define ARG_NAME 5
/* the options, the fewest arguments */
#define ARG_OPTIONS 6
#define ARGS_MIN 4
/* the program's results */
#define EXIT_OK 0
#define EXIT_ERRORS 1
#define EXIT_USAGE 2
/* strcmp's "the same" */
#define SAME 0
/* one */
#define ONE 1

/* what find_dir_cb looks for, and what it found */
typedef struct
{
/* the name, its first cluster, found */
    const char *pc_want;
    uint32_t ui32_clus;
    bool b_hit;
} FIND;

/* the TAP file to save */
static uint8_t g_aui8_tap[TAP_MAX];
/* the file "many" writes (too big for the stack) */
static FWFILE g_s_many_file;
/* the card image */
static FILE *g_ps_img;
/* recorder model: a queue of events, */
static uint32_t *g_pui32_queue;
/* its length, its room, the next one to read */
static size_t g_sz_count;
static size_t g_sz_room;
static size_t g_sz_next;
/* since-value once the queue is empty */
static uint32_t g_ui32_since_after;
/* the registers written, and the timer */
static uint32_t g_ui32_ctl;
static uint32_t g_ui32_tape;
static uint32_t g_ui32_now;
/* the jitter generator's state */
static uint32_t g_ui32_rnd = RND_SEED;

/* read one sector of the image */
int32_t sd_read(uint32_t ui32_lba, uint8_t *pui8_buf)
{
    int32_t i32_result;

    i32_result = SD_ERROR;
/* seek, then read: both must work */
    if (fseek(g_ps_img, (long)ui32_lba * SECTOR_SIZE, SEEK_SET) == 0)
    {
        if (fread(pui8_buf, ONE, SECTOR_SIZE, g_ps_img) == SECTOR_SIZE)
        {
            i32_result = SD_OK;
        }
    }
/* SD_OK or SD_ERROR */
    return i32_result;
}

/* write one sector of the image (WRLOG in the environment: every write is listed) */
int32_t sd_write(uint32_t ui32_lba, const uint8_t *pui8_buf)
{
/* local variables */
    int32_t i32_result;

/* start values */
    i32_result = SD_ERROR;
    if (getenv("WRLOG") != NULL)
    {
        fprintf(stderr, "write %u\n", (unsigned)ui32_lba);
    }
/* seek, then write: both must work */
    if (fseek(g_ps_img, (long)ui32_lba * SECTOR_SIZE, SEEK_SET) == 0)
    {
        if (fwrite(pui8_buf, ONE, SECTOR_SIZE, g_ps_img) == SECTOR_SIZE)
        {
            i32_result = SD_OK;
        }
    }
/* SD_OK or SD_ERROR */
    return i32_result;
}

/* the pulse FIFO is not used: always room, commands dropped */
uint32_t fifo_free(void)
{
    return FIFO_ROOM;
}

/* a command is dropped */
void fifo_push(uint32_t ui32_cmd)
{
    (void)ui32_cmd;
}

/* one more event at the end of the queue */
static void ev(uint32_t ui32_event)
{
    if (g_sz_count == g_sz_room)
    {
/* full: twice the room */
        if (g_sz_room != 0)
        {
            g_sz_room = g_sz_room * QUEUE_GROW;
        }
        else
        {
            g_sz_room = QUEUE_FIRST;
        }
/* the queue moves to the larger memory */
        g_pui32_queue = (uint32_t *)realloc(g_pui32_queue, g_sz_room * sizeof *g_pui32_queue);
    }
    g_pui32_queue[g_sz_count] = ui32_event;
    g_sz_count++;
}

/* an edge ui32_time T-states after the last one */
static void edge_after(uint32_t ui32_time)
{
    uint32_t ui32_kept;

    ui32_kept = ui32_time;
/* the counter stops at its maximum */
    if (ui32_kept > EV_TIME_MAX)
    {
        ui32_kept = EV_TIME_MAX;
    }
    ev(EV_EDGE | ui32_kept);
}

/* no edge for a long time */
static void gap(void)
{
    ev(EV_GAP | GAP_TIME);
}

/* next recorder event (0: none) */
uint32_t rec_event(void)
{
/* local variables */
    uint32_t ui32_event;

/* start values */
    ui32_event = 0;
    if (g_sz_next < g_sz_count)
    {
        ui32_event = g_pui32_queue[g_sz_next];
/* taken */
        g_sz_next++;
    }
    return ui32_event;
}

/* T-states since the last edge: only counted once the queue is empty */
uint32_t rec_since(void)
{
/* local variables */
    uint32_t ui32_since;

/* start values */
    ui32_since = 0;
    if (g_sz_next >= g_sz_count)
    {
/* the value set for an empty queue */
        ui32_since = g_ui32_since_after;
    }
    return ui32_since;
}

/* the registers: kept for the checks at the end */
void rec_ctl(uint32_t ui32_value)
{
    g_ui32_ctl = ui32_value;
}

/* the tape register */
void tape_ctl(uint32_t ui32_value)
{
    g_ui32_tape = ui32_value;
}

/* the timer */
uint32_t timer_now(void)
{
    return g_ui32_now;
}

/* the next jitter value: -15 .. +15 */
static int32_t jit(void)
{
/* local variables */
    int32_t i32_value;

/* start values */
    g_ui32_rnd = (g_ui32_rnd * RND_MUL) + RND_ADD;
    i32_value = (int32_t)((g_ui32_rnd >> RND_SHIFT) % JIT_RANGE) - JIT_HALF;
    return i32_value;
}

/* one ROM-format block: pilot, sync, data; the first edge comes after ui32_pause */
static void rom_block(const uint8_t *pui8_data, uint32_t ui32_count, uint32_t ui32_pause)
{
/* local variables */
    uint32_t ui32_index;
    uint32_t ui32_bit;
/* pilot pulses, half a bit */
    uint32_t ui32_pilot;
    uint32_t ui32_half;

/* start values */
    ui32_index = 0;
    ui32_bit = 0;
/* a header's pilot unless the flag says data */
    ui32_pilot = PILOT_HEADER;
    ui32_half = 0;
/* a data block (flag byte 0x80 and up) has the short pilot */
    if ((pui8_data[0] & FLAG_DATA_BIT) != 0)
    {
        ui32_pilot = PILOT_DATA;
    }
/* the edge that starts the pilot */
    edge_after(ui32_pause);
    for (ui32_index = 0; ui32_index < ui32_pilot; ui32_index++)
    {
        edge_after((uint32_t)(T_PILOT + jit()));
    }
/* the two sync pulses */
    edge_after((uint32_t)(T_SYNC1 + jit()));
    edge_after((uint32_t)(T_SYNC2 + jit()));
/* the bytes, MSB first, two pulses per bit */
    for (ui32_index = 0; ui32_index < ui32_count; ui32_index++)
    {
        for (ui32_bit = 0; ui32_bit < BYTE_BITS; ui32_bit++)
        {
            ui32_half = T_BIT0;
/* a 1 bit is twice as long */
            if (((pui8_data[ui32_index] >> (TOP_BIT - ui32_bit)) & BIT_MASK) != 0)
            {
                ui32_half = T_BIT1;
            }
            edge_after((uint32_t)((int32_t)ui32_half + jit()));
/* no closing edge at the very end */
            if (!((ui32_index == (ui32_count - ONE)) && (ui32_bit == TOP_BIT)))
            {
                edge_after((uint32_t)((int32_t)ui32_half + jit()));
            }
        }
    }
    gap();
}

/* fat_list's callback: stop at the folder wanted */
static int32_t find_dir_cb(const DIRENT *ps_entry, void *p_ctx)
{
/* local variables */
    FIND *ps_find;
    int32_t i32_stop;

/* start values */
    ps_find = (FIND *)p_ctx;
    i32_stop = 0;
    if (((ps_entry->ui8_attr & ATTR_DIR) != 0) && (strcmp(ps_entry->ac_name, ps_find->pc_want) == SAME))
    {
/* found: its first cluster */
        ps_find->ui32_clus = ps_entry->ui32_clus;
        ps_find->b_hit = true;
        i32_stop = ONE;
    }
/* non-zero ends the scan */
    return i32_stop;
}

/* the first cluster of a folder in the root ("/": the root itself); the test ends without it */
static uint32_t dir_of(const char *pc_name)
{
/* local variables */
    FIND s_find;

/* start values */
    s_find.pc_want = pc_name;
    s_find.ui32_clus = 0;
    s_find.b_hit = false;
/* the root needs no search */
    if (strcmp(pc_name, "/") != SAME)
    {
        fat_list(0, find_dir_cb, &s_find);
        if (!s_find.b_hit)
        {
/* no such folder */
            printf("ERROR: folder %s not found\n", pc_name);
            exit(EXIT_ERRORS);
        }
    }
    return s_find.ui32_clus;
}

/* "NAME" -> "NAME    TAP" as a directory entry stores it */
static void name11(char ac_out[FAT_NAME11_LEN], const char *pc_name8)
{
    int32_t i32_index;

    for (i32_index = 0; i32_index < NAME8_LEN; i32_index++)
    {
/* the name, then spaces */
        if (i32_index < (int32_t)strlen(pc_name8))
        {
            ac_out[i32_index] = pc_name8[i32_index];
        }
        else
        {
            ac_out[i32_index] = ' ';
        }
    }
/* the extension */
    ac_out[EXT_0] = 'T';
    ac_out[EXT_1] = 'A';
    ac_out[EXT_2] = 'P';
}

/* "many": COUNT small files in one folder */
static int32_t run_many(char **argv)
{
/* local variables */
    char ac_name11[FAT_NAME11_LEN];
    char ac_name8[NAME8_BUF];
    uint32_t ui32_dir;
/* how many files, counters */
    int32_t i32_count;
    int32_t i32_index;
    int32_t i32_byte;
/* the exit code */
    int32_t i32_exit;

/* start values */
    ui32_dir = dir_of(argv[ARG_MANY_DIR]);
    i32_count = atoi(argv[ARG_MANY_COUNT]);
    i32_index = 0;
/* no error; file by file */
    i32_byte = 0;
    i32_exit = EXIT_OK;
    while ((i32_exit == EXIT_OK) && (i32_index < i32_count))
    {
/* F000, F001, ...: must be new */
        snprintf(ac_name8, sizeof ac_name8, "F%03d", (int)i32_index);
        name11(ac_name11, ac_name8);
        if (fat_exists(ui32_dir, ac_name11) != 0)
        {
/* it is there already */
            printf("ERROR: %s exists\n", ac_name8);
            i32_exit = EXIT_ERRORS;
        }
/* created */
        else if (fw_create(&g_s_many_file, ui32_dir, ac_name11) != FAT_OK)
        {
            printf("ERROR: create %d\n", (int)i32_index);
            i32_exit = EXIT_ERRORS;
        }
        else
        {
/* its bytes, each file one longer */
            for (i32_byte = 0; i32_byte < (MANY_BASE + i32_index); i32_byte++)
            {
                fw_putc(&g_s_many_file, (uint8_t)(i32_index + i32_byte));
            }
            if (fw_close(&g_s_many_file) != FAT_OK)
            {
/* the close failed */
                printf("ERROR: close %d\n", (int)i32_index);
                i32_exit = EXIT_ERRORS;
            }
        }
        i32_index++;
    }
/* all created */
    if (i32_exit == EXIT_OK)
    {
        printf("created %d files\n", (int)i32_count);
    }
    return i32_exit;
}

/* the noise before a recording: clicks and a 50-pulse pilot make no block */
static void feed_noise(void)
{
/* local variables */
    int32_t i32_index;

    for (i32_index = 0; i32_index < NOISE_CLICKS; i32_index++)
    {
        edge_after(NOISE_BASE + ((uint32_t)(jit() + JIT_HALF) * NOISE_STEP));
    }
/* a pilot that is too short */
    for (i32_index = 0; i32_index < NOISE_PILOT; i32_index++)
    {
        edge_after(T_PILOT);
    }
/* a long pause, then silence */
    edge_after(NOISE_PAUSE);
    gap();
}

/* the end of a recording: the status, and the state everything must be left in */
static int32_t check_end(uint32_t ui32_dir, const char ac_name11[FAT_NAME11_LEN], bool b_empty)
{
/* local variables */
    char ac_status[STATUS_LEN];
    const char *pc_turbo;
/* the recorder's state as text, the exit code */
    const char *pc_recorder;
    int32_t i32_exit;

/* start values */
    pc_turbo = "off";
    pc_recorder = "off";
    i32_exit = EXIT_OK;
/* the recorder's last message */
    if (rec_status(ac_status) != 0)
    {
        printf("status: %s\n", ac_status);
    }
/* turbo and the recorder: both must be off again */
    if ((g_ui32_tape & TAPE_TURBO) != 0)
    {
        pc_turbo = "ON";
    }
/* the recorder */
    if (g_ui32_ctl != 0)
    {
        pc_recorder = "ON";
    }
/* said, and checked */
    printf("events %zu, turbo %s, recorder %s at the end\n", g_sz_count, pc_turbo, pc_recorder);
    if (((g_ui32_tape & TAPE_TURBO) != 0) || (g_ui32_ctl != 0) || (rec_active() != 0))
    {
        printf("ERROR: state after the end\n");
/* an error */
        i32_exit = EXIT_ERRORS;
    }
    else if (b_empty && (fat_exists(ui32_dir, ac_name11) != 0))
    {
/* nothing was saved: no file may stay */
        printf("ERROR: empty recording left a file\n");
        i32_exit = EXIT_ERRORS;
    }
    else
    {
/* as expected */
    }
    return i32_exit;
}

/* "save": recording mode started, the TAP file's blocks saved by the "Spectrum", stopped */
static int32_t run_save(int argc, char **argv)
{
/* local variables */
    char ac_name11[FAT_NAME11_LEN];
    FILE *ps_tap;
    size_t sz_count;
/* the place in the file, the folder, a block's length */
    size_t sz_pos;
    uint32_t ui32_dir;
    uint32_t ui32_len;
/* the pause before a block, a counter, the exit code */
    uint32_t ui32_pause;
    int32_t i32_index;
    int32_t i32_exit;
/* the options */
    bool b_noise;
    bool b_empty;

/* start values */
    ps_tap = fopen(argv[ARG_TAP], "rb");
    sz_count = 0;
    sz_pos = 0;
/* nothing read yet */
    ui32_dir = 0;
    ui32_len = 0;
    ui32_pause = 0;
/* no error */
    i32_index = 0;
    i32_exit = EXIT_OK;
/* no options yet */
    b_noise = false;
    b_empty = false;
/* the TAP file, the folder, the options */
    if (ps_tap != NULL)
    {
        sz_count = fread(g_aui8_tap, ONE, sizeof g_aui8_tap, ps_tap);
    }
/* the folder */
    ui32_dir = dir_of(argv[ARG_DIR]);
    for (i32_index = ARG_OPTIONS; i32_index < argc; i32_index++)
    {
        if (strcmp(argv[i32_index], "noise") == SAME)
        {
/* noise first; nothing saved */
            b_noise = true;
        }
        if (strcmp(argv[i32_index], "empty") == SAME)
        {
            b_empty = true;
        }
    }
/* start recording */
    if (sz_count == 0)
    {
        printf("ERROR: no TAP\n");
        i32_exit = EXIT_ERRORS;
    }
    else
    {
/* the file's name; the recorder is armed by the start */
        name11(ac_name11, argv[ARG_NAME]);
        if (rec_start(ui32_dir, ac_name11) != FAT_OK)
        {
/* it failed */
            printf("ERROR: rec_start\n");
            i32_exit = EXIT_ERRORS;
        }
/* it must be armed now */
        else if ((g_ui32_ctl & REC_ARMED) == 0)
        {
            printf("ERROR: recorder not armed\n");
            i32_exit = EXIT_ERRORS;
        }
        else
        {
/* recording */
        }
    }
    if (i32_exit == EXIT_OK)
    {
        if (b_noise)
        {
            feed_noise();
        }
/* every block of the file; 1 s (real time, = 28 M T in turbo) between blocks */
        while (!b_empty && ((sz_pos + TAP_LEN_BYTES) <= sz_count))
        {
            ui32_len = (uint32_t)g_aui8_tap[sz_pos] | ((uint32_t)g_aui8_tap[sz_pos + TAP_LEN_HIGH] << HIGH_SHIFT);
/* a short pause before the first block */
            ui32_pause = PAUSE_FIRST;
            if (sz_pos != 0)
            {
                ui32_pause = PAUSE_BLOCK;
            }
/* the block's pulses */
            rom_block(g_aui8_tap + sz_pos + TAP_LEN_BYTES, ui32_len, ui32_pause);
            sz_pos += TAP_LEN_BYTES + ui32_len;
        }
/* the recorder takes every event, then the recording ends */
        while (g_sz_next < g_sz_count)
        {
            rec_service();
        }
/* the end */
        rec_end();
        g_ui32_now = 0;
/* the checks */
        i32_exit = check_end(ui32_dir, ac_name11, b_empty);
    }
    return i32_exit;
}

int main(int argc, char **argv)
{
/* the exit code */
    int32_t i32_exit;

    i32_exit = EXIT_OK;
    if (argc < ARGS_MIN)
    {
/* too few arguments */
        fprintf(stderr, "usage: see save_test.c\n");
        i32_exit = EXIT_USAGE;
    }
    else
    {
/* the card image, mounted */
        g_ps_img = fopen(argv[ARG_IMAGE], "r+b");
        if ((g_ps_img == NULL) || (fat_mount() != FAT_OK))
        {
/* no image, or no file system */
            printf("ERROR: mount\n");
            i32_exit = EXIT_ERRORS;
        }
/* many small files */
        else if (strcmp(argv[ARG_MODE], "many") == SAME)
        {
            i32_exit = run_many(argv);
        }
        else
        {
/* every other mode is "save" */
            i32_exit = run_save(argc, argv);
        }
    }
    return i32_exit;
}
