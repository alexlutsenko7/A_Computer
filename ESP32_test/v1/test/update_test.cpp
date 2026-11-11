/* update_test.cpp -- PC test of the flash update (update.cpp, flash.cpp, fat.cpp as C++) */
/* */
/* Runs against the flash model (flash_model.cpp: 4 KB erase, page program, busy times, a write */
/* while a byte shifts is ignored; TIMER advances 10 us per register access; the flash stream is */
/* one register access plus 1 us per byte; tests 1-7 use it). */
/* Usage: update_test card.img LUPDATE.BIN (card.img holds LUPDATE.BIN in its root; the test */
/* works on copies of it) */
/*   1. old flash (a few machine sectors and one menu sector differ, C64 ROM area with data): update, */
/*      flash = image outside the C64 area, C64 area untouched, menu_changed, file deleted */
/*   2. flash already equal: nothing written, menu_changed 0 */
/*   3. a damaged file: rejected by upd_check, flash untouched */
/*   4. updates cut off after a random number of register accesses (power off / ESP32 restart): the */
/*      menu sectors are only touched after every machine sector is right; the file is still there; */
/*      a full update afterwards gives the image */
/*   5. no machines: upd_machines_present on an empty flash / after the loader */
/*   6, 7. first install on a loader board (FF / 00 after the menu) */
/*   8. the same with an old menu (link version 1: no flash stream, byte-wise) */
/*   9. the same with a stream that breaks (a dropped byte) in the middle: byte-wise from there on */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
/* the cut-off jump; the registers and the platform */
#include <setjmp.h>
#include "../../../ESP32/v1/src/hw.h"
#include "../../../ESP32/v1/src/hal.h"
/* the card, the code under test */
#include "../../../ESP32/v1/src/fat.h"
#include "../../../ESP32/v1/src/update.h"
#include "../../../ESP32/v1/src/flash.h"
/* the flash model */
#include "flash_model.h"

/* hw.h: main is the ESP32 loader task */
#undef main

/* bytes of one card sector */
#define SECTOR_SIZE 512
/* results of the card functions */
#define SD_OK 0
#define SD_ERROR (-1)
/* what fifo_free always answers: the whole FIFO */
#define FIFO_ROOM 512
/* the link is always there */
#define LINK_ALIVE 1
/* the flash: the menu's megabyte, and the C64 ROM area an update never touches */
#define MENU_END 0x100000u
#define SKIP_LO 0x580000u
#define SKIP_HI 0x600000u
/* the C64 ROMs "installed" in the old flash */
#define C64_ROM_LEN 49152u
#define C64_ROM_MUL 7
/* the update file: a header of 256 bytes with the image's length at 8..11 */
#define FILE_HDR 256
#define LEN_OFS 8
#define LEN_OFS1 9
/* its upper bytes */
#define LEN_OFS2 10
#define LEN_OFS3 11
/* their shifts */
#define BYTE1_SHIFT 8
#define BYTE2_SHIFT 16
#define BYTE3_SHIFT 24
/* the old flash: the sectors changed, the byte in each, the menu byte changed */
#define CHANGED_SECTORS 5
#define CHANGED_OFS 17
#define CHANGED_XOR 0x5A
/* the menu's */
#define MENU_CHANGED_ADDR 0x01003u
#define MENU_CHANGED_XOR 0xFF
/* sectors test 1 must write: the five and the menu's */
#define WRITTEN_WANTED 6
/* the damaged file: one bit of this image byte */
#define DAMAGE_OFS 0x123456
#define DAMAGE_XOR 1
#define DAMAGE_LEN 1
/* flash fill values */
#define ERASED 0xFF
#define ZEROED 0x00
/* the copy buffer for the card */
#define COPY_BUF 65536
/* cut-offs tried; rand() is 15 bits on Windows */
#define CUT_TRIES 60
#define RAND_BITS 15
/* the streams that break in test 9 */
#define BREAK_FIRST 300
#define BREAK_LAST 301
/* run_update: no update file, cut off */
#define RUN_NO_FILE (-100)
#define RUN_CUT (-200)
/* the random generator's seed */
#define SEED 1
/* the command line */
#define ARG_CARD 1
#define ARG_FILE 2
#define ARGS_MIN 3
/* the program's results */
#define EXIT_OK 0
#define EXIT_ERRORS 1
#define EXIT_USAGE 2
/* the modelled seconds of a count of register accesses, and microseconds as a real number */
#define S_PER_ACCESS 10e-6
#define US_PER_S 1e6
/* one */
#define ONE 1

/* machine sectors the old flash differs in */
static const uint32_t g_aui32_changed[CHANGED_SECTORS] = { 0x101000u, 0x1F0000u, 0x205000u, 0x400000u, 0x541000u };
/* the image of the update file, and the flash before an update */
static uint8_t g_aui8_img[FM_FLASH_SIZE];
static uint8_t g_aui8_old[FM_FLASH_SIZE];
/* buffers: the file's header, the card copy */
static uint8_t g_aui8_hdr[FILE_HDR];
static uint8_t g_aui8_copy[COPY_BUF];
/* the update file on the card, opened to damage it (too big for the stack) */
static FFILE g_s_file;
/* the image's length */
static uint32_t g_ui32_img_len;
/* the card: the working copy, and the file it is copied from */
static FILE *g_ps_card;
static const char *g_pc_card_src;
/* errors found */
static int32_t g_i32_errors;

/* read one sector of the working copy */
int32_t sd_read(uint32_t ui32_lba, uint8_t *pui8_buf)
{
    int32_t i32_result;

    i32_result = SD_ERROR;
/* seek, then read: both must work */
    if (fseek(g_ps_card, (long)ui32_lba * SECTOR_SIZE, SEEK_SET) == 0)
    {
        if (fread(pui8_buf, SECTOR_SIZE, ONE, g_ps_card) == ONE)
        {
            i32_result = SD_OK;
        }
    }
/* SD_OK or SD_ERROR */
    return i32_result;
}

/* write one sector of the working copy */
int32_t sd_write(uint32_t ui32_lba, const uint8_t *pui8_buf)
{
    int32_t i32_result;

    i32_result = SD_ERROR;
/* seek, then write: both must work */
    if (fseek(g_ps_card, (long)ui32_lba * SECTOR_SIZE, SEEK_SET) == 0)
    {
        if (fwrite(pui8_buf, SECTOR_SIZE, ONE, g_ps_card) == ONE)
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

/* the FPGA answers */
int32_t link_alive(void)
{
    return LINK_ALIVE;
}

/* a new working copy of the card, mounted; the test ends without it */
static void fresh_card(void)
{
/* local variables */
    FILE *ps_src;
    size_t sz_count;

/* start values */
    ps_src = fopen(g_pc_card_src, "rb");
    sz_count = 0;
    if (g_ps_card != NULL)
    {
/* the old working copy is closed */
        fclose(g_ps_card);
    }
    g_ps_card = fopen("work_card.img", "w+b");
    if ((ps_src == NULL) || (g_ps_card == NULL))
    {
/* the test cannot run without it */
        printf("ERROR: card copy\n");
        exit(EXIT_USAGE);
    }
/* the copy */
    sz_count = fread(g_aui8_copy, ONE, sizeof g_aui8_copy, ps_src);
    while (sz_count > 0)
    {
        fwrite(g_aui8_copy, ONE, sz_count, g_ps_card);
/* the next piece */
        sz_count = fread(g_aui8_copy, ONE, sizeof g_aui8_copy, ps_src);
    }
    fclose(ps_src);
    fflush(g_ps_card);
/* the copy must have a file system */
    if (fat_mount() != FAT_OK)
    {
        printf("ERROR: mount\n");
        exit(EXIT_USAGE);
    }
}

/* is the address in the C64 ROM area? */
static bool in_skip(uint32_t ui32_addr)
{
    return (ui32_addr >= SKIP_LO) && (ui32_addr < SKIP_HI);
}

/* is the flash the image from ui32_from on, outside the C64 ROM area? */
static bool sectors_right(uint32_t ui32_from)
{
/* local variables */
    uint32_t ui32_addr;
    bool b_right;

/* start values */
    b_right = true;
    for (ui32_addr = ui32_from; ui32_addr < g_ui32_img_len; ui32_addr += FM_SECTOR)
    {
        if (!in_skip(ui32_addr) && (memcmp(g_aui8_fm_flash + ui32_addr, g_aui8_img + ui32_addr, FM_SECTOR) != 0))
        {
/* a sector differs */
            b_right = false;
        }
    }
    return b_right;
}

/* the whole flash is the image */
static bool flash_is_image(void)
{
    return sectors_right(0);
}

/* every machine sector (after the menu) is right */
static bool machines_right(void)
{
    return sectors_right(MENU_END);
}

/* the C64 ROM area is as before the update */
static bool skip_untouched(void)
{
    return memcmp(g_aui8_fm_flash + SKIP_LO, g_aui8_old + SKIP_LO, SKIP_HI - SKIP_LO) == 0;
}

/* is the update file still on the card? */
static bool file_there(void)
{
    DIRENT s_entry;

    return upd_find(&s_entry) > 0;
}

/* one update (check + run), cut off after i64_cut_after register accesses (FM_NO_CUT: never): */
/* the update's result, RUN_NO_FILE or RUN_CUT */
static int32_t run_update(int64_t i64_cut_after, int32_t *pi32_menu_changed, uint32_t *pui32_written)
{
/* local variables */
    DIRENT s_entry;
    int32_t i32_result;

/* start values */
    i32_result = RUN_NO_FILE;
    g_i64_fm_accesses = 0;
    fm_link_idle();
/* only with an update file */
    if (upd_find(&s_entry) > 0)
    {
        g_i64_fm_cut_at = i64_cut_after;
        if (setjmp(g_s_fm_cut) != 0)
        {
/* cut off: the model jumped here */
            i32_result = RUN_CUT;
        }
        else
        {
/* check, then update */
            i32_result = upd_check(&s_entry, NULL);
            if (i32_result == UPD_OK)
            {
                i32_result = upd_run(&s_entry, NULL, pi32_menu_changed, pui32_written);
            }
        }
/* no cut-off any more */
        g_i64_fm_cut_at = FM_NO_CUT;
    }
    return i32_result;
}

/* the flash as before an update */
static void old_flash(void)
{
    memcpy(g_aui8_fm_flash, g_aui8_old, FM_FLASH_SIZE);
}

/* the flash of a board shipped with the loader .jic: the menu only, ui8_fill after it; */
/* b_set_old: the same fill is what the C64 ROM area must keep */
static void loader_board(uint8_t ui8_fill, bool b_set_old)
{
    memset(g_aui8_fm_flash, ui8_fill, FM_FLASH_SIZE);
    memcpy(g_aui8_fm_flash, g_aui8_img, MENU_END);
/* the old flash too */
    if (b_set_old)
    {
        memset(g_aui8_old, ui8_fill, FM_FLASH_SIZE);
    }
/* the model's clock starts again */
    fm_clock_restart();
}

/* one more error, with its text */
static void error(const char *pc_text)
{
    printf("%s\n", pc_text);
    g_i32_errors++;
}

/* the image from the update file; false: the file cannot be used */
static bool read_image(const char *pc_name)
{
/* local variables */
    FILE *ps_file;
    bool b_ok;

/* start values */
    ps_file = fopen(pc_name, "rb");
    b_ok = false;
/* no such file */
    if (ps_file == NULL)
    {
        printf("ERROR: %s\n", pc_name);
    }
    else if (fread(g_aui8_hdr, ONE, FILE_HDR, ps_file) == FILE_HDR)
    {
/* the length from the header, then the image; the rest stays erased */
        g_ui32_img_len = (uint32_t)g_aui8_hdr[LEN_OFS] | ((uint32_t)g_aui8_hdr[LEN_OFS1] << BYTE1_SHIFT) |
                         ((uint32_t)g_aui8_hdr[LEN_OFS2] << BYTE2_SHIFT) | ((uint32_t)g_aui8_hdr[LEN_OFS3] << BYTE3_SHIFT);
        memset(g_aui8_img, ERASED, sizeof g_aui8_img);
        b_ok = fread(g_aui8_img, ONE, g_ui32_img_len, ps_file) == g_ui32_img_len;
    }
    else
    {
/* too short for a header */
    }
    if (ps_file != NULL)
    {
        fclose(ps_file);
    }
    return b_ok;
}

/* the "old" flash: the image with a few machine sectors and one menu sector changed, the C64 */
/* ROM area holding installed ROMs, the rest of the flash erased */
static void make_old(void)
{
/* local variables */
    uint32_t ui32_index;

    memcpy(g_aui8_old, g_aui8_img, FM_FLASH_SIZE);
/* one byte in each of five sectors */
    for (ui32_index = 0; ui32_index < CHANGED_SECTORS; ui32_index++)
    {
        g_aui8_old[g_aui32_changed[ui32_index] + CHANGED_OFS] ^= CHANGED_XOR;
    }
/* the menu */
    g_aui8_old[MENU_CHANGED_ADDR] ^= MENU_CHANGED_XOR;
    for (ui32_index = SKIP_LO; ui32_index < (SKIP_LO + C64_ROM_LEN); ui32_index++)
    {
        g_aui8_old[ui32_index] = (uint8_t)(ui32_index * C64_ROM_MUL);
    }
}

/* 1: an update of the old flash; returns the register accesses it took */
static int64_t test_update(void)
{
/* local variables */
    uint32_t ui32_written;
    int64_t i64_full;
    int32_t i32_result;
/* the menu changed */
    int32_t i32_menu_changed;

    ui32_written = 0;
    i64_full = 0;
/* nothing yet; a fresh card */
    i32_result = 0;
    i32_menu_changed = 0;
    fresh_card();
/* the old flash, no erases counted yet */
    old_flash();
    g_i64_fm_erases = 0;
    i32_result = run_update(FM_NO_CUT, &i32_menu_changed, &ui32_written);
/* what it took */
    i64_full = g_i64_fm_accesses;
    printf("1. update: r=%d written=%u menu_changed=%d erases=%ld, %ld register accesses, %.1f s modelled\n",
           (int)i32_result, (unsigned)ui32_written, (int)i32_menu_changed, (long)g_i64_fm_erases, (long)i64_full,
           g_i64_fm_accesses * S_PER_ACCESS);
/* the image, the C64 area kept, the menu changed, six sectors, the file gone */
    if ((i32_result != UPD_OK) || !flash_is_image() || !skip_untouched() || (i32_menu_changed == 0) ||
        (ui32_written != WRITTEN_WANTED) || file_there())
    {
        printf("ERROR 1: image %d skip %d file %d\n", (int)flash_is_image(), (int)skip_untouched(), (int)file_there());
        g_i32_errors++;
    }
/* the accesses of a full update */
    return i64_full;
}

/* 2: the flash is up to date already */
static void test_up_to_date(void)
{
/* local variables */
    uint32_t ui32_written;
    int32_t i32_result;
    int32_t i32_menu_changed;

/* start values */
    ui32_written = 0;
    i32_result = 0;
    i32_menu_changed = 0;
/* a fresh card, the flash as test 1 left it */
    fresh_card();
    g_i64_fm_erases = 0;
    i32_result = run_update(FM_NO_CUT, &i32_menu_changed, &ui32_written);
/* what happened */
    printf("2. up to date: r=%d written=%u menu_changed=%d erases=%ld\n", (int)i32_result, (unsigned)ui32_written,
           (int)i32_menu_changed, (long)g_i64_fm_erases);
/* nothing written, the file gone */
    if ((i32_result != UPD_OK) || (ui32_written != 0) || (i32_menu_changed != 0) || (g_i64_fm_erases != 0) ||
        !flash_is_image() || file_there())
    {
        error("ERROR 2");
    }
}

/* 3: a damaged file (one image byte flipped on the card) */
static void test_damaged(void)
{
/* local variables */
    DIRENT s_entry;
    uint32_t ui32_written;
    uint8_t ui8_byte;
/* the result, the menu changed */
    int32_t i32_result;
    int32_t i32_menu_changed;

/* start values */
    ui32_written = 0;
    ui8_byte = 0;
    i32_result = 0;
/* a fresh card */
    i32_menu_changed = 0;
    fresh_card();
/* the byte read, one bit changed, written back */
    upd_find(&s_entry);
    ff_open(&g_s_file, s_entry.ui32_clus, s_entry.ui32_size);
    ff_seek(&g_s_file, FILE_HDR + DAMAGE_OFS);
/* one bit flipped */
    ui8_byte = (uint8_t)(ff_getc(&g_s_file) ^ DAMAGE_XOR);
    ff_update(&g_s_file, FILE_HDR + DAMAGE_OFS, &ui8_byte, DAMAGE_LEN);
/* the update must refuse it */
    old_flash();
    i32_result = run_update(FM_NO_CUT, &i32_menu_changed, &ui32_written);
    printf("3. damaged file: r=%d\n", (int)i32_result);
/* rejected: the flash untouched, the file kept */
    if ((i32_result != UPD_EBAD) || (memcmp(g_aui8_fm_flash, g_aui8_old, FM_FLASH_SIZE) != 0) || !file_there())
    {
        error("ERROR 3");
    }
}

/* 4: cut-offs, each followed by a full update */
static void test_cuts(int64_t i64_full)
{
/* local variables */
    uint32_t ui32_written;
    int64_t i64_at;
    int64_t i64_high;
/* counters, results */
    int32_t i32_try;
    int32_t i32_result;
    int32_t i32_menu_changed;
/* cut-offs made, cut-offs in the menu's sectors */
    int32_t i32_cuts;
    int32_t i32_menu_touched;

/* start values */
    ui32_written = 0;
    i64_at = 0;
    i64_high = 0;
/* nothing yet */
    i32_try = 0;
    i32_result = 0;
    i32_menu_changed = 0;
/* nothing counted; try by try */
    i32_cuts = 0;
    i32_menu_touched = 0;
    for (i32_try = 0; i32_try < CUT_TRIES; i32_try++)
    {
/* a random access of the full update: 30 bits from two rand() calls */
        i64_high = (int64_t)rand() << RAND_BITS;
        i64_at = ONE + ((i64_high ^ rand()) % i64_full);
/* a fresh card, the old flash, the update cut off there */
        fresh_card();
        old_flash();
        i32_result = run_update(i64_at, &i32_menu_changed, &ui32_written);
/* it was cut off */
        if (i32_result == RUN_CUT)
        {
            i32_cuts++;
/* power off / restart: the flash finishes */
            g_ui64_fm_now_us += FM_US_PER_S;
            if (memcmp(g_aui8_fm_flash, g_aui8_old, MENU_END) != 0)
            {
/* the menu area was touched */
                i32_menu_touched++;
                if (!machines_right())
                {
/* too early */
                    printf("ERROR 4: cut at %ld: menu touched before the machines were right\n", (long)i64_at);
                    g_i32_errors++;
                }
            }
/* the C64 ROM area */
            if (!skip_untouched())
            {
                printf("ERROR 4: cut at %ld: C64 ROM area touched\n", (long)i64_at);
                g_i32_errors++;
            }
/* the file must still be there */
            if (!file_there())
            {
                printf("ERROR 4: cut at %ld: file deleted\n", (long)i64_at);
                g_i32_errors++;
            }
/* the update afterwards must give the image */
            i32_result = run_update(FM_NO_CUT, &i32_menu_changed, &ui32_written);
            if ((i32_result != UPD_OK) || !flash_is_image() || !skip_untouched() || file_there())
            {
/* it did not */
                printf("ERROR 4: update after cut at %ld: r=%d\n", (long)i64_at, (int)i32_result);
                g_i32_errors++;
            }
        }
    }
    printf("4. %d cut-offs (%d in the menu sectors)\n", (int)i32_cuts, (int)i32_menu_touched);
}

/* a first install's result: the image, the C64 area kept, the menu not changed, the file gone */
static bool install_right(int32_t i32_result, int32_t i32_menu_changed)
{
    return (i32_result == UPD_OK) && flash_is_image() && skip_untouched() && (i32_menu_changed == 0) && !file_there();
}

/* 6, 7, 8: first installs on a loader board */
static void test_first_installs(void)
{
/* local variables */
    uint32_t ui32_written;
    int32_t i32_result;
    int32_t i32_menu_changed;

/* start values */
    ui32_written = 0;
    i32_result = 0;
    i32_menu_changed = 0;
/* 6: a board shipped with the loader .jic: the menu only, everything else erased */
    fresh_card();
    loader_board(ERASED, true);
    g_i64_fm_erases = 0;
/* the update */
    i32_result = run_update(FM_NO_CUT, &i32_menu_changed, &ui32_written);
    printf("6. first install on a loader board: r=%d written=%u menu_changed=%d, %.1f s modelled\n", (int)i32_result,
           (unsigned)ui32_written, (int)i32_menu_changed, g_ui64_fm_now_us / US_PER_S);
    if (!install_right(i32_result, i32_menu_changed))
    {
/* not as expected */
        error("ERROR 6");
    }
/* 7: first install on a board the loader .jic cleared with 00 */
    fresh_card();
    loader_board(ZEROED, true);
    i32_result = run_update(FM_NO_CUT, &i32_menu_changed, &ui32_written);
/* what happened */
    printf("7. first install over 00: r=%d written=%u menu_changed=%d, %.1f s modelled\n", (int)i32_result,
           (unsigned)ui32_written, (int)i32_menu_changed, g_ui64_fm_now_us / US_PER_S);
    if (!install_right(i32_result, i32_menu_changed))
    {
        error("ERROR 7");
    }
/* 8: an old menu without the stream */
    g_b_fm_stream_on = false;
    fresh_card();
    loader_board(ERASED, true);
/* the update, byte-wise */
    i32_result = run_update(FM_NO_CUT, &i32_menu_changed, &ui32_written);
    printf("8. first install, old menu (byte-wise): r=%d written=%u, %.1f s modelled\n", (int)i32_result,
           (unsigned)ui32_written, g_ui64_fm_now_us / US_PER_S);
    if (!install_right(i32_result, i32_menu_changed))
    {
/* not as expected */
        error("ERROR 8");
    }
}

/* 9: the stream breaks in the middle of the update (a page program, a sector read) */
static void test_stream_breaks(void)
{
/* local variables */
    uint32_t ui32_written;
    int64_t i64_break;
/* the result, the menu changed */
    int32_t i32_result;
    int32_t i32_menu_changed;

/* start values */
    ui32_written = 0;
    i64_break = 0;
    i32_result = 0;
/* the two stream numbers */
    i32_menu_changed = 0;
    for (i64_break = BREAK_FIRST; i64_break <= BREAK_LAST; i64_break++)
    {
        g_b_fm_stream_on = true;
/* counted from 0; this one breaks */
        g_i64_fm_streams = 0;
        g_i64_fm_stream_break = i64_break;
        fresh_card();
/* a loader board */
        loader_board(ERASED, false);
        i32_result = run_update(FM_NO_CUT, &i32_menu_changed, &ui32_written);
        printf("9. stream breaks at stream %ld: r=%d written=%u, %.1f s modelled\n", (long)i64_break, (int)i32_result,
               (unsigned)ui32_written, g_ui64_fm_now_us / US_PER_S);
/* installed all the same, and the stream given up */
        if (!install_right(i32_result, i32_menu_changed) || g_b_fm_stream_on)
        {
            error("ERROR 9");
        }
    }
/* the stream works again for the tests that follow */
    g_b_fm_stream_on = true;
    g_i64_fm_stream_break = 0;
}

/* 5: are machines installed? */
static void test_machines_present(void)
{
/* the loader .jic: the menu only */
    memset(g_aui8_fm_flash, ERASED, FM_FLASH_SIZE);
    memcpy(g_aui8_fm_flash, g_aui8_img, MENU_END);
/* no machines there */
    if (upd_machines_present() != 0)
    {
        error("ERROR 5: loader taken as machines installed");
    }
/* the loader .jic: 00 after the menu */
    memset(g_aui8_fm_flash + MENU_END, ZEROED, FM_FLASH_SIZE - MENU_END);
    if (upd_machines_present() != 0)
    {
        error("ERROR 5: zeroed slots taken as machines installed");
    }
/* the whole image */
    memcpy(g_aui8_fm_flash, g_aui8_img, g_ui32_img_len);
    if (upd_machines_present() == 0)
    {
        error("ERROR 5: machines not seen");
    }
/* done */
    printf("5. machines present: checked\n");
}

/* the test program */
int main(int argc, char **argv)
{
    int64_t i64_full;
    int32_t i32_exit;

/* start values; output without buffering */
    i64_full = 0;
    i32_exit = EXIT_OK;
    setvbuf(stdout, NULL, _IONBF, 0);
/* two arguments are needed */
    if (argc < ARGS_MIN)
    {
        printf("usage: update_test card.img LUPDATE.BIN\n");
        i32_exit = EXIT_USAGE;
    }
/* the update file must be readable */
    else if (!read_image(argv[ARG_FILE]))
    {
        i32_exit = EXIT_USAGE;
    }
    else
    {
/* the tests, in the order of their random numbers */
        g_pc_card_src = argv[ARG_CARD];
        srand(SEED);
        make_old();
/* tests 1 to 3 */
        i64_full = test_update();
        test_up_to_date();
        test_damaged();
/* 4, then 6 to 8 */
        test_cuts(i64_full);
        test_first_installs();
/* 9 and 5 */
        test_stream_breaks();
        test_machines_present();
/* the working copy is not kept */
        fclose(g_ps_card);
        remove("work_card.img");
        if (g_i32_errors != 0)
        {
/* errors give exit code 1 */
            printf("FAIL (%d errors)\n", (int)g_i32_errors);
            i32_exit = EXIT_ERRORS;
        }
        else
        {
/* none */
            printf("PASS\n");
        }
    }
    return i32_exit;
}
