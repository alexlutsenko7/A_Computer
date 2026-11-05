/* snap_test.c -- snap.c + fat.c on the PC against a card image, with a model of the
 * snapshot hardware (zx_bus.v: frozen CPU, 128K RAM, registers, AY, ports).
 *
 *   snap_test IMAGE save DIR NAME8 SEED EXPECTED OUT
 *       Makes a machine state from SEED (pages with runs, ED bytes, random data;
 *       random registers; HALT if SEED is odd), writes it to EXPECTED (dump format
 *       below), saves DIR/NAME8.Z80, checks the machine runs on unchanged (AY
 *       volumes and select restored, CPU not frozen), copies the file to OUT, then
 *       loads it into a cleared machine and compares everything.
 *   snap_test IMAGE load PATH DUMP
 *       Loads PATH ("/SNAPS/X.Z80") into a machine filled with 0x55 and writes the
 *       resulting state to DUMP; prints "result N" (snap_load's return value).
 *
 * Dump: 128K RAM (pages 0-7), 7 register words (cpu_t80 layout, little endian),
 * 16 AY registers, AY select, 7FFD, border. Checked by z80ref.py. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../src/fat.h"
#include "../src/snap.h"
#include "../src/shot.h"
#include "host_hw.h"

static FILE *img;

int sd_read(uint32_t lba, uint8_t *buf)
{
    if (fseek(img, (long)lba * 512, SEEK_SET)) return -1;
    return fread(buf, 1, 512, img) == 512 ? 0 : -1;
}

int sd_write(uint32_t lba, const uint8_t *buf)
{
    if (fseek(img, (long)lba * 512, SEEK_SET)) return -1;
    return fwrite(buf, 1, 512, img) == 512 ? 0 : -1;
}

uint32_t fifo_free(void) { return 512; }
void     fifo_push(uint32_t c) { (void)c; }
uint32_t timer_now(void) { return 0; }

/* ---- machine model ------------------------------------------------------- */
static uint8_t  mem[1 << 18];
static uint32_t regs[7], dirw[7];
static uint8_t  ay[16], ay_sel, ay_addr, p7ffd, border, halt;
static int      frozen, errors, loads;

static const uint8_t ay_mask[16] = { 0xFF, 0x0F, 0xFF, 0x0F, 0xFF, 0x0F, 0x1F, 0xFF,
                                     0x1F, 0x1F, 0x1F, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF };

static void err(const char *m) { printf("ERROR: %s\n", m); errors++; }

void     snap_ctl(uint32_t v) { frozen = v & 1; }
uint32_t snap_status(void)    { return frozen ? SNAP_FROZEN : 0; }

uint32_t snap_cmd(uint32_t c, uint32_t a, uint32_t d)
{
    if (!frozen) { err("command while not frozen"); return 0; }
    switch (c) {
    case 1:  if (a >= sizeof mem) err("MRD address"); return mem[a & 0x3FFFF];
    case 2:  if (a >= 0x20000) err("MWR outside RAM"); mem[a & 0x3FFFF] = (uint8_t)d; return 0;
    case 3:  if (a > 6) err("REG word"); return regs[a % 7];
    case 4:  if (a > 6) err("DIR word"); dirw[a % 7] = d; return 0;
    case 5:  memcpy(regs, dirw, sizeof regs); halt = 0; loads++; return 0;
    case 6:  ay_addr = a & 15; return ay[ay_addr] & ay_mask[ay_addr];
    case 7:  ay_addr = a & 15; ay[ay_addr] = (uint8_t)d; return 0;
    case 8:  ay_addr = d & 15; ay_sel = (uint8_t)d; return 0;
    case 9:  p7ffd = (uint8_t)d; border = (d >> 8) & 7; return 0;
    case 10: return p7ffd | (uint32_t)border << 8 | (uint32_t)ay_sel << 16 | (uint32_t)halt << 24;
    default: err("bad command"); return 0;
    }
}

static void dump(const char *fn)
{
    FILE *f = fopen(fn, "wb");
    uint8_t t[3] = { ay_sel, p7ffd, border };
    int i;
    fwrite(mem, 1, 0x20000, f);
    for (i = 0; i < 7; i++) { uint8_t w[4] = { (uint8_t)regs[i], (uint8_t)(regs[i] >> 8), (uint8_t)(regs[i] >> 16), (uint8_t)(regs[i] >> 24) }; fwrite(w, 1, 4, f); }
    for (i = 0; i < 16; i++) { uint8_t v = ay[i] & ay_mask[i]; fwrite(&v, 1, 1, f); }
    fwrite(t, 1, 3, f);
    fclose(f);
}

/* ---- files ---------------------------------------------------------------- */
struct find { const char *want; uint32_t clus, size; int hit, dir; };

static int find_cb(const DIRENT *d, void *ctx)
{
    struct find *f = ctx;
    if (strcmp(d->name, f->want) == 0 && !!(d->attr & ATTR_DIR) == f->dir) { f->clus = d->clus; f->size = d->size; f->hit = 1; return 1; }
    return 0;
}

static int find(uint32_t dir, const char *name, int is_dir, uint32_t *clus, uint32_t *size)
{
    struct find f = { name, 0, 0, 0, is_dir };
    fat_list(dir, find_cb, &f);
    *clus = f.clus;
    *size = f.size;
    return f.hit;
}

/* "/A/B.Z80" -> first cluster and size */
static int open_path(const char *path, FFILE *ff)
{
    char part[64];
    uint32_t dir = 0, clus, size;
    const char *p = path + 1, *s;
    for (;;) {
        s = strchr(p, '/');
        if (!s) break;
        memcpy(part, p, (size_t)(s - p)); part[s - p] = 0;
        if (!find(dir, part, 1, &clus, &size)) return 0;
        dir = clus;
        p = s + 1;
    }
    if (!find(dir, p, 0, &clus, &size)) return 0;
    ff_open(ff, clus, size);
    return 1;
}

static uint32_t rnd = 1;
static uint32_t next(void) { rnd = rnd * 1103515245u + 12345u; return rnd >> 8; }

static void make_state(uint32_t seed)
{
    uint32_t i, pg;
    rnd = seed * 2654435761u + 1;
    for (pg = 0; pg < 8; pg++) {
        uint8_t *m = mem + pg * 16384;
        for (i = 0; i < 16384; i++) {
            switch ((pg + seed) % 8) {
            case 0:  m[i] = (uint8_t)next(); break;                         /* incompressible */
            case 1:  m[i] = 0; break;
            case 2:  m[i] = (uint8_t)((i / ((next() % 9) + 1)) & 3 ? 0xED : next()); break;  /* runs + EDs */
            case 3:  m[i] = 0xED; break;
            case 4:  m[i] = (i & 1) ? 0xED : (uint8_t)(i >> 3); break;      /* ED x ED x ... */
            case 5:  m[i] = (uint8_t)((i % 300) < 280 ? i / 300 : next()); break;  /* long runs */
            case 6:  m[i] = (uint8_t)((next() % 4) ? 0xED : (next() % 3 ? 0xED : 7)); break;
            default: m[i] = (uint8_t)(i % 7 < 5 ? 0x11 : i); break;         /* runs of 5 */
            }
        }
    }
    for (i = 0; i < 7; i++) regs[i] = next() ^ next() << 16;
    regs[6] = (regs[6] & 0xFFFF) | ((next() % 3) << 16) | ((next() & 1) << 18) | ((next() & 1) << 19);
    for (i = 0; i < 16; i++) ay[i] = (uint8_t)next();
    ay_sel = (uint8_t)(next() & 15);
    ay_addr = ay_sel;
    p7ffd = (uint8_t)(next() & 0x3F);
    border = (uint8_t)(next() & 7);
    halt = seed & 1;
}

int main(int argc, char **argv)
{
    static FFILE ff;
    if (argc < 4) { fprintf(stderr, "usage: see snap_test.c\n"); return 2; }
    img = fopen(argv[1], "r+b");
    if (!img || fat_mount() != FAT_OK) { printf("ERROR: mount\n"); return 1; }

    if (strcmp(argv[2], "load") == 0) {
        int r;
        memset(mem, 0x55, sizeof mem);
        memset(regs, 0xA5, sizeof regs);
        memset(ay, 0x33, sizeof ay);
        ay_sel = 9; p7ffd = 0x17; border = 5; halt = 0;
        if (!open_path(argv[3], &ff)) { printf("ERROR: %s not found\n", argv[3]); return 1; }
        r = snap_load(&ff);
        printf("result %d, loads %d, frozen %d\n", r, loads, frozen);
        if (frozen) err("left frozen");
        if (r == 0 && loads != 1) err("no LOAD");
        if (r != 0 && r != SNAP_EBAD) err("unexpected result");
        dump(argv[4]);
        return errors ? 1 : 0;
    }

    if (strcmp(argv[2], "save") == 0) {
        static uint8_t mem0[0x20000];
        uint32_t regs0[7], dir = 0, size, i;
        uint8_t  ay0[16], sel0, p0, b0;
        char     n11[11];
        int      r;
        FILE    *o;

        make_state((uint32_t)atoi(argv[5]));
        if (strcmp(argv[3], "/") && !find(0, argv[3], 1, &dir, &size)) { printf("ERROR: folder\n"); return 1; }
        {   /* expected state: as saved, PC one back in HALT */
            uint32_t pc = regs[2] & 0xFFFF;
            memcpy(regs0, regs, sizeof regs);
            if (halt) regs0[2] = (regs0[2] & 0xFFFF0000u) | ((pc - 1) & 0xFFFF);
            memcpy(mem0, mem, sizeof mem0);
            memcpy(ay0, ay, sizeof ay0); sel0 = ay_sel; p0 = p7ffd; b0 = border;
            memcpy(regs, regs0, sizeof regs);
            dump(argv[6]);
            regs[2] = (regs[2] & 0xFFFF0000u) | pc;                         /* the CPU's own PC */
        }
        for (i = 0; i < 8; i++) n11[i] = i < strlen(argv[4]) ? argv[4][i] : ' ';
        n11[8] = 'Z'; n11[9] = '8'; n11[10] = '0';
        if (snap_freeze() != 0) { printf("ERROR: freeze\n"); return 1; }
        snap_capture();
        if (ay[8] || ay[9] || ay[10]) err("AY not muted while stopped");
        r = snap_save(dir, n11);
        snap_resume();
        printf("save result %d\n", r);
        if (r != FAT_OK) err("save");
        if (frozen) err("left frozen");
        for (i = 0; i < 16; i++)                        /* unused AY bits read as 0 (as the real one) */
            if ((ay[i] & ay_mask[i]) != (ay0[i] & ay_mask[i])) err("AY not restored");
        if (ay_sel != sel0 || ay_addr != (sel0 & 15)) err("AY select not restored");
        if (memcmp(mem, mem0, sizeof mem0) || p7ffd != p0 || border != b0) err("machine changed by saving");

        /* copy the file out, then load it into a cleared machine */
        {
            char path[64];
            int c;
            if (strcmp(argv[3], "/")) sprintf(path, "/%s/%s.Z80", argv[3], argv[4]);
            else                      sprintf(path, "/%s.Z80", argv[4]);
            if (!open_path(path, &ff)) { printf("ERROR: saved file %s not found\n", path); return 1; }
            o = fopen(argv[7], "wb");
            while ((c = ff_getc(&ff)) >= 0) fputc(c, o);
            fclose(o);
            printf("file %s: %u bytes\n", path, ff.size);
            memset(mem, 0, sizeof mem); memset(regs, 0, sizeof regs); memset(ay, 0, sizeof ay);
            ay_sel = p7ffd = border = 0; halt = 0;
            ff_open(&ff, ff.first, ff.size);
            r = snap_load(&ff);
            if (r != 0) { printf("ERROR: load result %d\n", r); return 1; }
            if (memcmp(mem, mem0, sizeof mem0)) err("RAM differs after save + load");
            if (memcmp(regs, regs0, sizeof regs)) {
                for (i = 0; i < 7; i++) printf("  word %u: %08x / %08x\n", i, regs[i], regs0[i]);
                err("registers differ after save + load");
            }
            for (i = 0; i < 16; i++) if ((ay[i] & ay_mask[i]) != (ay0[i] & ay_mask[i])) err("AY differs");
            if (ay_sel != sel0 || p7ffd != p0 || border != b0) err("ports differ after save + load");
        }
        return errors ? 1 : 0;
    }
    if (strcmp(argv[2], "shot") == 0) {                 /* shot OUT.BMP 7FFD: two screenshots, check the second */
        static uint8_t bmp[40000];
        char     n11[11], want[12];
        uint32_t i, base, n = 0;
        int      k, r, c, x, y;
        for (i = 0; i < sizeof mem; i++) mem[i] = (uint8_t)next();
        p7ffd  = (uint8_t)atoi(argv[4]);
        border = 3;
        for (k = 1; k <= 2; k++) {
            if (shot_name(0, n11) != 0) { err("shot_name"); return 1; }
            sprintf(want, "SCRN%04dBMP", k);
            if (memcmp(n11, want, 11)) err("screenshot name");
            r = snap_screenshot(0, n11);
            if (r != 0) { printf("ERROR: screenshot result %d\n", r); return 1; }
            if (frozen) err("left frozen");
        }
        if (!open_path("/SCRN0002.BMP", &ff)) { printf("ERROR: SCRN0002.BMP not found\n"); return 1; }
        while ((c = ff_getc(&ff)) >= 0 && n < sizeof bmp) bmp[n++] = (uint8_t)c;
        { FILE *o = fopen(argv[3], "wb"); fwrite(bmp, 1, n, o); fclose(o); }
        printf("SCRN0002.BMP: %u bytes\n", n);
        if (n != 118 + 160 * 240) err("BMP size");
        if (bmp[0] != 'B' || bmp[1] != 'M' || bmp[10] != 118 || bmp[18] != 0x40 || bmp[19] != 1 || bmp[22] != 240 || bmp[28] != 4)
            err("BMP header");
        base = ((p7ffd & 8) ? 7u : 5u) * 16384u;
        for (y = 0; y < 240; y++)
            for (x = 0; x < 320; x++) {
                int col, got;
                if (y < 24 || y >= 216 || x < 32 || x >= 288) col = border;
                else {
                    int sy = y - 24, sx = x - 32;
                    uint32_t line = (uint32_t)((sy >> 6) * 2048 + (sy & 7) * 256 + ((sy >> 3) & 7) * 32);
                    uint8_t  a    = mem[base + 6144 + (uint32_t)(sy / 8 * 32 + sx / 8)];
                    int      on   = (mem[base + line + (uint32_t)(sx / 8)] & (0x80 >> (sx % 8))) != 0;
                    col = (a & 0x40 ? 8 : 0) + (on ? a % 8 : a / 8 % 8);
                }
                got = bmp[118 + (239 - y) * 160 + x / 2];
                got = (x % 2) ? got & 15 : got >> 4;
                if (got != col) { if (errors < 5) printf("  pixel %d,%d: %d, expected %d\n", x, y, got, col); errors++; }
            }
        return errors ? 1 : 0;
    }
    fprintf(stderr, "unknown mode\n");
    return 2;
}
