/* esp_hw.cpp -- the platform under the SD tape loader firmware: SPI link to the FPGA */
/* (rtl/esp_link.v), register proxies (hw.h), pulse FIFO */
/* bursts (hal.h), OSD text (osd.h), SD card sectors (hal.h / sd.h) and the loader task. */
/* Link: HSPI, mode 0, 8 MHz. SCK GPIO14 -> FPGA AB13, MOSI GPIO13 -> AA13, CS GPIO33 -> AB14, */
/* MISO GPIO35 <- AA14, IRQ GPIO34 <- AB15 (not used). SD card: VSPI, SCK 18, MISO 19, MOSI 23, CS 5. */
/* Writes that come in streams are collected and sent as one link frame before any other register */
/* access: pulse FIFO commands, OSD text, Spectrum memory writes. Spectrum memory reads (snapshot */
/* saving) are fetched 256 bytes at a time. Everything else is one link frame per access. */
#include <Arduino.h>
#include <SPI.h>
#include <SD.h>
/* the SD card driver */
#include <sd_diskio.h>
#include <diskio.h>
/* pins, heap, firmware update */
#include <driver/gpio.h>
#include <esp_heap_caps.h>
#include <Update.h>
/* the loader's own headers */
#include "hw.h"
#include "hal.h"
#include "osd.h"
/* the card, the loader's start, the firmware update */
#include "sd.h"
#include "loader.h"
#include "espupd.h"
/* flash stream, restart, the cut-off jump */
#include "flash.h"
#include "reset.h"
#include <setjmp.h>

/* the link's pins and speed */
#define L_SCK 14
#define L_MOSI 13
#define L_CS 33
/* inputs */
#define L_MISO 35
#define L_IRQ 34
/* no chip select by the SPI driver; 8 MHz */
#define L_NO_PIN (-1)
#define LINK_HZ 8000000u
/* the SD card's pins and the speeds tried */
#define SD_SCK 18
#define SD_MISO 19
#define SD_MOSI 23
/* chip select; two speeds */
#define SD_CS 5
#define SD_SPEEDS 2
/* 20 MHz, then 4 MHz */
#define SD_HZ_FAST 20000000u
#define SD_HZ_SLOW 4000000u
#define SD_NO_DRIVE 0xFF
/* for the report */
#define HZ_PER_MHZ 1000000u
#define SHIFT_MB 20
/* core IDs: LSpectrum ("ZX"), link version 1; L64 ("C6"), link version 2: C64 ROMs at flash */
/* 0x580000; LTari ("AT"), link version 1; the machine menu ("MN"): flash update, link version 1; */
/* the same, link version 2: + flash stream frames (FLS) */
#define ID_ZX 0x5A580001u
#define ID_C64 0x43360002u
#define ID_AT 0x41540001u
/* the machine menu, without and with the flash stream */
#define ID_MN 0x4D4E0001u
#define ID_MN2 0x4D4E0002u
/* a core ID read with this many wrong bits at most is a link error, not another device */
#define ID_NEAR_BITS 6
/* the IRQ mask register: the bit set at start, and the bits that read back while the FPGA was not reset */
#define IRQ_MARK 0x100u
#define IRQ_MASK_BITS 0xF00u
/* 18-bit Spectrum memory address space */
#define SPEC_MEM 0x40000u
/* link frames: buffer size, and the lengths of the fixed frames */
#define FRAME_BUF 1100
#define FRAME_WR_LEN 6
#define FRAME_RD_LEN 7
/* STAT, and the zeros that clock an answer out */
#define FRAME_STAT_LEN 6
#define FRAME_STAT_ZEROS 5
#define FRAME_RD_ZEROS 5
/* places in the frames */
#define F_CMD 0
#define F_REG 1
#define F_WR_DATA 2
/* a read's data, the OSD frame */
#define F_RD_DATA 3
#define F_OSD_ADDR 1
#define F_OSD_TEXT 3
/* pulse commands, memory writes */
#define F_FIFO_DATA 1
#define F_MWR_ADDR 1
#define F_MWR_DATA 4
/* memory reads */
#define F_MRD_ADDR 1
#define F_MRD_DUMMY 4
#define F_MRD_DATA 5
/* the link's status */
#define F_STAT_FLAGS 2
#define STAT_STREAM_ERROR 0x80
/* bytes and shifts */
#define BYTE_1 1
#define BYTE_2 2
#define BYTE_3 3
/* their shifts */
#define SHIFT_BYTE 8
#define SHIFT_WORD 16
#define SHIFT_3_BYTES 24
/* bytes of a word */
#define WORD_BYTES 4
/* collected writes: pulse commands, memory writes, the memory read cache */
#define FIFO_BUF_LEN 200
#define MWR_BUF_LEN 1024
/* the read cache, the OSD's cells */
#define MRD_BUF_LEN 256
#define OSD_CELLS (OSD_COLS * OSD_ROWS)
/* the flash stream: command byte, header, data, two bytes for the answer's delay */
#define FLS_HDR_MAX 4u
#define FLS_RX_DELAY 2u
#define FLS_BUF (1 + 4 + FL_STREAM_MAX + 2)
/* snapshot commands, and the command's place in the register */
#define SNAP_CMD_SHIFT 28
#define SNAP_WAIT_MS 100u
/* OSD characters: printable ASCII, inverse video in bit 7 */
#define CHAR_FIRST 0x20
#define CHAR_LAST 0x7F
#define CHAR_INVERSE 0x80
/* times in milliseconds */
#define YIELD_MS 20u
#define CHECK_MS 500u
#define RESTART_DELAY_MS 50
/* waiting for the FPGA at the start, then probing */
#define BEGIN_WAIT_MS 3000u
#define BEGIN_STEP_MS 100
#define PROBE_MS 2000u
/* a loader that stopped talking: noticed, reported, restarted */
#define STALL_MS 3000u
#define STALL_REPORT_MS 5000u
#define STALL_RESTART_MS 15000u
/* microseconds: chip select to the first clock, and the last memory write after its frame */
#define CS_DELAY_US 1
#define MWR_DELAY_US 2
/* the FPGA's clock ticks per microsecond */
#define CLK_PER_US 56
/* the loader task: stack, priority, core */
#define TASK_STACK 16384
#define TASK_PRIORITY 1
/* the core, one tick */
#define TASK_CORE 1
#define ONE_TICK 1
/* the loader's stack report: RAM and code address ranges of the ESP32, words looked at, addresses shown */
#define RAM_FIRST 0x3FFB0000u
#define RAM_END 0x40000000u
#define CODE_FLASH_FIRST 0x400D0000u
/* code in RAM */
#define CODE_FLASH_END 0x40400000u
#define CODE_RAM_FIRST 0x40080000u
#define CODE_RAM_END 0x400A0000u
/* a windowed call's return address */
#define CALL_ADDR_MASK 0x3FFFFFFFu
#define CALL_ADDR_BASE 0x40000000u
#define CALL_WINDOW_SHIFT 30
/* the saved frame */
#define STACK_PC_WORD 1
#define STACK_FIRST_WORD 2
#define STACK_WORDS 1024
/* addresses shown, task states */
#define STACK_SHOWN 24
#define TASK_STATES 6
#define TASK_STATE_INVALID 5
/* flags as numbers */
#define YES 1
#define LEFT 1
#define ERROR_RESULT (-1)

/* link commands */
enum
{
    CMD_WR = 1,
    CMD_RD = 2,
    CMD_OSD = 3,
    CMD_FIFO = 4,
    CMD_MWR = 5,
    CMD_MRD = 6,
    CMD_STAT = 7,
    CMD_FLS = 8
};

/* registers handled here */
enum
{
    R_ID = 0x00,
    R_IRQ = 0x04,
    R_FIFO = 0x0C,
    R_TIMER = 0x18,
    R_SNAPCTL = 0x2C,
    R_SNAPCMD = 0x30,
    R_SNAPDAT = 0x34
};

/* snapshot port commands (snap.cpp) */
enum
{
    C_MRD = 1,
    C_MWR = 2
};

int loader_main(void);

/* SD card speeds, the fast one first */
static const uint32_t g_aui32_sd_hz[SD_SPEEDS] = { SD_HZ_FAST, SD_HZ_SLOW };
/* names of the task states */
static const char *const g_apc_task_state[TASK_STATES] = { "running", "ready", "blocked", "suspended", "deleted", "invalid" };
/* one link frame out and in */
static uint8_t g_aui8_ftx[FRAME_BUF];
static uint8_t g_aui8_frx[FRAME_BUF];
/* collected pulse commands */
static uint32_t g_aui32_fifo_buf[FIFO_BUF_LEN];
/* what the OSD shows */
static uint8_t g_aui8_osd[OSD_CELLS];
/* collected memory writes, and the memory read cache */
static uint8_t g_aui8_mwr_buf[MWR_BUF_LEN];
static uint8_t g_aui8_mrd_buf[MRD_BUF_LEN];
/* where the loader is left when the machine left */
static jmp_buf g_s_leave_jb;
/* the two SPI ports */
static SPIClass g_s_linkspi(HSPI);
static SPIClass g_s_sdspi(VSPI);
/* the machine found (probe); flash stream frames work (menu link version 2) */
static uint32_t g_ui32_core_id;
static bool g_b_fls_ok;
/* hw.h: 1 = L64, 1 = LTari, 1 = the machine menu (AMenu) */
int32_t g_i32_machine_c64;
int32_t g_i32_machine_atari;
int32_t g_i32_machine_menu;
/* the link's pins are set up */
static bool g_b_link_up;
/* a loader task runs (cleared by the task when it ends) */
static volatile bool g_b_running;
/* the loader task (stall report, loader_check) */
static TaskHandle_t g_s_loader_th;
/* millis() of the last link frame (stall check), and link frames sent */
static volatile uint32_t g_ui32_frame_ms;
static volatile uint32_t g_ui32_frames;
/* pulse commands collected */
static int32_t g_i32_fifo_n;
/* the OSD's dirty range [lo, hi) */
static int32_t g_i32_osd_lo = OSD_CELLS;
static int32_t g_i32_osd_hi;
/* collected memory writes: first address, count */
static uint32_t g_ui32_mwr_addr;
static int32_t g_i32_mwr_n;
/* the memory read cache: first address, count (0 = empty) */
static uint32_t g_ui32_mrd_addr;
static int32_t g_i32_mrd_n;
/* the snapshot port: data written, result of the last command */
static uint32_t g_ui32_snap_dat;
static uint32_t g_ui32_snap_res;
/* a command finished here: the next SNAPCTL read is not busy */
static bool g_b_snap_done;
/* when the other tasks got time last, and when the FPGA was checked last */
static uint32_t g_ui32_yield_ms;
static uint32_t g_ui32_check_ms;
/* the machine menu was left (its task only ends) */
static volatile bool g_b_menu_left;
/* the flash stream's buffers: on the heap, allocated on first use (only the menu mode streams; */
/* static RAM chops the Bluetooth audio) */
static uint8_t *g_pui8_fls_tx;
static uint8_t *g_pui8_fls_rx;
/* the SD card is ready; its drive number in the SD library's driver */
static bool g_b_sd_ok;
static uint8_t g_ui8_sd_pdrv = SD_NO_DRIVE;
/* when the link was probed last; when a stall was reported last */
static uint32_t g_ui32_probe_ms;
static uint32_t g_ui32_stall_report_ms;

/* link frames */

/* one frame of i32_len bytes: the frame buffers out and in */
static void frame(size_t s_len)
{
    g_s_linkspi.beginTransaction(SPISettings(LINK_HZ, MSBFIRST, SPI_MODE0));
    digitalWrite(L_CS, LOW);
/* >= 100 ns CS -> first SCK */
    delayMicroseconds(CS_DELAY_US);
    g_s_linkspi.transferBytes(g_aui8_ftx, g_aui8_frx, s_len);
    delayMicroseconds(CS_DELAY_US);
/* chip select off */
    digitalWrite(L_CS, HIGH);
    g_s_linkspi.endTransaction();
    delayMicroseconds(CS_DELAY_US);
/* for the stall check */
    g_ui32_frame_ms = millis();
    g_ui32_frames = g_ui32_frames + YES;
}

/* write a register */
static void link_wr(uint8_t ui8_reg, uint32_t ui32_value)
{
    g_aui8_ftx[F_CMD] = CMD_WR;
    g_aui8_ftx[F_REG] = ui8_reg;
/* the value, high byte first */
    g_aui8_ftx[F_WR_DATA] = ui32_value >> SHIFT_3_BYTES;
    g_aui8_ftx[F_WR_DATA + BYTE_1] = ui32_value >> SHIFT_WORD;
    g_aui8_ftx[F_WR_DATA + BYTE_2] = ui32_value >> SHIFT_BYTE;
/* the low byte, then the frame */
    g_aui8_ftx[F_WR_DATA + BYTE_3] = ui32_value;
    frame(FRAME_WR_LEN);
}

/* read a register */
static uint32_t link_rd(uint8_t ui8_reg)
{
/* local variables */
    uint32_t ui32_value;

/* start values */
    g_aui8_ftx[F_CMD] = CMD_RD;
    g_aui8_ftx[F_REG] = ui8_reg;
/* zeros clock the answer out */
    memset(g_aui8_ftx + F_WR_DATA, 0, FRAME_RD_ZEROS);
    frame(FRAME_RD_LEN);
/* the value, high byte first */
    ui32_value = ((uint32_t)g_aui8_frx[F_RD_DATA] << SHIFT_3_BYTES) | ((uint32_t)g_aui8_frx[F_RD_DATA + BYTE_1] << SHIFT_WORD) |
                 ((uint32_t)g_aui8_frx[F_RD_DATA + BYTE_2] << SHIFT_BYTE) | g_aui8_frx[F_RD_DATA + BYTE_3];
    return ui32_value;
}

/* collected writes */

/* the collected pulse commands as one frame */
static void flush_fifo(void)
{
/* local variables */
    int32_t i32_index;
    uint32_t ui32_cmd;

/* start values */
    ui32_cmd = 0;
    if (g_i32_fifo_n != 0)
    {
        g_aui8_ftx[F_CMD] = CMD_FIFO;
/* each command, high byte first */
        for (i32_index = 0; i32_index < g_i32_fifo_n; i32_index++)
        {
            ui32_cmd = g_aui32_fifo_buf[i32_index];
            g_aui8_ftx[F_FIFO_DATA + (WORD_BYTES * i32_index)] = ui32_cmd >> SHIFT_3_BYTES;
/* the lower bytes */
            g_aui8_ftx[F_FIFO_DATA + BYTE_1 + (WORD_BYTES * i32_index)] = ui32_cmd >> SHIFT_WORD;
            g_aui8_ftx[F_FIFO_DATA + BYTE_2 + (WORD_BYTES * i32_index)] = ui32_cmd >> SHIFT_BYTE;
            g_aui8_ftx[F_FIFO_DATA + BYTE_3 + (WORD_BYTES * i32_index)] = ui32_cmd;
        }
/* one frame for all of them */
        frame(F_FIFO_DATA + (WORD_BYTES * g_i32_fifo_n));
        g_i32_fifo_n = 0;
    }
}

/* the changed part of the OSD text as one frame */
static void flush_osd(void)
{
/* local variables */
    int32_t i32_count;

/* start values */
    i32_count = 0;
    if (g_i32_osd_lo < g_i32_osd_hi)
    {
        i32_count = g_i32_osd_hi - g_i32_osd_lo;
/* the first changed cell's address, then the text */
        g_aui8_ftx[F_CMD] = CMD_OSD;
        g_aui8_ftx[F_OSD_ADDR] = g_i32_osd_lo >> SHIFT_BYTE;
        g_aui8_ftx[F_OSD_ADDR + BYTE_1] = g_i32_osd_lo;
/* the cells from the first to the last changed */
        memcpy(g_aui8_ftx + F_OSD_TEXT, g_aui8_osd + g_i32_osd_lo, i32_count);
        frame(F_OSD_TEXT + i32_count);
/* nothing dirty */
        g_i32_osd_lo = OSD_CELLS;
        g_i32_osd_hi = 0;
    }
}

/* the collected memory writes as one frame */
static void flush_mwr(void)
{
    if (g_i32_mwr_n != 0)
    {
        g_aui8_ftx[F_CMD] = CMD_MWR;
/* the first address, then the bytes */
        g_aui8_ftx[F_MWR_ADDR] = g_ui32_mwr_addr >> SHIFT_WORD;
        g_aui8_ftx[F_MWR_ADDR + BYTE_1] = g_ui32_mwr_addr >> SHIFT_BYTE;
        g_aui8_ftx[F_MWR_ADDR + BYTE_2] = g_ui32_mwr_addr;
/* the collected bytes */
        memcpy(g_aui8_ftx + F_MWR_DATA, g_aui8_mwr_buf, g_i32_mwr_n);
        frame(F_MWR_DATA + g_i32_mwr_n);
/* the last byte's write finishes after the frame */
        delayMicroseconds(MWR_DELAY_US);
        g_i32_mwr_n = 0;
    }
}

/* everything collected, in the order pulses, OSD, memory */
static void flush_all(void)
{
    flush_fifo();
/* OSD text, then memory */
    flush_osd();
    flush_mwr();
}

/* register proxies (hw.h) */

/* the ESP32's clock as the FPGA's 56 MHz count */
static uint32_t timer56(void)
{
/* local variables */
    uint32_t ui32_ticks;

    ui32_ticks = (uint32_t)(esp_timer_get_time() * CLK_PER_US);
    return ui32_ticks;
}

/* machine menu: 0 once the FPGA was reconfigured into a machine */
int32_t menu_present(void)
{
/* local variables */
    int32_t i32_result;

/* start values */
    i32_result = YES;
    if (g_b_menu_left)
    {
/* the menu is gone */
        i32_result = 0;
    }
    return i32_result;
}

/* The loader polls registers in tight loops: let the other tasks on this core run now and then. */
/* Every 0.5 s it also checks that the FPGA was not reset (KEY0 resets the loader hardware: the */
/* IRQ mask set at start reads 0 again); the firmware's state would then not match, so restart. */
/* Leaving the machine menu is the exception: the menu's task only ends (menu_present() = 0) and */
/* the next probe starts the machine, so the ESP32 does not restart and a Bluetooth connection */
/* being set up at power-up is not cut (a restart there broke the A2DP audio on hardware). */
/* A machine left (another core on the link: the menu after KEY1 / Ctrl+Alt+Del, or a */
/* reconfiguration): the loader is left from wherever it polls the link back to loader_task, which */
/* puts every module back to its start state; the next probe starts the loader for the new core. */
/* No ESP32 restart, so the Bluetooth connection stays. KEY0 (the same core, its IRQ mask cleared) */
/* still restarts the ESP32: "everything". */
static void housekeeping(void)
{
/* local variables */
    uint32_t ui32_now;
    uint32_t ui32_id;
    uint32_t ui32_irq;

/* start values */
    ui32_now = millis();
    ui32_id = 0;
    ui32_irq = 0;
/* time for the other tasks */
    if ((ui32_now - g_ui32_yield_ms) >= YIELD_MS)
    {
        vTaskDelay(ONE_TICK);
        g_ui32_yield_ms = millis();
    }
/* is the same core still there, not reset? */
    if ((ui32_now - g_ui32_check_ms) >= CHECK_MS)
    {
        g_ui32_check_ms = ui32_now;
/* its ID and its IRQ mask */
        ui32_id = link_rd(R_ID);
        ui32_irq = link_rd(R_IRQ);
        if ((ui32_id != g_ui32_core_id) || ((ui32_irq & IRQ_MASK_BITS) == 0))
        {
/* the menu, or a machine */
            if (g_i32_machine_menu != 0)
            {
/* the menu was left: its task ends by itself */
                g_b_menu_left = true;
            }
            else if (ui32_id != g_ui32_core_id)
            {
/* another core: back to loader_task */
                Serial.printf("\r\nloader: the machine left (id %08lx): loader starts again, no restart\r\n",
                              (unsigned long)ui32_id);
                longjmp(g_s_leave_jb, LEFT);
            }
            else
            {
/* the same core, reset: everything starts again */
                Serial.printf("\r\nloader: FPGA reset or reconfigured (id %08lx, irq %08lx): restarting the ESP32\r\n",
                              (unsigned long)ui32_id, (unsigned long)ui32_irq);
                delay(RESTART_DELAY_MS);
                esp_restart();
            }
        }
    }
}

/* bytes in the PSRAM (WROVER module), 0 if there is none */
void *ext_alloc(uint32_t ui32_size)
{
/* local variables */
    void *p_mem;

    p_mem = heap_caps_malloc(ui32_size, MALLOC_CAP_SPIRAM);
    return p_mem;
}

/* one line to the ESP32's USB serial port (diagnostics) */
void log_line(const char *pc_text)
{
    Serial.printf("loader: %s\r\n", pc_text);
}

/* a STAT frame: reads (and clears) the link's error flags into the receive buffer */
static void stat_frame(void)
{
    g_aui8_ftx[F_CMD] = CMD_STAT;
/* zeros clock the flags out */
    memset(g_aui8_ftx + F_REG, 0, FRAME_STAT_ZEROS);
    frame(FRAME_STAT_LEN);
}

/* flash stream (flash.h): one FLS frame, then STAT for its error flag */
int32_t fl_stream(const uint8_t *pui8_hdr, uint32_t ui32_hdr_len, const uint8_t *pui8_data, uint8_t *pui8_rx,
                  uint32_t ui32_count)
{
    size_t s_len;
    int32_t i32_result;

/* command, header, data, and two more bytes when the flash's answer is wanted */
    s_len = YES + ui32_hdr_len + ui32_count;
    if (pui8_rx != NULL)
    {
        s_len += FLS_RX_DELAY;
    }
/* no stream, or too much for one */
    i32_result = FL_OK;
    if (!g_b_fls_ok || (ui32_hdr_len > FLS_HDR_MAX) || (ui32_count > FL_STREAM_MAX))
    {
        i32_result = FL_ERROR;
    }
/* the buffers, at the first use; without them there is no stream */
    if ((i32_result == FL_OK) && (g_pui8_fls_tx == NULL))
    {
        g_pui8_fls_tx = (uint8_t *)malloc(FLS_BUF);
        g_pui8_fls_rx = (uint8_t *)malloc(FLS_BUF);
/* no memory */
        if ((g_pui8_fls_tx == NULL) || (g_pui8_fls_rx == NULL))
        {
            free(g_pui8_fls_tx);
            free(g_pui8_fls_rx);
/* no buffers, no stream */
            g_pui8_fls_tx = NULL;
            g_pui8_fls_rx = NULL;
            g_b_fls_ok = false;
/* the caller does it byte-wise */
            i32_result = FL_ERROR;
        }
    }
    if (i32_result == FL_OK)
    {
/* everything collected goes first */
        housekeeping();
        flush_all();
/* clear an older error first */
        stat_frame();
/* the stream: command, header, data (zeros when only reading) */
        g_pui8_fls_tx[F_CMD] = CMD_FLS;
        memcpy(g_pui8_fls_tx + YES, pui8_hdr, ui32_hdr_len);
/* data to write, or zeros */
        if (pui8_data != NULL)
        {
            memcpy(g_pui8_fls_tx + YES + ui32_hdr_len, pui8_data, ui32_count);
        }
        else
        {
            memset(g_pui8_fls_tx + YES + ui32_hdr_len, 0, ui32_count);
        }
/* two zeros clock the last two bytes of the answer out */
        if (pui8_rx != NULL)
        {
            g_pui8_fls_tx[s_len - BYTE_2] = 0;
            g_pui8_fls_tx[s_len - BYTE_1] = 0;
        }
/* one transaction for the whole stream */
        g_s_linkspi.beginTransaction(SPISettings(LINK_HZ, MSBFIRST, SPI_MODE0));
        digitalWrite(L_CS, LOW);
        delayMicroseconds(CS_DELAY_US);
/* out and in at once */
        g_s_linkspi.transferBytes(g_pui8_fls_tx, g_pui8_fls_rx, s_len);
        delayMicroseconds(CS_DELAY_US);
/* chip select off */
        digitalWrite(L_CS, HIGH);
        g_s_linkspi.endTransaction();
        delayMicroseconds(CS_DELAY_US);
/* a byte was late or dropped: no stream from now on */
        stat_frame();
        if ((g_aui8_frx[F_STAT_FLAGS] & STAT_STREAM_ERROR) != 0)
        {
            g_b_fls_ok = false;
/* said once */
            Serial.printf("loader: flash stream error, byte-wise from now on\r\n");
            i32_result = FL_ERROR;
        }
        else if (pui8_rx != NULL)
        {
/* the flash's byte for frame byte k comes in byte k + 2 */
            memcpy(pui8_rx, g_pui8_fls_rx + YES + ui32_hdr_len + FLS_RX_DELAY, ui32_count);
        }
        else
        {
/* a write: nothing to hand back */
        }
    }
    return i32_result;
}

/* 1 = that machine still answers on the link */
int32_t link_alive(void)
{
    int32_t i32_result;

    i32_result = 0;
/* the same core ID, and the IRQ mask still set */
    if (link_rd(R_ID) == g_ui32_core_id)
    {
        if ((link_rd(R_IRQ) & IRQ_MASK_BITS) != 0)
        {
/* alive */
            i32_result = YES;
        }
    }
    return i32_result;
}

/* a write to SNAPCMD: memory writes are collected, memory reads come from a cache of 256 bytes, */
/* everything else is done in the FPGA */
static void snap_command(uint32_t ui32_value)
{
/* local variables */
    uint32_t ui32_cmd;
    uint32_t ui32_addr;
/* a wait's start, a byte count */
    uint32_t ui32_start;
    int32_t i32_count;

/* start values */
    ui32_cmd = ui32_value >> SNAP_CMD_SHIFT;
    ui32_addr = ui32_value & (SPEC_MEM - YES);
    ui32_start = 0;
/* the command counts as done */
    i32_count = 0;
    g_b_snap_done = true;
    if (ui32_cmd == C_MWR)
    {
/* the read cache is no longer valid */
        g_i32_mrd_n = 0;
/* a write that does not follow the collected ones, or a full buffer: send those first */
        if ((g_i32_mwr_n != 0) &&
            ((ui32_addr != (g_ui32_mwr_addr + (uint32_t)g_i32_mwr_n)) || (g_i32_mwr_n == MWR_BUF_LEN)))
        {
            flush_mwr();
        }
/* the first of a new run */
        if (g_i32_mwr_n == 0)
        {
            g_ui32_mwr_addr = ui32_addr;
        }
/* one more byte collected */
        g_aui8_mwr_buf[g_i32_mwr_n] = (uint8_t)g_ui32_snap_dat;
        g_i32_mwr_n++;
        g_ui32_snap_res = 0;
    }
/* a memory read */
    else if (ui32_cmd == C_MRD)
    {
        flush_all();
/* an address outside the cache: fetch 256 bytes from there (fewer at the end of the memory) */
        if ((g_i32_mrd_n == 0) || (ui32_addr < g_ui32_mrd_addr) || (ui32_addr >= (g_ui32_mrd_addr + (uint32_t)g_i32_mrd_n)))
        {
            i32_count = MRD_BUF_LEN;
/* fewer at the end of the memory */
            if ((SPEC_MEM - ui32_addr) < MRD_BUF_LEN)
            {
                i32_count = (int32_t)(SPEC_MEM - ui32_addr);
            }
/* the frame: command and address */
            g_aui8_ftx[F_CMD] = CMD_MRD;
            g_aui8_ftx[F_MRD_ADDR] = ui32_addr >> SHIFT_WORD;
            g_aui8_ftx[F_MRD_ADDR + BYTE_1] = ui32_addr >> SHIFT_BYTE;
/* its low byte, a dummy byte */
            g_aui8_ftx[F_MRD_ADDR + BYTE_2] = ui32_addr;
            g_aui8_ftx[F_MRD_DUMMY] = 0;
/* zeros clock the data out */
            memset(g_aui8_ftx + F_MRD_DATA, 0, i32_count);
            frame(F_MRD_DATA + i32_count);
/* into the cache */
            memcpy(g_aui8_mrd_buf, g_aui8_frx + F_MRD_DATA, i32_count);
            g_ui32_mrd_addr = ui32_addr;
            g_i32_mrd_n = i32_count;
        }
/* the byte asked for */
        g_ui32_snap_res = g_aui8_mrd_buf[ui32_addr - g_ui32_mrd_addr];
    }
    else
    {
/* registers, LOAD, AY, ports: done in the FPGA */
        flush_all();
        g_i32_mrd_n = 0;
/* the data, then the command */
        link_wr(R_SNAPDAT, g_ui32_snap_dat);
        link_wr(R_SNAPCMD, ui32_value);
        ui32_start = millis();
/* wait until the FPGA has done it */
        while (((link_rd(R_SNAPCTL) & SNAP_BUSY) != 0) && ((millis() - ui32_start) < SNAP_WAIT_MS))
        {
        }
        g_ui32_snap_res = link_rd(R_SNAPDAT);
    }
}

/* read a register */
uint32_t hw_rd(uint8_t ui8_reg)
{
    uint32_t ui32_value;

    if (ui8_reg == R_TIMER)
    {
/* local */
        ui32_value = timer56();
    }
    else if ((ui8_reg == R_SNAPCTL) && g_b_snap_done)
    {
/* the command finished here: frozen and not busy */
        g_b_snap_done = false;
        ui32_value = SNAP_FROZEN;
    }
/* the result of the last command */
    else if (ui8_reg == R_SNAPDAT)
    {
        ui32_value = g_ui32_snap_res;
    }
    else
    {
/* over the link, after everything collected */
        housekeeping();
        flush_all();
/* the register */
        ui32_value = link_rd(ui8_reg);
    }
    return ui32_value;
}

/* write a register */
void hw_wr(uint8_t ui8_reg, uint32_t ui32_value)
{
    if (ui8_reg == R_SNAPDAT)
    {
        g_ui32_snap_dat = ui32_value;
    }
/* a snapshot command */
    else if (ui8_reg == R_SNAPCMD)
    {
        snap_command(ui32_value);
    }
    else
    {
        flush_all();
/* the Spectrum runs again / stops: memory may change */
        if (ui8_reg == R_SNAPCTL)
        {
            g_i32_mrd_n = 0;
        }
        link_wr(ui8_reg, ui32_value);
    }
}

/* hal.h / osd.h / sd.h */

/* one command into the pulse FIFO (collected) */
void fifo_push(uint32_t ui32_cmd)
{
    if (g_i32_fifo_n == FIFO_BUF_LEN)
    {
        flush_fifo();
    }
/* into the buffer */
    g_aui32_fifo_buf[g_i32_fifo_n] = ui32_cmd;
    g_i32_fifo_n++;
}

/* all rows empty */
void osd_clear(void)
{
/* local variables */
    int32_t i32_row;

    for (i32_row = 0; i32_row < OSD_ROWS; i32_row++)
    {
        osd_text(i32_row, 0, "", OSD_COLS, 0);
    }
}

/* text at (row, column), padded with spaces to a width; inverse video if i32_inverse */
void osd_text(int32_t i32_row, int32_t i32_col, const char *pc_text, int32_t i32_width, int32_t i32_inverse)
{
/* local variables */
    uint8_t ui8_mask;
    uint8_t ui8_char;
/* the first cell, a counter */
    int32_t i32_cell;
    int32_t i32_index;

/* start values */
    ui8_mask = 0;
    ui8_char = 0;
    i32_cell = (i32_row * OSD_COLS) + i32_col;
/* inverse text has the top bit set */
    i32_index = 0;
    if (i32_inverse != 0)
    {
        ui8_mask = CHAR_INVERSE;
    }
/* only inside the screen */
    if ((i32_row >= 0) && (i32_row < OSD_ROWS) && (i32_col >= 0) && (i32_col < OSD_COLS))
    {
        while ((i32_index < i32_width) && ((i32_col + i32_index) < OSD_COLS))
        {
/* the text's next character, or a space behind its end */
            ui8_char = ' ';
            if (*pc_text != 0)
            {
                ui8_char = (uint8_t)*pc_text;
/* next character */
                pc_text++;
            }
/* only printable ASCII has a shape in the font */
            if ((ui8_char < CHAR_FIRST) || (ui8_char > CHAR_LAST))
            {
                ui8_char = '?';
            }
            ui8_char |= ui8_mask;
/* a changed cell widens the dirty range */
            if (g_aui8_osd[i32_cell + i32_index] != ui8_char)
            {
                g_aui8_osd[i32_cell + i32_index] = ui8_char;
/* the lowest changed cell */
                if ((i32_cell + i32_index) < g_i32_osd_lo)
                {
                    g_i32_osd_lo = i32_cell + i32_index;
                }
/* the end of the changed cells */
                if ((i32_cell + i32_index + YES) > g_i32_osd_hi)
                {
                    g_i32_osd_hi = i32_cell + i32_index + YES;
                }
            }
            i32_index++;
        }
    }
}

/* full screen (keyboard goes to the OSD) or bottom row only */
void osd_show(int32_t i32_full)
{
    if (i32_full != 0)
    {
        OSDC = OSD_ON | OSD_FULL;
    }
    else
    {
/* the bottom row */
        OSDC = OSD_ON;
    }
}

/* the overlay off */
void osd_hide(void)
{
    OSDC = 0;
}

/* The card is used by raw sectors only (src/fat.cpp is the file system), so it is started with the SD */
/* library's driver calls and never mounted: SD.begin() also registers a FAT volume, which takes about */
/* 25 KB of internal heap (a 4096-byte sector buffer for the volume and for each of 5 files). That */
/* memory is what the Bluetooth audio needs (see `status`, heap). */
static void sd_stop(void)
{
    if (g_ui8_sd_pdrv != SD_NO_DRIVE)
    {
        sdcard_uninit(g_ui8_sd_pdrv);
    }
/* no drive */
    g_ui8_sd_pdrv = SD_NO_DRIVE;
}

/* start the card: SD_OK = card ready */
int32_t sd_init(void)
{
/* local variables */
    int32_t i32_speed;
    uint32_t ui32_hz;
    int32_t i32_result;

/* start values */
    i32_speed = 0;
    ui32_hz = 0;
    i32_result = SD_ERROR;
/* a card that was in use is closed */
    sd_stop();
    g_b_sd_ok = false;
/* the fast speed first, then the slow one */
    while ((i32_speed < SD_SPEEDS) && (i32_result != SD_OK))
    {
        ui32_hz = g_aui32_sd_hz[i32_speed];
        g_s_sdspi.end();
/* the SPI bus, with a pull-up on the card's output */
        g_s_sdspi.begin(SD_SCK, SD_MISO, SD_MOSI, SD_CS);
        gpio_pullup_en((gpio_num_t)SD_MISO);
/* the driver, then the card's own start */
        g_ui8_sd_pdrv = sdcard_init(SD_CS, &g_s_sdspi, ui32_hz);
        if ((g_ui8_sd_pdrv != SD_NO_DRIVE) && ((disk_initialize(g_ui8_sd_pdrv) & STA_NOINIT) == 0))
        {
            g_b_sd_ok = true;
/* found: its size and speed */
            Serial.printf("loader: SD card %llu MB at %lu MHz\r\n",
                          ((uint64_t)sdcard_num_sectors(g_ui8_sd_pdrv) * sdcard_sector_size(g_ui8_sd_pdrv)) >> SHIFT_MB,
                          (unsigned long)(ui32_hz / HZ_PER_MHZ));
            i32_result = SD_OK;
        }
        else
        {
/* not at this speed */
            sd_stop();
        }
        i32_speed++;
    }
    if (i32_result != SD_OK)
    {
/* no card */
        Serial.print("loader: no SD card\r\n");
    }
    return i32_result;
}

/* 1 = the card is ready */
int32_t sd_ready(void)
{
/* local variables */
    int32_t i32_result;

/* start values */
    i32_result = 0;
    if (g_b_sd_ok)
    {
/* a card is there */
        i32_result = YES;
    }
    return i32_result;
}

/* read one 512-byte sector: 0 = ok; a failed read means the card is gone */
int32_t sd_read(uint32_t ui32_lba, uint8_t *pui8_buf)
{
/* local variables */
    int32_t i32_result;

/* start values */
    i32_result = ERROR_RESULT;
    if (g_b_sd_ok)
    {
        if (sd_read_raw(g_ui8_sd_pdrv, pui8_buf, ui32_lba))
        {
/* the sector was read; a failure means the card is gone */
            i32_result = 0;
        }
        else
        {
            g_b_sd_ok = false;
        }
    }
    return i32_result;
}

/* write one 512-byte sector: 0 = ok; a failed write means the card is gone */
int32_t sd_write(uint32_t ui32_lba, const uint8_t *pui8_buf)
{
/* local variables */
    int32_t i32_result;

/* start values */
    i32_result = ERROR_RESULT;
    if (g_b_sd_ok)
    {
        if (sd_write_raw(g_ui8_sd_pdrv, const_cast<uint8_t *>(pui8_buf), ui32_lba))
        {
/* the sector was written; a failure means the card is gone */
            i32_result = 0;
        }
        else
        {
            g_b_sd_ok = false;
        }
    }
    return i32_result;
}

/* loader.h */

/* the link-side state back to the start (frames collected for the old core are dropped) */
static void link_reset(void)
{
    g_i32_fifo_n = 0;
    memset(g_aui8_osd, 0, sizeof g_aui8_osd);
/* nothing dirty, nothing collected */
    g_i32_osd_lo = OSD_CELLS;
    g_i32_osd_hi = 0;
/* no memory writes collected */
    g_i32_mwr_n = 0;
    g_ui32_mwr_addr = 0;
/* the read cache and the snapshot port */
    g_i32_mrd_n = 0;
    g_ui32_mrd_addr = 0;
/* the snapshot port's data, result, state */
    g_ui32_snap_dat = 0;
    g_ui32_snap_res = 0;
    g_b_snap_done = false;
}

/* the loader's task: runs the loader until the machine leaves */
static void loader_task(void *p_arg)
{
    (void)p_arg;
/* the clocks of the housekeeping */
    g_ui32_yield_ms = millis();
    g_ui32_check_ms = g_ui32_yield_ms;
/* housekeeping comes back here when the machine left */
    if (setjmp(g_s_leave_jb) == 0)
    {
/* returns only when the machine menu is left */
        loader_main();
        Serial.print("loader: the menu is gone, waiting for the machine\r\n");
    }
/* the machine is gone: everything starts fresh */
    link_reset();
    loader_reset_all();
    g_ui32_probe_ms = millis();
/* the task ends */
    g_s_loader_th = nullptr;
/* loader_poll probes for the machine */
    g_b_running = false;
    vTaskDelete(nullptr);
}

/* A core ID with a few wrong bits or shifted by one bit: link bit errors, not the menu (whose */
/* unused MISO pin floats and reads as noise) or no FPGA (0 / FFFFFFFF) */
static bool near_id(uint32_t ui32_id, uint32_t ui32_want)
{
/* local variables */
    bool b_near;

    b_near = (__builtin_popcount(ui32_id ^ ui32_want) <= ID_NEAR_BITS) || (ui32_id == (ui32_want << YES)) ||
             (ui32_id == (ui32_want >> YES));
    return b_near;
}

/* is a known core on the link? Sets the machine flags and the reset check's mark */
static bool probe(void)
{
/* local variables */
    uint32_t ui32_id;
    bool b_found;

/* start values */
    ui32_id = link_rd(R_ID);
    b_found = false;
    if ((ui32_id != ID_ZX) && (ui32_id != ID_C64) && (ui32_id != ID_AT) && (ui32_id != ID_MN) && (ui32_id != ID_MN2))
    {
/* nearly an ID: say so, it is a wiring or timing problem */
        if (near_id(ui32_id, ID_ZX) || near_id(ui32_id, ID_C64) || near_id(ui32_id, ID_AT) || near_id(ui32_id, ID_MN) ||
            near_id(ui32_id, ID_MN2))
        {
            Serial.printf("loader: core id %08lx read with bit errors (link timing?)\r\n", (unsigned long)ui32_id);
        }
    }
    else
    {
/* a machine: its ID is kept */
        g_ui32_core_id = ui32_id;
        g_b_menu_left = false;
/* which machine */
        g_i32_machine_c64 = 0;
        g_i32_machine_atari = 0;
        g_i32_machine_menu = 0;
/* the C64 */
        if (ui32_id == ID_C64)
        {
            g_i32_machine_c64 = YES;
        }
/* the Atari */
        if (ui32_id == ID_AT)
        {
            g_i32_machine_atari = YES;
        }
/* the machine menu, either version */
        if ((ui32_id == ID_MN) || (ui32_id == ID_MN2))
        {
            g_i32_machine_menu = YES;
        }
/* the flash stream only in version 2 */
        g_b_fls_ok = ui32_id == ID_MN2;
/* mask bit for the FPGA reset check (housekeeping) */
        link_wr(R_IRQ, IRQ_MARK);
        b_found = (link_rd(R_IRQ) & IRQ_MASK_BITS) != 0;
    }
    return b_found;
}

/* the name of the machine on the link */
static const char *machine_name(void)
{
/* local variables */
    const char *pc_name;

/* start values */
    pc_name = "LSpectrum";
    if (g_i32_machine_menu != 0)
    {
        pc_name = "the menu";
    }
/* the C64 */
    else if (g_i32_machine_c64 != 0)
    {
        pc_name = "L64";
    }
/* the Atari */
    else if (g_i32_machine_atari != 0)
    {
        pc_name = "LTari";
    }
    else
    {
/* the Spectrum */
    }
    return pc_name;
}

/* start the loader's task if a machine answers and none runs */
static void start_if_found(void)
{
/* local variables */
    const char *pc_what;

/* start values */
    pc_what = "SD loader running (F12)";
    if (!g_b_running)
    {
        if (probe())
        {
/* a machine answered */
            g_b_running = true;
            if (g_i32_machine_menu != 0)
            {
                pc_what = "flash update ready (LUPDATE.BIN)";
            }
/* said on the console, then the loader's task starts */
            Serial.printf("loader: %s found, %s, free heap %u bytes, largest block %u\r\n", machine_name(), pc_what,
                          (unsigned)ESP.getFreeHeap(), (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_8BIT));
            g_ui32_frame_ms = millis();
            xTaskCreatePinnedToCore(loader_task, "loader", TASK_STACK, nullptr, TASK_PRIORITY, &g_s_loader_th, TASK_CORE);
        }
    }
}

/* setup(): link + SD pins; starts the loader if the FPGA answers */
void loader_begin(void)
{
/* local variables */
    uint32_t ui32_start;

/* the link's pins */
    pinMode(L_CS, OUTPUT);
    digitalWrite(L_CS, HIGH);
    pinMode(L_IRQ, INPUT);
/* its SPI bus */
    g_s_linkspi.begin(L_SCK, L_MISO, L_MOSI, L_NO_PIN);
    g_b_link_up = true;
    ui32_start = millis();
/* the FPGA may still be configuring / loading ROMs */
    while (!g_b_running && ((millis() - ui32_start) < BEGIN_WAIT_MS))
    {
        start_if_found();
        if (!g_b_running)
        {
/* try again shortly */
            delay(BEGIN_STEP_MS);
        }
    }
    if (!g_b_running)
    {
        Serial.print("loader: no machine on the link yet (menu shown, or FPGA not configured): retrying every 2 s\r\n");
    }
/* loader_poll goes on looking */
    g_ui32_probe_ms = millis();
}

/* loop(): keeps looking for the FPGA (configured later, reprogrammed) */
void loader_poll(void)
{
    if (g_b_link_up && !g_b_running && ((millis() - g_ui32_probe_ms) >= PROBE_MS))
    {
/* every 2 s */
        g_ui32_probe_ms = millis();
        start_if_found();
    }
}

/* a loader task runs */
bool loader_running(void)
{
/* local variables */
    bool b_running;

    b_running = g_b_running;
    return b_running;
}

/* The loader task's state and the code addresses on its stack (a rough call chain: decode with */
/* xtensa-esp32-elf-addr2line -e v2.ino.elf). The saved context starts at pxTopOfStack (the */
/* TCB's first word): exit, pc, ps, ... */
static void loader_report(Print &r_out)
{
/* local variables */
    TaskHandle_t s_task;
    eTaskState e_state;
    uint32_t *pui32_stack;
/* a word of it, a code address */
    uint32_t *pui32_word;
    uint32_t ui32_addr;
/* addresses shown, the word's index, the state's name */
    int32_t i32_shown;
    int32_t i32_index;
    int32_t i32_name;
/* more to report */
    bool b_more;

/* start values */
    s_task = g_s_loader_th;
    e_state = eInvalid;
    pui32_stack = nullptr;
/* nothing found yet */
    pui32_word = nullptr;
    ui32_addr = 0;
    i32_shown = 0;
/* behind the saved registers */
    i32_index = STACK_FIRST_WORD;
    i32_name = TASK_STATE_INVALID;
    b_more = g_b_running && (s_task != nullptr);
/* the link */
    r_out.printf("loader: running=%d core %08lx frames=%lu last frame %lu ms ago\r\n", (int)g_b_running,
                 (unsigned long)g_ui32_core_id, (unsigned long)g_ui32_frames, (unsigned long)(millis() - g_ui32_frame_ms));
    if (b_more)
    {
        e_state = eTaskGetState(s_task);
/* its state as a word */
        if (e_state <= TASK_STATE_INVALID)
        {
            i32_name = (int32_t)e_state;
        }
        r_out.printf("loader: task %s, stack left %u bytes\r\n", g_apc_task_state[i32_name],
                     (unsigned)uxTaskGetStackHighWaterMark(s_task));
/* on the other core's view a running task has no saved context */
        if (e_state == eRunning)
        {
            b_more = false;
        }
    }
/* the saved stack pointer must be an address in the RAM */
    if (b_more)
    {
        pui32_stack = *(uint32_t **)s_task;
/* anything else is not a stack */
        if (((uint32_t)pui32_stack < RAM_FIRST) || ((uint32_t)pui32_stack >= RAM_END))
        {
            b_more = false;
        }
    }
/* the PC, then the words of the stack */
    if (b_more)
    {
        r_out.printf("loader: pc %08lx, code on the stack:", (unsigned long)pui32_stack[STACK_PC_WORD]);
        while ((i32_index < STACK_WORDS) && (i32_shown < STACK_SHOWN) && b_more)
        {
/* the next word, while it is inside the RAM */
            pui32_word = pui32_stack + i32_index;
            if ((uint32_t)pui32_word >= RAM_END)
            {
                b_more = false;
            }
            else
            {
/* windowed call: top 2 bits = window size; the rest is a code address */
                ui32_addr = (*pui32_word & CALL_ADDR_MASK) | CALL_ADDR_BASE;
                if (((*pui32_word >> CALL_WINDOW_SHIFT) != 0) &&
                    (((ui32_addr >= CODE_FLASH_FIRST) && (ui32_addr < CODE_FLASH_END)) ||
                     ((ui32_addr >= CODE_RAM_FIRST) && (ui32_addr < CODE_RAM_END))))
                {
/* a return address */
                    r_out.printf(" %08lx", (unsigned long)ui32_addr);
                    i32_shown++;
                }
                i32_index++;
            }
        }
/* the end of the line */
        r_out.print("\r\n");
    }
}

/* "loader" command: task state, last link frame, stack code addresses */
void loader_info(Print &r_out)
{
    loader_report(r_out);
}

/* loop(): a loader that sends no link frame for 3 s on a machine is stuck (every loop of the */
/* loader reads registers): report where, and after 15 s restart the ESP32 as KEY0 would. The */
/* machine menu is left out (the ESP32 firmware update writes flash for a while without frames). */
void loader_check(void)
{
/* local variables */
    uint32_t ui32_idle;

/* start values */
    ui32_idle = 0;
    if (!g_b_running || (g_i32_machine_menu != 0))
    {
        g_ui32_stall_report_ms = 0;
    }
    else
    {
/* how long since the last frame */
        ui32_idle = millis() - g_ui32_frame_ms;
        if (ui32_idle < STALL_MS)
        {
            g_ui32_stall_report_ms = 0;
        }
        else
        {
/* a report at once, then every 5 s */
            if ((g_ui32_stall_report_ms == 0) || ((millis() - g_ui32_stall_report_ms) >= STALL_REPORT_MS))
            {
                g_ui32_stall_report_ms = millis();
/* what the loader's task is doing */
                Serial.print("\r\nloader: STALLED (no link frame)\r\n");
                loader_report(Serial);
            }
/* 15 s: only a restart helps */
            if (ui32_idle >= STALL_RESTART_MS)
            {
                Serial.print("loader: stalled for 15 s, restarting the ESP32\r\n");
/* after the text is out */
                delay(RESTART_DELAY_MS);
                esp_restart();
            }
        }
    }
}

/* espupd.h: the ESP32's own firmware from the SD card (the Arduino Update class = esp_ota_*) */

/* start writing an image of this size: 0 = ok */
int32_t ota_begin(uint32_t ui32_size)
{
/* local variables */
    int32_t i32_result;

/* start values */
    i32_result = 0;
    if (!Update.begin(ui32_size, U_FLASH))
    {
        Serial.printf("loader: firmware update: begin failed (%s)\r\n", Update.errorString());
/* an error for the caller */
        i32_result = ERROR_RESULT;
    }
    return i32_result;
}

/* the next bytes of the image: 0 = ok */
int32_t ota_write(const uint8_t *pui8_data, uint32_t ui32_count)
{
/* local variables */
    int32_t i32_result;

/* start values */
    i32_result = 0;
    if (Update.write(const_cast<uint8_t *>(pui8_data), ui32_count) != ui32_count)
    {
        Serial.printf("loader: firmware update: write failed (%s)\r\n", Update.errorString());
/* an error for the caller */
        i32_result = ERROR_RESULT;
    }
    return i32_result;
}

/* verify + select the new slot: 0 = ok */
int32_t ota_end(void)
{
/* local variables */
    int32_t i32_result;

/* start values */
    i32_result = 0;
    if (!Update.end(true))
    {
        Serial.printf("loader: firmware update: image rejected (%s)\r\n", Update.errorString());
/* an error for the caller */
        i32_result = ERROR_RESULT;
    }
    return i32_result;
}

/* give up: the running firmware stays */
void ota_abort(void)
{
    Update.abort();
}

/* restart the ESP32 */
void esp_reboot(void)
{
    Serial.print("loader: new firmware installed, restarting the ESP32\r\n");
/* after the text is out */
    delay(RESTART_DELAY_MS);
    esp_restart();
}
