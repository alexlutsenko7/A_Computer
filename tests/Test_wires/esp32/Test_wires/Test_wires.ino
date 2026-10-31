// Test_wires -- ESP32 side of the ESP32 <-> FPGA wiring test (Test_wires/README.md).
// FPGA: Test_wires/fpga (Test_wires.sof). Board: ESP32 Dev Module (esp32:esp32:esp32, core 3.3.x).
// USB serial 115200, line ending "New Line". The whole test runs at reset and on Enter.
//
// Wires under test (same as LSpectrum, docs/LSpectrum_Connection.docx section 9):
//   FPGA -> ESP32: U7.7 R1 -> GPIO35, U7.8 R2 -> GPIO34, U7.19 F1 -> GPIO22, U7.20 F2 -> GPIO16
//   ESP32 -> FPGA: GPIO14 -> U7.9 P1, GPIO13 -> U7.10 P2, GPIO33 -> U7.11 N1,
//                  GPIO26 -> U7.17 H1, GPIO25 -> U7.18 H2, GPIO17 -> U7.21 E1
//   SD card on the ESP32: SCK GPIO18, MISO GPIO19, MOSI GPIO23, CS GPIO5
//
// How it works: every FPGA output sends a UART frame (115200) that names the FPGA pin it
// leaves on and reports the levels and rising-edge counts the FPGA sees on its 6 inputs.
// The ESP32 samples all its pins every 2 us and decodes the frames in software, so each
// ESP32 input tells which FPGA pin it is really wired to. Then the ESP32 drives patterns
// and pulse bursts on its 6 outputs and checks what the FPGA reports back.
//
// Commands:
//   (Enter) / all     run every test (SD, FPGA -> ESP32, ESP32 -> FPGA levels, pulses)
//   sd                SD card: init + root folder      ls <path>   list an SD folder
//   back              FPGA -> ESP32 wires only (all ESP32 pins stay inputs)
//   fwd               ESP32 -> FPGA levels           fast   ESP32 -> FPGA pulse bursts
//   set <hex>         drive the 6 outputs (bit 0 GPIO14 ... bit 5 GPIO17) and leave them, for a meter
//   watch             print what the FPGA sees once a second; any input stops
//   sdprobe           SD reset command with every assignment of the 4 SD pins (finds swapped SD wires)
//   find              look for the FPGA frames on every free ESP32 pin (where did a wire land?)
//   raw               levels / edge counts / first 120 samples of all 10 pins (all inputs)
//   help
#include <Arduino.h>
#include <SPI.h>
#include <SD.h>
#include <driver/gpio.h>
#include <soc/gpio_reg.h>
#include <esp_cpu.h>
#include <algorithm>
#include "Test_wires.h"

// FPGA -> ESP32; the FPGA marks frames on these with id C1..C4 (in this order)
static const Wire RET[4] = {
    {35, "GPIO35 (D35)", "R1", "U7.7",  "ESP_MISO"},
    {34, "GPIO34 (D34)", "R2", "U7.8",  "ESP_IRQ"},
    {22, "GPIO22 (D22)", "F1", "U7.19", "BT_DATA"},
    {16, "GPIO16 (RX2)", "F2", "U7.20", "BT_TX"},
};
// ESP32 -> FPGA; bit n of the FPGA's level byte / counter n
static const Wire FWD[6] = {
    {14, "GPIO14 (D14)", "P1", "U7.9",  "ESP_SCK"},
    {13, "GPIO13 (D13)", "P2", "U7.10", "ESP_MOSI"},
    {33, "GPIO33 (D33)", "N1", "U7.11", "ESP_CS_N"},
    {26, "GPIO26 (D26)", "H1", "U7.17", "BT_BCLK"},
    {25, "GPIO25 (D25)", "H2", "U7.18", "BT_LRCK"},
    {17, "GPIO17 (TX2)", "E1", "U7.21", "BT_RX"},
};
static const int SD_SCK = 18, SD_MISO = 19, SD_MOSI = 23, SD_CS = 5;

SPIClass sdspi(VSPI);
SPIClass fastspi(HSPI);

//-----------------------------------------------------------------------------
// capture: all 10 pins every 2 us (sample bit k = RET[k], bit 4+k = FWD[k]); 1 us is too fast
// for the loop (two GPIO register reads over the APB bus)
//-----------------------------------------------------------------------------
static const int SAMPLE_US = 2, MAXS = 20000;
static const float BIT = 1e6f / 115200.0f / SAMPLE_US;   // samples per UART bit
static uint16_t smp[MAXS];
static int nsmp;
static uint32_t cap_cycles;                         // length of the last capture

// bit masks per register, built once from RET / FWD
static uint32_t m_in[16], m_in1[16];
static int npack = 10;

static void pack_init()
{
    npack = 10;
    for (int k = 0; k < 10; k++) {
        int g = k < 4 ? RET[k].gpio : FWD[k - 4].gpio;
        m_in[k]  = g < 32 ? 1u << g : 0;
        m_in1[k] = g < 32 ? 0 : 1u << (g - 32);
    }
}

static inline uint16_t pack(uint32_t in, uint32_t in1)
{
    uint16_t v = 0;
    for (int k = 0; k < npack; k++)
        if ((in & m_in[k]) | (in1 & m_in1[k])) v |= 1 << k;
    return v;
}

static void capture(int us)
{
    nsmp = us / SAMPLE_US < MAXS ? us / SAMPLE_US : MAXS;
    const uint32_t step = getCpuFrequencyMhz() * SAMPLE_US;
    Serial.flush();
    portDISABLE_INTERRUPTS();
    uint32_t t = esp_cpu_get_cycle_count();
    uint32_t t_start = t;
    for (int n = 0; n < nsmp; n++) {
        while ((int32_t)(esp_cpu_get_cycle_count() - t) < 0) {}
        t += step;
        smp[n] = pack(REG_READ(GPIO_IN_REG), REG_READ(GPIO_IN1_REG));
    }
    cap_cycles = esp_cpu_get_cycle_count() - t_start;
    uint32_t want = (uint32_t)nsmp * step;
    if (cap_cycles > want + want / 50)
        Serial.printf("WARNING: sampling too slow (%lu instead of %lu cycles): results not valid\n",
                      (unsigned long)cap_cycles, (unsigned long)want);
    portENABLE_INTERRUPTS();
}

//-----------------------------------------------------------------------------
// software UART decode of one sample bit, then frame parsing
//-----------------------------------------------------------------------------
static LineStat decode(int bitn)
{
    LineStat st = {};
    static uint8_t by[2000];
    int nb = 0;
    for (int i = 0; i < nsmp; i++) {
        int b = (smp[i] >> bitn) & 1;
        st.ones += b;
        if (i && b != ((smp[i - 1] >> bitn) & 1)) st.edges++;
    }
    // sync: start after the first idle gap (the FPGA leaves 20 bit times between frames),
    // so a capture that begins inside a byte does not count as a framing error
    int i = 1, high = 0;
    for (; i < nsmp && high < (int)(15 * BIT); i++) high = ((smp[i] >> bitn) & 1) ? high + 1 : 0;
    while (i < nsmp) {
        if (!(((smp[i - 1] >> bitn) & 1) && !((smp[i] >> bitn) & 1))) { i++; continue; }
        float t0 = i - 0.5f;
        int stop = (int)(t0 + 9.5f * BIT);
        if (stop >= nsmp) break;
        if ((smp[(int)(t0 + 0.5f * BIT)] >> bitn) & 1) { i++; continue; }   // glitch
        uint8_t v = 0;
        for (int k = 0; k < 8; k++)
            v |= ((smp[(int)(t0 + (1.5f + k) * BIT)] >> bitn) & 1) << k;
        if ((smp[stop] >> bitn) & 1) {
            if (nb < (int)sizeof by) by[nb++] = v;
            st.bytes++;
        } else st.ferr++;
        i = stop + 1;
    }
    for (int k = 0; k + 10 <= nb; ) {
        if (by[k] != 0xA5) { k++; continue; }
        uint8_t c = 0x5A;
        for (int j = 1; j <= 8; j++) c ^= by[k + j];
        if (c != by[k + 9]) { k++; continue; }
        Frame f;
        f.id = by[k + 1];
        f.lvl = by[k + 2];
        memcpy(f.cnt, &by[k + 3], 6);
        st.frames++;
        if (f.id >= 0xC1 && f.id <= 0xC4) st.id_count[f.id - 0xC1]++;
        else st.other_ids++;
        st.last = f;
        st.have = true;
        k += 10;
    }
    return st;
}

// index of the RET id seen most on this line, or -1
static int main_id(const LineStat &s)
{
    int best = -1;
    for (int k = 0; k < 4; k++)
        if (s.id_count[k] && (best < 0 || s.id_count[k] > s.id_count[best])) best = k;
    return best;
}

//-----------------------------------------------------------------------------
// results for the summary
//-----------------------------------------------------------------------------
enum { R_NONE, R_PASS, R_FAIL };
static int r_sd, r_ret[4], r_fwd[6], r_fast[6], r_spi;
static const char *res(int r) { return r == R_PASS ? "OK" : r == R_FAIL ? "FAIL" : "not tested"; }

static void outputs_off()
{
    for (auto &w : FWD) pinMode(w.gpio, INPUT);
    for (auto &w : RET) pinMode(w.gpio, INPUT);   // also enables the input buffer (off by default on GPIO34/35)
}

static void outputs_on(uint8_t v)
{
    for (int k = 0; k < 6; k++) {
        digitalWrite(FWD[k].gpio, (v >> k) & 1);
        pinMode(FWD[k].gpio, OUTPUT);
        digitalWrite(FWD[k].gpio, (v >> k) & 1);
    }
}

// latest frame from the FPGA over any working return wire (started after this call)
static bool fpga_frame(Frame &f)
{
    delay(3);
    capture(6000);
    for (int k = 0; k < 4; k++) {
        LineStat s = decode(k);
        if (s.have) { f = s.last; return true; }
    }
    return false;
}

static void print_bits6(uint8_t v)
{
    for (int k = 5; k >= 0; k--) Serial.print((v >> k) & 1);
}

//-----------------------------------------------------------------------------
// SD card
//-----------------------------------------------------------------------------
static bool sd_mounted;

static void list_dir(const char *path)
{
    File d = SD.open(path);
    if (!d || !d.isDirectory()) { Serial.printf("  cannot open folder %s\n", path); return; }
    int nd = 0, nf = 0;
    Serial.printf("  folder %s:\n", path);
    while (File f = d.openNextFile()) {
        if (f.isDirectory()) { Serial.printf("    <DIR>        %s\n", f.name()); nd++; }
        else { Serial.printf("    %10lu   %s\n", (unsigned long)f.size(), f.name()); nf++; }
        f.close();
        if (nd + nf >= 500) { Serial.println("    ... (stopped at 500 entries)"); break; }
    }
    d.close();
    Serial.printf("  %d folders, %d files\n", nd, nf);
}

static void test_sd()
{
    Serial.println("\n=== SD card (on the ESP32: SCK 18, MISO 19, MOSI 23, CS 5) ===");
    SD.end();
    sd_mounted = false;
    static const uint32_t hz[] = {20000000, 4000000, 400000};
    for (uint32_t f : hz) {
        sdspi.end();
        sdspi.begin(SD_SCK, SD_MISO, SD_MOSI, SD_CS);
        gpio_pullup_en((gpio_num_t)SD_MISO);        // internal pull-up on MISO (an external 10k-47k is better)
        if (SD.begin(SD_CS, sdspi, f)) {
            sd_mounted = true;
            const char *t = SD.cardType() == CARD_MMC ? "MMC" : SD.cardType() == CARD_SD ? "SDSC"
                          : SD.cardType() == CARD_SDHC ? "SDHC/SDXC" : "unknown";
            Serial.printf("  card found at %lu kHz: %s, %llu MB, FAT used %llu of %llu MB\n", (unsigned long)(f / 1000), t,
                          SD.cardSize() >> 20, SD.usedBytes() >> 20, SD.totalBytes() >> 20);
            if (f != hz[0]) Serial.println("  WARNING: works only at a lower clock: check SCK/MISO/MOSI wiring, length, ground");
            list_dir("/");
            r_sd = f == hz[0] ? R_PASS : R_FAIL;
            return;
        }
        SD.end();
        Serial.printf("  no card at %lu kHz\n", (unsigned long)(f / 1000));
    }
    r_sd = R_FAIL;
    Serial.println("  FAIL: SD card not found. Check: card inserted, 3V3 + GND to the SD board, CS = GPIO5,");
    Serial.println("        SCK = GPIO18, MOSI = GPIO23 -> card DI, MISO = GPIO19 <- card DO (DI/DO swapped is common),");
    Serial.println("        card formatted FAT16/FAT32 (exFAT is not supported).");
}

//-----------------------------------------------------------------------------
// FPGA -> ESP32 (also the safety check: no FPGA output may sit on an ESP32 output pin)
//-----------------------------------------------------------------------------
static bool fwd_safe;     // no FPGA frames on the ESP32 output pins
static bool any_back;     // at least one FPGA -> ESP32 wire carries frames

static void describe_dead(const LineStat &s, const char *pull)
{
    if (s.edges == 0)
        Serial.printf("always %d (%s): wire open, wrong pin, or FPGA not loaded\n", s.ones ? 1 : 0, pull);
    else
        Serial.printf("%d edges but no valid frame (%d bytes, %d framing errors): floating, or shorted to another wire\n",
                      s.edges, s.bytes, s.ferr);
}

static void test_back()
{
    Serial.println("\n=== FPGA -> ESP32 wires (ESP32 pins all inputs) ===");
    outputs_off();
    gpio_pulldown_en((gpio_num_t)22);
    gpio_pulldown_en((gpio_num_t)16);
    delay(5);
    capture(20000);
    any_back = false;
    for (int k = 0; k < 4; k++) {
        const Wire &w = RET[k];
        LineStat s = decode(k);
        int m = main_id(s);
        Serial.printf("  %-13s expects FPGA %s %-5s (%-8s): ", w.esp, w.fpga, w.u7, w.sig);
        if (s.frames == 0) {
            describe_dead(s, w.gpio >= 34 ? "input-only pin, no pull resistor" : "ESP32 pull-down");
            r_ret[k] = R_FAIL;
            continue;
        }
        any_back = true;
        int mixed = s.frames - s.id_count[m];
        if (m == k && mixed == 0 && s.ferr == 0) {
            Serial.printf("OK (%d frames)\n", s.frames);
            r_ret[k] = R_PASS;
        } else if (m == k) {
            Serial.printf("right pin but unreliable: %d good frames, %d from other pins, %d framing errors (short / noise?)\n",
                          s.id_count[m], mixed, s.ferr);
            r_ret[k] = R_FAIL;
        } else if (m < 0) {
            Serial.printf("frames with unknown id: noise\n");
            r_ret[k] = R_FAIL;
        } else {
            Serial.printf("SWAPPED: wired to FPGA %s %s (%s)\n", RET[m].fpga, RET[m].u7, RET[m].sig);
            r_ret[k] = R_FAIL;
        }
    }
    gpio_pulldown_dis((gpio_num_t)22);
    gpio_pulldown_dis((gpio_num_t)16);

    // the ESP32 output pins, still inputs: an FPGA output there would fight the ESP32
    fwd_safe = true;
    for (int k = 0; k < 6; k++) {
        LineStat s = decode(4 + k);
        int m = main_id(s);
        if (m >= 0) {
            Serial.printf("  DANGER: %s (should go to FPGA input %s %s) carries FPGA output %s %s (%s)\n",
                          FWD[k].esp, FWD[k].fpga, FWD[k].u7, RET[m].fpga, RET[m].u7, RET[m].sig);
            fwd_safe = false;
        }
    }
    if (!fwd_safe)
        Serial.println("  ESP32 -> FPGA tests are skipped until this is fixed (two outputs would fight).");
    if (!any_back)
        Serial.println("  No frames from the FPGA at all: is Test_wires.sof loaded (LED blinking)? Common GND wire? "
                       "Without a working return wire the ESP32 -> FPGA tests cannot run.");
}

//-----------------------------------------------------------------------------
// ESP32 -> FPGA, static levels
//-----------------------------------------------------------------------------
static void test_fwd()
{
    Serial.println("\n=== ESP32 -> FPGA wires, levels (14 patterns) ===");
    if (!fwd_safe || !any_back) { Serial.println("  skipped (see above)"); return; }
    uint8_t pat[14], obs[14];
    int np = 0;
    pat[np++] = 0x00;
    pat[np++] = 0x3F;
    for (int k = 0; k < 6; k++) pat[np++] = 1 << k;
    for (int k = 0; k < 6; k++) pat[np++] = 0x3F ^ (1 << k);
    outputs_on(0);
    Serial.println("  ESP32 drives   FPGA sees   (bit order: GPIO17 25 26 33 13 14 = E1 H2 H1 N1 P2 P1)");
    for (int t = 0; t < np; t++) {
        outputs_on(pat[t]);
        Frame f;
        if (!fpga_frame(f)) { Serial.println("  lost the FPGA frames"); outputs_off(); return; }
        obs[t] = f.lvl & 0x3F;
        Serial.print("  ");
        print_bits6(pat[t]);
        Serial.print("         ");
        print_bits6(obs[t]);
        Serial.println(obs[t] == pat[t] ? "" : "   <- differs");
    }
    outputs_off();

    auto vec = [&](const uint8_t *a, int bit) { uint16_t v = 0; for (int t = 0; t < np; t++) v |= ((a[t] >> bit) & 1) << t; return v; };
    uint16_t ex[6];
    for (int i = 0; i < 6; i++) ex[i] = vec(pat, i);
    const uint16_t all = (1 << np) - 1;
    for (int j = 0; j < 6; j++) {                    // FPGA input j
        uint16_t o = vec(obs, j);
        Serial.printf("  FPGA %s %-5s (%-8s) expects %-13s: ", FWD[j].fpga, FWD[j].u7, FWD[j].sig, FWD[j].esp);
        r_fwd[j] = R_FAIL;
        int who = -1;
        for (int i = 0; i < 6; i++) if (ex[i] == o) who = i;
        if (who == j) { Serial.println("OK"); r_fwd[j] = R_PASS; continue; }
        if (who >= 0) { Serial.printf("SWAPPED: driven by %s\n", FWD[who].esp); continue; }
        if (o == all) { Serial.println("always 1: wire open (FPGA pull-up) or wrong pin"); continue; }
        if (o == 0)   { Serial.println("always 0: shorted to GND?"); continue; }
        bool named = false;
        for (int a = 0; a < 6 && !named; a++)
            for (int b = a + 1; b < 6 && !named; b++)
                if (o == (ex[a] & ex[b]) || o == (ex[a] | ex[b])) {
                    Serial.printf("follows %s AND/OR %s: those two wires are shorted together\n", FWD[a].esp, FWD[b].esp);
                    named = true;
                }
        if (!named) Serial.println("follows no ESP32 pin: short, or bad contact");
    }
}

//-----------------------------------------------------------------------------
// ESP32 -> FPGA, pulse bursts (edge counters): speed, missing edges, extra edges, crosstalk
//-----------------------------------------------------------------------------
static void burst(int gpio, int n)               // n pulses at 2 MHz
{
    uint32_t m = 1u << (gpio & 31);
    uint32_t s = gpio < 32 ? GPIO_OUT_W1TS_REG : GPIO_OUT1_W1TS_REG;
    uint32_t c = gpio < 32 ? GPIO_OUT_W1TC_REG : GPIO_OUT1_W1TC_REG;
    uint32_t q = getCpuFrequencyMhz() / 4;            // 250 ns
    portDISABLE_INTERRUPTS();
    uint32_t t = esp_cpu_get_cycle_count();
    for (int i = 0; i < n; i++) {
        REG_WRITE(s, m);
        t += q; while ((int32_t)(esp_cpu_get_cycle_count() - t) < 0) {}
        REG_WRITE(c, m);
        t += q; while ((int32_t)(esp_cpu_get_cycle_count() - t) < 0) {}
    }
    portENABLE_INTERRUPTS();
}

// counter differences after - before; expect[k] per input; prints and returns true if all match
static bool check_counts(const Frame &a, const Frame &b, const int *expect, const char *what)
{
    bool ok = true;
    Serial.printf("  %-34s", what);
    for (int k = 0; k < 6; k++) {
        int d = (uint8_t)(b.cnt[k] - a.cnt[k]);
        Serial.printf(" %s:%3d", FWD[k].fpga, d);
        if (d != expect[k]) ok = false;
    }
    Serial.println(ok ? "   OK" : "   <- wrong");
    return ok;
}

static void test_fast()
{
    Serial.println("\n=== ESP32 -> FPGA wires, pulse bursts (FPGA rising-edge counters) ===");
    if (!fwd_safe || !any_back) { Serial.println("  skipped (see above)"); return; }
    const int N = 100;
    for (int k = 0; k < 6; k++) {
        outputs_on(0);
        Frame a, b;
        if (!fpga_frame(a)) { Serial.println("  lost the FPGA frames"); break; }
        burst(FWD[k].gpio, N);
        if (!fpga_frame(b)) { Serial.println("  lost the FPGA frames"); break; }
        int ex[6] = {};
        ex[k] = N;
        char what[48];
        snprintf(what, sizeof what, "100 x 2 MHz on %s:", FWD[k].esp);
        r_fast[k] = check_counts(a, b, ex, what) ? R_PASS : R_FAIL;
    }

    // the real link speed: 8 MHz SPI on SCK (200 rising edges) with 0x55 on MOSI (100)
    outputs_on(0);
    pinMode(FWD[0].gpio, INPUT);
    pinMode(FWD[1].gpio, INPUT);
    fastspi.begin(FWD[0].gpio, -1, FWD[1].gpio, -1);
    Frame a, b;
    bool got = fpga_frame(a);
    fastspi.beginTransaction(SPISettings(8000000, MSBFIRST, SPI_MODE0));
    uint8_t buf[25];
    memset(buf, 0x55, sizeof buf);
    fastspi.transferBytes(buf, nullptr, sizeof buf);
    fastspi.endTransaction();
    got = got && fpga_frame(b);
    fastspi.end();
    outputs_off();
    if (!got) { Serial.println("  lost the FPGA frames"); r_spi = R_FAIL; return; }
    int ex[6] = {200, 100, 0, 0, 0, 0};
    r_spi = check_counts(a, b, ex, "8 MHz SPI, 25 x 0x55 (link speed):") ? R_PASS : R_FAIL;
    Serial.println("  (more edges than sent = ringing/crosstalk, fewer = slow edges or bad contact)");
}

//-----------------------------------------------------------------------------
static void summary()
{
    Serial.println("\n=== Summary ===");
    Serial.printf("  SD card                                   %s\n", res(r_sd));
    for (int k = 0; k < 4; k++)
        Serial.printf("  FPGA %s %-5s -> %-13s %-8s  %s\n", RET[k].fpga, RET[k].u7, RET[k].esp, RET[k].sig, res(r_ret[k]));
    for (int k = 0; k < 6; k++) {
        int r = r_fwd[k] == R_PASS && r_fast[k] == R_PASS ? R_PASS : (r_fwd[k] == R_FAIL || r_fast[k] == R_FAIL) ? R_FAIL : R_NONE;
        Serial.printf("  %-13s -> FPGA %s %-5s %-8s  %s (levels %s, pulses %s)\n", FWD[k].esp, FWD[k].fpga, FWD[k].u7,
                      FWD[k].sig, res(r), res(r_fwd[k]), res(r_fast[k]));
    }
    Serial.printf("  8 MHz SPI on SCK/MOSI                     %s\n", res(r_spi));
    bool all = r_sd == R_PASS && r_spi == R_PASS;
    for (int k = 0; k < 4; k++) all = all && r_ret[k] == R_PASS;
    for (int k = 0; k < 6; k++) all = all && r_fwd[k] == R_PASS && r_fast[k] == R_PASS;
    Serial.println(all ? "  ALL WIRES OK" : "  SOME TESTS FAILED (details above)");
    Serial.println("Enter = run again, help = commands");
}

static void run_all()
{
    r_sd = r_spi = R_NONE;
    for (int k = 0; k < 4; k++) r_ret[k] = R_NONE;
    for (int k = 0; k < 6; k++) r_fwd[k] = r_fast[k] = R_NONE;
    test_sd();
    test_back();
    test_fwd();
    test_fast();
    summary();
}

static void watch()
{
    Serial.println("FPGA inputs once a second (E1 H2 H1 N1 P2 P1, then edge counters); any input stops");
    while (!Serial.available()) {
        Frame f;
        if (fpga_frame(f)) {
            Serial.printf("  via FPGA %s: levels ", f.id >= 0xC1 && f.id <= 0xC4 ? RET[f.id - 0xC1].fpga : "?");
            print_bits6(f.lvl);
            Serial.printf("  counts %3d %3d %3d %3d %3d %3d\n", f.cnt[5], f.cnt[4], f.cnt[3], f.cnt[2], f.cnt[1], f.cnt[0]);
        } else Serial.println("  no frame from the FPGA");
        delay(1000);
    }
    while (Serial.available()) Serial.read();
}

// raw levels of all 10 pins (all inputs), for debugging
static void raw()
{
    outputs_off();
    delay(5);
    capture(20000);
    Serial.printf("raw capture: %d samples in %lu us (one every %d us); first 120 shown\n", nsmp,
                  (unsigned long)(cap_cycles / getCpuFrequencyMhz()), SAMPLE_US);
    for (int k = 0; k < 10; k++) {
        const Wire &w = k < 4 ? RET[k] : FWD[k - 4];
        LineStat s = decode(k);
        Serial.printf("  %-13s %s %-5s ones %5.1f%%  edges %5d  ", w.esp, w.fpga, w.u7, 100.0f * s.ones / nsmp, s.edges);
        for (int i = 0; i < 120; i++) Serial.print((smp[i] >> k) & 1);
        Serial.println();
    }
}

// SD wiring probe: bit-banged CMD0 (go idle, expect R1 = 01) with every assignment of the 4 SD pins
static int sd_try(int cs, int sck, int mosi, int miso)
{
    int pins[4] = {cs, sck, mosi, miso};
    for (int p : pins) pinMode(p, INPUT);
    pinMode(miso, INPUT_PULLUP);
    digitalWrite(cs, HIGH);   pinMode(cs, OUTPUT);
    digitalWrite(sck, LOW);   pinMode(sck, OUTPUT);
    digitalWrite(mosi, HIGH); pinMode(mosi, OUTPUT);
    auto xfer = [&](uint8_t v) {
        uint8_t r = 0;
        for (int b = 7; b >= 0; b--) {
            digitalWrite(mosi, (v >> b) & 1);
            delayMicroseconds(5);
            digitalWrite(sck, HIGH);
            r = (r << 1) | digitalRead(miso);
            delayMicroseconds(5);
            digitalWrite(sck, LOW);
        }
        return r;
    };
    for (int i = 0; i < 10; i++) xfer(0xFF);           // >= 74 clocks with CS high
    digitalWrite(cs, LOW);
    static const uint8_t cmd0[6] = {0x40, 0, 0, 0, 0, 0x95};
    for (uint8_t b : cmd0) xfer(b);
    int resp = -1;
    for (int i = 0; i < 16 && resp < 0; i++) { uint8_t r = xfer(0xFF); if (r != 0xFF) resp = r; }
    digitalWrite(cs, HIGH);
    xfer(0xFF);
    for (int p : pins) pinMode(p, INPUT);
    return resp;
}

static void sd_probe()
{
    SD.end();
    sdspi.end();
    sd_mounted = false;
    const int P[4] = {SD_CS, SD_SCK, SD_MOSI, SD_MISO};
    Serial.println("SD probe: CMD0 at ~100 kHz with every assignment of GPIO5/18/23/19 (expect answer 01)");
    int found = 0;
    int idx[4] = {0, 1, 2, 3};
    do {
        int r = sd_try(P[idx[0]], P[idx[1]], P[idx[2]], P[idx[3]]);
        if (r >= 0) {
            Serial.printf("  CS=GPIO%-2d SCK=GPIO%-2d MOSI=GPIO%-2d MISO=GPIO%-2d -> answer %02X%s\n", P[idx[0]], P[idx[1]],
                          P[idx[2]], P[idx[3]], r, idx[0] == 0 && idx[1] == 1 && idx[2] == 2 ? "  (the expected wiring)" : "");
            found++;
        }
    } while (std::next_permutation(idx, idx + 4));
    if (!found) Serial.println("  no answer with any assignment: card power (3V3/GND), card seated, or a wire not connected");
    Serial.println("  (run sd to mount the card again)");
}

// look for the FPGA's frames on every free ESP32 pin (finds where a wire really landed)
static void find()
{
    static const int cand[16] = {35, 34, 22, 16, 36, 39, 32, 27, 4, 2, 15, 21, 5, 18, 19, 23};
    SD.end();
    sdspi.end();
    sd_mounted = false;
    outputs_off();
    for (int k = 0; k < 16; k++) {
        if (cand[k] < 34 || cand[k] > 39) pinMode(cand[k], INPUT_PULLDOWN);
        else pinMode(cand[k], INPUT);
        m_in[k]  = cand[k] < 32 ? 1u << cand[k] : 0;
        m_in1[k] = cand[k] < 32 ? 0 : 1u << (cand[k] - 32);
    }
    npack = 16;
    delay(5);
    capture(20000);
    Serial.println("FPGA frames on the free ESP32 pins (pull-down on, except GPIO34-39):");
    int hits = 0;
    for (int k = 0; k < 16; k++) {
        LineStat s = decode(k);
        int m = main_id(s);
        Serial.printf("  GPIO%-2d  ones %5.1f%%  edges %5d  ", cand[k], 100.0f * s.ones / nsmp, s.edges);
        if (m >= 0) { Serial.printf("frames from FPGA %s %s (%s)\n", RET[m].fpga, RET[m].u7, RET[m].sig); hits++; }
        else Serial.println("-");
    }
    if (!hits) Serial.println("  none");
    pack_init();
    for (int k = 4; k < 16; k++) pinMode(cand[k], INPUT);
    Serial.println("  (SD released: run sd to mount it again)");
}

static void help()
{
    Serial.println("commands: (Enter)/all | sd | ls <path> | back | fwd | fast | set <hex> | watch | raw | find | sdprobe | help");
}

void setup()
{
    pack_init();
    outputs_off();
    Serial.begin(115200);
    delay(500);
    Serial.println("\nTest_wires: ESP32 <-> FPGA wiring test (load Test_wires.sof into the FPGA first)");
    run_all();
}

void loop()
{
    if (!Serial.available()) return;
    String l = Serial.readStringUntil('\n');
    l.trim();
    int sp = l.indexOf(' ');
    String c = sp < 0 ? l : l.substring(0, sp), a = sp < 0 ? "" : l.substring(sp + 1);
    a.trim();
    if (c == "" || c == "all") run_all();
    else if (c == "sd") test_sd();
    else if (c == "ls") { if (sd_mounted) list_dir(a.length() ? a.c_str() : "/"); else Serial.println("no SD card (run sd)"); }
    else if (c == "back") test_back();
    else if (c == "fwd") { test_back(); test_fwd(); }
    else if (c == "fast") { test_back(); test_fast(); }
    else if (c == "set") {
        test_back();
        if (!fwd_safe) return;
        uint8_t v = strtoul(a.c_str(), 0, 16) & 0x3F;
        outputs_on(v);
        Serial.printf("outputs driven: ");
        print_bits6(v);
        Serial.println(" (GPIO17 25 26 33 13 14); 'back' releases them");
    }
    else if (c == "watch") watch();
    else if (c == "raw") raw();
    else if (c == "find") find();
    else if (c == "sdprobe") sd_probe();
    else if (c == "help") help();
    else Serial.println("unknown command; help");
}
