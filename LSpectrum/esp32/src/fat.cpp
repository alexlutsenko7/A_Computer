/* fat.c -- FAT16 / FAT32: reading, and writing new files (fw_*)
 *
 * The FAT sector cache is write-back: a changed sector is written to every
 * FAT copy when another FAT sector is needed and when a file is closed. */
#include "fat.h"
#include "hal.h"
#include "util.h"

static uint8_t  secbuf[512];            /* boot sectors and directories */
static uint8_t  fatbuf[512];            /* FAT sector cache */
static uint32_t fatbuf_lba;
static uint8_t  fat32, spc_shift, nfats, fat_dirty, fsinfo_done;
static uint32_t spc, fat_lba, root_lba, root_secs, data_lba, root_clus, max_clus;
static uint32_t fatsz, fsinfo_lba, free_hint;

FWFILE fw_file;

static uint32_t rd16(const uint8_t *p) { return p[0] | ((uint32_t)p[1] << 8); }
static uint32_t rd32(const uint8_t *p) { return rd16(p) | (rd16(p + 2) << 16); }

static int is_vbr(const uint8_t *b)
{
    return (b[0] == 0xEB || b[0] == 0xE9) && rd16(b + 11) == 512 && b[13] != 0 &&
           (u_memcmp(b + 54, "FAT", 3) == 0 || u_memcmp(b + 82, "FAT32", 5) == 0);
}

int fat_mount(void)
{
    uint32_t vbr = 0, rsv, rootents, tot;
    int i;

    fatbuf_lba = 0xFFFFFFFFu;
    fat_dirty = 0;
    fsinfo_done = 0;
    if (sd_read(0, secbuf)) return FAT_EIO;
    if (rd16(secbuf + 510) != 0xAA55) return FAT_ENOFS;
    if (!is_vbr(secbuf)) {                                   /* MBR: first FAT partition */
        for (i = 0; i < 4; i++) {
            const uint8_t *p = secbuf + 446 + 16 * i;
            uint8_t t = p[4];
            if (t == 0x01 || t == 0x04 || t == 0x06 || t == 0x0B || t == 0x0C || t == 0x0E) {
                vbr = rd32(p + 8);
                break;
            }
        }
        if (!vbr) return FAT_ENOFS;
        if (sd_read(vbr, secbuf)) return FAT_EIO;
        if (rd16(secbuf + 510) != 0xAA55 || !is_vbr(secbuf)) return FAT_ENOFS;
    }
    spc = secbuf[13];
    if (spc & (spc - 1)) return FAT_ENOFS;
    for (spc_shift = 0; (1u << spc_shift) < spc; spc_shift++) ;
    rsv      = rd16(secbuf + 14);
    nfats    = secbuf[16];
    rootents = rd16(secbuf + 17);
    tot      = rd16(secbuf + 19) ? rd16(secbuf + 19) : rd32(secbuf + 32);
    fatsz    = rd16(secbuf + 22) ? rd16(secbuf + 22) : rd32(secbuf + 36);
    if (nfats == 0) return FAT_ENOFS;
    root_secs = (rootents * 32 + 511) >> 9;
    fat_lba   = vbr + rsv;
    root_lba  = fat_lba + nfats * fatsz;
    data_lba  = root_lba + root_secs;
    if (tot <= data_lba - vbr) return FAT_ENOFS;
    max_clus  = ((tot - (data_lba - vbr)) >> spc_shift) + 1;  /* highest valid cluster number */
    if (max_clus < 4085 + 1) return FAT_ENOFS;               /* FAT12 */
    fat32     = max_clus >= 65525 + 1;
    root_clus = fat32 ? rd32(secbuf + 44) : 0;
    fsinfo_lba = fat32 ? vbr + rd16(secbuf + 48) : 0;
    free_hint = 2;
    if (fsinfo_lba && sd_read(fsinfo_lba, secbuf) == 0 &&
        rd32(secbuf) == 0x41615252u && rd32(secbuf + 484) == 0x61417272u) {
        uint32_t h = rd32(secbuf + 492);               /* FSI_Nxt_Free */
        if (h >= 2 && h <= max_clus) free_hint = h;
    } else
        fsinfo_lba = 0;
    return FAT_OK;
}

int fat_is_fat32(void) { return fat32; }

static int clus_end(uint32_t c) { return c < 2 || c > max_clus; }

static uint32_t clus_lba(uint32_t c) { return data_lba + ((c - 2) << spc_shift); }

static void wr16(uint8_t *p, uint32_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static void wr32(uint8_t *p, uint32_t v) { wr16(p, v); wr16(p + 2, v >> 16); }

static int fat_flush(void)
{
    uint32_t i;
    if (!fat_dirty) return FAT_OK;
    for (i = 0; i < nfats; i++)
        if (sd_write(fatbuf_lba + i * fatsz, fatbuf)) return FAT_EIO;
    fat_dirty = 0;
    return FAT_OK;
}

/* FAT sector holding entry c in fatbuf; returns the byte offset, or -1 */
static int fat_load(uint32_t c)
{
    uint32_t off = fat32 ? c << 2 : c << 1;
    uint32_t lba = fat_lba + (off >> 9);
    if (lba != fatbuf_lba) {
        if (fat_flush()) return -1;
        if (sd_read(lba, fatbuf)) { fatbuf_lba = 0xFFFFFFFFu; return -1; }
        fatbuf_lba = lba;
    }
    return (int)(off & 511);
}

/* raw FAT entry (FAT32: 28 bits); 0xFFFFFFFF on a read error */
static uint32_t fat_get(uint32_t c)
{
    int o = fat_load(c);
    if (o < 0) return 0xFFFFFFFFu;
    return fat32 ? rd32(fatbuf + o) & 0x0FFFFFFFu : rd16(fatbuf + o);
}

static int fat_set(uint32_t c, uint32_t v)
{
    int o = fat_load(c);
    if (o < 0) return FAT_EIO;
    if (fat32) wr32(fatbuf + o, (rd32(fatbuf + o) & 0xF0000000u) | (v & 0x0FFFFFFFu));
    else       wr16(fatbuf + o, v);
    fat_dirty = 1;
    return FAT_OK;
}

/* next cluster in the chain; 0 = end of chain or error */
static uint32_t fat_next(uint32_t c)
{
    uint32_t n = fat_get(c);
    return clus_end(n) ? 0 : n;
}

/* byte offsets of the 13 UTF-16 characters in a long-name entry */
static const uint8_t lfn_off[13] = { 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30 };
static uint32_t ent_lba;                /* where fat_list found the entry it passed to cb last */
static int      ent_idx;

int fat_list(uint32_t clus, dir_cb cb, void *ctx)
{
    char     lfn[64];
    int      has_lfn = 0, e, k;
    uint32_t sec = 0, lba;
    int      fixed = (clus == 0 && !fat32);

    if (clus == 0 && fat32) clus = root_clus;
    for (;;) {
        if (fixed) {
            if (sec >= root_secs) return FAT_OK;
            lba = root_lba + sec;
        } else {
            if (sec && !(sec & (spc - 1))) {
                clus = fat_next(clus);
                if (!clus) return FAT_OK;
            }
            if (clus_end(clus)) return FAT_OK;
            lba = clus_lba(clus) + (sec & (spc - 1));
        }
        if (sd_read(lba, secbuf)) return FAT_EIO;
        for (e = 0; e < 16; e++) {
            const uint8_t *d = secbuf + 32 * e;
            DIRENT de;

            if (d[0] == 0x00) return FAT_OK;                 /* end of directory */
            if (d[0] == 0xE5) { has_lfn = 0; continue; }     /* deleted */
            if (d[11] == 0x0F) {                             /* long-name part */
                int seq = d[0] & 0x1F;
                if (d[0] & 0x40) { u_memset(lfn, 0, sizeof lfn); has_lfn = 1; }
                if (has_lfn && seq >= 1) {
                    for (k = 0; k < 13; k++) {
                        int pos = (seq - 1) * 13 + k;
                        uint32_t ch = rd16(d + lfn_off[k]);
                        if (pos < (int)sizeof lfn - 1)
                            lfn[pos] = (ch == 0 || ch == 0xFFFF) ? 0 : (ch < 0x80 ? (char)ch : '?');
                    }
                }
                continue;
            }
            if (d[11] & 0x08) { has_lfn = 0; continue; }     /* volume label */

            for (k = 0; k < 11; k++) de.sname[k] = (char)d[k];
            if (d[0] == 0x05) de.sname[0] = (char)0xE5;
            de.attr = d[11];
            de.size = rd32(d + 28);
            de.clus = rd16(d + 26) | (fat32 ? rd16(d + 20) << 16 : 0);
            for (k = 0; k < 3; k++) de.ext[k] = (char)d[8 + k];
            de.ext[3] = 0;
            for (k = 2; k >= 0 && de.ext[k] == ' '; k--) de.ext[k] = 0;
            if (has_lfn && lfn[0]) {
                u_strncpy(de.name, lfn, NAME_MAX);
            } else {                                         /* 8.3 name, NT lower-case flags */
                char *p = de.name;
                for (k = 0; k < 8 && d[k] != ' '; k++) {
                    char c = (char)(k == 0 && d[0] == 0x05 ? 0xE5 : d[k]);
                    if ((d[12] & 0x08) && c >= 'A' && c <= 'Z') c += 32;
                    *p++ = c;
                }
                if (de.ext[0]) {
                    *p++ = '.';
                    for (k = 0; de.ext[k]; k++) {
                        char c = de.ext[k];
                        if ((d[12] & 0x10) && c >= 'A' && c <= 'Z') c += 32;
                        *p++ = c;
                    }
                }
                *p = 0;
            }
            has_lfn = 0;
            ent_lba = lba;
            ent_idx = e;
            if (cb(&de, ctx)) return FAT_OK;
        }
        sec++;
    }
}

void ff_open(FFILE *f, uint32_t clus, uint32_t size)
{
    f->first = clus;
    f->size  = size;
    f->pos   = 0;
    f->clus  = clus;
    f->cidx  = 0;
    f->lba   = 0xFFFFFFFFu;
}

int ff_getc(FFILE *f)
{
    uint32_t sec, ci, lba;

    if (f->pos >= f->size) return -1;
    sec = f->pos >> 9;
    ci  = sec >> spc_shift;
    if (ci < f->cidx) { f->clus = f->first; f->cidx = 0; }
    while (f->cidx < ci) {
        f->clus = fat_next(f->clus);
        if (!f->clus) { f->cidx = 0; f->clus = f->first; return -1; }
        f->cidx++;
    }
    if (clus_end(f->clus)) return -1;
    lba = clus_lba(f->clus) + (sec & (spc - 1));
    if (lba != f->lba) {
        if (sd_read(lba, f->buf)) { f->lba = 0xFFFFFFFFu; return -1; }
        f->lba = lba;
    }
    return f->buf[f->pos++ & 511];
}

void     ff_seek(FFILE *f, uint32_t pos) { f->pos = pos; }
uint32_t ff_tell(const FFILE *f)         { return f->pos; }

/* overwrite n bytes of an existing file at pos, inside one 512-byte sector (the
 * L64 drive's .d64 sectors); the file size does not change */
int ff_update(FFILE *f, uint32_t pos, const uint8_t *d, uint32_t n)
{
    uint32_t i;
    if (n == 0 || pos + n > f->size || (pos & 511) + n > 512) return FAT_EIO;
    f->pos = pos;
    if (ff_getc(f) < 0) return FAT_EIO;                     /* the sector is in f->buf now */
    for (i = 0; i < n; i++) f->buf[(pos & 511) + i] = d[i];
    return sd_write(f->lba, f->buf) ? FAT_EIO : FAT_OK;
}

/*----------------------------------------------------------------------------
 * writing
 *--------------------------------------------------------------------------*/

/* a free cluster, marked end-of-chain and linked after prev (0: none); 0 = full or error */
static uint32_t fat_alloc(uint32_t prev)
{
    uint32_t c = free_hint, start, n;

    if (fsinfo_lba && !fsinfo_done) {                   /* free count becomes "unknown" */
        if (sd_read(fsinfo_lba, secbuf)) return 0;
        wr32(secbuf + 488, 0xFFFFFFFFu);
        if (sd_write(fsinfo_lba, secbuf)) return 0;
        fsinfo_done = 1;
    }
    if (c < 2 || c > max_clus) c = 2;
    start = c;
    for (;;) {
        n = fat_get(c);
        if (n == 0xFFFFFFFFu) return 0;
        if (n == 0) break;
        if (++c > max_clus) c = 2;
        if (c == start) return 0;                       /* card full */
    }
    if (fat_set(c, fat32 ? 0x0FFFFFFFu : 0xFFFFu)) return 0;
    if (prev && fat_set(prev, c)) return 0;
    free_hint = c + 1;
    return c;
}

struct find_ctx { char name[11]; int hit; };

static int find_cb(const DIRENT *d, void *ctx)
{
    struct find_ctx *f = (struct find_ctx *)ctx;
    if (u_memcmp(d->sname, f->name, 11) == 0) { f->hit = 1; return 1; }
    return 0;
}

/* 1 = an entry with this 8.3 name exists, 0 = not, < 0 = error */
int fat_exists(uint32_t dir, const char name11[11])
{
    struct find_ctx f;
    int r;
    u_memcpy(f.name, name11, 11);
    f.hit = 0;
    r = fat_list(dir, find_cb, &f);
    return r != FAT_OK ? r : f.hit;
}

/* delete the file with this 8.3 name: its clusters are freed, its entry (and the long-name
 * parts before it in the same sector) marked deleted. FAT_OK (also when there is no such file) */
int fat_delete(uint32_t dir, const char name11[11])
{
    struct find_ctx f;
    uint32_t c, n, lba;
    int r, e;
    u_memcpy(f.name, name11, 11);
    f.hit = 0;
    r = fat_list(dir, find_cb, &f);
    if (r != FAT_OK) return r;
    if (!f.hit) return FAT_OK;
    lba = ent_lba;
    e   = ent_idx;
    if (sd_read(lba, secbuf)) return FAT_EIO;
    c = rd16(secbuf + 32 * e + 26) | (fat32 ? rd16(secbuf + 32 * e + 20) << 16 : 0);
    while (c >= 2 && !clus_end(c)) {                        /* free the chain */
        n = fat_next(c);
        if (fat_set(c, 0)) return FAT_EIO;
        c = n;
    }
    if (fat_flush()) return FAT_EIO;
    if (sd_read(lba, secbuf)) return FAT_EIO;
    secbuf[32 * e] = 0xE5;
    while (--e >= 0 && secbuf[32 * e + 11] == 0x0F && secbuf[32 * e] != 0xE5)
        secbuf[32 * e] = 0xE5;                              /* its long-name parts */
    return sd_write(lba, secbuf) ? FAT_EIO : FAT_OK;
}

/* sector lba of the file's sector sidx, allocating clusters at the end when needed */
static uint32_t file_lba(FWFILE *w, uint32_t sidx)
{
    uint32_t ci = sidx >> spc_shift, c, k;
    while (ci >= w->ncl) {
        c = fat_alloc(w->last);
        if (!c) return 0;
        if (!w->first) w->first = c;
        w->last = c;
        w->ncl++;
    }
    if (ci == w->ncl - 1)
        c = w->last;
    else
        for (c = w->first, k = 0; k < ci && c; k++) c = fat_next(c);
    return c ? clus_lba(c) + (sidx & (spc - 1)) : 0;
}

int fw_create(FWFILE *w, uint32_t dir, const char name11[11])
{
    uint32_t clus = dir, prev = 0, sec = 0, lba = 0, i;
    int      fixed = (dir == 0 && !fat32), e = -1;

    if (dir == 0 && fat32) clus = root_clus;
    /* first free directory entry (0x00 = never used, 0xE5 = deleted) */
    for (;;) {
        if (fixed) {
            if (sec >= root_secs) return FAT_EFULL;
            lba = root_lba + sec;
        } else {
            if (sec && !(sec & (spc - 1))) {
                prev = clus;
                clus = fat_next(clus);
                if (!clus) {                            /* directory full: add a zeroed cluster */
                    clus = fat_alloc(prev);
                    if (!clus) return FAT_EFULL;
                    u_memset(secbuf, 0, 512);
                    for (i = 0; i < spc; i++)
                        if (sd_write(clus_lba(clus) + i, secbuf)) return FAT_EIO;
                }
            }
            lba = clus_lba(clus) + (sec & (spc - 1));
        }
        if (sd_read(lba, secbuf)) return FAT_EIO;
        for (i = 0; i < 16; i++)
            if (secbuf[32 * i] == 0x00 || secbuf[32 * i] == 0xE5) { e = (int)i; break; }
        if (e >= 0) break;
        sec++;
    }
    u_memset(secbuf + 32 * e, 0, 32);
    u_memcpy(secbuf + 32 * e, name11, 11);
    secbuf[32 * e + 11] = 0x20;                             /* archive */
    if (sd_write(lba, secbuf)) return FAT_EIO;
    if (fat_flush()) return FAT_EIO;
    w->first = w->last = w->ncl = w->size = 0;
    w->dir_lba = lba;
    w->dir_off = 32 * (uint32_t)e;
    return FAT_OK;
}

int fw_putc(FWFILE *w, uint8_t b)
{
    uint32_t lba;
    w->buf[w->size & 511] = b;
    w->size++;
    if (w->size & 511) return FAT_OK;
    lba = file_lba(w, (w->size - 1) >> 9);                  /* a full sector: write it */
    if (!lba) return FAT_EFULL;
    return sd_write(lba, w->buf) ? FAT_EIO : FAT_OK;
}

int fw_patch(FWFILE *w, uint32_t pos, uint8_t b)
{
    uint32_t lba;
    if (pos >= w->size) return FAT_OK;
    if ((pos >> 9) == (w->size >> 9)) {                     /* still in the buffer */
        w->buf[pos & 511] = b;
        return FAT_OK;
    }
    lba = file_lba(w, pos >> 9);
    if (!lba || sd_read(lba, secbuf)) return FAT_EIO;
    secbuf[pos & 511] = b;
    return sd_write(lba, secbuf) ? FAT_EIO : FAT_OK;
}

int fw_close(FWFILE *w)
{
    uint32_t lba;
    uint8_t *d;
    if (w->size & 511) {                                    /* last, partial sector */
        u_memset(w->buf + (w->size & 511), 0, 512 - (w->size & 511));
        lba = file_lba(w, w->size >> 9);
        if (!lba || sd_write(lba, w->buf)) return FAT_EIO;
    }
    if (fat_flush()) return FAT_EIO;
    if (sd_read(w->dir_lba, secbuf)) return FAT_EIO;
    d = secbuf + w->dir_off;
    wr16(d + 20, w->first >> 16);
    wr16(d + 26, w->first);
    wr32(d + 28, w->size);
    return sd_write(w->dir_lba, secbuf) ? FAT_EIO : FAT_OK;
}

int fw_discard(FWFILE *w)
{
    uint32_t c = w->first, n;
    while (c) {                                             /* free the chain */
        n = fat_next(c);
        if (fat_set(c, 0)) return FAT_EIO;
        c = n;
    }
    if (fat_flush()) return FAT_EIO;
    if (sd_read(w->dir_lba, secbuf)) return FAT_EIO;
    secbuf[w->dir_off] = 0xE5;                              /* entry deleted */
    return sd_write(w->dir_lba, secbuf) ? FAT_EIO : FAT_OK;
}
