/* next.cpp -- LNext (the ZX Spectrum Next core): the SD card's sectors for the machine */
/* The Next starts and works from its SD card. On this board the card is on the ESP32, so the */
/* FPGA holds an SD card made of logic and this file moves 512-byte sectors between it and the */
/* real card (LNext/10cl025/rtl/LNext.v): */
/*   MCTL read (MSTAT): [31] a sector waits to be written, [30] a sector is wanted, [29:0] its number */
/*   MCLR written:      the card's size in sectors */
/*   MCTL written:      [0] the ESP32 has the sector buffer, [1] a card is in (0: the machine is held in reset), */
/*                      [2] the UART pins are the Next's ESP UART (0: the loader's UART for the Bluetooth menu) */
/* The buffer's bytes go through the memory commands (addresses 0 to 511), which esp_hw.cpp sends */
/* as bursts. A request ends when bit 0 is cleared again; the machine then takes the sector (read) */
/* or goes on (write: its CPU waits until then). */
/* The Next's distribution (TBBLUE.FW, the machines and nextzxos folders ...) is in the folder */
/* ZXNEXT of the card's first FAT32 partition. The Next looks for its files in the root directory, */
/* so the machine is shown the folder as the root: FAT32 names the root directory's first cluster */
/* in its boot sector, and that one number is changed on the way to the machine (and changed back */
/* in a boot sector the machine writes). The folder's own "." and ".." entries, which a root */
/* directory does not have, are shown as parts of a long name that belongs to no file, which every */
/* FAT reader skips. Nothing on the card itself is different: the PC sees a normal folder, and the */
/* machine cannot reach the files outside it. A card without the folder is given as it is (the */
/* distribution in the root). */
#include "hw.h"
#include "hal.h"
/* this module's header, string functions */
#include "next.h"
#include "util.h"

/* yes */
#define YES 1
/* MSTAT: the two requests, the sector's number */
#define ST_WRITE 0x80000000u
#define ST_READ 0x40000000u
#define ST_LBA_MASK 0x3FFFFFFFu
/* MCTL: the buffer is ours, a card is in */
#define MC_ACK 1u
#define MC_IN 2u
/* MCTL: the UART pins are the Next's ESP UART */
#define MC_UART 4u
/* a sector's bytes */
#define SECTOR 512u
/* memory commands: read, write, and one that only empties esp_hw.cpp's read cache */
#define C_MRD 1u
#define C_MWR 2u
#define C_NONE 3u
/* where a command's number is in SNAPCMD */
#define CMD_SHIFT 28
/* polls without a request before next_service returns (a poll takes about 50 microseconds) */
#define IDLE_POLLS 40u
/* a sector that cannot be read is given as zeros */
#define FILL 0u
/* the card's first sector: its signature, the first partition's type and first sector */
#define SIG_OFFSET 510u
#define SIG_VALUE 0xAA55u
#define PART_TYPE 450u
#define PART_START 454u
/* a boot sector starts with a jump (two forms) */
#define JUMP_SHORT 0xEBu
#define JUMP_NEAR 0xE9u
/* boot sector fields: bytes per sector, sectors per cluster, reserved sectors, number of FATs, */
/* FAT16's FAT size (0 on FAT32), FAT32's FAT size, the root directory's cluster, the copy's place */
#define BS_BYTES 11u
#define BS_CLUSTER 13u
#define BS_RESERVED 14u
#define BS_FATS 16u
#define BS_FAT16 22u
#define BS_FAT32 36u
#define BS_ROOT 44u
#define BS_COPY 50u
/* a directory entry: its size, the name's length, the attribute byte, the cluster's two halves */
#define ENTRY 32u
#define NAME_LEN 11u
#define E_ATTR 11u
#define E_CLUS_HI 20u
#define E_CLUS_LO 26u
/* first bytes: the directory ends, a deleted entry, the folder's own entries */
#define E_END 0x00u
#define E_DELETED 0xE5u
#define E_DOT 0x2Eu
/* attributes: a folder, the bits that mark a volume label or a part of a long name, a long name */
#define A_DIR 0x10u
#define A_VOLUME 0x08u
#define A_LONG 0x0Fu
/* the two entries "." and ".." at the start of a folder */
#define DOT_ENTRIES 2u
/* clusters: the first one with data, a FAT entry's bits and size, entries per FAT sector */
#define CLUS_FIRST 2u
#define CLUS_MASK 0x0FFFFFFFu
#define CLUS_END 0x0FFFFFF8u
#define FAT_ENTRY 4u
#define FAT_PER_SECTOR 128u
/* the longest root directory looked through, in clusters */
#define ROOT_CLUSTERS 4096u
/* byte and half-word steps */
#define SHIFT_8 8
#define SHIFT_16 16
#define SHIFT_24 24
#define BYTE_MASK 0xFFu
#define BYTE_1 1u
#define BYTE_2 2u
#define BYTE_3 3u

/* the folder's name as a directory entry holds it */
static const char g_ac_folder[NAME_LEN + YES] = "ZXNEXT     ";

/* the sector in work */
static uint8_t g_aui8_sector[SECTOR];
/* the card is in the machine */
static int32_t g_i32_in;
/* the machine word's UART bit as it is now (MC_UART or 0) */
static uint32_t g_ui32_uart;
/* its size in sectors */
static uint32_t g_ui32_sectors;
/* sectors moved */
static uint32_t g_ui32_reads;
static uint32_t g_ui32_writes;
/* a second sector: the card's own copy of one the machine writes */
static uint8_t g_aui8_card[SECTOR];
/* the folder shown as the root: its first cluster (0: none) and that cluster's first sector */
static uint32_t g_ui32_folder;
static uint32_t g_ui32_folder_lba;
/* the root directory's real cluster, the boot sector and its copy */
static uint32_t g_ui32_root;
static uint32_t g_ui32_boot;
static uint32_t g_ui32_copy;

/* a 16-bit and a 32-bit number of the card (low byte first) */
static uint32_t rd16(const uint8_t *pui8_src)
{
    return (uint32_t)pui8_src[0] | ((uint32_t)pui8_src[BYTE_1] << SHIFT_8);
}

static uint32_t rd32(const uint8_t *pui8_src)
{
    return rd16(pui8_src) | ((uint32_t)pui8_src[BYTE_2] << SHIFT_16) | ((uint32_t)pui8_src[BYTE_3] << SHIFT_24);
}

static void wr32(uint8_t *pui8_dst, uint32_t ui32_value)
{
    pui8_dst[0] = (uint8_t)(ui32_value & BYTE_MASK);
    pui8_dst[BYTE_1] = (uint8_t)((ui32_value >> SHIFT_8) & BYTE_MASK);
/* the upper half */
    pui8_dst[BYTE_2] = (uint8_t)((ui32_value >> SHIFT_16) & BYTE_MASK);
    pui8_dst[BYTE_3] = (uint8_t)((ui32_value >> SHIFT_24) & BYTE_MASK);
}

/* 1 = the sector in work starts like a boot sector of 512-byte sectors */
static int32_t is_boot(void)
{
/* local variables */
    int32_t i32_result;

/* start values */
    i32_result = 0;
    if ((g_aui8_sector[0] == JUMP_SHORT) || (g_aui8_sector[0] == JUMP_NEAR))
    {
        if ((rd16(g_aui8_sector + BS_BYTES) == SECTOR) && (g_aui8_sector[BS_CLUSTER] != 0))
        {
            i32_result = YES;
        }
    }
    return i32_result;
}

/* Look for the folder in the card's first FAT32 partition. Found: g_ui32_folder is its cluster. */
static void find_folder(void)
{
/* local variables */
    uint32_t ui32_fat;
    uint32_t ui32_data;
    uint32_t ui32_per_cluster;
    uint32_t ui32_clus;
    uint32_t ui32_count;
    uint32_t ui32_sector;
    uint32_t ui32_offset;
    uint32_t ui32_found;
    int32_t i32_ok;
    int32_t i32_end;

/* start values */
    ui32_fat = 0;
    ui32_data = 0;
    ui32_per_cluster = 0;
    ui32_clus = 0;
    ui32_count = 0;
    ui32_sector = 0;
    ui32_offset = 0;
    ui32_found = 0;
    i32_ok = 0;
    i32_end = 0;
    g_ui32_folder = 0;
    g_ui32_boot = 0;
/* the card's first sector: a boot sector itself, or a partition table */
    if ((sd_read(0, g_aui8_sector) == 0) && (rd16(g_aui8_sector + SIG_OFFSET) == SIG_VALUE))
    {
        i32_ok = YES;
        if ((is_boot() == 0) && (g_aui8_sector[PART_TYPE] != 0))
        {
            g_ui32_boot = rd32(g_aui8_sector + PART_START);
/* the partition's boot sector */
            if ((sd_read(g_ui32_boot, g_aui8_sector) != 0) || (rd16(g_aui8_sector + SIG_OFFSET) != SIG_VALUE))
            {
                i32_ok = 0;
            }
        }
    }
/* FAT32 only: FAT16's root directory is not a chain of clusters */
    if ((i32_ok != 0) && (is_boot() != 0) && (rd16(g_aui8_sector + BS_FAT16) == 0)
        && (rd32(g_aui8_sector + BS_FAT32) != 0))
    {
        ui32_per_cluster = g_aui8_sector[BS_CLUSTER];
        ui32_fat = g_ui32_boot + rd16(g_aui8_sector + BS_RESERVED);
        ui32_data = ui32_fat + (g_aui8_sector[BS_FATS] * rd32(g_aui8_sector + BS_FAT32));
/* the root directory, the boot sector's copy */
        g_ui32_root = rd32(g_aui8_sector + BS_ROOT);
        g_ui32_copy = g_ui32_boot + rd16(g_aui8_sector + BS_COPY);
        ui32_clus = g_ui32_root;
    }
    else
    {
        i32_end = YES;
    }
/* the root directory, cluster by cluster, until the folder or the end */
    while (i32_end == 0)
    {
        if ((ui32_clus < CLUS_FIRST) || (ui32_clus >= CLUS_END) || (ui32_count >= ROOT_CLUSTERS))
        {
            i32_end = YES;
        }
        ui32_count++;
        for (ui32_sector = 0; (ui32_sector < ui32_per_cluster) && (i32_end == 0); ui32_sector++)
        {
            if (sd_read(ui32_data + ((ui32_clus - CLUS_FIRST) * ui32_per_cluster) + ui32_sector, g_aui8_sector) != 0)
            {
                i32_end = YES;
            }
/* the sector's entries */
            for (ui32_offset = 0; (ui32_offset < SECTOR) && (i32_end == 0); ui32_offset += ENTRY)
            {
                if (g_aui8_sector[ui32_offset] == E_END)
                {
                    i32_end = YES;
                }
                else if ((g_aui8_sector[ui32_offset] != E_DELETED)
                         && ((g_aui8_sector[ui32_offset + E_ATTR] & (A_DIR | A_VOLUME)) == A_DIR)
                         && (u_memcmp(g_aui8_sector + ui32_offset, g_ac_folder, NAME_LEN) == 0))
                {
/* the folder */
                    ui32_found = rd16(g_aui8_sector + ui32_offset + E_CLUS_LO)
                                 | (rd16(g_aui8_sector + ui32_offset + E_CLUS_HI) << SHIFT_16);
                    i32_end = YES;
                }
                else
                {
/* another entry */
                }
            }
        }
/* the next cluster of the chain */
        if (i32_end == 0)
        {
            if (sd_read(ui32_fat + (ui32_clus / FAT_PER_SECTOR), g_aui8_sector) != 0)
            {
                i32_end = YES;
            }
            ui32_clus = rd32(g_aui8_sector + ((ui32_clus % FAT_PER_SECTOR) * FAT_ENTRY)) & CLUS_MASK;
        }
    }
/* a folder with a cluster of its own, other than the root */
    if ((ui32_found >= CLUS_FIRST) && (ui32_found < CLUS_END) && (ui32_found != g_ui32_root))
    {
        g_ui32_folder = ui32_found;
        g_ui32_folder_lba = ui32_data + ((ui32_found - CLUS_FIRST) * ui32_per_cluster);
    }
}

/* a sector on its way to the machine: the folder becomes the root directory */
static void to_machine(uint32_t ui32_lba)
{
/* local variables */
    uint32_t ui32_entry;
    uint32_t ui32_offset;

/* start values */
    ui32_entry = 0;
    ui32_offset = 0;
    if (g_ui32_folder != 0)
    {
/* the boot sector and its copy name the folder's cluster as the root */
        if (((ui32_lba == g_ui32_boot) || (ui32_lba == g_ui32_copy)) && (rd32(g_aui8_sector + BS_ROOT) == g_ui32_root))
        {
            wr32(g_aui8_sector + BS_ROOT, g_ui32_folder);
        }
/* the folder's "." and "..": parts of a long name without a file */
        if (ui32_lba == g_ui32_folder_lba)
        {
            for (ui32_entry = 0; ui32_entry < DOT_ENTRIES; ui32_entry++)
            {
                ui32_offset = ui32_entry * ENTRY;
                if (g_aui8_sector[ui32_offset] == E_DOT)
                {
                    g_aui8_sector[ui32_offset + E_ATTR] = A_LONG;
                }
            }
        }
    }
}

/* a sector the machine wrote: what was changed for it is put back */
static void from_machine(uint32_t ui32_lba)
{
    if (g_ui32_folder != 0)
    {
/* a boot sector keeps the real root directory */
        if (((ui32_lba == g_ui32_boot) || (ui32_lba == g_ui32_copy)) && (rd32(g_aui8_sector + BS_ROOT) == g_ui32_folder))
        {
            wr32(g_aui8_sector + BS_ROOT, g_ui32_root);
        }
/* the folder's first two entries stay as the card has them */
        if (ui32_lba == g_ui32_folder_lba)
        {
            if ((sd_read(ui32_lba, g_aui8_card) == 0) && (g_aui8_card[0] == E_DOT))
            {
                u_memcpy(g_aui8_sector, g_aui8_card, DOT_ENTRIES * ENTRY);
            }
        }
    }
}

/* a memory command (esp_hw.cpp turns the writes into bursts and reads through a cache) */
static uint32_t snap_cmd(uint32_t ui32_cmd, uint32_t ui32_addr, uint32_t ui32_data)
{
/* local variables */
    uint32_t ui32_result;

    SNAPDAT = ui32_data;
    SNAPCMD = (ui32_cmd << CMD_SHIFT) | ui32_addr;
/* wait until the FPGA has done it */
    while ((SNAPCTL & SNAP_BUSY) != 0)
    {
    }
    ui32_result = SNAPDAT;
    return ui32_result;
}

/* the machine's request, read until two reads agree (the FPGA's word changes in another clock) */
static uint32_t request(void)
{
/* local variables */
    uint32_t ui32_first;
    uint32_t ui32_second;

/* start values */
    ui32_first = MCTL;
    ui32_second = ui32_first;
/* without a request one read is enough */
    if ((ui32_first & (ST_READ | ST_WRITE)) != 0)
    {
        ui32_second = MCTL;
        while (ui32_second != ui32_first)
        {
/* once more */
            ui32_first = ui32_second;
            ui32_second = MCTL;
        }
    }
/* both requests at once do not exist: that is an FPGA that is gone (reconfiguring, all ones) */
    if ((ui32_second & (ST_READ | ST_WRITE)) == (ST_READ | ST_WRITE))
    {
        ui32_second = 0;
    }
/* a sector outside the card is no request either */
    if ((ui32_second & ST_LBA_MASK) >= g_ui32_sectors)
    {
        ui32_second = 0;
    }
    return ui32_second;
}

/* the machine wants a sector: from the card into the buffer */
static void give_sector(uint32_t ui32_lba)
{
/* local variables */
    uint32_t ui32_index;

/* start values */
    ui32_index = 0;
    if (sd_read(ui32_lba, g_aui8_sector) != 0)
    {
/* the card failed: zeros */
        u_memset(g_aui8_sector, FILL, SECTOR);
    }
    to_machine(ui32_lba);
    MCTL = MC_IN | MC_ACK | g_ui32_uart;
/* the bytes; the write of MCTL that follows sends the collected ones first */
    for (ui32_index = 0; ui32_index < SECTOR; ui32_index++)
    {
        snap_cmd(C_MWR, ui32_index, g_aui8_sector[ui32_index]);
    }
    MCTL = MC_IN | g_ui32_uart;
    g_ui32_reads++;
}

/* the machine wrote a sector: from the buffer onto the card */
static void take_sector(uint32_t ui32_lba)
{
/* local variables */
    uint32_t ui32_index;

/* start values */
    ui32_index = 0;
    MCTL = MC_IN | MC_ACK | g_ui32_uart;
/* nothing of an earlier sector may come from the read cache */
    snap_cmd(C_NONE, 0, 0);
    for (ui32_index = 0; ui32_index < SECTOR; ui32_index++)
    {
        g_aui8_sector[ui32_index] = (uint8_t)snap_cmd(C_MRD, ui32_index, 0);
    }
/* the machine goes on; the card is written meanwhile */
    MCTL = MC_IN | g_ui32_uart;
    from_machine(ui32_lba);
    sd_write(ui32_lba, g_aui8_sector);
    g_ui32_writes++;
}

/* Put the card into the machine: NEXT_OK, NEXT_ENOCARD */
int32_t next_start(void)
{
/* local variables */
    uint32_t ui32_sectors;
    int32_t i32_result;

/* start values */
    ui32_sectors = sd_sectors();
    i32_result = NEXT_ENOCARD;
    MCTL = 0;
    g_i32_in = 0;
/* a card that answers: its size first, then the machine may start */
    if (ui32_sectors != 0)
    {
        g_ui32_sectors = ui32_sectors;
/* the folder with the Next's files, before the machine reads anything */
        find_folder();
        MCLR = ui32_sectors;
        MCTL = MC_IN | g_ui32_uart;
        g_i32_in = YES;
        i32_result = NEXT_OK;
    }
    return i32_result;
}

/* main loop: the sectors the machine asks for */
uint32_t next_service(void)
{
/* local variables */
    uint32_t ui32_state;
    uint32_t ui32_idle;
    uint32_t ui32_moved;

/* start values */
    ui32_state = 0;
    ui32_idle = 0;
    ui32_moved = 0;
    if (g_i32_in != 0)
    {
/* requests come in runs: stay while they follow each other */
        while (ui32_idle < IDLE_POLLS)
        {
            ui32_state = request();
            if ((ui32_state & ST_WRITE) != 0)
            {
                take_sector(ui32_state & ST_LBA_MASK);
                ui32_idle = 0;
                ui32_moved++;
            }
            else if ((ui32_state & ST_READ) != 0)
            {
                give_sector(ui32_state & ST_LBA_MASK);
                ui32_idle = 0;
                ui32_moved++;
            }
            else if (ui32_moved != 0)
            {
/* nothing: a few more looks after a sector was moved */
                ui32_idle++;
            }
            else
            {
/* nothing at all: back at once */
                ui32_idle = IDLE_POLLS;
            }
        }
    }
    return ui32_moved;
}

/* sectors read and written since the start */
void next_counts(uint32_t *pui32_read, uint32_t *pui32_written)
{
    *pui32_read = g_ui32_reads;
    *pui32_written = g_ui32_writes;
}

/* 1 = the machine works in the card's folder ZXNEXT, 0 = in the card's root directory */
int32_t next_in_folder(void)
{
    return (g_ui32_folder != 0) ? YES : 0;
}

/* The UART pins between the FPGA and the ESP32: 1 = the Next's ESP UART (the ESP32 is its Wi-Fi */
/* module), 0 = the loader's UART (the Bluetooth menu). Not during a sector request. */
void next_uart(int32_t i32_machine)
{
    g_ui32_uart = 0;
    if (i32_machine != 0)
    {
        g_ui32_uart = MC_UART;
    }
/* the machine word, with the card as it is */
    if (g_i32_in != 0)
    {
        MCTL = MC_IN | g_ui32_uart;
    }
    else
    {
        MCTL = g_ui32_uart;
    }
}

/* back to the state after a start: the next machine starts the loader again without an ESP32 */
/* restart (esp_hw.cpp; the Bluetooth connection stays) */
void next_reset(void)
{
    g_i32_in = 0;
    g_ui32_uart = 0;
    g_ui32_sectors = 0;
    g_ui32_folder = 0;
    g_ui32_reads = 0;
    g_ui32_writes = 0;
}
