/* fat.h -- FAT16 / FAT32 (MBR-partitioned or unpartitioned card, 512-byte sectors): reading,
 * and creating new files with 8.3 names (for saving) */
#ifndef FAT_H
#define FAT_H

#include <stdint.h>

#define FAT_OK      0
#define FAT_EIO    -1       /* card read error */
#define FAT_ENOFS  -2       /* no FAT16/FAT32 file system (FAT12, exFAT, NTFS, unformatted) */
#define FAT_EFULL  -3       /* card or (FAT16) root directory full */

#define NAME_MAX    29      /* characters kept from a (long) file name */

#define ATTR_RO     0x01
#define ATTR_HIDDEN 0x02
#define ATTR_SYSTEM 0x04
#define ATTR_DIR    0x10

typedef struct {
    uint32_t clus;          /* first cluster (0: empty file, or the root directory for "..") */
    uint32_t size;
    uint8_t  attr;
    char     ext[4];        /* 8.3 extension, upper case */
    char     sname[11];     /* 8.3 name as stored (8 + 3, space padded) */
    char     name[NAME_MAX + 1];
} DIRENT;

/* Called for every directory entry; return non-zero to stop the scan. */
typedef int (*dir_cb)(const DIRENT *e, void *ctx);

typedef struct {
    uint32_t first, size, pos;
    uint32_t clus, cidx;    /* current cluster and its index in the chain */
    uint32_t lba;           /* sector in buf (0xFFFFFFFF: none) */
    uint8_t  buf[512];
} FFILE;

/* a file being written (created by fw_create, finished by fw_close) */
typedef struct {
    uint32_t first, last, ncl;  /* first / last cluster, clusters in the chain */
    uint32_t size;              /* bytes written */
    uint32_t dir_lba;           /* sector and offset of the directory entry */
    uint32_t dir_off;
    uint8_t  buf[512];          /* sector being filled */
} FWFILE;

int      fat_mount(void);
int      fat_is_fat32(void);
int      fat_list(uint32_t dir_clus, dir_cb cb, void *ctx);   /* dir_clus 0 = root directory */
void     ff_open(FFILE *f, uint32_t clus, uint32_t size);
int      ff_getc(FFILE *f);                                    /* -1 at the end or on a read error */
void     ff_seek(FFILE *f, uint32_t pos);
uint32_t ff_tell(const FFILE *f);
int      ff_update(FFILE *f, uint32_t pos, const uint8_t *d, uint32_t n);   /* overwrite inside one sector */

int      fat_exists(uint32_t dir_clus, const char name11[11]);
int      fat_delete(uint32_t dir_clus, const char name11[11]);    /* FAT_OK also if there is no such file */
int      fw_create(FWFILE *w, uint32_t dir_clus, const char name11[11]);
int      fw_putc(FWFILE *w, uint8_t b);
int      fw_patch(FWFILE *w, uint32_t pos, uint8_t b);      /* change a byte already written */
int      fw_close(FWFILE *w);
int      fw_discard(FWFILE *w);                             /* delete the file being written */

/* the file being written: a tape recording (save.c) or a snapshot (snap.c), never both */
extern FWFILE fw_file;

#endif
