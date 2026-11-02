/* flash.c -- the configuration flash through the FPGA's pass-through register (flash.h) */
#include "hw.h"
#include "flash.h"

/* the FPGA ignores a write while a byte is still shifting (rtl/tape_loader.v): wait first */
static void fl_put(uint32_t v) { while (FLASH & FL_BUSY) ; FLASH = v; }

void    fl_send(uint8_t b)    { fl_put(FL_EN | FL_CS | FL_START | b); }
uint8_t fl_xfer(uint8_t b)    { fl_send(b); while (FLASH & FL_BUSY) ; return (uint8_t)(FLASH & 0xFFu); }
void    fl_end(void)          { fl_put(FL_EN); }
/* a command: chip select off first (it stays on in the FPGA if the ESP32 restarted in a transfer) */
void    fl_cmd(uint8_t c)     { fl_end(); fl_send(c); }
void    fl_wren(void)         { fl_cmd(0x06); fl_end(); }
void    fl_release(void)      { while (FLASH & FL_BUSY) ; FLASH = 0; }

void fl_addr(uint8_t cmd, uint32_t a)
{
    fl_cmd(cmd);
    fl_send((uint8_t)(a >> 16)); fl_send((uint8_t)(a >> 8)); fl_send((uint8_t)a);
}

int fl_wait(uint32_t ms)
{
    uint32_t t0 = TIMER;
    for (;;) {
        fl_cmd(0x05);
        uint8_t st = fl_xfer(0);
        fl_end();
        if (!(st & 1)) return 0;
        if (TIMER - t0 > ms * CLK_PER_MS) return -1;
    }
}

static void hdr4(uint8_t h[4], uint8_t cmd, uint32_t a)
{
    h[0] = cmd; h[1] = (uint8_t)(a >> 16); h[2] = (uint8_t)(a >> 8); h[3] = (uint8_t)a;
}

void fl_read(uint32_t a, uint8_t *d, uint32_t n)
{
    uint8_t h[4];
    while (n) {                                             /* the stream, in pieces */
        uint32_t k = n < FL_STREAM_MAX ? n : FL_STREAM_MAX;
        fl_end();
        hdr4(h, 0x03, a);
        if (fl_stream(h, 4, 0, d, k)) break;
        fl_end();
        a += k; d += k; n -= k;
    }
    if (!n) return;
    fl_addr(0x03, a);                                       /* byte-wise */
    while (n--) *d++ = fl_xfer(0);
    fl_end();
}

void fl_prog(uint32_t a, const uint8_t *d)
{
    uint8_t  h[4];
    uint32_t i;
    fl_wren();
    hdr4(h, 0x02, a);
    if (fl_stream(h, 4, d, 0, 256) == 0) { fl_end(); return; }
    fl_end();                                               /* a broken stream: program it again */
    fl_wren();
    fl_addr(0x02, a);
    for (i = 0; i < 256; i++) fl_send(d[i]);
    fl_end();
}
