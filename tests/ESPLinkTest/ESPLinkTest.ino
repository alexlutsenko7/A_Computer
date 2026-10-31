// ESPLinkTest -- first hardware test of the ESP32 system controller for LSpectrum
// (docs/PLAN.md "Next stage"). FPGA: LSpectrum (rtl/esp_link.v).
//
// Board: ESP32 Dev Module (esp32:esp32:esp32, Arduino core 3.3.x). USB serial 115200, line ending "New Line".
//
// Wiring (see docs/PLAN.md):
//   SD card (SPI, VSPI host):  SCK GPIO18, MISO GPIO19, MOSI GPIO23, CS GPIO5, 3V3, GND
//   FPGA link (HSPI host):     SCK GPIO14 -> U7.9 (P1), MOSI GPIO13 -> U7.10 (P2), CS GPIO33 -> U7.11 (N1),
//                              MISO GPIO35 <- U7.7 (R1), IRQ GPIO34 <- U7.8 (R2), GND -> U7.1/2
//
// Commands:
//   help                 this list
//   id                   read the core ID (expect 5A580001)
//   rd <reg>             read a loader register (hex byte offset, e.g. rd 18 = 56 MHz timer)
//   wr <reg> <value>     write a loader register (hex)
//   stat                 link error flag (read clears it)
//   ls [path]            list an SD folder on USB and on the OSD (full screen)
//   osd off              hide the OSD
//   osdtest              visual OSD test on the TV, 4 pages (grid, characters, speed, status bar); Enter = next
//   keys                 show loader keys / raw keyboard reports for 15 s (IRQ driven); any USB input stops
//   memtest [n]          freeze the Spectrum, n rounds of write/read-back over the screen (page 5), restore
//   speed                MRD/MWR throughput over 32 KB of page 7
#include <Arduino.h>
#include <SPI.h>
#include <SD.h>

// pins
static const int SD_SCK = 18, SD_MISO = 19, SD_MOSI = 23, SD_CS = 5;
static const int L_SCK = 14, L_MOSI = 13, L_CS = 33, L_MISO = 35, L_IRQ = 34;

static const uint32_t LINK_HZ = 8000000;        // esp_link: SCK <= 8 MHz
static const uint32_t SD_HZ   = 20000000;

// link commands (rtl/esp_link.v)
enum { CMD_WR = 1, CMD_RD = 2, CMD_OSD = 3, CMD_FIFO = 4, CMD_MWR = 5, CMD_MRD = 6, CMD_STAT = 7 };
// loader registers (LSpectrum/fw/hw.h; 0x00/0x04 = core ID / IRQ in the ESP_LINK build)
enum { R_ID = 0x00, R_IRQ = 0x04, R_KEYS = 0x08, R_FIFO = 0x0C, R_TAPE = 0x10, R_OSDC = 0x14, R_TIMER = 0x18,
       R_KEYRAW = 0x28, R_SNAPCTL = 0x2C };

SPIClass sdspi(VSPI);
SPIClass linkspi(HSPI);
static bool sd_ok = false;

//-----------------------------------------------------------------------------
// link
//-----------------------------------------------------------------------------
static void frame(const uint8_t *tx, uint8_t *rx, size_t n)
{
    linkspi.beginTransaction(SPISettings(LINK_HZ, MSBFIRST, SPI_MODE0));
    digitalWrite(L_CS, LOW);
    delayMicroseconds(1);                       // >= 100 ns CS -> first SCK
    linkspi.transferBytes(tx, rx, n);
    delayMicroseconds(1);
    digitalWrite(L_CS, HIGH);
    linkspi.endTransaction();
    delayMicroseconds(1);
}

static void reg_wr(uint8_t r, uint32_t v)
{
    uint8_t tx[6] = { CMD_WR, r, (uint8_t)(v >> 24), (uint8_t)(v >> 16), (uint8_t)(v >> 8), (uint8_t)v }, rx[6];
    frame(tx, rx, 6);
}

static uint32_t reg_rd(uint8_t r)
{
    uint8_t tx[7] = { CMD_RD, r, 0, 0, 0, 0, 0 }, rx[7];
    frame(tx, rx, 7);
    return (uint32_t)rx[3] << 24 | (uint32_t)rx[4] << 16 | (uint32_t)rx[5] << 8 | rx[6];
}

static uint32_t link_stat()
{
    uint8_t tx[6] = { CMD_STAT, 0, 0, 0, 0, 0 }, rx[6];
    frame(tx, rx, 6);
    return (uint32_t)rx[2] << 24 | (uint32_t)rx[3] << 16 | (uint32_t)rx[4] << 8 | rx[5];
}

static uint8_t buf_tx[4200], buf_rx[4200];

static void osd_write(uint16_t a, const uint8_t *d, size_t n)
{
    buf_tx[0] = CMD_OSD; buf_tx[1] = a >> 8; buf_tx[2] = a;
    memcpy(buf_tx + 3, d, n);
    frame(buf_tx, buf_rx, n + 3);
}

static void mem_write(uint32_t a, const uint8_t *d, size_t n)      // n <= 4096
{
    buf_tx[0] = CMD_MWR; buf_tx[1] = a >> 16; buf_tx[2] = a >> 8; buf_tx[3] = a;
    memcpy(buf_tx + 4, d, n);
    frame(buf_tx, buf_rx, n + 4);
    delayMicroseconds(2);                       // the last byte's write finishes after the frame
}

static void mem_read(uint32_t a, uint8_t *d, size_t n)             // n <= 4096
{
    buf_tx[0] = CMD_MRD; buf_tx[1] = a >> 16; buf_tx[2] = a >> 8; buf_tx[3] = a; buf_tx[4] = 0;
    memset(buf_tx + 5, 0, n);
    frame(buf_tx, buf_rx, n + 5);
    memcpy(d, buf_rx + 5, n);
}

static bool freeze(bool on)
{
    reg_wr(R_SNAPCTL, on ? 1 : 0);
    if (!on) return true;
    uint32_t t0 = millis();
    while (!(reg_rd(R_SNAPCTL) & 1))
        if (millis() - t0 > 200) { reg_wr(R_SNAPCTL, 0); return false; }
    return true;
}

//-----------------------------------------------------------------------------
// OSD: 32 x 24 characters (ASCII, bit 7 = inverse)
//-----------------------------------------------------------------------------
static uint8_t osd[768];

static void osd_clear() { memset(osd, ' ', sizeof osd); }

static void osd_line(int row, const char *s, bool inv = false)
{
    if (row < 0 || row > 23) return;
    for (int i = 0; i < 32; i++) {
        uint8_t c = *s ? (uint8_t)*s++ : ' ';
        if (c < 32 || c > 126) c = '?';
        osd[row * 32 + i] = inv ? (c | 0x80) : c;
    }
}

static void osd_show()
{
    osd_write(0, osd, sizeof osd);
    reg_wr(R_OSDC, 3);                          // on, full screen
}

//-----------------------------------------------------------------------------
// commands
//-----------------------------------------------------------------------------
static void cmd_ls(String path)
{
    if (!sd_ok) { Serial.println("no SD card"); return; }
    if (path.length() == 0) path = "/";
    File dir = SD.open(path);
    if (!dir || !dir.isDirectory()) { Serial.println("not a folder: " + path); return; }
    osd_clear();
    char t[40];
    snprintf(t, sizeof t, " %.30s", path.c_str());
    osd_line(0, t, true);
    int row = 1, count = 0;
    uint32_t t0 = millis();
    for (File f = dir.openNextFile(); f; f = dir.openNextFile()) {
        count++;
        Serial.printf("%s%s  %u\n", f.name(), f.isDirectory() ? "/" : "", (unsigned)f.size());
        if (row < 23) {
            snprintf(t, sizeof t, "%s%.30s%s", f.isDirectory() ? "" : " ", f.name(), f.isDirectory() ? "/" : "");
            osd_line(row++, t);
        }
        f.close();
    }
    snprintf(t, sizeof t, " %d entries, %lu ms", count, (unsigned long)(millis() - t0));
    osd_line(23, t, true);
    uint32_t t1 = micros();
    osd_show();
    Serial.printf("%d entries; OSD drawn in %lu us; link stat %08lx\n", count, (unsigned long)(micros() - t1),
                  (unsigned long)link_stat());
}

// waits for Enter on USB (or ms); false if "q" was typed
static bool osd_wait(uint32_t ms)
{
    Serial.println("  (Enter = next page, q = quit)");
    uint32_t t0 = millis();
    while (millis() - t0 < ms)
        if (Serial.available()) {
            String l = Serial.readStringUntil('\n');
            l.trim();
            return l != "q";
        }
    return true;
}

// visual OSD test on the TV: geometry, character set, speed/stress, status-bar mode
static void cmd_osdtest()
{
    char t[40];
    // 1: grid. Every cell is drawn: row numbers on the left, a column ruler on rows 1 and 22,
    // a checkerboard of inverse blanks and dots, '|' in column 31, corners marked '+'
    osd_clear();
    osd_line(0, " OSD TEST 1/4: GRID 32 x 24", true);
    osd_line(1, "+1234567890123456789012345678901");
    for (int r = 2; r < 22; r++)
        for (int c = 0; c < 32; c++) {
            uint8_t ch;
            if (c < 2) ch = c ? '0' + r % 10 : '0' + r / 10;
            else if (c == 31) ch = '|';
            else ch = (r + c) & 1 ? (' ' | 0x80) : '.';
            osd[r * 32 + c] = ch;
        }
    osd_line(22, "+1234567890123456789012345678901");
    osd_line(23, " row 23 = status bar row       +", true);
    osd[1 * 32 + 31] = '+';
    osd[22 * 32 + 31] = '+';
    osd_show();
    Serial.println("osdtest 1/4 GRID: 24 full rows, 32 columns, nothing cut off at any edge; rows 02-21 numbered;");
    Serial.println("  checkerboard regular (a wrong cell = OSD address/data error); '+' in all 4 corners of rows 1/22");
    if (!osd_wait(15000)) goto done;

    // 2: character set, normal and inverse
    osd_clear();
    osd_line(0, " OSD TEST 2/4: CHARACTERS", true);
    osd_line(1, "normal:");
    for (int i = 0; i < 95; i++) osd[2 * 32 + i] = 32 + i;
    osd_line(6, "inverse:");
    for (int i = 0; i < 95; i++) osd[7 * 32 + i] = (32 + i) | 0x80;
    osd_line(11, "The quick brown fox jumps over");
    osd_line(12, "THE LAZY DOG. 0123456789 +-*/=");
    osd_line(13, "the lazy dog! @#$%&()[]{}<>?:;");
    osd_line(14, " an inverse line of text       ", true);
    osd_line(23, " ASCII 32-126 in rows 2-4 / 7-9", true);
    osd_show();
    Serial.println("osdtest 2/4 CHARACTERS: rows 2-4 = ASCII 32..126 (space ! \" # ... ~), rows 7-9 the same inverse;");
    Serial.println("  every glyph distinct and readable, no missing or doubled pixel columns");
    if (!osd_wait(15000)) goto done;

    // 3: speed / stress: 100 full screens of random text, then a known screen
    {
        osd_clear();
        uint32_t t0 = micros();
        for (int k = 0; k < 100; k++) {
            for (int i = 0; i < 768; i++) osd[i] = 32 + esp_random() % 95 | (esp_random() & 0x80);
            osd_write(0, osd, sizeof osd);
        }
        uint32_t us = micros() - t0;
        uint32_t st = link_stat();
        osd_clear();
        osd_line(0, " OSD TEST 3/4: SPEED", true);
        snprintf(t, sizeof t, "100 screens in %lu ms", (unsigned long)(us / 1000));
        osd_line(10, t);
        snprintf(t, sizeof t, "= %lu us per 768-byte screen", (unsigned long)(us / 100));
        osd_line(11, t);
        snprintf(t, sizeof t, "link stat %08lx", (unsigned long)st);
        osd_line(12, t);
        osd_line(23, " no random characters left over", true);
        osd_show();
        Serial.printf("osdtest 3/4 SPEED: 100 random screens in %lu ms (%lu us each), link stat %08lx;\n",
                      (unsigned long)(us / 1000), (unsigned long)(us / 100), (unsigned long)st);
        Serial.println("  the TV shows only the result text (no leftover random characters)");
        if (!osd_wait(15000)) goto done;
    }

    // 4: status bar only (bottom row over the running Spectrum)
    osd_clear();
    osd_line(23, " OSD 4/4: status bar only      ", true);
    osd_write(0, osd, sizeof osd);
    reg_wr(R_OSDC, 1);                          // on, bottom row only
    Serial.println("osdtest 4/4 STATUS BAR: Spectrum picture visible, only the bottom text row is the OSD bar;");
    Serial.println("  the Spectrum keyboard works again (full-screen OSD blocks it)");
    osd_wait(15000);
done:
    reg_wr(R_OSDC, 0);
    Serial.printf("OSD off; link stat %08lx\n", (unsigned long)link_stat());
}

static void cmd_keys()
{
    reg_wr(R_IRQ, 0x200);                       // IRQ on key change
    reg_rd(R_IRQ);                              // clear an old cause
    Serial.println("press keys on the Spectrum keyboard (15 s, any USB input stops)");
    uint32_t t0 = millis();
    while (millis() - t0 < 15000 && !Serial.available()) {
        if (digitalRead(L_IRQ)) {
            uint32_t c = reg_rd(R_IRQ);         // reading clears the key cause
            Serial.printf("IRQ %03lx  keys %05lx  raw %08lx\n", (unsigned long)c, (unsigned long)reg_rd(R_KEYS),
                          (unsigned long)reg_rd(R_KEYRAW));
        }
    }
    while (Serial.available()) Serial.read();
    reg_wr(R_IRQ, 0);
    Serial.printf("IRQ pin now %d\n", digitalRead(L_IRQ));
}

static uint8_t save_scr[6912], pat[6912], back[6912];

static void cmd_memtest(int rounds)
{
    const uint32_t SCR = 0x14000;               // page 5 = screen 0
    if (!freeze(true)) { Serial.println("Spectrum did not freeze"); return; }
    for (int o = 0; o < 6912; o += 4096) mem_read(SCR + o, save_scr + o, min(4096, 6912 - o));
    uint32_t errs = 0;
    for (int r = 0; r < rounds; r++) {
        uint32_t seed = esp_random();
        for (int i = 0; i < 6912; i++) { seed = seed * 1103515245u + 12345u; pat[i] = seed >> 24; }
        for (int o = 0; o < 6912; o += 4096) mem_write(SCR + o, pat + o, min(4096, 6912 - o));
        for (int o = 0; o < 6912; o += 4096) mem_read(SCR + o, back + o, min(4096, 6912 - o));
        uint32_t e = 0;
        for (int i = 0; i < 6912; i++) if (back[i] != pat[i]) { if (e < 5) Serial.printf("  %04x: %02x != %02x\n", i, back[i], pat[i]); e++; }
        errs += e;
        Serial.printf("round %d: %lu errors\n", r + 1, (unsigned long)e);
    }
    for (int o = 0; o < 6912; o += 4096) mem_write(SCR + o, save_scr + o, min(4096, 6912 - o));
    for (int o = 0; o < 6912; o += 4096) mem_read(SCR + o, back + o, min(4096, 6912 - o));
    bool restored = memcmp(back, save_scr, 6912) == 0;
    freeze(false);
    Serial.printf("memtest: %lu errors in %d rounds, screen restored: %s, link stat %08lx\n", (unsigned long)errs,
                  rounds, restored ? "yes" : "NO", (unsigned long)link_stat());
}

static void cmd_speed()
{
    static uint8_t b[4096];
    const uint32_t P7 = 0x1C000;
    if (!freeze(true)) { Serial.println("Spectrum did not freeze"); return; }
    uint32_t t0 = micros();
    for (int o = 0; o < 16384; o += 4096) mem_read(P7 + o, b, 4096);
    uint32_t t1 = micros();
    for (int o = 0; o < 16384; o += 4096) mem_read(P7 + o, b, 4096), mem_write(P7 + o, b, 4096);  // restore as read
    uint32_t t2 = micros();
    freeze(false);
    Serial.printf("MRD 16 KB: %lu us (%.0f KB/s); MRD+MWR 16 KB: %lu us; link stat %08lx\n", (unsigned long)(t1 - t0),
                  16384.0 / 1.024 / (t1 - t0) * 1000.0, (unsigned long)(t2 - t1), (unsigned long)link_stat());
}

static void help()
{
    Serial.println("commands: id | rd <reg> | wr <reg> <val> | stat | ls [path] | osd off | osdtest | keys | memtest [n] | speed");
}

void setup()
{
    Serial.begin(115200);
    delay(300);
    pinMode(L_CS, OUTPUT);
    digitalWrite(L_CS, HIGH);
    pinMode(L_IRQ, INPUT);
    linkspi.begin(L_SCK, L_MISO, L_MOSI, -1);
    sdspi.begin(SD_SCK, SD_MISO, SD_MOSI, SD_CS);
    sd_ok = SD.begin(SD_CS, sdspi, SD_HZ);
    Serial.printf("\nESPLinkTest. SD: %s", sd_ok ? "ok" : "not found");
    if (sd_ok) Serial.printf(" (%llu MB)", SD.cardSize() >> 20);
    Serial.printf(". FPGA core ID: %08lx (expect 5a580001)\n", (unsigned long)reg_rd(R_ID));
    help();
}

void loop()
{
    if (!Serial.available()) return;
    String l = Serial.readStringUntil('\n');
    l.trim();
    if (l.length() == 0) return;
    int sp = l.indexOf(' ');
    String c = sp < 0 ? l : l.substring(0, sp), a = sp < 0 ? "" : l.substring(sp + 1);
    a.trim();
    if (c == "help") help();
    else if (c == "id") Serial.printf("core ID %08lx\n", (unsigned long)reg_rd(R_ID));
    else if (c == "rd") { uint8_t r = strtoul(a.c_str(), 0, 16); Serial.printf("reg %02x = %08lx\n", r, (unsigned long)reg_rd(r)); }
    else if (c == "wr") {
        int s2 = a.indexOf(' ');
        if (s2 < 0) { Serial.println("wr <reg> <value>"); return; }
        uint8_t r = strtoul(a.substring(0, s2).c_str(), 0, 16);
        uint32_t v = strtoul(a.substring(s2 + 1).c_str(), 0, 16);
        reg_wr(r, v);
        Serial.printf("reg %02x <= %08lx\n", r, (unsigned long)v);
    }
    else if (c == "stat") Serial.printf("link stat %08lx\n", (unsigned long)link_stat());
    else if (c == "ls") cmd_ls(a);
    else if (c == "osdtest") cmd_osdtest();
    else if (c == "osd") { reg_wr(R_OSDC, 0); Serial.println("OSD off"); }
    else if (c == "keys") cmd_keys();
    else if (c == "memtest") cmd_memtest(a.length() ? a.toInt() : 3);
    else if (c == "speed") cmd_speed();
    else Serial.println("unknown command; help");
}
