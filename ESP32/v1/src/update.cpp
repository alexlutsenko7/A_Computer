/* update.c -- flash update from the SD card, run while the machine menu (AMenu) is on the link. */
/* LUPDATE.BIN (made by AMenu/ep4_ce15/tools/mk_update.py from the same .cof as L.jic): */
/*   0    "LUPDATE1" */
/*   8    image length (bytes from flash address 0, a multiple of 4096) */
/*   12   CRC-32 of the image (zlib) */
/*   16   skip start, 20 skip end: never written (the C64 ROMs the ESP32 installed, 0x580000-0x5FFFFF) */
/*   24   menu end (0x100000): the factory image's slot, written last */
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
/* machine slots, where an image starts inside its slot, and the sync byte as SPI reads it */
#define SLOTS 4
#define IMAGE_START 0x20u
#define SYNC_BYTE_AS_READ 0x56
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
};

/* what the search for the file leaves */
struct find_upd
{
    DIRENT s_entry;
    int32_t i32_hit;
};

/* AMenu MACHINE_ADDR (1 MB slots) */
static const uint32_t g_aui32_slot[SLOTS] = { 0x100000u, 0x200000u, 0x300000u, 0x400000u };
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

/* open the file, read and check its header: UPD_OK, UPD_EBAD, FAT_EIO */
static int32_t read_hdr(FFILE *ps_file, const DIRENT *ps_entry)
{
    int32_t i32_result;

    i32_result = UPD_OK;
/* the buffers, at the first use */
    if (g_ps_buf == NULL)
    {
        g_ps_buf = (struct ubuf *)calloc(ONE, sizeof *g_ps_buf);
/* no memory */
        if (g_ps_buf == NULL)
        {
            i32_result = FAT_EIO;
        }
    }
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

/* diagnostics: the 4 bytes at a slot's image start (slot 0 the menu, 1-4 the machines) */
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

/* a configuration image starts 32 bytes into its slot: FF before, then the sync byte 6A, which reads */
/* 56 over SPI (LSB first in the flash; seen on hardware). An erased slot reads FF, a slot the loader */
/* .jic cleared reads 00 */
int32_t upd_machines_present(void)
{
/* local variables */
    uint8_t aui8_bytes[UPD_SLOT_BYTES];
    uint32_t ui32_slot;
    int32_t i32_result;

/* start values */
    ui32_slot = 0;
    i32_result = 0;
/* the first slot with an image decides */
    while ((ui32_slot < SLOTS) && (i32_result == 0))
    {
        fl_read(g_aui32_slot[ui32_slot] + IMAGE_START, aui8_bytes, sizeof aui8_bytes);
        if (aui8_bytes[0] == SYNC_BYTE_AS_READ)
        {
/* an image */
            i32_result = UPD_PRESENT;
        }
        ui32_slot++;
    }
/* the flash is given back */
    fl_release();
    return i32_result;
}
