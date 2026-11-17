/* update.c -- flash update from the SD card, run while the machine menu (AMenu) is on the link, */
/* and the machines in the flash (second half of this file). */
/* LUPDATE.BIN (made by AMenu/ep4_ce15/tools/mk_update.py from the same .cof as L.jic): */
/*   0    "LUPDATE1" */
/*   8    image length (bytes from flash address 0, a multiple of 4096) */
/*   12   CRC-32 of the image (zlib) */
/*   16   skip start, 20 skip end: a range that is never written (none today) */
/*   24   menu end: the factory image's part, written last (today the whole file: the menu alone) */
/*   28   label, 64 bytes, NUL padded */
/*   252  CRC-32 of bytes 0-251 */
/*   256  the image: the flash contents as read over SPI (Quartus' .rpd with the bits of each byte reversed) */
/* Each 4 KB sector is compared with the flash and only rewritten if it differs (erase, program the */
/* pages that are not all FF, read back). The machines' sectors come first, the menu's last: an */
/* update cut off before that leaves a working menu, and the file stays for the next start. The file */
/* is deleted only after every sector checked out. */
#include <stdlib.h>
#include "hw.h"
#include "fat.h"
/* the flash, this module's header, string functions */
#include "flash.h"
#include "update.h"
#include "util.h"

/* the file's header, and one flash sector */
#define HDR 256u
#define SECTOR 4096u
/* 4 KB erase (maximum 0.4 s), page program (maximum 5 ms): the waits allowed */
#define ERASE_MS 2000u
#define PROG_MS 50u
/* size of the flash */
#define FL_MAX 0x800000u
/* fields of the header */
#define HDR_MAGIC_LEN 8
#define HDR_IMG_LEN_OFF 8
#define HDR_IMG_CRC_OFF 12
/* the area an update leaves alone, the end of the menu */
#define HDR_SKIP_LO_OFF 16
#define HDR_SKIP_HI_OFF 20
#define HDR_MENU_END_OFF 24
/* the label, the header's own checksum */
#define HDR_LABEL_OFF 28
#define HDR_LABEL_LEN 64
#define HDR_CRC_OFF 252
/* the label with its terminator */
#define LABEL_BUF_LEN 65
/* CRC-32 (zlib): table size, polynomial, bits per byte, byte mask */
#define CRC_TABLE_LEN 256
#define CRC_POLY 0xEDB88320u
#define CRC_BITS 8
/* the byte mask, the entry that shows the table is built */
#define CRC_BYTE_MASK 0xFFu
#define CRC_FIRST_FILLED 1
/* little-endian 32-bit fields */
#define BYTE_1 1
#define BYTE_2 2
#define BYTE_3 3
/* their shifts */
#define SHIFT_BYTE_1 8
#define SHIFT_BYTE_2 16
#define SHIFT_BYTE_3 24
/* one unit: bit 0, a single step */
#define ONE 1u
/* progress is shown every 256 KB of checking and every 128 KB of writing */
#define CHECK_PROGRESS_MASK 0x3FFFFu
#define WRITE_PROGRESS_MASK 0x1FFFFu
/* the flash: sector erase command, page size, an erased byte */
#define CMD_SECTOR_ERASE 0x20
#define PAGE 256u
#define ERASED 0xFF
/* a sector is burnt at most twice */
#define BURN_TRIES_MAX 2
/* two passes: the machines, then the menu */
#define PASSES 2
#define PASS_MENU 1
/* where an image starts inside its megabyte, and the sync byte as SPI reads it */
#define IMAGE_START 0x20u
#define SYNC_BYTE_AS_READ 0x56
/* the machines: one megabyte (the bitstream's part of a position, and the ROM area's) */
#define MB 0x100000u
/* a machine file: its name's extension, the folder, the header's fields */
#define MCH_EXT "LMC"
#define MCH_DIR11 "MACHINES   "
#define MCH_MAGIC "LMACHIN1"
#define MCH_BOARD_OFF 8
#define MCH_IMG_LEN_OFF 12
#define MCH_IMG_CRC_OFF 16
/* the ROM data, the info sector's checksum */
#define MCH_ROM_LEN_OFF 20
#define MCH_ROM_CRC_OFF 24
#define MCH_INFO_CRC_OFF 28
/* the info sector: the tag's two fixed bytes, the machine byte and its complement, the menu line */
#define INFO_TAG_0 0xA5
#define INFO_TAG_1 0x5A
#define INFO_MACHINE_OFF 2
#define INFO_NOT_OFF 3
#define INFO_LINE_OFF 16
/* bytes of the info sector that tell what is in a position */
#define INFO_READ (INFO_LINE_OFF + MCH_LINE_LEN)
/* the tag's length */
#define INFO_TAG_LEN 4
/* the parts of a file, in the order they are checked */
#define PART_INFO 0
#define PART_ROM 1
#define PART_IMAGE 2
#define PARTS 3
/* the directory callback's answers */
#define SCAN_GO_ON 0
#define SCAN_STOP 1

/* The buffers are allocated the first time an update file is read: only the menu mode does that, so */
/* the machines keep this RAM for the Bluetooth stack (static, it made A2DP stutter on hardware). */
struct ubuf
{
/* the file's header */
    uint8_t aui8_hdr[HDR];
/* the file's sector, and the flash's sector */
    uint8_t aui8_sec[SECTOR];
    uint8_t aui8_chk[SECTOR];
/* CRC table, built at the first use */
    uint32_t aui32_crc_tab[CRC_TABLE_LEN];
    char ac_label[LABEL_BUF_LEN];
/* the machine files of the card, and how many */
    MCH_FILE as_files[MCH_FILES_MAX];
    int32_t i32_files;
};

/* what the search for the file leaves */
struct find_upd
{
    DIRENT s_entry;
    int32_t i32_hit;
};

/* AMenu MACHINE_ADDR: the bitstreams of the three positions; each one's ROM area is 1 MB above */
static const uint32_t g_aui32_slot[MCH_POSITIONS] = { 0x100000u, 0x300000u, 0x500000u };
/* the buffers, NULL until the first update file is read */
static struct ubuf *g_ps_buf;

/* 32 bits, low byte first */
static uint32_t rd32(const uint8_t *pui8_src)
{
/* local variables */
    uint32_t ui32_value;

    ui32_value = pui8_src[0] | ((uint32_t)pui8_src[BYTE_1] << SHIFT_BYTE_1) |
                 ((uint32_t)pui8_src[BYTE_2] << SHIFT_BYTE_2) | ((uint32_t)pui8_src[BYTE_3] << SHIFT_BYTE_3);
    return ui32_value;
}

/* CRC-32 (zlib) of ui32_count bytes, continuing from ui32_crc */
static uint32_t crc32(uint32_t ui32_crc, const uint8_t *pui8_data, uint32_t ui32_count)
{
/* local variables */
    uint32_t ui32_index;
    uint32_t ui32_value;
    int32_t i32_bit;

/* start values */
    ui32_index = 0;
    ui32_value = 0;
    i32_bit = 0;
/* the table is built once (entry 1 is not 0 in a built table) */
    if (g_ps_buf->aui32_crc_tab[CRC_FIRST_FILLED] == 0)
    {
        for (ui32_index = 0; ui32_index < CRC_TABLE_LEN; ui32_index++)
        {
            ui32_value = ui32_index;
/* eight steps of the shift register */
            for (i32_bit = 0; i32_bit < CRC_BITS; i32_bit++)
            {
                if ((ui32_value & ONE) != 0)
                {
                    ui32_value = CRC_POLY ^ (ui32_value >> ONE);
                }
                else
                {
/* no carry: only the shift */
                    ui32_value = ui32_value >> ONE;
                }
            }
            g_ps_buf->aui32_crc_tab[ui32_index] = ui32_value;
        }
    }
/* byte by byte through the table */
    ui32_crc = ~ui32_crc;
    while (ui32_count != 0)
    {
/* the table entry of the low byte, the rest shifted */
        ui32_crc = g_ps_buf->aui32_crc_tab[(ui32_crc ^ *pui8_data) & CRC_BYTE_MASK] ^ (ui32_crc >> CRC_BITS);
        pui8_data++;
/* one byte less to do */
        ui32_count--;
    }
    ui32_crc = ~ui32_crc;
    return ui32_crc;
}

/* directory callback: stop at the file LUPDATE.BIN */
static int32_t find_cb(const DIRENT *ps_entry, void *p_ctx)
{
/* local variables */
    struct find_upd *ps_find;
    int32_t i32_stop;

/* start values */
    ps_find = (struct find_upd *)p_ctx;
    i32_stop = SCAN_GO_ON;
/* a file, not a folder, with the stored name */
    if (((ps_entry->ui8_attr & ATTR_DIR) == 0) && (u_memcmp(ps_entry->ac_sname, UPD_NAME11, FAT_NAME11_LEN) == 0))
    {
        ps_find->s_entry = *ps_entry;
        ps_find->i32_hit = UPD_FOUND;
/* found: the scan ends */
        i32_stop = SCAN_STOP;
    }
    return i32_stop;
}

/* LUPDATE.BIN in the root folder: UPD_FOUND (entry filled), 0 = none, below 0 = card error */
int32_t upd_find(DIRENT *ps_entry)
{
/* local variables */
    struct find_upd s_find;
    int32_t i32_result;

/* start values */
    s_find.i32_hit = 0;
    i32_result = 0;
/* scan the root folder */
    if (fat_list(0, find_cb, &s_find) != FAT_OK)
    {
        i32_result = FAT_EIO;
    }
    else
    {
/* the entry only if the file is there */
        if (s_find.i32_hit != 0)
        {
            *ps_entry = s_find.s_entry;
        }
/* found or not */
        i32_result = s_find.i32_hit;
    }
    return i32_result;
}

/* the update's label, empty before a file was read */
const char *upd_label(void)
{
    const char *pc_label;

    pc_label = "";
/* the buffers exist after the first file */
    if (g_ps_buf != NULL)
    {
        pc_label = g_ps_buf->ac_label;
    }
    return pc_label;
}

/* header field: image length */
static uint32_t img_len(void)
{
/* local variables */
    uint32_t ui32_value;

    ui32_value = rd32(g_ps_buf->aui8_hdr + HDR_IMG_LEN_OFF);
    return ui32_value;
}

/* header field: start of the range that is never written */
static uint32_t skip_lo(void)
{
/* local variables */
    uint32_t ui32_value;

    ui32_value = rd32(g_ps_buf->aui8_hdr + HDR_SKIP_LO_OFF);
    return ui32_value;
}

/* header field: end of the range that is never written */
static uint32_t skip_hi(void)
{
/* local variables */
    uint32_t ui32_value;

    ui32_value = rd32(g_ps_buf->aui8_hdr + HDR_SKIP_HI_OFF);
    return ui32_value;
}

/* header field: end of the menu's slot */
static uint32_t menu_end(void)
{
/* local variables */
    uint32_t ui32_value;

    ui32_value = rd32(g_ps_buf->aui8_hdr + HDR_MENU_END_OFF);
    return ui32_value;
}

/* read ui32_count bytes of the file into a buffer: UPD_OK or FAT_EIO */
static int32_t read_bytes(FFILE *ps_file, uint8_t *pui8_dst, uint32_t ui32_count)
{
/* local variables */
    uint32_t ui32_index;
    int32_t i32_char;
    int32_t i32_result;

/* start values */
    ui32_index = 0;
    i32_char = 0;
    i32_result = UPD_OK;
/* byte by byte, until the card fails */
    while ((ui32_index < ui32_count) && (i32_result == UPD_OK))
    {
        i32_char = ff_getc(ps_file);
        if (i32_char < 0)
        {
/* the card failed, or the file ended early */
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

/* the buffers, allocated at the first use: UPD_OK, or FAT_EIO without memory */
static int32_t need_buf(void)
{
    int32_t i32_result;

    i32_result = UPD_OK;
    if (g_ps_buf == NULL)
    {
        g_ps_buf = (struct ubuf *)calloc(ONE, sizeof *g_ps_buf);
/* no memory */
        if (g_ps_buf == NULL)
        {
            i32_result = FAT_EIO;
        }
    }
    return i32_result;
}

/* open the file, read and check its header: UPD_OK, UPD_EBAD, FAT_EIO */
static int32_t read_hdr(FFILE *ps_file, const DIRENT *ps_entry)
{
    int32_t i32_result;

/* the buffers, at the first use */
    i32_result = need_buf();
/* the header's bytes; a file shorter than a header is a bad file, not a card error */
    if (i32_result == UPD_OK)
    {
        ff_open(ps_file, ps_entry->ui32_clus, ps_entry->ui32_size);
        i32_result = read_bytes(ps_file, g_ps_buf->aui8_hdr, HDR);
/* too short */
        if ((i32_result != UPD_OK) && (ps_entry->ui32_size < HDR))
        {
            i32_result = UPD_EBAD;
        }
    }
/* the magic text and the header's own checksum */
    if (i32_result == UPD_OK)
    {
        if ((u_memcmp(g_ps_buf->aui8_hdr, "LUPDATE1", HDR_MAGIC_LEN) != 0) ||
            (crc32(0, g_ps_buf->aui8_hdr, HDR_CRC_OFF) != rd32(g_ps_buf->aui8_hdr + HDR_CRC_OFF)))
        {
            i32_result = UPD_EBAD;
        }
    }
/* the image: whole sectors, not larger than the flash, and the file as long as the header says */
    if (i32_result == UPD_OK)
    {
        if ((img_len() == 0) || ((img_len() % SECTOR) != 0) || (img_len() > FL_MAX) ||
            (ps_entry->ui32_size != (HDR + img_len())))
        {
            i32_result = UPD_EBAD;
        }
    }
/* the menu's end and the skipped range on sector borders */
    if (i32_result == UPD_OK)
    {
        if (((menu_end() % SECTOR) != 0) || (menu_end() > img_len()) || ((skip_lo() % SECTOR) != 0) ||
            ((skip_hi() % SECTOR) != 0))
        {
            i32_result = UPD_EBAD;
        }
    }
/* the label, terminated */
    if (i32_result == UPD_OK)
    {
        u_memcpy(g_ps_buf->ac_label, g_ps_buf->aui8_hdr + HDR_LABEL_OFF, HDR_LABEL_LEN);
/* its terminator */
        g_ps_buf->ac_label[HDR_LABEL_LEN] = 0;
    }
    return i32_result;
}

/* check the file: header, size, CRC-32 of the whole image. UPD_OK, UPD_EBAD, FAT_EIO */
int32_t upd_check(const DIRENT *ps_entry, void (*pf_progress)(uint32_t ui32_done, uint32_t ui32_total))
{
/* local variables */
    FFILE s_file;
    uint32_t ui32_addr;
/* the checksum so far, the result */
    uint32_t ui32_crc;
    int32_t i32_result;

/* start values */
    ui32_addr = 0;
    ui32_crc = 0;
    i32_result = read_hdr(&s_file, ps_entry);
/* the image follows the header, sector by sector */
    while ((i32_result == UPD_OK) && (ui32_addr < img_len()))
    {
        i32_result = read_bytes(&s_file, g_ps_buf->aui8_sec, SECTOR);
/* into the checksum */
        if (i32_result == UPD_OK)
        {
            ui32_crc = crc32(ui32_crc, g_ps_buf->aui8_sec, SECTOR);
/* show how far it is */
            if ((pf_progress != NULL) && ((ui32_addr & CHECK_PROGRESS_MASK) == 0))
            {
                pf_progress(ui32_addr, img_len());
            }
            ui32_addr += SECTOR;
        }
    }
/* the checksum of the whole image */
    if ((i32_result == UPD_OK) && (ui32_crc != rd32(g_ps_buf->aui8_hdr + HDR_IMG_CRC_OFF)))
    {
        i32_result = UPD_EBAD;
    }
    return i32_result;
}

/* does the flash sector at ui32_addr equal the file's sector in the buffer? */
static bool same(uint32_t ui32_addr)
{
/* local variables */
    bool b_same;

/* read the sector back */
    fl_read(ui32_addr, g_ps_buf->aui8_chk, SECTOR);
    b_same = u_memcmp(g_ps_buf->aui8_chk, g_ps_buf->aui8_sec, SECTOR) == 0;
    return b_same;
}

/* erase the sector at ui32_addr and program the buffer into it (pages that are all FF stay erased) */
static int32_t burn(uint32_t ui32_addr)
{
/* local variables */
    uint32_t ui32_page;
    uint32_t ui32_index;
    int32_t i32_result;

/* start values */
    ui32_page = 0;
    ui32_index = 0;
    i32_result = UPD_OK;
/* erase */
    fl_wren();
    fl_addr(CMD_SECTOR_ERASE, ui32_addr);
    fl_end();
/* wait until it is done */
    if (fl_wait(ERASE_MS) != FL_OK)
    {
        i32_result = UPD_EFLASH;
    }
/* page by page */
    while ((i32_result == UPD_OK) && (ui32_page < SECTOR))
    {
/* how many bytes at the page's start are erased bytes */
        ui32_index = 0;
        while ((ui32_index < PAGE) && (g_ps_buf->aui8_sec[ui32_page + ui32_index] == ERASED))
        {
            ui32_index++;
        }
/* a page that is not all FF is programmed */
        if (ui32_index != PAGE)
        {
            fl_prog(ui32_addr + ui32_page, g_ps_buf->aui8_sec + ui32_page);
            if (fl_wait(PROG_MS) != FL_OK)
            {
/* the flash did not finish */
                i32_result = UPD_EFLASH;
            }
        }
        ui32_page += PAGE;
    }
    return i32_result;
}

/* the file's sector for flash address ui32_addr into the buffer */
static int32_t load_sector(FFILE *ps_file, uint32_t ui32_addr)
{
/* local variables */
    int32_t i32_result;

/* the image starts behind the header */
    ff_seek(ps_file, HDR + ui32_addr);
    i32_result = read_bytes(ps_file, g_ps_buf->aui8_sec, SECTOR);
    return i32_result;
}

/* bring one flash sector to the file's contents: compare, burn at most twice, compare again */
static int32_t update_sector(FFILE *ps_file, uint32_t ui32_addr, bool b_menu, int32_t *pi32_menu_changed,
                             uint32_t *pui32_written)
{
/* local variables */
    int32_t i32_tries;
    int32_t i32_result;

/* start values */
    i32_tries = 0;
    i32_result = load_sector(ps_file, ui32_addr);
/* as long as the flash differs */
    while ((i32_result == UPD_OK) && !same(ui32_addr))
    {
        if (i32_tries == BURN_TRIES_MAX)
        {
/* still different after two burns */
            i32_result = UPD_EFLASH;
        }
        else if (burn(ui32_addr) != UPD_OK)
        {
            i32_result = UPD_EFLASH;
        }
        else
        {
/* the first burn of a sector is counted */
            if (i32_tries == 0)
            {
                (*pui32_written)++;
                if (b_menu)
                {
/* the menu itself changed */
                    *pi32_menu_changed = (int32_t)ONE;
                }
            }
            i32_tries++;
        }
    }
    return i32_result;
}

/* write the sectors that differ (the menu's last, the skipped range never), verify, delete the file */
int32_t upd_run(const DIRENT *ps_entry, void (*pf_progress)(uint32_t ui32_done, uint32_t ui32_total),
                int32_t *pi32_menu_changed, uint32_t *pui32_written)
{
/* local variables */
    FFILE s_file;
    uint32_t ui32_addr;
    uint32_t ui32_done;
/* bytes to do, the pass (machines, then menu), where the pass ends */
    uint32_t ui32_total;
    uint32_t ui32_pass;
    uint32_t ui32_to;
/* the result */
    int32_t i32_result;

/* start values */
    ui32_addr = 0;
    ui32_done = 0;
    ui32_total = 0;
/* the first pass */
    ui32_pass = 0;
    ui32_to = 0;
    i32_result = read_hdr(&s_file, ps_entry);
/* nothing written yet */
    *pi32_menu_changed = 0;
    *pui32_written = 0;
    if (i32_result == UPD_OK)
    {
/* the sectors to look at: the image without the skipped range */
        ui32_total = img_len();
        if (skip_hi() > skip_lo())
        {
            ui32_total -= skip_hi() - skip_lo();
        }
/* pass 0: the machines (from the menu's end to the image's end), pass 1: the menu */
        for (ui32_pass = 0; (ui32_pass < PASSES) && (i32_result == UPD_OK); ui32_pass++)
        {
            ui32_addr = menu_end();
            ui32_to = img_len();
/* the menu's slot starts at 0 */
            if (ui32_pass == PASS_MENU)
            {
                ui32_addr = 0;
                ui32_to = menu_end();
            }
/* sector by sector */
            while ((ui32_addr < ui32_to) && (i32_result == UPD_OK))
            {
/* the skipped range is never touched */
                if (!((ui32_addr >= skip_lo()) && (ui32_addr < skip_hi())))
                {
                    i32_result = update_sector(&s_file, ui32_addr, ui32_pass == PASS_MENU, pi32_menu_changed,
                                               pui32_written);
/* show how far it is */
                    if (i32_result == UPD_OK)
                    {
                        ui32_done += SECTOR;
                        if ((pf_progress != NULL) && ((ui32_done & WRITE_PROGRESS_MASK) == 0))
                        {
/* the caller's progress display */
                            pf_progress(ui32_done, ui32_total);
                        }
                    }
                }
                ui32_addr += SECTOR;
            }
        }
/* the flash pins go back to the FPGA in every case */
        fl_release();
/* the file is deleted only after every sector checked out */
        if (i32_result == UPD_OK)
        {
            if (fat_delete(0, UPD_NAME11) != FAT_OK)
            {
/* the card failed */
                i32_result = FAT_EIO;
            }
        }
    }
    return i32_result;
}

/* diagnostics: the 4 bytes at an image start (0 the menu, 1-3 the machine positions) */
void upd_slot_bytes(int32_t i32_slot, uint8_t aui8_bytes[UPD_SLOT_BYTES])
{
    uint32_t ui32_addr;

    ui32_addr = IMAGE_START;
/* a machine's slot */
    if (i32_slot != 0)
    {
        ui32_addr = g_aui32_slot[i32_slot - (int32_t)ONE] + IMAGE_START;
    }
/* the bytes, then the flash is given back */
    fl_read(ui32_addr, aui8_bytes, UPD_SLOT_BYTES);
    fl_release();
}

/* a machine is installed where a position's info sector has its tag (the menu starts no other): */
/* UPD_PRESENT if any position has one */
int32_t upd_machines_present(void)
{
/* local variables */
    char ac_line[MCH_LINE_BUF];
    uint8_t ui8_machine;
    int32_t i32_pos;
    int32_t i32_result;

/* start values */
    ui8_machine = 0;
    i32_pos = 0;
    i32_result = 0;
/* the first position with a machine decides */
    while ((i32_pos < MCH_POSITIONS) && (i32_result == 0))
    {
        if (mch_position(i32_pos, ac_line, &ui8_machine) == MCH_PRESENT)
        {
            i32_result = UPD_PRESENT;
        }
        i32_pos++;
    }
    return i32_result;
}

/* The machines. A position is 2 MB: the bitstream in the first megabyte (g_aui32_slot), the ROM */
/* area in the second. The ROM area's first sector is the info sector (tag A5 5A <machine byte> */
/* <complement>, the menu line at 16), the ROM image follows at MCH_ROM_OFFSET. */
/* A machine file (AMenu/ep4_ce15/tools/mk_flash.py): */
/*   0    "LMACHIN1" */
/*   8    board (1 = EP4CE15, 2 = 10CL025) */
/*   12   image length, 16 its CRC-32, 20 ROM length (0: the user's ROMs), 24 its CRC-32, */
/*   28   CRC-32 of the info sector */
/*   252  CRC-32 of bytes 0-251 */
/*   256  the info sector, the ROM data, the image (whole sectors, as the flash returns them) */

/* the flash address of a position's ROM area */
uint32_t mch_rom_area(int32_t i32_pos)
{
    uint32_t ui32_addr;

    ui32_addr = g_aui32_slot[i32_pos] + MB;
    return ui32_addr;
}

/* what is in a position: MCH_PRESENT (menu line and machine byte filled) or 0 = empty */
int32_t mch_position(int32_t i32_pos, char ac_line[MCH_LINE_BUF], uint8_t *pui8_machine)
{
/* local variables */
    uint8_t aui8_info[INFO_READ];
    int32_t i32_index;
    int32_t i32_result;

/* start values */
    i32_index = 0;
    i32_result = 0;
/* the start of the info sector; the flash is given back */
    fl_read(mch_rom_area(i32_pos), aui8_info, sizeof aui8_info);
    fl_release();
    ac_line[0] = 0;
    *pui8_machine = 0;
/* the tag: A5 5A, a machine byte and its complement */
    if ((aui8_info[0] == INFO_TAG_0) && (aui8_info[ONE] == INFO_TAG_1) &&
        (aui8_info[INFO_NOT_OFF] == (uint8_t)~aui8_info[INFO_MACHINE_OFF]))
    {
        i32_result = MCH_PRESENT;
        *pui8_machine = aui8_info[INFO_MACHINE_OFF];
/* the menu line, terminated */
        for (i32_index = 0; i32_index < MCH_LINE_LEN; i32_index++)
        {
            ac_line[i32_index] = (char)aui8_info[INFO_LINE_OFF + i32_index];
        }
        ac_line[MCH_LINE_LEN] = 0;
    }
    return i32_result;
}

/* the first position that holds the machine with this tag byte, or MCH_NONE */
int32_t mch_find(uint8_t ui8_machine)
{
/* local variables */
    char ac_line[MCH_LINE_BUF];
    uint8_t ui8_found;
    int32_t i32_pos;
    int32_t i32_result;

/* start values */
    ui8_found = 0;
    i32_pos = 0;
    i32_result = MCH_NONE;
/* position by position */
    while ((i32_pos < MCH_POSITIONS) && (i32_result == MCH_NONE))
    {
        if ((mch_position(i32_pos, ac_line, &ui8_found) == MCH_PRESENT) && (ui8_found == ui8_machine))
        {
            i32_result = i32_pos;
        }
        i32_pos++;
    }
    return i32_result;
}

/* directory callback: the folder MACHINES in the root folder */
static int32_t mch_dir_cb(const DIRENT *ps_entry, void *p_ctx)
{
/* local variables */
    struct find_upd *ps_find;
    int32_t i32_stop;

/* start values */
    ps_find = (struct find_upd *)p_ctx;
    i32_stop = SCAN_GO_ON;
/* a folder with the stored name */
    if (((ps_entry->ui8_attr & ATTR_DIR) != 0) && (u_memcmp(ps_entry->ac_sname, MCH_DIR11, FAT_NAME11_LEN) == 0))
    {
        ps_find->s_entry = *ps_entry;
        ps_find->i32_hit = UPD_FOUND;
        i32_stop = SCAN_STOP;
    }
    return i32_stop;
}

/* directory callback: every .LMC file goes into the list, until it is full */
static int32_t mch_file_cb(const DIRENT *ps_entry, void *p_ctx)
{
/* local variables */
    int32_t i32_stop;

/* start values */
    (void)p_ctx;
    i32_stop = SCAN_GO_ON;
/* a file with the machine files' extension */
    if (((ps_entry->ui8_attr & ATTR_DIR) == 0) && (u_stricmp(ps_entry->ac_ext, MCH_EXT) == 0))
    {
        g_ps_buf->as_files[g_ps_buf->i32_files].s_entry = *ps_entry;
        g_ps_buf->i32_files++;
/* the list is full */
        if (g_ps_buf->i32_files == MCH_FILES_MAX)
        {
            i32_stop = SCAN_STOP;
        }
    }
    return i32_stop;
}

/* header field of a machine file */
static uint32_t mch_field(uint32_t ui32_off)
{
    uint32_t ui32_value;

    ui32_value = rd32(g_ps_buf->aui8_hdr + ui32_off);
    return ui32_value;
}

/* open a machine file, read and check its header: UPD_OK, UPD_EBAD, MCH_EBOARD, FAT_EIO */
static int32_t mch_read_hdr(FFILE *ps_file, const DIRENT *ps_entry, uint32_t ui32_board)
{
    int32_t i32_result;

/* the buffers, at the first use */
    i32_result = need_buf();
/* the header's bytes; a file shorter than a header is a bad file, not a card error */
    if (i32_result == UPD_OK)
    {
        ff_open(ps_file, ps_entry->ui32_clus, ps_entry->ui32_size);
        i32_result = read_bytes(ps_file, g_ps_buf->aui8_hdr, HDR);
/* too short */
        if ((i32_result != UPD_OK) && (ps_entry->ui32_size < HDR))
        {
            i32_result = UPD_EBAD;
        }
    }
/* the magic text and the header's own checksum */
    if (i32_result == UPD_OK)
    {
        if ((u_memcmp(g_ps_buf->aui8_hdr, MCH_MAGIC, HDR_MAGIC_LEN) != 0) ||
            (crc32(0, g_ps_buf->aui8_hdr, HDR_CRC_OFF) != rd32(g_ps_buf->aui8_hdr + HDR_CRC_OFF)))
        {
            i32_result = UPD_EBAD;
        }
    }
/* the image: whole sectors, at most its megabyte; the ROM data: whole sectors behind the info sector */
    if (i32_result == UPD_OK)
    {
        if ((mch_field(MCH_IMG_LEN_OFF) == 0) || ((mch_field(MCH_IMG_LEN_OFF) % SECTOR) != 0) ||
            (mch_field(MCH_IMG_LEN_OFF) > MB) || ((mch_field(MCH_ROM_LEN_OFF) % SECTOR) != 0) ||
            (mch_field(MCH_ROM_LEN_OFF) > (MB - MCH_ROM_OFFSET)))
        {
            i32_result = UPD_EBAD;
        }
    }
/* the file as long as the header says */
    if (i32_result == UPD_OK)
    {
        if (ps_entry->ui32_size != (HDR + SECTOR + mch_field(MCH_ROM_LEN_OFF) + mch_field(MCH_IMG_LEN_OFF)))
        {
            i32_result = UPD_EBAD;
        }
    }
/* made for this core board */
    if (i32_result == UPD_OK)
    {
        if (mch_field(MCH_BOARD_OFF) != ui32_board)
        {
            i32_result = MCH_EBOARD;
        }
    }
    return i32_result;
}

/* the machine files for this core board in /MACHINES: their number, below 0 = card error */
int32_t mch_list(uint32_t ui32_board, const MCH_FILE **pps_files)
{
/* local variables */
    struct find_upd s_find;
    FFILE s_file;
    int32_t i32_index;
    int32_t i32_kept;
    int32_t i32_result;

/* start values */
    s_find.i32_hit = 0;
    i32_index = 0;
    i32_kept = 0;
    i32_result = need_buf();
/* the folder */
    if (i32_result == UPD_OK)
    {
        g_ps_buf->i32_files = 0;
        if (fat_list(0, mch_dir_cb, &s_find) != FAT_OK)
        {
            i32_result = FAT_EIO;
        }
    }
/* its .LMC files */
    if ((i32_result == UPD_OK) && (s_find.i32_hit != 0))
    {
        if (fat_list(s_find.s_entry.ui32_clus, mch_file_cb, NULL) != FAT_OK)
        {
            i32_result = FAT_EIO;
        }
    }
/* only the files with a good header for this board stay, each with its menu line */
    if (i32_result == UPD_OK)
    {
        for (i32_index = 0; i32_index < g_ps_buf->i32_files; i32_index++)
        {
            if (mch_read_hdr(&s_file, &g_ps_buf->as_files[i32_index].s_entry, ui32_board) == UPD_OK)
            {
/* the line is in the info sector that follows the header */
                if (read_bytes(&s_file, g_ps_buf->aui8_sec, INFO_READ) == UPD_OK)
                {
                    g_ps_buf->as_files[i32_kept].s_entry = g_ps_buf->as_files[i32_index].s_entry;
                    u_memcpy(g_ps_buf->as_files[i32_kept].ac_line, g_ps_buf->aui8_sec + INFO_LINE_OFF, MCH_LINE_LEN);
                    g_ps_buf->as_files[i32_kept].ac_line[MCH_LINE_LEN] = 0;
                    i32_kept++;
                }
            }
        }
        g_ps_buf->i32_files = i32_kept;
        *pps_files = g_ps_buf->as_files;
        i32_result = i32_kept;
    }
    return i32_result;
}

/* the length of a part of the file whose header is in the buffer */
static uint32_t part_len(int32_t i32_part)
{
    uint32_t ui32_len;

    ui32_len = SECTOR;
    if (i32_part == PART_ROM)
    {
        ui32_len = mch_field(MCH_ROM_LEN_OFF);
    }
/* the image */
    if (i32_part == PART_IMAGE)
    {
        ui32_len = mch_field(MCH_IMG_LEN_OFF);
    }
    return ui32_len;
}

/* where a part starts in the file */
static uint32_t part_pos(int32_t i32_part)
{
    uint32_t ui32_pos;

    ui32_pos = HDR;
    if (i32_part != PART_INFO)
    {
        ui32_pos += SECTOR;
    }
/* the image follows the ROM data */
    if (i32_part == PART_IMAGE)
    {
        ui32_pos += mch_field(MCH_ROM_LEN_OFF);
    }
    return ui32_pos;
}

/* check a machine file: header, board, sizes, the three checksums */
int32_t mch_check(const DIRENT *ps_entry, uint32_t ui32_board,
                  void (*pf_progress)(uint32_t ui32_done, uint32_t ui32_total))
{
/* local variables */
    FFILE s_file;
    uint32_t ui32_off;
    uint32_t ui32_done;
/* bytes to check, the checksum so far, the checksum the header gives */
    uint32_t ui32_total;
    uint32_t ui32_crc;
    uint32_t ui32_want;
/* the part, the result */
    int32_t i32_part;
    int32_t i32_result;

/* start values */
    ui32_off = 0;
    ui32_done = 0;
    ui32_total = 0;
/* no checksum yet */
    ui32_crc = 0;
    ui32_want = 0;
    i32_part = 0;
    i32_result = mch_read_hdr(&s_file, ps_entry, ui32_board);
    if (i32_result == UPD_OK)
    {
        ui32_total = ps_entry->ui32_size - HDR;
    }
/* the parts follow the header in the file's order: info sector, ROM data, image */
    for (i32_part = 0; (i32_part < PARTS) && (i32_result == UPD_OK); i32_part++)
    {
        ui32_crc = 0;
        for (ui32_off = 0; (ui32_off < part_len(i32_part)) && (i32_result == UPD_OK); ui32_off += SECTOR)
        {
            i32_result = read_bytes(&s_file, g_ps_buf->aui8_sec, SECTOR);
/* into the checksum */
            if (i32_result == UPD_OK)
            {
                ui32_crc = crc32(ui32_crc, g_ps_buf->aui8_sec, SECTOR);
/* show how far it is */
                if ((pf_progress != NULL) && ((ui32_done & CHECK_PROGRESS_MASK) == 0))
                {
                    pf_progress(ui32_done, ui32_total);
                }
                ui32_done += SECTOR;
            }
        }
/* the part's checksum in the header */
        ui32_want = mch_field(MCH_INFO_CRC_OFF);
        if (i32_part == PART_ROM)
        {
            ui32_want = mch_field(MCH_ROM_CRC_OFF);
        }
        if (i32_part == PART_IMAGE)
        {
            ui32_want = mch_field(MCH_IMG_CRC_OFF);
        }
/* it must match */
        if ((i32_result == UPD_OK) && (ui32_crc != ui32_want))
        {
            i32_result = UPD_EBAD;
        }
    }
    return i32_result;
}

/* erase one flash sector: UPD_OK or UPD_EFLASH */
static int32_t erase_sector(uint32_t ui32_addr)
{
    int32_t i32_result;

    i32_result = UPD_OK;
    fl_wren();
    fl_addr(CMD_SECTOR_ERASE, ui32_addr);
    fl_end();
/* wait until it is done */
    if (fl_wait(ERASE_MS) != FL_OK)
    {
        i32_result = UPD_EFLASH;
    }
    return i32_result;
}

/* bring a run of flash sectors to a part of the file: UPD_OK, UPD_EFLASH, FAT_EIO */
static int32_t write_part(FFILE *ps_file, int32_t i32_part, uint32_t ui32_flash, uint32_t *pui32_done,
                          uint32_t ui32_total, void (*pf_progress)(uint32_t ui32_done, uint32_t ui32_total),
                          uint32_t *pui32_written)
{
/* local variables */
    uint32_t ui32_off;
    int32_t i32_tries;
    int32_t i32_result;

/* start values */
    ui32_off = 0;
    i32_tries = 0;
    i32_result = UPD_OK;
/* sector by sector */
    while ((ui32_off < part_len(i32_part)) && (i32_result == UPD_OK))
    {
        ff_seek(ps_file, part_pos(i32_part) + ui32_off);
        i32_result = read_bytes(ps_file, g_ps_buf->aui8_sec, SECTOR);
        i32_tries = 0;
/* as long as the flash differs: burn, at most twice */
        while ((i32_result == UPD_OK) && !same(ui32_flash + ui32_off))
        {
            if ((i32_tries == BURN_TRIES_MAX) || (burn(ui32_flash + ui32_off) != UPD_OK))
            {
                i32_result = UPD_EFLASH;
            }
            else
            {
/* the first burn of a sector is counted */
                if (i32_tries == 0)
                {
                    (*pui32_written)++;
                }
                i32_tries++;
            }
        }
/* show how far it is */
        if (i32_result == UPD_OK)
        {
            *pui32_done += SECTOR;
            if ((pf_progress != NULL) && ((*pui32_done & WRITE_PROGRESS_MASK) == 0))
            {
                pf_progress(*pui32_done, ui32_total);
            }
        }
        ui32_off += SECTOR;
    }
    return i32_result;
}

/* install a checked machine file into a position */
int32_t mch_install(const DIRENT *ps_entry, int32_t i32_pos,
                    void (*pf_progress)(uint32_t ui32_done, uint32_t ui32_total), uint32_t *pui32_written)
{
/* local variables */
    FFILE s_file;
    char ac_line[MCH_LINE_BUF];
    uint8_t aui8_tag[INFO_TAG_LEN];
/* the machine that was in the position */
    uint8_t ui8_old;
    int32_t i32_old;
/* progress, the ROM area, the result */
    uint32_t ui32_done;
    uint32_t ui32_total;
    uint32_t ui32_area;
    int32_t i32_result;

/* start values */
    ui8_old = 0;
    i32_old = 0;
    ui32_done = 0;
/* the position's ROM area */
    ui32_total = 0;
    ui32_area = mch_rom_area(i32_pos);
    *pui32_written = 0;
/* what the position holds now, then the file's header (the board was checked by mch_check) */
    i32_old = mch_position(i32_pos, ac_line, &ui8_old);
    i32_result = mch_read_hdr(&s_file, ps_entry, 0);
    if (i32_result == MCH_EBOARD)
    {
        i32_result = UPD_OK;
    }
    if (i32_result == UPD_OK)
    {
        ui32_total = ps_entry->ui32_size - HDR;
/* the file's tag: is it the machine that was there? */
        ff_seek(&s_file, HDR);
        i32_result = read_bytes(&s_file, aui8_tag, sizeof aui8_tag);
    }
/* the info sector goes first: the position is empty until everything is written */
    if (i32_result == UPD_OK)
    {
        i32_result = erase_sector(ui32_area);
    }
/* the bitstream */
    if (i32_result == UPD_OK)
    {
        i32_result = write_part(&s_file, PART_IMAGE, g_aui32_slot[i32_pos], &ui32_done, ui32_total, pf_progress,
                                pui32_written);
    }
/* the ROM data; a file without them keeps the same machine's ROMs and removes another machine's */
    if (i32_result == UPD_OK)
    {
        if (mch_field(MCH_ROM_LEN_OFF) != 0)
        {
            i32_result = write_part(&s_file, PART_ROM, ui32_area + MCH_ROM_OFFSET, &ui32_done, ui32_total,
                                    pf_progress, pui32_written);
        }
        else if ((i32_old != MCH_PRESENT) || (ui8_old != aui8_tag[INFO_MACHINE_OFF]))
        {
            i32_result = erase_sector(ui32_area + MCH_ROM_OFFSET);
        }
        else
        {
/* the same machine: its ROMs stay */
        }
    }
/* the info sector last: the machine is installed from here on */
    if (i32_result == UPD_OK)
    {
        i32_result = write_part(&s_file, PART_INFO, ui32_area, &ui32_done, ui32_total, pf_progress, pui32_written);
    }
    if ((i32_result == UPD_OK) && (pf_progress != NULL))
    {
        pf_progress(ui32_total, ui32_total);
    }
/* the flash pins go back to the FPGA in every case */
    fl_release();
    return i32_result;
}
