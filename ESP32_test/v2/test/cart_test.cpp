/* cart_test.cpp -- PC test of the cartridge loaders (cart.cpp, nes.cpp, md.cpp, compiled as C++) */
/* */
/* The FPGA is a small model here: the memory commands of the snapshot port with the page */
/* field of MCTL (LNES: bits 30:27, LMega: bits 26:22), an 8 MB memory, the "cartridge RAM */
/* written" bit, the timer. The card is a FAT image made by the run script (tools/mkimg.py) from */
/* the files of mkcart.py; it is written, because the battery RAM files are created on it. */
/* Usage: cart_test card.img tree    (tree = the folder with the same files) */
/*   LNES:  T1.NES into the memory (program, pictures, cartridge word); its battery RAM goes to a */
/*          .SAV file after the game "wrote" it and comes back at the next load; T2.NES (picture RAM); */
/*          T5.NES and BAD.NES are refused and the running game stays */
/*   LMega: G1.MD into the memory, region and battery RAM from its header, the .SAV file; G1.SMD */
/*          gives the same memory; EU.MD and JP.BIN select their regions */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
/* the registers and the platform */
#include "../../../ESP32/v2/src/hw.h"
#include "../../../ESP32/v2/src/hal.h"
/* the code under test */
#include "../../../ESP32/v2/src/fat.h"
#include "../../../ESP32/v2/src/nes.h"
#include "../../../ESP32/v2/src/md.h"

/* hw.h: main is the ESP32 loader task */
#undef main

/* bytes of one card sector */
#define SECTOR_SIZE 512
/* results of the card functions */
#define SD_OK 0
#define SD_ERROR (-1)
/* what fifo_free always answers: the whole FIFO */
#define FIFO_ROOM 512
/* yes, one */
#define YES 1
#define ONE 1
/* the modelled memory: 8 MB */
#define MEM_LEN 0x800000u
#define MEM_MASK 0x7FFFFFu
/* registers (rtl/tape_loader.v) */
#define R_TIMER 0x18
#define R_SNAPCTL 0x2C
#define R_SNAPCMD 0x30
/* the data register, the two machine registers */
#define R_SNAPDAT 0x34
#define R_MCTL 0x48
#define R_MCLR 0x4C
/* a memory command: its number's place, read, write, the address inside a page */
#define CMD_SHIFT 28
#define C_MRD 1u
#define C_MWR 2u
/* a page: 256 KB */
#define PAGE_SHIFT 18
#define PAGE_ADDR_MASK 0x3FFFFu
/* the page fields of the two machines */
#define NES_PAGE_LSB 27
#define NES_PAGE_MASK 0xFu
#define MD_PAGE_LSB 22
/* its width */
#define MD_PAGE_MASK 0x1Fu
/* the bit "cartridge RAM written" */
#define ST_WRITTEN 1u
/* LNES: where things are, the cartridge word's bits */
#define NES_WRAM 0x002000u
#define NES_CHR 0x100000u
#define NES_PRG 0x200000u
/* the cartridge RAM's length, the file header's */
#define NES_WRAM_LEN 8192u
#define NES_HDR 16u
#define NES_RUN 0x80000000u
/* T1: its sizes and its cartridge word */
#define NES_T1_PRG 32768u
#define NES_T1_CHR 8192u
#define NES_T1_WORD 0x80038301u
/* T2: its size and its cartridge word */
#define NES_T2_PRG 65536u
#define NES_T2_WORD 0x85038702u
#define NES_T5_MAPPER 5u
/* LMega: where things are, the cartridge word's bits */
#define MD_SRAM 0x420000u
#define MD_SRAM_LEN 0x4000u
#define MD_ROM_LEN 0x40000u
/* the cartridge words of the three regions */
#define MD_WORD_US 0x80000006u
#define MD_WORD_EU 0x80000003u
#define MD_WORD_JP 0x80000000u
/* battery RAM without a file */
#define MD_EMPTY 0xFFu
/* the largest test file, a name buffer */
#define FILE_MAX 0x50000u
#define PATH_LEN 300
/* bytes changed in the battery RAM, and their values */
#define MARK_AT 5u
#define MARK_VALUE 0xABu
#define MARK2_AT 0x1234u
/* the second mark */
#define MARK2_VALUE 0x5Au
/* time steps: longer than the quiet time before a save */
#define STEP_MS 2000u
/* the 8.3 name's extension place */
#define EXT_AT 8
#define EXT_LEN 3
/* the command line: the tree's folder is the second argument */
#define ARG_TREE 2

/* the modelled memory and a file of the tree */
static uint8_t *g_pui8_mem;
static uint8_t g_aui8_file[FILE_MAX];
/* the name looked for and what was found */
static char g_ac_want[NAME_BUF_LEN];
static DIRENT g_s_found;
static int32_t g_i32_found;
/* the card image, the tree's folder */
static FILE *g_ps_card;
static const char *g_pc_tree;
/* the registers: MCTL, the data register, the page field in use, the written bit, the timer */
static uint32_t g_ui32_mctl;
static uint32_t g_ui32_dat;
static uint32_t g_ui32_page_lsb;
/* its width */
static uint32_t g_ui32_page_mask;
static uint32_t g_ui32_written;
static uint32_t g_ui32_timer;
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

/* write one sector of the card */
int32_t sd_write(uint32_t ui32_lba, const uint8_t *pui8_buf)
{
    int32_t i32_result;

    i32_result = SD_ERROR;
/* seek, then write */
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
    return YES;
}

/* a register is read */
uint32_t hw_rd(uint8_t ui8_reg)
{
    uint32_t ui32_value;

    ui32_value = 0;
/* the data of the last command, the written bit, the timer; SNAPCTL: never busy */
    if (ui8_reg == R_SNAPDAT)
    {
        ui32_value = g_ui32_dat;
    }
    else if (ui8_reg == R_MCTL)
    {
/* MSTAT: the written bit */
        ui32_value = g_ui32_written;
    }
    else if (ui8_reg == R_TIMER)
    {
        ui32_value = g_ui32_timer;
    }
    else
    {
/* everything else reads 0 */
    }
    return ui32_value;
}

/* a register is written */
void hw_wr(uint8_t ui8_reg, uint32_t ui32_value)
{
    uint32_t ui32_addr;

    ui32_addr = 0;
/* the data register */
    if (ui8_reg == R_SNAPDAT)
    {
        g_ui32_dat = ui32_value;
    }
    else if (ui8_reg == R_MCTL)
    {
/* the cartridge word */
        g_ui32_mctl = ui32_value;
    }
/* the written bit is cleared */
    else if (ui8_reg == R_MCLR)
    {
        if ((ui32_value & ST_WRITTEN) != 0)
        {
            g_ui32_written = 0;
        }
    }
/* a memory command */
    else if (ui8_reg == R_SNAPCMD)
    {
/* a memory command: the page from MCTL, the rest from the command */
        ui32_addr = (((g_ui32_mctl >> g_ui32_page_lsb) & g_ui32_page_mask) << PAGE_SHIFT) | (ui32_value & PAGE_ADDR_MASK);
        ui32_addr &= MEM_MASK;
        if ((ui32_value >> CMD_SHIFT) == C_MRD)
        {
/* the byte read */
            g_ui32_dat = g_pui8_mem[ui32_addr];
        }
/* a write */
        if ((ui32_value >> CMD_SHIFT) == C_MWR)
        {
            g_pui8_mem[ui32_addr] = (uint8_t)g_ui32_dat;
        }
    }
    else
    {
/* other registers are not modelled */
    }
}

/* one check: said when it fails */
static void check(bool b_ok, const char *pc_what)
{
    if (!b_ok)
    {
        printf("  ERROR: %s\n", pc_what);
/* one more error */
        g_i32_errors++;
    }
}

/* directory scan: the entry with the wanted name, or (name ".SAV") the first .SAV file */
static int32_t find_cb(const DIRENT *ps_entry, void *p_ctx)
{
    int32_t i32_stop;
    bool b_match;

/* not found yet */
    i32_stop = 0;
    (void)p_ctx;
    b_match = strcmp(ps_entry->ac_name, g_ac_want) == 0;
/* any .SAV file */
    if ((strcmp(g_ac_want, ".SAV") == 0) && (memcmp(ps_entry->ac_sname + EXT_AT, "SAV", EXT_LEN) == 0))
    {
        b_match = true;
    }
    if (b_match)
    {
/* kept for the caller */
        memcpy(&g_s_found, ps_entry, sizeof g_s_found);
        g_i32_found = YES;
        i32_stop = YES;
    }
/* non-zero stops the scan */
    return i32_stop;
}

/* look for a file in the card's root folder */
static bool find(const char *pc_name)
{
    strncpy(g_ac_want, pc_name, NAME_MAX);
    g_i32_found = 0;
/* the scan */
    fat_list(0, find_cb, NULL);
    return g_i32_found != 0;
}

/* a file of the tree into g_aui8_file: its length */
static uint32_t tree_file(const char *pc_name)
{
    char ac_path[PATH_LEN];
    FILE *ps_file;
/* its length */
    uint32_t ui32_len;

    ui32_len = 0;
    snprintf(ac_path, sizeof ac_path, "%s/%s", g_pc_tree, pc_name);
/* the file */
    ps_file = fopen(ac_path, "rb");
/* read whole */
    if (ps_file != NULL)
    {
        ui32_len = (uint32_t)fread(g_aui8_file, ONE, FILE_MAX, ps_file);
        fclose(ps_file);
    }
/* 0 if it is not there */
    return ui32_len;
}

/* the first .SAV file of the card: its length must be ui32_len and its byte ui32_at ui8_value */
static void check_sav(uint32_t ui32_len, uint32_t ui32_at, uint8_t ui8_value, const char *pc_what)
{
    FFILE s_file;
    uint32_t ui32_index;
/* a character of the file */
    int32_t i32_char;

    i32_char = 0;
    if (!find(".SAV"))
    {
/* no .SAV file at all */
        check(false, pc_what);
    }
    else
    {
        check(g_s_found.ui32_size == ui32_len, pc_what);
        ff_open(&s_file, g_s_found.ui32_clus, g_s_found.ui32_size);
/* up to the byte that was changed */
        for (ui32_index = 0; ui32_index <= ui32_at; ui32_index++)
        {
            i32_char = ff_getc(&s_file);
        }
        check(i32_char == (int32_t)ui8_value, pc_what);
/* the file goes away again: the next machine's test starts without one */
        fat_delete(0, g_s_found.ac_sname);
    }
}

/* the game "writes" a byte of its battery RAM, time passes, the service saves it */
static void game_writes(uint32_t ui32_addr, uint8_t ui8_value, bool b_nes)
{
    g_pui8_mem[ui32_addr] = ui8_value;
    g_ui32_written = ST_WRITTEN;
/* seen by the first call, saved by the second one after the quiet time */
    if (b_nes)
    {
        nes_service();
    }
    else
    {
        md_service();
    }
/* time passes */
    g_ui32_timer += STEP_MS * CLK_PER_MS;
    if (b_nes)
    {
        nes_service();
    }
    else
    {
/* the second call */
        md_service();
    }
}

/* LNES */
static void test_nes(void)
{
    FFILE s_file;
    uint32_t ui32_mapper;
/* a file's length */
    uint32_t ui32_len;
    int32_t i32_result;

    ui32_mapper = 0;
/* the page field of this machine */
    g_ui32_page_lsb = NES_PAGE_LSB;
    g_ui32_page_mask = NES_PAGE_MASK;
/* T1: mapper 1, program, pictures, battery */
    ui32_len = tree_file("T1.NES");
    check(find("T1.NES") && (ui32_len == (NES_HDR + NES_T1_PRG + NES_T1_CHR)), "T1.NES on the card");
    ff_open(&s_file, g_s_found.ui32_clus, g_s_found.ui32_size);
/* the cartridge RAM holds something else before */
    memset(g_pui8_mem + NES_WRAM, MARK_VALUE, NES_WRAM_LEN);
    i32_result = nes_load(&s_file, "T1.NES", 0, &ui32_mapper);
    check(i32_result == NES_OK, "T1.NES loads");
/* what must be in the memory now */
    check(memcmp(g_pui8_mem + NES_PRG, g_aui8_file + NES_HDR, NES_T1_PRG) == 0, "T1 program data");
    check(memcmp(g_pui8_mem + NES_CHR, g_aui8_file + NES_HDR + NES_T1_PRG, NES_T1_CHR) == 0, "T1 picture data");
    check(g_ui32_mctl == NES_T1_WORD, "T1 cartridge word");
/* no file yet */
    check(g_pui8_mem[NES_WRAM] == 0, "T1 battery RAM starts as zeros");
/* the game writes its battery RAM: a .SAV file with that byte */
    game_writes(NES_WRAM + MARK_AT, MARK_VALUE, true);
    check(find(".SAV"), "T1 .SAV file written");
/* the next load brings it back */
    memset(g_pui8_mem + NES_WRAM, 0, NES_WRAM_LEN);
    find("T1.NES");
    ff_open(&s_file, g_s_found.ui32_clus, g_s_found.ui32_size);
/* loaded again */
    i32_result = nes_load(&s_file, "T1.NES", 0, &ui32_mapper);
    check((i32_result == NES_OK) && (g_pui8_mem[NES_WRAM + MARK_AT] == MARK_VALUE), "T1 battery RAM comes back");
    check_sav(NES_WRAM_LEN, MARK_AT, MARK_VALUE, "T1 .SAV contents");
/* files the core cannot take: refused, the game stays */
    find("T5.NES");
    ff_open(&s_file, g_s_found.ui32_clus, g_s_found.ui32_size);
    i32_result = nes_load(&s_file, "T5.NES", 0, &ui32_mapper);
/* its mapper number comes back */
    check((i32_result == NES_EMAPPER) && (ui32_mapper == NES_T5_MAPPER), "T5.NES refused with its mapper");
    find("BAD.NES");
    ff_open(&s_file, g_s_found.ui32_clus, g_s_found.ui32_size);
/* not a cartridge file */
    i32_result = nes_load(&s_file, "BAD.NES", 0, &ui32_mapper);
    check((i32_result == NES_EBAD) && (g_ui32_mctl == NES_T1_WORD), "BAD.NES refused, T1 still runs");
/* T2: picture RAM, no battery */
    ui32_len = tree_file("T2.NES");
    find("T2.NES");
    ff_open(&s_file, g_s_found.ui32_clus, g_s_found.ui32_size);
/* the picture memory holds something else before */
    memset(g_pui8_mem + NES_CHR, MARK_VALUE, NES_WRAM_LEN);
    i32_result = nes_load(&s_file, "T2.NES", 0, &ui32_mapper);
    check((i32_result == NES_OK) && (ui32_len == (NES_HDR + NES_T2_PRG)), "T2.NES loads");
/* its program data */
    check(memcmp(g_pui8_mem + NES_PRG, g_aui8_file + NES_HDR, NES_T2_PRG) == 0, "T2 program data");
    check((g_pui8_mem[NES_CHR] == 0) && (g_pui8_mem[NES_CHR + NES_WRAM_LEN - ONE] == 0), "T2 picture RAM empty");
    check(g_ui32_mctl == NES_T2_WORD, "T2 cartridge word");
/* no battery: nothing is saved */
    game_writes(NES_WRAM + MARK_AT, MARK_VALUE, true);
    check(!find(".SAV"), "T2 writes no .SAV file");
    nes_reset();
/* the verdict so far */
    printf("LNES: %s\n", (g_i32_errors == 0) ? "ok" : "ERRORS");
}

/* LMega */
static void test_md(void)
{
    FFILE s_file;
    uint32_t ui32_len;
/* a result, the errors before this part */
    int32_t i32_result;
    int32_t i32_before;

    i32_before = g_i32_errors;
/* the page field of this machine */
    g_ui32_page_lsb = MD_PAGE_LSB;
    g_ui32_page_mask = MD_PAGE_MASK;
    g_ui32_written = 0;
/* G1: the ROM, the region, the battery RAM */
    ui32_len = tree_file("G1.MD");
    check(find("G1.MD") && (ui32_len == MD_ROM_LEN), "G1.MD on the card");
    ff_open(&s_file, g_s_found.ui32_clus, g_s_found.ui32_size);
/* loaded */
    i32_result = md_load(&s_file, "G1.MD", 0);
    check(i32_result == MD_OK, "G1.MD loads");
    check(memcmp(g_pui8_mem, g_aui8_file, MD_ROM_LEN) == 0, "G1 ROM data");
/* its word */
    check(g_ui32_mctl == MD_WORD_US, "G1 cartridge word (America, battery RAM)");
    check((g_pui8_mem[MD_SRAM] == MD_EMPTY) && (g_pui8_mem[MD_SRAM + MD_SRAM_LEN - ONE] == MD_EMPTY), "G1 battery RAM starts as ones");
/* the game writes: a .SAV file; the next load brings it back */
    game_writes(MD_SRAM + MARK2_AT, MARK2_VALUE, false);
    check(find(".SAV"), "G1 .SAV file written");
    memset(g_pui8_mem + MD_SRAM, 0, MD_SRAM_LEN);
/* the ROM area too */
    memset(g_pui8_mem, 0, MD_ROM_LEN);
/* the same game as an .smd file */
    find("G1.SMD");
    ff_open(&s_file, g_s_found.ui32_clus, g_s_found.ui32_size);
    i32_result = md_load(&s_file, "G1.MD", 0);
/* the same bytes as the plain file */
    check((i32_result == MD_OK) && (memcmp(g_pui8_mem, g_aui8_file, MD_ROM_LEN) == 0), "G1.SMD gives the same ROM data");
    check(g_pui8_mem[MD_SRAM + MARK2_AT] == MARK2_VALUE, "G1 battery RAM comes back");
    check_sav(MD_SRAM_LEN, MARK2_AT, MARK2_VALUE, "G1 .SAV contents");
/* the other regions */
    find("EU.MD");
    ff_open(&s_file, g_s_found.ui32_clus, g_s_found.ui32_size);
    i32_result = md_load(&s_file, "EU.MD", 0);
/* Europe */
    check((i32_result == MD_OK) && (g_ui32_mctl == MD_WORD_EU), "EU.MD: a 50 Hz console");
    find("JP.BIN");
    ff_open(&s_file, g_s_found.ui32_clus, g_s_found.ui32_size);
/* Japan */
    i32_result = md_load(&s_file, "JP.BIN", 0);
    check((i32_result == MD_OK) && (g_ui32_mctl == MD_WORD_JP), "JP.BIN: a Japanese console");
/* too short for a cartridge */
    find("BAD.NES");
    g_s_found.ui32_size = SECTOR_SIZE - ONE;
    ff_open(&s_file, g_s_found.ui32_clus, g_s_found.ui32_size);
/* a file of 511 bytes */
    i32_result = md_load(&s_file, "BAD", 0);
    check((i32_result == MD_EBAD) && (g_ui32_mctl == MD_WORD_JP), "a short file is refused, the game stays");
    md_reset();
/* the verdict of this part */
    printf("LMega: %s\n", (g_i32_errors == i32_before) ? "ok" : "ERRORS");
}

/* the test */
int main(int argc, char **argv)
{
    int32_t i32_result;

    i32_result = EXIT_FAILURE;
/* the modelled memory */
    g_pui8_mem = (uint8_t *)calloc(MEM_LEN, ONE);
    if ((argc > ARG_TREE) && (g_pui8_mem != NULL))
    {
        g_ps_card = fopen(argv[ONE], "r+b");
/* the folder with the files */
        g_pc_tree = argv[ARG_TREE];
    }
/* the card */
    if ((g_ps_card == NULL) || (fat_mount() != FAT_OK))
    {
        printf("usage: cart_test card.img tree\n");
    }
    else
    {
        test_nes();
/* the second machine */
        test_md();
        fclose(g_ps_card);
/* the verdict */
        if (g_i32_errors == 0)
        {
            i32_result = EXIT_SUCCESS;
        }
    }
    return i32_result;
}
