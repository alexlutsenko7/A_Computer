/* fat.c -- FAT16 / FAT32: reading, and writing new files (fw_*) */
/* The FAT sector cache is write-back: a changed sector is written to every */
/* FAT copy when another FAT sector is needed and when a file is closed. */
#include "fat.h"
#include "hal.h"
#include "util.h"

/* sectors: bytes as a shift and as a mask */
#define SECTOR_SHIFT 9
#define SECTOR_MASK 511u
/* rounding a byte count up to whole sectors */
#define SECTOR_ROUND_UP 511u
/* "no sector" in a cache, and the error value of fat_get */
#define LBA_NONE 0xFFFFFFFFu
#define FAT_GET_ERROR 0xFFFFFFFFu
/* fat_load: the FAT sector could not be read */
#define FAT_LOAD_ERROR (-1)
/* little-endian fields */
#define SHIFT_BYTE 8
#define SHIFT_WORD 16
/* offsets inside a field */
#define NEXT_BYTE 1
#define HIGH_WORD 2
/* one unit: a single step, bit 0, or the difference between a power of two and its mask */
#define ONE 1u
/* boolean results that the interface gives as numbers */
#define YES 1
/* boot sector and MBR: signature at the end of the sector */
#define BOOT_SIG_OFF 510
#define BOOT_SIG 0xAA55u
/* boot sector: the jump instruction it starts with */
#define VBR_JUMP_SHORT 0xEB
#define VBR_JUMP_NEAR 0xE9
/* boot sector: fields of the BIOS parameter block */
#define BPB_BYTES_PER_SEC 11
#define BPB_SEC_PER_CLUS 13
#define BPB_RSVD_SECS 14
/* number of FATs, root entries, total sectors (16 bit) */
#define BPB_NUM_FATS 16
#define BPB_ROOT_ENTRIES 17
#define BPB_TOTAL_SECS_16 19
/* the FAT's size, and the 32-bit total */
#define BPB_FAT_SIZE_16 22
#define BPB_TOTAL_SECS_32 32
#define BPB_FAT_SIZE_32 36
/* FAT32: root cluster, FSInfo sector */
#define BPB_ROOT_CLUS 44
#define BPB_FSINFO_SEC 48
/* boot sector: the file system type text of FAT12/16 and of FAT32 */
#define VBR_TYPE16_OFF 54
#define VBR_TYPE16_LEN 3
/* FAT32's */
#define VBR_TYPE32_OFF 82
#define VBR_TYPE32_LEN 5
/* MBR: the partition table */
#define MBR_TABLE_OFF 446
#define MBR_ENTRY_LEN 16
#define MBR_ENTRIES 4
/* inside an entry: type, first sector */
#define MBR_ENTRY_TYPE 4
#define MBR_ENTRY_LBA 8
/* MBR: partition types that hold FAT12/16/32 */
#define PART_FAT12 0x01
#define PART_FAT16_SMALL 0x04
#define PART_FAT16 0x06
/* FAT32, and the LBA variants */
#define PART_FAT32 0x0B
#define PART_FAT32_LBA 0x0C
#define PART_FAT16_LBA 0x0E
/* cluster numbers: the first data cluster, and the limits that tell FAT12 / FAT16 / FAT32 apart */
#define CLUS_FIRST 2u
#define CLUS_MIN_FAT16 4086u
#define CLUS_MIN_FAT32 65526u
/* FAT entries: bytes per entry as a shift, the used bits of FAT32, end-of-chain marks */
#define FAT32_ENTRY_SHIFT 2
#define FAT16_ENTRY_SHIFT 1
/* FAT32: 28 bits used, 4 kept */
#define FAT32_ENTRY_MASK 0x0FFFFFFFu
#define FAT32_RESERVED_MASK 0xF0000000u
/* the end of a chain */
#define FAT32_END_OF_CHAIN 0x0FFFFFFFu
#define FAT16_END_OF_CHAIN 0xFFFFu
/* FSInfo sector of FAT32: signatures, free count, next free cluster */
#define FSI_LEAD_SIG 0x41615252u
#define FSI_STRUC_SIG_OFF 484
#define FSI_STRUC_SIG 0x61417272u
/* where the free count and the next free cluster are */
#define FSI_FREE_COUNT_OFF 488
#define FSI_NEXT_FREE_OFF 492
#define FSI_FREE_UNKNOWN 0xFFFFFFFFu
/* directory entries */
#define DIR_ENTRY_LEN 32
#define DIR_ENTRIES_PER_SEC 16
#define DIR_NO_ENTRY (-1)
/* directory entry: first byte marks */
#define DIR_END 0x00
#define DIR_DELETED 0xE5
#define DIR_E5_ESCAPE 0x05
/* directory entry: field offsets */
#define DIR_EXT_OFF 8
#define DIR_ATTR_OFF 11
#define DIR_NT_FLAGS_OFF 12
/* first cluster (two halves), size */
#define DIR_CLUS_HIGH_OFF 20
#define DIR_CLUS_LOW_OFF 26
#define DIR_SIZE_OFF 28
/* directory entry: attributes used here */
#define DIR_ATTR_LONG_NAME 0x0F
#define DIR_ATTR_VOLUME 0x08
#define DIR_ATTR_ARCHIVE 0x20
/* directory entry: Windows NT flags, name / extension stored in lower case */
#define NT_LOWER_NAME 0x08
#define NT_LOWER_EXT 0x10
/* 8.3 names */
#define SNAME_NAME_LEN 8
#define SNAME_EXT_LEN 3
/* the last place of an extension, the distance from 'A' to 'a' */
#define EXT_LAST_INDEX 2
#define ASCII_CASE_OFFSET 32
/* long-name entries: sequence number, mark of the last part, characters per part */
#define LFN_SEQ_MASK 0x1F
#define LFN_LAST_PART 0x40
#define LFN_CHARS 13
/* the name buffer, the first sequence number */
#define LFN_BUF_LEN 64
#define LFN_SEQ_FIRST 1
/* long names: unused characters are 0xFFFF, characters outside ASCII are shown as '?' */
#define LFN_PAD 0xFFFFu
#define ASCII_END 0x80u

/* byte offsets of the 13 UTF-16 characters in a long-name entry */
static const uint8_t g_aui8_lfn_off[LFN_CHARS] = { 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30 };
/* boot sectors and directories */
static uint8_t g_aui8_secbuf[FAT_SECTOR_SIZE];
/* FAT sector cache */
static uint8_t g_aui8_fatbuf[FAT_SECTOR_SIZE];
/* the file being written */
FWFILE g_s_fw_file;
/* sector in the FAT cache */
static uint32_t g_ui32_fatbuf_lba;
/* file system type, sectors per cluster as a shift, number of FAT copies */
static uint8_t g_ui8_fat32;
static uint8_t g_ui8_spc_shift;
static uint8_t g_ui8_nfats;
/* the FAT cache was changed; the FSInfo free count was set to "unknown" */
static uint8_t g_ui8_fat_dirty;
static uint8_t g_ui8_fsinfo_done;
/* sectors per cluster, and where the areas of the volume start */
static uint32_t g_ui32_spc;
static uint32_t g_ui32_fat_lba;
static uint32_t g_ui32_root_lba;
/* the root directory's sectors (FAT16), the data area */
static uint32_t g_ui32_root_secs;
static uint32_t g_ui32_data_lba;
/* root directory cluster (FAT32), highest valid cluster number */
static uint32_t g_ui32_root_clus;
static uint32_t g_ui32_max_clus;
/* sectors of one FAT, FSInfo sector (0: none), where to look for a free cluster */
static uint32_t g_ui32_fatsz;
static uint32_t g_ui32_fsinfo_lba;
static uint32_t g_ui32_free_hint;
/* where fat_list found the entry it passed to the callback last */
static uint32_t g_ui32_ent_lba;
static int32_t g_i32_ent_idx;

/* 16 bits, low byte first */
static uint32_t rd16(const uint8_t *pui8_src)
{
/* local variables */
    uint32_t ui32_value;

    ui32_value = pui8_src[0] | ((uint32_t)pui8_src[NEXT_BYTE] << SHIFT_BYTE);
    return ui32_value;
}

/* 32 bits, low byte first */
static uint32_t rd32(const uint8_t *pui8_src)
{
/* local variables */
    uint32_t ui32_value;

    ui32_value = rd16(pui8_src) | (rd16(pui8_src + HIGH_WORD) << SHIFT_WORD);
    return ui32_value;
}

/* store 16 bits, low byte first */
static void wr16(uint8_t *pui8_dst, uint32_t ui32_value)
{
    pui8_dst[0] = (uint8_t)ui32_value;
    pui8_dst[NEXT_BYTE] = (uint8_t)(ui32_value >> SHIFT_BYTE);
}

/* store 32 bits, low byte first */
static void wr32(uint8_t *pui8_dst, uint32_t ui32_value)
{
    wr16(pui8_dst, ui32_value);
    wr16(pui8_dst + HIGH_WORD, ui32_value >> SHIFT_WORD);
}

/* is this sector the boot sector of a FAT volume with 512-byte sectors? */
static bool is_vbr(const uint8_t *pui8_sec)
{
/* local variables */
    bool b_jump;
    bool b_type;
    bool b_result;

/* it starts with a jump instruction */
    b_jump = (pui8_sec[0] == VBR_JUMP_SHORT) || (pui8_sec[0] == VBR_JUMP_NEAR);
/* and names its type as FAT.. (FAT12/16) or FAT32 */
    b_type = (u_memcmp(pui8_sec + VBR_TYPE16_OFF, "FAT", VBR_TYPE16_LEN) == 0) ||
             (u_memcmp(pui8_sec + VBR_TYPE32_OFF, "FAT32", VBR_TYPE32_LEN) == 0);
/* with 512-byte sectors and a cluster size */
    b_result = b_jump && (rd16(pui8_sec + BPB_BYTES_PER_SEC) == FAT_SECTOR_SIZE) &&
               (pui8_sec[BPB_SEC_PER_CLUS] != 0) && b_type;
    return b_result;
}

/* the first FAT partition of the MBR in the sector buffer: its first sector, or 0 */
static uint32_t mbr_partition(void)
{
/* local variables */
    const uint8_t *pui8_entry;
    uint32_t ui32_vbr;
/* a loop counter, a partition's type */
    int32_t i32_index;
    uint8_t ui8_type;

/* start values */
    pui8_entry = g_aui8_secbuf;
    ui32_vbr = 0;
    ui8_type = 0;
/* the four entries of the table, until one fits */
    for (i32_index = 0; (i32_index < MBR_ENTRIES) && (ui32_vbr == 0); i32_index++)
    {
        pui8_entry = g_aui8_secbuf + MBR_TABLE_OFF + (MBR_ENTRY_LEN * i32_index);
        ui8_type = pui8_entry[MBR_ENTRY_TYPE];
/* any of the FAT partition types */
        if ((ui8_type == PART_FAT12) || (ui8_type == PART_FAT16_SMALL) || (ui8_type == PART_FAT16) ||
            (ui8_type == PART_FAT32) || (ui8_type == PART_FAT32_LBA) || (ui8_type == PART_FAT16_LBA))
        {
            ui32_vbr = rd32(pui8_entry + MBR_ENTRY_LBA);
        }
    }
    return ui32_vbr;
}

/* read the volume's layout from its boot sector in the sector buffer */
static int32_t mount_volume(uint32_t ui32_vbr)
{
/* local variables */
    uint32_t ui32_rsv;
    uint32_t ui32_rootents;
    uint32_t ui32_total;
/* the next-free hint, the result */
    uint32_t ui32_hint;
    int32_t i32_result;

/* start values */
    ui32_rsv = 0;
    ui32_rootents = 0;
    ui32_total = 0;
/* nothing read yet, no error */
    ui32_hint = 0;
    i32_result = FAT_OK;
/* sectors per cluster must be a power of two */
    g_ui32_spc = g_aui8_secbuf[BPB_SEC_PER_CLUS];
    if ((g_ui32_spc & (g_ui32_spc - ONE)) != 0)
    {
        i32_result = FAT_ENOFS;
    }
/* the sizes of the volume's areas */
    if (i32_result == FAT_OK)
    {
/* sectors per cluster as a shift */
        g_ui8_spc_shift = 0;
        while ((ONE << g_ui8_spc_shift) < g_ui32_spc)
        {
            g_ui8_spc_shift++;
        }
/* the reserved sectors, the FATs, the root directory */
        ui32_rsv = rd16(g_aui8_secbuf + BPB_RSVD_SECS);
        g_ui8_nfats = g_aui8_secbuf[BPB_NUM_FATS];
        ui32_rootents = rd16(g_aui8_secbuf + BPB_ROOT_ENTRIES);
/* the 16-bit fields are 0 when the 32-bit ones are used */
        ui32_total = rd16(g_aui8_secbuf + BPB_TOTAL_SECS_16);
        if (ui32_total == 0)
        {
            ui32_total = rd32(g_aui8_secbuf + BPB_TOTAL_SECS_32);
        }
/* the same for the FAT's size */
        g_ui32_fatsz = rd16(g_aui8_secbuf + BPB_FAT_SIZE_16);
/* the same for the size of one FAT */
        if (g_ui32_fatsz == 0)
        {
            g_ui32_fatsz = rd32(g_aui8_secbuf + BPB_FAT_SIZE_32);
        }
/* a volume has at least one FAT */
        if (g_ui8_nfats == 0)
        {
            i32_result = FAT_ENOFS;
        }
    }
/* where the areas start */
    if (i32_result == FAT_OK)
    {
        g_ui32_root_secs = ((ui32_rootents * DIR_ENTRY_LEN) + SECTOR_ROUND_UP) >> SECTOR_SHIFT;
        g_ui32_fat_lba = ui32_vbr + ui32_rsv;
/* the root directory of FAT16 follows the FATs, the data follows it */
        g_ui32_root_lba = g_ui32_fat_lba + (g_ui8_nfats * g_ui32_fatsz);
        g_ui32_data_lba = g_ui32_root_lba + g_ui32_root_secs;
/* there must be room for data */
        if (ui32_total <= (g_ui32_data_lba - ui32_vbr))
        {
            i32_result = FAT_ENOFS;
        }
    }
/* the number of clusters decides the type */
    if (i32_result == FAT_OK)
    {
/* highest valid cluster number */
        g_ui32_max_clus = ((ui32_total - (g_ui32_data_lba - ui32_vbr)) >> g_ui8_spc_shift) + ONE;
/* fewer clusters would be FAT12 */
        if (g_ui32_max_clus < CLUS_MIN_FAT16)
        {
            i32_result = FAT_ENOFS;
        }
    }
/* FAT32 has its root directory in a cluster chain, and an FSInfo sector */
    if (i32_result == FAT_OK)
    {
        g_ui8_fat32 = 0;
/* no root cluster, no FSInfo sector */
        g_ui32_root_clus = 0;
        g_ui32_fsinfo_lba = 0;
/* FAT32 only */
        if (g_ui32_max_clus >= CLUS_MIN_FAT32)
        {
            g_ui8_fat32 = YES;
            g_ui32_root_clus = rd32(g_aui8_secbuf + BPB_ROOT_CLUS);
/* the FSInfo sector's place */
            g_ui32_fsinfo_lba = ui32_vbr + rd16(g_aui8_secbuf + BPB_FSINFO_SEC);
        }
        g_ui32_free_hint = CLUS_FIRST;
/* a valid FSInfo sector says where to look for a free cluster; an invalid one is not used */
        if ((g_ui32_fsinfo_lba != 0) && (sd_read(g_ui32_fsinfo_lba, g_aui8_secbuf) == 0) &&
            (rd32(g_aui8_secbuf) == FSI_LEAD_SIG) && (rd32(g_aui8_secbuf + FSI_STRUC_SIG_OFF) == FSI_STRUC_SIG))
        {
            ui32_hint = rd32(g_aui8_secbuf + FSI_NEXT_FREE_OFF);
/* only a possible cluster number is taken */
            if ((ui32_hint >= CLUS_FIRST) && (ui32_hint <= g_ui32_max_clus))
            {
                g_ui32_free_hint = ui32_hint;
            }
        }
        else
        {
/* no usable FSInfo sector */
            g_ui32_fsinfo_lba = 0;
        }
    }
    return i32_result;
}

/* find the file system on the card: FAT_OK, FAT_EIO, FAT_ENOFS */
int32_t fat_mount(void)
{
/* local variables */
    uint32_t ui32_vbr;
    int32_t i32_result;

/* start values */
    ui32_vbr = 0;
    i32_result = FAT_OK;
/* the caches are empty */
    g_ui32_fatbuf_lba = LBA_NONE;
    g_ui8_fat_dirty = 0;
    g_ui8_fsinfo_done = 0;
/* sector 0 is a boot sector or an MBR; both end with the signature */
    if (sd_read(0, g_aui8_secbuf) != 0)
    {
        i32_result = FAT_EIO;
    }
/* no signature: no file system */
    else if (rd16(g_aui8_secbuf + BOOT_SIG_OFF) != BOOT_SIG)
    {
        i32_result = FAT_ENOFS;
    }
    else if (!is_vbr(g_aui8_secbuf))
    {
/* MBR: first FAT partition */
        ui32_vbr = mbr_partition();
        if (ui32_vbr == 0)
        {
            i32_result = FAT_ENOFS;
        }
/* its boot sector */
        else if (sd_read(ui32_vbr, g_aui8_secbuf) != 0)
        {
/* the partition's boot sector could not be read */
            i32_result = FAT_EIO;
        }
        else if ((rd16(g_aui8_secbuf + BOOT_SIG_OFF) != BOOT_SIG) || !is_vbr(g_aui8_secbuf))
        {
/* the partition holds no FAT volume */
            i32_result = FAT_ENOFS;
        }
        else
        {
/* the partition's boot sector is in the buffer */
        }
    }
    else
    {
/* an unpartitioned card: the boot sector is in the buffer */
    }
/* the boot sector tells the rest */
    if (i32_result == FAT_OK)
    {
        i32_result = mount_volume(ui32_vbr);
    }
    return i32_result;
}

/* 1 = the mounted file system is FAT32 */
int32_t fat_is_fat32(void)
{
/* local variables */
    int32_t i32_result;

    i32_result = g_ui8_fat32;
    return i32_result;
}

/* is this cluster number outside the volume (end of chain, free, bad)? */
static bool clus_end(uint32_t ui32_clus)
{
/* local variables */
    bool b_result;

    b_result = (ui32_clus < CLUS_FIRST) || (ui32_clus > g_ui32_max_clus);
    return b_result;
}

/* first sector of a cluster */
static uint32_t clus_lba(uint32_t ui32_clus)
{
/* local variables */
    uint32_t ui32_lba;

    ui32_lba = g_ui32_data_lba + ((ui32_clus - CLUS_FIRST) << g_ui8_spc_shift);
    return ui32_lba;
}

/* write a changed FAT cache sector to every FAT copy */
static int32_t fat_flush(void)
{
/* local variables */
    uint32_t ui32_copy;
    int32_t i32_result;

/* start values */
    ui32_copy = 0;
    i32_result = FAT_OK;
/* nothing to do for an unchanged sector */
    if (g_ui8_fat_dirty != 0)
    {
/* every copy, until one fails */
        while ((ui32_copy < g_ui8_nfats) && (i32_result == FAT_OK))
        {
            if (sd_write(g_ui32_fatbuf_lba + (ui32_copy * g_ui32_fatsz), g_aui8_fatbuf) != 0)
            {
                i32_result = FAT_EIO;
            }
/* next copy */
            ui32_copy++;
        }
/* clean only when every copy was written */
        if (i32_result == FAT_OK)
        {
            g_ui8_fat_dirty = 0;
        }
    }
    return i32_result;
}

/* FAT sector holding the entry of a cluster into the cache; returns the byte offset, or FAT_LOAD_ERROR */
static int32_t fat_load(uint32_t ui32_clus)
{
/* local variables */
    uint32_t ui32_off;
    uint32_t ui32_lba;
    int32_t i32_result;

/* byte offset of the entry in the FAT: 4 bytes per entry in FAT32, 2 in FAT16 */
    ui32_off = ui32_clus << FAT16_ENTRY_SHIFT;
    if (g_ui8_fat32 != 0)
    {
        ui32_off = ui32_clus << FAT32_ENTRY_SHIFT;
    }
/* the sector, and the place in it */
    ui32_lba = g_ui32_fat_lba + (ui32_off >> SECTOR_SHIFT);
    i32_result = (int32_t)(ui32_off & SECTOR_MASK);
/* another sector than the cached one: write the old one back first */
    if (ui32_lba != g_ui32_fatbuf_lba)
    {
        if (fat_flush() != FAT_OK)
        {
            i32_result = FAT_LOAD_ERROR;
        }
/* then read the one wanted */
        else if (sd_read(ui32_lba, g_aui8_fatbuf) != 0)
        {
/* the cache holds nothing usable now */
            g_ui32_fatbuf_lba = LBA_NONE;
            i32_result = FAT_LOAD_ERROR;
        }
        else
        {
/* cached now */
            g_ui32_fatbuf_lba = ui32_lba;
        }
    }
    return i32_result;
}

/* raw FAT entry (FAT32: 28 bits); FAT_GET_ERROR on a read error */
static uint32_t fat_get(uint32_t ui32_clus)
{
/* local variables */
    int32_t i32_off;
    uint32_t ui32_value;

/* start values */
    i32_off = fat_load(ui32_clus);
    ui32_value = FAT_GET_ERROR;
/* the entry is in the cache */
    if (i32_off >= 0)
    {
        if (g_ui8_fat32 != 0)
        {
            ui32_value = rd32(g_aui8_fatbuf + i32_off) & FAT32_ENTRY_MASK;
        }
        else
        {
/* FAT16: the whole entry */
            ui32_value = rd16(g_aui8_fatbuf + i32_off);
        }
    }
    return ui32_value;
}

/* change a FAT entry in the cache (FAT32: the 4 reserved bits are kept) */
static int32_t fat_set(uint32_t ui32_clus, uint32_t ui32_value)
{
/* local variables */
    int32_t i32_off;
    int32_t i32_result;

/* start values */
    i32_off = fat_load(ui32_clus);
    i32_result = FAT_EIO;
/* the entry is in the cache */
    if (i32_off >= 0)
    {
        if (g_ui8_fat32 != 0)
        {
            wr32(g_aui8_fatbuf + i32_off,
                 (rd32(g_aui8_fatbuf + i32_off) & FAT32_RESERVED_MASK) | (ui32_value & FAT32_ENTRY_MASK));
        }
        else
        {
/* FAT16: the whole entry */
            wr16(g_aui8_fatbuf + i32_off, ui32_value);
        }
/* the sector must be written back */
        g_ui8_fat_dirty = YES;
        i32_result = FAT_OK;
    }
    return i32_result;
}

/* next cluster in the chain; 0 = end of chain or error */
static uint32_t fat_next(uint32_t ui32_clus)
{
    uint32_t ui32_next;

    ui32_next = fat_get(ui32_clus);
/* everything outside the volume ends the chain */
    if (clus_end(ui32_next))
    {
        ui32_next = 0;
    }
    return ui32_next;
}

/* one part of a long name (a directory entry with the long-name attribute) into ac_lfn */
static void lfn_part(const uint8_t *pui8_entry, char ac_lfn[LFN_BUF_LEN], int32_t *pi32_has_lfn)
{
/* local variables */
    int32_t i32_seq;
    int32_t i32_index;
/* the place in the name, one character */
    int32_t i32_pos;
    uint32_t ui32_char;

/* start values */
    i32_seq = pui8_entry[0] & LFN_SEQ_MASK;
    i32_index = 0;
/* nothing placed yet */
    i32_pos = 0;
    ui32_char = 0;
/* the last part is stored first: a new name starts */
    if ((pui8_entry[0] & LFN_LAST_PART) != 0)
    {
        u_memset(ac_lfn, 0, LFN_BUF_LEN);
        *pi32_has_lfn = YES;
    }
/* the part's 13 characters go to their place in the name */
    if ((*pi32_has_lfn != 0) && (i32_seq >= LFN_SEQ_FIRST))
    {
        for (i32_index = 0; i32_index < LFN_CHARS; i32_index++)
        {
/* its place, and the character (UTF-16) */
            i32_pos = ((i32_seq - LFN_SEQ_FIRST) * LFN_CHARS) + i32_index;
            ui32_char = rd16(pui8_entry + g_aui8_lfn_off[i32_index]);
/* what does not fit the buffer is dropped; the last place stays 0 */
            if (i32_pos < (LFN_BUF_LEN - (int32_t)ONE))
            {
                if ((ui32_char == 0) || (ui32_char == LFN_PAD))
                {
                    ac_lfn[i32_pos] = 0;
                }
/* plain ASCII is kept */
                else if (ui32_char < ASCII_END)
                {
/* an ASCII character */
                    ac_lfn[i32_pos] = (char)ui32_char;
                }
                else
                {
/* no font for anything else */
                    ac_lfn[i32_pos] = '?';
                }
            }
        }
    }
}

/* the readable 8.3 name of an entry: name, dot, extension, with the NT lower-case flags */
static void short_name(const uint8_t *pui8_entry, DIRENT *ps_entry)
{
/* local variables */
    char *pc_dst;
    char c_char;
    int32_t i32_index;

/* start values */
    pc_dst = ps_entry->ac_name;
    c_char = 0;
    i32_index = 0;
/* the name part ends at the first space */
    while ((i32_index < SNAME_NAME_LEN) && (pui8_entry[i32_index] != ' '))
    {
        c_char = (char)pui8_entry[i32_index];
/* a first byte 05 stands for the character E5 */
        if ((i32_index == 0) && (pui8_entry[0] == DIR_E5_ESCAPE))
        {
            c_char = (char)DIR_DELETED;
        }
/* stored in upper case, with a flag for lower case */
        if (((pui8_entry[DIR_NT_FLAGS_OFF] & NT_LOWER_NAME) != 0) && (c_char >= 'A') && (c_char <= 'Z'))
        {
            c_char += ASCII_CASE_OFFSET;
        }
/* into the name */
        *pc_dst = c_char;
        pc_dst++;
        i32_index++;
    }
/* the extension, if there is one */
    if (ps_entry->ac_ext[0] != 0)
    {
        *pc_dst = '.';
        pc_dst++;
/* its characters, with their own lower-case flag */
        for (i32_index = 0; ps_entry->ac_ext[i32_index] != 0; i32_index++)
        {
            c_char = ps_entry->ac_ext[i32_index];
/* lower case if flagged */
            if (((pui8_entry[DIR_NT_FLAGS_OFF] & NT_LOWER_EXT) != 0) && (c_char >= 'A') && (c_char <= 'Z'))
            {
                c_char += ASCII_CASE_OFFSET;
            }
/* into the name */
            *pc_dst = c_char;
            pc_dst++;
        }
    }
/* terminate the name */
    *pc_dst = 0;
}

/* a file or folder entry of a directory sector as a DIRENT */
static void entry_fill(const uint8_t *pui8_entry, DIRENT *ps_entry, const char ac_lfn[LFN_BUF_LEN], int32_t i32_has_lfn)
{
    int32_t i32_index;

    i32_index = 0;
/* the 8.3 name as stored */
    for (i32_index = 0; i32_index < FAT_NAME11_LEN; i32_index++)
    {
        ps_entry->ac_sname[i32_index] = (char)pui8_entry[i32_index];
    }
/* a first byte 05 stands for the character E5 */
    if (pui8_entry[0] == DIR_E5_ESCAPE)
    {
        ps_entry->ac_sname[0] = (char)DIR_DELETED;
    }
/* attribute and size */
    ps_entry->ui8_attr = pui8_entry[DIR_ATTR_OFF];
    ps_entry->ui32_size = rd32(pui8_entry + DIR_SIZE_OFF);
/* the first cluster: FAT32 has 16 more bits */
    ps_entry->ui32_clus = rd16(pui8_entry + DIR_CLUS_LOW_OFF);
    if (g_ui8_fat32 != 0)
    {
        ps_entry->ui32_clus |= rd16(pui8_entry + DIR_CLUS_HIGH_OFF) << SHIFT_WORD;
    }
/* the extension, without its padding */
    for (i32_index = 0; i32_index < SNAME_EXT_LEN; i32_index++)
    {
        ps_entry->ac_ext[i32_index] = (char)pui8_entry[DIR_EXT_OFF + i32_index];
    }
    ps_entry->ac_ext[SNAME_EXT_LEN] = 0;
/* trailing spaces become terminators */
    i32_index = EXT_LAST_INDEX;
    while ((i32_index >= 0) && (ps_entry->ac_ext[i32_index] == ' '))
    {
/* one space less */
        ps_entry->ac_ext[i32_index] = 0;
        i32_index--;
    }
/* the long name if the entry has one, else the 8.3 name */
    if ((i32_has_lfn != 0) && (ac_lfn[0] != 0))
    {
        u_strncpy(ps_entry->ac_name, ac_lfn, NAME_MAX);
    }
    else
    {
        short_name(pui8_entry, ps_entry);
    }
}

/* call cb for every entry of a directory; cluster 0 = root directory */
int32_t fat_list(uint32_t ui32_clus, dir_cb cb, void *p_ctx)
{
/* local variables */
    char ac_lfn[LFN_BUF_LEN];
    DIRENT s_entry;
    const uint8_t *pui8_entry;
/* long name seen, entry index, sector index */
    int32_t i32_has_lfn;
    int32_t i32_index;
    uint32_t ui32_sec;
/* the sector's address, fixed root or chain */
    uint32_t ui32_lba;
    bool b_fixed;
/* the end of the scan, the result */
    bool b_done;
    int32_t i32_result;

/* start values */
    pui8_entry = g_aui8_secbuf;
    i32_has_lfn = 0;
    i32_index = 0;
/* sector 0 first */
    ui32_sec = 0;
    ui32_lba = 0;
/* the root directory of FAT16 is a fixed area, every other directory a cluster chain */
    b_fixed = (ui32_clus == 0) && (g_ui8_fat32 == 0);
    b_done = false;
    i32_result = FAT_OK;
/* FAT32: the root is a chain like any other */
    if ((ui32_clus == 0) && (g_ui8_fat32 != 0))
    {
        ui32_clus = g_ui32_root_clus;
    }
/* sector by sector */
    while (!b_done)
    {
/* where the next sector is, or the end of the directory's area */
        if (b_fixed)
        {
            if (ui32_sec >= g_ui32_root_secs)
            {
                b_done = true;
            }
            else
            {
/* the next sector of the area */
                ui32_lba = g_ui32_root_lba + ui32_sec;
            }
        }
        else
        {
/* at a cluster's end the chain goes on */
            if ((ui32_sec != 0) && ((ui32_sec & (g_ui32_spc - ONE)) == 0))
            {
                ui32_clus = fat_next(ui32_clus);
/* the chain ended */
                if (ui32_clus == 0)
                {
                    b_done = true;
                }
            }
/* a cluster number outside the volume ends the directory too */
            if (!b_done)
            {
                if (clus_end(ui32_clus))
                {
                    b_done = true;
                }
                else
                {
/* the sector inside the cluster */
                    ui32_lba = clus_lba(ui32_clus) + (ui32_sec & (g_ui32_spc - ONE));
                }
            }
        }
/* the sector's 16 entries */
        if (!b_done)
        {
            if (sd_read(ui32_lba, g_aui8_secbuf) != 0)
            {
/* the card failed */
                i32_result = FAT_EIO;
                b_done = true;
            }
/* entry by entry, until the end of the directory or the callback stops the scan */
            for (i32_index = 0; (i32_index < DIR_ENTRIES_PER_SEC) && !b_done; i32_index++)
            {
                pui8_entry = g_aui8_secbuf + (DIR_ENTRY_LEN * i32_index);
                if (pui8_entry[0] == DIR_END)
                {
/* end of directory */
                    b_done = true;
                }
                else if (pui8_entry[0] == DIR_DELETED)
                {
/* a deleted entry: a long name before it is not valid */
                    i32_has_lfn = 0;
                }
                else if (pui8_entry[DIR_ATTR_OFF] == DIR_ATTR_LONG_NAME)
                {
/* long-name part */
                    lfn_part(pui8_entry, ac_lfn, &i32_has_lfn);
                }
                else if ((pui8_entry[DIR_ATTR_OFF] & DIR_ATTR_VOLUME) != 0)
                {
/* volume label */
                    i32_has_lfn = 0;
                }
                else
                {
/* a file or a folder */
                    entry_fill(pui8_entry, &s_entry, ac_lfn, i32_has_lfn);
                    i32_has_lfn = 0;
/* fat_delete finds the entry here */
                    g_ui32_ent_lba = ui32_lba;
                    g_i32_ent_idx = i32_index;
/* the callback may end the scan */
                    if (cb(&s_entry, p_ctx) != 0)
                    {
                        b_done = true;
                    }
                }
            }
/* the next sector */
            ui32_sec++;
        }
    }
    return i32_result;
}

/* start reading a file */
void ff_open(FFILE *ps_file, uint32_t ui32_clus, uint32_t ui32_size)
{
    ps_file->ui32_first = ui32_clus;
    ps_file->ui32_size = ui32_size;
/* at its start */
    ps_file->ui32_pos = 0;
    ps_file->ui32_clus = ui32_clus;
    ps_file->ui32_cidx = 0;
/* no sector in the buffer */
    ps_file->ui32_lba = LBA_NONE;
}

/* next byte, or FF_EOF at the end or on a read error */
int32_t ff_getc(FFILE *ps_file)
{
/* local variables */
    uint32_t ui32_sec;
    uint32_t ui32_cidx;
    uint32_t ui32_lba;
/* success so far, the result */
    bool b_ok;
    int32_t i32_result;

/* start values */
    ui32_sec = ps_file->ui32_pos >> SECTOR_SHIFT;
    ui32_cidx = ui32_sec >> g_ui8_spc_shift;
    ui32_lba = 0;
/* nothing to read behind the end */
    b_ok = ps_file->ui32_pos < ps_file->ui32_size;
    i32_result = FF_EOF;
    if (b_ok)
    {
/* a position before the current cluster: follow the chain from its start */
        if (ui32_cidx < ps_file->ui32_cidx)
        {
            ps_file->ui32_clus = ps_file->ui32_first;
            ps_file->ui32_cidx = 0;
        }
/* follow the chain to the position's cluster */
        while ((ps_file->ui32_cidx < ui32_cidx) && b_ok)
        {
            ps_file->ui32_clus = fat_next(ps_file->ui32_clus);
/* a chain shorter than the file's size */
            if (ps_file->ui32_clus == 0)
            {
/* start over next time */
                ps_file->ui32_cidx = 0;
                ps_file->ui32_clus = ps_file->ui32_first;
                b_ok = false;
            }
            else
            {
/* one cluster further */
                ps_file->ui32_cidx++;
            }
        }
    }
/* the cluster must be inside the volume */
    if (b_ok && clus_end(ps_file->ui32_clus))
    {
        b_ok = false;
    }
/* the position's sector into the file's buffer */
    if (b_ok)
    {
        ui32_lba = clus_lba(ps_file->ui32_clus) + (ui32_sec & (g_ui32_spc - ONE));
        if (ui32_lba != ps_file->ui32_lba)
        {
/* a failed read leaves the buffer invalid */
            if (sd_read(ui32_lba, ps_file->aui8_buf) != 0)
            {
                ps_file->ui32_lba = LBA_NONE;
                b_ok = false;
            }
            else
            {
/* the buffer holds this sector */
                ps_file->ui32_lba = ui32_lba;
            }
        }
    }
/* the byte, and on to the next */
    if (b_ok)
    {
        i32_result = ps_file->aui8_buf[ps_file->ui32_pos & SECTOR_MASK];
        ps_file->ui32_pos++;
    }
/* the byte, or FF_EOF */
    return i32_result;
}

/* set the read position */
void ff_seek(FFILE *ps_file, uint32_t ui32_pos)
{
    ps_file->ui32_pos = ui32_pos;
}

/* the read position */
uint32_t ff_tell(const FFILE *ps_file)
{
/* local variables */
    uint32_t ui32_pos;

    ui32_pos = ps_file->ui32_pos;
    return ui32_pos;
}

/* overwrite bytes of an existing file at a position, inside one 512-byte sector (the */
/* L64 drive's .d64 sectors); the file size does not change */
int32_t ff_update(FFILE *ps_file, uint32_t ui32_pos, const uint8_t *pui8_data, uint32_t ui32_count)
{
/* local variables */
    uint32_t ui32_index;
    int32_t i32_result;

/* start values */
    ui32_index = 0;
    i32_result = FAT_EIO;
/* inside the file and inside one sector */
    if ((ui32_count != 0) && ((ui32_pos + ui32_count) <= ps_file->ui32_size) &&
        (((ui32_pos & SECTOR_MASK) + ui32_count) <= FAT_SECTOR_SIZE))
    {
        ps_file->ui32_pos = ui32_pos;
/* reading one byte brings the sector into the file's buffer */
        if (ff_getc(ps_file) >= 0)
        {
            for (ui32_index = 0; ui32_index < ui32_count; ui32_index++)
            {
                ps_file->aui8_buf[(ui32_pos & SECTOR_MASK) + ui32_index] = pui8_data[ui32_index];
            }
/* and back to the card */
            if (sd_write(ps_file->ui32_lba, ps_file->aui8_buf) == 0)
            {
                i32_result = FAT_OK;
            }
        }
    }
    return i32_result;
}

/* writing */

/* a free cluster, marked end-of-chain and linked after ui32_prev (0: none); 0 = full or error */
static uint32_t fat_alloc(uint32_t ui32_prev)
{
/* local variables */
    uint32_t ui32_clus;
    uint32_t ui32_start;
    uint32_t ui32_entry;
/* the end-of-chain mark, success so far, found */
    uint32_t ui32_end_mark;
    bool b_ok;
    bool b_found;

/* start values */
    ui32_clus = g_ui32_free_hint;
    ui32_start = 0;
    ui32_entry = 0;
/* the end-of-chain mark of the file system */
    ui32_end_mark = FAT16_END_OF_CHAIN;
    if (g_ui8_fat32 != 0)
    {
        ui32_end_mark = FAT32_END_OF_CHAIN;
    }
/* nothing failed, nothing found yet */
    b_ok = true;
    b_found = false;
/* before the first allocation the FSInfo free count becomes "unknown" */
    if ((g_ui32_fsinfo_lba != 0) && (g_ui8_fsinfo_done == 0))
    {
        if (sd_read(g_ui32_fsinfo_lba, g_aui8_secbuf) != 0)
        {
            b_ok = false;
        }
        else
        {
/* free count unknown */
            wr32(g_aui8_secbuf + FSI_FREE_COUNT_OFF, FSI_FREE_UNKNOWN);
/* done once per mount */
            if (sd_write(g_ui32_fsinfo_lba, g_aui8_secbuf) != 0)
            {
                b_ok = false;
            }
            else
            {
                g_ui8_fsinfo_done = YES;
            }
        }
    }
/* search from the hint, once around the FAT */
    if (b_ok)
    {
        if ((ui32_clus < CLUS_FIRST) || (ui32_clus > g_ui32_max_clus))
        {
            ui32_clus = CLUS_FIRST;
        }
/* where the search began */
        ui32_start = ui32_clus;
/* a free cluster has entry 0 */
        while (b_ok && !b_found)
        {
            ui32_entry = fat_get(ui32_clus);
/* the card failed */
            if (ui32_entry == FAT_GET_ERROR)
            {
                b_ok = false;
            }
            else if (ui32_entry == 0)
            {
/* free */
                b_found = true;
            }
            else
            {
/* taken: the next one, wrapping at the end */
                ui32_clus++;
                if (ui32_clus > g_ui32_max_clus)
                {
                    ui32_clus = CLUS_FIRST;
                }
/* back at the start: card full */
                if (ui32_clus == ui32_start)
                {
                    b_ok = false;
                }
            }
        }
    }
/* mark it as the end of a chain */
    if (b_ok)
    {
        if (fat_set(ui32_clus, ui32_end_mark) != FAT_OK)
        {
            b_ok = false;
        }
    }
/* and link it after the previous cluster */
    if (b_ok && (ui32_prev != 0))
    {
        if (fat_set(ui32_prev, ui32_clus) != FAT_OK)
        {
            b_ok = false;
        }
    }
/* the next search starts behind it */
    if (b_ok)
    {
        g_ui32_free_hint = ui32_clus + ONE;
    }
    else
    {
/* 0 = no cluster */
        ui32_clus = 0;
    }
    return ui32_clus;
}

/* what the name search looks for, and whether it was found */
struct find_ctx
{
    char ac_name[FAT_NAME11_LEN];
    int32_t i32_hit;
};

/* directory callback: stop at the entry with the wanted 8.3 name */
static int32_t find_cb(const DIRENT *ps_entry, void *p_ctx)
{
/* local variables */
    struct find_ctx *ps_find;
    int32_t i32_stop;

/* start values */
    ps_find = (struct find_ctx *)p_ctx;
    i32_stop = 0;
/* the stored names are compared */
    if (u_memcmp(ps_entry->ac_sname, ps_find->ac_name, FAT_NAME11_LEN) == 0)
    {
        ps_find->i32_hit = YES;
        i32_stop = YES;
    }
/* non-zero ends the scan */
    return i32_stop;
}

/* 1 = an entry with this 8.3 name exists, 0 = not, below 0 = error */
int32_t fat_exists(uint32_t ui32_dir, const char ac_name11[FAT_NAME11_LEN])
{
/* local variables */
    struct find_ctx s_find;
    int32_t i32_result;

/* what to look for */
    u_memcpy(s_find.ac_name, ac_name11, FAT_NAME11_LEN);
    s_find.i32_hit = 0;
/* scan the directory */
    i32_result = fat_list(ui32_dir, find_cb, &s_find);
    if (i32_result == FAT_OK)
    {
/* found or not */
        i32_result = s_find.i32_hit;
    }
    return i32_result;
}

/* delete the file with this 8.3 name: its clusters are freed, its entry (and the long-name */
/* parts before it in the same sector) marked deleted. FAT_OK (also when there is no such file) */
int32_t fat_delete(uint32_t ui32_dir, const char ac_name11[FAT_NAME11_LEN])
{
/* local variables */
    struct find_ctx s_find;
    uint32_t ui32_clus;
    uint32_t ui32_next;
/* the entry's sector and index, the result */
    uint32_t ui32_lba;
    int32_t i32_entry;
    int32_t i32_result;

/* start values */
    ui32_clus = 0;
    ui32_next = 0;
/* nowhere yet */
    ui32_lba = 0;
    i32_entry = 0;
/* find the entry */
    u_memcpy(s_find.ac_name, ac_name11, FAT_NAME11_LEN);
    s_find.i32_hit = 0;
    i32_result = fat_list(ui32_dir, find_cb, &s_find);
/* nothing to do if there is no such file */
    if ((i32_result == FAT_OK) && (s_find.i32_hit != 0))
    {
/* fat_list left the place of the entry */
        ui32_lba = g_ui32_ent_lba;
        i32_entry = g_i32_ent_idx;
/* its sector */
        if (sd_read(ui32_lba, g_aui8_secbuf) != 0)
        {
            i32_result = FAT_EIO;
        }
/* free the chain */
        if (i32_result == FAT_OK)
        {
            ui32_clus = rd16(g_aui8_secbuf + (DIR_ENTRY_LEN * i32_entry) + DIR_CLUS_LOW_OFF);
/* FAT32 has 16 more bits */
            if (g_ui8_fat32 != 0)
            {
                ui32_clus |= rd16(g_aui8_secbuf + (DIR_ENTRY_LEN * i32_entry) + DIR_CLUS_HIGH_OFF) << SHIFT_WORD;
            }
/* free every cluster of the chain */
            while ((ui32_clus >= CLUS_FIRST) && !clus_end(ui32_clus) && (i32_result == FAT_OK))
            {
                ui32_next = fat_next(ui32_clus);
/* entry 0 = free */
                if (fat_set(ui32_clus, 0) != FAT_OK)
                {
                    i32_result = FAT_EIO;
                }
                ui32_clus = ui32_next;
            }
        }
/* the FAT goes to the card before the directory */
        if ((i32_result == FAT_OK) && (fat_flush() != FAT_OK))
        {
            i32_result = FAT_EIO;
        }
/* the directory sector again: the FAT work used the buffer */
        if ((i32_result == FAT_OK) && (sd_read(ui32_lba, g_aui8_secbuf) != 0))
        {
            i32_result = FAT_EIO;
        }
/* mark the entry and its long-name parts deleted */
        if (i32_result == FAT_OK)
        {
            g_aui8_secbuf[DIR_ENTRY_LEN * i32_entry] = DIR_DELETED;
            i32_entry--;
/* the long-name parts are the entries just before it */
            while ((i32_entry >= 0) &&
                   (g_aui8_secbuf[(DIR_ENTRY_LEN * i32_entry) + DIR_ATTR_OFF] == DIR_ATTR_LONG_NAME) &&
                   (g_aui8_secbuf[DIR_ENTRY_LEN * i32_entry] != DIR_DELETED))
            {
                g_aui8_secbuf[DIR_ENTRY_LEN * i32_entry] = DIR_DELETED;
                i32_entry--;
            }
/* and the sector back to the card */
            if (sd_write(ui32_lba, g_aui8_secbuf) != 0)
            {
                i32_result = FAT_EIO;
            }
        }
    }
    return i32_result;
}

/* sector of the file's sector index, allocating clusters at the end when needed; 0 = full or error */
static uint32_t file_lba(FWFILE *ps_file, uint32_t ui32_sidx)
{
/* local variables */
    uint32_t ui32_cidx;
    uint32_t ui32_clus;
    uint32_t ui32_step;
/* the sector's address, success so far */
    uint32_t ui32_lba;
    bool b_ok;

/* start values */
    ui32_cidx = ui32_sidx >> g_ui8_spc_shift;
    ui32_clus = 0;
    ui32_step = 0;
/* nothing found yet */
    ui32_lba = 0;
    b_ok = true;
/* make the chain long enough */
    while ((ui32_cidx >= ps_file->ui32_ncl) && b_ok)
    {
        ui32_clus = fat_alloc(ps_file->ui32_last);
/* the card is full */
        if (ui32_clus == 0)
        {
            b_ok = false;
        }
        else
        {
/* the first cluster of the file is remembered for its directory entry */
            if (ps_file->ui32_first == 0)
            {
                ps_file->ui32_first = ui32_clus;
            }
/* the chain is one longer */
            ps_file->ui32_last = ui32_clus;
            ps_file->ui32_ncl++;
        }
    }
/* the cluster of that index: the last one, or by following the chain */
    if (b_ok)
    {
        if (ui32_cidx == (ps_file->ui32_ncl - ONE))
        {
            ui32_clus = ps_file->ui32_last;
        }
        else
        {
/* from the first cluster on */
            ui32_clus = ps_file->ui32_first;
/* a broken chain gives 0 */
            for (ui32_step = 0; (ui32_step < ui32_cidx) && (ui32_clus != 0); ui32_step++)
            {
                ui32_clus = fat_next(ui32_clus);
            }
        }
/* the sector inside the cluster */
        if (ui32_clus != 0)
        {
            ui32_lba = clus_lba(ui32_clus) + (ui32_sidx & (g_ui32_spc - ONE));
        }
    }
    return ui32_lba;
}

/* create an empty file for writing: FAT_OK, FAT_EFULL, FAT_EIO */
int32_t fw_create(FWFILE *ps_file, uint32_t ui32_dir, const char ac_name11[FAT_NAME11_LEN])
{
/* local variables */
    uint32_t ui32_clus;
    uint32_t ui32_prev;
    uint32_t ui32_sec;
/* the sector's address, a loop counter, fixed root or chain */
    uint32_t ui32_lba;
    uint32_t ui32_index;
    bool b_fixed;
/* the end of the search, the free entry, the result */
    bool b_done;
    int32_t i32_entry;
    int32_t i32_result;

/* start values */
    ui32_clus = ui32_dir;
    ui32_prev = 0;
    ui32_sec = 0;
/* nothing read yet */
    ui32_lba = 0;
    ui32_index = 0;
/* the root directory of FAT16 is a fixed area, every other directory a cluster chain */
    b_fixed = (ui32_dir == 0) && (g_ui8_fat32 == 0);
    b_done = false;
    i32_entry = DIR_NO_ENTRY;
/* no error; FAT32's root is a chain like any other */
    i32_result = FAT_OK;
    if ((ui32_dir == 0) && (g_ui8_fat32 != 0))
    {
        ui32_clus = g_ui32_root_clus;
    }
/* first free directory entry (0x00 = never used, 0xE5 = deleted) */
    while (!b_done)
    {
        if (b_fixed)
        {
/* a full root directory cannot grow */
            if (ui32_sec >= g_ui32_root_secs)
            {
                i32_result = FAT_EFULL;
                b_done = true;
            }
            else
            {
/* the next sector of the area */
                ui32_lba = g_ui32_root_lba + ui32_sec;
            }
        }
        else
        {
/* at a cluster's end the chain goes on */
            if ((ui32_sec != 0) && ((ui32_sec & (g_ui32_spc - ONE)) == 0))
            {
                ui32_prev = ui32_clus;
                ui32_clus = fat_next(ui32_clus);
/* directory full: add a zeroed cluster */
                if (ui32_clus == 0)
                {
                    ui32_clus = fat_alloc(ui32_prev);
/* the card is full */
                    if (ui32_clus == 0)
                    {
                        i32_result = FAT_EFULL;
                        b_done = true;
                    }
                    else
                    {
/* zeros for the new cluster */
                        u_memset(g_aui8_secbuf, 0, FAT_SECTOR_SIZE);
/* every sector of the new cluster */
                        for (ui32_index = 0; (ui32_index < g_ui32_spc) && !b_done; ui32_index++)
                        {
                            if (sd_write(clus_lba(ui32_clus) + ui32_index, g_aui8_secbuf) != 0)
                            {
/* the card failed */
                                i32_result = FAT_EIO;
                                b_done = true;
                            }
                        }
                    }
                }
            }
/* the sector inside the cluster */
            if (!b_done)
            {
                ui32_lba = clus_lba(ui32_clus) + (ui32_sec & (g_ui32_spc - ONE));
            }
        }
/* look for a free entry in the sector */
        if (!b_done)
        {
            if (sd_read(ui32_lba, g_aui8_secbuf) != 0)
            {
/* the card failed */
                i32_result = FAT_EIO;
                b_done = true;
            }
/* the first free one is taken */
            for (ui32_index = 0; (ui32_index < DIR_ENTRIES_PER_SEC) && !b_done; ui32_index++)
            {
                if ((g_aui8_secbuf[DIR_ENTRY_LEN * ui32_index] == DIR_END) ||
                    (g_aui8_secbuf[DIR_ENTRY_LEN * ui32_index] == DIR_DELETED))
                {
/* this one */
                    i32_entry = (int32_t)ui32_index;
                    b_done = true;
                }
            }
/* the next sector */
            ui32_sec++;
        }
    }
/* write the entry: the name, the archive attribute, everything else 0 */
    if (i32_result == FAT_OK)
    {
        u_memset(g_aui8_secbuf + (DIR_ENTRY_LEN * i32_entry), 0, DIR_ENTRY_LEN);
/* the 8.3 name, the attribute */
        u_memcpy(g_aui8_secbuf + (DIR_ENTRY_LEN * i32_entry), ac_name11, FAT_NAME11_LEN);
        g_aui8_secbuf[(DIR_ENTRY_LEN * i32_entry) + DIR_ATTR_OFF] = DIR_ATTR_ARCHIVE;
/* the directory sector, then the FAT (a new directory cluster) */
        if (sd_write(ui32_lba, g_aui8_secbuf) != 0)
        {
            i32_result = FAT_EIO;
        }
/* the FAT */
        else if (fat_flush() != FAT_OK)
        {
            i32_result = FAT_EIO;
        }
        else
        {
/* an empty file; its entry is filled in when it is closed */
            ps_file->ui32_first = 0;
            ps_file->ui32_last = 0;
/* no clusters, no bytes */
            ps_file->ui32_ncl = 0;
            ps_file->ui32_size = 0;
/* where the entry is */
            ps_file->ui32_dir_lba = ui32_lba;
            ps_file->ui32_dir_off = DIR_ENTRY_LEN * (uint32_t)i32_entry;
        }
    }
    return i32_result;
}

/* append one byte: FAT_OK, FAT_EFULL, FAT_EIO */
int32_t fw_putc(FWFILE *ps_file, uint8_t ui8_byte)
{
/* local variables */
    uint32_t ui32_lba;
    int32_t i32_result;

/* start values */
    ui32_lba = 0;
    i32_result = FAT_OK;
/* into the sector being filled */
    ps_file->aui8_buf[ps_file->ui32_size & SECTOR_MASK] = ui8_byte;
    ps_file->ui32_size++;
/* a full sector: write it */
    if ((ps_file->ui32_size & SECTOR_MASK) == 0)
    {
        ui32_lba = file_lba(ps_file, (ps_file->ui32_size - ONE) >> SECTOR_SHIFT);
        if (ui32_lba == 0)
        {
/* no room on the card */
            i32_result = FAT_EFULL;
        }
        else if (sd_write(ui32_lba, ps_file->aui8_buf) != 0)
        {
/* the card did not take the sector */
            i32_result = FAT_EIO;
        }
        else
        {
/* written */
        }
    }
    return i32_result;
}

/* change a byte already written; a position behind the end is ignored */
int32_t fw_patch(FWFILE *ps_file, uint32_t ui32_pos, uint8_t ui8_byte)
{
/* local variables */
    uint32_t ui32_lba;
    int32_t i32_result;

/* start values */
    ui32_lba = 0;
    i32_result = FAT_OK;
/* only inside the file */
    if (ui32_pos < ps_file->ui32_size)
    {
        if ((ui32_pos >> SECTOR_SHIFT) == (ps_file->ui32_size >> SECTOR_SHIFT))
        {
/* still in the buffer */
            ps_file->aui8_buf[ui32_pos & SECTOR_MASK] = ui8_byte;
        }
        else
        {
/* already on the card: read the sector, change it, write it */
            ui32_lba = file_lba(ps_file, ui32_pos >> SECTOR_SHIFT);
            if ((ui32_lba == 0) || (sd_read(ui32_lba, g_aui8_secbuf) != 0))
            {
                i32_result = FAT_EIO;
            }
            else
            {
/* the byte, changed in the sector */
                g_aui8_secbuf[ui32_pos & SECTOR_MASK] = ui8_byte;
/* back to the card */
                if (sd_write(ui32_lba, g_aui8_secbuf) != 0)
                {
                    i32_result = FAT_EIO;
                }
            }
        }
    }
    return i32_result;
}

/* write the last sector, the FAT and the directory entry */
int32_t fw_close(FWFILE *ps_file)
{
/* local variables */
    uint32_t ui32_lba;
    uint32_t ui32_used;
/* the directory entry, the result */
    uint8_t *pui8_entry;
    int32_t i32_result;

    ui32_lba = 0;
/* bytes in the sector being filled */
    ui32_used = ps_file->ui32_size & SECTOR_MASK;
    pui8_entry = g_aui8_secbuf;
    i32_result = FAT_OK;
/* last, partial sector: padded with zeros */
    if (ui32_used != 0)
    {
        u_memset(ps_file->aui8_buf + ui32_used, 0, FAT_SECTOR_SIZE - ui32_used);
        ui32_lba = file_lba(ps_file, ps_file->ui32_size >> SECTOR_SHIFT);
/* no cluster, or the card did not take the sector */
        if ((ui32_lba == 0) || (sd_write(ui32_lba, ps_file->aui8_buf) != 0))
        {
            i32_result = FAT_EIO;
        }
    }
/* the FAT */
    if ((i32_result == FAT_OK) && (fat_flush() != FAT_OK))
    {
        i32_result = FAT_EIO;
    }
/* the directory entry: first cluster and size */
    if ((i32_result == FAT_OK) && (sd_read(ps_file->ui32_dir_lba, g_aui8_secbuf) != 0))
    {
        i32_result = FAT_EIO;
    }
/* fill it in */
    if (i32_result == FAT_OK)
    {
        pui8_entry = g_aui8_secbuf + ps_file->ui32_dir_off;
/* the cluster number in two halves */
        wr16(pui8_entry + DIR_CLUS_HIGH_OFF, ps_file->ui32_first >> SHIFT_WORD);
        wr16(pui8_entry + DIR_CLUS_LOW_OFF, ps_file->ui32_first);
        wr32(pui8_entry + DIR_SIZE_OFF, ps_file->ui32_size);
/* back to the card */
        if (sd_write(ps_file->ui32_dir_lba, g_aui8_secbuf) != 0)
        {
            i32_result = FAT_EIO;
        }
    }
    return i32_result;
}

/* delete the file being written: its clusters are freed, its entry marked deleted */
int32_t fw_discard(FWFILE *ps_file)
{
/* local variables */
    uint32_t ui32_clus;
    uint32_t ui32_next;
    int32_t i32_result;

/* start values */
    ui32_clus = ps_file->ui32_first;
    ui32_next = 0;
    i32_result = FAT_OK;
/* free the chain */
    while ((ui32_clus != 0) && (i32_result == FAT_OK))
    {
        ui32_next = fat_next(ui32_clus);
/* entry 0 = free */
        if (fat_set(ui32_clus, 0) != FAT_OK)
        {
            i32_result = FAT_EIO;
        }
        ui32_clus = ui32_next;
    }
/* the FAT goes to the card before the directory */
    if ((i32_result == FAT_OK) && (fat_flush() != FAT_OK))
    {
        i32_result = FAT_EIO;
    }
/* the directory sector */
    if ((i32_result == FAT_OK) && (sd_read(ps_file->ui32_dir_lba, g_aui8_secbuf) != 0))
    {
        i32_result = FAT_EIO;
    }
/* entry deleted */
    if (i32_result == FAT_OK)
    {
        g_aui8_secbuf[ps_file->ui32_dir_off] = DIR_DELETED;
/* written back */
        if (sd_write(ps_file->ui32_dir_lba, g_aui8_secbuf) != 0)
        {
            i32_result = FAT_EIO;
        }
    }
    return i32_result;
}

/* back to the state after a start: the next machine starts the loader again without an ESP32 */
/* restart (esp_hw.cpp; the Bluetooth connection stays) */
void fat_reset(void)
{
    u_memset(g_aui8_secbuf, 0, sizeof g_aui8_secbuf);
    u_memset(g_aui8_fatbuf, 0, sizeof g_aui8_fatbuf);
/* the volume's description */
    g_ui32_fatbuf_lba = 0;
    g_ui8_fat32 = 0;
/* cluster size, number of FATs */
    g_ui8_spc_shift = 0;
    g_ui8_nfats = 0;
/* the cache flags */
    g_ui8_fat_dirty = 0;
    g_ui8_fsinfo_done = 0;
    g_ui32_spc = 0;
/* the areas */
    g_ui32_fat_lba = 0;
    g_ui32_root_lba = 0;
/* the FAT16 root's size, the data area */
    g_ui32_root_secs = 0;
    g_ui32_data_lba = 0;
/* the clusters */
    g_ui32_root_clus = 0;
    g_ui32_max_clus = 0;
    g_ui32_fatsz = 0;
/* the free-cluster search */
    g_ui32_fsinfo_lba = 0;
    g_ui32_free_hint = 0;
/* the last listed entry */
    g_ui32_ent_lba = 0;
    g_i32_ent_idx = 0;
}
