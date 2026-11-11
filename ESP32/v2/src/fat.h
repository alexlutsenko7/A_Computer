/* fat.h -- FAT16 / FAT32 (MBR-partitioned or unpartitioned card, 512-byte sectors): reading, */
/* and creating new files with 8.3 names (for saving) */
#ifndef FAT_H
#define FAT_H

/* the headers this one needs */
#include <stdint.h>
#include <stdbool.h>

/* results */
#define FAT_OK 0
/* card read or write error */
#define FAT_EIO (-1)
/* no FAT16/FAT32 file system (FAT12, exFAT, NTFS, unformatted) */
#define FAT_ENOFS (-2)
/* card or (FAT16) root directory full */
#define FAT_EFULL (-3)
/* ff_getc: the end of the file, or a read error */
#define FF_EOF (-1)

/* characters kept from a (long) file name */
#define NAME_MAX 29
/* a name with its terminator */
#define NAME_BUF_LEN 30
/* an 8.3 name as stored: 8 + 3 characters, space padded, no dot */
#define FAT_NAME11_LEN 11
/* an 8.3 extension with its terminator */
#define FAT_EXT_BUF_LEN 4
/* bytes of one sector */
#define FAT_SECTOR_SIZE 512

/* attribute bits of a directory entry */
#define ATTR_RO 0x01
#define ATTR_HIDDEN 0x02
#define ATTR_SYSTEM 0x04
/* a folder */
#define ATTR_DIR 0x10

/* one directory entry, as fat_list passes it to the callback */
typedef struct
{
/* first cluster (0: empty file, or the root directory for "..") */
    uint32_t ui32_clus;
/* length in bytes */
    uint32_t ui32_size;
/* ATTR_* bits */
    uint8_t ui8_attr;
/* 8.3 extension, upper case */
    char ac_ext[FAT_EXT_BUF_LEN];
/* 8.3 name as stored (8 + 3, space padded) */
    char ac_sname[FAT_NAME11_LEN];
/* the long name, or the 8.3 name with its dot */
    char ac_name[NAME_BUF_LEN];
} DIRENT;

/* Called for every directory entry; return non-zero to stop the scan. */
typedef int32_t (*dir_cb)(const DIRENT *ps_entry, void *p_ctx);

/* a file being read */
typedef struct
{
/* first cluster, length, read position */
    uint32_t ui32_first;
    uint32_t ui32_size;
    uint32_t ui32_pos;
/* current cluster and its index in the chain */
    uint32_t ui32_clus;
    uint32_t ui32_cidx;
/* sector in the buffer (0xFFFFFFFF: none) */
    uint32_t ui32_lba;
    uint8_t aui8_buf[FAT_SECTOR_SIZE];
} FFILE;

/* a file being written (created by fw_create, finished by fw_close) */
typedef struct
{
/* first / last cluster, clusters in the chain */
    uint32_t ui32_first;
    uint32_t ui32_last;
    uint32_t ui32_ncl;
/* bytes written */
    uint32_t ui32_size;
/* sector and offset of the directory entry */
    uint32_t ui32_dir_lba;
    uint32_t ui32_dir_off;
/* sector being filled */
    uint8_t aui8_buf[FAT_SECTOR_SIZE];
} FWFILE;

/* find the file system on the card: FAT_OK, FAT_EIO, FAT_ENOFS */
int32_t fat_mount(void);
/* 1 = the mounted file system is FAT32 */
int32_t fat_is_fat32(void);
/* call cb for every entry of a directory; cluster 0 = root directory */
int32_t fat_list(uint32_t ui32_dir_clus, dir_cb cb, void *p_ctx);
/* start reading a file */
void ff_open(FFILE *ps_file, uint32_t ui32_clus, uint32_t ui32_size);
/* next byte, or FF_EOF at the end or on a read error */
int32_t ff_getc(FFILE *ps_file);
/* set the read position */
void ff_seek(FFILE *ps_file, uint32_t ui32_pos);
/* the read position */
uint32_t ff_tell(const FFILE *ps_file);
/* overwrite bytes of an existing file, inside one sector */
int32_t ff_update(FFILE *ps_file, uint32_t ui32_pos, const uint8_t *pui8_data, uint32_t ui32_count);

/* 1 = an entry with this 8.3 name exists, 0 = not, below 0 = error */
int32_t fat_exists(uint32_t ui32_dir_clus, const char ac_name11[FAT_NAME11_LEN]);
/* delete a file; FAT_OK also if there is no such file */
int32_t fat_delete(uint32_t ui32_dir_clus, const char ac_name11[FAT_NAME11_LEN]);
/* create an empty file for writing */
int32_t fw_create(FWFILE *ps_file, uint32_t ui32_dir_clus, const char ac_name11[FAT_NAME11_LEN]);
/* append one byte */
int32_t fw_putc(FWFILE *ps_file, uint8_t ui8_byte);
/* change a byte already written */
int32_t fw_patch(FWFILE *ps_file, uint32_t ui32_pos, uint8_t ui8_byte);
/* write the last sector and the directory entry */
int32_t fw_close(FWFILE *ps_file);
/* delete the file being written */
int32_t fw_discard(FWFILE *ps_file);

/* the file being written: a tape recording (save.c) or a snapshot (snap.c), never both */
extern FWFILE g_s_fw_file;

#endif
