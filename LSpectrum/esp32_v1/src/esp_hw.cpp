// esp_hw.cpp -- the platform under the SD tape loader firmware: SPI link to the FPGA
// (rtl/esp_link.v), register proxies (hw.h), pulse FIFO
// bursts (hal.h), OSD text (osd.h), SD card sectors (hal.h / sd.h) and the loader task.
//
// Link: HSPI, mode 0, 8 MHz. SCK GPIO14 -> FPGA AB13, MOSI GPIO13 -> AA13, CS GPIO33 -> AB14,
// MISO GPIO35 <- AA14, IRQ GPIO34 <- AB15 (not used). SD card: VSPI, SCK 18, MISO 19, MOSI 23, CS 5.
//
// Writes that come in streams are collected and sent as one link frame before any other register
// access: pulse FIFO commands, OSD text, Spectrum memory writes. Spectrum memory reads (snapshot
// saving) are fetched 256 bytes at a time. Everything else is one link frame per access.
#include <Arduino.h>
#include <SPI.h>
#include <SD.h>
#include <driver/gpio.h>
#include <esp_heap_caps.h>
#include <Update.h>
#include "hw.h"
#include "hal.h"
#include "osd.h"
#include "sd.h"
#include "loader.h"
#include "espupd.h"
#include "flash.h"
#include "reset.h"
#include <setjmp.h>

int loader_main(void);

static const int L_SCK = 14, L_MOSI = 13, L_CS = 33, L_MISO = 35, L_IRQ = 34;
static const int SD_SCK = 18, SD_MISO = 19, SD_MOSI = 23, SD_CS = 5;
static const uint32_t LINK_HZ = 8000000;
static const uint32_t ID_ZX  = 0x5A580001;       // LSpectrum ("ZX"), link version 1
static const uint32_t ID_C64 = 0x43360002;       // L64 ("C6"), link version 2: C64 ROMs at flash 0x580000
static const uint32_t ID_AT  = 0x41540001;       // LTari ("AT"), link version 1
static const uint32_t ID_MN  = 0x4D4E0001;       // the machine menu ("MN"): flash update, link version 1
static const uint32_t ID_MN2 = 0x4D4E0002;       // the same, link version 2: + flash stream frames (FLS)
static uint32_t core_id;                         // the machine found (probe)
static bool     fls_ok;                          // flash stream frames work (menu link version 2)
int machine_c64;                                 // hw.h: 1 = L64
int machine_atari;                               // hw.h: 1 = LTari
int machine_menu;                                // hw.h: 1 = the machine menu (AMenu)

enum { CMD_WR = 1, CMD_RD = 2, CMD_OSD = 3, CMD_FIFO = 4, CMD_MWR = 5, CMD_MRD = 6, CMD_STAT = 7, CMD_FLS = 8 };
enum { R_ID = 0x00, R_IRQ = 0x04, R_FIFO = 0x0C, R_TIMER = 0x18, R_SNAPCTL = 0x2C, R_SNAPCMD = 0x30, R_SNAPDAT = 0x34 };
enum { C_MRD = 1, C_MWR = 2 };                    // snapshot port commands (snap.cpp)
static const uint32_t SPEC_MEM = 0x40000;         // 18-bit Spectrum memory address space

static SPIClass linkspi(HSPI);
static SPIClass sdspi(VSPI);
static bool link_up;
static volatile bool running;                     // a loader task runs (cleared by the menu task when it ends)
static TaskHandle_t loader_th;                    // the loader task (stall report, loader_check)
static volatile uint32_t frame_ms;                // millis() of the last link frame (stall check)
static volatile uint32_t frames;                  // link frames sent

//-----------------------------------------------------------------------------
// link frames
//-----------------------------------------------------------------------------
static uint8_t ftx[1100], frx[1100];

static void frame(size_t n)
{
    linkspi.beginTransaction(SPISettings(LINK_HZ, MSBFIRST, SPI_MODE0));
    digitalWrite(L_CS, LOW);
    delayMicroseconds(1);                         // >= 100 ns CS -> first SCK
    linkspi.transferBytes(ftx, frx, n);
    delayMicroseconds(1);
    digitalWrite(L_CS, HIGH);
    linkspi.endTransaction();
    delayMicroseconds(1);
    frame_ms = millis();
    frames = frames + 1;
}

static void link_wr(uint8_t r, uint32_t v)
{
    ftx[0] = CMD_WR; ftx[1] = r;
    ftx[2] = v >> 24; ftx[3] = v >> 16; ftx[4] = v >> 8; ftx[5] = v;
    frame(6);
}

static uint32_t link_rd(uint8_t r)
{
    ftx[0] = CMD_RD; ftx[1] = r;
    memset(ftx + 2, 0, 5);
    frame(7);
    return (uint32_t)frx[3] << 24 | (uint32_t)frx[4] << 16 | (uint32_t)frx[5] << 8 | frx[6];
}

//-----------------------------------------------------------------------------
// collected writes
//-----------------------------------------------------------------------------
static uint32_t fifo_buf[200];
static int      fifo_n;
static uint8_t  osd_sh[OSD_COLS * OSD_ROWS];
static int      osd_lo = OSD_COLS * OSD_ROWS, osd_hi;      // dirty range [lo, hi)
static uint8_t  mwr_buf[1024];
static uint32_t mwr_a;
static int      mwr_n;
static uint8_t  mrd_buf[256];
static uint32_t mrd_a;
static int      mrd_n;                                     // 0 = cache empty

static void flush_fifo()
{
    if (!fifo_n) return;
    ftx[0] = CMD_FIFO;
    for (int i = 0; i < fifo_n; i++) {
        uint32_t c = fifo_buf[i];
        ftx[1 + 4 * i] = c >> 24; ftx[2 + 4 * i] = c >> 16; ftx[3 + 4 * i] = c >> 8; ftx[4 + 4 * i] = c;
    }
    frame(1 + 4 * fifo_n);
    fifo_n = 0;
}

static void flush_osd()
{
    if (osd_lo >= osd_hi) return;
    int n = osd_hi - osd_lo;
    ftx[0] = CMD_OSD; ftx[1] = osd_lo >> 8; ftx[2] = osd_lo;
    memcpy(ftx + 3, osd_sh + osd_lo, n);
    frame(3 + n);
    osd_lo = OSD_COLS * OSD_ROWS;
    osd_hi = 0;
}

static void flush_mwr()
{
    if (!mwr_n) return;
    ftx[0] = CMD_MWR; ftx[1] = mwr_a >> 16; ftx[2] = mwr_a >> 8; ftx[3] = mwr_a;
    memcpy(ftx + 4, mwr_buf, mwr_n);
    frame(4 + mwr_n);
    delayMicroseconds(2);                         // the last byte's write finishes after the frame
    mwr_n = 0;
}

static void flush_all()
{
    flush_fifo();
    flush_osd();
    flush_mwr();
}

//-----------------------------------------------------------------------------
// register proxies (hw.h)
//-----------------------------------------------------------------------------
static uint32_t snap_dat, snap_res;
static bool     snap_done;                        // a command finished here: the next SNAPCTL read is not busy
static uint32_t t_yield, t_check;

static uint32_t timer56() { return (uint32_t)(esp_timer_get_time() * 56); }

// The loader polls registers in tight loops: let the other tasks on this core run now and then.
// Every 0.5 s it also checks that the FPGA was not reset (KEY0 resets the loader hardware: the
// IRQ mask set at start reads 0 again); the firmware's state would then not match, so restart.
// Leaving the machine menu is the exception: the menu's task only ends (menu_present() = 0) and
// the next probe starts the machine, so the ESP32 does not restart and a Bluetooth connection
// being set up at power-up is not cut (a restart there broke the A2DP audio on hardware).
static volatile bool menu_left;
// A machine left (another core on the link: the menu after KEY1 / Ctrl+Alt+Del, or a reconfiguration):
// the loader is left from wherever it polls the link (housekeeping) back to loader_task, which puts
// every module back to its start state; the next probe starts the loader for the new core. No ESP32
// restart, so the Bluetooth connection stays. KEY0 (the same core, its IRQ mask cleared) still
// restarts the ESP32: "everything".
static jmp_buf leave_jb;

int menu_present(void) { return !menu_left; }

static void housekeeping()
{
    uint32_t now = millis();
    if (now - t_yield >= 20) { vTaskDelay(1); t_yield = millis(); }
    if (now - t_check >= 500) {
        t_check = now;
        uint32_t id = link_rd(R_ID), irq = link_rd(R_IRQ);
        if (id != core_id || !(irq & 0xF00)) {
            if (machine_menu) { menu_left = true; return; }
            if (id != core_id) {
                Serial.printf("\r\nloader: the machine left (id %08lx): loader starts again, no restart\r\n",
                              (unsigned long)id);
                longjmp(leave_jb, 1);
            }
            Serial.printf("\r\nloader: FPGA reset or reconfigured (id %08lx, irq %08lx): restarting the ESP32\r\n",
                          (unsigned long)id, (unsigned long)irq);
            delay(50);
            esp_restart();
        }
    }
}

void log_line(const char *s) { Serial.printf("loader: %s\r\n", s); }

//-----------------------------------------------------------------------------
// flash stream (flash.h): one FLS frame, then STAT for its error flag
//-----------------------------------------------------------------------------
// on the heap, allocated on first use: only the menu mode streams (static RAM chops the Bluetooth audio)
#define FLS_BUF (1 + 4 + FL_STREAM_MAX + 2)
static uint8_t *fls_tx, *fls_rx;

int fl_stream(const uint8_t *hdr, uint32_t nh, const uint8_t *data, uint8_t *rx, uint32_t n)
{
    size_t len = 1 + nh + n + (rx ? 2 : 0);
    if (!fls_ok || nh > 4 || n > FL_STREAM_MAX) return -1;
    if (!fls_tx) {
        fls_tx = (uint8_t *)malloc(FLS_BUF);
        fls_rx = (uint8_t *)malloc(FLS_BUF);
        if (!fls_tx || !fls_rx) { free(fls_tx); free(fls_rx); fls_tx = fls_rx = nullptr; fls_ok = false; return -1; }
    }
    housekeeping();
    flush_all();
    ftx[0] = CMD_STAT;                            // clear an older error first
    memset(ftx + 1, 0, 5);
    frame(6);
    fls_tx[0] = CMD_FLS;
    memcpy(fls_tx + 1, hdr, nh);
    if (data) memcpy(fls_tx + 1 + nh, data, n); else memset(fls_tx + 1 + nh, 0, n);
    if (rx) fls_tx[len - 2] = fls_tx[len - 1] = 0;
    linkspi.beginTransaction(SPISettings(LINK_HZ, MSBFIRST, SPI_MODE0));
    digitalWrite(L_CS, LOW);
    delayMicroseconds(1);
    linkspi.transferBytes(fls_tx, fls_rx, len);
    delayMicroseconds(1);
    digitalWrite(L_CS, HIGH);
    linkspi.endTransaction();
    delayMicroseconds(1);
    ftx[0] = CMD_STAT;
    memset(ftx + 1, 0, 5);
    frame(6);
    if (frx[2] & 0x80) {                          // a byte was late or dropped: no stream from now on
        fls_ok = false;
        Serial.printf("loader: flash stream error, byte-wise from now on\r\n");
        return -1;
    }
    if (rx) memcpy(rx, fls_rx + 1 + nh + 2, n);   // the flash's byte for frame byte k comes in byte k + 2
    return 0;
}

int link_alive(void)
{
    return link_rd(R_ID) == core_id && (link_rd(R_IRQ) & 0xF00) != 0;
}

static void snap_command(uint32_t v)
{
    uint32_t c = v >> 28, a = v & (SPEC_MEM - 1);
    snap_done = true;
    if (c == C_MWR) {
        mrd_n = 0;
        if (mwr_n && (a != mwr_a + (uint32_t)mwr_n || mwr_n == (int)sizeof mwr_buf)) flush_mwr();
        if (!mwr_n) mwr_a = a;
        mwr_buf[mwr_n++] = (uint8_t)snap_dat;
        snap_res = 0;
        return;
    }
    flush_all();
    if (c == C_MRD) {
        if (!mrd_n || a < mrd_a || a >= mrd_a + (uint32_t)mrd_n) {
            int n = SPEC_MEM - a < sizeof mrd_buf ? SPEC_MEM - a : sizeof mrd_buf;
            ftx[0] = CMD_MRD; ftx[1] = a >> 16; ftx[2] = a >> 8; ftx[3] = a; ftx[4] = 0;
            memset(ftx + 5, 0, n);
            frame(5 + n);
            memcpy(mrd_buf, frx + 5, n);
            mrd_a = a;
            mrd_n = n;
        }
        snap_res = mrd_buf[a - mrd_a];
        return;
    }
    mrd_n = 0;                                    // registers, LOAD, AY, ports: done in the FPGA
    link_wr(R_SNAPDAT, snap_dat);
    link_wr(R_SNAPCMD, v);
    uint32_t t0 = millis();
    while ((link_rd(R_SNAPCTL) & SNAP_BUSY) && millis() - t0 < 100) {}
    snap_res = link_rd(R_SNAPDAT);
}

uint32_t hw_rd(uint8_t r)
{
    if (r == R_TIMER) return timer56();
    if (r == R_SNAPCTL && snap_done) { snap_done = false; return SNAP_FROZEN; }
    if (r == R_SNAPDAT) return snap_res;
    housekeeping();
    flush_all();
    return link_rd(r);
}

void hw_wr(uint8_t r, uint32_t v)
{
    if (r == R_SNAPDAT) { snap_dat = v; return; }
    if (r == R_SNAPCMD) { snap_command(v); return; }
    flush_all();
    if (r == R_SNAPCTL) mrd_n = 0;                // the Spectrum runs again / stops: memory may change
    link_wr(r, v);
}

//-----------------------------------------------------------------------------
// hal.h / osd.h / sd.h
//-----------------------------------------------------------------------------
void fifo_push(uint32_t cmd)
{
    if (fifo_n == (int)(sizeof fifo_buf / sizeof fifo_buf[0])) flush_fifo();
    fifo_buf[fifo_n++] = cmd;
}

void osd_clear(void)
{
    osd_text(0, 0, "", OSD_COLS, 0);
    for (int r = 1; r < OSD_ROWS; r++) osd_text(r, 0, "", OSD_COLS, 0);
}

void osd_text(int row, int col, const char *s, int width, int inv)
{
    if (row < 0 || row >= OSD_ROWS || col < 0 || col >= OSD_COLS) return;
    uint8_t m = inv ? 0x80 : 0x00;
    int a = row * OSD_COLS + col, i;
    for (i = 0; i < width && col + i < OSD_COLS; i++) {
        uint8_t c = (uint8_t)(*s ? *s++ : ' ');
        if (c < 0x20 || c > 0x7F) c = '?';
        c |= m;
        if (osd_sh[a + i] != c) {
            osd_sh[a + i] = c;
            if (a + i < osd_lo) osd_lo = a + i;
            if (a + i + 1 > osd_hi) osd_hi = a + i + 1;
        }
    }
}

void osd_show(int full) { OSDC = OSD_ON | (full ? OSD_FULL : 0); }
void osd_hide(void)     { OSDC = 0; }

static bool sd_ok;

int sd_init(void)
{
    static const uint32_t hz[] = {20000000, 4000000};
    SD.end();
    sd_ok = false;
    for (uint32_t f : hz) {
        sdspi.end();
        sdspi.begin(SD_SCK, SD_MISO, SD_MOSI, SD_CS);
        gpio_pullup_en((gpio_num_t)SD_MISO);
        if (SD.begin(SD_CS, sdspi, f)) {
            sd_ok = true;
            Serial.printf("loader: SD card %llu MB at %lu MHz\r\n", SD.cardSize() >> 20, (unsigned long)(f / 1000000));
            return 0;
        }
        SD.end();
    }
    Serial.print("loader: no SD card\r\n");
    return -1;
}

int sd_ready(void) { return sd_ok; }

int sd_read(uint32_t lba, uint8_t *buf)
{
    if (!sd_ok) return -1;
    if (SD.readRAW(buf, lba)) return 0;
    sd_ok = false;
    return -1;
}

int sd_write(uint32_t lba, const uint8_t *buf)
{
    if (!sd_ok) return -1;
    if (SD.writeRAW(const_cast<uint8_t *>(buf), lba)) return 0;
    sd_ok = false;
    return -1;
}

//-----------------------------------------------------------------------------
// loader.h
//-----------------------------------------------------------------------------
static uint32_t t_probe;

// the link-side state back to the start (frames collected for the old core are dropped)
static void link_reset()
{
    fifo_n = 0;
    memset(osd_sh, 0, sizeof osd_sh);
    osd_lo = OSD_COLS * OSD_ROWS;
    osd_hi = 0;
    mwr_n = 0;
    mwr_a = 0;
    mrd_n = 0;
    mrd_a = 0;
    snap_dat = snap_res = 0;
    snap_done = false;
}

static void loader_task(void *)
{
    t_yield = t_check = millis();
    if (setjmp(leave_jb) == 0) {
        loader_main();                            // returns only when the machine menu is left
        Serial.print("loader: the menu is gone, waiting for the machine\r\n");
    }
    link_reset();
    loader_reset_all();
    t_probe = millis();
    loader_th = nullptr;
    running = false;                              // loader_poll probes for the machine
    vTaskDelete(nullptr);
}

// A core ID with a few wrong bits or shifted by one bit: link bit errors, not the menu (whose
// unused MISO pin floats and reads as noise) or no FPGA (0 / FFFFFFFF)
static bool near_id(uint32_t id, uint32_t want)
{
    return __builtin_popcount(id ^ want) <= 6 || id == want << 1 || id == want >> 1;
}

static bool probe()
{
    uint32_t id = link_rd(R_ID);
    if (id != ID_ZX && id != ID_C64 && id != ID_AT && id != ID_MN && id != ID_MN2) {
        if (near_id(id, ID_ZX) || near_id(id, ID_C64) || near_id(id, ID_AT) || near_id(id, ID_MN) || near_id(id, ID_MN2))
            Serial.printf("loader: core id %08lx read with bit errors (link timing?)\r\n", (unsigned long)id);
        return false;
    }
    core_id     = id;
    menu_left   = false;
    machine_c64 = id == ID_C64;
    machine_atari = id == ID_AT;
    machine_menu  = id == ID_MN || id == ID_MN2;
    fls_ok        = id == ID_MN2;
    link_wr(R_IRQ, 0x100);                        // mask bit for the FPGA reset check (housekeeping)
    return (link_rd(R_IRQ) & 0xF00) != 0;
}

static void start_if_found()
{
    if (running || !probe()) return;
    running = true;
    Serial.printf("loader: %s found, %s, free heap %u bytes, largest block %u\r\n",
                  machine_menu ? "the menu" : machine_c64 ? "L64" : machine_atari ? "LTari" : "LSpectrum",
                  machine_menu ? "flash update ready (LUPDATE.BIN)" : "SD loader running (F12)", (unsigned)ESP.getFreeHeap(),
                  (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_8BIT));
    frame_ms = millis();
    xTaskCreatePinnedToCore(loader_task, "loader", 16384, nullptr, 1, &loader_th, 1);
}

void loader_begin(void)
{
    pinMode(L_CS, OUTPUT);
    digitalWrite(L_CS, HIGH);
    pinMode(L_IRQ, INPUT);
    linkspi.begin(L_SCK, L_MISO, L_MOSI, -1);
    link_up = true;
    uint32_t t0 = millis();
    while (!running && millis() - t0 < 3000) {    // the FPGA may still be configuring / loading ROMs
        start_if_found();
        if (!running) delay(100);
    }
    if (!running) Serial.print("loader: no machine on the link yet (menu shown, or FPGA not configured): retrying every 2 s\r\n");
    t_probe = millis();
}

void loader_poll(void)
{
    if (!link_up || running || millis() - t_probe < 2000) return;
    t_probe = millis();
    start_if_found();
}

bool loader_running(void) { return running; }

// The loader task's state and the code addresses on its stack (a rough call chain: decode with
// xtensa-esp32-elf-addr2line -e esp32_v1.ino.elf). The saved context starts at pxTopOfStack (the
// TCB's first word): exit, pc, ps, ...
static void loader_report(Print &out)
{
    static const char *const st[] = {"running", "ready", "blocked", "suspended", "deleted", "invalid"};
    TaskHandle_t th = loader_th;
    out.printf("loader: running=%d core %08lx frames=%lu last frame %lu ms ago\r\n", (int)running,
               (unsigned long)core_id, (unsigned long)frames, (unsigned long)(millis() - frame_ms));
    if (!running || !th) return;
    eTaskState ts = eTaskGetState(th);
    out.printf("loader: task %s, stack left %u bytes\r\n", st[ts <= 5 ? ts : 5],
               (unsigned)uxTaskGetStackHighWaterMark(th));
    if (ts == eRunning) return;                   // on the other core's view: no saved context
    uint32_t *sp = *(uint32_t **)th;
    if ((uint32_t)sp < 0x3FFB0000u || (uint32_t)sp >= 0x40000000u) return;
    out.printf("loader: pc %08lx, code on the stack:", (unsigned long)sp[1]);
    int n = 0;
    for (int i = 2; i < 1024 && n < 24; i++) {
        uint32_t *w = sp + i;
        if ((uint32_t)w >= 0x40000000u) break;
        uint32_t a = (*w & 0x3FFFFFFFu) | 0x40000000u;   // windowed call: top 2 bits = window size
        if ((*w >> 30) && ((a >= 0x400D0000u && a < 0x40400000u) || (a >= 0x40080000u && a < 0x400A0000u))) {
            out.printf(" %08lx", (unsigned long)a);
            n++;
        }
    }
    out.print("\r\n");
}

void loader_info(Print &out) { loader_report(out); }

// loop(): a loader that sends no link frame for 3 s on a machine is stuck (every loop of the
// loader reads registers): report where, and after 15 s restart the ESP32 as KEY0 would. The
// machine menu is left out (the ESP32 firmware update writes flash for a while without frames).
void loader_check(void)
{
    static uint32_t t_rep;
    if (!running || machine_menu) { t_rep = 0; return; }
    uint32_t idle = millis() - frame_ms;
    if (idle < 3000) { t_rep = 0; return; }
    if (!t_rep || millis() - t_rep >= 5000) {
        t_rep = millis();
        Serial.print("\r\nloader: STALLED (no link frame)\r\n");
        loader_report(Serial);
    }
    if (idle >= 15000) {
        Serial.print("loader: stalled for 15 s, restarting the ESP32\r\n");
        delay(50);
        esp_restart();
    }
}

//-----------------------------------------------------------------------------
// espupd.h: the ESP32's own firmware from the SD card (the Arduino Update class = esp_ota_*)
//-----------------------------------------------------------------------------
int ota_begin(uint32_t size)
{
    if (Update.begin(size, U_FLASH)) return 0;
    Serial.printf("loader: firmware update: begin failed (%s)\r\n", Update.errorString());
    return -1;
}

int ota_write(const uint8_t *d, uint32_t n)
{
    if (Update.write(const_cast<uint8_t *>(d), n) == n) return 0;
    Serial.printf("loader: firmware update: write failed (%s)\r\n", Update.errorString());
    return -1;
}

int ota_end(void)
{
    if (Update.end(true)) return 0;
    Serial.printf("loader: firmware update: image rejected (%s)\r\n", Update.errorString());
    return -1;
}

void ota_abort(void) { Update.abort(); }

void esp_reboot(void)
{
    Serial.print("loader: new firmware installed, restarting the ESP32\r\n");
    delay(50);
    esp_restart();
}
