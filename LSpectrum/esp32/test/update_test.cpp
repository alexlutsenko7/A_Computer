/* update_test.cpp -- PC test of the flash update (update.cpp, flash.cpp, fat.cpp as C++)
 *
 * The flash and the pass-through register are modelled as in c64rom_test.cpp (4 KB erase, page
 * program, busy times, a write while a byte shifts is ignored); TIMER advances 10 us per register
 * access. Usage: update_test card.img LUPDATE.BIN (card.img holds LUPDATE.BIN in its root; the test
 * works on copies of it)
 *   1. old flash (a few machine sectors and one menu sector differ, C64 ROM area with data): update,
 *      flash = image outside the C64 area, C64 area untouched, menu_changed, file deleted
 *   2. flash already equal: nothing written, menu_changed 0
 *   3. a damaged file: rejected by upd_check, flash untouched
 *   4. updates cut off after a random number of register accesses (power off / ESP32 restart): the
 *      menu sectors are only touched after every machine sector is right; the file is still there;
 *      a full update afterwards gives the image
 *   5. no machines: upd_machines_present on an empty flash / after the loader
 *   6, 7. first install on a loader board (FF / 00 after the menu)
 *   8. the same with an old menu (link version 1: no flash stream, byte-wise)
 *   9. the same with a stream that breaks (a dropped byte) in the middle: byte-wise from there on
 * The flash stream (fl_stream, the link's FLS frame) is modelled as one register access plus
 * 1 us per byte; tests 1-7 use it.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <setjmp.h>
#include "../src/hw.h"
#include "../src/hal.h"
#include "../src/fat.h"
#include "../src/update.h"
#include "../src/flash.h"
#undef main

#define FL_SIZE  0x800000u
#define MENU_END 0x080000u
#define SKIP_LO  0x200000u
#define SKIP_HI  0x280000u

static uint8_t  flash[FL_SIZE], img[FL_SIZE], old[FL_SIZE];
static uint32_t img_len;
static FILE    *card;
static const char *card_src;
static int      errors;

/* card: a working copy, read and written */
int sd_read(uint32_t lba, uint8_t *buf)
{
    if (fseek(card, (long)lba * 512, SEEK_SET) || fread(buf, 512, 1, card) != 1) return -1;
    return 0;
}
int sd_write(uint32_t lba, const uint8_t *buf)
{
    if (fseek(card, (long)lba * 512, SEEK_SET) || fwrite(buf, 512, 1, card) != 1) return -1;
    return 0;
}
uint32_t fifo_free(void) { return 512; }
int link_alive(void) { return 1; }
void fifo_push(uint32_t c) { (void)c; }

static void fresh_card(void)
{
    FILE *s = fopen(card_src, "rb");
    if (card) fclose(card);
    card = fopen("work_card.img", "w+b");
    if (!s || !card) { printf("ERROR: card copy\n"); exit(2); }
    static uint8_t b[65536];
    size_t n;
    while ((n = fread(b, 1, sizeof b, s)) > 0) fwrite(b, 1, n, card);
    fclose(s);
    fflush(card);
    if (fat_mount() != FAT_OK) { printf("ERROR: mount\n"); exit(2); }
}

/* time, cut-off */
static uint64_t now_us;
static long     accesses, cut_at = -1;
static jmp_buf  cut;

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
static long     erases;

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
        busy_until = now_us + 40000 + (uint64_t)(rand() % 410000);
        wel = 0;
        erases++;
    } else if (cmd[0] == 0x02 && ncmd > 4 && wel) {
        for (int i = 4; i < ncmd && i < 260; i++)
            flash[(a & ~0xFFu) | ((a + i - 4) & 0xFFu)] &= cmd[i];
        busy_until = now_us + 700 + (uint64_t)(rand() % 2000);
        wel = 0;
    } else if (cmd[0] != 0x05 && cmd[0] != 0x03)
        wel = 0;
    ncmd = 0;
}

static uint32_t pt_q, busy_us = 5;
static uint64_t pt_until;
static int      pt_en;

uint32_t hw_rd(uint8_t r)
{
    tick();
    if (r == 0x18) return (uint32_t)(now_us * 56);
    if (r == 0x40) return (now_us < pt_until ? FL_BUSY : 0) | pt_q;
    return 0;
}

void hw_wr(uint8_t r, uint32_t v)
{
    tick();
    if (r != 0x40) return;
    if (now_us < pt_until) return;
    pt_en = (v & FL_EN) != 0;
    int ncs = !(v & FL_CS) || !pt_en;
    if (ncs && cs) spi_cs_off();
    cs = !ncs;
    if (v & FL_START) { pt_q = cs ? spi_byte((uint8_t)v) : 0xFF; pt_until = now_us + busy_us; }
}

/* the flash stream: stream_on = the menu has it; stream_break = the stream number that drops a byte */
static int  stream_on = 1;
static long streams, stream_break;

int fl_stream(const uint8_t *hdr, uint32_t nh, const uint8_t *data, uint8_t *rx, uint32_t n)
{
    uint32_t i, all = nh + n + (rx ? 2 : 0);
    if (!stream_on) return -1;
    tick();
    if (now_us < pt_until) now_us = pt_until;
    pt_en = 1;
    cs = 1;
    ++streams;
    for (i = 0; i < all; i++) {
        uint8_t b = i < nh ? hdr[i] : i - nh < n && data ? data[i - nh] : 0;
        now_us += 1;
        if (streams == stream_break && i == all / 2) continue;   /* dropped: the FPGA flags it */
        uint8_t q = spi_byte(b);
        if (rx && i >= nh && i - nh < n) rx[i - nh] = q;
    }
    if (streams == stream_break) { stream_on = 0; return -1; }
    return 0;
}

/* checks */
static int in_skip(uint32_t a) { return a >= SKIP_LO && a < SKIP_HI; }

static int flash_is_image(void)
{
    for (uint32_t a = 0; a < img_len; a += 4096)
        if (!in_skip(a) && memcmp(flash + a, img + a, 4096)) return 0;
    return 1;
}
static int skip_untouched(void) { return memcmp(flash + SKIP_LO, old + SKIP_LO, SKIP_HI - SKIP_LO) == 0; }
static int machines_right(void)
{
    for (uint32_t a = MENU_END; a < img_len; a += 4096)
        if (!in_skip(a) && memcmp(flash + a, img + a, 4096)) return 0;
    return 1;
}

static int file_there(void) { DIRENT d; return upd_find(&d) > 0; }

static int run_update(long cut_after, int *menu_changed, uint32_t *written)
{
    DIRENT d;
    int r;
    accesses = 0;
    pt_until = 0;
    if (upd_find(&d) <= 0) return -100;
    cut_at = cut_after;
    if (setjmp(cut)) { cut_at = -1; return -200; }
    r = upd_check(&d, NULL);
    if (!r) r = upd_run(&d, NULL, menu_changed, written);
    cut_at = -1;
    return r;
}

static void old_flash(void)
{
    memcpy(flash, old, FL_SIZE);
}

int main(int argc, char **argv)
{
    int r, mc;
    uint32_t w;
    long full;
    FILE *f;

    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc < 3) { printf("usage: update_test card.img LUPDATE.BIN\n"); return 2; }
    card_src = argv[1];
    if (!(f = fopen(argv[2], "rb"))) { printf("ERROR: %s\n", argv[2]); return 2; }
    static uint8_t h[256];
    if (fread(h, 1, 256, f) != 256) return 2;
    img_len = h[8] | h[9] << 8 | h[10] << 16 | (uint32_t)h[11] << 24;
    memset(img, 0xFF, sizeof img);
    if (fread(img, 1, img_len, f) != img_len) return 2;
    fclose(f);
    srand(1);

    /* the "old" flash: the image with a few machine sectors and one menu sector changed, the C64
       ROM area holding installed ROMs, the rest of the flash erased */
    memcpy(old, img, FL_SIZE);
    static const uint32_t changed[] = { 0x081000u, 0x0F0000u, 0x185000u, 0x300000u, 0x386000u };
    for (uint32_t k = 0; k < 5; k++) old[changed[k] + 17] ^= 0x5A;
    old[0x01000 + 3] ^= 0xFF;                                   /* menu */
    for (uint32_t i = SKIP_LO; i < SKIP_LO + 49152; i++) old[i] = (uint8_t)(i * 7);

    /* 1 */
    fresh_card();
    old_flash();
    erases = 0;
    r = run_update(-1, &mc, &w);
    full = accesses;
    printf("1. update: r=%d written=%u menu_changed=%d erases=%ld, %ld register accesses, %.1f s modelled\n",
           r, w, mc, erases, full, accesses * 10e-6);
    if (r || !flash_is_image() || !skip_untouched() || !mc || w != 6 || file_there()) {
        printf("ERROR 1: image %d skip %d file %d\n", flash_is_image(), skip_untouched(), file_there()); errors++;
    }

    /* 2 */
    fresh_card();
    erases = 0;
    r = run_update(-1, &mc, &w);
    printf("2. up to date: r=%d written=%u menu_changed=%d erases=%ld\n", r, w, mc, erases);
    if (r || w || mc || erases || !flash_is_image() || file_there()) { printf("ERROR 2\n"); errors++; }

    /* 3: a damaged file (one image byte flipped on the card) */
    fresh_card();
    {
        DIRENT d;
        FFILE ff;
        upd_find(&d);
        ff_open(&ff, d.clus, d.size);
        static uint8_t one;
        ff_seek(&ff, 256 + 0x123456);
        one = (uint8_t)(ff_getc(&ff) ^ 1);
        ff_update(&ff, 256 + 0x123456, &one, 1);
    }
    old_flash();
    r = run_update(-1, &mc, &w);
    printf("3. damaged file: r=%d\n", r);
    if (r != UPD_EBAD || memcmp(flash, old, FL_SIZE) || !file_there()) { printf("ERROR 3\n"); errors++; }

    /* 4: cut-offs */
    int cuts = 0, menu_touched = 0;
    for (int n = 0; n < 60; n++) {
        long at = 1 + (((long)rand() << 15) ^ rand()) % full;     /* rand() is 15 bits on Windows */
        fresh_card();
        old_flash();
        r = run_update(at, &mc, &w);
        if (r != -200) continue;
        cuts++;
        now_us += 1000000;                                      /* power off / restart: the flash finishes */
        if (memcmp(flash, old, MENU_END)) {                     /* the menu area was touched */
            menu_touched++;
            if (!machines_right()) { printf("ERROR 4: cut at %ld: menu touched before the machines were right\n", at); errors++; }
        }
        if (!skip_untouched()) { printf("ERROR 4: cut at %ld: C64 ROM area touched\n", at); errors++; }
        if (!file_there()) { printf("ERROR 4: cut at %ld: file deleted\n", at); errors++; }
        r = run_update(-1, &mc, &w);
        if (r || !flash_is_image() || !skip_untouched() || file_there()) {
            printf("ERROR 4: update after cut at %ld: r=%d\n", at, r); errors++;
        }
    }
    printf("4. %d cut-offs (%d in the menu sectors)\n", cuts, menu_touched);

    /* 6: a board shipped with the loader .jic: the menu only, everything else erased */
    fresh_card();
    memset(flash, 0xFF, FL_SIZE);
    memcpy(flash, img, MENU_END);
    memset(old, 0xFF, FL_SIZE);                                 /* for skip_untouched: the C64 area stays erased */
    now_us = 0;
    busy_until = 0;                                             /* the model's clock starts again */
    pt_until = 0;
    erases = 0;
    r = run_update(-1, &mc, &w);
    printf("6. first install on a loader board: r=%d written=%u menu_changed=%d, %.1f s modelled\n",
           r, w, mc, now_us / 1e6);
    if (r || !flash_is_image() || !skip_untouched() || mc || file_there()) { printf("ERROR 6\n"); errors++; }

    /* 7: first install on a board the loader .jic cleared with 00 */
    fresh_card();
    memset(flash, 0x00, FL_SIZE);
    memcpy(flash, img, MENU_END);
    memset(old, 0x00, FL_SIZE);
    now_us = 0; busy_until = 0; pt_until = 0;
    r = run_update(-1, &mc, &w);
    printf("7. first install over 00: r=%d written=%u menu_changed=%d, %.1f s modelled\n", r, w, mc, now_us / 1e6);
    if (r || !flash_is_image() || !skip_untouched() || mc || file_there()) { printf("ERROR 7\n"); errors++; }

    /* 8: an old menu without the stream */
    stream_on = 0;
    fresh_card();
    memset(flash, 0xFF, FL_SIZE);
    memcpy(flash, img, MENU_END);
    memset(old, 0xFF, FL_SIZE);
    now_us = 0; busy_until = 0; pt_until = 0;
    r = run_update(-1, &mc, &w);
    printf("8. first install, old menu (byte-wise): r=%d written=%u, %.1f s modelled\n", r, w, now_us / 1e6);
    if (r || !flash_is_image() || !skip_untouched() || mc || file_there()) { printf("ERROR 8\n"); errors++; }

    /* 9: the stream breaks in the middle of the update (a page program, a sector read) */
    for (long sb = 300; sb <= 301; sb++) {
        stream_on = 1; streams = 0; stream_break = sb;
        fresh_card();
        memset(flash, 0xFF, FL_SIZE);
        memcpy(flash, img, MENU_END);
        now_us = 0; busy_until = 0; pt_until = 0;
        r = run_update(-1, &mc, &w);
        printf("9. stream breaks at stream %ld: r=%d written=%u, %.1f s modelled\n", sb, r, w, now_us / 1e6);
        if (r || !flash_is_image() || !skip_untouched() || mc || file_there() || stream_on) { printf("ERROR 9\n"); errors++; }
    }
    stream_on = 1; stream_break = 0;

    /* 5 */
    memset(flash, 0xFF, FL_SIZE);
    memcpy(flash, img, MENU_END);                               /* the loader .jic: the menu only */
    if (upd_machines_present()) { printf("ERROR 5: loader taken as machines installed\n"); errors++; }
    memset(flash + MENU_END, 0x00, FL_SIZE - MENU_END);          /* the loader .jic: 00 after the menu */
    if (upd_machines_present()) { printf("ERROR 5: zeroed slots taken as machines installed\n"); errors++; }
    memcpy(flash, img, img_len);
    if (!upd_machines_present()) { printf("ERROR 5: machines not seen\n"); errors++; }
    printf("5. machines present: checked\n");

    fclose(card);
    remove("work_card.img");
    printf(errors ? "FAIL (%d errors)\n" : "PASS\n", errors);
    return errors ? 1 : 0;
}
