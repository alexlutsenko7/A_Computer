/* c64rom_test.cpp -- PC test of the L64 ROM install (c64.cpp, compiled as C++)
 *
 * hw_rd / hw_wr model the tape loader's flash pass-through (register 0x40, rtl/tape_loader.v:
 * a write while a byte shifts is ignored) and an SPI flash with 4 KB erase (0x06 / 0x05 / 0x20 /
 * 0x02 / 0x03; busy while erasing or programming, commands ignored then). TIMER advances 10 us
 * per register access. Usage: c64rom_test card.img romdir [busy_us] (5 = the real link; 25 makes
 * every byte still busy at the next access)
 *   1. flash in the state seen on hardware 2026-10-28 (image right, header bytes FF): install
 *   2. installs cut off after a random number of register accesses (an ESP32 restart):
 *      the flash may only look installed (c64_rom_present) when the whole image is right
 *   3. a full install after each cut-off: image right, RELOAD written
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <setjmp.h>
#include "../src/hw.h"
#include "../src/hal.h"
#include "../src/fat.h"
#include "../src/c64.h"
#undef main                                     /* hw.h: main is the ESP32 loader task */

#define FL_SIZE  0x400000u
#define ROM_BASE 0x200000u
#define ROM_LEN  49152u

static uint8_t  flash[FL_SIZE], expect[ROM_LEN];
static FILE    *card;
static int      errors;

/* card */
int sd_read(uint32_t lba, uint8_t *buf)
{
    if (fseek(card, (long)lba * 512, SEEK_SET) || fread(buf, 512, 1, card) != 1) return -1;
    return 0;
}
int sd_write(uint32_t lba, const uint8_t *buf) { (void)lba; (void)buf; return -1; }
uint32_t fifo_free(void) { return 512; }
int link_alive(void) { return 1; }
void fifo_push(uint32_t c) { (void)c; }

/* time, cut-off */
static uint64_t now_us;
static long     accesses, cut_at = -1;
static jmp_buf  cut;
static int      reloads;

static void tick(void)
{
    now_us += 10;
    ++accesses;
    if (cut_at >= 0 && accesses >= cut_at) longjmp(cut, 1);
}

/* SPI flash */
static int      cs, wel;
static uint64_t busy_until;
static uint8_t  cmd[300];
static int      ncmd;
static uint32_t rd_addr;

static int fl_busy(void) { return now_us < busy_until; }

static uint8_t spi_byte(uint8_t mosi)
{
    uint8_t miso = 0xFF;
    if (ncmd >= 1 && cmd[0] == 0x05) miso = (uint8_t)((fl_busy() ? 1 : 0) | (wel ? 2 : 0));
    if (ncmd >= 4 && cmd[0] == 0x03 && !fl_busy()) miso = flash[rd_addr++ % FL_SIZE];
    if (ncmd < (int)sizeof cmd) cmd[ncmd] = mosi;
    ncmd++;
    if (ncmd == 4 && cmd[0] == 0x03) rd_addr = (uint32_t)cmd[1] << 16 | cmd[2] << 8 | cmd[3];
    return miso;
}

static void spi_cs_off(void)
{
    uint32_t a = ncmd >= 4 ? ((uint32_t)cmd[1] << 16 | cmd[2] << 8 | cmd[3]) % FL_SIZE : 0;
    if (ncmd == 0 || fl_busy()) { ncmd = 0; return; }
    if (cmd[0] == 0x06 && ncmd == 1) wel = 1;
    else if (cmd[0] == 0x20 && ncmd == 4 && wel) {
        memset(flash + (a & ~0xFFFu), 0xFF, 4096);
        busy_until = now_us + 40000 + (uint64_t)(rand() % 410000);    /* 40 .. 450 ms */
        wel = 0;
    } else if (cmd[0] == 0x02 && ncmd > 4 && wel) {
        for (int i = 4; i < ncmd && i < 260; i++)                     /* wraps inside the page */
            flash[(a & ~0xFFu) | ((a + i - 4) & 0xFFu)] &= cmd[i];
        busy_until = now_us + 700 + (uint64_t)(rand() % 2000);
        wel = 0;
    } else if (cmd[0] != 0x05 && cmd[0] != 0x03)
        wel = 0;
    ncmd = 0;
}

/* pass-through register: a started byte is busy for busy_us (the link takes 10 us per access) */
static uint32_t pt_q, busy_us = 5;
static uint64_t pt_until;
static int      pt_en;

uint32_t hw_rd(uint8_t r)
{
    tick();
    if (r == 0x18) return (uint32_t)(now_us * 56);
    if (r == 0x40) {
        return (now_us < pt_until ? FL_BUSY : 0) | pt_q;
    }
    return 0;
}

void hw_wr(uint8_t r, uint32_t v)
{
    tick();
    if (r == 0x44) { if (v & 1) reloads++; return; }
    if (r != 0x40) return;
    if (now_us < pt_until) return;                  /* ignored, as in the RTL */
    pt_en = (v & FL_EN) != 0;
    int ncs = !(v & FL_CS) || !pt_en;
    if (ncs && cs) spi_cs_off();
    cs = !ncs;
    if (v & FL_START) { pt_q = cs ? spi_byte((uint8_t)v) : 0xFF; pt_until = now_us + busy_us; }
}

/* checks */
static void progress(const char *t) { (void)t; }

static int image_right(void) { return memcmp(flash + ROM_BASE, expect, ROM_LEN) == 0; }

static long run_install(long cut_after, int *r)
{
    accesses = 0;
    cut_at = cut_after;
    pt_until = 0;                               /* the pass-through keeps its chip select */
    if (setjmp(cut)) { cut_at = -1; return 1; }
    *r = c64_rom_install(progress);
    cut_at = -1;
    return 0;
}

static void load(const char *path, uint32_t off, uint32_t len)
{
    FILE *f = fopen(path, "rb");
    if (!f || fread(expect + off, 1, len, f) != len) { printf("ERROR: %s\n", path); exit(2); }
    fclose(f);
}

int main(int argc, char **argv)
{
    int r = 0, cuts = 0, looked_valid = 0;
    long full;

    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc < 3 || !(card = fopen(argv[1], "rb"))) { printf("usage: c64rom_test card.img romdir [busy_us]\n"); return 2; }
    if (argc > 3) busy_us = (uint32_t)atoi(argv[3]);
    if (fat_mount() != FAT_OK) { printf("ERROR: mount\n"); return 2; }
    memset(expect, 0xFF, sizeof expect);
    expect[0] = 0xF3; memcpy(expect + 1, "L64 ROMS    ", 12); expect[13] = 1;
    char p[512];
    snprintf(p, sizeof p, "%s/char.bin", argv[2]);    load(p, 4096, 4096);
    snprintf(p, sizeof p, "%s/basic.bin", argv[2]);   load(p, 8192, 8192);
    snprintf(p, sizeof p, "%s/kernal.bin", argv[2]);  load(p, 16384, 8192);
    snprintf(p, sizeof p, "%s/dos1541.bin", argv[2]); load(p, 32768, 16384);
    srand(1);

    /* 1: the hardware state */
    memset(flash, 0xFF, sizeof flash);
    memcpy(flash + ROM_BASE, expect, ROM_LEN);
    memset(flash + ROM_BASE, 0xFF, 14);
    if (c64_rom_present()) { printf("ERROR: header FF taken as installed\n"); errors++; }
    run_install(-1, &r);
    full = accesses;
    if (r || !image_right() || !c64_rom_present() || reloads != 1) {
        printf("ERROR: install from the hardware state: r=%d right=%d present=%d reloads=%d\n",
               r, image_right(), c64_rom_present(), reloads);
        errors++;
    }
    printf("full install: %ld register accesses, %.2f s modelled\n", full, now_us / 1e6);

    /* 2 + 3: cut-offs, each followed by a full install */
    for (int n = 0; n < 300; n++) {
        long at = 1 + rand() % full;
        if (n < 20) at = full - n;                  /* the last accesses: header write / check */
        if (run_install(at, &r) == 0) continue;     /* finished before the cut */
        cuts++;
        now_us += 1000000;                          /* the ESP32 restarts: the flash finishes */
        if (c64_rom_present()) {
            looked_valid++;
            if (!image_right()) { printf("ERROR: cut at %ld: header present, image wrong\n", at); errors++; }
        }
        reloads = 0;
        run_install(-1, &r);
        if (r || !image_right() || reloads != 1) {
            printf("ERROR: install after cut at %ld: r=%d right=%d\n", at, r, image_right());
            errors++;
        }
    }
    printf("%d cut-offs (%d left a valid image), %d errors\n", cuts, looked_valid, errors);
    printf(errors ? "FAIL\n" : "PASS\n");
    return errors ? 1 : 0;
}
