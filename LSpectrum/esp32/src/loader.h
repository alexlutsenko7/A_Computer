/* loader.h -- the SD tape loader (main.cpp and the files around it, on esp_hw.cpp).
 * Starts when the FPGA answers the link with the LSpectrum core ID. */
#ifndef LOADER_H
#define LOADER_H

void loader_begin(void);    /* setup(): link + SD pins; starts the loader if the FPGA answers */
void loader_poll(void);     /* loop(): keeps looking for the FPGA (configured later, reprogrammed) */
bool loader_running(void);

#endif
