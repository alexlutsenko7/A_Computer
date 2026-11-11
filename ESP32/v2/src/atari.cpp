/* atari.c -- LTari (Atari 800XL / 130XE core): the SIO disk drive D1: for .atr images */
/* The FPGA's SIO bridge (LTari/ep4_ce15/rtl/atari_sio.v) gives us the bytes POKEY sends, each with */
/* the command line state, and sends our bytes to POKEY's serial input at 19,200 baud: */
/*   MSTAT (read MCTL): [7:0] byte, [8] valid, [9] sent during a command frame, [10] first byte of */
/*                      the frame, [11] command line asserted now, [13] everything sent */
/*   MCLR:              [7:0] byte, [8] send it, [9] drop the oldest received byte, [10] flush */
/* The drive follows the SIO protocol of the Altirra Hardware Reference Manual (9.1, 10.2): a command */
/* frame (device, command, AUX1, AUX2, checksum) is answered after the command line is raised: */
/* ACK 'A' (or NAK 'N'), then for a write the computer's data frame and a second ACK, then at least */
/* 250 us later Complete 'C' (or Error 'E') and, for a read, the data frame. Checksums are the 8-bit */
/* sum with the carry added back in. */
/* Commands: $53 status (4 bytes: drive status, inverted FDC status, format timeout $E0, 0), */
/* $52 read, $50 put / $57 write, $21 / $22 format (sectors filled with 0; the answer is a */
/* sector-sized buffer of $FF = no bad sectors); anything else is NAKed. Sectors 1-3 are always */
/* 128 bytes, the others the image's sector size (128 or 256). */
/* .atr: 16-byte header ($96 $02, size in 16-byte paragraphs [3:2] + [6] << 16, sector size [5:4]), */
/* then the sectors in order (a header size beyond the file's end, as some old images have, is cut to */
/* the file). Mounting cold-starts the Atari (RELOAD), so the OS boots from D1:. */
/* .car: 16-byte header ("CART", type and checksum big-endian), then the ROM. Types 1 (standard 8 KB, */
/* $A000) and 2 (standard 16 KB, $8000) are written to SDRAM 0x28000, types 41 (Atarimax 128 KB), 42 */
/* (Atarimax 1 MB, starts in bank 0) and 75 (the same, starting in bank 127) to 0x100000 through the */
/* cartridge window (MCTL [23], 256 KB page in [21:20]); the snapshot port's MWR does the writing. MCTL */
/* [18:16] then switches the cartridge on (rtl/atari_system.v) and the Atari cold-starts into it. Inserting */
/* an .atr or running an .xex takes the cartridge out again (KEY0 too). */
/* Screenshot: the frame buffer's newest frame (rtl/atari_fb.v: 376 x 240 pixels, one byte each, */
/* 512 bytes per line), held while it is read (memory command CTL [2]), as a 256-colour BMP. */
/* .xex: a read-only virtual disk: sectors 1-3 = our boot loader (atari_xexboot.h, from */
/* LTari/ep4_ce15/tools/mk_xexboot.py, with the file length patched in), sectors 4.. = the file. */
/* Snapshots (.A8S, as L64's .A64; rtl/atari_system.v): freeze at an instruction boundary, */
/* 128-byte header (CPU, PIA, cartridge state, cartridge / disk names), the I/O shadow */
/* (0x3D000-0x3D4FF: GTIA, -, POKEY, PIA, ANTIC pages), 64 KB RAM (+ 64 KB extended on the 130). */
/* Loading: RAM back, then a restore program in the restore bank (0x30000) runs in restore mode: */
/* POKEY, GTIA, PIA, ANTIC, Atarimax bank, stack, A / X / Y, RTI. */
#include <stdlib.h>
#include "hw.h"
#include "hal.h"
/* this module's header, string functions */
#include "atari.h"
#include "util.h"
/* the generated tables */
#include "atari_xexboot.h"
#include "atari_palette.h"
/* screenshots, the card */
#include "shot.h"
#include "fat.h"

/* MSTAT (read MCTL): a byte is there, it was sent in a command frame, it is the frame's first, */
/* the command line is asserted now, everything was sent */
#define ST_VALID (1u << 8)
#define ST_CMD (1u << 9)
#define ST_FIRST (1u << 10)
/* the command line now, the transmitter empty */
#define ST_CMDNOW (1u << 11)
#define ST_TXDONE (1u << 13)
/* MCLR: send a byte, drop the oldest received byte, flush */
#define CL_PUSH (1u << 8)
#define CL_POP (1u << 9)
#define CL_FLUSH (1u << 10)
/* MCTL: the cartridge type's place, OPTION held, the cartridge window and its 256 KB page */
#define MC_CART_SHIFT 16
#define MC_OPTION (1u << 24)
/* the cartridge window */
#define MC_WINDOW (1u << 23)
#define MC_WINDOW_PAGE_SHIFT 20
/* a register read from a gone FPGA */
#define ALL_ONES 0xFFFFFFFFu
/* the SIO bus: the drive's device number, the command frame, the answers */
#define DEV_D1 0x31
#define CF_LEN 5
#define CF_DEVICE 0
/* the frame's bytes */
#define CF_COMMAND 1
#define CF_AUX1 2
#define CF_AUX2 3
/* the checksum, and how many bytes it covers */
#define CF_CHECKSUM 4
#define CF_DATA_LEN 4
/* the answers */
#define SIO_ACK 0x41
#define SIO_NAK 0x4E
/* complete, error */
#define SIO_COMPLETE 0x43
#define SIO_ERROR 0x45
/* the SIO commands of a disk drive */
#define SIO_CMD_FORMAT 0x21
#define SIO_CMD_FORMAT_MEDIUM 0x22
#define SIO_CMD_PUT 0x50
/* read, status, write with verify */
#define SIO_CMD_READ 0x52
#define SIO_CMD_STATUS 0x53
#define SIO_CMD_WRITE 0x57
/* the status answer: 4 bytes; drive status bits; the FDC status inverted; the format timeout */
#define STATUS_LEN 4
#define STATUS_DRIVE 0
#define STATUS_FDC 1
/* the timeout, an unused byte */
#define STATUS_TIMEOUT 2
#define STATUS_UNUSED 3
/* drive status bits */
#define DRIVE_DOUBLE_DENSITY 0x20
#define DRIVE_ENHANCED_DENSITY 0x80
#define DRIVE_WRITE_PROTECT_ERROR 0x08
/* no FDC error; the format timeout */
#define FDC_NO_ERROR 0xFF
#define FORMAT_TIMEOUT 0xE0
/* times of the protocol */
#define US_PER_MS 1000u
#define TX_WAIT_MS 200u
#define RESULT_DELAY_US 300u
/* waiting for a byte, the pause before the second ACK */
#define RX_TIMEOUT_MS 50u
#define DATA_ACK_DELAY_US 1000u
/* rx_frame: timeout or a command frame instead; bad checksum */
#define RX_OK 0
#define RX_NONE (-1)
#define RX_BAD_SUM (-2)
/* sector access: failed */
#define SEC_OK 0
#define SEC_ERROR (-1)
/* events handled in one call of at_service */
#define EVENTS_PER_CALL 64
/* disks: the first three sectors are always 128 bytes */
#define BOOT_SECTORS 3u
#define SEC_FIRST 1u
#define SEC_AFTER_BOOT 4u
/* sector sizes */
#define SEC_SINGLE 128u
#define SEC_DOUBLE 256u
#define BOOT_BYTES 384u
/* an enhanced density disk; the sector buffer */
#define SECTORS_ENHANCED 1040u
#define SEC_BUF_LEN 257
/* the checksum: 8 bits with the carry added back in */
#define SUM_MASK 0xFFu
/* shifts of the bytes of a word */
#define SHIFT_BYTE 8
#define SHIFT_WORD 16
#define SHIFT_3_BYTES 24
/* bits of a byte */
#define BITS_PER_BYTE 8u
/* card sectors, for ff_update */
#define CARD_SECTOR 512u
#define CARD_SECTOR_MASK 511u
/* .atr header: 16 bytes, magic $96 $02, size in 16-byte paragraphs, sector size */
#define ATR_HDR_LEN 16u
#define ATR_MAGIC_0 0x96
#define ATR_MAGIC_1 0x02
/* offsets in the header */
#define ATR_MAGIC_1_OFF 1
#define ATR_SIZE_LOW 2
#define ATR_SIZE_MID 3
/* the sector size, the size's high byte */
#define ATR_SECSIZE_LOW 4
#define ATR_SECSIZE_HIGH 5
#define ATR_SIZE_HIGH 6
/* bytes of a paragraph */
#define ATR_PARAGRAPH 16u
/* .xex: a binary load file starts with $FFFF and has at least one segment; the length is 3 bytes */
#define XEX_MAGIC 0xFF
#define XEX_MIN_SIZE 7u
/* the length field; rounding up to a sector */
#define XEX_LEN_BYTES 3u
#define SEC_ROUND_UP 127u
/* .car header: 16 bytes, "CART", the type big-endian */
#define CAR_HDR_LEN 16u
#define CAR_TYPE_0 4
#define CAR_TYPE_1 5
/* its lower bytes, the magic's length */
#define CAR_TYPE_2 6
#define CAR_TYPE_3 7
#define CAR_MAGIC_LEN 4
/* cartridge types of the .car file, their sizes, and the mode number the FPGA knows them by */
#define CAR_STD_8K 1u
#define CAR_STD_16K 2u
#define CAR_ATARIMAX_128K 41u
/* the two 1 MB Atarimax kinds */
#define CAR_ATARIMAX_1M_OLD 42u
#define CAR_ATARIMAX_1M_NEW 75u
/* sizes */
#define LEN_8K 8192u
#define LEN_16K 16384u
#define LEN_128K 131072u
/* 1 MB; then the FPGA's modes */
#define LEN_1M 1048576u
#define MODE_STD_8K 1u
#define MODE_STD_16K 2u
/* the Atarimax modes */
#define MODE_ATARIMAX_128K 3u
#define MODE_ATARIMAX_1M_OLD 4u
#define MODE_ATARIMAX_1M_NEW 5u
/* SDRAM address of the cartridge image (rtl/atari_system.v); the window's 256 KB pages */
#define CART_BASE 0x28000u
#define WINDOW_MASK 0x3FFFFu
#define WINDOW_SHIFT 18
/* OPTION released at the latest after this (no SIO command came) */
#define NOBA_MS 5000u
/* characters of a name shown in the status row, and kept in a snapshot */
#define STATUS_NAME_LEN 26
#define SNAP_NAME_LEN 31
/* the screenshot: the frame buffer's picture and line length; hold / release of the buffers */
#define SHOT_WIDTH 376
#define SHOT_HEIGHT 240
#define SHOT_LAST_ROW 239
/* the buffer's line, the hold bit */
#define FB_LINE_BYTES 512u
#define CTL_HOLD_FB 4u
/* snapshot port: the command's place, and the control values of restore mode */
#define CMD_SHIFT 28
#define CTL_FREEZE 1u
#define FREEZE_MS 200u
/* restore mode */
#define CTL_RESTORE_RESET 3u
#define CTL_RESTORE_RUN 1u
#define CTL_RESTORE_BUSY 1u
/* its timeout */
#define RESTORE_MS 500u
/* the register words of the snapshot port */
#define REG_CPU 0
#define REG_CPU2 1
#define REG_PIA_A 2
/* PIA port B, the machine */
#define REG_PIA_B 3
#define REG_MACHINE 4
/* fields of the machine word: cartridge type, Atarimax bank and "off", model */
#define M_CART_MASK 7u
#define M_BANK_SHIFT 4
#define M_BANK_MASK 0x7Fu
/* bank off, the model, one bit */
#define M_BANK_OFF_SHIFT 11
#define M_MODEL_SHIFT 12
#define BIT_MASK 1u
/* snapshots (.A8S): the I/O shadow (GTIA $D0, $D1 unused, POKEY $D2, PIA $D3, ANTIC $D4), */
/* the restore bank (the CPU's view in restore mode), the restore program in it, the file's header */
#define SH_BASE 0x3D000u
#define SH_LEN 0x500u
#define RB_BASE 0x30000u
/* the restore program, the header's length */
#define STUB 0x2000u
#define A8S_HDR 128u
/* RAM of the 800XL and of the 130XE */
#define RAM_800 65536u
#define RAM_130 131072u
/* the .A8S header */
#define A8S_MAGIC_LEN 8
#define A8S_VERSION_OFF 8
#define A8S_VERSION 1
/* the model, then the 6502's registers */
#define A8S_MODEL 9
#define A8S_A 10
#define A8S_X 11
/* Y, P, S */
#define A8S_Y 12
#define A8S_P 13
#define A8S_S 14
/* the PC */
#define A8S_PCL 15
#define A8S_PCH 16
/* PIA port A */
#define A8S_ORA 17
#define A8S_DDRA 18
#define A8S_PACTL 19
/* PIA port B */
#define A8S_ORB 20
#define A8S_DDRB 21
#define A8S_PBCTL 22
/* the cartridge */
#define A8S_CART 23
#define A8S_BANK 24
#define A8S_BANK_OFF 25
/* a disk was in; the two names */
#define A8S_DISK_IN 26
#define A8S_CART_NAME 32
#define A8S_DISK_NAME 64
/* 6502 opcodes of the restore program */
#define OP_SEI 0x78
#define OP_CLD 0xD8
#define OP_LDA_IMM 0xA9
/* store, load, X */
#define OP_STA_ABS 0x8D
#define OP_LDA_ABS 0xAD
#define OP_LDX_IMM 0xA2
/* Y, the stack pointer, return from interrupt */
#define OP_LDY_IMM 0xA0
#define OP_TXS 0x9A
#define OP_RTI 0x40
/* the 6502's reset vector and stack page */
#define VEC_RESET_LOW 0xFFFCu
#define VEC_RESET_HIGH 0xFFFDu
#define STACK_PAGE 0x0100u
/* what RTI takes from the stack */
#define STACK_RTI_FRAME 3
#define STACK_P 2
#define STACK_PCL 1
/* the Atari's chips as the restore program writes them, and their place in the shadow */
#define GTIA_BASE 0xD000u
#define GTIA_REGS 0x1Du
#define GTIA_HITCLR 0xD01Eu
/* the console keys */
#define GTIA_CONSOL 0xD01Fu
#define SH_GTIA_CONSOL 0x1Fu
/* POKEY */
#define POKEY_BASE 0xD200u
#define POKEY_AUDIO_REGS 8u
#define POKEY_AUDCTL 0xD208u
/* timers start, IRQ enable, serial control */
#define POKEY_STIMER 0xD209u
#define POKEY_IRQEN 0xD20Eu
#define POKEY_SKCTL 0xD20Fu
/* POKEY in the shadow */
#define SH_POKEY 0x200u
#define SH_POKEY_AUDCTL 0x208u
#define SH_POKEY_IRQEN 0x20Eu
/* serial control in the shadow */
#define SH_POKEY_SKCTL 0x20Fu
/* the PIA */
#define PIA_PORTA 0xD300u
#define PIA_PORTB 0xD301u
#define PIA_PACTL 0xD302u
/* port B's control; control values */
#define PIA_PBCTL 0xD303u
#define PIA_CTL_DDR 0x3B
#define PIA_CTL_MASK 0x3F
/* the port, not the direction */
#define PIA_CTL_PORT 0x04
/* ANTIC */
#define ANTIC_BASE 0xD400u
#define ANTIC_NMIEN 0xD40Eu
#define SH_ANTIC 0x400u
/* NMI enable in the shadow; registers restored */
#define SH_ANTIC_NMIEN 0x40Eu
#define ANTIC_RESTORED 8
/* the Atarimax cartridge's bank register */
#define ATARIMAX_BASE 0xD500u
#define ATARIMAX_OFF_128K 0x10u
#define ATARIMAX_OFF_1M 0x80u
/* flags as numbers */
#define YES 1
#define ONE 1u

/* snapshot port commands */
enum
{
    C_MRD = 1,
    C_MWR = 2,
    C_REG = 3,
    C_CTL = 4
};

/* ANTIC registers restored from the shadow, NMIEN last */
static const uint8_t g_aui8_antic[ANTIC_RESTORED] = { 0x01, 0x02, 0x03, 0x04, 0x05, 0x07, 0x09, 0x00 };
/* the cartridge in (snapshots check it) */
static char g_ac_cart_name[NAME_BUF_LEN];
/* the disk in: its name and its sector buffer */
static char g_ac_name[NAME_BUF_LEN];
static uint8_t g_aui8_buf[SEC_BUF_LEN];
/* the command frame being received */
static uint8_t g_aui8_cf[CF_LEN];
/* a snapshot's header */
static uint8_t g_aui8_hdr[A8S_HDR];
/* the disk image's file */
static FFILE g_s_file;
/* a disk is in; it is read only; the last write hit the write protection; it is an .xex */
static int32_t g_i32_on;
static int32_t g_i32_ro;
/* write protection hit; an .xex */
static int32_t g_i32_wperr;
static int32_t g_i32_xex;
/* MCTL [18:16]: the cartridge in */
static uint32_t g_ui32_cart;
/* sector size and number of sectors of the disk */
static uint32_t g_ui32_ssz;
static uint32_t g_ui32_nsec;
/* bytes of the command frame received */
static int32_t g_i32_cn;
/* .xex: the file length, patched into the loader sectors */
static uint32_t g_ui32_xlen;
/* OPTION held (MCTL [24]) until the first SIO command: no BASIC; since when */
static int32_t g_i32_noba;
static uint32_t g_ui32_noba_t0;
/* SH_LEN bytes while a snapshot loads (heap) */
static uint8_t *g_pui8_shadow;
/* where the restore program is being written */
static uint32_t g_ui32_stub_pc;

/* snapshot port memory command (esp_hw.cpp turns MWR into bursts); the CPU need not stop */
static uint32_t snap_cmd(uint32_t ui32_cmd, uint32_t ui32_addr, uint32_t ui32_data)
{
/* local variables */
    uint32_t ui32_result;

    SNAPDAT = ui32_data;
    SNAPCMD = (ui32_cmd << CMD_SHIFT) | ui32_addr;
/* wait until the FPGA has done it */
    while ((SNAPCTL & SNAP_BUSY) != 0)
    {
    }
    ui32_result = SNAPDAT;
    return ui32_result;
}

/* SIO checksum: the 8-bit sum with the carry added back in */
static uint8_t csum(const uint8_t *pui8_data, int32_t i32_count)
{
/* local variables */
    uint32_t ui32_sum;
    int32_t i32_index;

/* start values */
    ui32_sum = 0;
    for (i32_index = 0; i32_index < i32_count; i32_index++)
    {
        ui32_sum += pui8_data[i32_index];
/* the carry goes back into the sum */
        ui32_sum = (ui32_sum & SUM_MASK) + (ui32_sum >> SHIFT_BYTE);
    }
    return (uint8_t)ui32_sum;
}

/* bytes of a sector: the first three are always 128 */
static uint32_t sec_len(uint32_t ui32_sec)
{
/* local variables */
    uint32_t ui32_len;

/* start values */
    ui32_len = g_ui32_ssz;
    if (ui32_sec <= BOOT_SECTORS)
    {
/* a boot sector */
        ui32_len = SEC_SINGLE;
    }
    return ui32_len;
}

/* where a sector is in the .atr file */
static uint32_t sec_off(uint32_t ui32_sec)
{
/* local variables */
    uint32_t ui32_off;

    if (ui32_sec <= BOOT_SECTORS)
    {
        ui32_off = ATR_HDR_LEN + ((ui32_sec - SEC_FIRST) * SEC_SINGLE);
    }
    else
    {
/* behind the three boot sectors */
        ui32_off = ATR_HDR_LEN + BOOT_BYTES + ((ui32_sec - SEC_AFTER_BOOT) * g_ui32_ssz);
    }
    return ui32_off;
}

/* wait some microseconds */
static void wait_us(uint32_t ui32_us)
{
/* local variables */
    uint32_t ui32_start;

    ui32_start = TIMER;
    while ((TIMER - ui32_start) < (ui32_us * (CLK_PER_MS / US_PER_MS)))
    {
    }
}

/* one byte to POKEY's serial input */
static void tx(uint8_t ui8_byte)
{
    MCLR = CL_PUSH | ui8_byte;
}

/* a data frame: the bytes and their checksum */
static void tx_frame(const uint8_t *pui8_data, int32_t i32_count)
{
/* local variables */
    int32_t i32_index;

    for (i32_index = 0; i32_index < i32_count; i32_index++)
    {
        tx(pui8_data[i32_index]);
    }
/* the checksum */
    tx(csum(pui8_data, i32_count));
}

/* until the last byte's stop bit is out (at most 200 ms) */
static void tx_wait(void)
{
/* local variables */
    uint32_t ui32_start;
    bool b_wait;

/* start values */
    ui32_start = TIMER;
    b_wait = true;
    while (b_wait)
    {
/* everything sent, or too long */
        if ((MCTL & ST_TXDONE) != 0)
        {
            b_wait = false;
        }
/* too long */
        else if ((TIMER - ui32_start) >= (TX_WAIT_MS * CLK_PER_MS))
        {
            b_wait = false;
        }
        else
        {
/* still sending */
        }
    }
}

/* the result byte after an ACK: at least 250 us of dead time after it */
static void tx_result(uint8_t ui8_byte)
{
    tx_wait();
/* the dead time, then the byte */
    wait_us(RESULT_DELAY_US);
    tx(ui8_byte);
}

/* the computer's data frame: i32_count bytes + checksum into a buffer; RX_OK, RX_NONE = timeout / */
/* command frame instead, RX_BAD_SUM = bad checksum */
static int32_t rx_frame(uint8_t *pui8_data, int32_t i32_count)
{
/* local variables */
    uint32_t ui32_start;
    uint32_t ui32_status;
/* a byte counter, the result */
    int32_t i32_index;
    int32_t i32_result;

/* start values */
    ui32_start = TIMER;
    ui32_status = 0;
/* nothing received, no error */
    i32_index = 0;
    i32_result = RX_OK;
/* the data bytes and the checksum byte */
    while ((i32_index < (i32_count + YES)) && (i32_result == RX_OK))
    {
        ui32_status = MCTL;
        if (ui32_status == ALL_ONES)
        {
/* FPGA gone */
            i32_result = RX_NONE;
        }
        else if ((ui32_status & ST_VALID) != 0)
        {
            if ((ui32_status & ST_CMD) != 0)
            {
/* a command frame instead of the data */
                i32_result = RX_NONE;
            }
            else
            {
/* one more byte; the timeout starts again */
                pui8_data[i32_index] = (uint8_t)ui32_status;
                i32_index++;
                MCLR = CL_POP;
/* the timeout from here */
                ui32_start = TIMER;
            }
        }
        else if ((TIMER - ui32_start) > (RX_TIMEOUT_MS * CLK_PER_MS))
        {
            i32_result = RX_NONE;
        }
        else
        {
/* nothing yet */
        }
    }
/* the checksum of a complete frame */
    if ((i32_result == RX_OK) && (csum(pui8_data, i32_count) != pui8_data[i32_count]))
    {
        i32_result = RX_BAD_SUM;
    }
    return i32_result;
}

/* a sector of an .xex's virtual disk: the loader, then the file, padded with 0 */
static int32_t read_sec_xex(uint32_t ui32_sec, uint8_t *pui8_dst)
{
/* local variables */
    uint32_t ui32_index;
    uint32_t ui32_off;
/* a character, the result */
    int32_t i32_char;
    int32_t i32_result;

/* start values */
    ui32_index = 0;
    ui32_off = 0;
    i32_char = 0;
/* no error; the boot sectors or the file */
    i32_result = SEC_OK;
    if (ui32_sec <= BOOT_SECTORS)
    {
/* the loader (flash) with the file length patched in */
        u_memcpy(pui8_dst, atari_xexboot + ((ui32_sec - SEC_FIRST) * SEC_SINGLE), SEC_SINGLE);
        for (ui32_index = 0; ui32_index < XEX_LEN_BYTES; ui32_index++)
        {
            ui32_off = XEXBOOT_LEN_OFS + ui32_index;
/* a byte of the length that lies in this sector */
            if ((ui32_off / SEC_SINGLE) == (ui32_sec - SEC_FIRST))
            {
                pui8_dst[ui32_off % SEC_SINGLE] = (uint8_t)(g_ui32_xlen >> (BITS_PER_BYTE * ui32_index));
            }
        }
    }
    else
    {
/* the file, 128 bytes per sector; behind its end the sector is 0 */
        ff_seek(&g_s_file, (ui32_sec - SEC_AFTER_BOOT) * SEC_SINGLE);
        for (ui32_index = 0; ui32_index < SEC_SINGLE; ui32_index++)
        {
/* inside the file */
            i32_char = 0;
            if ((((ui32_sec - SEC_AFTER_BOOT) * SEC_SINGLE) + ui32_index) < g_s_file.ui32_size)
            {
                i32_char = ff_getc(&g_s_file);
            }
/* a card error gives 0 and an error at the end */
            if (i32_char < 0)
            {
                i32_char = 0;
                i32_result = SEC_ERROR;
            }
/* into the sector */
            pui8_dst[ui32_index] = (uint8_t)i32_char;
        }
    }
    return i32_result;
}

/* read a sector of the disk in: SEC_OK or SEC_ERROR */
static int32_t read_sec(uint32_t ui32_sec, uint8_t *pui8_dst)
{
/* local variables */
    uint32_t ui32_index;
    uint32_t ui32_len;
/* a character, the result */
    int32_t i32_char;
    int32_t i32_result;

/* start values */
    ui32_index = 0;
    ui32_len = sec_len(ui32_sec);
    i32_char = 0;
/* no error; an .xex has sectors of its own */
    i32_result = SEC_OK;
    if (g_i32_xex != 0)
    {
        i32_result = read_sec_xex(ui32_sec, pui8_dst);
    }
    else
    {
/* from the .atr file */
        ff_seek(&g_s_file, sec_off(ui32_sec));
        for (ui32_index = 0; ui32_index < ui32_len; ui32_index++)
        {
            i32_char = ff_getc(&g_s_file);
/* a card error gives 0 and an error at the end */
            if (i32_char < 0)
            {
                i32_char = 0;
                i32_result = SEC_ERROR;
            }
/* into the sector */
            pui8_dst[ui32_index] = (uint8_t)i32_char;
        }
    }
    return i32_result;
}

/* write a sector; ff_update writes inside one card sector, and a disk sector may straddle two */
static int32_t write_sec(uint32_t ui32_sec, const uint8_t *pui8_src)
{
/* local variables */
    uint32_t ui32_off;
    uint32_t ui32_left;
/* a piece's length, the result */
    uint32_t ui32_piece;
    int32_t i32_result;

/* start values */
    ui32_off = sec_off(ui32_sec);
    ui32_left = sec_len(ui32_sec);
    ui32_piece = 0;
/* no error yet */
    i32_result = SEC_OK;
    while ((ui32_left != 0) && (i32_result == SEC_OK))
    {
/* up to the end of the card sector */
        ui32_piece = CARD_SECTOR - (ui32_off & CARD_SECTOR_MASK);
        if (ui32_piece > ui32_left)
        {
            ui32_piece = ui32_left;
        }
/* written through the file */
        if (ff_update(&g_s_file, ui32_off, pui8_src, ui32_piece) != FAT_OK)
        {
            i32_result = SEC_ERROR;
        }
        else
        {
/* the rest is in the next card sector */
            ui32_off += ui32_piece;
            pui8_src += ui32_piece;
/* that much less to do */
            ui32_left -= ui32_piece;
        }
    }
    return i32_result;
}

/* the result byte for a sector operation */
static uint8_t result_byte(int32_t i32_result)
{
/* local variables */
    uint8_t ui8_byte;

/* start values */
    ui8_byte = SIO_COMPLETE;
    if (i32_result != SEC_OK)
    {
/* failed */
        ui8_byte = SIO_ERROR;
    }
    return ui8_byte;
}

/* command $53: status */
static void cmd_status(void)
{
/* local variables */
    uint8_t aui8_status[STATUS_LEN];
    uint8_t ui8_drive;

/* start values */
    ui8_drive = 0;
    tx(SIO_ACK);
/* the drive status: density and a write to a protected disk */
    if (g_ui32_ssz == SEC_DOUBLE)
    {
        ui8_drive |= DRIVE_DOUBLE_DENSITY;
    }
/* 1040 sectors: enhanced density */
    if (g_ui32_nsec == SECTORS_ENHANCED)
    {
        ui8_drive |= DRIVE_ENHANCED_DENSITY;
    }
/* the last write hit the write protection */
    if (g_i32_wperr != 0)
    {
        ui8_drive |= DRIVE_WRITE_PROTECT_ERROR;
    }
    aui8_status[STATUS_DRIVE] = ui8_drive;
/* no FDC error, the format timeout, 0 */
    aui8_status[STATUS_FDC] = FDC_NO_ERROR;
    aui8_status[STATUS_TIMEOUT] = FORMAT_TIMEOUT;
    aui8_status[STATUS_UNUSED] = 0;
/* Complete, then the four bytes */
    tx_result(SIO_COMPLETE);
    tx_frame(aui8_status, STATUS_LEN);
}

/* command $52: read a sector */
static void cmd_read(uint32_t ui32_sec)
{
/* local variables */
    uint32_t ui32_len;
    int32_t i32_result;

/* start values */
    ui32_len = 0;
    i32_result = SEC_OK;
    if ((ui32_sec < SEC_FIRST) || (ui32_sec > g_ui32_nsec))
    {
/* no such sector */
        tx(SIO_NAK);
    }
    else
    {
        tx(SIO_ACK);
/* the sector, read */
        ui32_len = sec_len(ui32_sec);
        i32_result = read_sec(ui32_sec, g_aui8_buf);
/* Complete or Error, then the data in both cases */
        tx_result(result_byte(i32_result));
        tx_frame(g_aui8_buf, (int32_t)ui32_len);
    }
}

/* commands $50 / $57: put / write a sector */
static void cmd_write(uint32_t ui32_sec)
{
/* local variables */
    uint32_t ui32_len;
    int32_t i32_result;

/* start values */
    ui32_len = 0;
    i32_result = SEC_OK;
    if ((ui32_sec < SEC_FIRST) || (ui32_sec > g_ui32_nsec))
    {
/* no such sector */
        tx(SIO_NAK);
    }
    else
    {
        tx(SIO_ACK);
/* the data frame from the computer */
        ui32_len = sec_len(ui32_sec);
        i32_result = rx_frame(g_aui8_buf, (int32_t)ui32_len);
        if (i32_result == RX_BAD_SUM)
        {
/* bad checksum: NAK, command ends */
            wait_us(DATA_ACK_DELAY_US);
            tx(SIO_NAK);
        }
        else if (i32_result != RX_OK)
        {
/* no data frame: the computer retries */
        }
        else
        {
/* 850 us-16 ms after the frame: the second ACK, then the write and its result */
            wait_us(DATA_ACK_DELAY_US);
            tx(SIO_ACK);
/* a read-only disk refuses the write */
            g_i32_wperr = g_i32_ro;
            if (g_i32_ro != 0)
            {
                i32_result = SEC_ERROR;
            }
/* the FPGA is gone */
            else if (link_alive() == 0)
            {
/* the FPGA is gone: nothing must be written */
                i32_result = SEC_ERROR;
            }
            else
            {
                i32_result = write_sec(ui32_sec, g_aui8_buf);
            }
            tx_result(result_byte(i32_result));
        }
    }
}

/* commands $21 / $22: format (sectors filled with 0; the answer says "no bad sectors") */
static void cmd_format(void)
{
/* local variables */
    uint32_t ui32_len;
    uint32_t ui32_index;
    int32_t i32_result;

/* start values */
    ui32_len = 0;
    ui32_index = 0;
    i32_result = SEC_OK;
/* accepted */
    tx(SIO_ACK);
    g_i32_wperr = g_i32_ro;
    if (g_i32_ro != 0)
    {
/* a read-only disk is not formatted */
        i32_result = SEC_ERROR;
    }
    else
    {
/* every sector filled with 0 */
        for (ui32_index = 0; ui32_index < SEC_DOUBLE; ui32_index++)
        {
            g_aui8_buf[ui32_index] = 0;
        }
/* sector by sector */
        for (ui32_index = SEC_FIRST; (ui32_index <= g_ui32_nsec) && (i32_result == SEC_OK); ui32_index++)
        {
            i32_result = write_sec(ui32_index, g_aui8_buf);
        }
    }
/* bad sector list: empty ($FFFF first), in a buffer of one sector */
    ui32_len = sec_len(SEC_AFTER_BOOT);
    for (ui32_index = 0; ui32_index < ui32_len; ui32_index++)
    {
        g_aui8_buf[ui32_index] = FDC_NO_ERROR;
    }
/* the result, then the list */
    tx_result(result_byte(i32_result));
    tx_frame(g_aui8_buf, (int32_t)ui32_len);
}

/* a complete command frame: answer it if it is for D1: */
static void command(void)
{
    uint32_t ui32_sec;

    ui32_sec = (uint32_t)g_aui8_cf[CF_AUX1] | ((uint32_t)g_aui8_cf[CF_AUX2] << SHIFT_BYTE);
/* another device, or a bad frame: no answer */
    if ((g_aui8_cf[CF_DEVICE] == DEV_D1) && (csum(g_aui8_cf, CF_DATA_LEN) == g_aui8_cf[CF_CHECKSUM]))
    {
        switch (g_aui8_cf[CF_COMMAND])
        {
/* the drive's status */
        case SIO_CMD_STATUS:
            cmd_status();
            break;
/* read a sector */
        case SIO_CMD_READ:
            cmd_read(ui32_sec);
            break;
/* write a sector, with or without verify */
        case SIO_CMD_PUT:
        case SIO_CMD_WRITE:
/* the same routine for both */
            cmd_write(ui32_sec);
            break;
/* format, single or medium density */
        case SIO_CMD_FORMAT:
        case SIO_CMD_FORMAT_MEDIUM:
/* one routine again */
            cmd_format();
            break;
        default:
/* a command this drive does not know */
            tx(SIO_NAK);
            break;
        }
    }
}

/* OPTION released */
static void noba_off(void)
{
    g_i32_noba = 0;
    MCTL = g_ui32_cart << MC_CART_SHIFT;
}

/* main loop: answers the Atari's SIO commands for D1: */
void at_service(void)
{
/* local variables */
    uint32_t ui32_status;
    int32_t i32_count;
/* more to read, the FPGA is gone */
    bool b_more;
    bool b_gone;

/* start values */
    ui32_status = 0;
    i32_count = 0;
/* going on */
    b_more = true;
    b_gone = false;
/* OPTION is released after a while even if no SIO command comes */
    if ((g_i32_noba != 0) && ((TIMER - g_ui32_noba_t0) > (NOBA_MS * CLK_PER_MS)))
    {
        noba_off();
    }
    if (g_i32_on != 0)
    {
/* the bytes received: those of a command frame are collected */
        while ((i32_count < EVENTS_PER_CALL) && b_more)
        {
            ui32_status = MCTL;
            if (ui32_status == ALL_ONES)
            {
/* a gone FPGA reads all ones */
                b_gone = true;
                b_more = false;
            }
/* nothing more received */
            else if ((ui32_status & ST_VALID) == 0)
            {
                b_more = false;
            }
            else
            {
/* taken; a command byte goes into the frame */
                MCLR = CL_POP;
                if ((ui32_status & ST_CMD) != 0)
                {
/* the first byte starts a new frame */
                    if ((ui32_status & ST_FIRST) != 0)
                    {
                        g_i32_cn = 0;
                    }
/* kept while the frame has room */
                    if (g_i32_cn < CF_LEN)
                    {
                        g_aui8_cf[g_i32_cn] = (uint8_t)ui32_status;
                        g_i32_cn++;
                    }
                }
/* one more byte handled */
                i32_count++;
            }
        }
/* frame complete, command line raised */
        if (!b_gone && (g_i32_cn == CF_LEN) && ((ui32_status & ST_CMDNOW) == 0))
        {
            g_i32_cn = 0;
/* the OS has checked OPTION long ago */
            if (g_i32_noba != 0)
            {
                noba_off();
            }
            command();
        }
    }
}

/* cold start (the cartridge out), OPTION held for "No BASIC" */
static void cold_start(int32_t i32_basic)
{
    g_ui32_cart = 0;
    g_i32_noba = 0;
/* without BASIC */
    if (i32_basic == 0)
    {
        g_i32_noba = YES;
    }
    g_ui32_noba_t0 = TIMER;
/* 19,200 baud; OPTION held or not */
    if (g_i32_noba != 0)
    {
        MCTL = MC_OPTION;
    }
    else
    {
        MCTL = 0u;
    }
/* the receiver emptied, the machine started */
    MCLR = CL_FLUSH;
    RELOAD = YES;
}

/* read the first bytes of a file into a buffer: FAT_OK or FAT_EIO */
static int32_t read_head(FFILE *ps_file, uint8_t *pui8_dst, uint32_t ui32_count)
{
/* local variables */
    uint32_t ui32_index;
    int32_t i32_char;
    int32_t i32_result;

/* start values */
    ui32_index = 0;
    i32_char = 0;
    i32_result = FAT_OK;
/* from the file's start */
    ff_seek(ps_file, 0);
    while ((ui32_index < ui32_count) && (i32_result == FAT_OK))
    {
        i32_char = ff_getc(ps_file);
/* the card failed, or the file is too short */
        if (i32_char < 0)
        {
            i32_result = FAT_EIO;
        }
        else
        {
/* one more byte */
            pui8_dst[ui32_index] = (uint8_t)i32_char;
            ui32_index++;
        }
    }
    return i32_result;
}

/* Insert an .atr into D1: AT_OK, AT_EBAD, FAT_EIO */
int32_t at_atr_mount(const FFILE *ps_file, const char *pc_name, int32_t i32_ro, int32_t i32_boot, int32_t i32_basic)
{
/* local variables */
    uint8_t aui8_hdr[ATR_HDR_LEN];
    uint32_t ui32_bytes;
    uint32_t ui32_ssz;
/* sectors, a copy of the file, the result */
    uint32_t ui32_nsec;
    FFILE s_try;
    int32_t i32_result;

/* start values */
    ui32_bytes = 0;
    ui32_ssz = 0;
    ui32_nsec = 0;
/* checked on a copy first: the disk in stays valid */
    u_memcpy(&s_try, ps_file, sizeof s_try);
    i32_result = read_head(&s_try, aui8_hdr, ATR_HDR_LEN);
/* the magic bytes */
    if ((i32_result == AT_OK) && ((aui8_hdr[0] != ATR_MAGIC_0) || (aui8_hdr[ATR_MAGIC_1_OFF] != ATR_MAGIC_1)))
    {
        i32_result = AT_EBAD;
    }
/* size and sector size */
    if (i32_result == AT_OK)
    {
        ui32_bytes = ((uint32_t)aui8_hdr[ATR_SIZE_LOW] | ((uint32_t)aui8_hdr[ATR_SIZE_MID] << SHIFT_BYTE) |
                      ((uint32_t)aui8_hdr[ATR_SIZE_HIGH] << SHIFT_WORD)) * ATR_PARAGRAPH;
/* the sector size */
        ui32_ssz = (uint32_t)aui8_hdr[ATR_SECSIZE_LOW] | ((uint32_t)aui8_hdr[ATR_SECSIZE_HIGH] << SHIFT_BYTE);
        if ((ui32_ssz != SEC_SINGLE) && (ui32_ssz != SEC_DOUBLE))
        {
            i32_result = AT_EBAD;
        }
    }
/* so far a valid header */
    if (i32_result == AT_OK)
    {
/* old writers: header size too big, the file counts */
        if ((ATR_HDR_LEN + ui32_bytes) > ps_file->ui32_size)
        {
            ui32_bytes = ps_file->ui32_size - ATR_HDR_LEN;
        }
/* the number of sectors: the first three are 128 bytes in every density */
        if ((ui32_ssz == SEC_SINGLE) || (ui32_bytes <= BOOT_BYTES))
        {
            ui32_nsec = ui32_bytes / SEC_SINGLE;
        }
        else
        {
            ui32_nsec = BOOT_SECTORS + ((ui32_bytes - BOOT_BYTES) / SEC_DOUBLE);
        }
/* no sectors, or more than the file holds */
        if ((ui32_nsec == 0) || ((ATR_HDR_LEN + ui32_bytes) > ps_file->ui32_size))
        {
            i32_result = AT_EBAD;
        }
    }
/* the disk goes in */
    if (i32_result == AT_OK)
    {
        u_memcpy(&g_s_file, &s_try, sizeof g_s_file);
        g_i32_xex = 0;
/* its geometry */
        g_ui32_ssz = ui32_ssz;
        g_ui32_nsec = ui32_nsec;
/* read only or not; no write error yet */
        g_i32_ro = 0;
        if (i32_ro != 0)
        {
            g_i32_ro = YES;
        }
/* no write error, the disk is in */
        g_i32_wperr = 0;
        g_i32_on = YES;
/* no command frame yet; its name */
        g_i32_cn = 0;
        u_strncpy(g_ac_name, pc_name, NAME_MAX);
/* without boot it is a disk change only, as a real drive's door; */
/* with boot the OS boots from D1: (cartridge out) */
        if (i32_boot != 0)
        {
            cold_start(i32_basic);
        }
    }
    return i32_result;
}

/* Run an .xex as a read-only boot disk: AT_OK, AT_EBAD (no $FFFF header), FAT_EIO */
int32_t at_xex_mount(const FFILE *ps_file, const char *pc_name)
{
/* local variables */
    int32_t i32_first;
    int32_t i32_second;
/* a copy of the file, the result */
    FFILE s_try;
    int32_t i32_result;

    i32_result = AT_OK;
/* checked on a copy first: the disk in stays valid */
    u_memcpy(&s_try, ps_file, sizeof s_try);
    ff_seek(&s_try, 0);
/* the first two bytes */
    i32_first = ff_getc(&s_try);
    i32_second = ff_getc(&s_try);
    if ((i32_first < 0) || (i32_second < 0))
    {
/* the card failed */
        i32_result = FAT_EIO;
    }
    else if ((i32_first != XEX_MAGIC) || (i32_second != XEX_MAGIC) || (ps_file->ui32_size < XEX_MIN_SIZE))
    {
/* a binary load file starts with $FFFF */
        i32_result = AT_EBAD;
    }
    else
    {
/* the file becomes the disk */
        u_memcpy(&g_s_file, &s_try, sizeof g_s_file);
        g_ui32_xlen = ps_file->ui32_size;
        g_i32_xex = YES;
/* the virtual disk: three loader sectors, then the file */
        g_ui32_ssz = SEC_SINGLE;
        g_ui32_nsec = BOOT_SECTORS + ((ps_file->ui32_size + SEC_ROUND_UP) / SEC_SINGLE);
        g_i32_ro = YES;
/* no write error, the disk is in */
        g_i32_wperr = 0;
        g_i32_on = YES;
/* no command frame yet; its name */
        g_i32_cn = 0;
        u_strncpy(g_ac_name, pc_name, NAME_MAX);
/* the OS boots the loader (it switches BASIC off) */
        cold_start(YES);
    }
    return i32_result;
}

/* length and FPGA mode of a cartridge type; a mode of 0 = type not supported */
static uint32_t car_mode(uint32_t ui32_type, uint32_t *pui32_len)
{
/* local variables */
    uint32_t ui32_mode;

/* start values */
    ui32_mode = 0;
    switch (ui32_type)
    {
    case CAR_STD_8K:
/* 8 KB */
        *pui32_len = LEN_8K;
        ui32_mode = MODE_STD_8K;
        break;
/* standard 16 KB */
    case CAR_STD_16K:
        *pui32_len = LEN_16K;
        ui32_mode = MODE_STD_16K;
/* the bank-switched kinds from here */
        break;
    case CAR_ATARIMAX_128K:
        *pui32_len = LEN_128K;
/* its mode */
        ui32_mode = MODE_ATARIMAX_128K;
        break;
    case CAR_ATARIMAX_1M_OLD:
/* 1 MB, old layout */
        *pui32_len = LEN_1M;
        ui32_mode = MODE_ATARIMAX_1M_OLD;
        break;
/* 1 MB, new layout */
    case CAR_ATARIMAX_1M_NEW:
        *pui32_len = LEN_1M;
        ui32_mode = MODE_ATARIMAX_1M_NEW;
/* any other type: mode 0, not supported */
        break;
    default:
/* a type this machine does not have */
        break;
    }
    return ui32_mode;
}

/* Insert a .car cartridge and cold-start into it: AT_OK, AT_EBAD, AT_ETYPE, FAT_EIO */
int32_t at_car_mount(const FFILE *ps_file, const char *pc_name)
{
/* local variables */
    uint8_t aui8_hdr[CAR_HDR_LEN];
    uint32_t ui32_type;
    uint32_t ui32_len;
/* a byte counter, the FPGA's mode, an SDRAM address */
    uint32_t ui32_index;
    uint32_t ui32_mode;
    uint32_t ui32_addr;
/* through the window, a character */
    bool b_window;
    int32_t i32_char;
/* a copy of the file, the result */
    FFILE s_car;
    int32_t i32_result;

/* start values */
    ui32_type = 0;
    ui32_len = 0;
    ui32_index = 0;
/* nothing known yet */
    ui32_mode = 0;
    ui32_addr = 0;
    b_window = false;
/* the header, read from a copy */
    i32_char = 0;
    u_memcpy(&s_car, ps_file, sizeof s_car);
    i32_result = read_head(&s_car, aui8_hdr, CAR_HDR_LEN);
/* "CART", then the type */
    if ((i32_result == AT_OK) && (u_memcmp(aui8_hdr, "CART", CAR_MAGIC_LEN) != 0))
    {
        i32_result = AT_EBAD;
    }
/* the type, big-endian */
    if (i32_result == AT_OK)
    {
        ui32_type = ((uint32_t)aui8_hdr[CAR_TYPE_0] << SHIFT_3_BYTES) | ((uint32_t)aui8_hdr[CAR_TYPE_1] << SHIFT_WORD) |
                    ((uint32_t)aui8_hdr[CAR_TYPE_2] << SHIFT_BYTE) | aui8_hdr[CAR_TYPE_3];
        ui32_mode = car_mode(ui32_type, &ui32_len);
/* a type the FPGA does not have */
        if (ui32_mode == 0)
        {
            i32_result = AT_ETYPE;
        }
/* shorter than its type says */
        else if (ps_file->ui32_size < (CAR_HDR_LEN + ui32_len))
        {
/* the file is shorter than the cartridge */
            i32_result = AT_EBAD;
        }
        else
        {
/* a cartridge this machine can take */
        }
    }
    if (i32_result == AT_OK)
    {
        g_ui32_cart = 0;
        g_i32_noba = 0;
/* Atarimax: through the cartridge window; not mapped while it is written */
        b_window = ui32_mode >= MODE_ATARIMAX_128K;
        MCTL = 0;
        while ((ui32_index < ui32_len) && (i32_result == AT_OK))
        {
/* next 256 KB page */
            if (b_window && ((ui32_index & WINDOW_MASK) == 0))
            {
                MCTL = MC_WINDOW | ((ui32_index >> WINDOW_SHIFT) << MC_WINDOW_PAGE_SHIFT);
            }
/* the next byte */
            i32_char = ff_getc(&s_car);
            if (i32_char < 0)
            {
/* the card failed: the window is closed */
                MCTL = 0;
                i32_result = FAT_EIO;
            }
            else
            {
/* into the SDRAM, through the window or at the cartridge's own place */
                ui32_addr = CART_BASE + ui32_index;
                if (b_window)
                {
                    ui32_addr = ui32_index & WINDOW_MASK;
                }
/* one byte written */
                snap_cmd(C_MWR, ui32_addr, (uint32_t)i32_char);
                ui32_index++;
            }
        }
    }
/* the cartridge is in: no disk, and the Atari cold-starts into it */
    if (i32_result == AT_OK)
    {
        g_ui32_cart = ui32_mode;
        g_i32_on = 0;
/* its name */
        u_strncpy(g_ac_cart_name, pc_name, NAME_MAX);
        MCTL = g_ui32_cart << MC_CART_SHIFT;
        MCLR = CL_FLUSH;
/* the machine restarts */
        RELOAD = YES;
    }
    return i32_result;
}

/* take the disk out */
void at_atr_eject(void)
{
    g_i32_on = 0;
}

/* "D1: NAME" into pc_text while a disk is in: AT_DISK_IN, else 0 */
int32_t at_status(char *pc_text)
{
/* local variables */
    int32_t i32_result;

/* start values */
    i32_result = 0;
    if (g_i32_on != 0)
    {
/* the drive and the disk's name */
        u_strncpy(u_strcpy(pc_text, "D1: "), g_ac_name, STATUS_NAME_LEN);
        i32_result = AT_DISK_IN;
    }
    return i32_result;
}

/* Print Screen: the frame buffer's newest frame as a 256-colour BMP: AT_OK, FAT_* */
int32_t at_screenshot(uint32_t ui32_dir, const char ac_name11[FAT_NAME11_LEN])
{
/* local variables */
    uint8_t *pui8_row;
    int32_t i32_y;
    int32_t i32_x;
/* the result of closing, the result */
    int32_t i32_end;
    int32_t i32_result;

/* not static: RAM for the Bluetooth stack */
    pui8_row = (uint8_t *)malloc(SHOT_WIDTH);
    i32_y = SHOT_LAST_ROW;
    i32_x = 0;
/* no memory unless the row was got */
    i32_end = FAT_OK;
    i32_result = FAT_EIO;
    if (pui8_row != NULL)
    {
/* hold the frame buffers while the picture is read, bottom row first */
        snap_cmd(C_CTL, 0, CTL_HOLD_FB);
        i32_result = shot_begin8(ui32_dir, ac_name11, SHOT_WIDTH, SHOT_HEIGHT, atari_pal);
        while ((i32_y >= 0) && (i32_result == FAT_OK))
        {
/* a row, pixel by pixel */
            for (i32_x = 0; i32_x < SHOT_WIDTH; i32_x++)
            {
                pui8_row[i32_x] = (uint8_t)snap_cmd(C_MRD, ((uint32_t)i32_y * FB_LINE_BYTES) + (uint32_t)i32_x, 0);
            }
/* into the file */
            i32_result = shot_row(pui8_row);
            i32_y--;
        }
/* the frame buffers run again */
        snap_cmd(C_CTL, 0, 0);
        free(pui8_row);
/* the file is closed, or deleted after an error; the first error is the result */
        i32_end = shot_end();
        if (i32_result == FAT_OK)
        {
/* the error of closing */
            i32_result = i32_end;
        }
    }
    return i32_result;
}

/* snapshots (.A8S) */

/* length of a snapshot file of a model */
static uint32_t a8s_size(int32_t i32_model130)
{
/* local variables */
    uint32_t ui32_size;

/* start values */
    ui32_size = A8S_HDR + SH_LEN + RAM_800;
    if (i32_model130 != 0)
    {
/* the 130XE */
        ui32_size = A8S_HDR + SH_LEN + RAM_130;
    }
    return ui32_size;
}

/* stop the Atari at an instruction boundary: AT_OK or AT_ERUN */
int32_t at_snap_freeze(void)
{
/* local variables */
    uint32_t ui32_start;
    int32_t i32_result;

/* start values */
    ui32_start = TIMER;
    i32_result = AT_OK;
/* ask for the stop, and wait for it */
    SNAPCTL = CTL_FREEZE;
    while ((i32_result == AT_OK) && ((SNAPCTL & SNAP_FROZEN) == 0))
    {
/* a CPU that is not running never gets there */
        if ((TIMER - ui32_start) > (FREEZE_MS * CLK_PER_MS))
        {
/* released, with an error */
            SNAPCTL = 0;
            i32_result = AT_ERUN;
        }
    }
    return i32_result;
}

/* the Atari runs on */
void at_snap_resume(void)
{
    SNAPCTL = 0;
}

/* the CPU's, the PIA's and the cartridge's state into the header buffer */
void at_snap_capture(void)
{
/* local variables */
    uint32_t ui32_cpu;
    uint32_t ui32_cpu2;
    uint32_t ui32_pia_a;
/* PIA port B, the machine word */
    uint32_t ui32_pia_b;
    uint32_t ui32_machine;

/* start values */
    ui32_cpu = snap_cmd(C_REG, REG_CPU, 0);
    ui32_cpu2 = snap_cmd(C_REG, REG_CPU2, 0);
    ui32_pia_a = snap_cmd(C_REG, REG_PIA_A, 0);
/* PIA port B, the machine word */
    ui32_pia_b = snap_cmd(C_REG, REG_PIA_B, 0);
    ui32_machine = snap_cmd(C_REG, REG_MACHINE, 0);
/* magic, version, model (1 = 130XE) */
    u_memset(g_aui8_hdr, 0, sizeof g_aui8_hdr);
    u_memcpy(g_aui8_hdr, "LTARISNP", A8S_MAGIC_LEN);
/* version and model */
    g_aui8_hdr[A8S_VERSION_OFF] = A8S_VERSION;
    g_aui8_hdr[A8S_MODEL] = (uint8_t)((ui32_machine >> M_MODEL_SHIFT) & BIT_MASK);
/* A, X, Y, P */
    g_aui8_hdr[A8S_A] = (uint8_t)ui32_cpu;
    g_aui8_hdr[A8S_X] = (uint8_t)(ui32_cpu >> SHIFT_BYTE);
/* Y and P */
    g_aui8_hdr[A8S_Y] = (uint8_t)(ui32_cpu >> SHIFT_WORD);
    g_aui8_hdr[A8S_P] = (uint8_t)(ui32_cpu >> SHIFT_3_BYTES);
/* S, PC */
    g_aui8_hdr[A8S_S] = (uint8_t)ui32_cpu2;
    g_aui8_hdr[A8S_PCL] = (uint8_t)(ui32_cpu2 >> SHIFT_WORD);
    g_aui8_hdr[A8S_PCH] = (uint8_t)(ui32_cpu2 >> SHIFT_3_BYTES);
/* ORA DDRA PACTL */
    g_aui8_hdr[A8S_ORA] = (uint8_t)ui32_pia_a;
    g_aui8_hdr[A8S_DDRA] = (uint8_t)(ui32_pia_a >> SHIFT_BYTE);
    g_aui8_hdr[A8S_PACTL] = (uint8_t)(ui32_pia_a >> SHIFT_WORD);
/* ORB DDRB PBCTL */
    g_aui8_hdr[A8S_ORB] = (uint8_t)ui32_pia_b;
    g_aui8_hdr[A8S_DDRB] = (uint8_t)(ui32_pia_b >> SHIFT_BYTE);
    g_aui8_hdr[A8S_PBCTL] = (uint8_t)(ui32_pia_b >> SHIFT_WORD);
/* cartridge type (MCTL [18:16]), Atarimax bank, Atarimax off */
    g_aui8_hdr[A8S_CART] = (uint8_t)(ui32_machine & M_CART_MASK);
    g_aui8_hdr[A8S_BANK] = (uint8_t)((ui32_machine >> M_BANK_SHIFT) & M_BANK_MASK);
    g_aui8_hdr[A8S_BANK_OFF] = (uint8_t)((ui32_machine >> M_BANK_OFF_SHIFT) & BIT_MASK);
/* a disk in D1: (an .xex's virtual disk does not count) */
    g_aui8_hdr[A8S_DISK_IN] = 0;
    if ((g_i32_on != 0) && (g_i32_xex == 0))
    {
        g_aui8_hdr[A8S_DISK_IN] = YES;
    }
/* the names of the cartridge and of the disk */
    if ((ui32_machine & M_CART_MASK) != 0)
    {
        u_strncpy((char *)g_aui8_hdr + A8S_CART_NAME, g_ac_cart_name, SNAP_NAME_LEN);
    }
/* the disk's */
    if (g_aui8_hdr[A8S_DISK_IN] != 0)
    {
        u_strncpy((char *)g_aui8_hdr + A8S_DISK_NAME, g_ac_name, SNAP_NAME_LEN);
    }
}

/* the captured state, the I/O shadow and the RAM as a new file: FAT_* */
int32_t at_snap_save(uint32_t ui32_dir, const char ac_name11[FAT_NAME11_LEN])
{
/* local variables */
    uint32_t ui32_index;
    uint32_t ui32_ram;
    int32_t i32_result;

/* start values */
    ui32_index = 0;
/* the 130XE has 64 KB of extended memory */
    ui32_ram = RAM_800;
    if (g_aui8_hdr[A8S_MODEL] != 0)
    {
        ui32_ram = RAM_130;
    }
/* the file */
    i32_result = fw_create(&g_s_fw_file, ui32_dir, ac_name11);
    if (i32_result == FAT_OK)
    {
/* the header */
        for (ui32_index = 0; (ui32_index < A8S_HDR) && (i32_result == FAT_OK); ui32_index++)
        {
            i32_result = fw_putc(&g_s_fw_file, g_aui8_hdr[ui32_index]);
        }
/* the I/O shadow */
        for (ui32_index = 0; (ui32_index < SH_LEN) && (i32_result == FAT_OK); ui32_index++)
        {
            i32_result = fw_putc(&g_s_fw_file, (uint8_t)snap_cmd(C_MRD, SH_BASE + ui32_index, 0));
        }
/* the RAM */
        for (ui32_index = 0; (ui32_index < ui32_ram) && (i32_result == FAT_OK); ui32_index++)
        {
            i32_result = fw_putc(&g_s_fw_file, (uint8_t)snap_cmd(C_MRD, ui32_index, 0));
        }
/* a failed write leaves no file */
        if (i32_result != FAT_OK)
        {
            fw_discard(&g_s_fw_file);
        }
        else
        {
/* complete: the directory entry is written */
            i32_result = fw_close(&g_s_fw_file);
        }
    }
    return i32_result;
}

/* restore program: one byte into the bank */
static void e8(uint8_t ui8_byte)
{
    snap_cmd(C_MWR, RB_BASE + g_ui32_stub_pc, ui8_byte);
    g_ui32_stub_pc++;
}

/* restore program: LDA #value / STA address */
static void e_sta(uint8_t ui8_value, uint32_t ui32_addr)
{
    e8(OP_LDA_IMM);
    e8(ui8_value);
/* the address, low byte first */
    e8(OP_STA_ABS);
    e8((uint8_t)ui32_addr);
    e8((uint8_t)(ui32_addr >> SHIFT_BYTE));
}

/* PIA port: DDR (control bit 2 = 0), then the output register, then the control register */
static void e_pia(uint32_t ui32_port, uint32_t ui32_ctl, uint8_t ui8_ddr, uint8_t ui8_out, uint8_t ui8_ctl)
{
    e_sta((uint8_t)(ui8_ctl & PIA_CTL_DDR), ui32_ctl);
    e_sta(ui8_ddr, ui32_port);
/* the port register instead of the DDR */
    e_sta((uint8_t)((ui8_ctl & PIA_CTL_MASK) | PIA_CTL_PORT), ui32_ctl);
    e_sta(ui8_out, ui32_port);
    e_sta((uint8_t)(ui8_ctl & PIA_CTL_MASK), ui32_ctl);
}

/* write the restore program into the restore bank: every chip back to its state, then RTI */
static void emit_restore(uint32_t ui32_type)
{
/* local variables */
    uint32_t ui32_index;
    uint32_t ui32_addr;
    uint8_t ui8_stack;

/* start values */
    ui32_index = 0;
    ui32_addr = 0;
    ui8_stack = g_aui8_hdr[A8S_S];
/* reset vector -> the program */
    snap_cmd(C_MWR, RB_BASE + VEC_RESET_LOW, STUB & SUM_MASK);
    snap_cmd(C_MWR, RB_BASE + VEC_RESET_HIGH, STUB >> SHIFT_BYTE);
    g_ui32_stub_pc = STUB;
/* SEI, CLD; NMIEN off until the end */
    e8(OP_SEI);
    e8(OP_CLD);
    e_sta(0, ANTIC_NMIEN);
/* POKEY: SKCTL init, AUDCTL, AUDF / AUDC 1-4, IRQEN, SKCTL, STIMER */
    e_sta(0, POKEY_SKCTL);
    e_sta(g_pui8_shadow[SH_POKEY_AUDCTL], POKEY_AUDCTL);
/* the four channels' frequency and control */
    for (ui32_index = 0; ui32_index < POKEY_AUDIO_REGS; ui32_index++)
    {
        e_sta(g_pui8_shadow[SH_POKEY + ui32_index], POKEY_BASE + ui32_index);
    }
/* interrupts, serial control, timers started */
    e_sta(g_pui8_shadow[SH_POKEY_IRQEN], POKEY_IRQEN);
    e_sta(g_pui8_shadow[SH_POKEY_SKCTL], POKEY_SKCTL);
    e_sta(0, POKEY_STIMER);
/* GTIA, HITCLR, CONSOL (speaker) */
    for (ui32_index = 0; ui32_index <= GTIA_REGS; ui32_index++)
    {
        e_sta(g_pui8_shadow[ui32_index], GTIA_BASE + ui32_index);
    }
/* collisions cleared, the console speaker */
    e_sta(0, GTIA_HITCLR);
    e_sta(g_pui8_shadow[SH_GTIA_CONSOL], GTIA_CONSOL);
/* the PIA's two ports, then ANTIC */
    e_pia(PIA_PORTA, PIA_PACTL, g_aui8_hdr[A8S_DDRA], g_aui8_hdr[A8S_ORA], g_aui8_hdr[A8S_PACTL]);
    e_pia(PIA_PORTB, PIA_PBCTL, g_aui8_hdr[A8S_DDRB], g_aui8_hdr[A8S_ORB], g_aui8_hdr[A8S_PBCTL]);
/* the ANTIC registers that can be written back */
    for (ui32_index = 0; ui32_index < ANTIC_RESTORED; ui32_index++)
    {
        e_sta(g_pui8_shadow[SH_ANTIC + g_aui8_antic[ui32_index]], ANTIC_BASE + g_aui8_antic[ui32_index]);
    }
/* Atarimax: any access to $D5xx selects the bank (or switches the cartridge off): LDA $D5xx */
    if (ui32_type >= MODE_ATARIMAX_128K)
    {
        ui32_addr = ATARIMAX_BASE + g_aui8_hdr[A8S_BANK];
/* or the address that switches it off */
        if (g_aui8_hdr[A8S_BANK_OFF] != 0)
        {
            if (ui32_type == MODE_ATARIMAX_128K)
            {
                ui32_addr += ATARIMAX_OFF_128K;
            }
            else
            {
/* 1 MB */
                ui32_addr += ATARIMAX_OFF_1M;
            }
        }
/* LDA at that address */
        e8(OP_LDA_ABS);
        e8((uint8_t)ui32_addr);
        e8((uint8_t)(ui32_addr >> SHIFT_BYTE));
    }
/* LDX #S-3, TXS; the stack for RTI: P, PCL, PCH */
    e8(OP_LDX_IMM);
    e8((uint8_t)(ui8_stack - STACK_RTI_FRAME));
    e8(OP_TXS);
/* P, PCL, PCH where RTI finds them */
    e_sta(g_aui8_hdr[A8S_P], STACK_PAGE + (uint8_t)(ui8_stack - STACK_P));
    e_sta(g_aui8_hdr[A8S_PCL], STACK_PAGE + (uint8_t)(ui8_stack - STACK_PCL));
    e_sta(g_aui8_hdr[A8S_PCH], STACK_PAGE + ui8_stack);
/* NMIEN (NMIs stay masked until the RTI is done) */
    e_sta(g_pui8_shadow[SH_ANTIC_NMIEN], ANTIC_NMIEN);
/* LDA #A, LDX #X, LDY #Y, RTI */
    e8(OP_LDA_IMM);
    e8(g_aui8_hdr[A8S_A]);
/* X */
    e8(OP_LDX_IMM);
    e8(g_aui8_hdr[A8S_X]);
/* Y, and back into the program */
    e8(OP_LDY_IMM);
    e8(g_aui8_hdr[A8S_Y]);
    e8(OP_RTI);
}

/* run the restore program in restore mode: AT_OK or AT_ERUN */
static int32_t run_restore(void)
{
/* local variables */
    uint32_t ui32_start;
    int32_t i32_result;

/* start values */
    ui32_start = 0;
    i32_result = AT_OK;
/* restore mode, CPU in reset; the Atari runs again (CPU still in reset) */
    snap_cmd(C_CTL, 0, CTL_RESTORE_RESET);
    SNAPCTL = 0;
    ui32_start = TIMER;
/* one millisecond of reset */
    while ((TIMER - ui32_start) < CLK_PER_MS)
    {
    }
/* CPU out of reset: vector, program, RTI */
    snap_cmd(C_CTL, 0, CTL_RESTORE_RUN);
    ui32_start = TIMER;
    while ((i32_result == AT_OK) && ((snap_cmd(C_CTL, 0, CTL_RESTORE_RUN) & CTL_RESTORE_BUSY) != 0))
    {
/* the program did not reach its end */
        if ((TIMER - ui32_start) > (RESTORE_MS * CLK_PER_MS))
        {
            i32_result = AT_ERUN;
        }
    }
/* restore mode off */
    snap_cmd(C_CTL, 0, 0);
    return i32_result;
}

/* read bytes of the snapshot file: into a buffer, or (pui8_dst NULL) into the Atari's RAM from address 0 */
static int32_t load_bytes(FFILE *ps_file, uint8_t *pui8_dst, uint32_t ui32_count)
{
/* local variables */
    uint32_t ui32_index;
    int32_t i32_char;
    int32_t i32_result;

/* start values */
    ui32_index = 0;
    i32_char = 0;
    i32_result = AT_OK;
/* byte by byte */
    while ((ui32_index < ui32_count) && (i32_result == AT_OK))
    {
        i32_char = ff_getc(ps_file);
        if (i32_char < 0)
        {
/* the card failed, or the file is too short */
            i32_result = FAT_EIO;
        }
        else
        {
/* a buffer or the machine's memory */
            if (pui8_dst != NULL)
            {
                pui8_dst[ui32_index] = (uint8_t)i32_char;
            }
            else
            {
/* the machine's memory */
                snap_cmd(C_MWR, ui32_index, (uint32_t)i32_char);
            }
            ui32_index++;
        }
    }
    return i32_result;
}

/* load a snapshot (the shadow buffer exists) */
static int32_t snap_load(FFILE *ps_file, char *pc_disk)
{
/* local variables */
    uint32_t ui32_ram;
    uint32_t ui32_machine;
/* the cartridge type, the result */
    uint32_t ui32_type;
    int32_t i32_result;

/* start values */
    ui32_ram = RAM_800;
    ui32_machine = 0;
/* no cartridge type, no disk name */
    ui32_type = 0;
    pc_disk[0] = 0;
/* the header: magic, version, and the file's length for its model */
    i32_result = load_bytes(ps_file, g_aui8_hdr, A8S_HDR);
    if ((i32_result == AT_OK) &&
        ((u_memcmp(g_aui8_hdr, "LTARISNP", A8S_MAGIC_LEN) != 0) || (g_aui8_hdr[A8S_VERSION_OFF] != A8S_VERSION) ||
         (ps_file->ui32_size != a8s_size(g_aui8_hdr[A8S_MODEL]))))
    {
        i32_result = AT_EBAD;
    }
/* the snapshot must be of this model */
    if (i32_result == AT_OK)
    {
        ui32_machine = snap_cmd(C_REG, REG_MACHINE, 0);
        if ((uint32_t)g_aui8_hdr[A8S_MODEL] != ((ui32_machine >> M_MODEL_SHIFT) & BIT_MASK))
        {
/* another model */
            i32_result = AT_EMODEL;
        }
    }
/* and its cartridge must be in */
    if (i32_result == AT_OK)
    {
        ui32_type = g_aui8_hdr[A8S_CART];
        if ((ui32_type != 0) &&
            ((g_ui32_cart != ui32_type) || (u_stricmp(g_ac_cart_name, (const char *)g_aui8_hdr + A8S_CART_NAME) != 0)))
        {
/* the cartridge to load first */
            u_strncpy(pc_disk, (const char *)g_aui8_hdr + A8S_CART_NAME, SNAP_NAME_LEN);
            i32_result = AT_ECART;
        }
    }
/* stop the Atari */
    if (i32_result == AT_OK)
    {
        if (g_aui8_hdr[A8S_MODEL] != 0)
        {
            ui32_ram = RAM_130;
        }
/* it must stop */
        if (at_snap_freeze() != AT_OK)
        {
            i32_result = AT_ERUN;
        }
    }
/* I/O shadow into the buffer, RAM (+ extended) into the machine; a card error lets the Atari run on */
    if (i32_result == AT_OK)
    {
        i32_result = load_bytes(ps_file, g_pui8_shadow, SH_LEN);
        if (i32_result == AT_OK)
        {
/* the RAM */
            i32_result = load_bytes(ps_file, NULL, ui32_ram);
        }
        if (i32_result != AT_OK)
        {
            SNAPCTL = 0;
        }
    }
/* everything is loaded */
    if (i32_result == AT_OK)
    {
/* the snapshot ran without the cartridge */
        if ((ui32_type == 0) && (g_ui32_cart != 0))
        {
            g_ui32_cart = 0;
/* no cartridge, no held OPTION */
            g_i32_noba = 0;
            MCTL = 0;
        }
/* the restore program, written and run */
        emit_restore(ui32_type);
        i32_result = run_restore();
    }
/* the program had this disk in D1: and another one (or none) is in now */
    if (i32_result == AT_OK)
    {
        if ((g_aui8_hdr[A8S_DISK_IN] != 0) &&
            ((g_i32_on == 0) || (g_i32_xex != 0) ||
             (u_stricmp(g_ac_name, (const char *)g_aui8_hdr + A8S_DISK_NAME) != 0)))
        {
/* its name for the caller */
            u_strncpy(pc_disk, (const char *)g_aui8_hdr + A8S_DISK_NAME, SNAP_NAME_LEN);
        }
    }
    return i32_result;
}

/* load a snapshot: AT_OK, AT_EBAD, AT_EMODEL, AT_ECART, AT_ERUN, FAT_EIO */
int32_t at_snap_load(FFILE *ps_file, char *pc_disk)
{
    int32_t i32_result;

    i32_result = FAT_EIO;
/* the shadow's buffer only while a snapshot loads */
    g_pui8_shadow = (uint8_t *)malloc(SH_LEN);
    if (g_pui8_shadow != NULL)
    {
        i32_result = snap_load(ps_file, pc_disk);
/* the buffer goes back */
        free(g_pui8_shadow);
        g_pui8_shadow = NULL;
    }
    return i32_result;
}

/* back to the state after a start: the next machine starts the loader again without an ESP32 */
/* restart (esp_hw.cpp; the Bluetooth connection stays) */
void at_reset(void)
{
    u_memset(g_ac_cart_name, 0, sizeof g_ac_cart_name);
    u_memset(&g_s_file, 0, sizeof g_s_file);
/* the disk */
    g_i32_on = 0;
    g_i32_ro = 0;
/* no write error, not an .xex */
    g_i32_wperr = 0;
    g_i32_xex = 0;
/* the cartridge and the disk's size */
    g_ui32_cart = 0;
    g_ui32_ssz = 0;
/* no sectors, no name */
    g_ui32_nsec = 0;
    u_memset(g_ac_name, 0, sizeof g_ac_name);
/* the buffers */
    u_memset(g_aui8_buf, 0, sizeof g_aui8_buf);
    u_memset(g_aui8_cf, 0, sizeof g_aui8_cf);
    g_i32_cn = 0;
/* the .xex and the OPTION key */
    g_ui32_xlen = 0;
    g_i32_noba = 0;
    g_ui32_noba_t0 = 0;
/* the snapshot */
    u_memset(g_aui8_hdr, 0, sizeof g_aui8_hdr);
    g_ui32_stub_pc = 0;
/* the shadow's buffer goes back */
    if (g_pui8_shadow != NULL)
    {
        free(g_pui8_shadow);
    }
    g_pui8_shadow = NULL;
}
