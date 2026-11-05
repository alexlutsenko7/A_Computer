/* espupd.c -- the ESP32's own firmware from the SD card, run while the machine menu is on the link.
 *
 * LESP32.BIN is the sketch's application image as arduino-cli builds it (esp32_v2.ino.bin, not the
 * merged image with the boot loader): it starts with the magic byte E9, the chip ID at 12-13 is 0
 * (ESP32). It goes into the firmware slot not running now; only after the whole image is written
 * and verified (esp_ota_end: checksum + SHA-256) does the ESP32 boot from that slot. A bad file or
 * a power cut leaves the running firmware as it is. The file is deleted once the slot is selected.
 */
#include <stdlib.h>
#include "fat.h"
#include "espupd.h"
#include "util.h"

#define CHUNK     4096u
#define MAX_SIZE  0x300000u     /* one firmware slot (partitions app0 / app1, 3 MB: 16 MB layout app3M_fat9M_16MB) */

struct find_esp { DIRENT d; int hit; };

static int find_cb(const DIRENT *d, void *ctx)
{
    struct find_esp *f = (struct find_esp *)ctx;
    if (!(d->attr & ATTR_DIR) && u_memcmp(d->sname, ESPUPD_NAME11, 11) == 0) { f->d = *d; f->hit = 1; return 1; }
    return 0;
}

int espupd_find(DIRENT *d)
{
    struct find_esp f;
    f.hit = 0;
    if (fat_list(0, find_cb, &f) != FAT_OK) return FAT_EIO;
    if (f.hit) *d = f.d;
    return f.hit;
}

int espupd_run(const DIRENT *d, void (*progress)(uint32_t done, uint32_t total))
{
    FFILE    f;
    uint8_t *buf;
    uint32_t done = 0, n, i;
    int      c, r = 0;

    if (d->size < 256 || d->size > MAX_SIZE) return ESPUPD_EBAD;
    if (!(buf = (uint8_t *)malloc(CHUNK))) return FAT_EIO;
    ff_open(&f, d->clus, d->size);
    for (i = 0; i < 16; i++) {
        if ((c = ff_getc(&f)) < 0) { free(buf); return FAT_EIO; }
        buf[i] = (uint8_t)c;
    }
    if (buf[0] != 0xE9 || buf[12] != 0 || buf[13] != 0) { free(buf); return ESPUPD_EBAD; }
    if (ota_begin(d->size)) { free(buf); return ESPUPD_EWRITE; }
    ff_seek(&f, 0);
    while (done < d->size) {
        n = d->size - done < CHUNK ? d->size - done : CHUNK;
        for (i = 0; i < n; i++) {
            if ((c = ff_getc(&f)) < 0) { r = FAT_EIO; break; }
            buf[i] = (uint8_t)c;
        }
        if (r) break;
        if (ota_write(buf, n)) { r = ESPUPD_EWRITE; break; }
        done += n;
        if (progress) progress(done, d->size);
    }
    free(buf);
    if (r) { ota_abort(); return r; }
    if (ota_end()) return ESPUPD_EWRITE;
    return fat_delete(0, ESPUPD_NAME11) == FAT_OK ? 0 : FAT_EIO;
}
