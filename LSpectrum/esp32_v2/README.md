# esp32_v2 — the system controller (ESP32) for LSpectrum and L64

**Version 2: for I/O board revision 2** (`Extra_PCB_CycloneIV_R2/`, ESP32-WROVER-E-N16R8 on the board, CP2102N on USB-C,
CH9350L USB keyboard). Started 2026-11-03 as a copy of `../esp32_v1/` (I/O board revision 1).

`esp32_v2.ino` runs on the ESP32-WROVER-E-N16R8 module of the I/O board (USB-C via the CP2102N). It serves whichever machine
the menu started (LSpectrum = ZX Spectrum 128K, L64 = Commodore 64), and does two jobs:

- **SD tape loader** (`src/`): owns the SD card and runs the browser (up to 4,096 entries per folder,
  the list in the PSRAM; 320 in internal RAM if no PSRAM is found; names up to 29 characters), TAP/TZX playback, recording, .z80 load/save
  and the F3 menu, driving the FPGA's loader hardware (`rtl/tape_loader.v`) over an SPI link (`rtl/esp_link.v`).
- **Bluetooth audio**: an A2DP **source**, like a phone, streaming 44.1 kHz audio to a Bluetooth speaker or
  headphones. The audio comes from the FPGA over I2S (`rtl/bt_i2s.v`); a built-in test tone can be used instead
  (`src tone`).

## Wiring (on the Extra_PCB_CycloneIV I/O board: ESP32 dev board in sockets U2, link through the board's J1 to U8)

| I/O board J1 | U8 pin | FPGA pin | Signal | Direction | ESP32 |
|---|---|---|---|---|---|
| 10 | 9 | AA14 | ESP_MISO (link data) | FPGA → ESP32 | GPIO35 (input only) |
| 11 | 12 | AB15 | ESP_IRQ (not used yet) | FPGA → ESP32 | GPIO34 (input only) |
| 7 | 8 | AB13 | ESP_SCK (link clock, 8 MHz) | ESP32 → FPGA | GPIO14 |
| 8 | 7 | AA13 | ESP_MOSI (link data) | ESP32 → FPGA | GPIO13 |
| 9 | 10 | AB14 | ESP_CS_N (link select) | ESP32 → FPGA | GPIO33 |
| 12 | 11 | AA15 | BT_BCLK | ESP32 → FPGA | GPIO26 (I2S BCLK, 1.4112 MHz) |
| 13 | 14 | AB16 | BT_LRCK | ESP32 → FPGA | GPIO25 (I2S WS, 44.1 kHz) |
| 14 | 13 | AA16 | BT_DATA | FPGA → ESP32 | GPIO22 (I2S DIN) |
| 15 | 16 | AB17 | BT_TX (UART, F3 menu) | FPGA → ESP32 | GPIO27 (RX2) |
| 16 | 15 | AA17 | BT_RX (UART, answers) | ESP32 → FPGA | GPIO21 (TX2) |

SD card (microSD socket J7 on the I/O board): SCK GPIO18, MISO GPIO19, MOSI GPIO23, CS GPIO5. FAT16/FAT32.

All 3.3 V, no level shifting. The ESP32 gets 5 V into its VIN from the I/O board (core board VIN via J1/U8 63/64).
The ESP32 is the I2S master, so BT and I2S run from the same clock. The FPGA has weak pull-ups on BCLK/LRCK, and
the ESP32 a pull-down on DIN: with either side unplugged the result is silence, not noise. Full wiring:
`docs/LSpectrum_Connection.docx`; a wiring test: `tests/Test_wires/`.

Sound sent: AY + beeper, the same as the analog outputs, mono in both channels, low-passed and DC-free (silence = 0).

## Build / flash

- Arduino core **esp32 3.3.2**, board **ESP32 Dev Module** with **PSRAM: Enabled** (`esp32:esp32:esp32:PSRAM=enabled`; the sketch
  stops with an error otherwise), **Flash Size: 16MB**, partition scheme **16M Flash (3MB APP/9.9MB FATFS)**
  (two 3 MB program slots app0 / app1 for the LESP32.BIN update; the sketch is 1.16 MB; the FAT partition is not used).
- Library **ESP32-A2DP v1.8.11** (Phil Schatzmann). It is not in the Library Manager, so it was copied from the
  GitHub tag into the Arduino sketchbook's `libraries\ESP32-A2DP` folder.
- Library **AAudioLinkFix** (in this folder, `libraries/AAudioLinkFix`): copy it into the sketchbook `libraries`
  folder too. It holds no code; it only makes the linker wrap an ESP-IDF function (see Notes).
- CLI (in `LSpectrum/`): `arduino-cli compile -b esp32:esp32:esp32:PSRAM=enabled,FlashSize=16M,PartitionScheme=app3M_fat9M_16MB -u -p COMx esp32_v2`
- PC tests of the loader code (FAT, TAP/TZX, saving, .z80, C64 ROM install): `test/run_host_test.sh` (w64devkit
  gcc / g++; card images made by `tools/`; the ROM install test `test/c64rom_test.cpp` needs `L64/roms_local/`).

## SD tape loader

- `src/main.cpp` (browser, keys, player), `tape.cpp` (TAP/TZX -> pulse commands), `save.cpp` (recording),
  `snap.cpp` (.z80), `bt.cpp` (F3 menu), `fat.cpp` (FAT16/32 on raw sectors), `util.cpp` are portable C (built as
  C++ here, as C for the PC tests). `src/hw.h` gives the FPGA's registers as proxy objects; `src/esp_hw.cpp`
  implements them over the link, plus SD sectors, the OSD and the loader task.
- At start the ESP32 looks for a known core ID on the link for 3 s, then every 2 s: 5A580001 = LSpectrum,
  43360001 = L64 (while the machine menu is shown, nothing answers). Found: the loader runs as a task on
  core 1 (`loader: ... running` on USB); a different ID later (KEY1 / Ctrl+Alt+Del -> menu) restarts the ESP32. Leaving the menu does not: the menu's task ends
  and the machine is picked up by the next probe (~2 s), so a Bluetooth connection made while the menu was shown is not
  cut (a restart there left Bose headphones connected but silent or chopped). Pulse commands, OSD text and Spectrum memory writes go as bursts;
  snapshot memory reads are fetched 256 bytes at a time.
- L64 (`src/c64.cpp`, same browser and keys): `.prg` / `.t64` written into the frozen C64's RAM (BASIC programs
  start with RUN), C64 `.tap` played and recorded through the cassette port, `.d64` in the 1541 (track under the
  head copied into the FPGA's track buffer, changed sectors written back), F4 control port mapping, F5 SID
  6581 / 8580, F6 turbo / normal (MCTL bit 2; the FPGA runs turbo while a motor runs), F2 snapshot `NAME.A64`
  (header + 64 KB RAM + I/O shadow; loading runs a generated restore program in the FPGA's restore mode). At start, if the flash has no C64 ROMs, they are installed from `/ROMS/C64/` (KERNAL*, BASIC*,
  CHAR*, DOS1541*) through the FPGA's flash pass-through, then the C64 restarts (`../../L64/README.md`).
- The F3 menu talks to the Bluetooth part through the FPGA's UART (BT_TX / BT_RX), with the commands below.
- KEY0 resets the FPGA's loader hardware; the ESP32 notices it within 0.5 s and restarts itself (Bluetooth reconnects
  by itself a few seconds later).

## Control

Normal use: **F3 on the LSpectrum keyboard** opens the Bluetooth menu (scan, connect, disconnect, forget, PIN,
volume, Spectrum sound / test tone; row 2 shows the measured sample rates, `Rate: in <I2S Hz> out <A2DP Hz>`); the loader (`src/bt.cpp`) sends the commands below over UART2 (RX GPIO27, TX GPIO21; GPIO16 / 17 are the module's PSRAM).
The USB port takes the same commands, for debugging only (Serial Monitor: line ending New Line, not "No line
ending"). Input lines may end in CR, LF or CR+LF; every output line ends in CR+LF. Replies start with `OK` or `ERR`.
Unsolicited events start with `EV` and go to both ports.

| Command | Effect |
|---|---|
| `help`, `status` | command list; connection, target, PIN, audio source, I2S peak (since the last `status`), underruns, overflows, drift fixes, stream state (restarts, relinks), measured rates, link RSSI delta, bitpool, transmit power |
| `info` | one line for the menu: `OK info <state> <scan\|idle> <MAC> <vol> <pin> <i2s\|tone> <short> <skip> <fix> <i2s Hz> <a2dp Hz> <history> <name>` |
| `rates` | sample-rate history: the first 5 measurements (every 2 s) of each stream and each change > 2 %: I2S in, A2DP out, overflows, drift fixes, RSSI delta, bitpool |
| `bitpool <n>` | SBC bitpool cap, 2..250, 0 = none (default); used from the next connection |
| `scan` | drop the current link (if any) and search; each device found is reported as `EV found <n> <MAC> <rssi> <name>` |
| `list` | devices found so far |
| `connect <n\|MAC\|name>` | connect to entry n of the list, a MAC, or an exact name (case-insensitive); saved as the target |
| `disconnect` | drop the link and stop auto-connecting |
| `forget` | clear the target, the stored last peer and its pairing (bond) |
| `pin auto\|<code>` | PIN for legacy devices: `auto` (default) tries 0000, 1234, 8888, 1111; or a fixed code of up to 16 digits |
| `src i2s\|tone` | audio from the FPGA (default) or the test tone |
| `vol <0..127>` | A2DP volume: scales the samples and is sent to the speaker over AVRCP |
| `mute on\|off` | not saved |
| `tone <hz>`, `wave sine\|square`, `level <0..100>` | test tone: 20..20000 Hz (0 = silence), shape, amplitude in % |

Settings (target, PIN, source, tone, vol, bitpool) are saved in NVS. At power-up the library first reconnects to the last
peer. If that fails, discovery runs and connects when it sees the saved target. Events: `EV connecting/connected/
disconnected <MAC> <name>`, `EV discovery on/off`, and the pairing events below.

Typical first use (F3 menu): put the speaker in pairing mode, Scan for devices, then Enter on its name.

## Pairing and PINs

A speaker has no screen, so it never shows a PIN prompt; the source (the ESP32) supplies the code.

- **Bluetooth 2.1 and later (almost every speaker)**: Secure Simple Pairing "Just Works", no PIN. Shown as
  `EV pairing confirm <number> (accepted)` then `EV paired <name>`.
- **Bluetooth 2.0 and older (PIN devices)**: the device asks for its fixed PIN, shown as `EV pairing pin <code>`.
  With `pin auto` a wrong code gives `EV pairing failed` and `EV pairing next try with pin <code>`; the next
  connection attempt (automatic, ~15-25 s later) uses the next code from 0000, 1234, 8888, 1111. For any other
  code, set it with `pin <code>`. A 16-digit request is padded with zeros.
- Such devices give their name only on a name request, not in the inquiry data; the scan reports them as soon as
  they are seen (as `(no name)` until the name arrives), and they can always be connected by index or MAC.
- After pairing, the link key is stored on both sides; later connections need no PIN.

## Notes

- Classic BT is needed, so only the original ESP32 works (S2/S3/C3 are BLE-only).
- The scan only reports devices whose Class of Device says audio/rendering/telephony.
- After it starts, the library waits about 10 s before it reconnects or starts discovery.
- **ESP-IDF 5.5 bug, worked around** (`IntegerDivideByZero` in `SBC_Encoder_Init`, seen with Bose headphones in
  38 of 40 connects): when the speaker opens the A2DP stream itself (it reconnects to its last source on its own,
  or answers our connect with its own) and sets the standard SBC configuration, Bluedroid never asks for the
  sink's capabilities, `bta_av_co_audio_set_codec()` fails, the encoder stays all-zero and the first stream start
  divides by 0 blocks. The sketch wraps that function at link time (`-Wl,--wrap`, via AAudioLinkFix) and reports
  success while a link is open; the encoder then uses Bluedroid's default SBC setup, which is the one the speaker
  chose. `status` shows `codec-fix=<n>` and `EV codec set up by the IDF fix` marks each use. (Arduino passes a
  library's `ldflags` only for a precompiled library, hence the stub archive in AAudioLinkFix.)
- The library's discovery loop would keep running while connected; the sketch stops it then.
- **Internal memory and the audio.** Bluedroid builds every A2DP media packet in a 4112-byte buffer from the ESP32's
  internal heap and fills it up to the sink's MTU (7 SBC frames at bitpool 53 with an MTU of 883), so a 30 ms tick
  needs two packets. When the second buffer cannot be allocated, the stack skips that packet without an error: the
  sink gets 2/3 of the audio (choppy, "sped up"; 29,867 Hz pulled instead of 44,100), and with less memory still
  nothing (connected, silent). So the internal heap must stay well above 20 KB while streaming: about 45 KB now.
  `status` shows it (`heap: free / largest block / lowest free ever`) together with the packets per second (67 when
  all is well, 33 in the bad state), frames per packet, MTU, buffers waiting in L2CAP and packets dropped by BTA
  (`--wrap` of `AVDT_WriteReqOpt`, `L2CA_FlushChannel`, `bta_av_co_audio_drop` in AAudioLinkFix). Two things keep the
  heap free: the SD card is used without the SD library's FAT mount (`sdcard_init` + `disk_initialize`, raw sector
  calls; `SD.begin()` takes about 25 KB for a volume the loader never uses), and `set_reset_ble(true)` gives the
  controller's BLE memory back. Check the heap line after adding buffers or libraries.
- **Bitpool cap.** `bitpool <n>` limits the SBC bitrate (53 = 328 kbit/s = Bluedroid's default, 35 = 229, 29 = 196 at
  44.1 kHz joint stereo); default 0 = no cap. It wraps `bta_av_co_get_remote_bitpool_pref()`, which the encoder asks
  for the sink's range, and returns the range capped (the configuration's range when the sink gave none). The BR/EDR
  transmit power is 0..+9 dBm (controller default 0..+3), set in `bt_start()` between controller start and Bluedroid
  start. `status` / `rates` show both sample rates, the RSSI delta (asked every 10 s), the bitpool in use, the link
  role and the power mode.
- **Clock drift.** The I2S input (APLL) and the A2DP stack's timer are different clocks. The stack takes the audio in
  bursts (about 1,300-1,400 frames every 30 ms), so the backlog in the 12 DMA buffers (256 frames each) is checked
  once per tick, at the start of the burst, and kept between 1,792 and 2,304 frames by dropping or repeating one
  sample frame in that tick; far outside that range (stream start) it jumps back to 2,048 (`resyncs`).
- **A stream that stops.** A sink that suspends the stream leaves the link connected with no audio pulled. After 3 s
  without audio the sketch sets the library's media state back to idle, so its heart beat starts the stream again
  (`restarts`); if there is still no audio 15 s later (seen after quick disconnects / reconnects from the
  headphones), it drops the link and connects again (`relinks`, `EV audio stream did not start again`).
- The ESP32's 16-bit I2S receive may swap left/right; irrelevant while the FPGA sends mono.
