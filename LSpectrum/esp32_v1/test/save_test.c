/* save_test.c -- save.c + fat.c (writing) on the PC against a card image.
 *
 *   save_test IMAGE save  TAPFILE DIR NAME8 [noise] [empty]
 *       Starts recording into DIR ("/" or a folder name in the root) / NAME8.TAP,
 *       feeds the MIC pulse train the ROM SAVE routine makes for TAPFILE (pilot
 *       8063/3223 x 2168, sync 667 + 735, 2 x 855 / 1710 per bit, 1 s in turbo
 *       between blocks, +-15 T-states of jitter, no closing edge after the last
 *       pulse of a block) and stops recording.
 *       noise: random MIC clicks and a too-short pilot first (must be ignored).
 *       empty: nothing saved: the file must be removed.
 *   save_test IMAGE many DIR COUNT
 *       Creates COUNT small files in DIR (directory growth beyond one cluster).
 *
 * The result is checked by tools/fatcheck.py. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../src/hal.h"
#include "../src/fat.h"
#include "../src/save.h"
#include "host_hw.h"

static FILE *img;

int sd_read(uint32_t lba, uint8_t *buf)
{
    if (fseek(img, (long)lba * 512, SEEK_SET)) return -1;
    return fread(buf, 1, 512, img) == 512 ? 0 : -1;
}

int sd_write(uint32_t lba, const uint8_t *buf)
{
    if (getenv("WRLOG")) fprintf(stderr, "write %u\n", lba);
    if (fseek(img, (long)lba * 512, SEEK_SET)) return -1;
    return fwrite(buf, 1, 512, img) == 512 ? 0 : -1;
}

uint32_t fifo_free(void) { return 512; }
void     fifo_push(uint32_t c) { (void)c; }

/* ---- recorder model: a queue of events ------------------------------------ */
static uint32_t *q;
static size_t    qn, qcap, qi;
static uint32_t  since_after;           /* since-value once the queue is empty */
static uint32_t  ctl, tape, now_t;

static void ev(uint32_t e)
{
    if (qn == qcap) { qcap = qcap ? qcap * 2 : 65536; q = realloc(q, qcap * sizeof *q); }
    q[qn++] = e;
}
static void edge_after(uint32_t t) { ev(0x80000000u | (t > 0xFFFFFF ? 0xFFFFFF : t)); }
static void gap(void)               { ev(0xC0000000u | 8000); }

uint32_t rec_event(void)     { return qi < qn ? q[qi++] : 0; }
uint32_t rec_since(void)     { return qi < qn ? 0 : since_after; }
void     rec_ctl(uint32_t v) { ctl = v; }
void     tape_ctl(uint32_t v){ tape = v; }
uint32_t timer_now(void)     { return now_t; }

static unsigned rnd = 12345;
static int jit(void) { rnd = rnd * 1103515245u + 12345u; return (int)((rnd >> 16) % 31) - 15; }

/* one ROM-format block: pilot, sync, data; the first edge comes after `pause` */
static void rom_block(const uint8_t *d, uint32_t n, uint32_t pause)
{
    uint32_t i, k, p = (d[0] & 0x80) ? 3223 : 8063;
    edge_after(pause);                                  /* the edge that starts the pilot */
    for (i = 0; i < p; i++) edge_after(2168 + jit());
    edge_after(667 + jit());
    edge_after(735 + jit());
    for (i = 0; i < n; i++)
        for (k = 0; k < 8; k++) {
            uint32_t h = ((d[i] >> (7 - k)) & 1) ? 1710 : 855;
            edge_after(h + jit());
            if (!(i == n - 1 && k == 7)) edge_after(h + jit());   /* no closing edge at the very end */
        }
    gap();
}

struct find { const char *want; uint32_t clus; int hit; };

static int find_dir_cb(const DIRENT *d, void *ctx)
{
    struct find *f = ctx;
    if ((d->attr & ATTR_DIR) && strcmp(d->name, f->want) == 0) { f->clus = d->clus; f->hit = 1; return 1; }
    return 0;
}

static uint32_t dir_of(const char *name)
{
    struct find f = { name, 0, 0 };
    if (strcmp(name, "/") == 0) return 0;
    fat_list(0, find_dir_cb, &f);
    if (!f.hit) { printf("ERROR: folder %s not found\n", name); exit(1); }
    return f.clus;
}

static void name11(char out[11], const char *n8)
{
    int i;
    for (i = 0; i < 8; i++) out[i] = (char)(i < (int)strlen(n8) ? n8[i] : ' ');
    out[8] = 'T'; out[9] = 'A'; out[10] = 'P';
}

int main(int argc, char **argv)
{
    char n11[11];
    if (argc < 4) { fprintf(stderr, "usage: see save_test.c\n"); return 2; }
    img = fopen(argv[1], "r+b");
    if (!img || fat_mount() != FAT_OK) { printf("ERROR: mount\n"); return 1; }

    if (strcmp(argv[2], "many") == 0) {
        uint32_t dir = dir_of(argv[3]);
        int i, count = atoi(argv[4]);
        for (i = 0; i < count; i++) {
            static FWFILE w;
            char n8[9];
            int k;
            sprintf(n8, "F%03d", i);
            name11(n11, n8);
            if (fat_exists(dir, n11) != 0) { printf("ERROR: %s exists\n", n8); return 1; }
            if (fw_create(&w, dir, n11) != FAT_OK) { printf("ERROR: create %d\n", i); return 1; }
            for (k = 0; k < 100 + i; k++) fw_putc(&w, (uint8_t)(i + k));
            if (fw_close(&w) != FAT_OK) { printf("ERROR: close %d\n", i); return 1; }
        }
        printf("created %d files\n", count);
        return 0;
    }

    /* save: recording mode started, the TAP file's blocks saved by the "Spectrum", stopped */
    {
        FILE *t = fopen(argv[3], "rb");
        static uint8_t tap[1 << 20];
        size_t n = t ? fread(tap, 1, sizeof tap, t) : 0, p = 0;
        int noise = 0, empty = 0, i;
        uint32_t dir = dir_of(argv[4]);
        char st[48];
        for (i = 6; i < argc; i++) {
            if (!strcmp(argv[i], "noise")) noise = 1;
            if (!strcmp(argv[i], "empty")) empty = 1;
        }
        if (!n) { printf("ERROR: no TAP\n"); return 1; }
        name11(n11, argv[5]);
        if (rec_start(dir, n11) != FAT_OK) { printf("ERROR: rec_start\n"); return 1; }
        if (!(ctl & REC_ARMED)) { printf("ERROR: recorder not armed\n"); return 1; }
        if (noise) {                                    /* clicks and a 50-pulse pilot: no block */
            for (i = 0; i < 300; i++) edge_after(50 + (uint32_t)(jit() + 15) * 40);
            for (i = 0; i < 50; i++) edge_after(2168);
            edge_after(30000); gap();
        }
        while (!empty && p + 2 <= n) {                  /* 1 s (real time, = 28 M T in turbo) between blocks */
            uint32_t len = tap[p] | tap[p + 1] << 8;
            rom_block(tap + p + 2, len, p ? 28000000 : 100000);
            p += 2 + len;
        }
        while (qi < qn) rec_service();
        rec_end();
        now_t = 0;
        if (rec_status(st)) printf("status: %s\n", st);
        printf("events %zu, turbo %s, recorder %s at the end\n", qn, (tape & TAPE_TURBO) ? "ON" : "off", ctl ? "ON" : "off");
        if ((tape & TAPE_TURBO) || ctl || rec_active()) { printf("ERROR: state after the end\n"); return 1; }
        if (empty && fat_exists(dir, n11) != 0) { printf("ERROR: empty recording left a file\n"); return 1; }
    }
    return 0;
}
