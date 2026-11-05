/* update.c -- flash update from the SD card, run while the machine menu (AMenu) is on the link.
 *
 * LUPDATE.BIN (made by AMenu/tools/mk_update.py from the same .cof as L.jic):
 *   0    "LUPDATE1"
 *   8    image length (bytes from flash address 0, a multiple of 4096)
 *   12   CRC-32 of the image (zlib)
 *   16   skip start, 20 skip end: never written (the C64 ROMs the ESP32 installed, 0x580000-0x5FFFFF)
 *   24   menu end (0x100000): the factory image's slot, written last
 *   28   label, 64 bytes, NUL padded
 *   252  CRC-32 of bytes 0-251
 *   256  the image: the flash contents as read over SPI (Quartus' .rpd with the bits of each byte reversed)
 * Each 4 KB sector is compared with the flash and only rewritten if it differs (erase, program the
 * pages that are not all FF, read back). The machines' sectors come first, the menu's last: an
 * update cut off before that leaves a working menu, and the file stays for the next start. The file
 * is deleted only after every sector checked out.
 */
#include <stdlib.h>
#include "hw.h"
#include "fat.h"
#include "flash.h"
#include "update.h"
#include "util.h"

#define HDR       256u
#define SECTOR    4096u
#define ERASE_MS  2000u     /* 4 KB erase (maximum 0.4 s) */
#define PROG_MS   50u       /* page program (maximum 5 ms) */
#define FL_MAX    0x800000u

static const uint32_t slot[4] = { 0x100000u, 0x200000u, 0x300000u, 0x400000u };   /* AMenu MACHINE_ADDR (1 MB slots) */

/* The buffers are allocated the first time an update file is read: only the menu mode does that, so
 * the machines keep this RAM for the Bluetooth stack (static, it made A2DP stutter on hardware). */
struct ubuf {
    uint8_t  hdr[HDR];
    uint8_t  sec[SECTOR];
    uint8_t  chk[SECTOR];       /* the flash's sector */
    uint32_t crc_tab[256];
    char     label[65];
};
static struct ubuf *ub;
#define hdr     (ub->hdr)
#define sec     (ub->sec)
#define chk     (ub->chk)
#define crc_tab (ub->crc_tab)
#define label   (ub->label)

static uint32_t rd32(const uint8_t *p) { return p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }

static uint32_t crc32(uint32_t c, const uint8_t *d, uint32_t n)
{
    if (!crc_tab[1])
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t v = i;
            for (int k = 0; k < 8; k++) v = v & 1 ? 0xEDB88320u ^ (v >> 1) : v >> 1;
            crc_tab[i] = v;
        }
    c = ~c;
    while (n--) c = crc_tab[(c ^ *d++) & 0xFF] ^ (c >> 8);
    return ~c;
}

struct find_upd { DIRENT d; int hit; };

static int find_cb(const DIRENT *d, void *ctx)
{
    struct find_upd *f = (struct find_upd *)ctx;
    if (!(d->attr & ATTR_DIR) && u_memcmp(d->sname, UPD_NAME11, 11) == 0) { f->d = *d; f->hit = 1; return 1; }
    return 0;
}

int upd_find(DIRENT *d)
{
    struct find_upd f;
    f.hit = 0;
    if (fat_list(0, find_cb, &f) != FAT_OK) return FAT_EIO;
    if (f.hit) *d = f.d;
    return f.hit;
}

const char *upd_label(void) { return ub ? label : ""; }

static uint32_t img_len(void)    { return rd32(hdr + 8); }
static uint32_t skip_lo(void)    { return rd32(hdr + 16); }
static uint32_t skip_hi(void)    { return rd32(hdr + 20); }
static uint32_t menu_end(void)   { return rd32(hdr + 24); }

static int read_hdr(FFILE *f, const DIRENT *d)
{
    uint32_t i;
    int c;
    if (!ub && !(ub = (struct ubuf *)calloc(1, sizeof *ub))) return FAT_EIO;
    ff_open(f, d->clus, d->size);
    for (i = 0; i < HDR; i++) {
        if ((c = ff_getc(f)) < 0) return d->size < HDR ? UPD_EBAD : FAT_EIO;
        hdr[i] = (uint8_t)c;
    }
    if (u_memcmp(hdr, "LUPDATE1", 8) != 0 || crc32(0, hdr, 252) != rd32(hdr + 252)) return UPD_EBAD;
    if (img_len() == 0 || img_len() % SECTOR || img_len() > FL_MAX || d->size != HDR + img_len()) return UPD_EBAD;
    if (menu_end() % SECTOR || menu_end() > img_len() || skip_lo() % SECTOR || skip_hi() % SECTOR) return UPD_EBAD;
    u_memcpy(label, hdr + 28, 64);
    label[64] = 0;
    return 0;
}

int upd_check(const DIRENT *d, void (*progress)(uint32_t done, uint32_t total))
{
    FFILE    f;
    uint32_t a, i, c = 0;
    int      r = read_hdr(&f, d), b;
    if (r) return r;
    for (a = 0; a < img_len(); a += SECTOR) {
        for (i = 0; i < SECTOR; i++) {
            if ((b = ff_getc(&f)) < 0) return FAT_EIO;
            sec[i] = (uint8_t)b;
        }
        c = crc32(c, sec, SECTOR);
        if (progress && !(a & 0x3FFFFu)) progress(a, img_len());
    }
    return c == rd32(hdr + 12) ? 0 : UPD_EBAD;
}

/* the flash sector at a equals sec[] */
static int same(uint32_t a)
{
    fl_read(a, chk, SECTOR);
    return u_memcmp(chk, sec, SECTOR) == 0;
}

/* erase the sector at a and program sec[] into it (pages that are all FF stay erased) */
static int burn(uint32_t a)
{
    uint32_t p, i;
    fl_wren();
    fl_addr(0x20, a);
    fl_end();
    if (fl_wait(ERASE_MS)) return UPD_EFLASH;
    for (p = 0; p < SECTOR; p += 256) {
        for (i = 0; i < 256 && sec[p + i] == 0xFF; i++) ;
        if (i == 256) continue;
        fl_prog(a + p, sec + p);
        if (fl_wait(PROG_MS)) return UPD_EFLASH;
    }
    return 0;
}

static int load_sector(FFILE *f, uint32_t a)
{
    uint32_t i;
    int c;
    ff_seek(f, HDR + a);
    for (i = 0; i < SECTOR; i++) {
        if ((c = ff_getc(f)) < 0) return FAT_EIO;
        sec[i] = (uint8_t)c;
    }
    return 0;
}

int upd_run(const DIRENT *d, void (*progress)(uint32_t done, uint32_t total), int *menu_changed, uint32_t *written)
{
    FFILE    f;
    uint32_t a, done = 0, total, pass;
    int      r = read_hdr(&f, d), tries;

    *menu_changed = 0;
    *written = 0;
    if (r) return r;
    total = img_len() - (skip_hi() > skip_lo() ? skip_hi() - skip_lo() : 0);
    for (pass = 0; pass < 2; pass++) {                      /* 0: the machines, 1: the menu */
        uint32_t from = pass ? 0 : menu_end(), to = pass ? menu_end() : img_len();
        for (a = from; a < to; a += SECTOR) {
            if (a >= skip_lo() && a < skip_hi()) continue;
            if ((r = load_sector(&f, a)) != 0) { fl_release(); return r; }
            for (tries = 0; !same(a); tries++) {
                if (tries == 2) { fl_release(); return UPD_EFLASH; }
                if (burn(a)) { fl_release(); return UPD_EFLASH; }
                if (!tries) { (*written)++; if (pass) *menu_changed = 1; }
            }
            done += SECTOR;
            if (progress && !(done & 0x1FFFFu)) progress(done, total);
        }
    }
    fl_release();
    return fat_delete(0, UPD_NAME11) == FAT_OK ? 0 : FAT_EIO;
}

void upd_slot_bytes(int k, uint8_t b[4])
{
    fl_read(k ? slot[k - 1] + 0x20 : 0x20, b, 4);
    fl_release();
}

/* a configuration image starts 32 bytes into its slot: FF before, then the sync byte 6A, which reads
 * 56 over SPI (LSB first in the flash; seen on hardware). An erased slot reads FF, a slot the loader
 * .jic cleared reads 00 */
int upd_machines_present(void)
{
    uint8_t  b[4];
    uint32_t k;
    for (k = 0; k < 4; k++) {
        fl_read(slot[k] + 0x20, b, sizeof b);
        if (b[0] == 0x56) { fl_release(); return 1; }
    }
    fl_release();
    return 0;
}
