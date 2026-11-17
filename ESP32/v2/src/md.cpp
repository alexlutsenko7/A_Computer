/* md.cpp -- LMega (the Sega Mega Drive core): cartridge files, battery RAM (.sav) */
/* A cartridge is only memory: the file is written into the FPGA's SDRAM from address 0 on, then */
/* the cartridge word (MCTL) starts the machine (LMega/10cl025/rtl/LMega.v, md_mem.v): */
/*   MCTL: [0] 50 Hz console, [1] overseas (not Japan) model, [2] the cartridge has battery RAM, */
/*         [26:22] the 256 KB page of the memory commands, [31] cartridge in (the machine runs) */
/* SDRAM: 0x000000 cartridge ROM (4 MB), 0x420000 cartridge RAM (64 KB, the 68000's $200000). */
/* Files: .md / .gen / .bin are the ROM as it is. .smd has a 512-byte header (bytes 8 and 9 = */
/* $AA $BB) and blocks of 16 KB, each holding first the bytes of the odd addresses, then those */
/* of the even ones. */
/* The cartridge's own header ($100-$1FF of the ROM) says what the console must be: */
/*   $1B0 "RA", $1B4 / $1B8 first and last address of the battery RAM */
/*   $1F0 region: letters J / U / E, or one hex digit with bit 0 Japan, bit 2 America, bit 3 Europe */
#include <stdlib.h>
#include "hw.h"
#include "hal.h"
/* this module's header, the shared cartridge functions, string functions, the card */
#include "md.h"
#include "cart.h"
#include "util.h"
/* the card */
#include "fat.h"

/* yes, and one as an unsigned number */
#define YES 1
#define ONE 1u
/* the cartridge word */
#define MC_PAL (1u << 0)
#define MC_OVERSEAS (1u << 1)
#define MC_SRAM (1u << 2)
/* the page field's place */
#define MC_PAGE_SHIFT 22
#define MC_RUN (1u << 31)
/* SDRAM: cartridge RAM */
#define SD_SRAM 0x420000u
/* the most the core takes; the smallest file with a header */
#define ROM_MAX 0x400000u
#define ROM_MIN 0x200u
/* .smd: the header, its two marker bytes, a block and its half */
#define SMD_HDR 512u
#define SMD_MARK_AT 8
#define SMD_MARK_0 0xAAu
/* the second marker byte */
#define SMD_MARK_1 0xBBu
#define SMD_BLOCK 16384u
#define SMD_HALF 8192u
/* the bytes of a half lie two addresses apart */
#define SMD_STEP 2u
/* the cartridge's header: battery RAM */
#define HDR_RAM_MARK 0x1B0u
#define HDR_RAM_FIRST 0x1B4u
#define HDR_RAM_LAST 0x1B8u
/* the region characters */
#define HDR_REGION 0x1F0u
#define REGION_CHARS 3
/* the 68000's address range of battery RAM, the part of an address inside the 64 KB */
#define RAM_AREA_FIRST 0x200000u
#define RAM_AREA_LAST 0x3FFFFFu
#define RAM_OFFSET_MASK 0xFFFEu
/* its largest size */
#define RAM_MAX 0x10000u
/* region bits: Japan, America, Europe */
#define REG_JAPAN 1u
#define REG_AMERICA 4u
#define REG_EUROPE 8u
/* the value of the letter A */
#define HEX_LETTER_BASE 10u
/* battery RAM without a file starts as all ones */
#define SRAM_EMPTY 0xFFu
/* bytes of a 32-bit number, bits of a byte */
#define LONG_BYTES 4u
#define BYTE_BITS 8

/* the name of the cartridge that is in */
static char g_ac_name[NAME_BUF_LEN];
/* a cartridge is in */
static int32_t g_i32_on;

/* a big-endian 32-bit number of the cartridge's header */
static uint32_t peek32(uint32_t ui32_addr)
{
/* local variables */
    uint32_t ui32_value;
    uint32_t ui32_index;

/* start values */
    ui32_value = 0;
    for (ui32_index = 0; ui32_index < LONG_BYTES; ui32_index++)
    {
        ui32_value = (ui32_value << BYTE_BITS) | cart_peek(ui32_addr + ui32_index);
    }
/* the number */
    return ui32_value;
}

/* the regions the cartridge runs in, as bits (0: the header does not say) */
static uint32_t regions(void)
{
/* local variables */
    uint32_t ui32_bits;
    uint32_t ui32_index;
    char c_char;

/* start values */
    ui32_bits = 0;
    c_char = '\0';
    for (ui32_index = 0; ui32_index < REGION_CHARS; ui32_index++)
    {
/* a region character */
        c_char = (char)cart_peek(HDR_REGION + ui32_index);
/* the old way: a letter per region */
        if (c_char == 'J')
        {
            ui32_bits |= REG_JAPAN;
        }
        else if (c_char == 'U')
        {
/* America */
            ui32_bits |= REG_AMERICA;
        }
        else if (c_char == 'E')
        {
            ui32_bits |= REG_EUROPE;
        }
/* the new way: one hex digit of region bits */
        else if ((c_char >= '0') && (c_char <= '9'))
        {
            ui32_bits |= (uint32_t)(c_char - '0');
        }
        else if ((c_char >= 'A') && (c_char <= 'F'))
        {
/* a letter digit */
            ui32_bits |= (uint32_t)(c_char - 'A') + HEX_LETTER_BASE;
        }
        else
        {
/* a space or anything else says nothing */
        }
    }
    return ui32_bits;
}

/* an .smd file's blocks into the SDRAM: FAT_OK, FAT_EIO */
static int32_t load_smd(FFILE *ps_file, uint32_t ui32_len)
{
/* local variables */
    uint32_t ui32_index;
    uint32_t ui32_in_block;
    uint32_t ui32_addr;
/* a character, the result */
    int32_t i32_char;
    int32_t i32_result;

/* start values */
    ui32_index = 0;
    ui32_in_block = 0;
    ui32_addr = 0;
/* no character yet */
    i32_char = 0;
    i32_result = FAT_OK;
    ff_seek(ps_file, SMD_HDR);
/* byte by byte */
    while ((ui32_index < ui32_len) && (i32_result == FAT_OK))
    {
        i32_char = ff_getc(ps_file);
/* the card failed */
        if (i32_char < 0)
        {
            i32_result = FAT_EIO;
        }
        else
        {
/* the first half of a block holds the odd addresses, the second half the even ones */
            ui32_in_block = ui32_index % SMD_BLOCK;
            ui32_addr = ui32_index - ui32_in_block;
            if (ui32_in_block < SMD_HALF)
            {
/* an odd address */
                ui32_addr += (ui32_in_block * SMD_STEP) + ONE;
            }
            else
            {
                ui32_addr += (ui32_in_block - SMD_HALF) * SMD_STEP;
            }
            cart_poke(ui32_addr, (uint8_t)i32_char);
/* the next byte */
            ui32_index++;
        }
    }
    return i32_result;
}

/* Load a cartridge file and start it: MD_OK, MD_EBAD, MD_ESIZE, FAT_EIO */
int32_t md_load(const FFILE *ps_file, const char *pc_name, uint32_t ui32_dir)
{
/* local variables */
    FFILE *ps_rom;
    uint32_t ui32_len;
    uint32_t ui32_index;
/* the word for the core, the region bits, the battery RAM's range */
    uint32_t ui32_cart;
    uint32_t ui32_region;
    uint32_t ui32_first;
/* its last address */
    uint32_t ui32_last;
    bool b_smd;
    int32_t i32_char;
/* the result */
    int32_t i32_result;

/* start values */
    ps_rom = (FFILE *)malloc(sizeof(FFILE));
    ui32_len = ps_file->ui32_size;
    ui32_index = 0;
/* America unless the header says otherwise */
    ui32_cart = MC_OVERSEAS;
    ui32_region = 0;
    ui32_first = 0;
/* no battery RAM range */
    ui32_last = 0;
    b_smd = false;
    i32_char = 0;
/* no file object yet */
    i32_result = FAT_EIO;
    if (ps_rom != NULL)
    {
        i32_result = FAT_OK;
/* a copy of the file object */
        u_memcpy(ps_rom, ps_file, sizeof(FFILE));
        ff_seek(ps_rom, 0);
/* an .smd file: its length and the two marker bytes of its header */
        if ((ui32_len % SMD_BLOCK) == SMD_HDR)
        {
            b_smd = true;
            for (ui32_index = 0; ui32_index <= (SMD_MARK_AT + ONE); ui32_index++)
            {
/* a byte of the header */
                i32_char = ff_getc(ps_rom);
                if ((ui32_index == SMD_MARK_AT) && (i32_char != (int32_t)SMD_MARK_0))
                {
                    b_smd = false;
                }
/* the second marker */
                if ((ui32_index == (SMD_MARK_AT + ONE)) && (i32_char != (int32_t)SMD_MARK_1))
                {
                    b_smd = false;
                }
            }
            ff_seek(ps_rom, 0);
        }
/* without its header */
        if (b_smd)
        {
            ui32_len -= SMD_HDR;
        }
/* what the core cannot take */
        if (ui32_len < ROM_MIN)
        {
            i32_result = MD_EBAD;
        }
        else if (ui32_len > ROM_MAX)
        {
/* too large */
            i32_result = MD_ESIZE;
        }
        else
        {
/* a file of a size the core takes */
        }
    }
    if (i32_result == FAT_OK)
    {
/* the machine stops; a battery RAM not saved yet goes to the card first */
        if (g_i32_on != 0)
        {
            cart_sav_flush();
        }
        g_i32_on = 0;
/* no battery RAM known yet */
        cart_sav_setup(ui32_dir, pc_name, SD_SRAM, 0);
        MCTL = 0;
        cart_begin(MC_PAGE_SHIFT, 0);
/* the ROM */
        if (b_smd)
        {
            i32_result = load_smd(ps_rom, ui32_len);
        }
        else
        {
            i32_result = cart_load(ps_rom, 0, ui32_len);
        }
    }
/* the ROM is in: what the cartridge's header says */
    if (i32_result == FAT_OK)
    {
/* the region: America if the game runs there, else Europe (50 Hz), else Japan */
        ui32_region = regions();
        if ((ui32_region != 0) && ((ui32_region & REG_AMERICA) == 0))
        {
            if ((ui32_region & REG_EUROPE) != 0)
            {
/* Europe: a 50 Hz console */
                ui32_cart = MC_OVERSEAS | MC_PAL;
            }
            else
            {
                ui32_cart = 0;
            }
        }
/* battery RAM: "RA" and a range inside the cartridge's RAM area */
        if ((cart_peek(HDR_RAM_MARK) == (uint8_t)'R') && (cart_peek(HDR_RAM_MARK + ONE) == (uint8_t)'A'))
        {
            ui32_first = peek32(HDR_RAM_FIRST) & ~ONE;
            ui32_last = peek32(HDR_RAM_LAST) | ONE;
/* a usable range */
            if ((ui32_first >= RAM_AREA_FIRST) && (ui32_last <= RAM_AREA_LAST) && (ui32_last > ui32_first) &&
                ((ui32_last - ui32_first) < RAM_MAX))
            {
                ui32_cart |= MC_SRAM;
                cart_sav_setup(ui32_dir, pc_name, SD_SRAM + (ui32_first & RAM_OFFSET_MASK), (ui32_last - ui32_first) + ONE);
/* its contents: the file's, or all ones */
                cart_sav_start(SRAM_EMPTY);
            }
        }
/* the write flag is cleared before the game runs */
        u_strncpy(g_ac_name, pc_name, NAME_MAX);
        MCTL = ui32_cart;
        MCLR = ONE;
/* the machine starts */
        MCTL = ui32_cart | MC_RUN;
        cart_begin(MC_PAGE_SHIFT, ui32_cart | MC_RUN);
        g_i32_on = YES;
    }
/* the card failed */
    else if (i32_result == FAT_EIO)
    {
/* the card failed while the memory was written: no cartridge */
        MCTL = 0;
        g_i32_on = 0;
    }
    else
    {
/* a file the core cannot take: the game that runs stays */
    }
    if (ps_rom != NULL)
    {
        free(ps_rom);
    }
    return i32_result;
}

/* main loop: the battery RAM goes to the card after the game wrote it */
void md_service(void)
{
    if (g_i32_on != 0)
    {
        cart_sav_service();
    }
}

/* the cartridge's name while one is in: MD_CART_IN, else 0 */
int32_t md_status(char *pc_text)
{
/* local variables */
    int32_t i32_result;

/* start values */
    i32_result = 0;
    if (g_i32_on != 0)
    {
        u_strcpy(pc_text, g_ac_name);
/* a cartridge is in */
        i32_result = MD_CART_IN;
    }
    return i32_result;
}

/* back to the state after a start: the next machine starts the loader again without an ESP32 */
/* restart (esp_hw.cpp; the Bluetooth connection stays) */
void md_reset(void)
{
    u_memset(g_ac_name, 0, sizeof g_ac_name);
    g_i32_on = 0;
/* the shared part */
    cart_reset();
}
