/* flash.c -- the configuration flash through the FPGA's pass-through register (flash.h) */
#include "hw.h"
#include "flash.h"

/* commands of the serial flash */
#define CMD_PAGE_PROGRAM 0x02
#define CMD_READ 0x03
/* status and write enable */
#define CMD_READ_STATUS 0x05
#define CMD_WRITE_ENABLE 0x06
/* status register: a write or an erase is in progress */
#define STATUS_BUSY 0x01u
/* the received byte in the FLASH register */
#define RX_MASK 0xFFu
/* a command header: the command and three address bytes, high byte first */
#define HDR_LEN 4
#define HDR_CMD 0
/* the three address bytes */
#define HDR_ADDR_HIGH 1
#define HDR_ADDR_MID 2
#define HDR_ADDR_LOW 3
/* shifts that take the high and the middle byte of a 24-bit address */
#define SHIFT_ADDR_HIGH 16
#define SHIFT_ADDR_MID 8
/* bytes of one flash page */
#define PAGE_SIZE 256u

/* write the FLASH register */
/* the FPGA ignores a write while a byte is still shifting (rtl/tape_loader.v): wait first */
static void fl_put(uint32_t ui32_value)
{
/* wait for the byte in progress */
    while ((FLASH & FL_BUSY) != 0)
    {
    }
    FLASH = ui32_value;
}

/* chip select on, send one byte */
void fl_send(uint8_t ui8_byte)
{
    fl_put(FL_EN | FL_CS | FL_START | ui8_byte);
}

/* send one byte, return the byte received */
uint8_t fl_xfer(uint8_t ui8_byte)
{
/* local variables */
    uint8_t ui8_rx;

    ui8_rx = 0;
    fl_send(ui8_byte);
/* the received byte is valid when the shift has ended */
    while ((FLASH & FL_BUSY) != 0)
    {
    }
    ui8_rx = (uint8_t)(FLASH & RX_MASK);
    return ui8_rx;
}

/* chip select off, the pins stay with the port */
void fl_end(void)
{
    fl_put(FL_EN);
}

/* a command: chip select off first (it stays on in the FPGA if the ESP32 restarted in a transfer) */
void fl_cmd(uint8_t ui8_cmd)
{
    fl_end();
    fl_send(ui8_cmd);
}

/* write enable */
void fl_wren(void)
{
    fl_cmd(CMD_WRITE_ENABLE);
    fl_end();
}

/* give the pins back to the FPGA's own flash access */
void fl_release(void)
{
/* wait for the byte in progress */
    while ((FLASH & FL_BUSY) != 0)
    {
    }
    FLASH = 0;
}

/* command + 24-bit address, high byte first */
void fl_addr(uint8_t ui8_cmd, uint32_t ui32_addr)
{
    fl_cmd(ui8_cmd);
/* the three address bytes */
    fl_send((uint8_t)(ui32_addr >> SHIFT_ADDR_HIGH));
    fl_send((uint8_t)(ui32_addr >> SHIFT_ADDR_MID));
    fl_send((uint8_t)ui32_addr);
}

/* wait while the flash is busy: FL_OK, or FL_ERROR after ui32_ms */
int32_t fl_wait(uint32_t ui32_ms)
{
/* local variables */
    uint32_t ui32_start;
    uint8_t ui8_status;
/* the end of the wait, and the result */
    bool b_done;
    int32_t i32_result;

/* start values */
    ui32_start = TIMER;
    ui8_status = 0;
/* poll the status register until it is ready or the time is over */
    b_done = false;
    i32_result = FL_OK;
    while (!b_done)
    {
/* read the status register */
        fl_cmd(CMD_READ_STATUS);
        ui8_status = fl_xfer(0);
        fl_end();
/* ready, or too late */
        if ((ui8_status & STATUS_BUSY) == 0)
        {
            b_done = true;
        }
        else if ((TIMER - ui32_start) > (ui32_ms * CLK_PER_MS))
        {
/* still busy after the allowed time */
            i32_result = FL_ERROR;
            b_done = true;
        }
        else
        {
/* still busy: ask again */
        }
    }
    return i32_result;
}

/* fill a command header: the command and a 24-bit address */
static void hdr4(uint8_t aui8_hdr[HDR_LEN], uint8_t ui8_cmd, uint32_t ui32_addr)
{
    aui8_hdr[HDR_CMD] = ui8_cmd;
/* the address, high byte first */
    aui8_hdr[HDR_ADDR_HIGH] = (uint8_t)(ui32_addr >> SHIFT_ADDR_HIGH);
    aui8_hdr[HDR_ADDR_MID] = (uint8_t)(ui32_addr >> SHIFT_ADDR_MID);
    aui8_hdr[HDR_ADDR_LOW] = (uint8_t)ui32_addr;
}

/* read ui32_count bytes from ui32_addr */
void fl_read(uint32_t ui32_addr, uint8_t *pui8_dst, uint32_t ui32_count)
{
/* local variables */
    uint8_t aui8_hdr[HDR_LEN];
    uint32_t ui32_piece;
    bool b_stream;

/* start values */
    ui32_piece = 0;
/* the stream is used until it fails */
    b_stream = true;
/* the stream, in pieces */
    while ((ui32_count != 0) && b_stream)
    {
        ui32_piece = ui32_count;
/* one piece is at most a full stream */
        if (ui32_piece > FL_STREAM_MAX)
        {
            ui32_piece = FL_STREAM_MAX;
        }
/* a new command: read from this address */
        fl_end();
        hdr4(aui8_hdr, CMD_READ, ui32_addr);
/* a failed stream leaves the rest to the byte-wise way */
        if (fl_stream(aui8_hdr, HDR_LEN, 0, pui8_dst, ui32_piece) != FL_OK)
        {
            b_stream = false;
        }
        else
        {
            fl_end();
/* this piece is done */
            ui32_addr += ui32_piece;
            pui8_dst += ui32_piece;
            ui32_count -= ui32_piece;
        }
    }
/* byte-wise: whatever the stream did not read */
    if (ui32_count != 0)
    {
        fl_addr(CMD_READ, ui32_addr);
/* one transfer per byte */
        while (ui32_count != 0)
        {
            *pui8_dst = fl_xfer(0);
            pui8_dst++;
/* one byte less to read */
            ui32_count--;
        }
        fl_end();
    }
}

/* write enable + page program of 256 bytes (no wait) */
void fl_prog(uint32_t ui32_addr, const uint8_t *pui8_src)
{
/* local variables */
    uint8_t aui8_hdr[HDR_LEN];
    uint32_t ui32_index;
    int32_t i32_stream;

/* start values */
    ui32_index = 0;
    i32_stream = FL_OK;
/* first the stream */
    fl_wren();
    hdr4(aui8_hdr, CMD_PAGE_PROGRAM, ui32_addr);
    i32_stream = fl_stream(aui8_hdr, HDR_LEN, pui8_src, 0, PAGE_SIZE);
/* both ways end with chip select off, which starts the programming */
    fl_end();
/* a broken stream: program the page again, byte-wise */
    if (i32_stream != FL_OK)
    {
        fl_wren();
        fl_addr(CMD_PAGE_PROGRAM, ui32_addr);
/* the page's bytes */
        for (ui32_index = 0; ui32_index < PAGE_SIZE; ui32_index++)
        {
            fl_send(pui8_src[ui32_index]);
        }
        fl_end();
    }
}
