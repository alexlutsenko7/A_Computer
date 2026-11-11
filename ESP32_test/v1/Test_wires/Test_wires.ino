/* Test_wires -- ESP32 side of the ESP32 <-> FPGA wiring test (Test_wires/README.md). */
/* FPGA: Test_wires/fpga (Test_wires.sof). Board: ESP32 Dev Module (esp32:esp32:esp32, core 3.3.x). */
/* USB serial 115200, line ending "New Line". The whole test runs at reset and on Enter. */
/* */
/* Wires under test (same as LSpectrum, docs/LSpectrum_Connection.docx section 9): */
/*   FPGA -> ESP32: U7.7 R1 -> GPIO35, U7.8 R2 -> GPIO34, U7.19 F1 -> GPIO22, U7.20 F2 -> GPIO16 */
/*   ESP32 -> FPGA: GPIO14 -> U7.9 P1, GPIO13 -> U7.10 P2, GPIO33 -> U7.11 N1, */
/*                  GPIO26 -> U7.17 H1, GPIO25 -> U7.18 H2, GPIO17 -> U7.21 E1 */
/*   SD card on the ESP32: SCK GPIO18, MISO GPIO19, MOSI GPIO23, CS GPIO5 */
/* */
/* How it works: every FPGA output sends a UART frame (115200) that names the FPGA pin it */
/* leaves on and reports the levels and rising-edge counts the FPGA sees on its 6 inputs. */
/* The ESP32 samples all its pins every 2 us and decodes the frames in software, so each */
/* ESP32 input tells which FPGA pin it is really wired to. Then the ESP32 drives patterns */
/* and pulse bursts on its 6 outputs and checks what the FPGA reports back. */
/* */
/* Commands: */
/*   (Enter) / all     run every test (SD, FPGA -> ESP32, ESP32 -> FPGA levels, pulses) */
/*   sd                SD card: init + root folder      ls <path>   list an SD folder */
/*   back              FPGA -> ESP32 wires only (all ESP32 pins stay inputs) */
/*   fwd               ESP32 -> FPGA levels           fast   ESP32 -> FPGA pulse bursts */
/*   set <hex>         drive the 6 outputs (bit 0 GPIO14 ... bit 5 GPIO17) and leave them, for a meter */
/*   watch             print what the FPGA sees once a second; any input stops */
/*   sdprobe           SD reset command with every assignment of the 4 SD pins (finds swapped SD wires) */
/*   find              look for the FPGA frames on every free ESP32 pin (where did a wire land?) */
/*   raw               levels / edge counts / first 120 samples of all 10 pins (all inputs) */
/*   help */
#include <Arduino.h>
#include <SPI.h>
#include <SD.h>
/* pins and their registers, the cycle counter */
#include <driver/gpio.h>
#include <soc/gpio_reg.h>
#include <esp_cpu.h>
/* the permutations of the SD probe; the types */
#include <algorithm>
#include "Test_wires.h"

/* the SD card's pins */
#define SD_SCK 18
#define SD_MISO 19
#define SD_MOSI 23
/* its chip select; the speeds tried */
#define SD_CS 5
#define SD_SPEEDS 3
/* units */
#define HZ_PER_KHZ 1000
#define SHIFT_MB 20
/* the USB serial port, and the pause before the first text */
#define UART_BAUD 115200
#define START_DELAY_MS 500
/* all wires */
#define ALL_WIRES 10
/* capture: a sample every 2 us, at most 20000 of them */
#define SAMPLE_US 2
#define MAXS 20000
/* samples per UART bit (115200 baud) */
#define BIT_SAMPLES (1e6f / 115200.0f / SAMPLE_US)
/* the lines of one sample: 10 for the wires, 16 for the search */
#define PACK_MAX 16
/* GPIO32 and up are in the second input register */
#define GPIO_PORT1_FIRST 32
#define GPIO_REG_MASK 31
/* GPIO34 to 39 are inputs without pull resistors */
#define INPUT_ONLY_FIRST 34
#define INPUT_ONLY_LAST 39
/* sampling is too slow when it takes 2 % longer than it should */
#define SLOW_FRACTION 50
/* the software UART: bytes kept, the idle time that starts it (bit times) */
#define BYTES_MAX 2000
#define IDLE_BITS 15
/* where a byte is sampled, in bit times from its start edge */
#define HALF_SAMPLE 0.5f
#define START_CHECK 0.5f
#define FIRST_DATA 1.5f
/* the stop bit; data bits */
#define STOP_BIT 9.5f
#define DATA_BITS 8
/* a frame: 10 bytes, A5 first, a checksum (XOR with 5A) last */
#define FRAME_LEN 10
#define FRAME_MAGIC 0xA5
#define SUM_SEED 0x5A
/* its bytes */
#define F_ID 1
#define F_LVL 2
#define F_CNT 3
/* the checksum covers bytes 1 to 8 */
#define F_SUM_LAST 8
#define F_SUM 9
/* the ids of the FPGA's outputs */
#define ID_FIRST 0xC1
#define ID_LAST 0xC4
/* no id */
#define NO_ID (-1)
/* results */
#define R_NONE 0
#define R_PASS 1
#define R_FAIL 2
/* a frame from the FPGA: settle, then capture 6 ms */
#define FRAME_SETTLE_MS 3
#define FRAME_CAPTURE_US 6000
/* the 6 output bits, all set, the highest */
#define ALL_ONES6 0x3F
#define BITS6_TOP 5
#define BIT_MASK 1
/* a folder listing stops here */
#define LIST_MAX 500
/* the return-wire test: pull-downs on the two pins that have them, settle, capture 20 ms */
#define PULLDOWN_PIN_A 22
#define PULLDOWN_PIN_B 16
#define BACK_SETTLE_MS 5
/* the capture's length */
#define BACK_CAPTURE_US 20000
/* the level test's patterns: all 0, all 1, one 1, one 0 */
#define PATTERNS 14
/* a burst: 100 pulses at 2 MHz (a quarter of a microsecond high, a quarter low... per MHz of CPU clock) */
#define BURST_PULSES 100
#define QUARTER 4
#define WHAT_BUF 48
/* the SPI burst: 25 bytes of 0x55 at 8 MHz = 200 clock edges, 100 data edges */
#define LINK_HZ 8000000
#define SPI_BYTES 25
#define SPI_PATTERN 0x55
/* the edges it makes */
#define SPI_SCK_EDGES 200
#define SPI_MOSI_EDGES 100
#define NO_PIN (-1)
/* the wires the SPI burst uses */
#define W_SCK 0
#define W_MOSI 1
/* watch: once a second */
#define WATCH_MS 1000
/* the FPGA's inputs in the order they are printed */
#define IN_E1 5
#define IN_H2 4
#define IN_H1 3
/* the lower three */
#define IN_N1 2
#define IN_P2 1
/* raw: samples shown */
#define RAW_SHOWN 120
#define PERCENT 100.0f
/* the SD probe: bit time, idle bytes, the reset command */
#define SD_PINS 4
#define SD_BIT_US 5
#define SD_IDLE_BYTES 10
/* CMD0 and the wait for its answer */
#define CMD0_LEN 6
#define SD_RESP_TRIES 16
#define SD_NO_RESP (-1)
/* an idle byte */
#define SD_FILL 0xFF
/* the pins in the order CS, SCK, MOSI, MISO */
#define P_CS 0
#define P_SCK 1
#define P_MOSI 2
/* the last one */
#define P_MISO 3
/* the search: pins looked at; the first four are the return wires */
#define CANDIDATES 16
/* numbers are typed in hexadecimal */
#define HEX 16
/* one, signed and unsigned */
#define ONE 1
#define ONE_U 1u

/* FPGA -> ESP32; the FPGA marks frames on these with id C1..C4 (in this order) */
static const Wire g_as_ret[RET_WIRES] =
{
    {35, "GPIO35 (D35)", "R1", "U7.7",  "ESP_MISO"},
    {34, "GPIO34 (D34)", "R2", "U7.8",  "ESP_IRQ"},
    {22, "GPIO22 (D22)", "F1", "U7.19", "BT_DATA"},
    {16, "GPIO16 (RX2)", "F2", "U7.20", "BT_TX"},
};
/* ESP32 -> FPGA; bit n of the FPGA's level byte / counter n */
static const Wire g_as_fwd[FWD_WIRES] =
{
    {14, "GPIO14 (D14)", "P1", "U7.9",  "ESP_SCK"},
    {13, "GPIO13 (D13)", "P2", "U7.10", "ESP_MOSI"},
    {33, "GPIO33 (D33)", "N1", "U7.11", "ESP_CS_N"},
    {26, "GPIO26 (D26)", "H1", "U7.17", "BT_BCLK"},
    {25, "GPIO25 (D25)", "H2", "U7.18", "BT_LRCK"},
    {17, "GPIO17 (TX2)", "E1", "U7.21", "BT_RX"},
};
/* the SD card's speeds, fastest first */
static const uint32_t g_aui32_sd_hz[SD_SPEEDS] = {20000000, 4000000, 400000};
/* the SD reset command */
static const uint8_t g_aui8_cmd0[CMD0_LEN] = {0x40, 0, 0, 0, 0, 0x95};
/* the SD card's pins in the probe's order: CS, SCK, MOSI, MISO */
static const int32_t g_ai32_sd_pin[SD_PINS] = {SD_CS, SD_SCK, SD_MOSI, SD_MISO};
/* the pins the search looks at */
static const int32_t g_ai32_cand[CANDIDATES] = {35, 34, 22, 16, 36, 39, 32, 27, 4, 2, 15, 21, 5, 18, 19, 23};
/* capture: all 10 pins every 2 us (sample bit k = g_as_ret[k], bit 4+k = g_as_fwd[k]); 1 us is too fast */
/* for the loop (two GPIO register reads over the APB bus) */
static uint16_t g_aui16_smp[MAXS];
/* the UART bytes of the line being decoded */
static uint8_t g_aui8_bytes[BYTES_MAX];
/* bit masks per register, built once from the wires */
static uint32_t g_aui32_m_in[PACK_MAX];
static uint32_t g_aui32_m_in1[PACK_MAX];
/* results */
static int32_t g_ai32_r_ret[RET_WIRES];
static int32_t g_ai32_r_fwd[FWD_WIRES];
static int32_t g_ai32_r_fast[FWD_WIRES];
/* the two SPI buses */
SPIClass g_s_sdspi(VSPI);
SPIClass g_s_fastspi(HSPI);
/* samples taken, lines in a sample */
static int32_t g_i32_nsmp;
static int32_t g_i32_npack = ALL_WIRES;
/* length of the last capture in CPU cycles */
static uint32_t g_ui32_cap_cycles;
/* results of the SD card and of the SPI burst */
static int32_t g_i32_r_sd;
static int32_t g_i32_r_spi;
/* the card is mounted */
static bool g_b_sd_mounted;
/* no FPGA frames on the ESP32 output pins; at least one FPGA -> ESP32 wire carries frames */
static bool g_b_fwd_safe;
static bool g_b_any_back;

/* the register masks of one pin, into place i32_index of a sample */
static void pack_pin(int32_t i32_index, int32_t i32_gpio)
{
    g_aui32_m_in[i32_index] = 0;
    g_aui32_m_in1[i32_index] = 0;
/* the first or the second input register */
    if (i32_gpio < GPIO_PORT1_FIRST)
    {
        g_aui32_m_in[i32_index] = ONE_U << i32_gpio;
    }
    else
    {
        g_aui32_m_in1[i32_index] = ONE_U << (i32_gpio - GPIO_PORT1_FIRST);
    }
}

/* the masks of the 10 wires: the return wires first */
static void pack_init(void)
{
/* local variables */
    int32_t i32_index;

/* start values */
    g_i32_npack = ALL_WIRES;
    for (i32_index = 0; i32_index < ALL_WIRES; i32_index++)
    {
/* a wire from the FPGA */
        if (i32_index < RET_WIRES)
        {
            pack_pin(i32_index, g_as_ret[i32_index].i32_gpio);
        }
        else
        {
/* then the wires to the FPGA */
            pack_pin(i32_index, g_as_fwd[i32_index - RET_WIRES].i32_gpio);
        }
    }
}

/* the two input registers as one sample */
static inline uint16_t pack(uint32_t ui32_in, uint32_t ui32_in1)
{
/* local variables */
    uint16_t ui16_value;
    int32_t i32_index;

/* start values */
    ui16_value = 0;
    for (i32_index = 0; i32_index < g_i32_npack; i32_index++)
    {
/* the line is high */
        if (((ui32_in & g_aui32_m_in[i32_index]) | (ui32_in1 & g_aui32_m_in1[i32_index])) != 0)
        {
            ui16_value |= (uint16_t)(ONE << i32_index);
        }
    }
    return ui16_value;
}

/* sample all lines for i32_us microseconds, interrupts off */
static void capture(int32_t i32_us)
{
/* local variables */
    uint32_t ui32_step;
    uint32_t ui32_time;
    uint32_t ui32_start;
/* the cycles it should take, a counter */
    uint32_t ui32_want;
    int32_t i32_index;

/* as many samples as the buffer holds */
    g_i32_nsmp = i32_us / SAMPLE_US;
    if (g_i32_nsmp > MAXS)
    {
        g_i32_nsmp = MAXS;
    }
/* CPU cycles per sample */
    ui32_step = getCpuFrequencyMhz() * SAMPLE_US;
    Serial.flush();
    portDISABLE_INTERRUPTS();
/* from now */
    ui32_time = esp_cpu_get_cycle_count();
    ui32_start = ui32_time;
    for (i32_index = 0; i32_index < g_i32_nsmp; i32_index++)
    {
/* wait for the sample's time, then read both registers */
        while ((int32_t)(esp_cpu_get_cycle_count() - ui32_time) < 0)
        {
        }
        ui32_time += ui32_step;
        g_aui16_smp[i32_index] = pack(REG_READ(GPIO_IN_REG), REG_READ(GPIO_IN1_REG));
    }
/* how long it took, and how long it should have */
    g_ui32_cap_cycles = esp_cpu_get_cycle_count() - ui32_start;
    ui32_want = (uint32_t)g_i32_nsmp * ui32_step;
    if (g_ui32_cap_cycles > (ui32_want + (ui32_want / SLOW_FRACTION)))
    {
/* too slow */
        Serial.printf("WARNING: sampling too slow (%lu instead of %lu cycles): results not valid\n",
                      (unsigned long)g_ui32_cap_cycles, (unsigned long)ui32_want);
    }
    portENABLE_INTERRUPTS();
}

/* one line's level in one sample: 0 or 1 */
static int32_t level(int32_t i32_sample, int32_t i32_bit)
{
    return (g_aui16_smp[i32_sample] >> i32_bit) & BIT_MASK;
}

/* software UART decode of one sampled line: its bytes into g_aui8_bytes; returns how many */
static int32_t uart_bytes(int32_t i32_bit, LineStat *ps_stat)
{
/* local variables */
    int32_t i32_count;
    int32_t i32_index;
    int32_t i32_high;
/* the stop bit's sample, a data bit's number */
    int32_t i32_stop;
    int32_t i32_data;
    float f_start;
/* the byte, the end of the samples */
    uint8_t ui8_value;
    bool b_done;

/* start values */
    i32_count = 0;
    i32_index = ONE;
    i32_high = 0;
/* nothing decoded yet */
    i32_stop = 0;
    i32_data = 0;
    f_start = 0;
/* no byte yet; not at the end */
    ui8_value = 0;
    b_done = false;
/* sync: start after the first idle gap (the FPGA leaves 20 bit times between frames), */
/* so a capture that begins inside a byte does not count as a framing error */
    while ((i32_index < g_i32_nsmp) && (i32_high < (int32_t)(IDLE_BITS * BIT_SAMPLES)))
    {
        if (level(i32_index, i32_bit) != 0)
        {
            i32_high++;
        }
        else
        {
/* low: the idle time starts again */
            i32_high = 0;
        }
        i32_index++;
    }
/* byte by byte */
    while ((i32_index < g_i32_nsmp) && !b_done)
    {
        if (!((level(i32_index - ONE, i32_bit) != 0) && (level(i32_index, i32_bit) == 0)))
        {
/* no falling edge here */
            i32_index++;
        }
        else
        {
/* a start bit: the edge is between the two samples */
            f_start = i32_index - HALF_SAMPLE;
            i32_stop = (int32_t)(f_start + (STOP_BIT * BIT_SAMPLES));
            if (i32_stop >= g_i32_nsmp)
            {
/* the byte does not end inside the capture */
                b_done = true;
            }
            else if (level((int32_t)(f_start + (START_CHECK * BIT_SAMPLES)), i32_bit) != 0)
            {
/* high again in the middle of the start bit: a glitch */
                i32_index++;
            }
            else
            {
/* the eight data bits, least significant first */
                ui8_value = 0;
                for (i32_data = 0; i32_data < DATA_BITS; i32_data++)
                {
                    ui8_value |= (uint8_t)(level((int32_t)(f_start + ((FIRST_DATA + i32_data) * BIT_SAMPLES)), i32_bit) << i32_data);
                }
/* a high stop bit makes it a byte */
                if (level(i32_stop, i32_bit) != 0)
                {
                    if (i32_count < BYTES_MAX)
                    {
/* kept while the buffer has room */
                        g_aui8_bytes[i32_count] = ui8_value;
                        i32_count++;
                    }
                    ps_stat->i32_bytes++;
                }
                else
                {
/* a framing error */
                    ps_stat->i32_ferr++;
                }
                i32_index = i32_stop + ONE;
            }
        }
    }
    return i32_count;
}

/* the frames in the decoded bytes: A5, id, levels, 6 counters, checksum */
static void parse_frames(int32_t i32_count, LineStat *ps_stat)
{
/* local variables */
    Frame s_frame;
    int32_t i32_index;
/* a byte's index in the frame, the checksum */
    int32_t i32_byte;
    uint8_t ui8_sum;

/* start values */
    i32_index = 0;
    i32_byte = 0;
    ui8_sum = 0;
/* while a whole frame can follow */
    while ((i32_index + FRAME_LEN) <= i32_count)
    {
/* the checksum of the bytes behind this one */
        ui8_sum = SUM_SEED;
        for (i32_byte = F_ID; i32_byte <= F_SUM_LAST; i32_byte++)
        {
            ui8_sum ^= g_aui8_bytes[i32_index + i32_byte];
        }
/* a frame starts with A5 and has the right checksum */
        if ((g_aui8_bytes[i32_index] != FRAME_MAGIC) || (ui8_sum != g_aui8_bytes[i32_index + F_SUM]))
        {
            i32_index++;
        }
        else
        {
/* its contents */
            s_frame.ui8_id = g_aui8_bytes[i32_index + F_ID];
            s_frame.ui8_lvl = g_aui8_bytes[i32_index + F_LVL];
            memcpy(s_frame.aui8_cnt, &g_aui8_bytes[i32_index + F_CNT], FWD_WIRES);
/* counted by its id */
            ps_stat->i32_frames++;
            if ((s_frame.ui8_id >= ID_FIRST) && (s_frame.ui8_id <= ID_LAST))
            {
                ps_stat->ai32_id_count[s_frame.ui8_id - ID_FIRST]++;
            }
            else
            {
/* another id */
                ps_stat->i32_other_ids++;
            }
/* the last one is kept */
            ps_stat->s_last = s_frame;
            ps_stat->b_have = true;
            i32_index += FRAME_LEN;
        }
    }
}

/* what one sampled line carried: levels, edges, UART bytes, frames */
static LineStat decode(int32_t i32_bit)
{
/* local variables */
    LineStat s_stat = {};
    int32_t i32_index;
/* a sample's level, the bytes decoded */
    int32_t i32_level;
    int32_t i32_count;

/* start values */
    i32_index = 0;
    i32_level = 0;
    i32_count = 0;
/* ones and edges */
    for (i32_index = 0; i32_index < g_i32_nsmp; i32_index++)
    {
        i32_level = level(i32_index, i32_bit);
        s_stat.i32_ones += i32_level;
/* a change from the sample before */
        if ((i32_index != 0) && (i32_level != level(i32_index - ONE, i32_bit)))
        {
            s_stat.i32_edges++;
        }
    }
/* bytes, then frames */
    i32_count = uart_bytes(i32_bit, &s_stat);
    parse_frames(i32_count, &s_stat);
    return s_stat;
}

/* index of the return-wire id seen most on this line, or NO_ID */
static int32_t main_id(const LineStat &r_stat)
{
/* local variables */
    int32_t i32_best;
    int32_t i32_index;

/* start values */
    i32_best = NO_ID;
    for (i32_index = 0; i32_index < RET_WIRES; i32_index++)
    {
        if ((r_stat.ai32_id_count[i32_index] != 0) &&
            ((i32_best < 0) || (r_stat.ai32_id_count[i32_index] > r_stat.ai32_id_count[i32_best])))
        {
/* the best so far */
            i32_best = i32_index;
        }
    }
    return i32_best;
}

/* a result as text */
static const char *res(int32_t i32_result)
{
/* local variables */
    const char *pc_text;

/* start values */
    pc_text = "not tested";
    if (i32_result == R_PASS)
    {
        pc_text = "OK";
    }
/* failed */
    else if (i32_result == R_FAIL)
    {
        pc_text = "FAIL";
    }
    else
    {
/* not tested */
    }
    return pc_text;
}

/* every pin an input */
static void outputs_off(void)
{
/* local variables */
    int32_t i32_index;

    for (i32_index = 0; i32_index < FWD_WIRES; i32_index++)
    {
        pinMode(g_as_fwd[i32_index].i32_gpio, INPUT);
    }
/* also enables the input buffer (off by default on GPIO34/35) */
    for (i32_index = 0; i32_index < RET_WIRES; i32_index++)
    {
        pinMode(g_as_ret[i32_index].i32_gpio, INPUT);
    }
}

/* the six outputs driven: bit n of the value on wire n */
static void outputs_on(uint8_t ui8_value)
{
/* local variables */
    int32_t i32_index;

    for (i32_index = 0; i32_index < FWD_WIRES; i32_index++)
    {
/* the level before and after the pin becomes an output */
        digitalWrite(g_as_fwd[i32_index].i32_gpio, (ui8_value >> i32_index) & BIT_MASK);
        pinMode(g_as_fwd[i32_index].i32_gpio, OUTPUT);
        digitalWrite(g_as_fwd[i32_index].i32_gpio, (ui8_value >> i32_index) & BIT_MASK);
    }
}

/* latest frame from the FPGA over any working return wire (started after this call) */
static bool fpga_frame(Frame &r_frame)
{
/* local variables */
    LineStat s_stat;
    int32_t i32_index;
    bool b_found;

/* start values */
    i32_index = 0;
    b_found = false;
/* a short capture */
    delay(FRAME_SETTLE_MS);
    capture(FRAME_CAPTURE_US);
/* the first return wire that has one */
    while ((i32_index < RET_WIRES) && !b_found)
    {
        s_stat = decode(i32_index);
        if (s_stat.b_have)
        {
/* its last frame */
            r_frame = s_stat.s_last;
            b_found = true;
        }
/* the next wire */
        i32_index++;
    }
    return b_found;
}

/* six bits, the highest first */
static void print_bits6(uint8_t ui8_value)
{
/* local variables */
    int32_t i32_bit;

    for (i32_bit = BITS6_TOP; i32_bit >= 0; i32_bit--)
    {
        Serial.print((ui8_value >> i32_bit) & BIT_MASK);
    }
}

/* SD card */

/* a folder of the card on USB */
static void list_dir(const char *pc_path)
{
/* local variables */
    File s_dir;
    File s_file;
    int32_t i32_dirs;
/* files counted, more to list */
    int32_t i32_files;
    bool b_more;

/* start values */
    i32_dirs = 0;
    i32_files = 0;
    b_more = true;
/* the folder */
    s_dir = SD.open(pc_path);
/* it must be a folder */
    if (!s_dir || !s_dir.isDirectory())
    {
        Serial.printf("  cannot open folder %s\n", pc_path);
    }
    else
    {
/* its entries */
        Serial.printf("  folder %s:\n", pc_path);
        s_file = s_dir.openNextFile();
/* entry by entry */
        while (s_file && b_more)
        {
            if (s_file.isDirectory())
            {
/* a folder */
                Serial.printf("    <DIR>        %s\n", s_file.name());
                i32_dirs++;
            }
            else
            {
/* a file with its size */
                Serial.printf("    %10lu   %s\n", (unsigned long)s_file.size(), s_file.name());
                i32_files++;
            }
            s_file.close();
/* not more than 500 */
            if ((i32_dirs + i32_files) >= LIST_MAX)
            {
                Serial.println("    ... (stopped at 500 entries)");
                b_more = false;
            }
            else
            {
/* the next entry */
                s_file = s_dir.openNextFile();
            }
        }
/* the totals */
        s_dir.close();
        Serial.printf("  %d folders, %d files\n", (int)i32_dirs, (int)i32_files);
    }
}

/* the card's type as text */
static const char *card_type(void)
{
/* local variables */
    const char *pc_type;

/* start values */
    pc_type = "unknown";
    if (SD.cardType() == CARD_MMC)
    {
        pc_type = "MMC";
    }
/* standard capacity */
    else if (SD.cardType() == CARD_SD)
    {
        pc_type = "SDSC";
    }
    else if (SD.cardType() == CARD_SDHC)
    {
/* high capacity */
        pc_type = "SDHC/SDXC";
    }
    else
    {
/* unknown */
    }
    return pc_type;
}

/* the SD card: found at the full speed, and its root folder */
static void test_sd(void)
{
/* local variables */
    uint32_t ui32_hz;
    int32_t i32_speed;
    bool b_found;

/* start values */
    ui32_hz = 0;
    i32_speed = 0;
    b_found = false;
/* the SD library lets the card go first */
    Serial.println("\n=== SD card (on the ESP32: SCK 18, MISO 19, MOSI 23, CS 5) ===");
    SD.end();
    g_b_sd_mounted = false;
/* the fastest speed first */
    while ((i32_speed < SD_SPEEDS) && !b_found)
    {
        ui32_hz = g_aui32_sd_hz[i32_speed];
/* the SPI bus from scratch */
        g_s_sdspi.end();
        g_s_sdspi.begin(SD_SCK, SD_MISO, SD_MOSI, SD_CS);
/* internal pull-up on MISO (an external 10k-47k is better) */
        gpio_pullup_en((gpio_num_t)SD_MISO);
        if (SD.begin(SD_CS, g_s_sdspi, ui32_hz))
        {
/* found */
            g_b_sd_mounted = true;
            b_found = true;
/* what it is */
            Serial.printf("  card found at %lu kHz: %s, %llu MB, FAT used %llu of %llu MB\n",
                          (unsigned long)(ui32_hz / HZ_PER_KHZ), card_type(), SD.cardSize() >> SHIFT_MB,
                          SD.usedBytes() >> SHIFT_MB, SD.totalBytes() >> SHIFT_MB);
            if (i32_speed != 0)
            {
                Serial.println("  WARNING: works only at a lower clock: check SCK/MISO/MOSI wiring, length, ground");
            }
/* its root; only the full speed is a pass */
            list_dir("/");
            g_i32_r_sd = R_FAIL;
/* the full speed */
            if (i32_speed == 0)
            {
                g_i32_r_sd = R_PASS;
            }
        }
        else
        {
/* not at this speed */
            SD.end();
            Serial.printf("  no card at %lu kHz\n", (unsigned long)(ui32_hz / HZ_PER_KHZ));
        }
        i32_speed++;
    }
/* at no speed */
    if (!b_found)
    {
        g_i32_r_sd = R_FAIL;
/* what to check */
        Serial.println("  FAIL: SD card not found. Check: card inserted, 3V3 + GND to the SD board, CS = GPIO5,");
        Serial.println("        SCK = GPIO18, MOSI = GPIO23 -> card DI, MISO = GPIO19 <- card DO (DI/DO swapped is common),");
        Serial.println("        card formatted FAT16/FAT32 (exFAT is not supported).");
    }
}

/* FPGA -> ESP32 (also the safety check: no FPGA output may sit on an ESP32 output pin) */

/* why a line carries no frames */
static void describe_dead(const LineStat &r_stat, const char *pc_pull)
{
/* local variables */
    int32_t i32_level;

/* start values */
    i32_level = 0;
    if (r_stat.i32_ones != 0)
    {
        i32_level = ONE;
    }
/* no edges at all, or edges without frames */
    if (r_stat.i32_edges == 0)
    {
        Serial.printf("always %d (%s): wire open, wrong pin, or FPGA not loaded\n", (int)i32_level, pc_pull);
    }
    else
    {
        Serial.printf("%d edges but no valid frame (%d bytes, %d framing errors): floating, or shorted to another wire\n",
                      (int)r_stat.i32_edges, (int)r_stat.i32_bytes, (int)r_stat.i32_ferr);
    }
}

/* one return wire: which FPGA output do its frames name? */
static void back_wire(int32_t i32_wire)
{
/* local variables */
    const Wire *ps_wire;
    const char *pc_pull;
    LineStat s_stat;
/* the id seen most, frames with another id */
    int32_t i32_main;
    int32_t i32_mixed;

/* start values */
    ps_wire = &g_as_ret[i32_wire];
    pc_pull = "ESP32 pull-down";
    s_stat = decode(i32_wire);
/* which output the line names */
    i32_main = main_id(s_stat);
    i32_mixed = 0;
/* GPIO34 and up have no pull resistor */
    if (ps_wire->i32_gpio >= INPUT_ONLY_FIRST)
    {
        pc_pull = "input-only pin, no pull resistor";
    }
/* the wire, then what was found on it */
    Serial.printf("  %-13s expects FPGA %s %-5s (%-8s): ", ps_wire->pc_esp, ps_wire->pc_fpga, ps_wire->pc_u7, ps_wire->pc_sig);
    g_ai32_r_ret[i32_wire] = R_FAIL;
/* no frames at all */
    if (s_stat.i32_frames == 0)
    {
        describe_dead(s_stat, pc_pull);
    }
    else
    {
/* frames: this wire works at least in part */
        g_b_any_back = true;
        if (i32_main >= 0)
        {
            i32_mixed = s_stat.i32_frames - s_stat.ai32_id_count[i32_main];
        }
/* the right output and nothing else */
        if ((i32_main == i32_wire) && (i32_mixed == 0) && (s_stat.i32_ferr == 0))
        {
            Serial.printf("OK (%d frames)\n", (int)s_stat.i32_frames);
/* passed */
            g_ai32_r_ret[i32_wire] = R_PASS;
        }
        else if (i32_main == i32_wire)
        {
/* the right output, with errors */
            Serial.printf("right pin but unreliable: %d good frames, %d from other pins, %d framing errors (short / noise?)\n",
                          (int)s_stat.ai32_id_count[i32_main], (int)i32_mixed, (int)s_stat.i32_ferr);
        }
        else if (i32_main < 0)
        {
            Serial.printf("frames with unknown id: noise\n");
        }
        else
        {
/* another output */
            Serial.printf("SWAPPED: wired to FPGA %s %s (%s)\n", g_as_ret[i32_main].pc_fpga, g_as_ret[i32_main].pc_u7,
                          g_as_ret[i32_main].pc_sig);
        }
    }
}

/* the four wires from the FPGA, with every ESP32 pin an input */
static void test_back(void)
{
/* local variables */
    LineStat s_stat;
    int32_t i32_index;
    int32_t i32_main;

/* start values */
    i32_index = 0;
    i32_main = NO_ID;
    Serial.println("\n=== FPGA -> ESP32 wires (ESP32 pins all inputs) ===");
/* all inputs; pull-downs where the pins have them */
    outputs_off();
    gpio_pulldown_en((gpio_num_t)PULLDOWN_PIN_A);
    gpio_pulldown_en((gpio_num_t)PULLDOWN_PIN_B);
/* 20 ms of samples */
    delay(BACK_SETTLE_MS);
    capture(BACK_CAPTURE_US);
    g_b_any_back = false;
/* wire by wire */
    for (i32_index = 0; i32_index < RET_WIRES; i32_index++)
    {
        back_wire(i32_index);
    }
/* the pull-downs off again */
    gpio_pulldown_dis((gpio_num_t)PULLDOWN_PIN_A);
    gpio_pulldown_dis((gpio_num_t)PULLDOWN_PIN_B);
/* the ESP32 output pins, still inputs: an FPGA output there would fight the ESP32 */
    g_b_fwd_safe = true;
    for (i32_index = 0; i32_index < FWD_WIRES; i32_index++)
    {
/* the line's statistics */
        s_stat = decode(RET_WIRES + i32_index);
        i32_main = main_id(s_stat);
/* frames on a pin that will be an output */
        if (i32_main >= 0)
        {
            Serial.printf("  DANGER: %s (should go to FPGA input %s %s) carries FPGA output %s %s (%s)\n",
                          g_as_fwd[i32_index].pc_esp, g_as_fwd[i32_index].pc_fpga, g_as_fwd[i32_index].pc_u7,
                          g_as_ret[i32_main].pc_fpga, g_as_ret[i32_main].pc_u7, g_as_ret[i32_main].pc_sig);
            g_b_fwd_safe = false;
        }
    }
/* what that means for the other tests */
    if (!g_b_fwd_safe)
    {
        Serial.println("  ESP32 -> FPGA tests are skipped until this is fixed (two outputs would fight).");
    }
/* no return wire works */
    if (!g_b_any_back)
    {
        Serial.println("  No frames from the FPGA at all: is Test_wires.sof loaded (LED blinking)? Common GND wire? "
                       "Without a working return wire the ESP32 -> FPGA tests cannot run.");
    }
}

/* ESP32 -> FPGA, static levels */

/* bit i32_bit of every pattern, as one word: pattern n in bit n */
static uint16_t column(const uint8_t *pui8_values, int32_t i32_bit)
{
/* local variables */
    uint16_t ui16_column;
    int32_t i32_index;

/* start values */
    ui16_column = 0;
    for (i32_index = 0; i32_index < PATTERNS; i32_index++)
    {
        ui16_column |= (uint16_t)(((pui8_values[i32_index] >> i32_bit) & BIT_MASK) << i32_index);
    }
/* one bit per pattern */
    return ui16_column;
}

/* the level patterns driven, and what the FPGA saw of each; false: the FPGA's frames were lost */
static bool fwd_measure(uint8_t aui8_pat[PATTERNS], uint8_t aui8_obs[PATTERNS])
{
/* local variables */
    Frame s_frame;
    int32_t i32_count;
/* a counter, frames still coming */
    int32_t i32_index;
    bool b_ok;

/* start values */
    i32_count = 0;
    i32_index = 0;
    b_ok = true;
/* all 0, all 1 */
    aui8_pat[i32_count] = 0;
    i32_count++;
/* all 1 */
    aui8_pat[i32_count] = ALL_ONES6;
    i32_count++;
/* one wire high */
    for (i32_index = 0; i32_index < FWD_WIRES; i32_index++)
    {
        aui8_pat[i32_count] = (uint8_t)(ONE << i32_index);
        i32_count++;
    }
/* one wire low */
    for (i32_index = 0; i32_index < FWD_WIRES; i32_index++)
    {
        aui8_pat[i32_count] = (uint8_t)(ALL_ONES6 ^ (ONE << i32_index));
        i32_count++;
    }
/* pattern by pattern */
    outputs_on(0);
    Serial.println("  ESP32 drives   FPGA sees   (bit order: GPIO17 25 26 33 13 14 = E1 H2 H1 N1 P2 P1)");
/* from the first */
    i32_index = 0;
    while ((i32_index < PATTERNS) && b_ok)
    {
/* driven, then the FPGA's frame */
        outputs_on(aui8_pat[i32_index]);
        if (!fpga_frame(s_frame))
        {
/* no frame: the test cannot go on */
            Serial.println("  lost the FPGA frames");
            b_ok = false;
        }
        else
        {
/* what was driven, what was seen */
            aui8_obs[i32_index] = s_frame.ui8_lvl & ALL_ONES6;
            Serial.print("  ");
            print_bits6(aui8_pat[i32_index]);
/* the gap, then what the FPGA saw */
            Serial.print("         ");
            print_bits6(aui8_obs[i32_index]);
/* a difference is marked */
            if (aui8_obs[i32_index] == aui8_pat[i32_index])
            {
                Serial.println("");
            }
            else
            {
                Serial.println("   <- differs");
            }
        }
/* the next pattern */
        i32_index++;
    }
/* the pins are inputs again */
    outputs_off();
    return b_ok;
}

/* an FPGA input that follows no single ESP32 pin: is it the AND or OR of two (a short)? */
static void fwd_short(uint16_t ui16_seen, const uint16_t aui16_expect[FWD_WIRES])
{
/* local variables */
    int32_t i32_first;
    int32_t i32_second;
    bool b_named;

/* start values */
    i32_first = 0;
    i32_second = 0;
    b_named = false;
/* every pair of wires, until one fits */
    for (i32_first = 0; (i32_first < FWD_WIRES) && !b_named; i32_first++)
    {
        for (i32_second = i32_first + ONE; (i32_second < FWD_WIRES) && !b_named; i32_second++)
        {
            if ((ui16_seen == (aui16_expect[i32_first] & aui16_expect[i32_second])) ||
                (ui16_seen == (aui16_expect[i32_first] | aui16_expect[i32_second])))
            {
/* a short between these two */
                Serial.printf("follows %s AND/OR %s: those two wires are shorted together\n", g_as_fwd[i32_first].pc_esp,
                              g_as_fwd[i32_second].pc_esp);
                b_named = true;
            }
        }
    }
/* no pair either */
    if (!b_named)
    {
        Serial.println("follows no ESP32 pin: short, or bad contact");
    }
}

/* the six wires to the FPGA with static levels */
static void test_fwd(void)
{
/* local variables */
    uint8_t aui8_pat[PATTERNS];
    uint8_t aui8_obs[PATTERNS];
    uint16_t aui16_expect[FWD_WIRES];
/* what one FPGA input saw, all patterns as ones */
    uint16_t ui16_seen;
    uint16_t ui16_all;
/* counters, the ESP32 pin an input follows */
    int32_t i32_input;
    int32_t i32_index;
    int32_t i32_who;

/* start values */
    ui16_seen = 0;
    ui16_all = (uint16_t)((ONE << PATTERNS) - ONE);
    i32_input = 0;
/* nothing found yet */
    i32_index = 0;
    i32_who = NO_ID;
    Serial.println("\n=== ESP32 -> FPGA wires, levels (14 patterns) ===");
/* only when it is safe and the FPGA can answer */
    if (!g_b_fwd_safe || !g_b_any_back)
    {
        Serial.println("  skipped (see above)");
    }
    else if (fwd_measure(aui8_pat, aui8_obs))
    {
/* what each FPGA input should have seen over the patterns */
        for (i32_index = 0; i32_index < FWD_WIRES; i32_index++)
        {
            aui16_expect[i32_index] = column(aui8_pat, i32_index);
        }
/* FPGA input by input */
        for (i32_input = 0; i32_input < FWD_WIRES; i32_input++)
        {
            ui16_seen = column(aui8_obs, i32_input);
            Serial.printf("  FPGA %s %-5s (%-8s) expects %-13s: ", g_as_fwd[i32_input].pc_fpga, g_as_fwd[i32_input].pc_u7,
                          g_as_fwd[i32_input].pc_sig, g_as_fwd[i32_input].pc_esp);
/* a failure unless it follows its own pin */
            g_ai32_r_fwd[i32_input] = R_FAIL;
            i32_who = NO_ID;
/* which ESP32 pin does it follow? */
            for (i32_index = 0; i32_index < FWD_WIRES; i32_index++)
            {
                if (aui16_expect[i32_index] == ui16_seen)
                {
                    i32_who = i32_index;
                }
            }
/* its own pin, another pin, stuck, or a short */
            if (i32_who == i32_input)
            {
                Serial.println("OK");
                g_ai32_r_fwd[i32_input] = R_PASS;
            }
/* another pin */
            else if (i32_who >= 0)
            {
                Serial.printf("SWAPPED: driven by %s\n", g_as_fwd[i32_who].pc_esp);
            }
            else if (ui16_seen == ui16_all)
            {
/* never low */
                Serial.println("always 1: wire open (FPGA pull-up) or wrong pin");
            }
            else if (ui16_seen == 0)
            {
                Serial.println("always 0: shorted to GND?");
            }
            else
            {
/* it follows something, but no single pin */
                fwd_short(ui16_seen, aui16_expect);
            }
        }
    }
    else
    {
/* the frames were lost: said by fwd_measure */
    }
}

/* ESP32 -> FPGA, pulse bursts (edge counters): speed, missing edges, extra edges, crosstalk */

/* i32_count pulses at 2 MHz on one pin */
static void burst(int32_t i32_gpio, int32_t i32_count)
{
/* local variables */
    uint32_t ui32_mask;
    uint32_t ui32_set_reg;
    uint32_t ui32_clear_reg;
/* a quarter microsecond in CPU cycles, the time, a counter */
    uint32_t ui32_quarter;
    uint32_t ui32_time;
    int32_t i32_index;

/* the pin's bit, and the registers that set and clear it */
    ui32_mask = ONE_U << (i32_gpio & GPIO_REG_MASK);
    ui32_set_reg = GPIO_OUT_W1TS_REG;
    ui32_clear_reg = GPIO_OUT_W1TC_REG;
/* GPIO32 and up are in the second register */
    if (i32_gpio >= GPIO_PORT1_FIRST)
    {
        ui32_set_reg = GPIO_OUT1_W1TS_REG;
        ui32_clear_reg = GPIO_OUT1_W1TC_REG;
    }
/* 250 ns high, 250 ns low */
    ui32_quarter = getCpuFrequencyMhz() / QUARTER;
    portDISABLE_INTERRUPTS();
/* from now */
    ui32_time = esp_cpu_get_cycle_count();
    for (i32_index = 0; i32_index < i32_count; i32_index++)
    {
/* high */
        REG_WRITE(ui32_set_reg, ui32_mask);
        ui32_time += ui32_quarter;
        while ((int32_t)(esp_cpu_get_cycle_count() - ui32_time) < 0)
        {
        }
/* low */
        REG_WRITE(ui32_clear_reg, ui32_mask);
        ui32_time += ui32_quarter;
        while ((int32_t)(esp_cpu_get_cycle_count() - ui32_time) < 0)
        {
        }
    }
/* interrupts on again */
    portENABLE_INTERRUPTS();
}

/* counter differences after - before; ai32_expect[k] per input; prints and returns true if all match */
static bool check_counts(const Frame &r_before, const Frame &r_after, const int32_t ai32_expect[FWD_WIRES], const char *pc_what)
{
/* local variables */
    int32_t i32_index;
    int32_t i32_diff;
    bool b_ok;

/* start values */
    i32_index = 0;
    i32_diff = 0;
    b_ok = true;
/* what is checked */
    Serial.printf("  %-34s", pc_what);
/* the counters are 8 bits wide */
    for (i32_index = 0; i32_index < FWD_WIRES; i32_index++)
    {
        i32_diff = (uint8_t)(r_after.aui8_cnt[i32_index] - r_before.aui8_cnt[i32_index]);
        Serial.printf(" %s:%3d", g_as_fwd[i32_index].pc_fpga, (int)i32_diff);
/* not what was sent */
        if (i32_diff != ai32_expect[i32_index])
        {
            b_ok = false;
        }
    }
/* the verdict */
    if (b_ok)
    {
        Serial.println("   OK");
    }
    else
    {
        Serial.println("   <- wrong");
    }
/* true = all six as expected */
    return b_ok;
}

/* a result from a check */
static int32_t pass_fail(bool b_ok)
{
/* local variables */
    int32_t i32_result;

/* start values */
    i32_result = R_FAIL;
    if (b_ok)
    {
/* passed */
        i32_result = R_PASS;
    }
    return i32_result;
}

/* the real link speed: 8 MHz SPI on SCK (200 rising edges) with 0x55 on MOSI (100) */
static void test_spi(void)
{
/* local variables */
    uint8_t aui8_buf[SPI_BYTES];
    int32_t ai32_expect[FWD_WIRES];
    Frame s_before;
/* after the burst; both frames came */
    Frame s_after;
    bool b_got;

/* the SPI bus on the first two wires */
    outputs_on(0);
    pinMode(g_as_fwd[W_SCK].i32_gpio, INPUT);
/* the bus drives them */
    pinMode(g_as_fwd[W_MOSI].i32_gpio, INPUT);
    g_s_fastspi.begin(g_as_fwd[W_SCK].i32_gpio, NO_PIN, g_as_fwd[W_MOSI].i32_gpio, NO_PIN);
/* the counters before, the burst, the counters after */
    b_got = fpga_frame(s_before);
    g_s_fastspi.beginTransaction(SPISettings(LINK_HZ, MSBFIRST, SPI_MODE0));
/* 25 bytes of 0x55 */
    memset(aui8_buf, SPI_PATTERN, sizeof aui8_buf);
    g_s_fastspi.transferBytes(aui8_buf, nullptr, sizeof aui8_buf);
/* the bus is given back */
    g_s_fastspi.endTransaction();
    b_got = b_got && fpga_frame(s_after);
/* the pins are inputs again */
    g_s_fastspi.end();
    outputs_off();
    if (!b_got)
    {
/* no frames */
        Serial.println("  lost the FPGA frames");
        g_i32_r_spi = R_FAIL;
    }
    else
    {
/* edges only on the clock and the data wire */
        memset(ai32_expect, 0, sizeof ai32_expect);
        ai32_expect[W_SCK] = SPI_SCK_EDGES;
        ai32_expect[W_MOSI] = SPI_MOSI_EDGES;
/* compared, and explained */
        g_i32_r_spi = pass_fail(check_counts(s_before, s_after, ai32_expect, "8 MHz SPI, 25 x 0x55 (link speed):"));
        Serial.println("  (more edges than sent = ringing/crosstalk, fewer = slow edges or bad contact)");
    }
}

/* the six wires to the FPGA with pulse bursts, then the SPI burst */
static void test_fast(void)
{
/* local variables */
    char ac_what[WHAT_BUF];
    int32_t ai32_expect[FWD_WIRES];
    Frame s_before;
/* after a burst, the wire, frames still coming */
    Frame s_after;
    int32_t i32_wire;
    bool b_ok;

/* start values */
    i32_wire = 0;
    b_ok = true;
    Serial.println("\n=== ESP32 -> FPGA wires, pulse bursts (FPGA rising-edge counters) ===");
/* only when it is safe and the FPGA can answer */
    if (!g_b_fwd_safe || !g_b_any_back)
    {
        Serial.println("  skipped (see above)");
    }
    else
    {
/* wire by wire: the counters before, 100 pulses, the counters after */
        while ((i32_wire < FWD_WIRES) && b_ok)
        {
            outputs_on(0);
            b_ok = fpga_frame(s_before);
/* the burst */
            if (b_ok)
            {
                burst(g_as_fwd[i32_wire].i32_gpio, BURST_PULSES);
                b_ok = fpga_frame(s_after);
            }
/* without frames the bursts end here */
            if (!b_ok)
            {
                Serial.println("  lost the FPGA frames");
            }
            else
            {
/* 100 edges on this input, none on the others */
                memset(ai32_expect, 0, sizeof ai32_expect);
                ai32_expect[i32_wire] = BURST_PULSES;
                snprintf(ac_what, sizeof ac_what, "100 x 2 MHz on %s:", g_as_fwd[i32_wire].pc_esp);
/* compared */
                g_ai32_r_fast[i32_wire] = pass_fail(check_counts(s_before, s_after, ai32_expect, ac_what));
            }
            i32_wire++;
        }
/* the link's real speed */
        test_spi();
    }
}

/* the result of one wire to the FPGA from its two tests */
static int32_t fwd_result(int32_t i32_wire)
{
/* local variables */
    int32_t i32_result;

/* start values */
    i32_result = R_NONE;
    if ((g_ai32_r_fwd[i32_wire] == R_PASS) && (g_ai32_r_fast[i32_wire] == R_PASS))
    {
        i32_result = R_PASS;
    }
/* one of them failed */
    else if ((g_ai32_r_fwd[i32_wire] == R_FAIL) || (g_ai32_r_fast[i32_wire] == R_FAIL))
    {
        i32_result = R_FAIL;
    }
    else
    {
/* not tested */
    }
    return i32_result;
}

/* every result on one screen */
static void summary(void)
{
/* local variables */
    int32_t i32_index;
    bool b_all;

/* the card, then the wires from the FPGA */
    Serial.println("\n=== Summary ===");
    Serial.printf("  SD card                                   %s\n", res(g_i32_r_sd));
/* wire by wire */
    for (i32_index = 0; i32_index < RET_WIRES; i32_index++)
    {
        Serial.printf("  FPGA %s %-5s -> %-13s %-8s  %s\n", g_as_ret[i32_index].pc_fpga, g_as_ret[i32_index].pc_u7,
                      g_as_ret[i32_index].pc_esp, g_as_ret[i32_index].pc_sig, res(g_ai32_r_ret[i32_index]));
    }
/* the wires to the FPGA: both tests */
    for (i32_index = 0; i32_index < FWD_WIRES; i32_index++)
    {
        Serial.printf("  %-13s -> FPGA %s %-5s %-8s  %s (levels %s, pulses %s)\n", g_as_fwd[i32_index].pc_esp,
                      g_as_fwd[i32_index].pc_fpga, g_as_fwd[i32_index].pc_u7, g_as_fwd[i32_index].pc_sig,
                      res(fwd_result(i32_index)), res(g_ai32_r_fwd[i32_index]), res(g_ai32_r_fast[i32_index]));
    }
/* the SPI burst; then: did everything pass? */
    Serial.printf("  8 MHz SPI on SCK/MOSI                     %s\n", res(g_i32_r_spi));
    b_all = (g_i32_r_sd == R_PASS) && (g_i32_r_spi == R_PASS);
/* the wires from the FPGA */
    for (i32_index = 0; i32_index < RET_WIRES; i32_index++)
    {
        b_all = b_all && (g_ai32_r_ret[i32_index] == R_PASS);
    }
/* the wires to the FPGA */
    for (i32_index = 0; i32_index < FWD_WIRES; i32_index++)
    {
        b_all = b_all && (g_ai32_r_fwd[i32_index] == R_PASS) && (g_ai32_r_fast[i32_index] == R_PASS);
    }
/* the verdict */
    if (b_all)
    {
        Serial.println("  ALL WIRES OK");
    }
    else
    {
/* at least one failed or was not tested */
        Serial.println("  SOME TESTS FAILED (details above)");
    }
    Serial.println("Enter = run again, help = commands");
}

/* every test, then the summary */
static void run_all(void)
{
/* local variables */
    int32_t i32_index;

/* nothing tested yet */
    g_i32_r_sd = R_NONE;
    g_i32_r_spi = R_NONE;
/* the wires from the FPGA */
    for (i32_index = 0; i32_index < RET_WIRES; i32_index++)
    {
        g_ai32_r_ret[i32_index] = R_NONE;
    }
/* the wires to the FPGA */
    for (i32_index = 0; i32_index < FWD_WIRES; i32_index++)
    {
        g_ai32_r_fwd[i32_index] = R_NONE;
        g_ai32_r_fast[i32_index] = R_NONE;
    }
/* the tests in their order */
    test_sd();
    test_back();
    test_fwd();
/* bursts, then the results */
    test_fast();
    summary();
}

/* "watch": what the FPGA sees, once a second, until something is typed */
static void watch(void)
{
/* local variables */
    Frame s_frame;
    const char *pc_via;

/* start values */
    pc_via = "?";
    Serial.println("FPGA inputs once a second (E1 H2 H1 N1 P2 P1, then edge counters); any input stops");
/* until something is typed */
    while (!Serial.available())
    {
        if (fpga_frame(s_frame))
        {
/* the output the frame came over */
            pc_via = "?";
            if ((s_frame.ui8_id >= ID_FIRST) && (s_frame.ui8_id <= ID_LAST))
            {
                pc_via = g_as_ret[s_frame.ui8_id - ID_FIRST].pc_fpga;
            }
/* levels and counters */
            Serial.printf("  via FPGA %s: levels ", pc_via);
            print_bits6(s_frame.ui8_lvl);
            Serial.printf("  counts %3d %3d %3d %3d %3d %3d\n", s_frame.aui8_cnt[IN_E1], s_frame.aui8_cnt[IN_H2],
                          s_frame.aui8_cnt[IN_H1], s_frame.aui8_cnt[IN_N1], s_frame.aui8_cnt[IN_P2], s_frame.aui8_cnt[0]);
        }
        else
        {
/* nothing came */
            Serial.println("  no frame from the FPGA");
        }
        delay(WATCH_MS);
    }
/* what was typed is thrown away */
    while (Serial.available())
    {
        Serial.read();
    }
}

/* "raw": raw levels of all 10 pins (all inputs), for debugging */
static void raw(void)
{
/* local variables */
    const Wire *ps_wire;
    LineStat s_stat;
/* counters */
    int32_t i32_wire;
    int32_t i32_index;

/* start values */
    ps_wire = nullptr;
    i32_wire = 0;
    i32_index = 0;
/* 20 ms of samples with every pin an input */
    outputs_off();
    delay(BACK_SETTLE_MS);
    capture(BACK_CAPTURE_US);
/* how many, how long */
    Serial.printf("raw capture: %d samples in %lu us (one every %d us); first 120 shown\n", (int)g_i32_nsmp,
                  (unsigned long)(g_ui32_cap_cycles / getCpuFrequencyMhz()), SAMPLE_US);
    for (i32_wire = 0; i32_wire < ALL_WIRES; i32_wire++)
    {
/* the return wires first */
        if (i32_wire < RET_WIRES)
        {
            ps_wire = &g_as_ret[i32_wire];
        }
        else
        {
            ps_wire = &g_as_fwd[i32_wire - RET_WIRES];
        }
/* its statistics, then its first samples */
        s_stat = decode(i32_wire);
        Serial.printf("  %-13s %s %-5s ones %5.1f%%  edges %5d  ", ps_wire->pc_esp, ps_wire->pc_fpga, ps_wire->pc_u7,
                      (PERCENT * s_stat.i32_ones) / g_i32_nsmp, (int)s_stat.i32_edges);
/* 120 samples */
        for (i32_index = 0; i32_index < RAW_SHOWN; i32_index++)
        {
            Serial.print(level(i32_index, i32_wire));
        }
        Serial.println();
    }
}

/* one byte to the card and one back, bit-banged */
static uint8_t sd_xfer(const int32_t ai32_pin[SD_PINS], uint8_t ui8_value)
{
/* local variables */
    uint8_t ui8_read;
    int32_t i32_bit;

/* start values */
    ui8_read = 0;
    for (i32_bit = DATA_BITS - ONE; i32_bit >= 0; i32_bit--)
    {
/* the data bit, then the clock's rising edge, where the card's bit is read */
        digitalWrite(ai32_pin[P_MOSI], (ui8_value >> i32_bit) & BIT_MASK);
        delayMicroseconds(SD_BIT_US);
        digitalWrite(ai32_pin[P_SCK], HIGH);
/* the card's bit */
        ui8_read = (uint8_t)((ui8_read << ONE) | digitalRead(ai32_pin[P_MISO]));
/* the clock low again */
        delayMicroseconds(SD_BIT_US);
        digitalWrite(ai32_pin[P_SCK], LOW);
    }
    return ui8_read;
}

/* SD wiring probe: bit-banged CMD0 (go idle, expect R1 = 01) on one assignment of the 4 SD pins: */
/* the card's answer, or SD_NO_RESP */
static int32_t sd_try(const int32_t ai32_pin[SD_PINS])
{
/* local variables */
    int32_t i32_index;
    int32_t i32_resp;
    uint8_t ui8_read;

/* start values */
    i32_index = 0;
    i32_resp = SD_NO_RESP;
    ui8_read = 0;
/* all four inputs, the card's output with a pull-up */
    for (i32_index = 0; i32_index < SD_PINS; i32_index++)
    {
        pinMode(ai32_pin[i32_index], INPUT);
    }
    pinMode(ai32_pin[P_MISO], INPUT_PULLUP);
/* chip select high, clock low, data high */
    digitalWrite(ai32_pin[P_CS], HIGH);
    pinMode(ai32_pin[P_CS], OUTPUT);
    digitalWrite(ai32_pin[P_SCK], LOW);
/* the clock and the data pin as outputs */
    pinMode(ai32_pin[P_SCK], OUTPUT);
    digitalWrite(ai32_pin[P_MOSI], HIGH);
    pinMode(ai32_pin[P_MOSI], OUTPUT);
/* >= 74 clocks with CS high */
    for (i32_index = 0; i32_index < SD_IDLE_BYTES; i32_index++)
    {
        sd_xfer(ai32_pin, SD_FILL);
    }
/* the command */
    digitalWrite(ai32_pin[P_CS], LOW);
    for (i32_index = 0; i32_index < CMD0_LEN; i32_index++)
    {
        sd_xfer(ai32_pin, g_aui8_cmd0[i32_index]);
    }
/* the answer is the first byte that is not FF */
    for (i32_index = 0; (i32_index < SD_RESP_TRIES) && (i32_resp < 0); i32_index++)
    {
        ui8_read = sd_xfer(ai32_pin, SD_FILL);
        if (ui8_read != SD_FILL)
        {
/* the answer */
            i32_resp = ui8_read;
        }
    }
/* the card is released, the pins are inputs again */
    digitalWrite(ai32_pin[P_CS], HIGH);
    sd_xfer(ai32_pin, SD_FILL);
/* all four pins released */
    for (i32_index = 0; i32_index < SD_PINS; i32_index++)
    {
        pinMode(ai32_pin[i32_index], INPUT);
    }
    return i32_resp;
}

/* "sdprobe": the SD reset command with every assignment of the four SD pins */
static void sd_probe(void)
{
/* local variables */
    int ai_order[SD_PINS] = {P_CS, P_SCK, P_MOSI, P_MISO};
    int32_t ai32_pin[SD_PINS];
    const char *pc_note;
/* assignments that answered, a counter, the answer */
    int32_t i32_found;
    int32_t i32_index;
    int32_t i32_resp;

/* start values */
    pc_note = "";
    i32_found = 0;
/* no answer yet */
    i32_index = 0;
    i32_resp = SD_NO_RESP;
/* the card is released from the SD library */
    SD.end();
    g_s_sdspi.end();
    g_b_sd_mounted = false;
/* every permutation of the four roles */
    Serial.println("SD probe: CMD0 at ~100 kHz with every assignment of GPIO5/18/23/19 (expect answer 01)");
    do
    {
/* the pins in this order of roles */
        for (i32_index = 0; i32_index < SD_PINS; i32_index++)
        {
            ai32_pin[i32_index] = g_ai32_sd_pin[ai_order[i32_index]];
        }
/* the reset command */
        i32_resp = sd_try(ai32_pin);
        if (i32_resp >= 0)
        {
/* an answer; is it the wiring it should be? */
            pc_note = "";
            if ((ai_order[P_CS] == P_CS) && (ai_order[P_SCK] == P_SCK) && (ai_order[P_MOSI] == P_MOSI))
            {
                pc_note = "  (the expected wiring)";
            }
/* the assignment and the answer */
            Serial.printf("  CS=GPIO%-2d SCK=GPIO%-2d MOSI=GPIO%-2d MISO=GPIO%-2d -> answer %02X%s\n", (int)ai32_pin[P_CS],
                          (int)ai32_pin[P_SCK], (int)ai32_pin[P_MOSI], (int)ai32_pin[P_MISO], (int)i32_resp, pc_note);
            i32_found++;
        }
    } while (std::next_permutation(ai_order, ai_order + SD_PINS));
/* nothing answered */
    if (i32_found == 0)
    {
        Serial.println("  no answer with any assignment: card power (3V3/GND), card seated, or a wire not connected");
    }
    Serial.println("  (run sd to mount the card again)");
}

/* "find": look for the FPGA's frames on every free ESP32 pin (finds where a wire really landed) */
static void find(void)
{
/* local variables */
    LineStat s_stat;
    int32_t i32_index;
/* the id seen most, pins with frames */
    int32_t i32_main;
    int32_t i32_hits;

/* start values */
    i32_index = 0;
    i32_main = NO_ID;
    i32_hits = 0;
/* the card's pins are looked at too */
    SD.end();
    g_s_sdspi.end();
    g_b_sd_mounted = false;
/* every pin an input */
    outputs_off();
    for (i32_index = 0; i32_index < CANDIDATES; i32_index++)
    {
/* a pull-down where the pin has one */
        if ((g_ai32_cand[i32_index] < INPUT_ONLY_FIRST) || (g_ai32_cand[i32_index] > INPUT_ONLY_LAST))
        {
            pinMode(g_ai32_cand[i32_index], INPUT_PULLDOWN);
        }
        else
        {
            pinMode(g_ai32_cand[i32_index], INPUT);
        }
/* its place in a sample */
        pack_pin(i32_index, g_ai32_cand[i32_index]);
    }
/* 20 ms of samples of all 16 */
    g_i32_npack = CANDIDATES;
    delay(BACK_SETTLE_MS);
    capture(BACK_CAPTURE_US);
/* pin by pin */
    Serial.println("FPGA frames on the free ESP32 pins (pull-down on, except GPIO34-39):");
    for (i32_index = 0; i32_index < CANDIDATES; i32_index++)
    {
/* the pin's statistics, and the FPGA output its frames name */
        s_stat = decode(i32_index);
        i32_main = main_id(s_stat);
        Serial.printf("  GPIO%-2d  ones %5.1f%%  edges %5d  ", (int)g_ai32_cand[i32_index],
                      (PERCENT * s_stat.i32_ones) / g_i32_nsmp, (int)s_stat.i32_edges);
/* frames */
        if (i32_main >= 0)
        {
            Serial.printf("frames from FPGA %s %s (%s)\n", g_as_ret[i32_main].pc_fpga, g_as_ret[i32_main].pc_u7,
                          g_as_ret[i32_main].pc_sig);
            i32_hits++;
        }
        else
        {
/* none */
            Serial.println("-");
        }
    }
/* nothing anywhere */
    if (i32_hits == 0)
    {
        Serial.println("  none");
    }
/* the 10 wires again; the pull-downs off */
    pack_init();
    for (i32_index = RET_WIRES; i32_index < CANDIDATES; i32_index++)
    {
        pinMode(g_ai32_cand[i32_index], INPUT);
    }
/* the card has to be mounted again */
    Serial.println("  (SD released: run sd to mount it again)");
}

/* the commands */
static void help(void)
{
    Serial.println("commands: (Enter)/all | sd | ls <path> | back | fwd | fast | set <hex> | watch | raw | find | sdprobe | help");
}

/* "set": the six outputs driven with a value and left so, for a meter */
static void cmd_set(String s_arg)
{
/* local variables */
    uint8_t ui8_value;

/* start values */
    ui8_value = 0;
    test_back();
/* only when no FPGA output sits on an ESP32 output pin */
    if (g_b_fwd_safe)
    {
        ui8_value = (uint8_t)(strtoul(s_arg.c_str(), 0, HEX) & ALL_ONES6);
/* driven, and said */
        outputs_on(ui8_value);
        Serial.printf("outputs driven: ");
/* the value in bits */
        print_bits6(ui8_value);
        Serial.println(" (GPIO17 25 26 33 13 14); 'back' releases them");
    }
}

/* one command line: the command, and the rest of the line as its argument */
static void command(String s_cmd, String s_arg)
{
/* local variables */
    const char *pc_path;

/* start values */
    pc_path = "/";
/* the commands */
    if ((s_cmd == "") || (s_cmd == "all"))
    {
        run_all();
    }
    else if (s_cmd == "sd")
    {
/* the card */
        test_sd();
    }
    else if (s_cmd == "ls")
    {
        if (g_b_sd_mounted)
        {
/* a folder, the root without a path */
            if (s_arg.length() != 0)
            {
                pc_path = s_arg.c_str();
            }
            list_dir(pc_path);
        }
        else
        {
/* the card is not mounted */
            Serial.println("no SD card (run sd)");
        }
    }
    else if (s_cmd == "back")
    {
/* the wires from the FPGA */
        test_back();
    }
    else if (s_cmd == "fwd")
    {
/* the safety check first */
        test_back();
        test_fwd();
    }
    else if (s_cmd == "fast")
    {
/* the bursts, after the safety check */
        test_back();
        test_fast();
    }
/* outputs for a meter */
    else if (s_cmd == "set")
    {
        cmd_set(s_arg);
    }
    else if (s_cmd == "watch")
    {
/* the FPGA's view, once a second */
        watch();
    }
/* raw samples */
    else if (s_cmd == "raw")
    {
        raw();
    }
    else if (s_cmd == "find")
    {
/* where did a wire land? */
        find();
    }
/* the SD pins */
    else if (s_cmd == "sdprobe")
    {
        sd_probe();
    }
    else if (s_cmd == "help")
    {
/* the list */
        help();
    }
    else
    {
        Serial.println("unknown command; help");
    }
}

void setup()
{
/* every pin an input; the USB serial port */
    pack_init();
    outputs_off();
    Serial.begin(UART_BAUD);
/* the whole test at reset */
    delay(START_DELAY_MS);
    Serial.println("\nTest_wires: ESP32 <-> FPGA wiring test (load Test_wires.sof into the FPGA first)");
    run_all();
}

/* commands from USB */
void loop()
{
/* local variables */
    String s_line;
    String s_cmd;
/* its argument, where the first space is */
    String s_arg;
    int32_t i32_space;

/* a line from USB; an empty one runs everything */
    if (Serial.available())
    {
        s_line = Serial.readStringUntil('\n');
        s_line.trim();
/* split at the first space */
        i32_space = s_line.indexOf(' ');
/* the command is the first word, the argument the rest */
        s_cmd = s_line;
        s_arg = "";
/* two words */
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
