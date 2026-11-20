/* pccard.h -- test option NEXT_SERIAL_CARD: LNext's SD card is a disk image on the PC */
#ifndef PCCARD_H
#define PCCARD_H

/* the headers this one needs */
#include <stdint.h>

/* Only in a build with -DNEXT_SERIAL_CARD (never in a product build): while LNext is the machine, */
/* the card's sectors are not the real card's but come from and go to a PC program over the USB */
/* serial port (ESP32_test/v2/tools/next_pccard.py with a disk image). The real card is not touched. */
/* The serial port runs at 921600 baud in such a build and takes no console commands. */
/*   read:  the ESP32 sends "#R<sector>\n", the PC answers the byte A5 and the 512 bytes */
/*   write: the ESP32 sends "#W<sector> <1024 hex digits>\n", the PC answers the byte A5 */

/* the image's size in sectors */
uint32_t pccard_sectors(void);
/* one sector from the PC: 0 = ok */
int32_t pccard_read(uint32_t ui32_lba, uint8_t *pui8_buf);
/* one sector to the PC: 0 = ok */
int32_t pccard_write(uint32_t ui32_lba, const uint8_t *pui8_buf);

#endif
