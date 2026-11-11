/* c64rom_test.cpp -- PC test of the L64 ROM install (c64.cpp, compiled as C++) */
/* */
/* Runs against the flash model (flash_model.cpp: pass-through register, SPI flash, modelled */
/* time, cut-offs). The flash stream exists only in the machine menu: byte-wise here, as in L64. */
/* Usage: c64rom_test card.img romdir [busy_us] (5 = the real link; 25 makes every byte still */
/* busy at the next access) */
/*   1. flash in the state seen on hardware 2026-10-28 (image right, header bytes FF): install */
/*   2. installs cut off after a random number of register accesses (an ESP32 restart): */
/*      the flash may only look installed (c64_rom_present) when the whole image is right */
/*   3. a full install after each cut-off: image right, RELOAD written */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
/* the cut-off jump; the registers and the platform */
#include <setjmp.h>
#include "../../../ESP32/v2/src/hw.h"
#include "../../../ESP32/v2/src/hal.h"
/* the code under test, the flash model */
#include "../../../ESP32/v2/src/fat.h"
#include "../../../ESP32/v2/src/c64.h"
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
/* the ROM image in the flash */
#define ROM_BASE 0x580000u
#define ROM_LEN 49152u
/* its header: F3, the signature, the version */
#define HDR_MAGIC 0xF3
#define HDR_SIGN_OFS 1
#define HDR_SIGN_LEN 12
/* the version, the header's length */
#define HDR_VERSION_OFS 13
#define HDR_VERSION 1
#define HDR_LEN 14
/* its parts: character ROM, BASIC, KERNAL, the 1541's ROM */
#define CHAR_OFS 4096
#define CHAR_LEN 4096
#define BASIC_OFS 8192
/* BASIC's length, the KERNAL */
#define BASIC_LEN 8192
#define KERNAL_OFS 16384
#define KERNAL_LEN 8192
/* the 1541's ROM */
#define DOS_OFS 32768
#define DOS_LEN 16384
/* an erased byte */
#define ERASED 0xFF
/* a file's path */
#define PATH_LEN 512
/* the cut-offs: 300 tries, the first 20 at the very end of an install */
#define CUT_TRIES 300
#define CUT_LAST 20
/* one RELOAD per install */
#define RELOADS_WANTED 1
/* the random generator's seed */
#define SEED 1
/* run_install: finished, cut off */
#define RUN_DONE 0
#define RUN_CUT 1
/* the command line */
#define ARG_CARD 1
#define ARG_ROMDIR 2
/* the optional speed */
#define ARG_BUSY 3
#define ARGS_MIN 3
/* the program's results */
#define EXIT_OK 0
#define EXIT_ERRORS 1
#define EXIT_USAGE 2
/* microseconds per second, as a real number */
#define US_PER_S 1e6
/* one */
#define ONE 1

/* the image the flash must hold */
static uint8_t g_aui8_expect[ROM_LEN];
/* the card image */
static FILE *g_ps_card;
/* errors found */
static int32_t g_i32_errors;

/* read one sector of the card */
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

/* the card is read-only here */
int32_t sd_write(uint32_t ui32_lba, const uint8_t *pui8_buf)
{
    (void)ui32_lba;
    (void)pui8_buf;
/* always an error */
    return SD_ERROR;
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

/* the install's progress texts are not shown */
static void progress(const char *pc_text)
{
    (void)pc_text;
}

/* does the flash hold the whole image? */
static bool image_right(void)
{
    return memcmp(g_aui8_fm_flash + ROM_BASE, g_aui8_expect, ROM_LEN) == 0;
}

/* one install, cut off after i64_cut_after register accesses (FM_NO_CUT: never): RUN_DONE or RUN_CUT */
static int32_t run_install(int64_t i64_cut_after, int32_t *pi32_result)
{
/* local variables */
    int32_t i32_run;

/* start values */
    i32_run = RUN_DONE;
    g_i64_fm_accesses = 0;
    g_i64_fm_cut_at = i64_cut_after;
/* the pass-through keeps its chip select */
    fm_link_idle();
    if (setjmp(g_s_fm_cut) != 0)
    {
/* cut off: the model jumped here */
        i32_run = RUN_CUT;
    }
    else
    {
        *pi32_result = c64_rom_install(progress);
    }
/* no cut-off any more */
    g_i64_fm_cut_at = FM_NO_CUT;
    return i32_run;
}

/* one ROM file into the expected image; the test ends without it */
static void load(const char *pc_dir, const char *pc_name, uint32_t ui32_ofs, uint32_t ui32_len)
{
/* local variables */
    char ac_path[PATH_LEN];
    FILE *ps_file;

/* the file's path */
    snprintf(ac_path, sizeof ac_path, "%s/%s", pc_dir, pc_name);
    ps_file = fopen(ac_path, "rb");
    if ((ps_file == NULL) || (fread(g_aui8_expect + ui32_ofs, ONE, ui32_len, ps_file) != ui32_len))
    {
/* no such file, or too short */
        printf("ERROR: %s\n", ac_path);
        exit(EXIT_USAGE);
    }
    fclose(ps_file);
}

/* 1: the hardware state (image right, header bytes FF); returns the accesses of a full install */
static int64_t test_hardware_state(void)
{
/* local variables */
    int64_t i64_full;
    int32_t i32_result;

/* start values */
    i64_full = 0;
    i32_result = 0;
/* an erased flash with the image, less its header */
    memset(g_aui8_fm_flash, ERASED, sizeof g_aui8_fm_flash);
    memcpy(g_aui8_fm_flash + ROM_BASE, g_aui8_expect, ROM_LEN);
    memset(g_aui8_fm_flash + ROM_BASE, ERASED, HDR_LEN);
/* without its header the image is not installed */
    if (c64_rom_present() != 0)
    {
        printf("ERROR: header FF taken as installed\n");
        g_i32_errors++;
    }
/* a full install */
    run_install(FM_NO_CUT, &i32_result);
    i64_full = g_i64_fm_accesses;
/* installed: image, header, one RELOAD */
    if ((i32_result != 0) || !image_right() || (c64_rom_present() == 0) || (g_i32_fm_reloads != RELOADS_WANTED))
    {
        printf("ERROR: install from the hardware state: r=%d right=%d present=%d reloads=%d\n", (int)i32_result,
               (int)image_right(), (int)c64_rom_present(), (int)g_i32_fm_reloads);
        g_i32_errors++;
    }
/* what it took */
    printf("full install: %ld register accesses, %.2f s modelled\n", (long)i64_full, g_ui64_fm_now_us / US_PER_S);
    return i64_full;
}

/* 2 + 3: cut-offs, each followed by a full install */
static void test_cuts(int64_t i64_full)
{
/* local variables */
    int64_t i64_at;
    int32_t i32_try;
    int32_t i32_result;
/* cut-offs made, images that looked installed */
    int32_t i32_cuts;
    int32_t i32_looked_valid;

/* start values */
    i64_at = 0;
    i32_try = 0;
    i32_result = 0;
/* nothing counted yet */
    i32_cuts = 0;
    i32_looked_valid = 0;
    for (i32_try = 0; i32_try < CUT_TRIES; i32_try++)
    {
/* a random access of the full install */
        i64_at = ONE + (rand() % i64_full);
/* the last accesses: header write / check */
        if (i32_try < CUT_LAST)
        {
            i64_at = i64_full - i32_try;
        }
/* an install that finished before the cut is not counted */
        if (run_install(i64_at, &i32_result) == RUN_CUT)
        {
            i32_cuts++;
/* the ESP32 restarts: the flash finishes */
            g_ui64_fm_now_us += FM_US_PER_S;
            if (c64_rom_present() != 0)
            {
                i32_looked_valid++;
/* then the image must be whole */
                if (!image_right())
                {
                    printf("ERROR: cut at %ld: header present, image wrong\n", (long)i64_at);
                    g_i32_errors++;
                }
            }
/* the install afterwards must give the image */
            g_i32_fm_reloads = 0;
            run_install(FM_NO_CUT, &i32_result);
            if ((i32_result != 0) || !image_right() || (g_i32_fm_reloads != RELOADS_WANTED))
            {
/* it did not */
                printf("ERROR: install after cut at %ld: r=%d right=%d\n", (long)i64_at, (int)i32_result, (int)image_right());
                g_i32_errors++;
            }
        }
    }
/* the summary */
    printf("%d cut-offs (%d left a valid image), %d errors\n", (int)i32_cuts, (int)i32_looked_valid, (int)g_i32_errors);
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
/* the flash stream exists only in the machine menu */
    g_b_fm_stream_on = false;
    if (argc >= ARGS_MIN)
    {
        g_ps_card = fopen(argv[ARG_CARD], "rb");
    }
/* no card image */
    if (g_ps_card == NULL)
    {
        printf("usage: c64rom_test card.img romdir [busy_us]\n");
        i32_exit = EXIT_USAGE;
    }
    else
    {
/* the pass-through's speed is optional */
        if (argc > ARG_BUSY)
        {
            g_ui32_fm_busy_us = (uint32_t)atoi(argv[ARG_BUSY]);
        }
        if (fat_mount() != FAT_OK)
        {
/* no file system */
            printf("ERROR: mount\n");
            i32_exit = EXIT_USAGE;
        }
    }
    if (i32_exit == EXIT_OK)
    {
/* the expected image: the header, then the four ROMs */
        memset(g_aui8_expect, ERASED, sizeof g_aui8_expect);
        g_aui8_expect[0] = HDR_MAGIC;
        memcpy(g_aui8_expect + HDR_SIGN_OFS, "L64 ROMS    ", HDR_SIGN_LEN);
/* its version; character ROM and BASIC */
        g_aui8_expect[HDR_VERSION_OFS] = HDR_VERSION;
        load(argv[ARG_ROMDIR], "char.bin", CHAR_OFS, CHAR_LEN);
        load(argv[ARG_ROMDIR], "basic.bin", BASIC_OFS, BASIC_LEN);
/* KERNAL and the 1541's ROM; the random sequence */
        load(argv[ARG_ROMDIR], "kernal.bin", KERNAL_OFS, KERNAL_LEN);
        load(argv[ARG_ROMDIR], "dos1541.bin", DOS_OFS, DOS_LEN);
        srand(SEED);
/* the tests */
        i64_full = test_hardware_state();
        test_cuts(i64_full);
        if (g_i32_errors != 0)
        {
/* errors give exit code 1 */
            printf("FAIL\n");
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
