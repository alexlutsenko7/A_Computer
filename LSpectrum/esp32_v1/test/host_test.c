/* host_test.c -- runs fat.c + tape.c on the PC against a card image.
 *
 *   host_test IMAGE OUTDIR [START_BLOCK]
 *
 * Lists the whole tree (stdout: "D path" / "F path size"), and plays every
 * .tap/.tzx file (continuing through stop blocks) into OUTDIR/<path, / -> _>.txt
 * as merged "level length" segments, decoded from the commands exactly as the
 * pulse player in rtl/tape_loader.v executes them. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../src/hal.h"
#include "../src/fat.h"
#include "../src/tape.h"

static FILE *img;
static long  reads;

int sd_read(uint32_t lba, uint8_t *buf)
{
    reads++;
    if (fseek(img, (long)lba * 512, SEEK_SET)) return -1;
    return fread(buf, 1, 512, img) == 512 ? 0 : -1;
}

int sd_write(uint32_t lba, const uint8_t *buf) { (void)lba; (void)buf; return -1; }   /* read-only test */

/* timeline, as the hardware player produces it */
static FILE    *out;
static int      lvl, have;
static uint32_t len0, len1, seg_lvl;
static uint64_t seg_len;

static void hold(int l, uint32_t n)
{
    if (!n) return;
    if (have && (int)seg_lvl == l) { seg_len += n; return; }
    if (have) fprintf(out, "%u %llu\n", seg_lvl, (unsigned long long)seg_len);
    have = 1; seg_lvl = (uint32_t)l; seg_len = n;
}

uint32_t fifo_free(void) { return 512; }

void fifo_push(uint32_t c)
{
    uint32_t n = c & 0xFFFFFF;
    int k;
    switch (c >> 30) {
    case 0: hold(lvl, n); lvl ^= 1; break;
    case 1: lvl = (c >> 24) & 1; hold(lvl, n); break;
    case 2:
        if (c & 0x800) {                                   /* SAMPLES */
            for (k = 0; k <= (int)((c >> 8) & 7); k++) { lvl = (c >> (7 - k)) & 1; hold(lvl, len0); }
            break;
        }
        for (k = 0; k <= (int)((c >> 8) & 7); k++) {
            uint32_t t = ((c >> (7 - k)) & 1) ? len1 : len0;
            hold(lvl, t); lvl ^= 1;
            hold(lvl, t); lvl ^= 1;
        }
        break;
    default:
        if (((c >> 28) & 3) == 0) len0 = c & 0xFFFF;
        if (((c >> 28) & 3) == 1) len1 = c & 0xFFFF;
        break;
    }
}

typedef struct { DIRENT e[256]; int n; } LIST;

static int collect(const DIRENT *d, void *ctx)
{
    LIST *l = ctx;
    if (l->n < 256) l->e[l->n++] = *d;
    return 0;
}

static int errors;
static uint32_t start_block;

static void play(const DIRENT *d, const char *path, const char *outdir)
{
    static FFILE f;
    char name[800], *p;
    int r, guard = 0, tzx = strcmp(d->ext, "TZX") == 0;

    snprintf(name, sizeof name, "%s/%s.txt", outdir, path + 1);
    for (p = name + strlen(outdir) + 1; *p; p++) if (*p == '/') *p = '_';
    out = fopen(name, "wb");
    if (!out) { perror(name); exit(1); }
    lvl = 0; have = 0; len0 = len1 = 0;
    ff_open(&f, d->clus, d->size);
    tape_start(&f, tzx, start_block);
    for (;;) {
        r = tape_pump();
        if (r == TS_STOP) { tape_continue(); continue; }
        if (r != TS_RUN) break;
        if (++guard > 10000000) { r = TS_ERR; break; }
    }
    if (have) fprintf(out, "%u %llu\n", seg_lvl, (unsigned long long)seg_len);
    fclose(out);
    if (r != TS_END) { printf("ERROR: %s ended with %d\n", path, r); errors++; }
}

static void walk(uint32_t clus, const char *path, const char *outdir)
{
    LIST *l = calloc(1, sizeof *l);
    char  sub[600];
    int   i;

    if (fat_list(clus, collect, l) != FAT_OK) { printf("ERROR: listing %s\n", path); errors++; }
    for (i = 0; i < l->n; i++) {
        DIRENT *d = &l->e[i];
        if (!strcmp(d->name, ".") || !strcmp(d->name, "..")) continue;
        snprintf(sub, sizeof sub, "%s%s", path, d->name);
        if (d->attr & ATTR_DIR) {
            printf("D %s\n", sub);
            strcat(sub, "/");
            walk(d->clus, sub, outdir);
        } else {
            printf("F %s %u\n", sub, d->size);
            if (!strcmp(d->ext, "TAP") || !strcmp(d->ext, "TZX"))
                play(d, sub, outdir);
        }
    }
    free(l);
}

int main(int argc, char **argv)
{
    int r;
    if (argc < 3) { fprintf(stderr, "usage: host_test IMAGE OUTDIR [START_BLOCK]\n"); return 2; }
    if (argc > 3) start_block = (uint32_t)atoi(argv[3]);
    img = fopen(argv[1], "rb");
    if (!img) { perror(argv[1]); return 2; }
    r = fat_mount();
    if (r) { printf("ERROR: mount %d\n", r); return 1; }
    printf("mounted FAT%d\n", fat_is_fat32() ? 32 : 16);
    walk(0, "/", argv[2]);
    printf("%ld sector reads, %d errors\n", reads, errors);
    return errors ? 1 : 0;
}
