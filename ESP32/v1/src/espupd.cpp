/* espupd.c -- the ESP32's own firmware from the SD card, run while the machine menu is on the link. */
/* LESP32.BIN is the sketch's application image as arduino-cli builds it (v1.ino.bin, not the */
/* merged image with the boot loader): it starts with the magic byte E9, the chip ID at 12-13 is 0 */
/* (ESP32). It goes into the firmware slot not running now; only after the whole image is written */
/* and verified (esp_ota_end: checksum + SHA-256) does the ESP32 boot from that slot. A bad file or */
/* a power cut leaves the running firmware as it is. The file is deleted once the slot is selected. */
#include <stdlib.h>
#include "fat.h"
#include "espupd.h"
/* the loader's own string functions */
#include "util.h"

/* bytes read from the card and written to the slot in one piece */
#define CHUNK 4096u
/* one firmware slot (partitions app0 / app1, 1.25 MB) */
#define MAX_SIZE 0x140000u
/* the smallest file that can be an image */
#define MIN_SIZE 256u
/* the image header: bytes checked, the magic byte, the two bytes of the chip ID (0 = ESP32) */
#define HEADER_LEN 16u
#define HEADER_MAGIC_OFF 0
#define HEADER_MAGIC 0xE9
/* where the chip ID is */
#define HEADER_CHIP_LOW_OFF 12
#define HEADER_CHIP_HIGH_OFF 13
/* the directory callback's answers */
#define SCAN_GO_ON 0
#define SCAN_STOP 1

/* what the search for the file leaves */
struct find_esp
{
    DIRENT s_entry;
    int32_t i32_hit;
};

/* directory callback: stop at the file LESP32.BIN */
static int32_t find_cb(const DIRENT *ps_entry, void *p_ctx)
{
/* local variables */
    struct find_esp *ps_find;
    int32_t i32_stop;

/* start values */
    ps_find = (struct find_esp *)p_ctx;
    i32_stop = SCAN_GO_ON;
/* a file, not a folder, with the stored name */
    if (((ps_entry->ui8_attr & ATTR_DIR) == 0) &&
        (u_memcmp(ps_entry->ac_sname, ESPUPD_NAME11, FAT_NAME11_LEN) == 0))
    {
        ps_find->s_entry = *ps_entry;
        ps_find->i32_hit = ESPUPD_FOUND;
/* found: the scan ends */
        i32_stop = SCAN_STOP;
    }
    return i32_stop;
}

/* LESP32.BIN in the root folder: ESPUPD_FOUND (entry filled), 0 = none, below 0 = card error */
int32_t espupd_find(DIRENT *ps_entry)
{
/* local variables */
    struct find_esp s_find;
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

/* read ui32_count bytes of the file into a buffer: FAT_OK or FAT_EIO */
static int32_t read_piece(FFILE *ps_file, uint8_t *pui8_buf, uint32_t ui32_count)
{
/* local variables */
    uint32_t ui32_index;
    int32_t i32_char;
    int32_t i32_result;

/* start values */
    ui32_index = 0;
    i32_char = 0;
    i32_result = FAT_OK;
/* byte by byte, until the card fails */
    while ((ui32_index < ui32_count) && (i32_result == FAT_OK))
    {
        i32_char = ff_getc(ps_file);
        if (i32_char < 0)
        {
/* the card failed, or the file ended early */
            i32_result = FAT_EIO;
        }
        else
        {
/* one more byte in the buffer */
            pui8_buf[ui32_index] = (uint8_t)i32_char;
            ui32_index++;
        }
    }
    return i32_result;
}

/* write the file into the unused firmware slot, verify it, select the slot, delete the file */
int32_t espupd_run(const DIRENT *ps_entry, void (*pf_progress)(uint32_t ui32_done, uint32_t ui32_total))
{
/* local variables */
    FFILE s_file;
    uint8_t *pui8_buf;
    uint32_t ui32_done;
/* how far the copy is, the size of the next piece */
    uint32_t ui32_piece;
    bool b_slot_open;
    int32_t i32_result;

/* start values */
    pui8_buf = NULL;
    ui32_done = 0;
    ui32_piece = 0;
/* the slot is open between ota_begin and ota_end / ota_abort */
    b_slot_open = false;
    i32_result = ESPUPD_OK;
/* the size must be possible for an image */
    if ((ps_entry->ui32_size < MIN_SIZE) || (ps_entry->ui32_size > MAX_SIZE))
    {
        i32_result = ESPUPD_EBAD;
    }
/* the buffer for one piece */
    if (i32_result == ESPUPD_OK)
    {
        pui8_buf = (uint8_t *)malloc(CHUNK);
        if (pui8_buf == NULL)
        {
/* no memory */
            i32_result = FAT_EIO;
        }
    }
/* the header: magic byte and chip */
    if (i32_result == ESPUPD_OK)
    {
        ff_open(&s_file, ps_entry->ui32_clus, ps_entry->ui32_size);
        i32_result = read_piece(&s_file, pui8_buf, HEADER_LEN);
    }
/* is it firmware for this chip? */
    if (i32_result == ESPUPD_OK)
    {
        if ((pui8_buf[HEADER_MAGIC_OFF] != HEADER_MAGIC) || (pui8_buf[HEADER_CHIP_LOW_OFF] != 0) ||
            (pui8_buf[HEADER_CHIP_HIGH_OFF] != 0))
        {
            i32_result = ESPUPD_EBAD;
        }
    }
/* open the unused slot */
    if (i32_result == ESPUPD_OK)
    {
        if (ota_begin(ps_entry->ui32_size) != 0)
        {
            i32_result = ESPUPD_EWRITE;
        }
        else
        {
/* from now on the slot has to be closed or given up */
            b_slot_open = true;
/* the image is written from its first byte */
            ff_seek(&s_file, 0);
        }
    }
/* the image, piece by piece */
    while ((i32_result == ESPUPD_OK) && (ui32_done < ps_entry->ui32_size))
    {
        ui32_piece = ps_entry->ui32_size - ui32_done;
/* the last piece may be shorter */
        if (ui32_piece > CHUNK)
        {
            ui32_piece = CHUNK;
        }
        i32_result = read_piece(&s_file, pui8_buf, ui32_piece);
/* into the slot */
        if (i32_result == ESPUPD_OK)
        {
            if (ota_write(pui8_buf, ui32_piece) != 0)
            {
                i32_result = ESPUPD_EWRITE;
            }
        }
/* show how far it is */
        if (i32_result == ESPUPD_OK)
        {
            ui32_done += ui32_piece;
/* the caller's progress display */
            if (pf_progress != NULL)
            {
                pf_progress(ui32_done, ps_entry->ui32_size);
            }
        }
    }
/* the buffer is not needed any more (free takes NULL) */
    free(pui8_buf);
/* a failed write gives the slot up; a complete one is verified and selected */
    if (b_slot_open)
    {
        if (i32_result != ESPUPD_OK)
        {
            ota_abort();
        }
/* verify the new firmware and select it */
        else if (ota_end() != 0)
        {
/* the image did not verify */
            i32_result = ESPUPD_EWRITE;
        }
        else if (fat_delete(0, ESPUPD_NAME11) != FAT_OK)
        {
/* the new firmware is selected, but the file is still on the card */
            i32_result = FAT_EIO;
        }
        else
        {
/* done: the caller restarts the ESP32 */
        }
    }
    return i32_result;
}
