/* flash_model.cpp -- the flash model of the two flash tests (see flash_model.h). */
/* */
/* hw_rd / hw_wr model the tape loader's flash pass-through (register 0x40, rtl/tape_loader.v: */
/* a write while a byte shifts is ignored) and an SPI flash with 4 KB erase (0x06 / 0x05 / 0x20 / */
/* 0x02 / 0x03; busy while erasing or programming, commands ignored then). TIMER advances 10 us */
/* per register access. The flash stream (fl_stream, the link's FLS frame) is modelled as one */
/* register access plus 1 us per byte. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
/* the registers' bits, the stream's prototype, this model's header */
#include "../../../ESP32/v2/src/hw.h"
#include "../../../ESP32/v2/src/flash.h"
#include "flash_model.h"

/* hw.h: main is the ESP32 loader task */
#undef main

/* the registers: TIMER, the flash pass-through, the machine control (bit 0: RELOAD) */
#define REG_TIMER 0x18
#define REG_FLASH 0x40
/* the machine control and its RELOAD bit */
#define REG_CTRL 0x44
#define CTRL_RELOAD 1u
/* the link takes 10 us per register access; TIMER counts 56 per us */
#define ACCESS_US 10
#define TIMER_PER_US 56
/* a byte of the pass-through takes 5 us (the real link) */
#define BUSY_US_REAL 5
/* the flash's commands */
#define FLASH_WREN 0x06
#define FLASH_RDSR 0x05
#define FLASH_ERASE 0x20
/* page program, read */
#define FLASH_PROGRAM 0x02
#define FLASH_READ 0x03
/* the status register's bits */
#define STATUS_BUSY 1
#define STATUS_WEL 2
/* a command: its code, 3 address bytes, data */
#define CMD_BUF 300
#define CMD_CODE_ONLY 1
#define CMD_WITH_ADDR 4
/* where the address bytes are */
#define ADDR_HIGH 1
#define ADDR_MID 2
#define ADDR_LOW 3
/* their shifts */
#define HIGH_SHIFT 16
#define MID_SHIFT 8
/* a page program: 256 bytes at most, wrapping inside the page */
#define PROGRAM_END 260
#define PAGE_MASK 0xFFu
#define SECTOR_MASK 0xFFFu
/* an erased byte; what the bus reads without a chip */
#define ERASED 0xFF
#define BUS_IDLE 0xFF
/* erase: 40 .. 450 ms; page program: 0.7 .. 2.7 ms */
#define ERASE_MIN_US 40000
#define ERASE_SPREAD_US 410000
/* page program */
#define PROGRAM_MIN_US 700
#define PROGRAM_SPREAD_US 2000
/* a stream: one microsecond per byte, two more bytes when data comes back */
#define STREAM_BYTE_US 1
#define STREAM_RX_EXTRA 2
#define HALF 2
/* one */
#define ONE 1

/* the flash's contents */
uint8_t g_aui8_fm_flash[FM_FLASH_SIZE];
/* the command being received */
static uint8_t g_aui8_cmd[CMD_BUF];
/* where tick() jumps to at the cut-off */
jmp_buf g_s_fm_cut;
/* the modelled time */
uint64_t g_ui64_fm_now_us;
/* register accesses counted, and the count that ends the run */
int64_t g_i64_fm_accesses;
int64_t g_i64_fm_cut_at = FM_NO_CUT;
/* sectors erased, RELOAD commands seen */
int64_t g_i64_fm_erases;
int32_t g_i32_fm_reloads;
/* how long a byte of the pass-through takes */
uint32_t g_ui32_fm_busy_us = BUSY_US_REAL;
/* the flash stream */
bool g_b_fm_stream_on = true;
int64_t g_i64_fm_streams;
int64_t g_i64_fm_stream_break;
/* SPI flash: chip select, write enable latch, busy until, bytes of the command, read address */
static bool g_b_cs;
static bool g_b_wel;
static uint64_t g_ui64_busy_until;
/* bytes received, the read address */
static int32_t g_i32_ncmd;
static uint32_t g_ui32_rd_addr;
/* pass-through register: the byte read, busy until, enabled */
static uint32_t g_ui32_pt_q;
static uint64_t g_ui64_pt_until;
static bool g_b_pt_en;

/* one register access: time goes on, and the run may end here */
static void tick(void)
{
    g_ui64_fm_now_us += ACCESS_US;
    g_i64_fm_accesses++;
/* the cut-off */
    if ((g_i64_fm_cut_at >= 0) && (g_i64_fm_accesses >= g_i64_fm_cut_at))
    {
        longjmp(g_s_fm_cut, ONE);
    }
}

/* is the flash erasing or programming? */
static bool fl_busy(void)
{
    return g_ui64_fm_now_us < g_ui64_busy_until;
}

/* the address of the command received */
static uint32_t cmd_addr(void)
{
/* local variables */
    uint32_t ui32_addr;

    ui32_addr = ((uint32_t)g_aui8_cmd[ADDR_HIGH] << HIGH_SHIFT) | ((uint32_t)g_aui8_cmd[ADDR_MID] << MID_SHIFT) |
                g_aui8_cmd[ADDR_LOW];
    return ui32_addr;
}

/* one byte to the flash, one byte back */
static uint8_t spi_byte(uint8_t ui8_mosi)
{
    uint8_t ui8_miso;

    ui8_miso = BUS_IDLE;
/* the status register */
    if ((g_i32_ncmd >= CMD_CODE_ONLY) && (g_aui8_cmd[0] == FLASH_RDSR))
    {
        ui8_miso = 0;
/* busy */
        if (fl_busy())
        {
            ui8_miso |= STATUS_BUSY;
        }
/* write enabled */
        if (g_b_wel)
        {
            ui8_miso |= STATUS_WEL;
        }
    }
/* data of a read (not while busy) */
    if ((g_i32_ncmd >= CMD_WITH_ADDR) && (g_aui8_cmd[0] == FLASH_READ) && !fl_busy())
    {
        ui8_miso = g_aui8_fm_flash[g_ui32_rd_addr % FM_FLASH_SIZE];
        g_ui32_rd_addr++;
    }
/* the byte received is kept while there is room */
    if (g_i32_ncmd < CMD_BUF)
    {
        g_aui8_cmd[g_i32_ncmd] = ui8_mosi;
    }
    g_i32_ncmd++;
/* a read's address is complete */
    if ((g_i32_ncmd == CMD_WITH_ADDR) && (g_aui8_cmd[0] == FLASH_READ))
    {
        g_ui32_rd_addr = cmd_addr();
    }
    return ui8_miso;
}

/* chip select off: the command received is executed */
static void spi_cs_off(void)
{
/* local variables */
    uint32_t ui32_addr;
    int32_t i32_index;

/* start values */
    ui32_addr = 0;
    i32_index = 0;
/* a command with an address */
    if (g_i32_ncmd >= CMD_WITH_ADDR)
    {
        ui32_addr = cmd_addr() % FM_FLASH_SIZE;
    }
    if ((g_i32_ncmd == 0) || fl_busy())
    {
/* nothing received, or ignored while busy */
    }
    else if ((g_aui8_cmd[0] == FLASH_WREN) && (g_i32_ncmd == CMD_CODE_ONLY))
    {
        g_b_wel = true;
    }
    else if ((g_aui8_cmd[0] == FLASH_ERASE) && (g_i32_ncmd == CMD_WITH_ADDR) && g_b_wel)
    {
/* sector erase: 40 .. 450 ms */
        memset(g_aui8_fm_flash + (ui32_addr & ~SECTOR_MASK), ERASED, FM_SECTOR);
        g_ui64_busy_until = g_ui64_fm_now_us + ERASE_MIN_US + (uint64_t)(rand() % ERASE_SPREAD_US);
/* write enable ends; counted */
        g_b_wel = false;
        g_i64_fm_erases++;
    }
    else if ((g_aui8_cmd[0] == FLASH_PROGRAM) && (g_i32_ncmd > CMD_WITH_ADDR) && g_b_wel)
    {
/* page program: bits only go to 0, the address wraps inside the page */
        for (i32_index = CMD_WITH_ADDR; (i32_index < g_i32_ncmd) && (i32_index < PROGRAM_END); i32_index++)
        {
            g_aui8_fm_flash[(ui32_addr & ~PAGE_MASK) | ((ui32_addr + i32_index - CMD_WITH_ADDR) & PAGE_MASK)] &=
                g_aui8_cmd[i32_index];
        }
/* 0.7 .. 2.7 ms */
        g_ui64_busy_until = g_ui64_fm_now_us + PROGRAM_MIN_US + (uint64_t)(rand() % PROGRAM_SPREAD_US);
        g_b_wel = false;
    }
    else if ((g_aui8_cmd[0] != FLASH_RDSR) && (g_aui8_cmd[0] != FLASH_READ))
    {
/* any other command ends the write enable */
        g_b_wel = false;
    }
    else
    {
/* status and read change nothing */
    }
    g_i32_ncmd = 0;
}

/* a register read: TIMER, and the pass-through (busy + the byte read) */
uint32_t hw_rd(uint8_t ui8_reg)
{
/* local variables */
    uint32_t ui32_value;

/* start values */
    ui32_value = 0;
    tick();
/* the timer, in the FPGA's clock ticks */
    if (ui8_reg == REG_TIMER)
    {
        ui32_value = (uint32_t)(g_ui64_fm_now_us * TIMER_PER_US);
    }
    else if (ui8_reg == REG_FLASH)
    {
/* a started byte is busy for g_ui32_fm_busy_us */
        ui32_value = g_ui32_pt_q;
        if (g_ui64_fm_now_us < g_ui64_pt_until)
        {
            ui32_value |= FL_BUSY;
        }
    }
    else
    {
/* every other register reads 0 */
    }
    return ui32_value;
}

/* a register write: RELOAD counted, the pass-through executed */
void hw_wr(uint8_t ui8_reg, uint32_t ui32_value)
{
/* local variables */
    bool b_ncs;

/* start values */
    b_ncs = false;
    tick();
/* the machine control */
    if (ui8_reg == REG_CTRL)
    {
        if ((ui32_value & CTRL_RELOAD) != 0)
        {
            g_i32_fm_reloads++;
        }
    }
/* any other register */
    else if (ui8_reg != REG_FLASH)
    {
/* not modelled */
    }
    else if (g_ui64_fm_now_us < g_ui64_pt_until)
    {
/* ignored while a byte shifts, as in the RTL */
    }
    else
    {
/* chip select: off also when the pass-through is disabled */
        g_b_pt_en = (ui32_value & FL_EN) != 0;
        b_ncs = ((ui32_value & FL_CS) == 0) || !g_b_pt_en;
/* a rising chip select ends the command */
        if (b_ncs && g_b_cs)
        {
            spi_cs_off();
        }
        g_b_cs = !b_ncs;
/* a byte started */
        if ((ui32_value & FL_START) != 0)
        {
            g_ui32_pt_q = BUS_IDLE;
/* with a chip selected the flash answers */
            if (g_b_cs)
            {
                g_ui32_pt_q = spi_byte((uint8_t)ui32_value);
            }
            g_ui64_pt_until = g_ui64_fm_now_us + g_ui32_fm_busy_us;
        }
    }
}

/* the flash stream: a header, then data out and / or data back, in one link frame */
int32_t fl_stream(const uint8_t *pui8_hdr, uint32_t ui32_hdr_len, const uint8_t *pui8_data, uint8_t *pui8_rx,
                  uint32_t ui32_count)
{
/* local variables */
    uint32_t ui32_index;
    uint32_t ui32_all;
    uint8_t ui8_out;
/* the byte back, the result */
    uint8_t ui8_in;
    int32_t i32_result;

/* start values */
    ui32_index = 0;
    ui32_all = ui32_hdr_len + ui32_count;
    ui8_out = 0;
/* nothing read; an error until the stream is through */
    ui8_in = 0;
    i32_result = FL_ERROR;
    if (pui8_rx != NULL)
    {
/* two more bytes clock the answer out */
        ui32_all += STREAM_RX_EXTRA;
    }
    if (g_b_fm_stream_on)
    {
/* one register access; a byte still shifting ends first */
        tick();
        if (g_ui64_fm_now_us < g_ui64_pt_until)
        {
            g_ui64_fm_now_us = g_ui64_pt_until;
        }
/* the pass-through is on, the chip selected */
        g_b_pt_en = true;
        g_b_cs = true;
        g_i64_fm_streams++;
/* byte by byte */
        for (ui32_index = 0; ui32_index < ui32_all; ui32_index++)
        {
/* the header, then the data (zeros when only reading) */
            ui8_out = 0;
            if (ui32_index < ui32_hdr_len)
            {
                ui8_out = pui8_hdr[ui32_index];
            }
/* the data */
            else if (((ui32_index - ui32_hdr_len) < ui32_count) && (pui8_data != NULL))
            {
                ui8_out = pui8_data[ui32_index - ui32_hdr_len];
            }
            else
            {
/* past the data: zeros */
            }
            g_ui64_fm_now_us += STREAM_BYTE_US;
/* the breaking stream drops its middle byte: the FPGA flags it */
            if (!((g_i64_fm_streams == g_i64_fm_stream_break) && (ui32_index == (ui32_all / HALF))))
            {
                ui8_in = spi_byte(ui8_out);
/* kept when it is part of the answer */
                if ((pui8_rx != NULL) && (ui32_index >= ui32_hdr_len) && ((ui32_index - ui32_hdr_len) < ui32_count))
                {
                    pui8_rx[ui32_index - ui32_hdr_len] = ui8_in;
                }
            }
        }
/* a broken stream is not used again */
        if (g_i64_fm_streams == g_i64_fm_stream_break)
        {
            g_b_fm_stream_on = false;
        }
        else
        {
/* through */
            i32_result = FL_OK;
        }
    }
    return i32_result;
}

/* the pass-through as after a restart of the ESP32: not busy (the chip select is kept) */
void fm_link_idle(void)
{
    g_ui64_pt_until = 0;
}

/* the model's clock starts again */
void fm_clock_restart(void)
{
    g_ui64_fm_now_us = 0;
/* nothing busy */
    g_ui64_busy_until = 0;
    g_ui64_pt_until = 0;
}
