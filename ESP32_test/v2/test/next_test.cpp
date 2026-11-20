/* next_test.cpp -- PC test of LNext's sector server (next.cpp, compiled as C++) */
/* */
/* The FPGA is a small model here (LNext/10cl025/rtl/next_sd.v as the firmware sees it): the */
/* machine word with the request and its sector, the "card is in" and "buffer is mine" bits, the */
/* card's size register and the sector buffer behind the memory commands. The card is 64 sectors */
/* of a pattern in memory. A script of requests plays the machine: */
/*   reads:  the buffer must hold the card's sector when the firmware gives it back */
/*   writes: the card must hold the buffer's bytes afterwards */
/*   a request word that changes between two readings (the FPGA's other clock) */
/*   an FPGA that is gone (all ones) and a sector outside the card: nothing may be written */
/*   no card: the machine stays in reset */
/* With a card image as the argument (FAT32 with a folder ZXNEXT, made by run_host_test.sh) the */
/* second part plays a machine that reads the card's root directory: */
/*   it must see the folder's files (TBBLUE.FW) and not the card's real root (OUTSIDE.TXT), */
/*   and no "." or ".." entry */
/*   a directory sector and a boot sector it writes back leave the card's folder entries and the */
/*   card's real root directory as they were */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
/* the registers and the platform */
#include "../../../ESP32/v2/src/hw.h"
#include "../../../ESP32/v2/src/hal.h"
/* the code under test */
#include "../../../ESP32/v2/src/next.h"

/* hw.h: main is the ESP32 loader task */
#undef main

/* a sector's bytes, the card's sectors */
#define SECTOR 512u
#define CARD_SECTORS 64u
/* registers (rtl/tape_loader.v) */
#define R_SNAPCTL 0x2C
#define R_SNAPCMD 0x30
#define R_SNAPDAT 0x34
#define R_MCTL 0x48
#define R_MCLR 0x4C
/* a memory command: its number's place, read, write, the address in the buffer */
#define CMD_SHIFT 28
#define C_MRD 1u
#define C_MWR 2u
#define ADDR_MASK 0x1FFu
/* the machine word as read and as written */
#define ST_WRITE 0x80000000u
#define ST_READ 0x40000000u
#define MC_ACK 1u
#define MC_IN 2u
/* an FPGA that is gone */
#define ALL_ONES 0xFFFFFFFFu
/* the pattern of the card and of a written sector */
#define CARD_MUL 7u
#define CARD_ADD 3u
#define WRITE_MUL 13u
#define WRITE_ADD 5u
#define BYTE_MASK 0xFFu
/* the script: sectors read, sectors written */
#define READS 5
#define WRITES 3
/* yes */
#define YES 1
/* the card image: the argument's place, the largest image */
#define ARG_IMAGE 1
#define ARGS_WITH_IMAGE 2
#define IMAGE_MAX_SECTORS 262144u
/* the first partition's first sector in the card's first sector */
#define PART_START 454u
/* boot sector fields: sectors per cluster, reserved sectors, FATs, FAT size, root cluster, the copy */
#define BS_CLUSTER 13u
#define BS_RESERVED 14u
#define BS_FATS 16u
#define BS_FAT32 36u
#define BS_ROOT 44u
#define BS_COPY 50u
/* a directory entry: size, name length, attribute byte, a long name's attribute, a folder */
#define ENTRY 32u
#define NAME_LEN 11u
#define E_ATTR 11u
#define A_LONG 0x0Fu
#define A_DIR 0x10u
#define E_DELETED 0xE5u
#define E_DOT 0x2Eu
/* the first cluster with data */
#define CLUS_FIRST 2u
/* bytes of a number */
#define SHIFT_8 8
#define SHIFT_16 16
#define SHIFT_24 24
#define BYTE_1 1u
#define BYTE_2 2u
#define BYTE_3 3u
/* the second entry of a sector */
#define SECOND 1u

/* the card */
static uint8_t g_aui8_pattern[CARD_SECTORS][SECTOR];
static uint8_t *g_pui8_card;
static uint32_t g_ui32_card_sectors;
static int32_t g_i32_card_writes;
static uint32_t g_ui32_last_write;
/* the model: registers, the buffer, the request, a reading that shows another sector once */
static uint32_t g_ui32_mctl;
static uint32_t g_ui32_size;
static uint32_t g_ui32_dat;
static uint8_t g_aui8_buf[SECTOR];
static uint32_t g_ui32_request;
static int32_t g_i32_torn;
/* requests served (the firmware gave the buffer back) */
static int32_t g_i32_served;
/* errors found */
static int32_t g_i32_errors;

/* a byte of the card's pattern */
static uint8_t card_byte(uint32_t ui32_lba, uint32_t ui32_index)
{
    return (uint8_t)(((ui32_lba * CARD_MUL) + ui32_index + CARD_ADD) & BYTE_MASK);
}

/* a byte of a sector the machine writes */
static uint8_t write_byte(uint32_t ui32_lba, uint32_t ui32_index)
{
    return (uint8_t)(((ui32_lba * WRITE_MUL) + (ui32_index * WRITE_ADD)) & BYTE_MASK);
}

/* an error is counted and said */
static void error(const char *pc_text, uint32_t ui32_value)
{
    printf("ERROR: %s (%lu)\n", pc_text, (unsigned long)ui32_value);
    g_i32_errors++;
}

/* hal.h: the card */
int32_t sd_read(uint32_t ui32_lba, uint8_t *pui8_buf)
{
/* local variables */
    int32_t i32_result;

/* start values */
    i32_result = -YES;
    if (ui32_lba < g_ui32_card_sectors)
    {
        memcpy(pui8_buf, g_pui8_card + (ui32_lba * SECTOR), SECTOR);
        i32_result = 0;
    }
    return i32_result;
}

int32_t sd_write(uint32_t ui32_lba, const uint8_t *pui8_buf)
{
/* local variables */
    int32_t i32_result;

/* start values */
    i32_result = -YES;
    g_i32_card_writes++;
    g_ui32_last_write = ui32_lba;
    if (ui32_lba < g_ui32_card_sectors)
    {
        memcpy(g_pui8_card + (ui32_lba * SECTOR), pui8_buf, SECTOR);
        i32_result = 0;
    }
    return i32_result;
}

uint32_t sd_sectors(void)
{
    return g_ui32_card_sectors;
}

/* hal.h: the pulse FIFO is not used here */
uint32_t fifo_free(void)
{
    return 0;
}

void fifo_push(uint32_t ui32_cmd)
{
    (void)ui32_cmd;
}

/* hw.h: a register is read */
uint32_t hw_rd(uint8_t ui8_reg)
{
/* local variables */
    uint32_t ui32_value;

/* start values */
    ui32_value = 0;
    if (ui8_reg == R_MCTL)
    {
        ui32_value = g_ui32_request;
/* once, a reading taken while the word changed */
        if (g_i32_torn != 0)
        {
            g_i32_torn = 0;
            ui32_value ^= YES;
        }
    }
    else if (ui8_reg == R_SNAPDAT)
    {
        ui32_value = g_ui32_dat;
    }
    else
    {
/* SNAPCTL: never busy; nothing else is read */
    }
    return ui32_value;
}

/* hw.h: a register is written */
void hw_wr(uint8_t ui8_reg, uint32_t ui32_value)
{
/* local variables */
    uint32_t ui32_cmd;
    uint32_t ui32_addr;

/* start values */
    ui32_cmd = ui32_value >> CMD_SHIFT;
    ui32_addr = ui32_value & ADDR_MASK;
    if (ui8_reg == R_MCLR)
    {
        g_ui32_size = ui32_value;
    }
    else if (ui8_reg == R_SNAPDAT)
    {
        g_ui32_dat = ui32_value;
    }
    else if (ui8_reg == R_SNAPCMD)
    {
/* the buffer's bytes; writes count only while the buffer is the firmware's */
        if (ui32_cmd == C_MRD)
        {
            g_ui32_dat = g_aui8_buf[ui32_addr];
        }
        else if (ui32_cmd == C_MWR)
        {
            if ((g_ui32_mctl & MC_ACK) != 0)
            {
                g_aui8_buf[ui32_addr] = (uint8_t)g_ui32_dat;
            }
            else
            {
                error("buffer written without the acknowledge", ui32_addr);
            }
        }
        else
        {
/* other commands do nothing */
        }
    }
    else if (ui8_reg == R_MCTL)
    {
/* the buffer is given back: the request is done */
        if (((g_ui32_mctl & MC_ACK) != 0) && ((ui32_value & MC_ACK) == 0))
        {
            g_ui32_request = 0;
            g_i32_served++;
        }
        g_ui32_mctl = ui32_value;
    }
    else
    {
/* nothing else is written */
    }
}

/* the machine reads a sector */
static void test_read(uint32_t ui32_lba)
{
/* local variables */
    uint32_t ui32_index;
    int32_t i32_before;

/* start values */
    i32_before = g_i32_served;
    memset(g_aui8_buf, 0, SECTOR);
    g_ui32_request = ST_READ | ui32_lba;
    next_service();
    if (g_i32_served != (i32_before + YES))
    {
        error("read request not served", ui32_lba);
    }
    for (ui32_index = 0; ui32_index < SECTOR; ui32_index++)
    {
        if (g_aui8_buf[ui32_index] != card_byte(ui32_lba, ui32_index))
        {
            error("read: wrong byte in the buffer", ui32_index);
            ui32_index = SECTOR;
        }
    }
}

/* the machine writes a sector */
static void test_write(uint32_t ui32_lba)
{
/* local variables */
    uint32_t ui32_index;
    int32_t i32_before;

/* start values */
    i32_before = g_i32_served;
    for (ui32_index = 0; ui32_index < SECTOR; ui32_index++)
    {
        g_aui8_buf[ui32_index] = write_byte(ui32_lba, ui32_index);
    }
    g_ui32_request = ST_WRITE | ui32_lba;
    next_service();
    if (g_i32_served != (i32_before + YES))
    {
        error("write request not served", ui32_lba);
    }
    for (ui32_index = 0; ui32_index < SECTOR; ui32_index++)
    {
        if (g_pui8_card[(ui32_lba * SECTOR) + ui32_index] != write_byte(ui32_lba, ui32_index))
        {
            error("write: wrong byte on the card", ui32_index);
            ui32_index = SECTOR;
        }
    }
}

/* a 16-bit and a 32-bit number, low byte first */
static uint32_t rd16(const uint8_t *pui8_src)
{
    return (uint32_t)pui8_src[0] | ((uint32_t)pui8_src[BYTE_1] << SHIFT_8);
}

static uint32_t rd32(const uint8_t *pui8_src)
{
    return rd16(pui8_src) | ((uint32_t)pui8_src[BYTE_2] << SHIFT_16) | ((uint32_t)pui8_src[BYTE_3] << SHIFT_24);
}

/* the machine reads a sector of the image into the buffer */
static void machine_read(uint32_t ui32_lba)
{
    memset(g_aui8_buf, 0, SECTOR);
    g_ui32_request = ST_READ | ui32_lba;
    next_service();
}

/* the machine writes the buffer to a sector of the image */
static void machine_write(uint32_t ui32_lba)
{
    g_ui32_request = ST_WRITE | ui32_lba;
    next_service();
}

/* 1 = the buffer (a directory sector as the machine sees it) has a file with this 8.3 name */
static int32_t machine_has(const char *pc_name)
{
/* local variables */
    uint32_t ui32_offset;
    int32_t i32_found;

/* start values */
    i32_found = 0;
    for (ui32_offset = 0; ui32_offset < SECTOR; ui32_offset += ENTRY)
    {
/* parts of long names and deleted entries are skipped, as every FAT reader does */
        if ((g_aui8_buf[ui32_offset] != E_DELETED) && (g_aui8_buf[ui32_offset + E_ATTR] != A_LONG)
            && (memcmp(g_aui8_buf + ui32_offset, pc_name, NAME_LEN) == 0))
        {
            i32_found = YES;
        }
    }
    return i32_found;
}

/* the second part: a card image with the folder ZXNEXT */
static void test_folder(const char *pc_image)
{
/* local variables */
    FILE *ps_file;
    uint8_t *pui8_image;
    uint32_t ui32_boot;
    uint32_t ui32_real_root;
    uint32_t ui32_root;
    uint32_t ui32_data;
    uint32_t ui32_dir;
    uint32_t ui32_copy;
    size_t ui32_got;

/* start values */
    ps_file = fopen(pc_image, "rb");
    pui8_image = (uint8_t *)malloc(IMAGE_MAX_SECTORS * SECTOR);
    ui32_boot = 0;
    ui32_real_root = 0;
    ui32_root = 0;
    ui32_data = 0;
    ui32_dir = 0;
    ui32_copy = 0;
    ui32_got = 0;
    if ((ps_file == NULL) || (pui8_image == NULL))
    {
        error("no card image", 0);
    }
    else
    {
        ui32_got = fread(pui8_image, YES, IMAGE_MAX_SECTORS * SECTOR, ps_file);
        fclose(ps_file);
/* the image is the card now */
        g_pui8_card = pui8_image;
        g_ui32_card_sectors = (uint32_t)(ui32_got / SECTOR);
        ui32_boot = rd32(pui8_image + PART_START);
        ui32_real_root = rd32(pui8_image + (ui32_boot * SECTOR) + BS_ROOT);
/* the test image's boot sector copy is empty: make it one (as a formatted card has it) */
        ui32_copy = ui32_boot + rd16(pui8_image + (ui32_boot * SECTOR) + BS_COPY);
        memcpy(pui8_image + (ui32_copy * SECTOR), pui8_image + (ui32_boot * SECTOR), SECTOR);
        next_reset();
        if ((next_start() != NEXT_OK) || (next_in_folder() == 0))
        {
            error("folder: not found on the image", 0);
        }
/* the machine finds its root directory through the boot sector */
        machine_read(ui32_boot);
        ui32_root = rd32(g_aui8_buf + BS_ROOT);
        ui32_data = ui32_boot + rd16(g_aui8_buf + BS_RESERVED) + (g_aui8_buf[BS_FATS] * rd32(g_aui8_buf + BS_FAT32));
        ui32_dir = ui32_data + ((ui32_root - CLUS_FIRST) * g_aui8_buf[BS_CLUSTER]);
        ui32_copy = ui32_boot + rd16(g_aui8_buf + BS_COPY);
        if (ui32_root == ui32_real_root)
        {
            error("folder: the machine sees the card's real root", ui32_root);
        }
/* the boot sector written back: the card keeps its real root */
        machine_write(ui32_boot);
        if (rd32(pui8_image + (ui32_boot * SECTOR) + BS_ROOT) != ui32_real_root)
        {
            error("folder: the card's root directory was changed", 0);
        }
/* the boot sector's copy shows the folder too */
        machine_read(ui32_copy);
        if (rd32(g_aui8_buf + BS_ROOT) != ui32_root)
        {
            error("folder: the boot sector's copy shows another root", 0);
        }
/* the machine's root directory: the folder's files only */
        machine_read(ui32_dir);
        if (machine_has("TBBLUE  FW ") == 0)
        {
            error("folder: TBBLUE.FW not seen", 0);
        }
        if ((machine_has("OUTSIDE TXT") != 0) || (machine_has("ZXNEXT     ") != 0))
        {
            error("folder: the card's real root is seen", 0);
        }
        if ((machine_has(".          ") != 0) || (machine_has("..         ") != 0))
        {
            error("folder: a dot entry is seen", 0);
        }
/* the directory sector written back: the card keeps the folder's two own entries */
        machine_write(ui32_dir);
        if ((pui8_image[(ui32_dir * SECTOR) + E_ATTR] != A_DIR) || (pui8_image[(ui32_dir * SECTOR) + ENTRY + E_ATTR] != A_DIR)
            || (pui8_image[(ui32_dir * SECTOR) + ENTRY + SECOND] != E_DOT))
        {
            error("folder: the card's dot entries were changed", 0);
        }
        printf("folder: machine root cluster %lu, card root cluster %lu\n", (unsigned long)ui32_root,
               (unsigned long)ui32_real_root);
    }
    free(pui8_image);
}

int main(int argc, char **argv)
{
/* local variables */
    static const uint32_t aui32_reads[READS] = { 0, 1, 2, 40, 63 };
    static const uint32_t aui32_writes[WRITES] = { 5, 6, 63 };
    uint32_t ui32_lba;
    uint32_t ui32_index;
    uint32_t ui32_read;
    uint32_t ui32_written;
    int32_t i32_index;
    int32_t i32_writes_before;

/* start values */
    ui32_read = 0;
    ui32_written = 0;
    g_pui8_card = &g_aui8_pattern[0][0];
    for (ui32_lba = 0; ui32_lba < CARD_SECTORS; ui32_lba++)
    {
        for (ui32_index = 0; ui32_index < SECTOR; ui32_index++)
        {
            g_aui8_pattern[ui32_lba][ui32_index] = card_byte(ui32_lba, ui32_index);
        }
    }
/* no card: the machine stays in reset, requests are not served */
    g_ui32_card_sectors = 0;
    if ((next_start() != NEXT_ENOCARD) || (g_ui32_mctl != 0))
    {
        error("no card: the machine was started", g_ui32_mctl);
    }
    g_ui32_request = ST_READ;
    if (next_service() != 0)
    {
        error("no card: a request was served", 0);
    }
    g_ui32_request = 0;
/* a card: its size goes to the FPGA, the machine starts */
    g_ui32_card_sectors = CARD_SECTORS;
    if ((next_start() != NEXT_OK) || (g_ui32_mctl != MC_IN) || (g_ui32_size != CARD_SECTORS))
    {
        error("card: not started", g_ui32_mctl);
    }
/* this card has no file system: it is given as it is */
    if (next_in_folder() != 0)
    {
        error("card without a file system: a folder was found", 0);
    }
/* reads; the third one with a request word that changes between two readings */
    for (i32_index = 0; i32_index < READS; i32_index++)
    {
        if (i32_index == (READS - YES - YES))
        {
            g_i32_torn = YES;
        }
        test_read(aui32_reads[i32_index]);
    }
/* writes */
    for (i32_index = 0; i32_index < WRITES; i32_index++)
    {
        test_write(aui32_writes[i32_index]);
    }
/* a written sector comes back when read */
    memset(g_aui8_buf, 0, SECTOR);
    g_ui32_request = ST_READ | aui32_writes[0];
    next_service();
    if (g_aui8_buf[YES] != write_byte(aui32_writes[0], YES))
    {
        error("a written sector does not read back", aui32_writes[0]);
    }
/* an FPGA that is gone, and a sector outside the card: nothing is served or written */
    i32_writes_before = g_i32_card_writes;
    g_ui32_request = ALL_ONES;
    if (next_service() != 0)
    {
        error("a gone FPGA was served", 0);
    }
    g_ui32_request = ST_WRITE | CARD_SECTORS;
    if (next_service() != 0)
    {
        error("a sector outside the card was served", CARD_SECTORS);
    }
    if (g_i32_card_writes != i32_writes_before)
    {
        error("the card was written without a request", g_ui32_last_write);
    }
    g_ui32_request = 0;
/* the counts */
    next_counts(&ui32_read, &ui32_written);
    if ((ui32_read != (uint32_t)(READS + YES)) || (ui32_written != (uint32_t)WRITES))
    {
        error("wrong counts", ui32_read);
    }
    printf("sectors read %lu, written %lu\n", (unsigned long)ui32_read, (unsigned long)ui32_written);
/* the second part */
    if (argc >= ARGS_WITH_IMAGE)
    {
        test_folder(argv[ARG_IMAGE]);
    }
    printf("errors %d\n", (int)g_i32_errors);
    printf("RESULT: %s\n", (g_i32_errors == 0) ? "PASS" : "FAIL");
    return (g_i32_errors == 0) ? 0 : YES;
}
