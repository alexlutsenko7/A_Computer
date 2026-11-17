/* nes.cpp -- LNES (the NES core): cartridge files (.nes), battery RAM (.sav), screenshot */
/* A cartridge is only memory: the file's program data (PRG) and picture data (CHR) are written */
/* into the FPGA's SDRAM through the memory commands of the snapshot port, then the cartridge word */
/* (MCTL) tells the core what the cartridge is and starts the machine (LNES/ep4_ce15/rtl/nes_system.v): */
/*   MCTL: [7:0] mapper, [14:8] program mask (8 KB banks - 1), [23:15] picture mask (1 KB banks - 1), */
/*         [24] vertical mirroring, [25] four screens, [26] picture memory is RAM, */
/*         [30:27] the 256 KB page of the memory commands, [31] cartridge in (the machine runs) */
/*   MSTAT (read MCTL): [0] the game wrote its cartridge RAM;  MCLR: [0] clears that bit */
/* SDRAM: 0x000000 the NES's RAM, 0x002000 cartridge RAM (8 KB), 0x100000 picture data, */
/* 0x200000 program data. */
/* .nes: 16-byte header ("NES" $1A, program size in 16 KB, picture size in 8 KB, flags 6: [0] */
/* vertical mirroring, [1] battery, [2] 512-byte trainer follows, [3] four screens, [7:4] mapper low; */
/* flags 7: [7:4] mapper high), then the program data, then the picture data. */
/* Battery RAM: the 8 KB at $6000-$7FFF of a game whose header has the battery bit are kept in a */
/* file NAMEhhhh.SAV beside the game (four characters of the game's name and a check value of the */
/* whole name). It is written when the game has stopped writing for a moment, or every few */
/* seconds while it keeps writing. */
/* Screenshot: the frame buffer's newest frame (rtl/nes_fb.v: two pixels per 16-bit word, 512 bytes */
/* per line), held while it is read (memory command CTL [2]), as a 256-colour BMP. */
#include <stdlib.h>
#include "hw.h"
#include "hal.h"
/* this module's header, string functions */
#include "nes.h"
#include "cart.h"
#include "util.h"
/* the generated palette, screenshots, the card */
#include "nes_palette.h"
#include "shot.h"
#include "fat.h"

/* yes, and one as an unsigned number */
#define YES 1
#define ONE 1u
/* memory commands of the snapshot port: read, control; where the command sits */
#define C_MRD 1
#define C_CTL 4
#define CMD_SHIFT 28
/* control: hold the frame buffers */
#define CTL_HOLD_FB 4u
/* the cartridge word */
#define MC_PRG_SHIFT 8
#define MC_CHR_SHIFT 15
#define MC_VERT (1u << 24)
/* four screens, picture RAM */
#define MC_FOUR (1u << 25)
#define MC_CHRRAM (1u << 26)
#define MC_PAGE_SHIFT 27
/* the machine runs */
#define MC_RUN (1u << 31)
/* SDRAM addresses: cartridge RAM, picture data, program data */
#define SD_WRAM 0x002000u
#define SD_CHR 0x100000u
#define SD_PRG 0x200000u
/* sizes: cartridge RAM, picture RAM, the units of the header, the banks of the masks */
#define WRAM_LEN 8192u
#define CHRRAM_LEN 8192u
#define PRG_UNIT 16384u
/* the header's units */
#define CHR_UNIT 8192u
#define PRG_BANK 8192u
#define CHR_BANK 1024u
/* the most the core takes */
#define PRG_MAX 0x100000u
#define CHR_MAX 0x80000u
/* the .nes header */
#define HDR_LEN 16u
#define HDR_MAGIC_LEN 4u
#define HDR_PRG 4
/* picture data size, the two flag bytes */
#define HDR_CHR 5
#define HDR_FLAGS6 6
#define HDR_FLAGS7 7
/* the header's last four bytes, which are zero in a clean header */
#define HDR_TAIL_0 12
#define HDR_TAIL_1 13
#define HDR_TAIL_2 14
/* the last of them */
#define HDR_TAIL_3 15
#define F6_VERT 0x01u
#define F6_BATTERY 0x02u
/* a trainer follows, four screens */
#define F6_TRAINER 0x04u
#define F6_FOUR 0x08u
#define NIBBLE_SHIFT 4
/* the high half of a byte */
#define HIGH_NIBBLE 0xF0u
#define TRAINER_LEN 512u
/* the mappers of the core */
#define MAP_NROM 0u
#define MAP_MMC1 1u
#define MAP_UXROM 2u
/* the simple mappers */
#define MAP_CNROM 3u
#define MAP_MMC3 4u
#define MAP_AXROM 7u
/* the two with one register */
#define MAP_COLOR 11u
#define MAP_GXROM 66u
/* screenshot: the picture, the bytes of a frame buffer line, the BMP's colours */
#define SHOT_WIDTH 256
#define SHOT_HEIGHT 240
#define SHOT_LAST_ROW 239
/* a row of the frame buffer */
#define FB_LINE_BYTES 512u
/* pixels of a frame buffer word */
#define PAIR 2
#define PIXEL_MASK 0x3Fu
#define LOW_RIGHT_SHIFT 6
/* the right pixel's upper bits */
#define HIGH_RIGHT_MASK 0x0Fu
#define HIGH_RIGHT_SHIFT 2
#define RGB_RED_SHIFT 16
/* green */
#define RGB_GREEN_SHIFT 8
#define BYTE_MASK 0xFFu
#define RGB_RED 0
/* green, blue */
#define RGB_GREEN 1
#define RGB_BLUE 2

/* the name of the cartridge that is in */
static char g_ac_name[NAME_BUF_LEN];
/* the cartridge word without the run bit and the page */
static uint32_t g_ui32_cart;
/* a cartridge is in */
static int32_t g_i32_on;

/* snapshot port memory command (esp_hw.cpp turns MWR into bursts) */
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

/* the smallest (power of two) - 1 that covers ui32_count banks */
static uint32_t mask_of(uint32_t ui32_count)
{
/* local variables */
    uint32_t ui32_size;

/* start values */
    ui32_size = ONE;
    while (ui32_size < ui32_count)
    {
        ui32_size <<= ONE;
    }
/* one less */
    return ui32_size - ONE;
}

/* does the core have this mapper? */
static bool mapper_known(uint32_t ui32_mapper)
{
/* local variables */
    bool b_known;

/* start values */
    b_known = false;
    if ((ui32_mapper == MAP_NROM) || (ui32_mapper == MAP_MMC1) || (ui32_mapper == MAP_UXROM) || (ui32_mapper == MAP_CNROM))
    {
        b_known = true;
    }
/* the second half of the list */
    if ((ui32_mapper == MAP_MMC3) || (ui32_mapper == MAP_AXROM) || (ui32_mapper == MAP_COLOR) || (ui32_mapper == MAP_GXROM))
    {
        b_known = true;
    }
    return b_known;
}

/* Load a .nes file and start it: NES_OK, NES_EBAD, NES_EMAPPER, NES_ESIZE, FAT_EIO */
int32_t nes_load(const FFILE *ps_file, const char *pc_name, uint32_t ui32_dir, uint32_t *pui32_mapper)
{
/* local variables */
    uint8_t aui8_hdr[HDR_LEN];
    FFILE *ps_nes;
    uint32_t ui32_index;
/* the sizes, the mapper, the word for the core */
    uint32_t ui32_prg;
    uint32_t ui32_chr;
    uint32_t ui32_mapper;
/* the word for the core */
    uint32_t ui32_cart;
    int32_t i32_char;
    int32_t i32_result;

/* start values */
    ps_nes = (FFILE *)malloc(sizeof(FFILE));
    ui32_index = 0;
    ui32_prg = 0;
/* the picture data's size */
    ui32_chr = 0;
    ui32_mapper = 0;
    ui32_cart = 0;
/* a character */
    i32_char = 0;
    i32_result = FAT_EIO;
    *pui32_mapper = 0;
/* the file object was got */
    if (ps_nes != NULL)
    {
/* the header, from a copy of the file object */
        u_memcpy(ps_nes, ps_file, sizeof(FFILE));
        ff_seek(ps_nes, 0);
        i32_result = FAT_OK;
/* the header, byte by byte */
        while ((ui32_index < HDR_LEN) && (i32_result == FAT_OK))
        {
            i32_char = ff_getc(ps_nes);
/* too short for a header */
            if (i32_char < 0)
            {
                i32_result = NES_EBAD;
            }
            else
            {
                aui8_hdr[ui32_index] = (uint8_t)i32_char;
/* the next byte */
                ui32_index++;
            }
        }
/* "NES" and the end-of-file character */
        if ((i32_result == FAT_OK) && (u_memcmp(aui8_hdr, "NES\x1A", HDR_MAGIC_LEN) != 0))
        {
            i32_result = NES_EBAD;
        }
    }
    if (i32_result == FAT_OK)
    {
/* the sizes and the mapper */
        ui32_prg = (uint32_t)aui8_hdr[HDR_PRG] * PRG_UNIT;
        ui32_chr = (uint32_t)aui8_hdr[HDR_CHR] * CHR_UNIT;
        ui32_mapper = (uint32_t)aui8_hdr[HDR_FLAGS6] >> NIBBLE_SHIFT;
/* the mapper's high half only from a clean header (old tools left text in its last bytes) */
        if ((aui8_hdr[HDR_TAIL_0] | aui8_hdr[HDR_TAIL_1] | aui8_hdr[HDR_TAIL_2] | aui8_hdr[HDR_TAIL_3]) == 0)
        {
            ui32_mapper |= (uint32_t)aui8_hdr[HDR_FLAGS7] & HIGH_NIBBLE;
        }
        *pui32_mapper = ui32_mapper;
/* what the core cannot take */
        if (!mapper_known(ui32_mapper))
        {
            i32_result = NES_EMAPPER;
        }
        else if ((ui32_prg == 0) || (ui32_prg > PRG_MAX) || (ui32_chr > CHR_MAX))
        {
/* too large */
            i32_result = NES_ESIZE;
        }
        else
        {
/* a cartridge the core has */
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
        cart_sav_setup(ui32_dir, pc_name, SD_WRAM, 0);
        MCTL = 0;
        cart_begin(MC_PAGE_SHIFT, 0);
/* the trainer is not used: skipped */
        if ((aui8_hdr[HDR_FLAGS6] & F6_TRAINER) != 0)
        {
            ff_seek(ps_nes, HDR_LEN + TRAINER_LEN);
        }
        i32_result = cart_load(ps_nes, SD_PRG, ui32_prg);
    }
/* the picture data, or 8 KB of empty picture RAM */
    if (i32_result == FAT_OK)
    {
        if (ui32_chr != 0)
        {
            i32_result = cart_load(ps_nes, SD_CHR, ui32_chr);
        }
        else
        {
/* picture RAM starts empty */
            cart_fill(SD_CHR, CHRRAM_LEN, 0);
        }
    }
    if (i32_result == FAT_OK)
    {
/* the word for the core */
        ui32_cart = ui32_mapper | (mask_of(ui32_prg / PRG_BANK) << MC_PRG_SHIFT);
        if (ui32_chr != 0)
        {
            ui32_cart |= mask_of(ui32_chr / CHR_BANK) << MC_CHR_SHIFT;
        }
        else
        {
/* 8 KB of picture RAM */
            ui32_cart |= (mask_of(CHRRAM_LEN / CHR_BANK) << MC_CHR_SHIFT) | MC_CHRRAM;
        }
/* the name table layout */
        if ((aui8_hdr[HDR_FLAGS6] & F6_VERT) != 0)
        {
            ui32_cart |= MC_VERT;
        }
        if ((aui8_hdr[HDR_FLAGS6] & F6_FOUR) != 0)
        {
/* four screens */
            ui32_cart |= MC_FOUR;
        }
/* the cartridge RAM: a game with a battery has its .sav file, the others zeros */
        g_ui32_cart = ui32_cart;
        u_strncpy(g_ac_name, pc_name, NAME_MAX);
        if ((aui8_hdr[HDR_FLAGS6] & F6_BATTERY) != 0)
        {
/* the battery RAM's file */
            cart_sav_setup(ui32_dir, pc_name, SD_WRAM, WRAM_LEN);
            cart_sav_start(0);
        }
        else
        {
            cart_fill(SD_WRAM, WRAM_LEN, 0);
        }
/* the write flag is cleared before the game runs */
        MCTL = ui32_cart;
        MCLR = ONE;
        MCTL = ui32_cart | MC_RUN;
/* from now on the machine runs while memory is read */
        cart_begin(MC_PAGE_SHIFT, ui32_cart | MC_RUN);
        g_i32_on = YES;
    }
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
    if (ps_nes != NULL)
    {
        free(ps_nes);
    }
    return i32_result;
}

/* main loop: the battery RAM goes to the card after the game wrote it */
void nes_service(void)
{
    if (g_i32_on != 0)
    {
        cart_sav_service();
    }
}

/* the cartridge's name while one is in: NES_CART_IN, else 0 */
int32_t nes_status(char *pc_text)
{
/* local variables */
    int32_t i32_result;

/* start values */
    i32_result = 0;
    if (g_i32_on != 0)
    {
        u_strcpy(pc_text, g_ac_name);
/* a cartridge is in */
        i32_result = NES_CART_IN;
    }
    return i32_result;
}

/* Print Screen: the frame buffer's newest frame as a 256-colour BMP: NES_OK, FAT_* */
int32_t nes_screenshot(uint32_t ui32_dir, const char ac_name11[FAT_NAME11_LEN])
{
/* local variables */
    uint8_t (*paui8_pal)[SHOT_RGB_LEN];
    uint8_t *pui8_row;
    int32_t i32_y;
/* a column */
    int32_t i32_x;
/* the two bytes of a pixel pair, an SDRAM address */
    uint32_t ui32_low;
    uint32_t ui32_high;
    uint32_t ui32_addr;
/* the result of closing, the result */
    int32_t i32_end;
    int32_t i32_result;

/* not static: RAM for the Bluetooth stack */
    paui8_pal = (uint8_t (*)[SHOT_RGB_LEN])malloc(SHOT_COLOURS_8BPP * SHOT_RGB_LEN);
    pui8_row = (uint8_t *)malloc(SHOT_WIDTH);
    i32_y = SHOT_LAST_ROW;
/* the first column */
    i32_x = 0;
    ui32_low = 0;
    ui32_high = 0;
/* no address yet */
    ui32_addr = 0;
    i32_end = FAT_OK;
    i32_result = FAT_EIO;
/* both buffers were got */
    if ((paui8_pal != NULL) && (pui8_row != NULL))
    {
/* the BMP's palette: the 64 colours, the rest black */
        u_memset(paui8_pal, 0, SHOT_COLOURS_8BPP * SHOT_RGB_LEN);
        for (i32_x = 0; i32_x < NES_COLOURS; i32_x++)
        {
            paui8_pal[i32_x][RGB_RED] = (uint8_t)(g_aui32_nes_palette[i32_x] >> RGB_RED_SHIFT);
/* green */
            paui8_pal[i32_x][RGB_GREEN] = (uint8_t)((g_aui32_nes_palette[i32_x] >> RGB_GREEN_SHIFT) & BYTE_MASK);
            paui8_pal[i32_x][RGB_BLUE] = (uint8_t)(g_aui32_nes_palette[i32_x] & BYTE_MASK);
        }
/* hold the frame buffers while the picture is read, bottom row first */
        snap_cmd(C_CTL, 0, CTL_HOLD_FB);
        i32_result = shot_begin8(ui32_dir, ac_name11, SHOT_WIDTH, SHOT_HEIGHT, paui8_pal);
        while ((i32_y >= 0) && (i32_result == FAT_OK))
        {
/* a row: two pixels per word, {emphasis, 0, right pixel, left pixel} */
            for (i32_x = 0; i32_x < SHOT_WIDTH; i32_x += PAIR)
            {
                ui32_addr = ((uint32_t)i32_y * FB_LINE_BYTES) + (uint32_t)i32_x;
                ui32_low = snap_cmd(C_MRD, ui32_addr, 0);
/* its second byte */
                ui32_high = snap_cmd(C_MRD, ui32_addr + ONE, 0);
                pui8_row[i32_x] = (uint8_t)(ui32_low & PIXEL_MASK);
                pui8_row[i32_x + YES] = (uint8_t)((ui32_low >> LOW_RIGHT_SHIFT) | ((ui32_high & HIGH_RIGHT_MASK) << HIGH_RIGHT_SHIFT));
            }
/* into the file */
            i32_result = shot_row(pui8_row);
            i32_y--;
        }
/* the frame buffers run again */
        snap_cmd(C_CTL, 0, 0);
        i32_end = shot_end();
        if (i32_result == FAT_OK)
        {
/* the error of closing */
            i32_result = i32_end;
        }
    }
/* the buffers go back */
    if (paui8_pal != NULL)
    {
        free(paui8_pal);
    }
    if (pui8_row != NULL)
    {
/* the row */
        free(pui8_row);
    }
    return i32_result;
}

/* back to the state after a start: the next machine starts the loader again without an ESP32 */
/* restart (esp_hw.cpp; the Bluetooth connection stays) */
void nes_reset(void)
{
    u_memset(g_ac_name, 0, sizeof g_ac_name);
/* no cartridge */
    g_ui32_cart = 0;
    g_i32_on = 0;
    cart_reset();
}
