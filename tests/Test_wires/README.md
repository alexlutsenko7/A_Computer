# Test_wires — ESP32 ↔ FPGA wiring test

Checks the 10 signal wires between the ESP32 and the FPGA (the LSpectrum pinout: SPI link + Bluetooth I2S/UART)
and the SD card on the ESP32. The results go to the ESP32's USB serial port.

| Direction | ESP32 | FPGA pin | U7 | Signal |
|---|---|---|---|---|
| FPGA → ESP32 | GPIO35 | R1 | U7.7 | ESP_MISO |
| FPGA → ESP32 | GPIO34 | R2 | U7.8 | ESP_IRQ |
| FPGA → ESP32 | GPIO22 | F1 | U7.19 | BT_DATA |
| FPGA → ESP32 | GPIO16 | F2 | U7.20 | BT_TX |
| ESP32 → FPGA | GPIO14 | P1 | U7.9 | ESP_SCK |
| ESP32 → FPGA | GPIO13 | P2 | U7.10 | ESP_MOSI |
| ESP32 → FPGA | GPIO33 | N1 | U7.11 | ESP_CS_N |
| ESP32 → FPGA | GPIO26 | H1 | U7.17 | BT_BCLK |
| ESP32 → FPGA | GPIO25 | H2 | U7.18 | BT_LRCK |
| ESP32 → FPGA | GPIO17 | E1 | U7.21 | BT_RX |
| SD card | 18 SCK, 19 MISO, 23 MOSI, 5 CS | – | – | – |

## How it works

- **FPGA** (`fpga/`, top `Test_wires`, 50 MHz, no PLL): every FPGA output repeatedly sends a 10-byte UART frame
  (115200 baud, ~1 ms). Byte 1 names the pin the frame leaves on (C1 = R1, C2 = R2, C3 = F1, C4 = F2). The frame also
  reports the levels on the 6 FPGA inputs and a rising-edge counter for each. The inputs have weak pull-ups, so an
  open wire reads 1. The LED blinks while the design runs.
- **ESP32** (`esp32/Test_wires/`): samples all 10 pins every 2 µs (4.3 samples per bit) and decodes the frames in
  software. It warns if the sampling loop ever falls behind.
  1. **SD**: mounts the card (20 MHz, then 4 MHz and 400 kHz if that fails) and lists the root folder.
  2. **FPGA → ESP32**: all ESP32 pins are inputs at this point. Each of the 4 input wires shows OK, SWAPPED (which
     FPGA pin it really comes from), stuck/open, or noisy/shorted. If an FPGA output turns up on one of the
     ESP32 *output* pins, the sketch reports DANGER and does not drive any pins, so two outputs never fight.
  3. **ESP32 → FPGA levels**: 14 patterns (all 0, all 1, walking 1, walking 0) on the 6 outputs. For each FPGA input
     it reports OK, SWAPPED (which GPIO drives it), always 1 (open), always 0 (short to GND), or which two wires are
     shorted together.
  4. **Pulses**: 100 pulses at 2 MHz on each output in turn, checked against the FPGA's edge counters, so it also
     finds missing edges, ringing (extra edges) and crosstalk (counts on other wires). Then a real 8 MHz SPI burst
     on SCK/MOSI (link speed: 200 / 100 edges expected).
  5. **Summary**: one line per wire, then `ALL WIRES OK` or `SOME TESTS FAILED`.

The FPGA → ESP32 wires are only tested at 115200 baud here. The 8 MHz MISO return path is tested by `ESPLinkTest/`
(`memtest`, `speed`), which runs with the normal LSpectrum bitstream.

## Build / run

1. FPGA (in `Test_wires/fpga`): `quartus_sh --flow compile Test_wires`, then load `output_files/Test_wires.sof` over
   JTAG (`quartus_pgm -c USB-Blaster -m JTAG -o "p;output_files/Test_wires.sof"`). The flash is not touched;
   power-cycle the board to get LSpectrum back.
2. ESP32 (in `Test_wires/esp32`): `arduino-cli compile -b esp32:esp32:esp32 -u -p COM10 Test_wires`
   (or open `Test_wires.ino` in the Arduino IDE, board "ESP32 Dev Module").
3. Open the serial monitor at 115200 with line ending "New Line", then press the ESP32's EN (reset) button: the
   whole test runs. Load the FPGA first; if you load it later, press Enter to run the test again.
4. Flash `LSpectrum/esp32` back onto the ESP32 afterwards.

Commands: Enter / `all` = everything, `sd`, `ls <path>`, `back`, `fwd`, `fast`,
`set <hex>` (drive the 6 outputs to a fixed pattern for a multimeter; bit 0 = GPIO14 … bit 5 = GPIO17),
`watch` (print what the FPGA sees once a second), `raw` (levels, edge counts and the first 120 samples of all 10 pins),
`find` (look for the FPGA frames on every free ESP32 pin: shows where a misplaced wire landed),
`sdprobe` (bit-banged SD reset command CMD0 with every assignment of GPIO5/18/19/23, expect answer 01: finds swapped
SD wires), `help`.

## Reading the results

- `always 0 (ESP32 pull-down)` on GPIO22/16, or `always 1 (FPGA pull-up)` on an FPGA input: the wire is open,
  or it is on the wrong pin.
- GPIO34/35 cannot have a pull resistor: an open wire there floats and shows up as `always x` or `edges but no
  valid frame`.
- `No frames from the FPGA at all`: Test_wires.sof is not loaded (the LED is not blinking), or there is no common GND.
- The SD card must be FAT16/FAT32. If it is only found at a lower clock, check the SPI wires and ground; a 10k-47k
  pull-up from MISO to 3V3 helps (the sketch also turns on the ESP32's internal pull-up).

## Simulation

`fpga/sim/run_sim.sh` (Questa FSE): drives levels, 37 pulses at 2 MHz and 200 pulses at 8 MHz, samples the outputs
at 1 MHz, and `check_samples.py` decodes them with the sketch's algorithm. Expected result: 14 frames per output,
0 framing errors, ids C1-C4, final counters 200 / 37.

## Results on hardware (2026-10-14)

The first run found the SD card missing (GPIO18 / SCK was held low). After the user re-soldered it: **ALL WIRES OK**.
The SD card (SDHC, 15 GB) is found at 20 MHz and the root folder is listed. All 10 ESP32 ↔ FPGA wires pass the
static levels, the 2 MHz pulses and the 8 MHz SPI burst, with no crosstalk.
