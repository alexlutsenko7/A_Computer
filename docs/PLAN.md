# L — ZX Spectrum 128 on QMTECH Cyclone IV (EP4CE15F23C8N) with SDRAM

Decisions and analysis agreed with the user, 2026-10-05. Source of truth for the porting plan.

## Goal
Port the user's working ZX Spectrum 128 (`Reference_ZX_On_DE10_Lite/`, MAX10, block-RAM only) to the QMTECH
Cyclone IV board, moving RAM (and ROM) into the on-board W9825G6KH-6 SDR SDRAM, with a fast "turbo" mode
(~28 MHz) for the user's tape simulator.

## Agreed architecture
- **One system clock** (PLL from 50 MHz) for SDRAM controller, CPU, bridge, AY, ports. No clock muxes.
- **CPU: T80 with clock enable (T80se)** stepping on CEN pulses from a 32-bit phase accumulator (DDS).
  - Normal: precise Spectrum speed (3.5469 MHz for 128K, or 3.5 MHz) — average exact, ±1 system clock jitter.
  - Turbo: ~28 MHz, selected by the TURBO_N input, active low (low = turbo, released/high = normal). Switching = change the accumulator
    increment; glitch-free at any time. Exact speeds not required, only "as precise as possible".
  - Turbo timing need not be cycle-exact: when SDRAM is not ready the bridge holds CEN (stalls the CPU).
  - Normal mode: memory always ready within a T-state budget -> cycle-exact, no waits.
  - T80 paths get multicycle constraints (CEN never closer than N system clocks); audit that all T80 regs are CEN-gated.
- **T80 version**: current T80 from the MiSTer ZX-Spectrum core, commit af0e6723 (2026-07-24), copied to `T80/`
  (see T80/SOURCE.md). The user's old T80(b) ver 303 stays in the reference folder as fallback.
- **CEN analysis done** (docs/T80_CEN_ANALYSIS.md): all T80 state is CEN-gated, so stalling CEN is safe. MiSTer ZX
  core does the same at 112 MHz (T80pa, turbo 28/56, SDRAM stall, VRAM shadow). Plan: own T80se-style wrapper
  (single CEN, exports MC/TS); DDS CEN (normal 3.5469 MHz, turbo exactly 112/4 = 28 MHz); CPU-internal multicycle
  setup 4 / hold 3; bridge starts SDRAM read at T1 (not on RD_n). T80 Fmax on EP4CE15 C8 measured: 63.5 MHz (15.75 ns) slow corner.
- **Memory map in SDRAM** (18-bit window, done):
  - 0x00000-0x1FFFF: RAM pages 0..7 (16 KB each)
  - 0x20000-0x27FFF: 128K ROM set (ROM 0 = 128K editor, ROM 1 = 48K BASIC; 7FFD bit 4 selects)
  - 0x28000-0x2BFFF: DiagROM v1.59 (16 KB); when selected it appears for both ROM pages
  - 0x2C000-0x3FFFF: spare
  - ROM region is read-only for the CPU. ROM set chosen by a switch sampled at reset (no re-copy needed).
  - No separate 48K ROM (user decision: ROM 1 of the 128K set serves 48K BASIC).
- **Flash (W25Q64 = EPCS64) layout**:
  - 0x000000: FPGA bitstream (~0.5 MB)
  - 0x100000: 128K ROM set, 32 KB  (source `Reference_ZX_On_DE10_Lite/128K_rom_hex.hex`, md5 85fede41...)
  - 0x108000: DiagROM, 16 KB       (source `Reference_ZX_On_DE10_Lite/DiagROM.hex`, "DIAGROM V1.59", md5 b90755c9...)
  - Boot copies both (48 KB, ~20 ms) into SDRAM.
  - Verified 2026-10-05: Quartus 25.1 Lite `quartus_cpf -c -d EPCS64 -s EP4CE15` builds a .jic; SFL images
    for EP4CE15 present (`quartus/common/devinfo/programmer/sfl_ep4ce15.sof`).
- **ROM source: on-board W25Q64 config flash** (EPCS64-compatible, ID 0x16). Bitstream uses ~0.5 MB; ROM image(s)
  stored at a fixed offset (proposed 0x100000). At boot: SDRAM init -> copy 32 KB flash->SDRAM via the
  `cycloneive_asmiblock` primitive (own SPI READ 0x03 FSM, ~20 MHz, ~13 ms) -> release CPU reset.
  Programming: Quartus "Convert Programming Files" -> .jic with .sof + ROM hex ("Add Hex Data" at the offset),
  programmed once via JTAG/SFL; day-to-day development loads .sof over JTAG, ROM stays in flash.
  To verify: EPCS64 still offered for Cyclone IV E in Quartus 25.1 Lite.
- **Video**: stays in FPGA block RAM — shadow copies of the screen area of pages 5 and 7 (6912 B each, 14-16 M9K),
  written in parallel with CPU writes to those pages. Video and floating-bus reads use the shadow, never SDRAM.
  ROMs stay in SDRAM (re-confirmed by the user 2026-10-06). ROM 32 KB + both shadows (46 of 56 M9K) would fit the
  EP4CE15, and loading only the selected ROM from flash into block RAM was considered. It was rejected so the design
  needs only ~15 M9K and can move to a smaller FPGA. The cost is an occasional 1-clock turbo stall on ROM fetches.
- **Refresh** hidden in the Z80 M1 refresh slot (T3/T4) where possible; otherwise forced every 7.5 us.
- **Reused from the reference** (ported into the single clock domain with CENs): 7FFD paging + lock, port FE
  (border/beeper/EAR, tape auto-lock), AY via JT49 (1.75 MHz), PWM audio, UART keyboard (CH9350-style HID packets),
  Kempston @1F, floating bus, VGA 640x480 50/60 Hz, INT 32 T-states from vsync.
- **Board I/O to add on headers** (QMTECH has none of it): VGA RGB444 + syncs, audio PWM, beeper, keyboard UART RX,
  tape in, turbo GPIO, Kempston, 50/60 Hz select, Z80 reset. DE10-Lite 7-segment debug is dropped.

## Turbo memory budget (system clock 112 MHz, CEN every 4 clocks = 28 MHz)
Opcode fetch needs data ~2 T-states after address = ~8 system clocks.
| SDRAM case | clocks incl. bridge | fits |
|---|---|---|
| write | 1 | yes |
| read, row open | 5 | yes |
| read, bank idle | 7 | yes |
| read, other row open | 9 | 1-clock stall |
| refresh | hidden in RFSH slot | — |
At 100 MHz (CEN avg every 3.57 clocks) the budget is ~7 clocks: est. 24-27 MHz effective; hence the move to 112 MHz.

## Steps
1. [done] DDR_TEST: 128Kx8 RAM on SDRAM @100 MHz, CL2, open-row; simulated + timing-clean + passes on hardware.
2. [done] SDRAM/system clock 112 MHz (28 x 4): timing closed (+0.74 ns worst), sim passes, passed on hardware.
3. ROM in SDRAM:
   a. [done] Controller + tester widened to 18-bit window (sdram_ram, ADDR_BITS=18); passes sim + hardware (soak test running).
   b. Flash->SDRAM ROM loader (asmiblock SPI READ), .jic flow with ROM hex, verify copy on hardware.
4. Z80 bus bridge (T80se + CEN DDS + stall), turbo GPIO; simulate with real ROM boot.
5. Port Spectrum peripherals into single clock domain; video with screen shadows; INT.
6. Pinout for add-on hardware on QMTECH headers; bring-up.

## Next stage: ESP32 as system controller (agreed 2026-10-13)

**Goal:** free block RAM. The FPGA stays the EP4CE15 (an EP4CE6 does not fit, see the session log). PicoRV32 and its
35 KB RAM leave the FPGA; the ESP32 (already there for Bluetooth) runs all loader firmware and drives the existing
loader hardware through an SPI link. Gain: **~38 M9K** (35 RAM + 2 CPU registers + 1 UART FIFO) of 56, ~2,600 LEs.
The same ESP32 + link is meant to serve later cores (C64) unchanged: machine-agnostic system controller.

### Split
| ESP32 (Arduino sketch, grows from `AAudio/`) | FPGA (`tape_loader` without the CPU) |
|---|---|
| SD card (own SPI host, FATFS, long names), directory listing + sort | pulse player + 512-entry command FIFO (T-state exact) |
| browser, save dialog, F-key handling, OSD drawing | MIC recorder with `hold` (no edge lost however slow the link is) |
| TAP/TZX parsing -> FIFO commands, MIC events -> TAP file | snapshot freeze + command port (MRD/MWR/REG/DIR/LOAD/AY/PORT/STATE) |
| .z80 load/save (`fw/snap.c`), BT menu (local calls, no UART) | OSD text RAM + font, INTPOS, contention switch, keys/KEYRAW |
| A2DP Bluetooth (core 0), loader (core 1) | **SPI-slave bridge** onto the register map + IRQ |

`fw/*.c` is ported, not rewritten: `hw.h` register access becomes link calls, `sd.c`/`fat.c` are replaced by the
ESP-IDF/Arduino FS, the browser keeps its list on the ESP32 (no 320-entry limit). The ESP32 becomes required for
loading/saving (the machine still boots and runs without it).

### Link (draft; finalise when building)
- SPI mode 0, ESP32 = master, FPGA = slave oversampling SCK in the 56 MHz loader domain: SCK <= 10 MHz (~1 MB/s;
  a 128 KB snapshot ~0.15 s). CS_N frames one command. MSB first.
- Frame = command byte + arguments; reads have one dummy byte before the data:
  | Cmd | Arguments | Purpose |
  |---|---|---|
  | `WR` | reg, data32 | write a loader register (same offsets as `fw/hw.h`) |
  | `RD` | reg, dummy -> data32 | read a loader register |
  | `FIFO` | n x data32 | push pulse-player commands (burst) |
  | `OSD` | addr16, n bytes | OSD text, auto-increment |
  | `MWR` / `MRD` | addr24, n bytes | Spectrum memory through the snapshot port, auto-increment (burst) |
  | `STAT` | dummy -> data32 | IRQ causes + FIFO free + core ID (reading acknowledges) |
- `ESP_IRQ` (FPGA -> ESP32, level, active high): FIFO below threshold, key report changed, recorder event, command done.
- Core ID register (e.g. "ZX", version) so the ESP32 firmware picks the machine's file handlers (C64 later).

### Test wiring (prototype, 2026-10-14)
SD card (Adafruit BFF, today on U8.7-13) moves to the ESP32; the link uses the free U7.7-11 next to the BT wires.
The current bitstream's F12 loader cannot reach the card any more after this; BT audio keeps working.

| Signal | ESP32 (DOIT 30-pin) | FPGA | U7 pin | Notes |
|---|---|---|---|---|
| SD SCK | GPIO18 (VSPI) | — | — | BFF JP3.2 |
| SD MISO | GPIO19 (VSPI) | — | — | BFF JP3.3; 10k pull-up to 3V3 if the BFF has none |
| SD MOSI | GPIO23 (VSPI) | — | — | BFF JP3.4 |
| SD CS | GPIO5 | — | — | BFF JP1.7 (TX); strapping pin, high at boot = default, OK |
| SD 3V3 / GND | 3V3 / GND | — | — | 10 uF + 100 nF stay at the BFF |
| ESP_SCK | GPIO14 | P1 | 9 | ESP32 -> FPGA |
| ESP_MOSI | GPIO13 | P2 | 10 | ESP32 -> FPGA |
| ESP_CS_N | GPIO33 | N1 | 11 | ESP32 -> FPGA; FPGA weak pull-up (deselected while the ESP32 boots) |
| ESP_MISO | GPIO35 (input only) | R1 | 7 | FPGA -> ESP32 |
| ESP_IRQ | GPIO34 (input only) | R2 | 8 | FPGA -> ESP32 |
| GND | GND | — | 1/2 | one more GND wire in the bundle |

Unchanged: I2S GPIO26/25/22 = U7.17-19; UART GPIO16/17 = U7.20/21 (kept until the BT menu runs on the ESP32).
Pins avoided on purpose: GPIO12 (strapping: high at boot selects 1.8 V flash; the FPGA's weak pull-ups would do
that), GPIO2/15 (strapping), GPIO6-11 (flash). SDMMC 1-bit/4-bit would need GPIO2/12/15, hence SD in SPI mode
(20-40 MHz, far more than tapes need). FPGA side: plain I/O in bank 2; Quartus confirms at the first build.

### Steps
1. First hardware test: ESP32 sketch mounts the SD card and lists a folder; FPGA build with the bridge
   (`ESP_LINK`, PicoRV32 removed) — ESP32 reads the core ID/TIMER, draws the listing on the OSD, reads keys,
   MWR/MRD burst round trip into a frozen machine. Sim first: bridge testbench with an ESP32 SPI-master model.
2. Port tape playback (`tape.c`: TAP/TZX -> FIFO, IRQ-driven refill) incl. turbo; compare with `run_loader_sim` data.
3. Port saving (`save.c`, recorder events), snapshots (`snap.c`), browser/save dialog, BT menu (drop the UART).
4. Remove PicoRV32, firmware RAM, UART and SD SPI master from the RTL; update docs (SD_TAPE_LOADER, Architecture,
   Connection, Keys) and `Extended/` (microSD to the ESP32, link pins on J1).
5. Later: second core (C64) reusing the ESP32 firmware's common part (SD, browser, OSD, BT, link).

## Next stage: machine menu + Commodore 64 "L64" (agreed 2026-10-27)

**Goal:** at every power-up a menu offers the machines (LSpectrum = ZX Spectrum 128K, L64 = Commodore 64,
more later); the choice loads that machine's bitstream. L64 gets the same F-key functions as LSpectrum where
the C64 has an equivalent, and full .d64 disk support (1541 in the FPGA).

### Bitstreams: Cyclone IV remote update
Both machines in one image would need ~80 % of the EP4CE15 at 112 MHz and leave no room for a third, so each
machine is its own bitstream in the 8 MB config flash; a small **menu core** is the factory image.

| Flash | Contents |
|---|---|
| 0x000000 | factory image: menu core `AMenu/` (VGA 640x480@60, text screen, keyboard, joysticks, remote-update block) |
| 0x080000 | LSpectrum (application image) |
| 0x100000 | ZX ROMs (`roms48k.hex`, unchanged: `rom_loader` keeps its address) |
| 0x180000 | L64 (application image) |
| 0x200000.. | C64 ROMs (KERNAL, BASIC, CHAR, 1541), installed from the SD card by the ESP32; then further cores |

- Power-up always loads the factory image. The menu (drawn by the FPGA itself, no ESP32 needed) is shown every time;
  Up/Down + Enter, the digit, or a joystick picks a machine. The menu core disables the watchdog, writes the boot
  address and triggers the reconfiguration.
- An application image can only reconfigure back to the factory image: **KEY1** in every machine returns to the menu.
- A missing or corrupt image falls back to the factory image; the menu reads the trigger reason and says so.
- The ESP32 needs no menu code: it already waits for a known core ID and restarts when the ID changes.
- One combined `.jic` (`AMenu/L.cof`) holds the menu, all machines and the ZX ROMs; LSpectrum.cof is retired.

### L64 (as built, `L64/README.md`)
- Sources: VIC-II = **VIC-II Kawari** (GPL-3; FPGA-64 is not redistributable: syntiac.com "strictly for personal
  educational purposes"), T65 (BSD, `T65/`), SID + CIA from MiSTer C64 (CERN-OHL-S / GPL); bus, PLA, colour RAM,
  keyboard, joysticks, video/OSD ours. RAM 64 KB + ROMs in SDRAM, colour RAM in M9K.
- Clocks: one PLL (VCO 756.25 MHz): 31.510 MHz dot4x = the whole C64, 94.531 MHz (3x, aligned) SDRAM/loaders/frame
  buffer, pixel clock 39.80 MHz (60 Hz) or 31.51 MHz (50 Hz) through a global clock switch (F8).
- Video (decided 2026-10-28, user: frame buffer rather than an NTSC machine, so PAL games stay correct): the
  VIC-II's colour index per dot -> triple frame buffer in SDRAM (400 x 284 dots, 16-bit words, slots at ticks 4-12
  of each half cycle) -> 800 x 600 @ 60 Hz VESA after power-up, F8 = 50 Hz (1008 x 624 at 31.51 MHz, Kawari's
  scan doubler timing). Kawari's RGB / scan doubler not built.
- ROMs (non-free): never in the repo / .jic; ESP32 installs `/ROMS/C64/*.rom` from SD into flash (memory "ROM licensing").
- F keys: F12 browser (.prg/.t64 injected, .tap through the pulse player, .d64 in the 1541), save line = cassette write
  -> .tap, F7 stop, F6 turbo, F3 Bluetooth, F4 joystick ports (swap / port 2 only / cursor keys), F5 SID 6581/8580,
  F8 60 / 50 Hz video, F2 snapshot (own format, last), Ctrl+Alt+Del reset, KEY0 full reset. Priority (user,
  2026-10-28): 60 Hz first, then turbo (on by default, need not be as fast as the Spectrum's), then snapshots if they fit.
  Extra C64 keys: Esc = RUN/STOP, Page Up = RESTORE (NMI), Win = C=.
- ESP32 firmware: common part (SD, browser, OSD, BT, link, ROM install) + one handler set per core ID; partition scheme
  with a bigger app partition (today 88 % of 1.3 MB).

### Steps
1. Menu core + remote update; LSpectrum as application image at 0x080000 with KEY1 -> menu; combined .jic.
2. L64 bring-up: CPU, VIC-II locked to 576p, keyboard, joysticks, SID -> jack + BT; test ROMs written over JTAG.
3. ROM install from SD (ESP32 -> flash pass-through).
4. Loaders: .prg/.t64, .tap play/record, turbo, SID model, PAL/NTSC.
5. 1541 + .d64 (read, then write), then snapshots.

## Session log
### 2026-10-05 (end of day)
Done: steps 1, 2, 3a (SDRAM controller 112 MHz, 256 KB window, passes sim + hardware); SDRAM chip confirmed plain -6;
T80 (MiSTer @af0e6723) copied to T80/, CEN approach analysed and confirmed (docs/T80_CEN_ANALYSIS.md), T80 alone
measured 63.5 MHz on EP4CE15 C8 (tests/t80_fmax); I/O pinout for the user's adapter agreed (docs/BOARD_PINOUT.md,
all on U7: VGA 2-bit RGB + syncs, AY PWM + separate beeper, keyboard RX/TX, tape in, turbo, reset, 50/60, Kempston,
ROM select); docs: SDRAM_TUTORIAL.md/.docx (incl. development history), SDRAM_CONTROLLER.md.
Waiting on the user: soak-test result; adapter wired to U7 and header power pins checked with a meter.
Next: step 3b — flash->SDRAM ROM loader (128K ROM @0x100000, DiagROM @0x108000 -> SDRAM 0x20000/0x28000),
.jic with ROM hex, ROM select = on-board KEY1 (Y13) held during reset/power-up -> DiagROM, else 128K ROM
(agreed 2026-10-06; machine reset = on-board KEY0 W13);
then step 4 (Z80 bridge).

### 2026-10-06
Done: indexed the user's I/O adapter `QM_Atrix_adapter/` (KiCad, made for a QMTECH Artix-7 board, 2x25 headers) ->
docs/QM_ATRIX_ADAPTER.md (files, header netlist, circuits, schematic-vs-PCB, mapping to the U7 proposal).
Facts confirmed by the user:
- The KiCad files are from Mar 2024 and were auto-converted to KiCad 10 today; the PCB/gerbers are close to the
  built board but not exact (the schematic's U1 7803 and Turbo 680 Ohm pull-up are missing from the PCB file, yet the
  pull-up is fitted on the real board -- see correction below; R numbering differs after conversion).
- Keyboard module: 5 V is only USB power pass-through; UART levels are 3.3 V.
- Tape_out never used (tape is load-only). DB9: only a plain joystick (no autofire) -> pin 7 tied to Right is harmless.
- VGA DAC (130/340 Ohm, ~1.46 V full scale) worked fine on the Artix board -> keep as is.
- Machine reset = FPGA board's own reset button -> on-board KEY0 (W13); U7.21 RESET_BTN_N not needed with this adapter.
- ROM select: not on the adapter (it was a production board) -> must be implemented differently, method TBD.
  AGREED: on-board KEY1 (Y13) held during reset/power-up -> DiagROM, otherwise 128K ROM
  (no extra hardware; optionally a USB-keyboard hotkey later). U7.28 ROM_SEL dropped.
Open (user's decision): how the adapter physically connects to the Cyclone IV board (it does not fit the U7/U8
2x32 headers).
- Turbo input polarity (user, 2026-10-06): **active low**. The SD card loader (tape simulator), when connected,
  pulls the pin low for turbo and releases it for normal speed; when no loader is connected the pin must read high
  (= normal), which was done with a pull-up. The 680 Ohm pull-up is fitted on the real adapter (user,
  2026-10-06: missing from the PCB file, version mismatch); FPGA weak pull-up ON as well (as the reference .qsf). Synchronise it
  (2-FF) and debounce/filter it before it changes the CEN increment. Earlier "high = turbo" in this plan was wrong.
- Correction (user, 2026-10-06): the KiCad PCB file does not fully match the real adapter. The 680 Ohm Turbo
  pull-up IS fitted on the real board. The 7803 (5 V -> 3v3) is fitted too (user, 2026-10-06), so the
  adapter needs only 5 V + GND from the Cyclone board; do not tie the host 3V3 to the adapter's 3v3 rail.
- The user's last adapter schematic/PCB revision was lost; the KiCad files are an earlier revision (explains the mismatch).
- Plan (user): plug adapter J2 (VGA, tape, turbo, keyboard) straight into a Cyclone header so the analog VGA path stays
  rigid; J1 (joystick, audio, 50/60) via wires. Alignment analysis in docs/QM_ATRIX_ADAPTER.md: recommended = J2 reversed
  with pin 1 at the VIN end (5 V/GND come through the header), provided J2.2 is isolated (meter check). The U7 pin
  assignment in BOARD_PINOUT.md must be redone once the physical fit is chosen.
- Decision (user): ROMs stay in SDRAM, loaded from flash at boot (original plan). Block-RAM ROM was considered and
  rejected so the design isn't tied to the EP4CE15's block RAM (option to move to a smaller FPGA).
- Turbo is only used for loading software, so 1-clock SDRAM stalls are irrelevant there (agreed with the user). The ROM
  loader's pulse-timing loop has no RAM accesses and runs from one SDRAM row. INT as in the reference: 50 Hz mode = from
  VGA vsync (real-time 50 Hz, also in turbo); 60 Hz mode = every 70000 CPU clocks (scales with turbo). Pulse = 32 CPU
  clocks. Implementation rule: count INT width and the 70000 period in CPU CEN pulses, not system clocks.
- Prototype hardware fit (user, 2026-10-06; prototype only, not the final design): adapter J2 plugged into U8 with
  J2 pin 1 on U8.64 (J2.2 cut), J1 outside the board and wired to U7. VGA/tape/turbo/keyboard on U8, joystick/audio/
  50/60 on U7. AB17/AA17 are tied to GND by the adapter: never drive high. Pin tables in docs/BOARD_PINOUT.md.
- VGA_TEST/ created (adapter bring-up): colour bars, 640x480 at 60 Hz (800x525) or 50 Hz (850x588, 50.02 Hz) on one
  25 MHz pixel clock, switch S1 (U7.22). Built + simulated. Waiting on the user: hardware test on the monitor.
- VGA_TEST first hardware try: "Input not supported" in both S1 positions. The LED showed 50 Hz all the time: S1 had no
  effect (D2/U7.22 wiring to check), and 850x588 (29.4 kHz line) is likely below the monitor's range. Changed 50 Hz to
  800x625 (31.25 kHz, 50.00 Hz), KEY1 now swaps 50/60. For the ZX: INT from vsync at 50.00 Hz (real 128: 50.02 Hz).
- 800x625@50 was shown by the user's monitor as "800x600@50" (picture squeezed to the top); 640x480@60 works. A true
  640x480@50 is not possible on analog VGA (the monitor picks the mode from H/V rate + line count). Agreed: 50 Hz =
  720x576@50 (576p, 27 MHz); 60 Hz stays 640x480 (25 MHz); pixel clock switched with the global clock control block
  (sequenced, video reset during the switch). For the ZX at 50 Hz: 512x384 screen + 104 px / 96 line borders.
- VGA_TEST passed on hardware (2026-10-06): 640x480@60 normal; 576p (OSD "800x600@50") centred vertically, sharp.
  Open: S1 (50/60) has no effect -> check the J1.5 -> U7.22 (D2) wire; then program VGA_TEST.jic as the safe flash image.
- S1 had no effect because it was miswired (user). Kept unwired for now: 50/60 is chosen with KEY1 (SW2, Y13); weak
  pull-up on D2 so the floating input reads a steady 50 Hz. Wire S1 (J1.5 -> U7.22) later; it overrides the pull-up.
- ROMs extracted to roms/ (zx128.rom, diagrom_v159.rom; hashes match this plan).
- LSpectrum/ created: the full ZX Spectrum 128K (steps 3b, 4, 5 and the U8/U7 pinout in one design; see LSpectrum/README.md).
  Builds clean (4,563 LEs, timing met, fully constrained). Sim: loader copies the bit-reversed flash image correctly
  (the .jic really stores user hex data bit-reversed -> loader auto-detect), 128K ROM boots (RAM test through all
  pages, INT every 70908 T, turbo 27.4 MHz effective). Next: hardware bring-up (program LSpectrum.jic once).
- LSpectrum works on hardware (2026-10-06, first try): 128K boots to the menu, user: "works just fine".
  Not yet tested by the user: full keyboard, DiagROM, turbo loading, AY/beeper, joystick (J1 wiring), tape.
- Final LSpectrum resources on EP4CE15: 4,563 LEs (30 %; T80 2,490, AY 486, SDRAM 428, keyboard 366, bus 334,
  video 167, loader 126), 17/56 M9K, 2 PLLs. Fits EP4CE10 comfortably, EP4CE6 at ~73 %.
- Smaller-board candidate (user, 2026-10-06): "Cyclone4 FPGA Core Board EP4CE6F17", 78x48 mm: 50 MHz clock,
  16 Mbit SPI flash (2 MB -> ROMs stay at 0x100000; .cof device EPCS16), 128 Mbit SDRAM = W9812G6KH-6
  (4 banks x 4096 rows x 512 cols x 16, A0-A11, CL2 to 133 MHz: drop-in for sdram_ram), 102 user I/O, one button.
  Port plan: new .qsf (device + pins from the vendor demo/schematic), SDRAM A12 unconnected, reset = the button,
  DiagROM select + 50/60 swap via keyboard hotkeys (proposed: F12 swap, hold F1 at reset = DiagROM) and/or S1;
  check header bank voltage (3.3 V), re-check timing at 73 % fill, add the W9812G6KH datasheet to docs/vendor/.

### 2026-10-08
- Agreed: internal SD tape loader replaces the external MCU loader. PicoRV32 (not Nios: no vendor lock-in) at 112 MHz
  from M9K, plays unmodified .tap/.tzx (no PC preprocessing), pulse FIFO counted in CPU CEN ticks (exact at 1x and 8x),
  loader keys on the keyboard numpad (F-key fallback, optional separate LOADER button on a U7 pin opens the menu without a keyboard; no long/short-press dual use), OSD replaces the
  LCD. Prototype SD adapter: Adafruit 5683 MicroSD BFF (bare socket; add caps, MISO pull-up). DivMMC/esxDOS rejected. ~1,700 LEs + ~20-29 M9K: fits EP4CE15/
  EP4CE10, not the EP4CE6 candidate. Full design: docs/SD_TAPE_LOADER.md.
- Hotkeys assigned: F12 browser, F9/F10/F11 navigate/play, F1 at start = DiagROM, F8 = 50/60, Ctrl+Alt+Del = reset;
  KEY1 retired (user). Adafruit BFF: only TX (= CS via SJ2) used. BFF wired (user): MOSI AA13, MISO AA14, SCK AA15,
  CS_N AA16 (U8.7/9/11/13), caps fitted.
- SD tape loader implemented: PicoRV32 at 56 MHz (user left 56 vs 112 to us), firmware in LSpectrum/fw
  (FAT16/32, TAP + TZX incl. loops/jumps/calls, OSD browser), pulse player with gapless command chaining and
  T-state crediting, F1/F8/Ctrl+Alt+Del in RTL, KEY1 unused. PC tests (3 card layouts, every signal vs an
  independent Python reference) and RTL sims pass. Loads games on hardware (user).
- Same day, all working on hardware (user): F7 / keypad * Stop; browser 400 entries (32 KB RAM, RV32IMC);
  saving = recording mode ([Save to this folder] + 8.3 name, every ROM-format block into one .tap until F12;
  MIC recorder holds the Z80 while the firmware is busy); F6 = turbo / normal speed for loading and saving.
  First save version (dialog after the header, end after 3 s) split header/data into two files because the ROM's
  1 s inter-block pause (real-time 50 Hz INTs) is 8x longer in turbo T-states -> replaced by start/stop.
  End-to-end sim: 128K ROM loads a BASIC program from the SD image (first attempt had too-short test pilots: the
  ROM's LD-WAIT needs ~3.5 M T before the leader). Build: 8,379 LEs (54 %), 55/56 M9K, worst slack +0.47 ns.
  Docs: KNOWN_ISSUES.md, LSpectrum_Keys.docx, LSpectrum_Architecture.docx (Letter; generators in docs/src).

- GitHub: https://github.com/alexlutsenko7/A_Computer (user commits from a separate folder). Checked from a fresh
  clone: complete (T80, sim, fw/test added), firmware rebuilds identical, PC tests + loader sim pass. Cosmetic left:
  .sh files without the executable flag, 32 leftover files tracked (VGA_TEST/sim/work, transcripts, a log, .qws), no
  .gitignore. Top-level README.md written (L/README.md, to be copied to the repo root).
- Game sources: archive.org "World of Spectrum June 2017 Mirror" (92.8 GB zip, torrent
  https://archive.org/download/World_of_Spectrum_June_2017_Mirror/World_of_Spectrum_June_2017_Mirror_archive.torrent);
  worldofspectrum.net is not wget-able (WordPress pages, files on spectrumcomputing.co.uk); spectrumcomputing.co.uk
  robots.txt disallows everything except /entry/ -> manual downloads only.

### Next session
- Open items: docs/KNOWN_ISSUES.md (SD card once not recognised, keyboard once dead at power-up). Block RAM is
  55/56: further block-RAM features would need the SDRAM (e.g. folder list there).
- Still to test from v1: keyboard, AY/beeper + joystick (J1 wiring), external tape (TURBO_N).
- EP4CE6F17 port deprioritised (user, 2026-10-08: too small once the SD loader is in). Possibly: floating bus.

## Session log 2026-10-09

- Video: not all monitors accept 576p50 (user). Power-up mode is now 640x480@60 and only F8 swaps; the S1 switch
  input (SW_50_60, D2) was removed (pin unused). Build timing clean.
- Snapshots (user: .z80 format, F2 saves with a typed name, loading through the F12 browser, no quick slots):
  zx_bus freezes the CPU at an instruction boundary (M1 T2, not INTA, no prefix pending) and offers a command port
  (SDRAM byte, T80 REG words, DIR + LOAD = T80-only reset + DIRSet, AY, ports, state) to the loader CPU; fw/snap.c
  writes .z80 v3 (128K, compressed) and loads v1-3 (48K/128K). Loader RAM became full: -msave-restore, stack
  reserve 1.25 KB (measured ~0.75 KB), browser 400 -> 350 entries. Build: 9,020 LEs, worst setup +0.51 ns.
  Tests: PC host test (reference files + round trips, independent decoder), tb_snap (random freezes / restores vs an
  undisturbed run, turbo and normal speed), whole-machine F2-save / F12-load simulation with the firmware.
  Works on hardware (user, 2026-10-09).
- Aquaplane horizon confirmed on hardware at frame INT 24.1 (line 24, pixel 166) with Level-1 contention: the default.
- Open: a 50 Hz mode for the user's worst TV (rejects 576p50 on VGA). Waiting for its VGA (analog) EDID from MonInfo.
  Analysis so far: 1080p50 is possible on analog VGA at 29.7 MHz (1 clock per Spectrum pixel = 5 screen pixels,
  528 x 1125 clocks, 56.25 kHz / 50.00 Hz, third PLL, 3rd clkctrl input). Catch: with 5 lines per Spectrum row the
  TV beam is ~40 % slower than the Spectrum's, so one INT delay aligns border effects at one height only (Aquaplane
  OK, multi-band / loading stripes drift up to ~8 rows); 3.6 lines per row (4/3 alternating, 691 lines) keeps them
  exact; a border buffer would decouple them but needs ~3 M9K (1 free). 576p stays the exact mode.
- Level-1 contention (F5) and the floating bus (same switch) added; DiagROM's floating bus test was failing before
  (snow test fails by design, not emulated). Sidewize (syncs with the floating bus) works on the hardware.
- Game collection cleanup (tools/sort_games.py, then by hand): 31 broken / bad-checksum TAPs, 1,565 TAPs that have a
  TZX of the same game, 327 TAPs with PAUSE 0 in their BASIC loader (Aqua Plane.tap: a modified emulator version
  that waits for a key with invisible text), and a C64 tape (Sidewize.tap) deleted; list in Games/deleted_taps.txt.
- Analysed, not done (user: not worth it now): TZX 0x19/0x18 (1 / 0 files in the collection), 48K timing mode (a real
  128K keeps 128K timing in 48 BASIC; auto-switch on 7FFD lock or a machine key would be "better than real").
- Game names shortened to the browser's 27 characters (tools/shorten_names.py: abbreviations S1/P2/Alt, brackets
  dropped, middle cut keeping the side/part; clashes get a publisher tag or " 2"): 4,561 files, list in
  Games/renamed_files.txt.
- Game tools keep .z80 / .z80.zip (snapshots load from the browser) and honour Games/protected.txt (names never
  deleted, renamed or moved; first entries: the user's Sidewize.z80 / Sidewize[a].z80 in games/s2).

### 2026-10-11
- Lag seen on 9 October was the TV's (user tested other monitors and a PC).
- Sidewize: the player flickered (~60/40, irregular) on all monitors in 50 Hz mode; clean in a 128K emulator. Not the
  display: moving the INT (PgUp/PgDn, 0..50) changed nothing, F5 off freezes the game (it waits on the floating bus).
  Cause: Sidewize polls port 40FF (IN A,(C) ; CP E ; JP NZ, 35 T) for attribute 40h (row 16) / 03h. Fuse 1.6
  (peripherals/ula.c, periph.c) reads the port after all I/O contention, at the start of the 4th T-state; a
  contended poll then sees only an attribute or FF. zx_bus sampled at T2 (after the T1 contention only): half of the
  polls saw bitmap bytes, a pixel byte 40h/03h ended the wait early. Fix in zx_bus: read point predicted at T2 from
  hpos + the remaining contention (2 pipeline stages, sample at chk[1]; a one-clock version failed timing by 2.5 ns),
  phase origin 14362 as Fuse. tb_float model changed to Fuse's rule (passes). New sim/tb_floatgame.sv +
  run_floatgame_sim.sh + mk_z80img.py: a .z80 game on zx_bus + T80, every floating-bus read vs Fuse (~1 min/frame).
  Build 9,338 LEs, +0.57 ns. Confirmed on hardware (user): Sidewize no flicker, Arkanoid and Cobra work.
- Not changed: Fuse also contends ports C000-FFFF while an odd RAM page is paged in; io_c only contends 40-7F.
- Game collection re-sorted (tools/resort_games.py, moves only): files grouped by first character (a-z, else 123),
  browser order, ceil(n/300) folders per letter, evenly filled; 5,922 of 15,965 files moved, 32 renamed " (n)" for
  same-name clashes in one group, 8 empty folders removed; log Games/resort_moves.log (undo possible).
- Question answered: Bluetooth audio out = original ESP32 (WROOM-32 DevKit, Classic BT; S2/S3/C3 cannot) as A2DP
  source, I2S from the FPGA (ESP32 as I2S master), UART to the PicoRV32 for pairing/PIN in the OSD; KCX_BT_EMITTER
  rejected (no PIN devices). User found a 30-pin WROOM-32 CP2102 Type-C board; not built yet. Latency ~150-250 ms (SBC).

### 2026-10-13
- Bluetooth audio built. ESP32 sketch `AAudio/AAudio.ino` (Arduino core esp32 3.3.2, ESP32-A2DP v1.8.11 from GitHub):
  A2DP source, audio from I2S (ESP32 = master: BCLK GPIO26, WS GPIO25, DIN GPIO22) or a test tone; text commands
  on USB and UART2 (GPIO16/17, for the PicoRV32 later), CRLF output, settings in NVS. PIN devices: legacy PIN
  requests answered with 0000/1234/8888/1111 in turn or a fixed `pin`; BT 2.0 devices (no EIR) listed by name request
  or MAC (library filter overridden); discovery stopped while connected; 16-digit PIN overflow in the library avoided.
- FPGA: `rtl/bt_i2s.v` in zx_system (AY + beeper, two one-pole low-passes at the AY rate, DC blocker per sample,
  Philips I2S slave, synchronised BCLK/LRCK); pins U7.17 H1 BT_BCLK, U7.18 H2 BT_LRCK, U7.19 F1 BT_DATA; U7.20 F2 /
  U7.21 E1 reserved for the ESP32 UART. sim/run_bt_i2s_sim.sh passes (16/32-bit slots). Build 9,498 LEs, 74 pins,
  +0.43 ns. Not yet tried on hardware.
- Bose headphones crashed the ESP32 in 38/40 connects: IntegerDivideByZero in SBC_Encoder_Init (ESP-IDF 5.5). When the
  sink opens/configures the stream itself with the standard SBC config, Bluedroid never fetches its capabilities,
  bta_av_co_audio_set_codec fails and the encoder stays zero. A first fix (calling btc_a2dp_source_setup_codec at
  "connected") asserted (link not yet open). Final fix: -Wl,--wrap=bta_av_co_audio_set_codec (library
  AAudio/libraries/AAudioLinkFix: Arduino passes ldflags only for a precompiled library with a stub archive), the
  wrapper reports success while connected. Confirmed by the user: connects, test tone plays.
- User: the Bluetooth device must be chosen from LSpectrum, USB only for debugging. Added: F3 = Bluetooth menu
  (fw/bt.c: scan, connect, disconnect, forget, PIN, volume, Spectrum sound / test tone; tape keeps playing), UART in
  tape_loader (reg 0x3C, 115200, 512-byte RX FIFO in an M9K; BT_TX F2 = U7.20, BT_RX E1 = U7.21), loader key bit 16
  (F3). ESP32 sketch: `info` one-line state, `scan` drops the link first.
- Firmware no longer fitted 32 KB (19.4 KB code). User pointed out unused block RAM: the screen shadows took 8 M9K
  each (8K x 1 slices) and JT49's 128 x 8 table a whole M9K. A 36 KB lane RAM (9 M9K per lane) made synthesis leave
  the PicoRV32 register file in logic (~1,800 LEs, +0.13 ns): its M9K estimate (shadows at 8) said "full". Final:
  shadows and a 3 KB RAM extension (768 x 32, byte enables, maximum_depth 256 = 3 M9K) as explicit altsyncrams
  (`ifdef ALTERA_RESERVED_QIS`, arrays in simulation), JT49 table in logic (QSF AUTO_ROM_RECOGNITION OFF),
  browser 350 -> 320 entries. 56/56 M9K, 9,829 LEs, +0.71 ns, hold +0.15 ns.
- UART bugs found in simulation (tb_tape_loader + ESP32 model): the stop bit lasted 1-2 clocks between bytes
  (busy ended at its start); OSD redraws (~1.6 ms) overran a 16-byte RX FIFO (now 512); menu redraws on ESP32
  lines and PIN typing. SystemVerilog has no "\r" escape (use "\x0d").
- Full run_loader_sim.sh (19 min) with the final firmware: tape signal 168 segments / 0 mismatches, stop, recording
  (file checked on the card image), speed, and the Bluetooth menu all pass (the menu-closed check had to look at
  osd_full: the "Speed: turbo" row from the step before stays on the bottom line). +define+BT_ONLY run: PASS.
- New document docs/LSpectrum_Connection.docx (all wiring); Architecture and Keys documents updated.
- User: TAPE_IN and TURBO_N (the adapter's tape header, for the old external tape simulator) are not used any more:
  removed from the design (ports, zx_bus EAR hold logic: EAR = loader while it plays, else the beeper; turbo = loader
  only; zx_system FORCE_TURBO parameter for the whole-machine testbench), QSF/SDC and all documents
  (QM_ATRIX_ADAPTER.md keeps the hardware description, marked "not used by LSpectrum"). zx_system: cont_on is now
  declared before its first use (Questa vlog-2388); run_sim.sh compiles bt_i2s.v.
- That build failed timing by 0.16 ns (SDRAM request path, placement only; same logic was +0.71 ns before): QSF
  OPTIMIZATION_MODE "HIGH PERFORMANCE EFFORT" -> 9,753 LEs, 74 pins, 56/56 M9K, +0.60 ns, hold +0.16 ns.


### 2026-10-13 (later): Extended I/O board (KiCad, `Extended/`)

- Discussed other machines on this FPGA (C64 without the 1541 likely fits; the 2-bit VGA DAC cannot show the C64
  palette -> 4-bit DAC; second joystick port). User asked for a new I/O board in `Extended/` (QM_Atrix_adapter/ untouched).
- User decisions: separate board wired to the FPGA board (no plug-in headers), 4-bit DAC (523/1.05k/2.1k/4.22k,
  0.7 V full scale), two standard right-angle DB9 male (pin 7 open), microSD socket on the board, 7803 switching module
  (5 V in), no 50/60 switch, no tape header, no audio amplifier (two volume pots -> 3-pin audio-out header), keyboard
  module with its USB end past the board edge, ESP32 30-pin dev board (DOIT pinout, CP2102 USB-C) on 2x 1x15 sockets,
  host header J1 = 2x32 (same size as U7/U8): pins 1-40 as before + 41-45 BT_BCLK/LRCK/DATA/TX/RX, 46/63/64 GND.
- Footprints checked against JLCPCB/LCSC stock: VGA = CONNFLY DS1038-15F (C75754; 2.29x2.54 rows -> new local
  footprint, flange flush with the edge, pin rows 8.63/11.17/13.71 mm); DB9 = CONNFLY DS1037-09M (C75750; fits the
  KiCad 7.70 footprint, flange 0.4 mm past the edge); microSD = Molex 104031-0811 (C585350). All "Extended" at JLCPCB.
  ESP32 and keyboard modules are bought separately (not JLCPCB parts).
- Layout iterated with the user (the user moved parts; I adjusted the outline, labels, nets). Final 84.1 x 83.43 mm,
  routed on 2 layers with FreeRouting 2.5.0 (no neckdown; +5V 0.4 mm, GND/+3V3 0.3 mm, signals 0.25 mm), GND pours on
  both layers, user's stitching vias. DRC: 0 unconnected, 0 clearance, 0 schematic-parity; left: DB9 outlines at the
  edge, 5 single-spoke thermals (J1.3/20/40/46, RV2.3) that also have GND tracks.
- Open: user review of the routed board; optionally pick a JLCPCB 1x15 female header for the ESP32 sockets; FPGA pin
  assignment for the 2x32 J1 wires (docs/BOARD_PINOUT.md) and the 4-bit VGA in LSpectrum when the board is built.

### 2026-10-13 (evening): cheaper FPGA? -> ESP32 system controller
- Question: move SD/loader work to the ESP32 and use a cheaper FPGA. Current loader: tape_loader 3,953 LEs / 40 M9K,
  of which PicoRV32 2,594 LEs, firmware RAM 35 M9K.
- Trial build (throwaway copy, deleted): EP4CE6F17C8 (6,272 LEs, 30 M9K, 2 PLLs), PicoRV32 + RAM replaced by an
  SPI-slave bus master, everything else unchanged (JT49, keyboard, SD SPI, BT UART): **6,311 combinational cells
  -> does not fit** (39 over); speed / balanced / aggressive-area synthesis all gave 6,311. Memory 145,920 bits,
  2/2 PLLs, 78 pins would have fit. Big users: T80 2,585, zx_bus 710, tape_loader rest 903, keyboard 499,
  JT49 450, sdram_ram 405, video 316. EP4CE10 would fit; DDR boards were considered and rejected.
- User: stay on the EP4CE15; block RAM matters, not LEs; future C64 core. Firmware RAM today: 19.4 KB code,
  11.5 KB browser list (320 x 36 B), ~2.1 KB SD/FAT buffers, stack 1.25 KB. Keeping PicoRV32 with SD/FAT on the
  ESP32 would save only 11-15 M9K; removing PicoRV32 saves ~38. Decision: the latter (section "Next stage" above).
- Next session: user wires the SD card to the ESP32 and the SPI link to U7.7-11 (table above); then step 1.
- Step 1 built the same evening (user: build now, any ESP32 pins): `rtl/esp_link.v` (SPI slave, mode 0, SCK <= 8 MHz
  oversampled at 56 MHz; WR/RD/OSD/FIFO/MWR/MRD/STAT; MWR/MRD bursts = one snapshot command per byte, MRD
  prefetched; sticky error flag), in `tape_loader` under `ESP_LINK` (PicoRV32 + RAM out, SD SPI writes off,
  reg 0x00 = core ID 5A580001, reg 0x04 = IRQ causes/mask; esp_irq pin). Quartus revision **LSpectrum_ESP**
  (`LSpectrum_ESP.qsf`, VERILOG_MACRO ESP_LINK; pins ESP_MISO R1, ESP_IRQ R2, ESP_SCK P1, ESP_MOSI P2, ESP_CS_N N1;
  SD pins dropped; `LSpectrum.sdc` picks the ESP or SD false paths by port existence; `LSpectrum_ESP.cof` -> .jic).
  Build: 7,520 LEs, **19/56 M9K**, 75 pins, +0.39 ns / hold +0.16 ns, fully constrained.
  sim/run_esp_link_sim.sh (tb_esp_link: ID, register R/W, OSD, FIFO, 256-byte MWR/MRD across a page, error flag
  with slow commands, IRQ on key change): PASS. The sim found an MRD bug (saturating byte counter + 1 wrapped:
  bursts stopped after 11 bytes), fixed. ESP32 test sketch `ESPLinkTest/` (id, rd/wr, stat, ls -> OSD, keys via
  IRQ, memtest over the frozen screen, speed); compiles (343 KB). Not yet on hardware.
- 2026-10-14: user wired the ESP32 (link U7.7-11, SD moved to the ESP32). Test_wires/ (FPGA .sof + ESP32 sketch,
  report on USB) found the SD SCK joint bad; after re-soldering ALL WIRES OK (10 link/BT wires: levels, 2 MHz pulses,
  8 MHz SPI, no crosstalk; SD at 20 MHz). Then LSpectrum_ESP.sof + ESPLinkTest on hardware: core ID 5a580001, timer,
  SD ls + OSD, memtest 5 rounds 0 errors, MRD 914 KB/s, link stat 0. Step 1 works; `keys` F1-F12 OK (HID 3A-45, KEYS bits as fw/hw.h).
- 2026-10-14 (later): step 2 by porting, not rewriting: AAudio runs the loader firmware (LSpectrum/fw, compiled as
  C++, register proxies over the link) next to Bluetooth; one ESP32 firmware for both FPGA builds (loader only when
  the link answers 5A580001). Casts added in fat.c/util.c for C++ (PicoRV32 fw.bin byte-identical). Flash now holds
  LSpectrum_ESP.jic. On hardware: loader starts, SD mounts at 20 MHz, BT stays responsive; user confirmed
  the same day that everything works (F12, tapes, .z80, F2, F3).
- 2026-10-14 (afternoon): Extra_PCB_CycloneIV (was Extended/, project + libraries renamed): schematic: SD card on the
  ESP32 (D18/D19/D23/D5), ESP32 SPI link + IRQ on J1, one 3.5 mm jack (AY 2.2k + beeper 2.2k + 1k to GND, mono on tip and
  ring; PJ-320D-4A C95562), volume pots removed. J1 = core board U8 pin for pin (side-by-side boards, outer row facing
  U8's outer row, pin 1 opposite pin 1; mirrored footprint PinHeader_2x32_..._RowsSwapped, 1.7 mm from the edge, DNP,
  hand-wired); VGA MSB pairs, syncs and keyboard keep LSpectrum's FPGA pins (E22 D22 C22 B22 N20 M20, F22/H22,
  AA18/AA19), new signals on AA13-AB17 (link, BT), AB18/AB19 (audio), AA20-U21 (joysticks), E21..M19 (VGA LSBs).
  U1 got a 15 x 12 mm reserved courtyard. Routed with FreeRouting 2.5.0 (724 segments, 55 vias) + user GND stitching
  vias; DRC 0 errors / 0 parity. JLCPCB files by tools/jlc_export.py (U2 ESP32, J5 keyboard, J1 DNP); U1 = YLPTEC
  K7803-500R3 C5369643 (4.75-36 V in; the first pick C5369647 needed 6 V); BOM grouped by LCSC part (two DB9 lines had
  shown 0 available). User submitted the order; board being assembled. Next: bring-up when it arrives (wire J1 to U8,
  new FPGA pin assignment for this board, 4-bit VGA, second joystick, audio jack).
- 2026-10-23: I/O boards delivered. J1 is wired to U8 with each pin pair swapped (J1.2k-1 -> U8.2k, J1.2k -> U8.2k-1;
  the power pairs are symmetric), so every signal sits on the partner FPGA pin. LSpectrum re-pinned for the I/O board
  only (QM_Atrix debug adapter retired: GND_TIE, the U7 wiring and the adapter pinout removed): VGA_R/G/B[3:0] + HS/VS
  (ZX normal = 4'hD, bright = 4'hF, one pclk register stage in the I/O cells), KB_OUT/KB_IN, AUDIO_AY/AUDIO_BEEP,
  JOY1/JOY2 (ANDed into the Kempston port), ESP link + BT on AA13-AB17. Build: 7,469 LEs, 84 pins, setup +0.15 ns,
  hold +0.16 ns, no unconstrained paths; .jic regenerated. Docs (BOARD_PINOUT, READMEs, Connection/Architecture
  .docx) describe the I/O board.
- 2026-10-23 (later): on hardware it works; picture a bit dark (DAC is the standard 0.7 V full scale, the old adapter
  gave ~1.46 V). ZX normal colours raised from 4'hD to 4'hE (bright stays 4'hF).
- 2026-10-24: joystick modes (user: both ports were always Kempston). F4 (free) opens an ESP32 OSD menu with three
  modes, stored in INTPOS[29:28] of the tape loader (reset 0): 0 both Kempston (ANDed, as before), 1 DB9-1 Kempston +
  DB9-2 Cursor (5 6 7 8, fire 0), 2 Interface 2 (DB9-1 Sinclair 1 = 6-0, DB9-2 Sinclair 2 = 1-5). zx_system
  synchronises the pins and the mode, and ANDs the joystick keys into the keyboard matrix (one register stage).
  lkeys 17 -> 18 bits (bit 17 = F4). Build: 7,569 LEs, setup +0.22 ns, hold +0.17 ns; esp_link sim PASS; sketch 88 %.
  Works on hardware (user).
- 2026-10-24: pixel clocks for HDMI readiness: 640x480@60 from 25.000 (59.52 Hz, -0.79 % against CEA's 25.200: outside
  the +-0.5 % tolerance; also the TDP158 minimum) to 25.208 MHz (60.02 Hz), 576p from 27.000 to 27.009 MHz (50.017 Hz;
  a real 128K is 50.021 Hz). One VCO 756.25 MHz (50 x 121 / 8, PFD 6.25 MHz, /30 and /28): exact 25.200 + 27.000 need a
  VCO multiple of 378 MHz, unreachable from 50 MHz with PFD >= 5 MHz; a third PLL for 25.200 alone was not taken (clock
  switch inputs from two PLLs). Line/frame timing already matched VESA DMT / CEA VIC 1 and VIC 17. Build: 7,587 LEs,
  setup +0.51 ns, hold +0.14 ns. Works on hardware (user).

### 2026-10-27: machine menu + L64, step 1 (menu core, remote update)
- User decisions: menu at every power-up; small separate menu core as the factory image; full feature set for the C64
  incl. .d64 (1541); plan above ("Next stage: machine menu + Commodore 64").
- `AMenu/` built: menu_boot (altremote_update: read previous trigger + boot address; write watchdog off, boot address,
  reconfig; 12.5 MHz = CLOCK_50/4), menu_video (32 x 24 text, OSD font, highlight, error row), keyboard via zx_keyboard
  (raw report), joysticks. 546 LEs, 2 M9K, timing clean. Cyclone IV altremote_update needs out_data_width = 29; the
  generated block takes the boot address as byte address data_in[23:2] (checked in db/rmtupdt_*.tdf).
  sim/run_sim.sh: power-up case and failed-image case PASS, screen dumps OK.
- LSpectrum: STRATIXIII_UPDATE_MODE REMOTE, KEY1 (Y13) held 21 ms -> reconfig (back to the factory image). 7,604 LEs,
  setup +0.12 ns, hold +0.17 ns.
- `AMenu/L.cof` -> L.jic: page 0 AMenu (page_flags 1 = factory), page 1 LSpectrum at 0x080000 (page_flags 0,
  explicit start_address; without it cpf packs the pages back to back), roms48k.hex at 0x100000. LSpectrum.cof retired.
  Two factory-flagged pages make quartus_cpf fail with only "Multiple remote update factory pages detected".
- Open (hardware): menu shows, both machines start, KEY1 returns with the cursor on the machine; choosing L64
  (empty flash) must come back with "Could not start" (checks the trigger bits, which come from forum reports).
- C64 sources looked at (MiSTer C64_MiSTer fe6dfe5, 2026-09-06): c64.sv GPL-2+; FPGA64 files (buslogic, VIC-II,
  cpu_6510) "Copyright Peter Wendrich" with no licence text in the headers; SID = Dag Lem's reDIP SID, CERN-OHL-S v2;
  VIA 6522 (Gideon Zweijtzer) GPL-3; mos6526 (Rayne/slingshot) no header; T65 BSD-style; rtl/roms/*.mif hold the
  Commodore ROMs (not to be copied). Licence decision needed from the user before step 2.

### 2026-10-27 (later): L64, steps 2-4 built (not on hardware yet)
- `L64/`: c64_pll, c64_system (bus: one owner per phi half, SDRAM access at tick 2, CIA/SID tick 12, CPU enable
  tick 15; CPU bus latched at phi1 tick 2), c64_keyboard (positional, Alt+F1..F8 = C64 F-keys, PgUp = RESTORE),
  c64_video (Kawari RGB + OSD), L64 top (KEY1 -> menu). Kawari changes (SOURCE.md): exported 14-bit VIC address +
  phase, ext_rst (Quartus dropped the power-up-1 internal reset: the whole VIC-II was optimised away, 3,090 LEs),
  char_buf in block RAM (-1,100 LEs), power-up values for simulation.
- Snapshot port (MRD/MWR via an SDRAM arbiter, bus first; REG = T65 Regs; freeze before an opcode fetch, CIAs/SID
  stop with the CPU), tape_loader: CORE_ID parameter, 32 registers, FLASH 0x40 (flash pass-through, SPI byte
  engine) and RELOAD 0x44; LSpectrum ties them off (needs a rebuild + esp_link sim). INTPOS[31] = SID 8580 on C64.
- ESP32 (`src/c64.cpp`, main.cpp): core ID 43360001; ROM install from /ROMS/C64/ (KERNAL*, BASIC*, CHAR*) into flash
  0x200000 with verify + RELOAD when the flash has none; .prg/.t64 inject (BASIC: pointers + RUN); C64 .tap play
  (2 half periods per pulse, cycles counted while the motor runs) and record (v1); F4 port mapping, F5 SID model.
  Sketch 1.17 MB (89 %).
- Sim (`L64/sim/run_sim.sh`, ROMs from roms_local/, RAM test patched out): boots to READY with the right banner
  and 38911 bytes free (~150 ms machine time, ~30 min wall). Questa needs sid_stub.sv (SID sources use before
  declaration); only one Questa session at a time (nodelocked licence).
- Build: 12,168 LEs (79 %), timing met (+1.22 ns at 94.5 MHz, +1.57 ns at 31.5 MHz), fully constrained.
- 1541 (step 5): MiSTer's c1541 needs its DDRAM track cache and c1541_logic ("from Mark McDougall") has no licence;
  plan: own drive logic around T65 + via6522 (GPL-3), sectors from the ESP32 over the link. ~3,200 LEs left.
- 1541 (step 5) built: `c1541.v` (ours: T65 at 1.000 MHz from a DDS, 2 KB RAM + 16 KB ROM + 8 KB track buffer in
  block RAM, 74LS42 decode, serial bus with ATN acknowledge, stepper -> half tracks) + `c1541_gcr.v` (ours: disk
  surface from the track buffer: SYNC/header/gap/data in GCR at the density the DOS selects, SYNC detection and
  byte-ready framing; write mode decodes data blocks back into the buffer, dirty bits) + iecdrv_via6522 x 2
  (Gideon Zweijtzer, GPL-3, rtl/via/). The 1541 ROM comes with the C64 ROM image (48 KB now: ROM at image 0x8000,
  header byte 13 = 1; also copied into the drive's block RAM while loading); no 1541 ROM = no drive.
  tape_loader: MCTL/MSTAT 0x48, MCLR 0x4C (generic machine registers). ESP32: .d64 mount (BAM ID), track under the
  head -> track buffer (MWR to 0x20000+, no freeze), dirty sectors -> .d64 (fat.cpp ff_update), types lO"*",8,1.
  tools/mk_d64.py makes test disks. Build: 14,677 LEs (95 %), 78 % memory bits, timing met.
- Sim fixes: stale pre-load bus request with an X address hung the SDRAM model (bus_pend only after ld_done; CIA2
  port treated as pulled up until its first phi2); Kawari relies on power-up zeros everywhere: Questa runs with
  +initreg+0 +initmem+0 (as the FPGA). Picture was squeezed: without HIRES_MODES the scan doubler needs native
  width (is_native_x_in = 1); sim/run_vic_sim.sh checks a register write and the 806-px border line.
  Track buffer: one address per port (Quartus could not infer three).

### 2026-10-27 (afternoon): first hardware tests (user)
- Menu: "Could not start" for both machines. Diagnostics added to the menu (reason code, the address the chip
  tried, mode, the reason before); cause: the generated altremote_update decodes WRITES only with read_source 00
  (db/rmtupdt_*.tdf param_decoder_select); menu_boot wrote with 11, so watchdog/boot address writes were dropped and
  the chip "booted" address 0 (the menu) as an application -> watchdog. Fixed (read_source 00); tb_amenu's model now
  drops such writes as the device. Reason bits as read: 02 watchdog (the Intel header's bit list did not fit).
  Machines also reset the watchdog (reset_timer every 82 us); KEY1 = press + release; LED on 2.7 s after start.
- LSpectrum: works from the menu (user loaded a game). Build seed 2 (+0.62 ns; default placement -0.09 ns), SDC
  multicycle 2 for rom_loader sd_addr/sd_din -> u_ram.
- L64: ROM install from SD worked; then every character drawn as one dot: Kawari computes the VIC address in
  the clock edge that starts tick 2, the bus took it at tick 2 = the previous access (g-access got the screen code).
  VIC address now taken at tick 3 (sim/tb_vic2.sv + VICTEST in tb_l64: HELLO through the real bus). Works.
- 1541: c1541_gcr read the track buffer one clock too early (2 registers: address + RAM output) -> every data byte
  shifted; fixed, sim/run_gcr_sim.sh decodes a whole track like the DOS (25 headers, 24 data blocks, PASS).
  ESP32: the track under the head is loaded before LOAD is typed (the DOS started on an empty track -> FILE NOT
  FOUND); the full LOAD"*",8,1 is written to the cursor's screen line (+ $CE, the character under the cursor) and
  RETURN is put into the keyboard buffer. On hardware: LOAD"$",8 + LIST and Bruce Lee.d64 load (user).
- Full-system disk sim: the patched fast-boot KERNAL reaches READY before the 1541 finished its self-test, so the
  sim's LOAD comes too early (not a design bug); the DISK test needs a later LOAD.
- Open: the stray character seen once after F12 (probably fixed by the screen-line typing), disk change detection
  (write-protect pulse on mount), reinstall when the flash has no 1541 ROM but the card does, snapshots, turbo,
  NTSC; docs (.docx) for the menu / L64.
- Next session first (user): Bruce Lee (C64HQ crack) loaded with loader effects the user could not judge. Test with
  predictable references: (1) a tools/mk_d64.py test disk (BASIC printing known text / colours), (2) simple programs
  without fast loaders, (3) the same game in VICE side by side with L64.
- Overnight sims (2026-10-27/28): DISK test PASS (1541 self-test done after 860 ms of machine time, then LOAD"$",8:
  DOS jobs B0 seek 18/0 -> 01, 80 read 18/0 -> 01, 80 read 18/1 -> 01; LIST shows 0 "TEST" 2A 2A / 1 "HELLO" PRG /
  663 BLOCKS FREE), menu testbench PASS (both cases, strict read_source model), esp_link PASS. tb_l64 DISK types
  LIST twice (harmless; the check runs again on the next 50 ms step).

### 2026-10-28: overnight results reviewed; F-key comparison; 60 Hz video (frame buffer)
- F keys vs LSpectrum: F12 / save line / F7 / F11 / F3 / F4 / Ctrl+Alt+Del / KEY0 / KEY1 the same, F5 = SID model;
  F6 showed "Speed: ..." but did nothing (no turbo clock), F2 / F8 / F1 had no function. F6 now says
  "Turbo: not yet on L64" (ESP32). User wants: 60 Hz at power-up (first), turbo on by default (second),
  snapshots if they fit (third).
- Menu: the "Chip tried address" row showed the raw read-back (0x180000 << 2 = 600000); a machine's address that
  reads back shifted is now shown as written.
- 60 Hz: an NTSC machine (Kawari can be a 6567) would be cheap but changes PAL games; the user chose the frame buffer.
  `L64/rtl/c64_fb.v`: writer at dot4x takes Kawari's `pixel_color3` the way its scan doubler did (the dot at
  raster_x is complete when raster_x moves on), 400 x 284 dots (raster_x 92-491, lines 16-299), 4 dots per word,
  256-word FIFO (M9K, clk_sd); triple buffers at 0x40000/0x60000/0x80000 (256 bytes per line); the reader fetches
  each line once into a 4-line M9K (up to 3 lines ahead), shows it twice at 2 px per dot, palette = Kawari's.
  SDRAM: `sdram_ram` got a 16-bit mode (`wide`, `din_hi`, `dout_w`; LSpectrum and its testbenches tie it off),
  L64's window is 20 bits; the frame buffer gets the SDRAM only at ticks 4-12 of a half cycle and only when no
  bus access waits, so the C64's accesses are never delayed. Kawari: NEED_RGB off (no RGB, no scan doubler; that
  freed its 2 M9K line buffers), outputs pixel / raster_x / raster_line added; `hires_vga_sync.v` dropped.
  PLL: c0 31.51 / c1 39.80 = the two pixel clocks into vga_clkmux (LSpectrum's sequencer, CLOCK_50), c2 dot4x,
  c3 SDRAM side, c4 SDRAM clock. Build: 14,940 LEs (97 %), 53 / 56 M9K, setup +1.08 ns (94.5 MHz), hold +0.11 ns.
- tb_vic / tb_vic2 use the colour index output; tb_l64 has a pixel clock (`+define+M50` for 50 Hz).
- Docs: README (menu + L64), L64 / AMenu / esp32 READMEs, SDRAM_CONTROLLER.md (16-bit mode),
  docs/L_Third_Party.docx (external cores and libraries, licences, how much is used).

### 2026-10-28 (later): turbo loading on L64
- Hardware (user): the 60 Hz frame buffer, F8 and the OSD work.
- Turbo (`c64_system.v`): CPU cycles at ticks 6 / 14 of either half (8 ticks: 3.94 MHz) through a new CPU SDRAM
  port (the VIC-II keeps the old one; arbiter VIC-II > CPU > frame buffer > snapshot); data checked 6 ticks after
  the latch (else 8 ticks later), enable one tick later. VIC-II / SID / colour RAM cycles wait for the normal phi2
  slot (sl_act); the VIC-II's chip select must stay on until phi1 tick 2, as it takes a write at tick 0 (first sim:
  black picture, every VIC write lost). CIAs: phi2_p after the latch, phi2_n with the data; RDY ignored; freeze
  only between cycles. 1541: in turbo the drive DDS adds 32 clocks' worth per C64 cycle (same 1.0156 ratio), drive
  cycles >= 5 clocks apart. On while the cassette or 1541 motor runs and MCTL[2] = 1 (ESP32: !slow_mode, F6). While
  the ESP32 refills the track buffer, no CPU cycle starts (C64 + drive pause together).
- Sim (+define+TURBO): boot in turbo, CPU 3.94 MHz, drive 4.00 MHz (ratio 1.0156). Build 14,929 LEs, setup +1.21 ns.
- Hardware (user): turbo loading works, with the OSD.

### 2026-10-28 (later): snapshots on L64
- I/O shadow: every CPU write to $D000-$DFFF also goes to SDRAM 0x3D000 (mirrors folded); mos6526 exports
  {CRB, CRA, IMR}. Snapshot port: REG 2 / 3 = CIA state, CTL (4) = restore mode request / CPU-only reset;
  track buffer now only at 0x2xxxx (0x3xxxx = restore bank in SDRAM).
- Restore mode: the CPU sees SDRAM 0x30000+ everywhere except $D000-$DFFF (I/O); ends at the first opcode fetch
  after an RTI. ESP32 (c64.cpp): .A64 = 32-byte header + RAM + shadow; load = RAM, colour RAM copy + vector + a
  generated program (VIC-II, SID, colour RAM loop, CIAs with force load, 6510 port, stack, A/X/Y, RTI).
- Sim +define+SNAPTEST PASS (frozen at $E5CD, restore mode ends after 51 us, registers and border right, runs on).
  Build 15,012 LEs, setup +0.88 ns. Hardware (user): works.

### 2026-10-28 (afternoon): Print Screen (both machines); ESP32 link timing
- Pushed to GitHub before this: 3ba2ccc (menu, L64, T65, docs; C64 ROMs excluded).
- Print Screen (USB HID 0x46, polled by the ESP32 in KEYRAW every 20 ms) -> SCRNnnnn.BMP (16 colours, 4 bpp,
  bottom-up, `esp32/src/shot.cpp`) in the browser's folder. LSpectrum (`snap.cpp` snap_screenshot): short freeze,
  the shown screen page (7FFD bit 3) + border -> 320 x 240; works on hardware; PC test `snap_test shot` checks
  every pixel (FAT16 / FAT32). L64 (`c64.cpp` c64_screenshot): the newest frame buffer, 400 x 284, the C64
  runs on.
- L64 frame buffer read: first version took address bits 19:18 from the MRD data word; the ESP32's MRD bursts
  (esp_hw.cpp cache, link frame 06) do not send it -> black picture, and later MRDs (track buffer write-back!)
  could have been misdirected by a stale data word. Now: CTL[2] = frame buffer hold; while it is on, MRD addr[16:0]
  reads the newest buffer (no freeze); otherwise MRD is unchanged. Sim SNAPTEST PASS (screenshot reads EE / 66
  against SDRAM, track buffer read after the hold, snapshot restore).
- Hardware with that build (12:11 .jic): L64 restarts over and over: the ESP32 reads the core ID / IRQ register
  with single bit errors (c3260001, 43760000, irq 0x0d) and takes it as an FPGA reset. Logic unchanged and sim
  PASS -> the link pins' timing: ESP_* have no SDC timing (false path) and this 97 % fit (15,010 LEs) routed them
  differently. Fix: FAST_INPUT_REGISTER on ESP_SCK / ESP_MOSI / ESP_CS_N (first synchroniser stage) and
  FAST_OUTPUT_REGISTER on ESP_MISO (tx_sh[7]) in L64.qsf and LSpectrum.qsf, so the pin timing no longer
  depends on the fit. Both rebuilt: fit reports show Input Register = yes (SCK, MOSI, CS_N) and Output Register
  = yes (MISO) in both; L64 15,051 LEs, setup +0.76 ns, hold +0.14 ns; LSpectrum 7,632 LEs, setup +0.57 ns,
  hold +0.16 ns; L.jic 12:31. Not yet on hardware.
- Next: hardware test of L64 (link
  stable, Print Screen picture), then docs for Print Screen (L64_Keys.docx, LSpectrum_Keys.docx, READMEs) and
  commit.
- Hardware with the 12:31 .jic (user): LSpectrum fine (all functions). L64: LED blinks fast (= no C64 ROM image
  at flash 0x200000, probably erased by programming the .jic), F8 works (FPGA), F9-F12 / Print Screen do nothing
  (= the ESP32 sits in c64_roms() after a failed ROM install, waiting for KEY0; the OSD message says why: "Put
  KERNAL...", "Flash write failed" or "Card error"). rom_loader sets done also with bad_image, so the flash
  pass-through is not blocked by that. Open: read the OSD message; check the install path (pass-through erase /
  write / verify) on this build; consider making the install retry instead of waiting for KEY0.

### 2026-10-28 (late afternoon): C64 ROM install made robust
- SD card checked (read-only): FAT32 clean (chkdsk), `/ROMS/C64/` files = roms_local (MD5), standard images.
- Flash read back over JTAG (`quartus_pgm -o "ei;readback.jic;EPCS64"`, nothing written): ZX ROMs right; C64 image
  at 0x200000 byte-exact except header bytes 0-13 = FF (its 4 KB block erased, header never rewritten). The ROM
  loader judges the image by byte 0 only but copies all of it -> LED fast blink with a working BASIC; the ESP32
  saw no header and stopped in its install. Likely start: an ESP32 restart (12:11 build's link errors) during an
  install, which used to erase block 0 and write the header page first.
- ESP32 (`c64.cpp`, `main.cpp`): header page written last, after the ROM data checked out; every flash command
  starts with chip select off (the pass-through keeps CS on across an ESP32 restart, which garbled the first
  command after it); waits for the pass-through's busy before each write (a write while a byte shifts is ignored
  by tape_loader); erase timeout 2 s (was 500 ms), program 50 ms; a flash / card error is retried twice, then
  F12 tries again (re-mounts the card) instead of waiting for KEY0.
- PC test `esp32/test/c64rom_test.cpp` (in run_host_test.sh): SPI flash + pass-through model, the hardware state,
  300 installs cut off at random points: PASS (with the old c64.cpp: no valid header after any cut-off, because of
  the stale chip select; with a slow pass-through, writes lost). Sketch uploaded (1.17 MB). Not yet on hardware.
- Hardware with that sketch (user): LED still blinks, F9-F12 dead. ESP32 USB log: "no machine on the link" --
  the probe read L64's ID with bit errors (87260001, c7260001, 43740002, ... for 43360001). With the link at
  4 MHz the ID read was a constant 866c0002 = 43360001 << 1: the ESP32 samples MISO late (near the falling edge,
  through its GPIO matrix), while esp_link changed MISO 2-3 clocks after the *rising* edge: L64's 94.5 MHz
  link clock (+ the fast output register) moved that change onto the ESP32's sample point; LSpectrum (56 MHz)
  only just missed it. The ROM install never ran (no loader without a core ID).
- Fix (`rtl/esp_link.v`, both machines): MISO from its own register, loaded at CS_N falling and at each falling
  SCK edge (tx_sh[7]); byte logic unchanged on the rising edge. tb_esp_link: master samples SAMP after the rising
  edge (+HALF, +CLKH plusargs); run_esp_link_sim.sh sweeps 56 / 94.5 MHz x 8 / 4 MHz x 4 sample points: PASS
  (16/16); the old esp_link fails with late sampling (ID b4b00002 = 5a580001 << 1, as on hardware) and passed only
  with the old rising-edge master. The slow-MRD error check now scales with the byte time. ESP32: the probe
  prints an unexpected core ID ("loader: unknown core id ..."); link back at 8 MHz.
- Builds with the fix: L64 14,624 LEs (95 %), worst slack +0.16 ns; LSpectrum seed 2 missed setup by 0.076 ns
  (zx_bus sd_addr -> SDRAM, unrelated placement noise) -> SEED 3: worst slack +0.108 ns, 7,685 LEs. ESP_MISO in the
  output register in both. L.jic 14:36. ESP32 sketch (8 MHz link) uploaded. Not yet on hardware.
- Hardware with the 14:36 .jic (user): LSpectrum and L64 both work (link, ROM install, keys).

### 2026-10-28 (evening): Ctrl+Alt+Del = back to the machine menu
- User: Ctrl+Alt+Del should restart the FPGA into the menu, so no board button is needed. Both tops
  (LSpectrum.v, L64.v): Ctrl+Alt+Del no longer resets the machine; synchronised to the remote-update clock,
  it sends the same reconfiguration request as KEY1 when the keys are released. The ESP32 restarts by itself
  (core ID gone). Consequences in the docs: DiagROM = F1 held at power-up / KEY0 / start from the menu; the F8
  50 Hz choice survives KEY0 only. Keys sheets, Architecture, Build docs, READMEs, SD_TAPE_LOADER.md updated.
- Hardware (user): Ctrl+Alt+Del -> menu works on both machines.

### 2026-10-28 (evening): Bluetooth volume after connecting
- User (L64): the F3 menu shows 100 % but the speaker plays quietly until the volume is set again. Cause in
  ESP32-A2DP 1.8.11: on connection the source registers for AVRCP volume notifications and takes the speaker's
  reported volume as its own software volume (bt_av_notify_evt_handler -> set_volume); our stored volume (prefs
  "vol", shown by 'info' / the F3 menu) was applied only once, before a2dp.start(). Both machines (the ESP32
  restarts with each); quieter SID output made it obvious on L64.
- esp32.ino loop(): for 5 s after a connection the stored volume is put back whenever the library's differs (at
  most every 0.5 s, "EV volume ... restored"); later changes from the speaker's buttons are taken over ("EV
  volume ... (set on the speaker)"), so 'info' and the menu show the volume in use. bt.cpp asks for 'info' on EV
  volume. The probe's ID log now prints only near misses (<= 6 bits off or a 1-bit shift): the menu leaves MISO
  floating, which read as random IDs. Sketch uploaded; not yet tested with a speaker.
- Hardware (user): with that sketch Krackout (.d64) hangs at LOADING, reproducibly (it loaded before the volume
  change). Debugging (ESP32 'loader' USB command, since removed): the loader task runs, keys and the link are fine
  (no dropped commands), MCTL says track 28 is in the buffer, MSTAT head 28 + motor + LED, and the track buffer
  in SDRAM equals the .d64's track 28 byte for byte; the same at normal speed (F6). The user asked to go back to
  the sketch before the volume change: the volume restore, the bt.cpp EV volume line, the near-miss ID filter
  and all debug code were removed again (sketch 1,174,515 bytes, the same as before); FPGA unchanged (.jic 14:57).
- Real cause of the Krackout hang: the card's `C64/tested/cp krackout.d64` differs from the local copy in 37
  sectors (track 28 all FF instead of zeros, track 9 sectors 0 and 3-5 rewritten, single-byte errors in 6-19):
  written back by c64_d64_service during the 12:11 / 12:31 builds' link bit errors (dirty bits misread, sectors
  read back with errors). Other C64 files on the card identical (ELITE.D64, DANDARE3.A64 have no local copy).
  The user restores the file. The volume restore and the near-miss ID filter are back (sketch 1,174,863 bytes).
  Proposed, not done: write back only sectors whose dirty bits two MSTAT reads agree on.
- Bisected on hardware (user, Krackout from a good copy): committed 3ba2ccc (.jic 10:43 + its ESP32) works;
  10:43 FPGA + current ESP32 works (volume right from the start) -> the cause is in the FPGA; current FPGA with
  c64_system.v / c64_fb.v as committed (no frame buffer hold) works; current RTL with the hold *and*
  ALLOW_POWER_UP_DONT_CARE OFF (L64.qsf) works. The hold logic is idle without a screenshot (logic
  identical), every clock crossing between the asynchronous groups is in the video path, and the design is
  fully constrained, so the suspect is a register without a reset whose power-up value synthesis chose
  differently per build (Power-Up Don't Care was On): each machine start is a new configuration, hence a
  build either always or never failed. With it, the drive went into write mode during the load and wrote FF
  data blocks (tracks 9 and 28), which the ESP32 saved into the .d64. Not yet found: which register.
- Build: L64 14,722 LEs (96 %), worst slack +0.139 ns; L.jic 17:00 (with LSpectrum 14:55).

### 2026-10-29: L64 start-up fixes (RAM clear, disk write-back guard, VGA sync), C64 done

- Overnight regression (all Questa sims): esp_link, zx_bt_i2s, zx_input, zx_cont, zx_float, zx_snap, menu, c64_boot,
  c64_snap, c64_turbo, c64_m50, c64_disk (124 min), zx_boot40 pass. run_floatgame_sim.sh / mk_z80img.py had stale
  paths (fw/test -> esp32/test, Games/games -> Games/ZXSpectrum); fixed (Sidewize needs +define+SIDEWIZE_KEMPSTON).
- Tried and not adopted: pausing the C64 and the 1541 while the ESP32 refills a track (drv_wait into the freeze and
  the drive's DDS). Its sims only exercised the power-up track load; the Krackout problem turned out to be the
  write-back below. The suspected FPGA write mode of 2026-10-28 (tracks 9 / 28 FF) was that write-back as well.
- Hardware (user): after Krackout and Ctrl+Alt+Del, starting L64 gave a full-screen flickering pattern; KEY0 did
  not help. Print Screen + F2 snapshot: 16 colours cycling every 72 dots = INC $D020 / JMP (9 cycles) with the
  screen off; RAM had "CBM80" at $8004 -> $8209: Krackout's reset protection, still in the SDRAM (it keeps its
  contents through a reconfiguration), caught every KERNAL reset. Fix (c64_system.v): after the ROM load the 64 KB
  RAM is written with 0 (~3 ms, ld_clr_done; SDC multicycle as for the loader's done) before ld_done, so at every
  start (menu, KEY0, ROM reload). tb_l64 +define+DIRTYRAM (CBM80 + the loop in SDRAM before power-up): passes;
  the old c64_system.v fails it (no BASIC, $8004 = C3). Confirmed on hardware.
- Hardware (user): a .d64 loaded once, then was broken: both card copies of Krackout had track 9 all FF. Cause
  (ESP32): Ctrl+Alt+Del / KEY0 while c64_d64_service ran: the reconfiguring FPGA reads as all ones (MSTAT: head 63,
  every sector dirty; sector data FF), written into the .d64 before the 0.5 s link check restarted the ESP32.
  Fix (c64.cpp): an MSTAT with head > 35 or dirty bits beyond the track's sectors is ignored; after reading a
  sector, link_alive() (esp_hw.cpp: core ID + IRQ mask) must hold before ff_update. Host test passes; uploaded.
- Hardware (user): a vertical line one pixel right of the picture (60 Hz), random colour / solid or dotted, changing
  per start, gone after F8, never in screenshots. Scope: the HSYNC edge couples onto the colour lines (+-40 mV,
  ~100 ns ringing, 40 pixels after the picture). The monitor auto-adjusts while the C64 start is still black and
  can take that spike for the right edge. Fix (L64.v): syncs off (no edges, colours black) from each start
  until 2 s after the C64 left reset (BASIC on screen), timed on ruclk; HSYNC / VSYNC as 3.3-V LVCMOS 2 mA
  (LVTTL allows no slew rate setting). Works on hardware. Next I/O board: series resistors in HSYNC / VSYNC.
- Hardware (user): the menu reported "reason 08" for L64: readback showed the image erased from 0x186C9F (mid
  page) to its end: the .jic had been programmed without Verify and the write stopped. Programmed again with ipv.
  The build document now says to tick Verify.
- Pac-Man (FH crack): the drive LED blinks slowly after RUN, not after LOAD: the game sends the drive something it
  rejects; harmless.
- Build: L64 14,770 LEs (96 %), setup +0.49 ns, hold +0.16 ns, fully constrained; L.jic 11:08.
  ESP32 sketch 1,174,943 bytes. User: the C64 is done.

### 2026-10-29 (afternoon): remaining L64 items before the final test round

- Disk change (ESP32 c64.cpp): choosing a .d64 while one is in holds MCTL "read only" (VIA2 PB4 low) for 0.3 s,
  as a disk covering the write-protect sensor while it slides in; the DOS sees the change and reads the new BAM.
  LOAD"*",8,1 is typed only at the BASIC prompt (frozen: $CC = 0, $9D = $80, IRQ vector $EA31), never into a
  running program.
- Read-only: the FAT read-only attribute (browser ENT.ro) mounts the .d64 write-protected (MCTL[1]); no write-back.
- 1541 ROM reinstall: c64_rom_present() returns 2 with the 1541 ROM (header byte 13); with 1 and a card that has
  DOS1541* the ROMs are installed again; if that fails the C64 runs on without the drive.
- esp_link.v (both machines): a frame is decoded only after CS_N was seen high since the reset, so a frame the
  ESP32 began while the FPGA started is ignored. tb_esp_link test 0 (a frame cut by the reset): the old esp_link
  fails it, the new one passes all 16 sweep points.
- Builds: LSpectrum 7,688 LEs, +0.61 / +0.16 ns; L64 14,811 LEs, +0.37 / +0.16 ns; L.jic 12:06,
  programmed with verify. ESP32 sketch 1,175,375 bytes, uploaded; host test passes. Hardware test round next.

---

## LTari: Atari 8-bit machine (third machine), plan (2026-10-29)

### Decisions (user, 2026-10-29)
- **Own chips, clean-room:** ANTIC, GTIA, POKEY and the PIA are written by us from documentation and checked
  against behaviour. Mark Watson's Atari800 core (non-commercial licence; its CPU may only be used inside that
  core) is **never opened**, not even for a look-up; a black-box comparison of its output in simulation would be
  allowed. The whole machine is our MIT code + T65, so selling the I/O board raises no licence question.
- **Machine:** 130XE (128 KB, PORTB bank switching for CPU and ANTIC), selectable as an 800XL (64 KB).
- **Video:** PAL (50 Hz, 312 lines, CPU 1.773 MHz), through a frame buffer at 800x600@60 with F8 = 50 Hz, as
  L64.
- **Media, first version:** .xex (straight into memory), .atr (disk over SIO, read + write), .car cartridges
  (standard 8 / 16 KB first, then common bank-switching types). Later or never: .cas, .atx, .pro, .dcm.
- **ROMs:** AltirraOS (XL/XE kernel) and Altirra BASIC by Avery Lee, both freely redistributable (AltirraOS:
  "Copying and distribution ... permitted in any medium without royalty provided the copyright notice and this
  notice are preserved"; Altirra BASIC: "freely distributable in both source and object code form"). They go
  into the .jic like the Spectrum ROMs; a user's own Atari ROMs could be installed from the card as on L64.
- Name (user): **LTari**; the two models are **LTari 800** (800XL, 64 KB) and **LTari 130** (130XE,
  128 KB). Folder `LTari/`.
- Machine menu (user): **two entries**, "LTari 800" and "LTari 130". One build, stored twice in the flash
  (e.g. 0x280000 = 800, 0x300000 = 130); at start the image reads its own configuration address from the remote
  update block (already in every machine for KEY1) and picks the model. No hand-over from the menu needed.

### References (the only sources for the chip logic)
- Altirra Hardware Reference Manual (Avery Lee, virtualdub.org/altirra): ANTIC DMA and timing, GTIA priorities /
  collisions / modes, POKEY timers / audio / serial / keyboard, PIA, memory map, XL/XE PORTB.
- De Re Atari; Atari 400/800 and XL/XE hardware manuals and chip data sheets.
- Acid800 (Avery Lee): hardware behaviour test suite, our acceptance test. Altirra and atari800 emulators as
  behaviour references (same program, compare picture and sound).

### Architecture (to be confirmed against the manual while writing each part)
- Top level and board side reused from L64: PLL (one VCO; Atari clock + SDRAM + pixel clocks), SDRAM
  controller, frame buffer (c64_fb.v adapted to the GTIA output), OSD, tape_loader / esp_link with a new core ID,
  ROM loader, Bluetooth I2S, KEY1 / Ctrl+Alt+Del to the menu, sync hold at start, RAM clear at start.
- CPU: T65 (6502C "Sally": RDY/HALT from ANTIC's DMA).
- Memory (SDRAM): 128 KB RAM, ROM image (OS 16 KB, BASIC 8 KB), cartridge image area, frame buffers. PORTB
  (PIA port B on XL/XE): OS ROM, BASIC, self-test window, 130XE bank select and CPU / ANTIC bank access bits.
- ANTIC: display list DMA, character / map modes, scrolling, player-missile DMA, cycle stealing (RDY), WSYNC,
  VCOUNT, NMIs (DLI, VBI, RESET key).
- GTIA: playfield colours, players / missiles, priorities, collisions, GTIA modes 9-11, PAL palette, CONSOL
  (START / SELECT / OPTION), triggers.
- POKEY: 4 audio channels (16-bit linking, high-pass filters, polynomial counters), timers and IRQs, keyboard
  scan (our USB keyboard mapped to the Atari matrix codes), RANDOM, serial port (SIO).
- PIA: joystick ports (two DB9), PORTB, SIO control lines.
- SIO disk: POKEY's serial bytes go to the ESP32 through a FIFO in the link registers; the ESP32 acts as an
  810 / 1050 drive (device $31, commands status / read / write / put / format) with the drive's handshake timing,
  serving .atr sectors from the card (write-back with the guards of L64's .d64 service).
- Keys (proposal, as the other machines): F12 browser, F2 snapshot, F3 Bluetooth, F4 joystick menu, F6 turbo,
  F8 50/60 Hz, Print Screen; START / SELECT / OPTION / HELP and RESET on keys still to assign (one function per key).

### Budget (estimate, to be confirmed by the first builds)
- T65 ~2,000 LEs; ANTIC ~1,500-2,500; GTIA ~2,000-3,000; POKEY ~1,500-2,000; PIA ~200; frame buffer, SDRAM
  bridge, ROM loader, link, OSD, audio ~3,000 (from L64). Total roughly 10,000-13,000 of 15,408 LEs: fits
  with margin, because there is no disk drive CPU in the FPGA (L64's 1541 is most of its size).
- Flash: the same image at 0x280000 and 0x300000 (512 KB slots), Altirra ROMs in the .jic; AMenu gets two entries.

### Steps
1. Get the Altirra Hardware Reference Manual and Acid800 (name chosen: LTari).
2. Skeleton: top level from L64, T65, memory map + PORTB banking, ROM loader with the Altirra ROMs, PIA,
   minimal ANTIC (display list, text mode 2) + GTIA (playfield colours): simulation boots AltirraOS into Altirra
   BASIC's READY screen (as tb_l64 does for the C64).
3. ANTIC complete: all modes, exact DMA / cycle stealing, fine scrolling, P/M DMA, DLI / VBI / WSYNC timing.
4. GTIA complete: players / missiles, priorities, collisions, GTIA modes, PAL palette, CONSOL, triggers.
5. POKEY: audio (sigma-delta + Bluetooth I2S), timers / IRQs, keyboard, RANDOM, serial.
6. ESP32: core ID, browser for .xex / .atr / .car, .xex loader, SIO drive with .atr read / write, cartridge
   loading + banking, OSD, F-keys, Print Screen, snapshots.
7. Machine menu entries 3 and 4, .jic, docs (keys sheet, build guide, third-party list: Altirra ROM notices).
8. Compatibility: Acid800 in simulation where possible and on hardware, then games and demos; a test plan sheet
   as for L64.

### Progress (2026-10-29)
- Step 2 (skeleton) in simulation: the ROM loader, RAM clear, T65, MMU, ANTIC display list + mode 2, VBI NMIs and
  the SIO command frame all work. The first boot run hung on the disk boot's retry: POKEY kept timers 3+4 held
  after the OS left the asynchronous receive mode (SKCTL $13 -> $23), so the output bit clock stopped and the
  second command frame never went out (fix: the hold only applies in the asynchronous mode). With the fix the OS
  retries the STATUS command (31 53 00 00 84) about every 40 ms, as expected with no drive.
- Board top level `LTari/rtl/LTari.v` (from L64): atari_pll (28.373 / 85.119 MHz) + atari_vpll
  (40 / 32 MHz pixel clocks), F8 clock switch, remote update (reads its own start address: 0x280000 = 800XL,
  anything else 130XE; KEY1 / Ctrl+Alt+Del to the menu), atari_keyboard, joysticks, POKEY audio (sigma-delta +
  Bluetooth), tape_loader with core ID 4154_0001 ("AT"), memory commands (MRD / MWR / frame buffer hold),
  atari_fb (triple frame buffer, 752 x 480 in 800 x 600, PAL palette from the manual's hue angles), OSD, sync
  hold. First build: 6,344 LEs (41 %), 55,296 memory bits, 2 PLLs, setup +2.04 ns / hold +0.14 ns, fully
  constrained.
- Keys chosen (one function per key, Alt+F-keys go to the machine as on L64): Alt+F2/F3/F4 START / SELECT /
  OPTION, Alt+F5 Reset, Alt+F6 Help, Pause and Alt+F7 Break; arrows = the Atari's Control + - = + *;
  ' \ [ ] ` = + * < > Inverse.
- Machine menu: four entries (LTari 800 at 0x280000, LTari 130 at 0x300000), name column widened to 12.
  L.cof: LTari.sof at both addresses, `LTari/roms/atarirom.hex` at 0x380000; the .jic builds
  (pages end at 0x2FCB87 / 0x37CB87).
- ESP32: core ID 4154_0001 accepted (`machine_atari`); the browser lists .xex / .atr / .car (loading: "Not yet"),
  the F3 and F4 menus work (F4: DB9-1 = stick 0 / stick 1); F2, Print Screen, saving: "Not on LTari yet".
  Sketch 1,176,027 bytes; host tests pass.
- First hardware test (user, 2026-10-29): both models boot to "Altirra 8K BASIC 1.59 / Ready" and BASIC runs. The
  first try showed garbled characters: ANTIC's display read of its line / character-data block RAM set the address
  one clock before the data was used, so the first colour clock of each machine cycle showed the data of the
  previous read (the character two places to the right, read for the next font fetch). Fix: address at ticks 1 / 9,
  data used at ticks 3 / 11. The simulation had only checked screen memory, not the drawn picture: tb_atari now
  also grabs the VGA output of the frame buffer (vga.png).
- SIO bridge `LTari/rtl/atari_sio.v` (POKEY's output bytes with the command line state -> ESP32 FIFO; ESP32 ->
  1024-byte FIFO -> bit stream on POKEY's serial input; tape loader MCTL / MSTAT / MCLR) and RELOAD (cold start)
  are in the build; the ESP32's drive emulation (.atr) is next.
- (2026-10-29 evening, unattended) GTIA complete per the manual ch. 6: P/M shift registers + size state machine,
  VDELAY, GRACTL (DMA, trigger latches), the priority equations (PRIOR 3:0, fifth player, multicolour), hi-res
  PF1 luminance, collisions ($22-$DD, lines 8-247; HITCLR), GTIA modes 9 / 10 / 11; a one-colour-clock pipeline
  so that the GTIA modes can pair colour clocks. Not modelled: table 18 write delays, table 15 lockup, pseudo
  mode E. Unit test sim/tb_gtia.sv. Build 7,147 LEs (46 %), timing clean.
- ESP32 drive (`LSpectrum/esp32/src/atari.cpp`): D1: for .atr (status / read / put / write / format, sectors
  1-3 always 128 bytes, write-back with ff_update split at card sector boundaries, link_alive guard); .xex as a
  read-only boot disk with our loader (`LTari/tools/mk_xexboot.py`, own 6502 code: BASIC off, segments,
  INITAD, RUNAD; uses $0700-$08FF); .car standard 8 / 16 KB (types 1 / 2) written to SDRAM 0x28000 through the
  memory port and mapped by MCTL [17:16] (MMU: cartridge > BASIC > RAM, TRIG3 = 1). Each cold-starts the Atari
  (RELOAD). The arbiter now serves the ESP32's port before the frame buffer (the link drops a byte that takes
  over ~1 us).
- Simulation results (2026-10-29 evening): disk boot through the SIO bridge passes (tb_atari +define+DISK: status,
  read sector 1, the boot code prints "DISK BOOT OK"; VGA frame from the frame buffer correct); .xex passes
  (+define+XEX, sim/mk_xextest.py: loader sectors 1-3, file sector 4, BASIC off, INIT, RUN -> "XEX OK");
  GTIA unit test passes (27 checks). Docs: docs/LTari_Test_Plan.xlsx (25 hardware tests).
- Cartridge passes in simulation (+define+CART: our 8 KB test cartridge at SDRAM 0x28000, $BFFD = 4 -> the OS
  skips the disk boot and starts it, "CART OK" at 0.45 s). An .atr / .xex takes the cartridge out again.
- Print Screen on LTari: the frame buffer's newest frame (held, memory command CTL [2]) as a 376 x 240
  256-colour BMP (shot.cpp now also writes 8 bits per pixel; palette table atari_palette.h from mk_palette.py).
  ESP32 mount fix: a new .atr / .xex is checked before it replaces the disk in (a bad file no longer leaves the
  old disk's state pointing at the new file).
- Atarimax cartridges (manual 8.2): .car types 41 (128 KB), 42 / 75 (1 MB, start bank 0 / 127). SDRAM addresses
  now 21 bits; the image at 0x100000-0x1FFFFF, written by the ESP32 through a cartridge window (MCTL [23], page
  [21:20]); MMU: any access to $D500-$D5FF selects the bank / switches the cartridge off; only a cold start resets
  it. Passes in simulation (+define+CART=4: bank 0 -> LDA $D501 -> bank 1 "BANK OK"). Build 7,179 LEs (47 %),
  timing clean.
- (2026-10-30) LTari video: the user saw a big border (BASIC's 320 x 192 playfield was 640 x 384 of 800 x 600).
  Now LSpectrum's modes and pixel clocks: 640x480@60 (25.208 MHz) shows the middle 320 x 240 of the stored
  376 x 240 at 2 x 2 (full height; 28 hi-res pixels cut per side, as a TV's overscan), F8 720x576@50 (27.009 MHz)
  the middle 360 x 240 with 48 black lines above and below. c64_video centres the OSD on the measured active area
  (same position as before for L64's 800 x 600).
- (2026-10-30) ESP32 .atr mount: an image whose header size runs past the end of the file (a 1996 Pac-Man .atr:
  header 26,624 bytes, file 13,312 + 16) was refused as "Not an .atr"; the size is now cut to the file, as Altirra does.
- (2026-10-30) LTari model: the 800 entry ran as a 130XE (user: banking test printed 11). Diagnostic read-back of
  the remote update current state (param 100) gave 0x03F80020 on both images: an application image cannot learn its
  own start address. Now two revisions of one project, parameter MODEL130: LTari800 (0x280000) and LTari
  (0x300000); the .cof takes LTari800.sof for Page_3. Test program LTari/tools/mk_modeltest.py (MODELTST.XEX:
  banking test on screen).
- (2026-10-30) M.U.L.E. (.atr for the 400/800: boot loads 129 sectors to $7BEF-$BBxx) hangs with BASIC on (user: top third
  cyan) and works with Alt+F4 held while pressing Enter in the browser (user). The LTari browser's bottom line now says
  "Ent=load  Alt+F4+Ent=BASIC off"; key sheet updated (KEY0 takes the disk out, so not for disks). POKEY + speaker sum
  saturates (it wrapped at 1024 with all four channels at volume 15 + the speaker). SIO "noisy I/O" beeps are authentic.
- (2026-10-30) LTari disk change: Shift+Enter on an .atr changes D1: without RELOAD (cartridge and SIO state kept);
  browser line "Ent=boot Shift=swap Alt+F4=noBAS". User: F6 / tape dropped for the Atari.
- (2026-10-30) LTari snapshots (F2, .A8S), as L64: freeze holds tick at 0 (no chip acts on tick 0) when the
  CPU's next own cycle is an opcode fetch (Sync); I/O shadow 0x3D000 (every CPU write to $D000-$D7FF, GTIA / POKEY /
  PIA / ANTIC mirrors folded); REG 0/1 T65 Regs, 2/3 PIA {CTL, DDR, OR}, 4 {model, Atarimax off, bank, type}; CTL
  restore mode / CPU-only reset; restore bank 0x30000 (CPU only; ANTIC DMA sees normal memory), NMIs masked in
  restore mode. ESP32 atari.cpp: header 128 bytes (regs, PIA, cartridge type / bank / name, disk name) + shadow
  1,280 + RAM 64 / 128 KB; load checks the model and that the same cartridge is in; restore program: NMIEN off,
  POKEY (SKCTL init first, STIMER last), GTIA (HITCLR), PIA (DDR then OR then CTL), ANTIC (NMIEN last), Atarimax
  bank by an access to $D5xx, stack + A/X/Y + RTI. Sim tb_atari +define+CART=1 +define+SNAPTEST.
- (2026-10-30) **Rename** (user): the project is **L**, the machines **LSpectrum** (was ASpectrum), **L64** (was ADore 64)
  and **LTari** (was AlexTari); folders, Quartus projects / revisions / top modules, `AMenu/L.cof` -> `L.jic`, docs,
  OSD and menu texts renamed (this file too). Signatures: C64 flash ROM header "L64 ROMS" + 4 spaces (the ESP32 still
  accepts "ADORE64 ROMS"), .a64 magic L64SNAPS (still loads ADORE64S), Atari ROM header "LTARI ROMS", .a8s LTARISNP.
  GitHub: new repo L_8_bit (the old ASpectrum repo is deleted by the user). The root folder name is unchanged.
- (2026-10-30) **Flash update from the SD card** (user: boards shipped with a loader, updated by copying LUPDATE.BIN):
  AMenu gets the ESP32 link (tape_loader + esp_link, menu_pll 75 MHz, core ID 4D4E0001), an OSD screen instead of the
  menu (input locked) and flash_if; 12,532 LEs, timing clean. ESP32 (update.cpp, flash.cpp split from c64.cpp,
  fat_delete): at the menu, LUPDATE.BIN in the root = update: header + CRC-32 check, 4 KB sectors compared and only
  differing ones erased / programmed / verified, machines first, menu (0-0x7FFFF) last, C64 ROM area never; file
  deleted at the end; menu changed -> "switch off and on". "No machines installed" when no slot has an image (data
  starts at +0x20 with the sync byte 6A: a 16-byte check was wrong, caught by the test). AMenu/tools/mk_update.py
  (.cof -> .pof -> .rpd; the .rpd is the flash byte for byte: ROM bytes bit-reversed) and --loader (L_loader.jic).
  PC test update_test.cpp: update, up to date, damaged file, 60 cut-offs (menu sectors only after the machines),
  first install on a loader board (519 sectors, ~3.5 min modelled): PASS. make_github.py builds the public
  LUPDATE.BIN / L_loader.jic and checks DiagROM in both bit orders. Not yet on hardware.
- (2026-10-30) LTari snapshot simulation (+CART=1 +SNAPTEST) PASS; the 640x480 VGA frame shows the 320-pixel playfield
  across the full width.
- (2026-10-30) Hardware: SD card update works (user: loader with 00 fill, LUPDATE.BIN installed all machines). Then
  Bluetooth audio broke (silence / chopped, also the ESP32's own test tone): since the menu has the link, the ESP32 starts
  with the menu at power-up, begins the A2DP connection, and restarted (housekeeping: core ID changed) when a machine was
  chosen, cutting the half-made connection; the Bose headphones then reconnect without a working stream. Fix: leaving the
  menu ends the menu task (menu_present() = 0, loader_task clears running) instead of esp_restart; the next probe starts
  the machine. User: works (2 power cycles). Misleading on the way: opening the ESP32's USB port can reset it (serial
  queries disturbed the sessions); a RAM-use theory (+9.8 KB static) was wrong (the same build works).
- (2026-10-30) Menu font (user: not the Spectrum font on the startup screens): Spleen 8x16 2.1.0 (BSD-2, AMenu/font/ with
  LICENSE), menu_video reads 16 font rows per character (ry[3:0]); notice in BUILDING_AND_LICENSES Appendix A. An italic
  slant of the Spectrum font was built first and dropped (user chose a clean upright 8x16 font).
  Atari collection: tools/sort_atari.py imported 5,011 files (.atr/.xex/.com) from a 5,494-zip download into
  Games/Atari (letters, <= 300 per folder; old files in #tested; side / disk markers kept in the 27-character names).
- (2026-10-30) OSD font in all machines too (user): zx_video / c64_video read 16 Spleen rows per character
  (../AMenu/rtl/menu_font.hex). c64_video's font had been built in logic (the inverse XOR in the read register
  prevented block RAM; L64 failed timing by 0.44 ns with the 2 KB font): the raw byte is registered, the XOR is applied
  at the pixel. L64 14,844 LEs +0.155 ns, LTari 6,961 LEs +0.133 ns, LSpectrum +0.144 ns. LUPDATE.BIN "Spleen font".
- (2026-10-31) Bluetooth: a non-Bose speaker (00:02:5b:01:11:ae) played chopped (0.5 s on / off, also the test tone)
  with the current firmware but steady with the GitHub d9423cb build. Static RAM brought back to the old level
  (76,668 B vs 75,612): update.cpp buffers on the heap (only the menu mode allocates them), ENT size field 22 bits,
  atari.cpp serves the .xex boot loader from flash, screenshot row and Atari snapshot shadow malloc'd. User: works.
  Volume: that speaker reports no AVRCP volume, so the stored volume was never sent (quiet until Right in F3): the
  stored volume is now sent once 1.5 s after connecting.
- (2026-10-31) Delirium Tremens (LTari) crashed in its depacker: GTIA's unused read addresses $D015-$D01E returned $00,
  the manual (table 13) says $0F; the depacker branches on LSR $D017. Found by comparing an RTL trace with a Python 6502
  reference run (tb_atari +INJSTAGE). gtia.v fixed; LTari +0.137 ns, LTari800 +0.141 ns; LUPDATE.BIN "GTIA fix".
  User: works on hardware.
- (2026-10-31) Menu: "No machines installed" flashed on a machine just started from the menu (the 2 s presence check
  read the flash while the FPGA reconfigured; the screen went to the new machine's OSD). The check now requires
  link_alive() before drawing. User: works.
- (2026-10-31) ESP32 firmware from the SD card: LESP32.BIN (the sketch's esp32.ino.bin, arduino-cli compile -e) in the
  root folder; the menu mode writes it into the spare OTA slot (app0 / app1, 1.25 MB each), esp_ota_end verifies it,
  the slot is selected, the file deleted, the ESP32 restarts; LESP32.BIN is handled before LUPDATE.BIN. src/espupd.cpp
  (portable, our FAT) + ota_* in esp_hw.cpp. Firmware 1,193,120 B (91 %). Uploaded over USB; User: LESP32.BIN + LUPDATE.BIN together work.
- (2026-10-31) Public repo renamed by the user: https://github.com/alexlutsenko7/A_Computer (L_8_bit is gone); first
  commit there b62ef6f = github/ from make_github.py of 2026-10-31 11:42.
- (2026-10-31) E.T. Phone Home! (.atr) went black for good on fire (both models). Cause: the .atr booted with BASIC on
  (the default without Alt+F4 = OPTION, as on a real XL); the disk copies a 16 KB cartridge to $8000-$BFFF, so the
  half at $A000-$BFFF fell under the BASIC ROM. The title runs from $8000-$9FFF; the game start calls $A000+ code.
  Found by tb_atari +define+TRIG_MS (new: joystick trigger press) with the image injected (BASIC off): the game
  starts normally. Hold Alt+F4 while pressing Enter on the .atr: E.T. works on hw (user). (The disk also has the cartridge's
  VCOUNT/WSYNC protection, bypassed by the crack; our ANTIC decodes it correctly: entry chain 1 -> 2 -> 3 -> $955A.)
- (2026-11-02) LTari .atr boot asks (user's idea): Enter on an .atr shows three OSD lines "How do you want to load it:
  <F1> No BASIC <F2> with BASIC" (Esc = back; Shift+Enter disk change is not asked). F1: MCTL[24] holds OPTION
  (LTari.v, synchronised into clk, ANDed into the console keys) through the cold start; the ESP32 releases it at the
  first SIO command frame (at most 5 s). .xex / .car are not asked (user: files that carry the choice stay as they
  are; the .xex loader switches BASIC off). LTari 6,936 LEs, LTari800 6,933 LEs, timing clean.
- (2026-11-02) Faster SD flash update (LUPDATE.BIN): the byte-wise FLASH register cost ~4 link frames per flash byte
  (~5 min first install). New link frame 08 FLS (esp_link parameter FLS, only the menu): each frame byte goes out on
  the flash, its answer comes back two bytes later; tape_loader FL_HALF 2 in the menu (DCLK 18.75 MHz, a byte shifts
  in ~0.45 us < the 1 us link byte). Menu core ID 4D4E_0002 = link version 2; the ESP32 streams only then (fl_stream
  in esp_hw.cpp; fl_read / fl_prog in flash.cpp), STAT before / after each frame, any error = byte-wise from then on.
  run_esp_link_sim.sh: menu + FLS at 75 MHz PASS (a 56 MHz / FL_HALF 4 run flags the error); update_test: first
  install 52 s modelled vs 300 s byte-wise, old menu and a broken stream fall back and finish. Machines unchanged
  (FLS = 0).
- (2026-11-02) Bluetooth across machine switches (user): leaving a machine restarted the ESP32 (core ID changed), which
  dropped the A2DP link (and a quick menu -> machine switch could then leave it unconnected). Now housekeeping
  longjmps back to loader_task, which resets the link state and every module (*_reset(), loader_reset_all() in
  main.cpp, src/reset.h) and probes again: no restart, the connection stays. KEY0 (same core, IRQ mask cleared)
  still restarts the ESP32. The FLS buffers had added 8.2 KB static RAM and chopped the audio again: now heap,
  menu only (76,996 B static). F3 in the machine menu: AMenu connects zx_keyboard's lkeys to tape_loader and
  BT_TX / BT_RX (AB17 / AA17); menu_text row 23 "F3: Bluetooth audio"; the ESP32's menu mode runs the same
  bt.cpp menu on the OSD (12,889 LEs, timing clean; AMenu sim fixed: link files + stubs, PASS).
  Short audio gaps: F3 shows "Gaps: data N late N max N ms" (I2S reads that came short / A2DP steps > 60 ms
  apart / longest step) to tell ESP32-side gaps from radio-side ones (no counter moves = radio). Not yet on hw.
- (2026-11-02) Bluetooth audio "jumped" (short skips forward, heard as a speed-up). The I2S input (APLL 44.1 kHz) and
  the A2DP stack's pull timer are different clocks: when the backlog in the 8 DMA buffers drifted up, the driver
  overwrote a buffer (~6 ms skip). esp32.ino now counts DMA buffers (on_recv / on_recv_q_ovf) and keeps the backlog
  at 512-1024 frames by dropping or repeating one frame per step (<= 0.2 %); F3 row 21 "Audio: short N skip N fix N",
  `status` shows the backlog. User: works. Why it showed only today (fine in the morning) is not known.
- (2026-11-02) After the update F12 was dead in a machine once (ESP32 reset over USB brought it back). Hardened the new
  menu-mode code: key_events ignores all-ones reads (FPGA reconfiguring), the menu loop stops as soon as the menu is
  left, bt_service stops on all-ones / after 512 bytes. Root cause not confirmed.
- (2026-11-02) User: everything above works on hardware (.atr prompt, fast SD update, F3 in the menu, Bluetooth kept across machine switches, audio drift fix).
- (2026-11-02) INSTALL/ in the public repo (user): for buyers of a ready board set (ESP32 programmed, machine menu in the
  FPGA) only LUPDATE.BIN and README.txt, plus the Installation Guide (SD card install/update, "Software not included":
  games, programs and the C64 ROMs come from elsewhere, with example archives and a copyright note) and the User Manual
  as PDF in nine languages (EN SP PT DE UA RU CN KR JP). Source: docs/manuals/build_manuals.py + lang_<code>.py (one
  content file per language, same block structure; English is the reference; on-screen texts stay English), HTML
  printed by headless Edge (Windows fonts: Segoe UI, Microsoft YaHei, Malgun Gothic, Yu Gothic), US Letter.
  make_github.py builds INSTALL/ from the public images, keeps github/.git, drops esp32.ino.map (Windows user path)
  and puts back files whose only change is line endings.
