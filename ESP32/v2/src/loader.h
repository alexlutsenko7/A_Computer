/* loader.h -- the SD tape loader (main.cpp and the files around it, on esp_hw.cpp). */
/* Starts when the FPGA answers the link with the LSpectrum core ID. */
#ifndef LOADER_H
#define LOADER_H

/* setup(): link + SD pins; starts the loader if the FPGA answers */
void loader_begin(void);
/* loop(): keeps looking for the FPGA (configured later, reprogrammed) */
void loader_poll(void);
/* a loader task runs */
bool loader_running(void);
/* loop(): a stuck loader task is reported, after 15 s the ESP32 restarts */
void loader_check(void);
#ifdef __cplusplus
class Print;
/* "loader" command: task state, last link frame, stack code addresses */
void loader_info(Print &r_out);
#endif

#endif
