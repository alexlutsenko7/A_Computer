/* host_test.c -- runs fat.c + tape.c on the PC against a card image. */
/* */
/*   host_test IMAGE OUTDIR [START_BLOCK] */
/* */
/* Lists the whole tree (stdout: "D path" / "F path size"), and plays every */
/* .tap/.tzx file (continuing through stop blocks) into OUTDIR/<path, / -> _>.txt */
/* as merged "level length" segments, decoded from the commands exactly as the */
/* pulse player in rtl/tape_loader.v executes them. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
/* bool, and the platform the code under test needs */
#include <stdbool.h>
#include "../../../ESP32/v1/src/hal.h"
/* the code under test */
#include "../../../ESP32/v1/src/fat.h"
#include "../../../ESP32/v1/src/tape.h"

/* bytes of one card sector */
#define SECTOR_SIZE 512
/* results of the card functions */
#define SD_OK 0
#define SD_ERROR (-1)
/* what fifo_free always answers: the whole FIFO */
#define FIFO_ROOM 512
/* the pulse player's command word: kind in bits 31:30, sub-kind in 29:28 */
#define KIND_SHIFT 30
#define KIND_PULSE 0
#define KIND_LEVEL 1
/* data; where the sub-kind is */
#define KIND_DATA 2
#define SUB_SHIFT 28
#define SUB_MASK 3
/* the two pulse lengths */
#define SUB_LEN0 0
#define SUB_LEN1 1
/* its fields */
#define TIME_MASK 0xFFFFFF
#define LEVEL_SHIFT 24
#define LEVEL_MASK 1
/* samples instead of bits; the bit count */
#define SAMPLES_BIT 0x800
#define COUNT_SHIFT 8
#define COUNT_MASK 7
/* the first bit sent; a 16-bit value */
#define TOP_BIT 7
#define WORD_MASK 0xFFFF
/* entries kept of one directory */
#define LIST_MAX 256
/* buffers for an output file name and a path */
#define OUT_NAME_LEN 800
#define PATH_LEN 600
/* the path without its leading slash */
#define PATH_SKIP 1
/* a file that never ends */
#define GUARD_MAX 10000000
/* the command line */
#define ARG_IMAGE 1
#define ARG_OUTDIR 2
/* the optional start block */
#define ARG_BLOCK 3
#define ARGS_MIN 3
/* the program's results */
#define EXIT_OK 0
#define EXIT_ERRORS 1
#define EXIT_USAGE 2
/* FAT types, for the report */
#define FAT_TYPE_16 16
#define FAT_TYPE_32 32
/* strcmp's "the same" */
#define SAME 0
/* one */
#define ONE 1

/* one directory's entries */
typedef struct
{
/* the entries, and how many */
    DIRENT as_entry[LIST_MAX];
    int32_t i32_count;
} LIST;

/* the file being played (too big for the stack) */
static FFILE g_s_file;
/* the card image */
static FILE *g_ps_img;
/* sectors read */
static int64_t g_i64_reads;
/* timeline, as the hardware player produces it: the output file, */
static FILE *g_ps_out;
/* the level now, and whether a segment is open */
static int32_t g_i32_lvl;
static bool g_b_have;
/* the pulse lengths of a 0 and a 1 bit */
static uint32_t g_ui32_len0;
static uint32_t g_ui32_len1;
/* the open segment: its level and its length */
static uint32_t g_ui32_seg_lvl;
static uint64_t g_ui64_seg_len;
/* errors found */
static int32_t g_i32_errors;
/* the block every file starts at */
static uint32_t g_ui32_start_block;

/* read one sector of the image */
int32_t sd_read(uint32_t ui32_lba, uint8_t *pui8_buf)
{
/* local variables */
    int32_t i32_result;

    i32_result = SD_ERROR;
    g_i64_reads++;
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

/* read-only test: every write fails */
int32_t sd_write(uint32_t ui32_lba, const uint8_t *pui8_buf)
{
    (void)ui32_lba;
    (void)pui8_buf;
/* always an error */
    return SD_ERROR;
}

/* the level i32_level for ui32_count T-states: joined to the open segment, or a new one */
static void hold(int32_t i32_level, uint32_t ui32_count)
{
    if (ui32_count == 0)
    {
/* nothing to add */
    }
    else if (g_b_have && ((int32_t)g_ui32_seg_lvl == i32_level))
    {
/* the same level goes on */
        g_ui64_seg_len += ui32_count;
    }
    else
    {
/* the level changed: the open segment is written */
        if (g_b_have)
        {
            fprintf(g_ps_out, "%u %llu\n", (unsigned)g_ui32_seg_lvl, (unsigned long long)g_ui64_seg_len);
        }
/* a new segment */
        g_b_have = true;
        g_ui32_seg_lvl = (uint32_t)i32_level;
        g_ui64_seg_len = ui32_count;
    }
}

/* the FIFO never fills */
uint32_t fifo_free(void)
{
    return FIFO_ROOM;
}

/* one command, executed as the pulse player does */
void fifo_push(uint32_t ui32_cmd)
{
/* local variables */
    uint32_t ui32_time;
    uint32_t ui32_kind;
    uint32_t ui32_sub;
/* a pulse length, the bit count less one, a bit counter */
    uint32_t ui32_len;
    int32_t i32_bits;
    int32_t i32_bit;

/* start values */
    ui32_time = ui32_cmd & TIME_MASK;
    ui32_kind = ui32_cmd >> KIND_SHIFT;
    ui32_sub = (ui32_cmd >> SUB_SHIFT) & SUB_MASK;
/* no length yet */
    ui32_len = 0;
/* bits of a data command, less one */
    i32_bits = (int32_t)((ui32_cmd >> COUNT_SHIFT) & COUNT_MASK);
    i32_bit = 0;
    if (ui32_kind == KIND_PULSE)
    {
/* hold, then toggle */
        hold(g_i32_lvl, ui32_time);
        g_i32_lvl ^= LEVEL_MASK;
    }
    else if (ui32_kind == KIND_LEVEL)
    {
/* set the level, then hold */
        g_i32_lvl = (int32_t)((ui32_cmd >> LEVEL_SHIFT) & LEVEL_MASK);
        hold(g_i32_lvl, ui32_time);
    }
    else if ((ui32_kind == KIND_DATA) && ((ui32_cmd & SAMPLES_BIT) != 0))
    {
/* SAMPLES: each bit is a level, held the length of a 0 bit */
        for (i32_bit = 0; i32_bit <= i32_bits; i32_bit++)
        {
            g_i32_lvl = (int32_t)((ui32_cmd >> (TOP_BIT - i32_bit)) & LEVEL_MASK);
            hold(g_i32_lvl, g_ui32_len0);
        }
    }
/* data bits */
    else if (ui32_kind == KIND_DATA)
    {
/* data bits, MSB first: two pulses each */
        for (i32_bit = 0; i32_bit <= i32_bits; i32_bit++)
        {
            ui32_len = g_ui32_len0;
/* a 1 bit has the other length */
            if (((ui32_cmd >> (TOP_BIT - i32_bit)) & LEVEL_MASK) != 0)
            {
                ui32_len = g_ui32_len1;
            }
/* the first pulse */
            hold(g_i32_lvl, ui32_len);
            g_i32_lvl ^= LEVEL_MASK;
/* the second pulse */
            hold(g_i32_lvl, ui32_len);
            g_i32_lvl ^= LEVEL_MASK;
        }
    }
    else if (ui32_sub == SUB_LEN0)
    {
/* the pulse length of a 0 bit */
        g_ui32_len0 = ui32_cmd & WORD_MASK;
    }
    else if (ui32_sub == SUB_LEN1)
    {
/* the pulse length of a 1 bit */
        g_ui32_len1 = ui32_cmd & WORD_MASK;
    }
    else
    {
/* a marker: nothing on the timeline */
    }
}

/* fat_list's callback: keep the entry while there is room */
static int32_t collect(const DIRENT *ps_entry, void *p_ctx)
{
/* local variables */
    LIST *ps_list;

/* start values */
    ps_list = (LIST *)p_ctx;
    if (ps_list->i32_count < LIST_MAX)
    {
        ps_list->as_entry[ps_list->i32_count] = *ps_entry;
/* one more */
        ps_list->i32_count++;
    }
/* the scan goes on */
    return 0;
}

/* play one tape file into its timeline file */
static void play(const DIRENT *ps_entry, const char *pc_path, const char *pc_outdir)
{
/* local variables */
    char ac_name[OUT_NAME_LEN];
    char *pc_char;
    int32_t i32_result;
/* a guard against endless files, TZX or TAP, the end */
    int32_t i32_guard;
    int32_t i32_tzx;
    bool b_done;

/* start values */
    pc_char = NULL;
    i32_result = TS_RUN;
    i32_guard = 0;
/* not a TZX, not done */
    i32_tzx = 0;
    b_done = false;
/* the extension decides */
    if (strcmp(ps_entry->ac_ext, "TZX") == SAME)
    {
        i32_tzx = ONE;
    }
/* the output file: the path with every slash as an underscore */
    snprintf(ac_name, sizeof ac_name, "%s/%s.txt", pc_outdir, pc_path + PATH_SKIP);
    for (pc_char = ac_name + strlen(pc_outdir) + ONE; *pc_char != 0; pc_char++)
    {
/* a slash */
        if (*pc_char == '/')
        {
            *pc_char = '_';
        }
    }
/* the file */
    g_ps_out = fopen(ac_name, "wb");
    if (g_ps_out == NULL)
    {
/* no output file: the test cannot go on */
        perror(ac_name);
        exit(EXIT_ERRORS);
    }
/* a new timeline */
    g_i32_lvl = 0;
    g_b_have = false;
    g_ui32_len0 = 0;
/* no bit lengths yet; the file from its start block */
    g_ui32_len1 = 0;
    ff_open(&g_s_file, ps_entry->ui32_clus, ps_entry->ui32_size);
    tape_start(&g_s_file, i32_tzx, g_ui32_start_block);
/* pump until the end, going on after every stop block */
    while (!b_done)
    {
        i32_result = tape_pump();
        if (i32_result == TS_STOP)
        {
/* after a stop block the tape goes on */
            tape_continue();
        }
        else if (i32_result != TS_RUN)
        {
            b_done = true;
        }
        else
        {
/* still running: count, a file that never ends is an error */
            i32_guard++;
            if (i32_guard > GUARD_MAX)
            {
/* given up */
                i32_result = TS_ERR;
                b_done = true;
            }
        }
    }
/* the last segment */
    if (g_b_have)
    {
        fprintf(g_ps_out, "%u %llu\n", (unsigned)g_ui32_seg_lvl, (unsigned long long)g_ui64_seg_len);
    }
/* closed; did the file end as it should? */
    fclose(g_ps_out);
    if (i32_result != TS_END)
    {
/* an error */
        printf("ERROR: %s ended with %d\n", pc_path, (int)i32_result);
        g_i32_errors++;
    }
}

/* list one directory, play its tape files, go down into its folders */
static void walk(uint32_t ui32_clus, const char *pc_path, const char *pc_outdir)
{
/* local variables */
    char ac_sub[PATH_LEN];
    LIST *ps_list;
    DIRENT *ps_entry;
/* a counter */
    int32_t i32_index;

    ps_list = (LIST *)calloc(ONE, sizeof *ps_list);
    ps_entry = NULL;
/* the folder's entries */
    i32_index = 0;
    if (fat_list(ui32_clus, collect, ps_list) != FAT_OK)
    {
        printf("ERROR: listing %s\n", pc_path);
/* counted */
        g_i32_errors++;
    }
    for (i32_index = 0; i32_index < ps_list->i32_count; i32_index++)
    {
        ps_entry = &ps_list->as_entry[i32_index];
/* not the folder itself, nor its parent */
        if ((strcmp(ps_entry->ac_name, ".") != SAME) && (strcmp(ps_entry->ac_name, "..") != SAME))
        {
            snprintf(ac_sub, sizeof ac_sub, "%s%s", pc_path, ps_entry->ac_name);
            if ((ps_entry->ui8_attr & ATTR_DIR) != 0)
            {
/* a folder */
                printf("D %s\n", ac_sub);
                strcat(ac_sub, "/");
                walk(ps_entry->ui32_clus, ac_sub, pc_outdir);
            }
            else
            {
/* a file: played when it is a tape */
                printf("F %s %u\n", ac_sub, (unsigned)ps_entry->ui32_size);
                if ((strcmp(ps_entry->ac_ext, "TAP") == SAME) || (strcmp(ps_entry->ac_ext, "TZX") == SAME))
                {
                    play(ps_entry, ac_sub, pc_outdir);
                }
            }
        }
    }
/* the list's memory goes back */
    free(ps_list);
}

int main(int argc, char **argv)
{
/* the mount's result, the exit code, the FAT type */
    int32_t i32_result;
    int32_t i32_exit;
    int32_t i32_fat_type;

/* start values */
    i32_result = 0;
    i32_exit = EXIT_OK;
    i32_fat_type = FAT_TYPE_16;
/* two arguments are needed */
    if (argc < ARGS_MIN)
    {
        fprintf(stderr, "usage: host_test IMAGE OUTDIR [START_BLOCK]\n");
        i32_exit = EXIT_USAGE;
    }
    else
    {
/* the block to start at is optional */
        if (argc > ARG_BLOCK)
        {
            g_ui32_start_block = (uint32_t)atoi(argv[ARG_BLOCK]);
        }
/* the card image */
        g_ps_img = fopen(argv[ARG_IMAGE], "rb");
        if (g_ps_img == NULL)
        {
/* it cannot be opened */
            perror(argv[ARG_IMAGE]);
            i32_exit = EXIT_USAGE;
        }
    }
/* the image is open: mount it */
    if (i32_exit == EXIT_OK)
    {
        i32_result = fat_mount();
        if (i32_result != FAT_OK)
        {
/* no file system */
            printf("ERROR: mount %d\n", (int)i32_result);
            i32_exit = EXIT_ERRORS;
        }
    }
/* mounted: the whole tree */
    if (i32_exit == EXIT_OK)
    {
        if (fat_is_fat32())
        {
            i32_fat_type = FAT_TYPE_32;
        }
/* the type, then the tree */
        printf("mounted FAT%d\n", (int)i32_fat_type);
        walk(0, "/", argv[ARG_OUTDIR]);
        printf("%ld sector reads, %d errors\n", (long)g_i64_reads, (int)g_i32_errors);
/* errors give exit code 1 */
        if (g_i32_errors != 0)
        {
            i32_exit = EXIT_ERRORS;
        }
    }
    return i32_exit;
}
