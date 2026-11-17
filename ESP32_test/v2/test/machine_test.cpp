/* machine_test.cpp -- PC test of the machines in the flash (update.cpp: mch_*, with flash.cpp and */
/* fat.cpp as C++): the list of machine files, installing into the three positions, replacing, */
/* power cuts, and the menu-only LUPDATE.BIN. */
/* */
/* Runs against the flash model (flash_model.cpp). */
/* Usage: machine_test card.img FILES_DIR L_flash.bin */
/*   card.img     holds /MACHINES with the four machine files of the EP4CE15 board, OTHER.LMC (a file */
/*                for the other core board), DAMAGED.LMC (one image byte wrong), and LUPDATE.BIN */
/*   FILES_DIR    the same machine files on the PC (what the flash must hold afterwards) */
/*   L_flash.bin  the flash of L.jic: the menu, LSpectrum, L64 and LTari 800 in positions 1 to 3 */
/*   1. the list: four files for board 1, one for board 2 */
/*   2. menu-only flash: no machines; the three installs give exactly L.jic's flash */
/*   3. the same machine again: only the info sector is written */
/*   4. a machine without ROMs in its file (L64): the same machine's ROMs stay, another machine's go */
/*   5. a file for the other board and a damaged file: refused, flash untouched */
/*   6. installs cut off anywhere: a position never shows a machine that is not completely there */
/*   7. LUPDATE.BIN (the menu alone): the menu is rewritten, the machines stay */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
/* the cut-off jump; the registers and the platform */
#include <setjmp.h>
#include "../../../ESP32/v2/src/hw.h"
#include "../../../ESP32/v2/src/hal.h"
/* the card, the code under test */
#include "../../../ESP32/v2/src/fat.h"
#include "../../../ESP32/v2/src/update.h"
#include "../../../ESP32/v2/src/flash.h"
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
/* the flash: one megabyte, the positions' bitstreams and ROM areas */
#define MB 0x100000u
#define POS_IMAGE(p) (0x100000u + ((uint32_t)(p) * 0x200000u))
#define POS_ROM(p) (0x200000u + ((uint32_t)(p) * 0x200000u))
/* a machine file: header, info sector, the fields used here */
#define FILE_HDR 256u
#define FILE_INFO 4096u
#define OFF_IMG_LEN 12
#define OFF_ROM_LEN 20
/* the largest machine file */
#define FILE_MAX (FILE_HDR + (2u * MB))
/* the boards */
#define BOARD_EP4 1u
#define BOARD_C10 2u
/* files wanted in the lists */
#define FILES_EP4 6
#define FILES_C10 1
/* the user's ROMs of test 4: length, first byte, a multiplier for the rest */
#define USER_ROM_LEN 49152u
#define USER_ROM_FIRST 0xF3
#define USER_ROM_MUL 5
/* test 3: sectors a repeated install writes */
#define AGAIN_WRITTEN 1u
/* an erased byte */
#define ERASED 0xFF
/* the copy buffer for the card */
#define COPY_BUF 65536
/* cut-offs tried; rand() is 15 bits on Windows */
#define CUT_TRIES 60
#define RAND_BITS 15
/* a run that was cut off */
#define RUN_CUT (-200)
/* the menu byte changed in test 7 */
#define MENU_CHANGED_ADDR 0x01003u
#define MENU_CHANGED_XOR 0xFF
/* the random generator's seed */
#define SEED 1
/* the command line */
#define ARG_CARD 1
#define ARG_DIR 2
#define ARG_FLASH 3
#define ARGS_MIN 4
/* the program's results */
#define EXIT_OK 0
#define EXIT_ERRORS 1
#define EXIT_USAGE 2
/* a path on the PC */
#define PATH_BUF 512
/* little-endian fields */
#define BYTE1_SHIFT 8
#define BYTE2_SHIFT 16
#define BYTE3_SHIFT 24
/* one, two, three */
#define ONE 1
#define TWO 2
#define THREE 3

/* a machine file as the PC has it */
struct pcfile
{
/* the whole file */
    uint8_t aui8_data[FILE_MAX];
/* its parts' lengths */
    uint32_t ui32_rom_len;
    uint32_t ui32_img_len;
};

/* the flash of L.jic, and a copy of the flash to compare with later */
static uint8_t g_aui8_jic[FM_FLASH_SIZE];
static uint8_t g_aui8_keep[FM_FLASH_SIZE];
/* the copy buffer */
static uint8_t g_aui8_copy[COPY_BUF];
/* the machine files: LSpectrum, L64, LTari 800, LTari 130 */
static struct pcfile g_s_zx;
static struct pcfile g_s_c64;
static struct pcfile g_s_at800;
static struct pcfile g_s_at130;
/* the update file on the card */
static DIRENT g_s_upd_entry;
/* the card: the working copy, and the file it is copied from */
static FILE *g_ps_card;
static const char *g_pc_card_src;
/* where the machine files are on the PC */
static const char *g_pc_dir;
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

/* one more error, with its text */
static void error(const char *pc_text)
{
    printf("%s\n", pc_text);
    g_i32_errors++;
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

/* 32 bits, low byte first */
static uint32_t rd32(const uint8_t *pui8_src)
{
    uint32_t ui32_value;

    ui32_value = pui8_src[0] | ((uint32_t)pui8_src[ONE] << BYTE1_SHIFT) | ((uint32_t)pui8_src[TWO] << BYTE2_SHIFT) |
                 ((uint32_t)pui8_src[THREE] << BYTE3_SHIFT);
    return ui32_value;
}

/* a machine file from the PC; the test ends without it */
static void load_pcfile(struct pcfile *ps_file, const char *pc_name)
{
/* local variables */
    char ac_path[PATH_BUF];
    FILE *ps_src;

    snprintf(ac_path, sizeof ac_path, "%s/%s", g_pc_dir, pc_name);
    ps_src = fopen(ac_path, "rb");
    if (ps_src == NULL)
    {
        printf("ERROR: %s\n", ac_path);
        exit(EXIT_USAGE);
    }
/* the whole file, then the lengths of its parts */
    if (fread(ps_file->aui8_data, ONE, FILE_MAX, ps_src) < (FILE_HDR + FILE_INFO))
    {
        printf("ERROR: %s is too short\n", ac_path);
        exit(EXIT_USAGE);
    }
    fclose(ps_src);
    ps_file->ui32_img_len = rd32(ps_file->aui8_data + OFF_IMG_LEN);
    ps_file->ui32_rom_len = rd32(ps_file->aui8_data + OFF_ROM_LEN);
}

/* does a position hold this machine file completely: bitstream, info sector, ROM data? */
static bool position_is(int32_t i32_pos, const struct pcfile *ps_file)
{
/* local variables */
    const uint8_t *pui8_info;
    const uint8_t *pui8_rom;
    const uint8_t *pui8_img;
    bool b_is;

/* the parts in the file's order */
    pui8_info = ps_file->aui8_data + FILE_HDR;
    pui8_rom = pui8_info + FILE_INFO;
    pui8_img = pui8_rom + ps_file->ui32_rom_len;
    b_is = (memcmp(g_aui8_fm_flash + POS_IMAGE(i32_pos), pui8_img, ps_file->ui32_img_len) == 0) &&
           (memcmp(g_aui8_fm_flash + POS_ROM(i32_pos), pui8_info, FILE_INFO) == 0) &&
           (memcmp(g_aui8_fm_flash + POS_ROM(i32_pos) + MCH_ROM_OFFSET, pui8_rom, ps_file->ui32_rom_len) == 0);
    return b_is;
}

/* the list's entry whose file name starts with pc_name; the test ends without it */
static const MCH_FILE *find_file(uint32_t ui32_board, const char *pc_name)
{
/* local variables */
    const MCH_FILE *ps_files;
    const MCH_FILE *ps_hit;
    int32_t i32_count;
    int32_t i32_index;

/* start values */
    ps_files = NULL;
    ps_hit = NULL;
    i32_count = mch_list(ui32_board, &ps_files);
    for (i32_index = 0; i32_index < i32_count; i32_index++)
    {
        if (strncmp(ps_files[i32_index].s_entry.ac_name, pc_name, strlen(pc_name)) == 0)
        {
            ps_hit = &ps_files[i32_index];
        }
    }
/* it must be on the card */
    if (ps_hit == NULL)
    {
        printf("ERROR: %s is not in the list\n", pc_name);
        exit(EXIT_USAGE);
    }
    return ps_hit;
}

/* check and install one machine file, cut off after i64_cut_after register accesses (FM_NO_CUT: */
/* never): the result, or RUN_CUT */
static int32_t install(const char *pc_name, int32_t i32_pos, int64_t i64_cut_after, uint32_t *pui32_written)
{
/* local variables */
    DIRENT s_entry;
    int32_t i32_result;

/* start values */
    s_entry = find_file(BOARD_EP4, pc_name)->s_entry;
    i32_result = UPD_OK;
    g_i64_fm_accesses = 0;
    fm_link_idle();
    g_i64_fm_cut_at = i64_cut_after;
    if (setjmp(g_s_fm_cut) != 0)
    {
/* cut off: the model jumped here */
        i32_result = RUN_CUT;
    }
    else
    {
        i32_result = mch_check(&s_entry, BOARD_EP4, NULL);
        if (i32_result == UPD_OK)
        {
            i32_result = mch_install(&s_entry, i32_pos, NULL, pui32_written);
        }
    }
/* no cut-off any more */
    g_i64_fm_cut_at = FM_NO_CUT;
    return i32_result;
}

/* the flash of a board with the menu alone */
static void menu_only(void)
{
    memset(g_aui8_fm_flash, ERASED, FM_FLASH_SIZE);
    memcpy(g_aui8_fm_flash, g_aui8_jic, MB);
    fm_clock_restart();
}

/* 1: the lists */
static void test_list(void)
{
/* local variables */
    const MCH_FILE *ps_files;
    int32_t i32_ep4;
    int32_t i32_c10;
    int32_t i32_index;

/* start values */
    ps_files = NULL;
    i32_c10 = mch_list(BOARD_C10, &ps_files);
    i32_ep4 = mch_list(BOARD_EP4, &ps_files);
    printf("1. list: %d files for board 1, %d for board 2\n", (int)i32_ep4, (int)i32_c10);
    for (i32_index = 0; i32_index < i32_ep4; i32_index++)
    {
        printf("     %-24s %s\n", ps_files[i32_index].s_entry.ac_name, ps_files[i32_index].ac_line);
    }
/* the five machines and the damaged file (its header is good); the other board's one file */
    if ((i32_ep4 != FILES_EP4) || (i32_c10 != FILES_C10))
    {
        error("ERROR 1: file counts");
    }
}

/* 2: three installs on a board with the menu alone give L.jic's flash; returns the accesses of one */
static int64_t test_installs(void)
{
/* local variables */
    uint32_t ui32_written;
    int64_t i64_full;
    int32_t i32_r1;
    int32_t i32_r2;
    int32_t i32_r3;

/* start values */
    ui32_written = 0;
    i64_full = 0;
    menu_only();
    if (upd_machines_present() != 0)
    {
        error("ERROR 2: machines seen on a board with the menu alone");
    }
/* position 1 to 3 */
    i32_r1 = install("LSpectrum", 0, FM_NO_CUT, &ui32_written);
    i32_r2 = install("L64", ONE, FM_NO_CUT, &ui32_written);
    i32_r3 = install("LTari800", TWO, FM_NO_CUT, &ui32_written);
    i64_full = g_i64_fm_accesses;
    printf("2. installs: r=%d %d %d, the last one wrote %u sectors, %.1f s modelled for the three\n", (int)i32_r1,
           (int)i32_r2, (int)i32_r3, (unsigned)ui32_written, g_ui64_fm_now_us / (double)FM_US_PER_S);
/* the flash of L.jic, byte for byte; the machines are found by their tags */
    if ((i32_r1 != UPD_OK) || (i32_r2 != UPD_OK) || (i32_r3 != UPD_OK) ||
        (memcmp(g_aui8_fm_flash, g_aui8_jic, FM_FLASH_SIZE) != 0))
    {
        error("ERROR 2: the flash is not L.jic's");
    }
    if ((upd_machines_present() == 0) || (mch_find(MCH_BYTE_ZX) != 0) || (mch_find(MCH_BYTE_C64) != ONE) ||
        (mch_find(MCH_BYTE_ATARI) != TWO))
    {
        error("ERROR 2: machines not found in their positions");
    }
    return i64_full;
}

/* 3: the same machine into its position again */
static void test_again(void)
{
/* local variables */
    uint32_t ui32_written;
    int32_t i32_result;

    ui32_written = 0;
    i32_result = install("LSpectrum", 0, FM_NO_CUT, &ui32_written);
    printf("3. the same machine again: r=%d written=%u\n", (int)i32_result, (unsigned)ui32_written);
/* only the info sector, and the flash as before */
    if ((i32_result != UPD_OK) || (ui32_written != AGAIN_WRITTEN) ||
        (memcmp(g_aui8_fm_flash, g_aui8_jic, FM_FLASH_SIZE) != 0))
    {
        error("ERROR 3");
    }
}

/* 4: a machine whose ROMs are the user's */
static void test_user_roms(void)
{
/* local variables */
    uint8_t *pui8_rom;
    uint32_t ui32_written;
    uint32_t ui32_index;
    int32_t i32_result;

/* start values: the user's ROMs behind L64's info sector (position 2) */
    pui8_rom = g_aui8_fm_flash + POS_ROM(ONE) + MCH_ROM_OFFSET;
    ui32_written = 0;
    for (ui32_index = 0; ui32_index < USER_ROM_LEN; ui32_index++)
    {
        pui8_rom[ui32_index] = (uint8_t)(ui32_index * USER_ROM_MUL);
    }
    pui8_rom[0] = USER_ROM_FIRST;
    memcpy(g_aui8_keep, pui8_rom, USER_ROM_LEN);
/* L64 again: its ROMs stay */
    i32_result = install("L64", ONE, FM_NO_CUT, &ui32_written);
    if ((i32_result != UPD_OK) || !position_is(ONE, &g_s_c64) || (memcmp(pui8_rom, g_aui8_keep, USER_ROM_LEN) != 0))
    {
        error("ERROR 4: L64 over L64 lost the ROMs");
    }
/* another machine there: its own ROMs */
    i32_result = install("LTari130", ONE, FM_NO_CUT, &ui32_written);
    if ((i32_result != UPD_OK) || !position_is(ONE, &g_s_at130))
    {
        error("ERROR 4: LTari 130 into position 2");
    }
/* L64 back: the other machine's ROM image must not look like L64's */
    i32_result = install("L64", ONE, FM_NO_CUT, &ui32_written);
    if ((i32_result != UPD_OK) || !position_is(ONE, &g_s_c64) || (pui8_rom[0] != ERASED))
    {
        error("ERROR 4: L64 over another machine kept that machine's ROMs");
    }
    printf("4. the user's ROMs: checked\n");
}

/* 5: files that must be refused */
static void test_refused(void)
{
/* local variables */
    DIRENT s_entry;
    int32_t i32_other;
    int32_t i32_damaged;

    memcpy(g_aui8_keep, g_aui8_fm_flash, FM_FLASH_SIZE);
/* the other board's file, asked for as board 1 */
    s_entry = find_file(BOARD_C10, "OTHER")->s_entry;
    i32_other = mch_check(&s_entry, BOARD_EP4, NULL);
    s_entry = find_file(BOARD_EP4, "DAMAGED")->s_entry;
    i32_damaged = mch_check(&s_entry, BOARD_EP4, NULL);
    printf("5. refused: other board r=%d, damaged r=%d\n", (int)i32_other, (int)i32_damaged);
    if ((i32_other != MCH_EBOARD) || (i32_damaged != UPD_EBAD) ||
        (memcmp(g_aui8_keep, g_aui8_fm_flash, FM_FLASH_SIZE) != 0))
    {
        error("ERROR 5");
    }
}

/* 6: installs cut off anywhere */
static void test_cuts(int64_t i64_full)
{
/* local variables */
    char ac_line[MCH_LINE_BUF];
    uint8_t ui8_machine;
    uint32_t ui32_written;
    int64_t i64_cut;
    int32_t i32_try;
    int32_t i32_empty;
    int32_t i32_result;
    bool b_new;

/* start values */
    ui8_machine = 0;
    ui32_written = 0;
    i32_empty = 0;
/* position 3 changes between LTari 800 and LTari 130; each try starts where the last one ended */
    for (i32_try = 0; i32_try < CUT_TRIES; i32_try++)
    {
        b_new = (i32_try % TWO) == 0;
        i64_cut = (int64_t)((((uint64_t)rand() << RAND_BITS) | (uint64_t)rand()) % (uint64_t)i64_full);
        i32_result = install(b_new ? "LTari130" : "LTari800", TWO, i64_cut, &ui32_written);
/* cut: the position shows no machine, or one that is all there */
        g_i64_fm_cut_at = FM_NO_CUT;
        fm_link_idle();
        if (mch_position(TWO, ac_line, &ui8_machine) != MCH_PRESENT)
        {
            i32_empty++;
        }
        else if (!position_is(TWO, &g_s_at130) && !position_is(TWO, &g_s_at800))
        {
            printf("ERROR 6: cut at %ld (r=%d): the position shows \"%s\" but it is not complete\n", (long)i64_cut,
                   (int)i32_result, ac_line);
            g_i32_errors++;
        }
        else
        {
/* a whole machine */
        }
/* the install is done again, whole */
        i32_result = install(b_new ? "LTari130" : "LTari800", TWO, FM_NO_CUT, &ui32_written);
        if ((i32_result != UPD_OK) || !position_is(TWO, b_new ? &g_s_at130 : &g_s_at800))
        {
            printf("ERROR 6: the install after a cut at %ld failed (r=%d)\n", (long)i64_cut, (int)i32_result);
            g_i32_errors++;
        }
    }
/* the other positions never changed */
    if (!position_is(0, &g_s_zx) || !position_is(ONE, &g_s_c64))
    {
        error("ERROR 6: another position changed");
    }
    printf("6. %d installs cut off: %d left the position empty, none left a broken machine\n", (int)CUT_TRIES,
           (int)i32_empty);
}

/* 7: LUPDATE.BIN, the menu alone */
static void test_menu_update(void)
{
/* local variables */
    uint32_t ui32_written;
    int32_t i32_menu_changed;
    int32_t i32_result;

/* start values */
    ui32_written = 0;
    i32_menu_changed = 0;
    i32_result = UPD_EBAD;
/* one byte of the menu is wrong */
    memcpy(g_aui8_keep, g_aui8_fm_flash, FM_FLASH_SIZE);
    g_aui8_fm_flash[MENU_CHANGED_ADDR] ^= MENU_CHANGED_XOR;
    if (upd_find(&g_s_upd_entry) > 0)
    {
        i32_result = upd_check(&g_s_upd_entry, NULL);
        if (i32_result == UPD_OK)
        {
            i32_result = upd_run(&g_s_upd_entry, NULL, &i32_menu_changed, &ui32_written);
        }
    }
    printf("7. LUPDATE.BIN: r=%d written=%u menu_changed=%d\n", (int)i32_result, (unsigned)ui32_written,
           (int)i32_menu_changed);
/* the menu as before, nothing else touched, the file gone */
    if ((i32_result != UPD_OK) || (ui32_written != ONE) || (i32_menu_changed == 0) ||
        (memcmp(g_aui8_keep, g_aui8_fm_flash, FM_FLASH_SIZE) != 0) || (upd_find(&g_s_upd_entry) > 0))
    {
        error("ERROR 7");
    }
}

/* the test program */
int main(int argc, char **argv)
{
/* local variables */
    FILE *ps_flash;
    int64_t i64_full;
    int32_t i32_exit;

/* start values; output without buffering */
    ps_flash = NULL;
    i64_full = 0;
    i32_exit = EXIT_OK;
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc < ARGS_MIN)
    {
        printf("usage: machine_test card.img FILES_DIR L_flash.bin\n");
        i32_exit = EXIT_USAGE;
    }
    else
    {
        ps_flash = fopen(argv[ARG_FLASH], "rb");
    }
/* L.jic's flash must be readable */
    if ((i32_exit == EXIT_OK) && ((ps_flash == NULL) || (fread(g_aui8_jic, ONE, FM_FLASH_SIZE, ps_flash) != FM_FLASH_SIZE)))
    {
        printf("ERROR: %s\n", argv[ARG_FLASH]);
        i32_exit = EXIT_USAGE;
    }
    if (ps_flash != NULL)
    {
        fclose(ps_flash);
    }
    if (i32_exit == EXIT_OK)
    {
/* the card and the files */
        g_pc_card_src = argv[ARG_CARD];
        g_pc_dir = argv[ARG_DIR];
        srand(SEED);
        load_pcfile(&g_s_zx, "LSpectrum_ep4ce15.LMC");
        load_pcfile(&g_s_c64, "L64_ep4ce15.LMC");
        load_pcfile(&g_s_at800, "LTari800_ep4ce15.LMC");
        load_pcfile(&g_s_at130, "LTari130_ep4ce15.LMC");
        fresh_card();
/* the tests */
        test_list();
        i64_full = test_installs();
        test_again();
        test_user_roms();
        test_refused();
/* the cut-offs work on position 3 */
        test_cuts(i64_full);
        test_menu_update();
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
            printf("PASS\n");
        }
    }
    return i32_exit;
}
