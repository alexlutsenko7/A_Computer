/* loader.h -- the SD tape loader (main.cpp and the files around it, on esp_hw.cpp).
 * Starts when the FPGA answers the link with the LSpectrum core ID. */
#ifndef LOADER_H
#define LOADER_H

void loader_begin(void);    /* setup(): link + SD pins; starts the loader if the FPGA answers */
void loader_poll(void);     /* loop(): keeps looking for the FPGA (configured later, reprogrammed) */
bool loader_running(void);
void loader_check(void);    /* loop(): a stuck loader task is reported, after 15 s the ESP32 restarts */
#ifdef __cplusplus
class Print;
void loader_info(Print &out);   /* "loader" command: task state, last link frame, stack code addresses */
#endif

#endif
