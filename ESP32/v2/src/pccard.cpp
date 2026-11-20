/* pccard.cpp -- test option NEXT_SERIAL_CARD: LNext's SD card is a disk image on the PC (pccard.h) */
#ifdef NEXT_SERIAL_CARD

#include <Arduino.h>
#include "pccard.h"

/* a sector's bytes */
#define SECTOR 512u
/* the image's size: 2 GB */
#define IMAGE_SECTORS 4194304u
/* the PC's answer starts with this byte */
#define MARK 0xA5
/* milliseconds to wait for the PC, and how often a request is sent again (another task's */
/* text can get into a request line; the loader must not be silent for seconds) */
#define WAIT_MS 250u
#define TRIES 8u
/* results */
#define OK_RESULT 0
#define ERROR_RESULT (-1)
/* hex digits of a byte, the high digit's shift, a digit's mask */
#define HEX_PER_BYTE 2u
#define NIBBLE_SHIFT 4
#define NIBBLE_MASK 0x0Fu

/* a sector as hex text */
static char g_ac_hex[(SECTOR * HEX_PER_BYTE) + HEX_PER_BYTE];
static const char g_ac_digits[] = "0123456789ABCDEF";

/* wait for the PC's mark byte: true = it came */
static bool wait_mark(void)
{
/* local variables */
    uint32_t ui32_start;
    bool b_found;

/* start values */
    ui32_start = millis();
    b_found = false;
    while (!b_found && ((millis() - ui32_start) < WAIT_MS))
    {
        if (Serial.available() > 0)
        {
            b_found = Serial.read() == MARK;
        }
    }
    return b_found;
}

/* the image's size in sectors */
uint32_t pccard_sectors(void)
{
    return IMAGE_SECTORS;
}

/* what the PC sent and nobody took is dropped */
static void drop_input(void)
{
    while (Serial.available() > 0)
    {
        Serial.read();
    }
}

/* one sector from the PC: 0 = ok */
int32_t pccard_read(uint32_t ui32_lba, uint8_t *pui8_buf)
{
/* local variables */
    uint32_t ui32_try;
    int32_t i32_result;

/* start values */
    ui32_try = 0;
    i32_result = ERROR_RESULT;
    Serial.setTimeout(WAIT_MS);
    while ((i32_result != OK_RESULT) && (ui32_try < TRIES))
    {
        drop_input();
        Serial.printf("\n#R%lu\n", (unsigned long)ui32_lba);
/* the sector's bytes follow the mark */
        if (wait_mark())
        {
            if (Serial.readBytes(pui8_buf, SECTOR) == SECTOR)
            {
                i32_result = OK_RESULT;
            }
        }
        ui32_try++;
    }
    return i32_result;
}

/* one sector to the PC: 0 = ok */
int32_t pccard_write(uint32_t ui32_lba, const uint8_t *pui8_buf)
{
/* local variables */
    uint32_t ui32_index;
    uint32_t ui32_try;
    int32_t i32_result;

/* start values */
    ui32_index = 0;
    ui32_try = 0;
    i32_result = ERROR_RESULT;
    for (ui32_index = 0; ui32_index < SECTOR; ui32_index++)
    {
        g_ac_hex[ui32_index * HEX_PER_BYTE] = g_ac_digits[pui8_buf[ui32_index] >> NIBBLE_SHIFT];
        g_ac_hex[(ui32_index * HEX_PER_BYTE) + 1u] = g_ac_digits[pui8_buf[ui32_index] & NIBBLE_MASK];
    }
/* the text ends */
    g_ac_hex[SECTOR * HEX_PER_BYTE] = 0;
    while ((i32_result != OK_RESULT) && (ui32_try < TRIES))
    {
        drop_input();
        Serial.printf("\n#W%lu %s\n", (unsigned long)ui32_lba, g_ac_hex);
        if (wait_mark())
        {
            i32_result = OK_RESULT;
        }
        ui32_try++;
    }
    return i32_result;
}

#endif
