# ESPLinkTest — first hardware test of the ESP32 system controller

Test sketch for step 1 of the "Next stage" in `docs/PLAN.md`: the ESP32 owns the SD card and talks to the FPGA
(`LSpectrum/rtl/esp_link.v`) over an SPI link. No Bluetooth and no loader in this sketch.

## Wiring

| Signal | ESP32 (DOIT 30-pin) | Other end |
|---|---|---|
| SD SCK | GPIO18 | BFF JP3.2 |
| SD MISO | GPIO19 | BFF JP3.3 |
| SD MOSI | GPIO23 | BFF JP3.4 |
| SD CS | GPIO5 | BFF JP1.7 (TX) |
| SD power | 3V3, GND | BFF 3.3V, GND |
| Link SCK | GPIO14 | U7.9 (FPGA P1) |
| Link MOSI | GPIO13 | U7.10 (FPGA P2) |
| Link CS_N | GPIO33 | U7.11 (FPGA N1) |
| Link MISO | GPIO35 (input only) | U7.7 (FPGA R1) |
| Link IRQ | GPIO34 (input only) | U7.8 (FPGA R2) |
| GND | GND | U7.1 or U7.2 |


## Build / flash

- FPGA: the normal LSpectrum build (`LSpectrum/output_files/LSpectrum.jic` in the flash).
- ESP32 (in `tests/`): board ESP32 Dev Module, `arduino-cli compile -b esp32:esp32:esp32 -u -p COM10 ESPLinkTest`.
  Flash `LSpectrum/esp32_v1` (I/O board revision 1) or `LSpectrum/esp32_v2` (revision 2) again afterwards (loader + Bluetooth).

## Test sequence (USB serial 115200, line ending New Line)

1. Reset: the banner shows `SD: ok (... MB)` and `FPGA core ID: 5a580001`.
2. `rd 18` twice: the 56 MHz timer register must change.
3. `ls` / `ls /games/a1`: the listing appears on the TV (full-screen OSD); `osd off` hides it.
4. `keys`: press keys (also F12, cursor keys) — IRQ lines with the key bits and raw reports.
5. `memtest 5`: freezes the Spectrum, writes random data over the screen (visible), reads it back, restores
   the screen, unfreezes. Expect 0 errors, `screen restored: yes`, link stat 00000000.
6. `speed`: MRD/MWR throughput (expect roughly 900 KB/s at 8 MHz SCK).
