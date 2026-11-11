/* ESPLinkTest -- first hardware test of the ESP32 system controller for LSpectrum */
/* (docs/PLAN.md "Next stage"). FPGA: LSpectrum (rtl/esp_link.v). */
/* */
/* Board: ESP32 Dev Module (esp32:esp32:esp32, Arduino core 3.3.x). USB serial 115200, line ending "New Line". */
/* */
/* Wiring (see docs/PLAN.md): */
/*   SD card (SPI, VSPI host):  SCK GPIO18, MISO GPIO19, MOSI GPIO23, CS GPIO5, 3V3, GND */
/*   FPGA link (HSPI host):     SCK GPIO14 -> U7.9 (P1), MOSI GPIO13 -> U7.10 (P2), CS GPIO33 -> U7.11 (N1), */
/*                              MISO GPIO35 <- U7.7 (R1), IRQ GPIO34 <- U7.8 (R2), GND -> U7.1/2 */
/* */
/* Commands: */
/*   help                 this list */
/*   id                   read the core ID (expect 5A580001) */
/*   rd <reg>             read a loader register (hex byte offset, e.g. rd 18 = 56 MHz timer) */
/*   wr <reg> <value>     write a loader register (hex) */
/*   stat                 link error flag (read clears it) */
/*   ls [path]            list an SD folder on USB and on the OSD (full screen) */
/*   osd off              hide the OSD */
/*   osdtest              visual OSD test on the TV, 4 pages (grid, characters, speed, status bar); Enter = next */
/*   keys                 show loader keys / raw keyboard reports for 15 s (IRQ driven); any USB input stops */
/*   memtest [n]          freeze the Spectrum, n rounds of write/read-back over the screen (page 5), restore */
/*   speed                MRD/MWR throughput over 32 KB of page 7 */
#include <Arduino.h>
#include <SPI.h>
#include <SD.h>

/* the SD card's pins and speed */
#define SD_SCK 18
#define SD_MISO 19
#define SD_MOSI 23
/* its chip select; 20 MHz */
#define SD_CS 5
#define SD_HZ 20000000u
/* megabytes from bytes */
#define SHIFT_MB 20
/* the link's pins */
#define L_SCK 14
#define L_MOSI 13
#define L_CS 33
/* its inputs; no chip select by the SPI driver */
#define L_MISO 35
#define L_IRQ 34
#define L_NO_PIN (-1)
/* esp_link: SCK <= 8 MHz; >= 100 ns CS -> first SCK */
#define LINK_HZ 8000000u
#define CS_DELAY_US 1
/* the last byte of a memory write finishes after the frame */
#define MWR_SETTLE_US 2
/* the USB serial port, and the pause before the first text */
#define UART_BAUD 115200
#define START_DELAY_MS 300
/* link commands (rtl/esp_link.v) */
#define CMD_WR 1
#define CMD_RD 2
#define CMD_OSD 3
/* pulse commands, memory write and read, the link's status */
#define CMD_FIFO 4
#define CMD_MWR 5
/* memory read; status */
#define CMD_MRD 6
#define CMD_STAT 7
/* loader registers (LSpectrum/fw/hw.h; 0x00/0x04 = core ID / IRQ in the ESP_LINK build) */
#define R_ID 0x00
#define R_IRQ 0x04
#define R_KEYS 0x08
/* pulse FIFO, tape control, OSD control */
#define R_FIFO 0x0C
#define R_TAPE 0x10
#define R_OSDC 0x14
/* the 56 MHz timer, the raw keyboard report, the snapshot control */
#define R_TIMER 0x18
#define R_KEYRAW 0x28
#define R_SNAPCTL 0x2C
/* register values: OSD off / bottom row / full screen; freeze; IRQ on a key change */
#define OSDC_OFF 0
#define OSDC_BAR 1
#define OSDC_FULL 3
/* snapshot control: freeze, frozen */
#define SNAP_FREEZE 1
#define SNAP_FROZEN 1u
#define IRQ_KEY 0x200
/* frames: lengths of the fixed ones, places of their bytes */
#define FRAME_WR_LEN 6
#define FRAME_RD_LEN 7
#define FRAME_STAT_LEN 6
/* command and register */
#define F_CMD 0
#define F_REG 1
/* a written value, high byte first */
#define F_WR_0 2
#define F_WR_1 3
/* its lower bytes */
#define F_WR_2 4
#define F_WR_3 5
/* a read value */
#define F_RD_0 3
#define F_RD_1 4
/* its lower bytes */
#define F_RD_2 5
#define F_RD_3 6
/* the status */
#define F_ST_0 2
#define F_ST_1 3
/* its lower bytes */
#define F_ST_2 4
#define F_ST_3 5
/* OSD frame: address (2 bytes), then the text */
#define F_OSD_HIGH 1
#define F_OSD_LOW 2
#define F_OSD_TEXT 3
/* memory frames: address (3 bytes), a dummy byte when reading, the data */
#define F_MEM_HIGH 1
#define F_MEM_MID 2
#define F_MEM_LOW 3
/* where the data starts */
#define F_MWR_DATA 4
#define F_MRD_DUMMY 4
#define F_MRD_DATA 5
/* shifts of the bytes of a word */
#define SHIFT_BYTE 8
#define SHIFT_WORD 16
#define SHIFT_3_BYTES 24
/* the frame buffers, and the most memory bytes in one frame */
#define BUF_LEN 4200
#define CHUNK 4096
/* OSD: 32 x 24 characters (ASCII, bit 7 = inverse) */
#define OSD_COLS 32
#define OSD_ROWS 24
#define OSD_CELLS 768
/* its last row and column */
#define OSD_LAST_ROW 23
#define OSD_LAST_COL 31
/* the characters it has */
#define CHAR_FIRST 32
#define CHAR_LAST 126
#define CHARS 95
/* inverse */
#define CHAR_INVERSE 0x80
/* a line of text for the OSD */
#define TEXT_BUF 40
/* rows of the ls screen */
#define LS_FIRST_ROW 1
/* the grid page: rows with the ruler, the rows numbered, the columns with the row number */
#define GRID_RULER_TOP 1
#define GRID_RULER_BOTTOM 22
#define GRID_FIRST_ROW 2
/* the number's two columns */
#define GRID_NUMBER_COLS 2
#define GRID_UNITS_COL 1
#define DECIMAL 10
/* a checkerboard */
#define ODD_MASK 1
/* the characters page */
#define CHARS_ROW_NORMAL_TITLE 1
#define CHARS_ROW_NORMAL 2
#define CHARS_ROW_INVERSE_TITLE 6
/* the inverse set, then three lines of text and an inverse one */
#define CHARS_ROW_INVERSE 7
#define CHARS_ROW_TEXT1 11
#define CHARS_ROW_TEXT2 12
/* the last two */
#define CHARS_ROW_TEXT3 13
#define CHARS_ROW_TEXT4 14
/* the speed page: screens written, rows of the result */
#define SPEED_SCREENS 100
#define SPEED_ROW_1 10
#define SPEED_ROW_2 11
/* the link's status */
#define SPEED_ROW_3 12
/* microseconds per millisecond */
#define US_PER_MS 1000
/* times: waiting for a frozen CPU, for Enter on a page, for keys */
#define FREEZE_MS 200
#define PAGE_WAIT_MS 15000
#define KEYS_MS 15000
/* the memory test: the screen of page 5, rounds by default, errors listed */
#define SCREEN_ADDR 0x14000u
#define SCREEN_LEN 6912
#define MEMTEST_ROUNDS 3
/* errors listed per round */
#define ERRORS_SHOWN 5
/* its pattern generator (the C library's classic one) */
#define RND_MUL 1103515245u
#define RND_ADD 12345u
#define RND_SHIFT 24
/* the speed test: 16 KB of page 7 */
#define PAGE7_ADDR 0x1C000u
#define SPEED_LEN 16384
/* KB/s from bytes and microseconds */
#define BYTES_PER_KB_MILLI 1.024
#define MS_SCALE 1000.0
/* register numbers and values are typed in hexadecimal */
#define HEX 16
/* one */
#define ONE 1

/* the frame buffers */
static uint8_t g_aui8_buf_tx[BUF_LEN];
static uint8_t g_aui8_buf_rx[BUF_LEN];
/* the OSD's text */
static uint8_t g_aui8_osd[OSD_CELLS];
/* the memory test: the screen as it was, the pattern, what was read back */
static uint8_t g_aui8_save_scr[SCREEN_LEN];
static uint8_t g_aui8_pat[SCREEN_LEN];
static uint8_t g_aui8_back[SCREEN_LEN];
/* the speed test's buffer */
static uint8_t g_aui8_speed[CHUNK];
/* the two SPI buses */
SPIClass g_s_sdspi(VSPI);
SPIClass g_s_linkspi(HSPI);
/* a card was found */
static bool g_b_sd_ok = false;

/* link */

/* one frame: bytes out and in at once */
static void frame(const uint8_t *pui8_tx, uint8_t *pui8_rx, size_t sz_len)
{
    g_s_linkspi.beginTransaction(SPISettings(LINK_HZ, MSBFIRST, SPI_MODE0));
    digitalWrite(L_CS, LOW);
/* >= 100 ns CS -> first SCK */
    delayMicroseconds(CS_DELAY_US);
    g_s_linkspi.transferBytes(pui8_tx, pui8_rx, sz_len);
    delayMicroseconds(CS_DELAY_US);
/* chip select off */
    digitalWrite(L_CS, HIGH);
    g_s_linkspi.endTransaction();
    delayMicroseconds(CS_DELAY_US);
}

/* write a loader register */
static void reg_wr(uint8_t ui8_reg, uint32_t ui32_value)
{
/* local variables */
    uint8_t aui8_tx[FRAME_WR_LEN];
    uint8_t aui8_rx[FRAME_WR_LEN];

/* start values */
    aui8_tx[F_CMD] = CMD_WR;
    aui8_tx[F_REG] = ui8_reg;
/* the value, high byte first */
    aui8_tx[F_WR_0] = (uint8_t)(ui32_value >> SHIFT_3_BYTES);
    aui8_tx[F_WR_1] = (uint8_t)(ui32_value >> SHIFT_WORD);
    aui8_tx[F_WR_2] = (uint8_t)(ui32_value >> SHIFT_BYTE);
/* its low byte, then the frame */
    aui8_tx[F_WR_3] = (uint8_t)ui32_value;
    frame(aui8_tx, aui8_rx, FRAME_WR_LEN);
}

/* read a loader register */
static uint32_t reg_rd(uint8_t ui8_reg)
{
/* local variables */
    uint8_t aui8_tx[FRAME_RD_LEN];
    uint8_t aui8_rx[FRAME_RD_LEN];
    uint32_t ui32_value;

/* zeros clock the answer out */
    memset(aui8_tx, 0, sizeof aui8_tx);
    aui8_tx[F_CMD] = CMD_RD;
    aui8_tx[F_REG] = ui8_reg;
/* the frame */
    frame(aui8_tx, aui8_rx, FRAME_RD_LEN);
/* the value, high byte first */
    ui32_value = ((uint32_t)aui8_rx[F_RD_0] << SHIFT_3_BYTES) | ((uint32_t)aui8_rx[F_RD_1] << SHIFT_WORD) |
                 ((uint32_t)aui8_rx[F_RD_2] << SHIFT_BYTE) | aui8_rx[F_RD_3];
    return ui32_value;
}

/* the link's error flags (reading clears them) */
static uint32_t link_stat(void)
{
/* local variables */
    uint8_t aui8_tx[FRAME_STAT_LEN];
    uint8_t aui8_rx[FRAME_STAT_LEN];
    uint32_t ui32_value;

/* zeros clock the flags out */
    memset(aui8_tx, 0, sizeof aui8_tx);
    aui8_tx[F_CMD] = CMD_STAT;
    frame(aui8_tx, aui8_rx, FRAME_STAT_LEN);
/* the flags, high byte first */
    ui32_value = ((uint32_t)aui8_rx[F_ST_0] << SHIFT_3_BYTES) | ((uint32_t)aui8_rx[F_ST_1] << SHIFT_WORD) |
                 ((uint32_t)aui8_rx[F_ST_2] << SHIFT_BYTE) | aui8_rx[F_ST_3];
    return ui32_value;
}

/* text into the OSD from a cell address on */
static void osd_write(uint16_t ui16_addr, const uint8_t *pui8_data, size_t sz_len)
{
    g_aui8_buf_tx[F_CMD] = CMD_OSD;
/* the cell's address */
    g_aui8_buf_tx[F_OSD_HIGH] = (uint8_t)(ui16_addr >> SHIFT_BYTE);
    g_aui8_buf_tx[F_OSD_LOW] = (uint8_t)ui16_addr;
/* the text */
    memcpy(g_aui8_buf_tx + F_OSD_TEXT, pui8_data, sz_len);
    frame(g_aui8_buf_tx, g_aui8_buf_rx, sz_len + F_OSD_TEXT);
}

/* bytes into the Spectrum's memory; sz_len <= CHUNK */
static void mem_write(uint32_t ui32_addr, const uint8_t *pui8_data, size_t sz_len)
{
    g_aui8_buf_tx[F_CMD] = CMD_MWR;
/* the address, high byte first */
    g_aui8_buf_tx[F_MEM_HIGH] = (uint8_t)(ui32_addr >> SHIFT_WORD);
    g_aui8_buf_tx[F_MEM_MID] = (uint8_t)(ui32_addr >> SHIFT_BYTE);
/* the address's low byte, then the data */
    g_aui8_buf_tx[F_MEM_LOW] = (uint8_t)ui32_addr;
    memcpy(g_aui8_buf_tx + F_MWR_DATA, pui8_data, sz_len);
    frame(g_aui8_buf_tx, g_aui8_buf_rx, sz_len + F_MWR_DATA);
/* the last byte's write finishes after the frame */
    delayMicroseconds(MWR_SETTLE_US);
}

/* bytes from the Spectrum's memory; sz_len <= CHUNK */
static void mem_read(uint32_t ui32_addr, uint8_t *pui8_data, size_t sz_len)
{
    g_aui8_buf_tx[F_CMD] = CMD_MRD;
/* the address, high byte first */
    g_aui8_buf_tx[F_MEM_HIGH] = (uint8_t)(ui32_addr >> SHIFT_WORD);
    g_aui8_buf_tx[F_MEM_MID] = (uint8_t)(ui32_addr >> SHIFT_BYTE);
/* the address's low byte, a dummy byte, zeros that clock the data out */
    g_aui8_buf_tx[F_MEM_LOW] = (uint8_t)ui32_addr;
    g_aui8_buf_tx[F_MRD_DUMMY] = 0;
    memset(g_aui8_buf_tx + F_MRD_DATA, 0, sz_len);
/* the frame, and the data from it */
    frame(g_aui8_buf_tx, g_aui8_buf_rx, sz_len + F_MRD_DATA);
    memcpy(pui8_data, g_aui8_buf_rx + F_MRD_DATA, sz_len);
}

/* stop the Spectrum's CPU (true = it stopped), or let it run again */
static bool freeze(bool b_on)
{
/* local variables */
    uint32_t ui32_start;
    bool b_ok;

/* start values */
    ui32_start = millis();
    b_ok = true;
/* let it run */
    if (!b_on)
    {
        reg_wr(R_SNAPCTL, 0);
    }
    else
    {
/* ask for the stop, and wait for it */
        reg_wr(R_SNAPCTL, SNAP_FREEZE);
        while (b_ok && ((reg_rd(R_SNAPCTL) & SNAP_FROZEN) == 0))
        {
            if ((millis() - ui32_start) > FREEZE_MS)
            {
/* a CPU that is not running never gets there */
                reg_wr(R_SNAPCTL, 0);
                b_ok = false;
            }
        }
    }
    return b_ok;
}

/* OSD: 32 x 24 characters (ASCII, bit 7 = inverse) */

/* an empty screen */
static void osd_clear(void)
{
    memset(g_aui8_osd, ' ', sizeof g_aui8_osd);
}

/* one row of text, padded with spaces; other characters than ASCII become '?' */
static void osd_line(int32_t i32_row, const char *pc_text, bool b_inverse)
{
/* local variables */
    int32_t i32_col;
    uint8_t ui8_char;

/* start values */
    i32_col = 0;
    ui8_char = 0;
/* only rows the screen has */
    if ((i32_row >= 0) && (i32_row <= OSD_LAST_ROW))
    {
        for (i32_col = 0; i32_col < OSD_COLS; i32_col++)
        {
/* the text's next character, or a space behind its end */
            ui8_char = ' ';
            if (*pc_text != 0)
            {
/* from the text */
                ui8_char = (uint8_t)*pc_text;
                pc_text++;
            }
/* only what the font has */
            if ((ui8_char < CHAR_FIRST) || (ui8_char > CHAR_LAST))
            {
                ui8_char = '?';
            }
/* inverse */
            if (b_inverse)
            {
                ui8_char |= CHAR_INVERSE;
            }
/* into the screen */
            g_aui8_osd[(i32_row * OSD_COLS) + i32_col] = ui8_char;
        }
    }
}

/* the screen to the FPGA, shown full screen */
static void osd_show(void)
{
    osd_write(0, g_aui8_osd, sizeof g_aui8_osd);
    reg_wr(R_OSDC, OSDC_FULL);
}

/* commands */

/* "ls": a folder of the card on USB and on the OSD */
static void cmd_ls(String s_path)
{
/* local variables */
    char ac_text[TEXT_BUF];
    File s_dir;
    File s_file;
/* the names of an entry's parts */
    const char *pc_lead;
    const char *pc_slash;
/* the OSD row, entries counted */
    int32_t i32_row;
    int32_t i32_count;
/* times */
    uint32_t ui32_start;
    uint32_t ui32_draw;
    bool b_ok;

/* start values */
    pc_lead = "";
    pc_slash = "";
    i32_row = LS_FIRST_ROW;
/* nothing listed yet */
    i32_count = 0;
    ui32_start = 0;
    ui32_draw = 0;
/* a card is needed */
    b_ok = g_b_sd_ok;
    if (!b_ok)
    {
        Serial.println("no SD card");
    }
    else
    {
/* no path: the root */
        if (s_path.length() == 0)
        {
            s_path = "/";
        }
        s_dir = SD.open(s_path);
/* it must be a folder */
        if (!s_dir || !s_dir.isDirectory())
        {
            Serial.println("not a folder: " + s_path);
            b_ok = false;
        }
    }
/* the folder is open */
    if (b_ok)
    {
/* the title: the path */
        osd_clear();
        snprintf(ac_text, sizeof ac_text, " %.30s", s_path.c_str());
        osd_line(0, ac_text, true);
/* entry by entry */
        ui32_start = millis();
        s_file = s_dir.openNextFile();
        while (s_file)
        {
/* counted */
            i32_count++;
/* a folder has a slash behind its name, a file a space before it */
            pc_lead = " ";
            pc_slash = "";
            if (s_file.isDirectory())
            {
/* a folder */
                pc_lead = "";
                pc_slash = "/";
            }
/* on USB with its size */
            Serial.printf("%s%s  %u\n", s_file.name(), pc_slash, (unsigned)s_file.size());
            if (i32_row < OSD_LAST_ROW)
            {
/* on the OSD while it has rows */
                snprintf(ac_text, sizeof ac_text, "%s%.30s%s", pc_lead, s_file.name(), pc_slash);
                osd_line(i32_row, ac_text, false);
                i32_row++;
            }
/* the next entry */
            s_file.close();
            s_file = s_dir.openNextFile();
        }
/* the last row: how many, how long it took */
        snprintf(ac_text, sizeof ac_text, " %d entries, %lu ms", (int)i32_count, (unsigned long)(millis() - ui32_start));
        osd_line(OSD_LAST_ROW, ac_text, true);
        ui32_draw = micros();
/* shown, and reported */
        osd_show();
        Serial.printf("%d entries; OSD drawn in %lu us; link stat %08lx\n", (int)i32_count,
                      (unsigned long)(micros() - ui32_draw), (unsigned long)link_stat());
    }
}

/* waits for Enter on USB (or ui32_ms); false if "q" was typed */
static bool osd_wait(uint32_t ui32_ms)
{
/* local variables */
    String s_line;
    uint32_t ui32_start;
/* go on with the test; a line came */
    bool b_go;
    bool b_done;

/* start values */
    ui32_start = millis();
    b_go = true;
    b_done = false;
/* the keys */
    Serial.println("  (Enter = next page, q = quit)");
/* until a line comes or the time is over */
    while (!b_done && ((millis() - ui32_start) < ui32_ms))
    {
        if (Serial.available())
        {
/* the line */
            s_line = Serial.readStringUntil('\n');
            s_line.trim();
/* q ends the test */
            b_go = s_line != "q";
            b_done = true;
        }
    }
    return b_go;
}

/* osdtest 1: grid. Every cell is drawn: row numbers on the left, a column ruler on rows 1 and 22, */
/* a checkerboard of inverse blanks and dots, '|' in column 31, corners marked '+' */
static void osd_page_grid(void)
{
/* local variables */
    int32_t i32_row;
    int32_t i32_col;
    uint8_t ui8_char;

/* start values */
    i32_row = 0;
    i32_col = 0;
    ui8_char = 0;
/* the title and the upper ruler */
    osd_clear();
    osd_line(0, " OSD TEST 1/4: GRID 32 x 24", true);
    osd_line(GRID_RULER_TOP, "+1234567890123456789012345678901", false);
/* every cell of the numbered rows */
    for (i32_row = GRID_FIRST_ROW; i32_row < GRID_RULER_BOTTOM; i32_row++)
    {
        for (i32_col = 0; i32_col < OSD_COLS; i32_col++)
        {
/* the row's number in the first two columns */
            if (i32_col == 0)
            {
                ui8_char = (uint8_t)('0' + (i32_row / DECIMAL));
            }
/* its units */
            else if (i32_col == GRID_UNITS_COL)
            {
                ui8_char = (uint8_t)('0' + (i32_row % DECIMAL));
            }
            else if (i32_col == OSD_LAST_COL)
            {
/* the right edge */
                ui8_char = '|';
            }
            else if (((i32_row + i32_col) & ODD_MASK) != 0)
            {
/* the checkerboard: an inverse blank, or a dot */
                ui8_char = ' ' | CHAR_INVERSE;
            }
            else
            {
                ui8_char = '.';
            }
            g_aui8_osd[(i32_row * OSD_COLS) + i32_col] = ui8_char;
        }
    }
/* the lower ruler, the status bar's row, the two right corners */
    osd_line(GRID_RULER_BOTTOM, "+1234567890123456789012345678901", false);
    osd_line(OSD_LAST_ROW, " row 23 = status bar row       +", true);
/* the two right corners */
    g_aui8_osd[(GRID_RULER_TOP * OSD_COLS) + OSD_LAST_COL] = '+';
    g_aui8_osd[(GRID_RULER_BOTTOM * OSD_COLS) + OSD_LAST_COL] = '+';
/* shown; what to look for */
    osd_show();
    Serial.println("osdtest 1/4 GRID: 24 full rows, 32 columns, nothing cut off at any edge; rows 02-21 numbered;");
    Serial.println("  checkerboard regular (a wrong cell = OSD address/data error); '+' in all 4 corners of rows 1/22");
}

/* osdtest 2: character set, normal and inverse */
static void osd_page_chars(void)
{
/* local variables */
    int32_t i32_index;

/* the title, the normal set */
    osd_clear();
    osd_line(0, " OSD TEST 2/4: CHARACTERS", true);
    osd_line(CHARS_ROW_NORMAL_TITLE, "normal:", false);
/* ASCII 32 to 126 */
    for (i32_index = 0; i32_index < CHARS; i32_index++)
    {
        g_aui8_osd[(CHARS_ROW_NORMAL * OSD_COLS) + i32_index] = (uint8_t)(CHAR_FIRST + i32_index);
    }
/* the inverse set */
    osd_line(CHARS_ROW_INVERSE_TITLE, "inverse:", false);
    for (i32_index = 0; i32_index < CHARS; i32_index++)
    {
        g_aui8_osd[(CHARS_ROW_INVERSE * OSD_COLS) + i32_index] = (uint8_t)((CHAR_FIRST + i32_index) | CHAR_INVERSE);
    }
/* text to read */
    osd_line(CHARS_ROW_TEXT1, "The quick brown fox jumps over", false);
    osd_line(CHARS_ROW_TEXT2, "THE LAZY DOG. 0123456789 +-*/=", false);
    osd_line(CHARS_ROW_TEXT3, "the lazy dog! @#$%&()[]{}<>?:;", false);
/* inverse text, the last row */
    osd_line(CHARS_ROW_TEXT4, " an inverse line of text       ", true);
    osd_line(OSD_LAST_ROW, " ASCII 32-126 in rows 2-4 / 7-9", true);
    osd_show();
/* what to look for */
    Serial.println("osdtest 2/4 CHARACTERS: rows 2-4 = ASCII 32..126 (space ! \" # ... ~), rows 7-9 the same inverse;");
    Serial.println("  every glyph distinct and readable, no missing or doubled pixel columns");
}

/* osdtest 3: speed / stress: 100 full screens of random text, then a known screen */
static void osd_page_speed(void)
{
/* local variables */
    char ac_text[TEXT_BUF];
    uint32_t ui32_start;
    uint32_t ui32_us;
/* the link's status, a random character, counters */
    uint32_t ui32_stat;
    uint32_t ui32_char;
/* counters */
    int32_t i32_screen;
    int32_t i32_index;

/* start values */
    ui32_stat = 0;
    ui32_char = 0;
/* counters */
    i32_screen = 0;
    i32_index = 0;
/* 100 screens of random characters, timed */
    osd_clear();
    ui32_start = micros();
    for (i32_screen = 0; i32_screen < SPEED_SCREENS; i32_screen++)
    {
/* every cell */
        for (i32_index = 0; i32_index < OSD_CELLS; i32_index++)
        {
/* a random character, randomly inverse */
            ui32_char = CHAR_FIRST + (esp_random() % CHARS);
            ui32_char |= esp_random() & CHAR_INVERSE;
            g_aui8_osd[i32_index] = (uint8_t)ui32_char;
        }
/* the screen to the FPGA */
        osd_write(0, g_aui8_osd, sizeof g_aui8_osd);
    }
/* how long it took, and whether the link saw an error */
    ui32_us = micros() - ui32_start;
    ui32_stat = link_stat();
    osd_clear();
/* the result on the screen */
    osd_line(0, " OSD TEST 3/4: SPEED", true);
    snprintf(ac_text, sizeof ac_text, "100 screens in %lu ms", (unsigned long)(ui32_us / US_PER_MS));
    osd_line(SPEED_ROW_1, ac_text, false);
/* per screen */
    snprintf(ac_text, sizeof ac_text, "= %lu us per 768-byte screen", (unsigned long)(ui32_us / SPEED_SCREENS));
    osd_line(SPEED_ROW_2, ac_text, false);
    snprintf(ac_text, sizeof ac_text, "link stat %08lx", (unsigned long)ui32_stat);
/* the status, the last row */
    osd_line(SPEED_ROW_3, ac_text, false);
    osd_line(OSD_LAST_ROW, " no random characters left over", true);
    osd_show();
/* the same on USB, and what to look for */
    Serial.printf("osdtest 3/4 SPEED: 100 random screens in %lu ms (%lu us each), link stat %08lx;\n",
                  (unsigned long)(ui32_us / US_PER_MS), (unsigned long)(ui32_us / SPEED_SCREENS), (unsigned long)ui32_stat);
    Serial.println("  the TV shows only the result text (no leftover random characters)");
}

/* osdtest 4: status bar only (bottom row over the running Spectrum) */
static void osd_page_bar(void)
{
    osd_clear();
    osd_line(OSD_LAST_ROW, " OSD 4/4: status bar only      ", true);
/* the screen to the FPGA */
    osd_write(0, g_aui8_osd, sizeof g_aui8_osd);
/* on, bottom row only */
    reg_wr(R_OSDC, OSDC_BAR);
    Serial.println("osdtest 4/4 STATUS BAR: Spectrum picture visible, only the bottom text row is the OSD bar;");
    Serial.println("  the Spectrum keyboard works again (full-screen OSD blocks it)");
}

/* "osdtest": visual OSD test on the TV: geometry, character set, speed/stress, status-bar mode */
static void cmd_osdtest(void)
{
/* local variables */
    bool b_go;

/* page by page, until q is typed */
    osd_page_grid();
    b_go = osd_wait(PAGE_WAIT_MS);
/* the characters */
    if (b_go)
    {
        osd_page_chars();
        b_go = osd_wait(PAGE_WAIT_MS);
    }
/* the speed page */
    if (b_go)
    {
        osd_page_speed();
        b_go = osd_wait(PAGE_WAIT_MS);
    }
/* the status bar */
    if (b_go)
    {
        osd_page_bar();
        osd_wait(PAGE_WAIT_MS);
    }
/* the OSD off again */
    reg_wr(R_OSDC, OSDC_OFF);
    Serial.printf("OSD off; link stat %08lx\n", (unsigned long)link_stat());
}

/* "keys": the loader's keys and the raw keyboard report at every key change, for 15 s */
static void cmd_keys(void)
{
/* local variables */
    uint32_t ui32_start;
    uint32_t ui32_cause;

/* start values */
    ui32_start = millis();
    ui32_cause = 0;
/* IRQ on key change; an old cause is cleared */
    reg_wr(R_IRQ, IRQ_KEY);
    reg_rd(R_IRQ);
    Serial.println("press keys on the Spectrum keyboard (15 s, any USB input stops)");
/* for 15 s, or until something is typed */
    while (((millis() - ui32_start) < KEYS_MS) && !Serial.available())
    {
        if (digitalRead(L_IRQ))
        {
/* reading clears the key cause */
            ui32_cause = reg_rd(R_IRQ);
            Serial.printf("IRQ %03lx  keys %05lx  raw %08lx\n", (unsigned long)ui32_cause, (unsigned long)reg_rd(R_KEYS),
                          (unsigned long)reg_rd(R_KEYRAW));
        }
    }
/* what was typed on USB is thrown away */
    while (Serial.available())
    {
        Serial.read();
    }
/* no IRQ any more */
    reg_wr(R_IRQ, 0);
    Serial.printf("IRQ pin now %d\n", digitalRead(L_IRQ));
}

/* the Spectrum's screen memory into a buffer, in pieces of one frame */
static void screen_read(uint8_t *pui8_dst)
{
/* local variables */
    int32_t i32_off;
    int32_t i32_len;

/* piece by piece */
    for (i32_off = 0; i32_off < SCREEN_LEN; i32_off += CHUNK)
    {
        i32_len = SCREEN_LEN - i32_off;
/* at most one frame's data */
        if (i32_len > CHUNK)
        {
            i32_len = CHUNK;
        }
        mem_read(SCREEN_ADDR + (uint32_t)i32_off, pui8_dst + i32_off, (size_t)i32_len);
    }
}

/* a buffer into the Spectrum's screen memory, in pieces of one frame */
static void screen_write(const uint8_t *pui8_src)
{
/* local variables */
    int32_t i32_off;
    int32_t i32_len;

/* piece by piece */
    for (i32_off = 0; i32_off < SCREEN_LEN; i32_off += CHUNK)
    {
        i32_len = SCREEN_LEN - i32_off;
/* at most one frame's data */
        if (i32_len > CHUNK)
        {
            i32_len = CHUNK;
        }
        mem_write(SCREEN_ADDR + (uint32_t)i32_off, pui8_src + i32_off, (size_t)i32_len);
    }
}

/* "memtest": rounds of random patterns written to the frozen Spectrum's screen and read back */
static void cmd_memtest(int32_t i32_rounds)
{
/* local variables */
    uint32_t ui32_errors;
    uint32_t ui32_round_errors;
    uint32_t ui32_seed;
/* counters, the screen is back */
    int32_t i32_round;
    int32_t i32_index;
/* the screen is back, as a flag and as text */
    bool b_restored;
    const char *pc_restored;

/* start values */
    ui32_errors = 0;
    ui32_round_errors = 0;
    ui32_seed = 0;
/* nothing done yet */
    i32_round = 0;
    i32_index = 0;
/* not restored until checked */
    b_restored = false;
    pc_restored = "NO";
/* the Spectrum must stop */
    if (!freeze(true))
    {
        Serial.println("Spectrum did not freeze");
    }
    else
    {
/* the screen as it is */
        screen_read(g_aui8_save_scr);
        for (i32_round = 0; i32_round < i32_rounds; i32_round++)
        {
            ui32_seed = esp_random();
/* a pattern from a random seed */
            for (i32_index = 0; i32_index < SCREEN_LEN; i32_index++)
            {
                ui32_seed = (ui32_seed * RND_MUL) + RND_ADD;
                g_aui8_pat[i32_index] = (uint8_t)(ui32_seed >> RND_SHIFT);
            }
/* written, read back, compared */
            screen_write(g_aui8_pat);
            screen_read(g_aui8_back);
/* byte by byte */
            ui32_round_errors = 0;
            for (i32_index = 0; i32_index < SCREEN_LEN; i32_index++)
            {
                if (g_aui8_back[i32_index] != g_aui8_pat[i32_index])
                {
/* the first few differences are listed */
                    if (ui32_round_errors < ERRORS_SHOWN)
                    {
                        Serial.printf("  %04x: %02x != %02x\n", (int)i32_index, g_aui8_back[i32_index], g_aui8_pat[i32_index]);
                    }
                    ui32_round_errors++;
                }
            }
/* the round's result */
            ui32_errors += ui32_round_errors;
            Serial.printf("round %d: %lu errors\n", (int)(i32_round + ONE), (unsigned long)ui32_round_errors);
        }
/* the old screen back, and checked */
        screen_write(g_aui8_save_scr);
        screen_read(g_aui8_back);
        b_restored = memcmp(g_aui8_back, g_aui8_save_scr, SCREEN_LEN) == 0;
/* the Spectrum runs again */
        freeze(false);
        if (b_restored)
        {
            pc_restored = "yes";
        }
/* the result */
        Serial.printf("memtest: %lu errors in %d rounds, screen restored: %s, link stat %08lx\n", (unsigned long)ui32_errors,
                      (int)i32_rounds, pc_restored, (unsigned long)link_stat());
    }
}

/* "speed": how fast memory is read, and read + written, over the link */
static void cmd_speed(void)
{
/* local variables */
    uint32_t ui32_start;
    uint32_t ui32_read;
/* after the second pass; an offset */
    uint32_t ui32_both;
    int32_t i32_off;

/* start values */
    ui32_start = 0;
    ui32_read = 0;
    ui32_both = 0;
/* the Spectrum must stop */
    i32_off = 0;
    if (!freeze(true))
    {
        Serial.println("Spectrum did not freeze");
    }
    else
    {
/* 16 KB read */
        ui32_start = micros();
        for (i32_off = 0; i32_off < SPEED_LEN; i32_off += CHUNK)
        {
            mem_read(PAGE7_ADDR + (uint32_t)i32_off, g_aui8_speed, CHUNK);
        }
/* read */
        ui32_read = micros();
/* 16 KB read and written back as read */
        for (i32_off = 0; i32_off < SPEED_LEN; i32_off += CHUNK)
        {
            mem_read(PAGE7_ADDR + (uint32_t)i32_off, g_aui8_speed, CHUNK);
            mem_write(PAGE7_ADDR + (uint32_t)i32_off, g_aui8_speed, CHUNK);
        }
/* both */
        ui32_both = micros();
/* the Spectrum runs again; the times */
        freeze(false);
        Serial.printf("MRD 16 KB: %lu us (%.0f KB/s); MRD+MWR 16 KB: %lu us; link stat %08lx\n",
                      (unsigned long)(ui32_read - ui32_start),
                      ((SPEED_LEN / BYTES_PER_KB_MILLI) / (ui32_read - ui32_start)) * MS_SCALE,
                      (unsigned long)(ui32_both - ui32_read), (unsigned long)link_stat());
    }
}

/* the commands */
static void help(void)
{
    Serial.println("commands: id | rd <reg> | wr <reg> <val> | stat | ls [path] | osd off | osdtest | keys | memtest [n] | speed");
}

/* "wr": a register number and a value, both hexadecimal */
static void cmd_wr(String s_arg)
{
/* local variables */
    int32_t i32_space;
    uint8_t ui8_reg;
    uint32_t ui32_value;

/* start values */
    i32_space = s_arg.indexOf(' ');
    ui8_reg = 0;
    ui32_value = 0;
/* a space separates them */
    if (i32_space < 0)
    {
        Serial.println("wr <reg> <value>");
    }
    else
    {
/* the two numbers */
        ui8_reg = (uint8_t)strtoul(s_arg.substring(0, i32_space).c_str(), 0, HEX);
        ui32_value = strtoul(s_arg.substring(i32_space + ONE).c_str(), 0, HEX);
/* written, and said */
        reg_wr(ui8_reg, ui32_value);
        Serial.printf("reg %02x <= %08lx\n", ui8_reg, (unsigned long)ui32_value);
    }
}

/* one command line: the command, and the rest of the line as its argument */
static void command(String s_cmd, String s_arg)
{
/* local variables */
    uint8_t ui8_reg;
    int32_t i32_rounds;

/* start values */
    ui8_reg = 0;
    i32_rounds = MEMTEST_ROUNDS;
/* the commands */
    if (s_cmd == "help")
    {
        help();
    }
/* the core's ID */
    else if (s_cmd == "id")
    {
        Serial.printf("core ID %08lx\n", (unsigned long)reg_rd(R_ID));
    }
    else if (s_cmd == "rd")
    {
/* a register, its number in hexadecimal */
        ui8_reg = (uint8_t)strtoul(s_arg.c_str(), 0, HEX);
        Serial.printf("reg %02x = %08lx\n", ui8_reg, (unsigned long)reg_rd(ui8_reg));
    }
/* write a register */
    else if (s_cmd == "wr")
    {
        cmd_wr(s_arg);
    }
    else if (s_cmd == "stat")
    {
/* the link's error flags */
        Serial.printf("link stat %08lx\n", (unsigned long)link_stat());
    }
/* a folder of the card */
    else if (s_cmd == "ls")
    {
        cmd_ls(s_arg);
    }
    else if (s_cmd == "osdtest")
    {
/* the four test pages */
        cmd_osdtest();
    }
    else if (s_cmd == "osd")
    {
        reg_wr(R_OSDC, OSDC_OFF);
/* said */
        Serial.println("OSD off");
    }
    else if (s_cmd == "keys")
    {
/* key changes */
        cmd_keys();
    }
    else if (s_cmd == "memtest")
    {
/* the number of rounds is optional */
        if (s_arg.length() != 0)
        {
            i32_rounds = s_arg.toInt();
        }
/* the test */
        cmd_memtest(i32_rounds);
    }
    else if (s_cmd == "speed")
    {
/* throughput */
        cmd_speed();
    }
    else
    {
        Serial.println("unknown command; help");
    }
}

void setup()
{
/* local variables */
    const char *pc_sd;

/* the USB serial port, the link's pins */
    Serial.begin(UART_BAUD);
    delay(START_DELAY_MS);
    pinMode(L_CS, OUTPUT);
/* chip select off, the IRQ pin an input */
    digitalWrite(L_CS, HIGH);
    pinMode(L_IRQ, INPUT);
    g_s_linkspi.begin(L_SCK, L_MISO, L_MOSI, L_NO_PIN);
/* the card */
    g_s_sdspi.begin(SD_SCK, SD_MISO, SD_MOSI, SD_CS);
    g_b_sd_ok = SD.begin(SD_CS, g_s_sdspi, SD_HZ);
/* found or not, as text */
    pc_sd = "not found";
    if (g_b_sd_ok)
    {
        pc_sd = "ok";
    }
/* what was found */
    Serial.printf("\nESPLinkTest. SD: %s", pc_sd);
    if (g_b_sd_ok)
    {
        Serial.printf(" (%llu MB)", SD.cardSize() >> SHIFT_MB);
    }
/* the FPGA's core ID, then the commands */
    Serial.printf(". FPGA core ID: %08lx (expect 5a580001)\n", (unsigned long)reg_rd(R_ID));
    help();
}

void loop()
{
/* local variables */
    String s_line;
    String s_cmd;
/* its argument, where the first space is */
    String s_arg;
    int32_t i32_space;

/* a line from USB */
    if (Serial.available())
    {
        s_line = Serial.readStringUntil('\n');
        s_line.trim();
/* an empty line is no command */
        if (s_line.length() != 0)
        {
/* the command is the first word, the argument the rest */
            i32_space = s_line.indexOf(' ');
            s_cmd = s_line;
            s_arg = "";
/* split at the first space */
            if (i32_space >= 0)
            {
                s_cmd = s_line.substring(0, i32_space);
                s_arg = s_line.substring(i32_space + ONE);
            }
/* without spaces around it */
            s_arg.trim();
            command(s_cmd, s_arg);
        }
    }
}
