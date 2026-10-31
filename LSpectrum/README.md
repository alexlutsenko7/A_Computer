# LSpectrum — ZX Spectrum 128K on the QMTECH Cyclone IV (EP4CE15) board

Hardware: QMTECH EP4CE15F23C8N core board + the Extra_PCB_CycloneIV I/O board (`../Extra_PCB_CycloneIV/`; its J1
wired to the core board's U8 with each pin pair swapped; pin table in `../docs/BOARD_PINOUT.md`).
Architecture and decisions: `../docs/PLAN.md`, CPU clock-enable analysis: `../docs/T80_CEN_ANALYSIS.md`.

## What it is

| Part | Implementation |
|---|---|
| CPU | T80 (MiSTer @af0e6723, `../T80/`) in `cpu_t80` (single clock enable), 3.5469 MHz, or 28 MHz while the SD tape loader plays or saves (F6: normal speed) |
| System clock | 112 MHz (sys_pll); CPU stepped by a phase accumulator; SDRAM stalls hold the clock enable (turbo only) |
| RAM + ROM | W9825G6KH SDRAM via `sdram_ram` (DDR_TEST, proven at 112 MHz): RAM pages 0-7, ROM 0/1, DiagROM |
| ROMs | in the configuration flash at 0x100000 (in the .jic), copied to SDRAM at power-up/reset by `rom_loader` (~14 ms) |
| Video | 640x480@60 (25.208 MHz, 60.02 Hz) or 720x576@50 (27.009 MHz, 50.017 Hz) VGA (CEA-861 VIC 1 / 17 timing, clocks +0.033 %), 4-bit RGB DAC (ZX normal = E, bright = F per colour), from block-RAM shadows of pages 5/7 |
| Sound | AY-3-8912 (JT49, GPL-3) at 1.7734 MHz -> sigma-delta on AUDIO_AY; beeper on AUDIO_BEEP (both to the 3.5 mm jack); the same mix as I2S (`bt_i2s`) to the ESP32, which sends it to Bluetooth headphones / speakers (`esp32/`) |
| Keyboard | USB keyboard via the CH9350-style UART module (115200), packet format as the DE10-Lite reference |
| Joystick | two DB9 ports, mode chosen in the F4 menu: both Kempston (port 1F, default); DB9-1 Kempston + DB9-2 Cursor (5 6 7 8, fire 0); Interface 2 (DB9-1 Sinclair 1 = 6-0, DB9-2 Sinclair 2 = 1-5). Sinclair / Cursor sticks press keys in the keyboard matrix (`zx_system.v`) |
| Tape | SD tape loader (EAR = loader while it plays, else the beeper) |
| SD tape loader | ESP32 system controller (`esp32/`) with the microSD card, over an SPI link (`rtl/esp_link.v`) to the FPGA's loader hardware (`rtl/tape_loader.v`): OSD file browser (320 entries), plays .tap/.tzx T-state exact, records SAVE output into .tap files; turbo or normal speed; .z80 snapshots: F2 saves, the browser loads (`../docs/SD_TAPE_LOADER.md`) |

## Controls

| Control | Function |
|---|---|
| KEY0 (W13) | reset: CPU, ports, ROM reload, tape loader (the ESP32 restarts, Bluetooth reconnects). The video mode is kept. |
| Ctrl+Alt+Del | back to the machine menu, as KEY1 (when the keys are released) |
| F1 | **held while the CPU starts** (power-up, KEY0, started from the menu): DiagROM instead of the 128K ROM |
| F3 | Bluetooth audio menu: scan, connect, PIN, volume; F3 / Esc closes |
| F4 | joystick menu: Kempston on both ports / Kempston + Cursor / Interface 2 (Sinclair 1 + 2); Up/Down, Enter selects, F4 / Esc closes. Back to Kempston after KEY0 / power-up |
| F8 | swap 60/50 Hz video. Power-up default is 640x480@60 (accepted by every monitor; 576p50 is not). |
| F12 / keypad / / NumLock | SD tape loader browser (keys: `../docs/SD_TAPE_LOADER.md`); keypad 5 / F11 pause-continue, keypad - back one block, F7 / keypad * stop. First browser line [Save to this folder]: name, then recording until F12 |
| F6 | tape speed for loading and saving: turbo (default) / normal |
| Print Screen | the screen with the border as `SCRNnnnn.BMP` (320 x 240, 16 colours) in the browser's current folder |
| F2 | save a snapshot of the whole machine: type a name, Enter -> NAME.Z80 in the browser's current folder. Load: F12, choose the .z80, Enter |
| KEY1 (Y13) | back to the machine menu (`../AMenu/`) |
| LED | on = turbo; fast blink = no ROM image in the flash (program the .jic) |

Keyboard: letters, digits, Enter, Space; Left Shift = CAPS SHIFT; Right Shift / Ctrl = SYMBOL SHIFT;
Backspace = DELETE, arrows = cursor keys, Esc = BREAK. While the tape browser is open the Spectrum sees no keys.
At power-up the CPU waits for the first keyboard packet (at most 1.5 s) so a held F1 is seen.

## Files

| Path | Role |
|---|---|
| `LSpectrum.qpf/.qsf/.sdc` | Quartus project, pins, constraints (SDRAM I/O as DDR_TEST, CPU multicycles, clock groups) |
| `roms48k.hex` | ROMs (128K set + a diagnostics ROM, 48 KB) for flash 0x100000, made by `tools/mk_roms48k.py` (the public copy has 48K BASIC in the diagnostics slot: DiagROM's licence is not known); the `.jic` is built by `../AMenu/L.cof` (menu at 0, this bitstream at 0x080000, ROMs) |
| `sta_report.tcl` | `quartus_sta -t sta_report.tcl`: unconstrained ports, worst paths, CPU multicycle check |
| `rtl/LSpectrum.v` | top: PLLs, resets (power-up / machine / tape loader), SDRAM clock (DDIO) and DQ, video clock switch (as VGA_TEST), F8/S1 handling |
| `rtl/zx_system.v` | the machine without PLLs: SDRAM, loader, bus, AY, keyboard, video, LED |
| `rtl/zx_bus.v` | CPU clock enable, bus bridge (speculative read at T1, posted writes, stall), paging, ports, INT |
| `rtl/cpu_t80.v` | T80 wrapper (T80se-style, exports MC/TS/decode) |
| `rtl/zx_video.v` | Spectrum picture (2x2 pixels, borders, FLASH) + screen shadows + OSD overlay |
| `rtl/zx_keyboard.v` | UART + packet parser -> 8x5 key matrix, loader keys, F1, F8, Ctrl+Alt+Del (menu) |
| `rtl/tape_loader.v` | loader hardware: register bus, command FIFO, pulse player, MIC recorder with CPU hold, snapshot port, OSD port, UART to the ESP32's Bluetooth part; shared with L64 (flash pass-through, ROM reload, MCTL / MCLR) |
| `rtl/esp_link.v` | SPI slave for the ESP32 (8 MHz, frames WR/RD/OSD/FIFO/MWR/MRD/STAT), master of the loader's register bus; IRQ pin |
| `rtl/osd_font.hex` | Spectrum character set (made by `esp32/tools/mkfont.py` from `../roms/zx128.rom`): labels of the documentation diagrams; the OSD uses `../AMenu/rtl/menu_font.hex` (Spleen 8x16) |
| `esp32/` | ESP32 system controller (Arduino sketch `esp32.ino`): SD tape loader firmware in `src/` (browser `main.cpp`, `fat.cpp`, `tape.cpp`, `save.cpp`, `snap.cpp`, `bt.cpp`; `hw.h` + `esp_hw.cpp` = link, SD, OSD) and Bluetooth audio; `test/` PC tests, `tools/` card image / test generators, FAT checker (`esp32/README.md`) |
| `rtl/rom_loader.v`, `rtl/flash_if.v` | flash READ -> SDRAM; bit-order auto-detect (the .jic stores the data bit-reversed) |
| `rtl/sd_dac.v` | sigma-delta audio DAC |
| `rtl/bt_i2s.v` | AY + beeper as I2S (slave, Philips 16 bit, 44.1 kHz from the ESP32's clocks), low-passed, DC-free; pins BT_BCLK AA15 / BT_LRCK AB16 / BT_DATA AA16 |
| `rtl/sdram_ram.v`, `rtl/sys_pll.v` | from DDR_TEST; `sdram_ram` also has a 16-bit mode (used by L64's frame buffer, tied off here) |
| `rtl/vga_pll.v`, `rtl/vga_clkmux.v`, `rtl/vga_timing.v` | copies from VGA_TEST |
| `rtl/jt49/` | JT49 AY core (Jose Tejada, GPL-3), as used in the reference |
| `sim/run_sim.sh [defines]` | whole-machine Questa simulation (flash model -> loader -> SDRAM model -> T80 boot); writes `screen.png` |
| `sim/run_esp_link_sim.sh` | tape_loader driven over the SPI link by an ESP32 model: ID, registers, OSD, FIFO, MWR/MRD bursts, error flag, IRQ |
| `sim/run_float_sim.sh`, `sim/run_floatgame_sim.sh [game.z80]` | floating bus: IN A,(FF) against Fuse's 128K rule; a real game (default Sidewize) with every floating-bus read and sync-loop exit compared with Fuse |
| `sim/run_bt_i2s_sim.sh` | bt_i2s against an ESP32-like I2S master, 16- and 32-bit slots: bit-exact words, beeper swing, DC removal |

## Build and program

```
quartus_sh --flow compile LSpectrum
(cd ../AMenu && quartus_cpf -c L.cof)  # -> ../AMenu/output_files/L.jic (menu + LSpectrum + ROMs)
arduino-cli compile -b esp32:esp32:esp32 -u -p COM10 esp32     # ESP32: loader + Bluetooth (esp32/README.md)
```
The loader firmware runs on the ESP32: after changing `esp32/`, only the ESP32 is flashed again.
Program `../AMenu/output_files/L.jic` once (Programmer, JTAG, Program/Configure, power-cycle): it puts the
ROMs into the flash. After that, `.sof` loads over JTAG are enough during development (ROMs stay in flash).
If the LED blinks fast after loading a .sof, the flash has no ROM image: program the .jic.

## Known limitations

- Memory contention at Level 1 only (memory and I/O cycles, not the internal contended T-states of some
  instructions); the floating bus follows Fuse 1.6 (byte at the start of the I/O cycle's 4th T-state, after its
  contention; fixed 2026-10-11, Sidewize / Arkanoid / Cobra work). No ULA snow. Border effects line up only in
  the 50 Hz mode (PgUp/PgDn move the interrupt). Current list: `../docs/KNOWN_ISSUES.md`.
- Keyboard module UART direction not confirmed: both lines are inputs with pull-ups, RX = KB_OUT AND KB_IN
  (works whichever line carries the data). Nothing is sent to the module.
- The ESP32 (`esp32/README.md`, `../docs/LSpectrum_Connection.docx`) is needed for the SD card, the browser and
  Bluetooth; without it the Spectrum boots and runs, but F12 does nothing.
