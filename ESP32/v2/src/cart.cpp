/* cart.cpp -- what the cartridge machines (LNES, LMega) share: a game file into the FPGA's */
/* SDRAM, and the battery RAM of a game as a .sav file beside it */
/* Memory: the snapshot port's memory commands address 256 KB; the page is a field of the */
/* machine's MCTL word (LNES: bits 30:27, LMega: bits 26:22). MSTAT (read MCTL) bit 0 = the game */
/* wrote its cartridge RAM; MCLR bit 0 clears that bit (the same in both machines). */
#include <stdlib.h>
#include "hw.h"
#include "hal.h"
/* this module's header, string functions, the card */
#include "cart.h"
#include "util.h"
#include "fat.h"

/* yes, and one as an unsigned number */
#define YES 1
#define ONE 1u
/* memory commands of the snapshot port: read, write; where the command sits */
#define C_MRD 1
#define C_MWR 2
#define CMD_SHIFT 28
/* a page of the memory commands: 256 KB */
#define PAGE_SHIFT 18
#define PAGE_MASK 0x3FFFFu
/* no page chosen yet */
#define PAGE_NONE 0xFFFFFFFFu
/* MSTAT / MCLR: the cartridge RAM was written */
#define ST_WRITTEN 1u
/* battery RAM: quiet time before it is saved, longest time between two saves while written */
#define SAVE_QUIET_MS 1500u
#define SAVE_MAX_MS 10000u
/* the largest battery RAM */
#define SAV_MAX 65536u
/* the .sav name: characters taken from the game's name, hex digits of the check value */
#define SAV_NAME_CHARS 4
#define SAV_HEX_DIGITS 4
#define NIBBLE_SHIFT 4
/* a hex digit */
#define HEX_MASK 0xFu
#define HEX_LETTERS 10u
#define HASH_FACTOR 31u
/* the check value's width */
#define HASH_MASK 0xFFFFu

/* the .sav file's 8.3 name */
static char g_ac_sav11[FAT_NAME11_LEN];
/* where the page field is in MCTL, the rest of the word, the page chosen last */
static uint32_t g_ui32_page_lsb;
static uint32_t g_ui32_state;
static uint32_t g_ui32_page;
/* battery RAM: the folder, the place in the SDRAM, the length (0: none) */
static uint32_t g_ui32_dir;
static uint32_t g_ui32_sav_addr;
static uint32_t g_ui32_sav_len;
/* written and not saved yet, the time of the last write seen and of the first */
static int32_t g_i32_dirty;
static uint32_t g_ui32_last_wr;
static uint32_t g_ui32_first_wr;
/* the .sav file as found by the directory scan */
static uint32_t g_ui32_sav_clus;
static uint32_t g_ui32_sav_size;
static int32_t g_i32_sav_found;

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

/* the page of an SDRAM address, chosen only when it changes */
static void set_page(uint32_t ui32_addr)
{
/* local variables */
    uint32_t ui32_page;

/* start values */
    ui32_page = ui32_addr >> PAGE_SHIFT;
    if (ui32_page != g_ui32_page)
    {
        g_ui32_page = ui32_page;
/* the page goes into its field */
        MCTL = g_ui32_state | (ui32_page << g_ui32_page_lsb);
    }
}

/* where the page field is, and the rest of the MCTL word from now on */
void cart_begin(uint32_t ui32_page_lsb, uint32_t ui32_state)
{
    g_ui32_page_lsb = ui32_page_lsb;
    g_ui32_state = ui32_state;
/* the next access writes MCTL */
    g_ui32_page = PAGE_NONE;
}

/* one byte out of the SDRAM */
uint8_t cart_peek(uint32_t ui32_addr)
{
/* local variables */
    uint8_t ui8_value;

    set_page(ui32_addr);
    ui8_value = (uint8_t)snap_cmd(C_MRD, ui32_addr & PAGE_MASK, 0);
/* the byte */
    return ui8_value;
}

/* one byte into the SDRAM */
void cart_poke(uint32_t ui32_addr, uint8_t ui8_value)
{
    set_page(ui32_addr);
    snap_cmd(C_MWR, ui32_addr & PAGE_MASK, ui8_value);
}

/* ui32_count bytes of a file into the SDRAM from ui32_addr on: FAT_OK, FAT_EIO */
int32_t cart_load(FFILE *ps_file, uint32_t ui32_addr, uint32_t ui32_count)
{
/* local variables */
    uint32_t ui32_index;
    int32_t i32_char;
    int32_t i32_result;

/* start values */
    ui32_index = 0;
    i32_char = 0;
    i32_result = FAT_OK;
/* byte by byte */
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
            cart_poke(ui32_addr + ui32_index, (uint8_t)i32_char);
/* the next byte */
            ui32_index++;
        }
    }
    return i32_result;
}

/* ui32_count bytes of one value into the SDRAM from ui32_addr on */
void cart_fill(uint32_t ui32_addr, uint32_t ui32_count, uint8_t ui8_value)
{
/* local variables */
    uint32_t ui32_index;

/* byte by byte */
    for (ui32_index = 0; ui32_index < ui32_count; ui32_index++)
    {
        cart_poke(ui32_addr + ui32_index, ui8_value);
    }
}

/* the .sav file's 8.3 name from the game's name: four of its letters and digits, then a */
/* check value of the whole name in hex */
static void sav_name(const char *pc_name)
{
/* local variables */
    uint32_t ui32_hash;
    int32_t i32_src;
    int32_t i32_dst;
/* a character, a hex digit */
    char c_char;
    uint32_t ui32_digit;

/* start values */
    ui32_hash = 0;
    i32_src = 0;
    i32_dst = 0;
/* no character yet */
    c_char = '\0';
    ui32_digit = 0;
/* "________SAV" until the name is known */
    u_memcpy(g_ac_sav11, "________SAV", FAT_NAME11_LEN);
    while (pc_name[i32_src] != '\0')
    {
        c_char = pc_name[i32_src];
/* lower case counts as upper case */
        if ((c_char >= 'a') && (c_char <= 'z'))
        {
            c_char = (char)(c_char - 'a' + 'A');
        }
        ui32_hash = ((ui32_hash * HASH_FACTOR) + (uint8_t)c_char) & HASH_MASK;
/* the first letters and digits make the readable part */
        if ((i32_dst < SAV_NAME_CHARS) && (((c_char >= 'A') && (c_char <= 'Z')) || ((c_char >= '0') && (c_char <= '9'))))
        {
            g_ac_sav11[i32_dst] = c_char;
            i32_dst++;
        }
/* the next character */
        i32_src++;
    }
/* the check value, high digit first */
    for (i32_dst = 0; i32_dst < SAV_HEX_DIGITS; i32_dst++)
    {
        ui32_digit = (ui32_hash >> (NIBBLE_SHIFT * (SAV_HEX_DIGITS - YES - i32_dst))) & HEX_MASK;
        c_char = (char)('0' + ui32_digit);
/* A to F */
        if (ui32_digit >= HEX_LETTERS)
        {
            c_char = (char)('A' + (ui32_digit - HEX_LETTERS));
        }
        g_ac_sav11[SAV_NAME_CHARS + i32_dst] = c_char;
    }
}

/* directory scan: is this entry the .sav file? */
static int32_t sav_cb(const DIRENT *ps_entry, void *p_ctx)
{
/* local variables */
    int32_t i32_stop;

/* start values */
    i32_stop = 0;
    (void)p_ctx;
    if (((ps_entry->ui8_attr & ATTR_DIR) == 0) && (u_memcmp(ps_entry->ac_sname, g_ac_sav11, FAT_NAME11_LEN) == 0))
    {
/* found: where it is */
        g_ui32_sav_clus = ps_entry->ui32_clus;
        g_ui32_sav_size = ps_entry->ui32_size;
        g_i32_sav_found = YES;
/* the scan can stop */
        i32_stop = YES;
    }
    return i32_stop;
}

/* the battery RAM of the game that is loaded now */
void cart_sav_setup(uint32_t ui32_dir, const char *pc_name, uint32_t ui32_addr, uint32_t ui32_len)
{
    g_ui32_dir = ui32_dir;
    g_ui32_sav_addr = ui32_addr;
/* its length */
    g_ui32_sav_len = ui32_len;
/* never more than the largest */
    if (g_ui32_sav_len > SAV_MAX)
    {
        g_ui32_sav_len = SAV_MAX;
    }
    g_i32_dirty = 0;
/* its file's name */
    sav_name(pc_name);
}

/* the RAM at the start: the .sav file's contents, or the fill value (machine stopped) */
void cart_sav_start(uint8_t ui8_fill)
{
/* local variables */
    FFILE *ps_file;
    int32_t i32_result;

/* start values */
    ps_file = NULL;
    i32_result = FAT_EIO;
    g_i32_sav_found = 0;
/* not found yet */
    g_ui32_sav_clus = 0;
    g_ui32_sav_size = 0;
    if (g_ui32_sav_len != 0)
    {
/* is the file there, with the right length? */
        fat_list(g_ui32_dir, sav_cb, NULL);
        if ((g_i32_sav_found != 0) && (g_ui32_sav_size == g_ui32_sav_len))
        {
/* not on the stack: a file object is larger than half a kilobyte */
            ps_file = (FFILE *)malloc(sizeof(FFILE));
        }
        if (ps_file != NULL)
        {
            ff_open(ps_file, g_ui32_sav_clus, g_ui32_sav_size);
/* its contents go into the RAM */
            i32_result = cart_load(ps_file, g_ui32_sav_addr, g_ui32_sav_len);
            free(ps_file);
        }
/* no file, or it could not be read */
        if (i32_result != FAT_OK)
        {
            cart_fill(g_ui32_sav_addr, g_ui32_sav_len, ui8_fill);
        }
    }
}

/* write the battery RAM to its .sav file (the machine runs on) */
static void sav_write(void)
{
/* local variables */
    uint8_t *pui8_ram;
    uint32_t ui32_index;
    int32_t i32_result;

/* start values */
    pui8_ram = (uint8_t *)malloc(g_ui32_sav_len);
    ui32_index = 0;
    i32_result = FAT_OK;
/* the buffer was got */
    if (pui8_ram != NULL)
    {
/* out of the SDRAM first */
        for (ui32_index = 0; ui32_index < g_ui32_sav_len; ui32_index++)
        {
            pui8_ram[ui32_index] = cart_peek(g_ui32_sav_addr + ui32_index);
        }
/* a machine that was left meanwhile answers with ones: nothing is written then */
        if (link_alive() != 0)
        {
            fat_delete(g_ui32_dir, g_ac_sav11);
            i32_result = fw_create(&g_s_fw_file, g_ui32_dir, g_ac_sav11);
/* from the first byte */
            ui32_index = 0;
/* byte by byte into the new file */
            while ((ui32_index < g_ui32_sav_len) && (i32_result == FAT_OK))
            {
                i32_result = fw_putc(&g_s_fw_file, pui8_ram[ui32_index]);
                ui32_index++;
            }
/* closed, or taken away after an error */
            if (i32_result == FAT_OK)
            {
                fw_close(&g_s_fw_file);
            }
            else
            {
                fw_discard(&g_s_fw_file);
            }
        }
/* the buffer goes back */
        free(pui8_ram);
    }
}

/* main loop: the battery RAM goes to the card after the game wrote it */
void cart_sav_service(void)
{
/* local variables */
    uint32_t ui32_now;

/* start values */
    ui32_now = TIMER;
    if (g_ui32_sav_len != 0)
    {
/* a write since the last look */
        if ((MCTL & ST_WRITTEN) != 0)
        {
            MCLR = ST_WRITTEN;
            g_ui32_last_wr = ui32_now;
/* the first write since the last save */
            if (g_i32_dirty == 0)
            {
                g_ui32_first_wr = ui32_now;
            }
            g_i32_dirty = YES;
        }
/* quiet for a moment, or written for a long time: saved */
        if ((g_i32_dirty != 0) && (((ui32_now - g_ui32_last_wr) >= (SAVE_QUIET_MS * CLK_PER_MS)) ||
                                   ((ui32_now - g_ui32_first_wr) >= (SAVE_MAX_MS * CLK_PER_MS))))
        {
            g_i32_dirty = 0;
            sav_write();
        }
    }
}

/* what is not saved yet goes to the card now */
void cart_sav_flush(void)
{
    if ((g_ui32_sav_len != 0) && (g_i32_dirty != 0))
    {
        g_i32_dirty = 0;
/* into the file */
        sav_write();
    }
}

/* back to the state after a start */
void cart_reset(void)
{
    u_memset(g_ac_sav11, 0, sizeof g_ac_sav11);
    g_ui32_page_lsb = 0;
/* no state */
    g_ui32_state = 0;
/* no page, no battery RAM */
    g_ui32_page = PAGE_NONE;
    g_ui32_dir = 0;
    g_ui32_sav_addr = 0;
/* no battery RAM */
    g_ui32_sav_len = 0;
/* nothing to save */
    g_i32_dirty = 0;
    g_ui32_last_wr = 0;
    g_ui32_first_wr = 0;
/* no .sav file known */
    g_ui32_sav_clus = 0;
    g_ui32_sav_size = 0;
    g_i32_sav_found = 0;
}
