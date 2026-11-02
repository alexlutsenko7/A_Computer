# L

Retro computers in an FPGA: an Intel/Altera Cyclone IV E (EP4CE15F23C8) on a QMTECH core board, with the RAM and
ROMs in the board's SDRAM, VGA output, a USB keyboard and an ESP32 system controller (SD card loader, on-screen
menus, Bluetooth audio). A machine menu at power-up chooses the machine:

- **LSpectrum**, a ZX Spectrum 128K with a built-in SD card tape loader that plays unmodified `.tap` / `.tzx` files,
  saves programs back to the card, and saves / loads `.z80` snapshots;
- **L64**, a Commodore 64 (PAL) with a 1541 disk drive that reads and writes `.d64` images, `.prg` / `.t64`
  loading, C64 `.tap` tapes, turbo loading and `.a64` snapshots;
- **LTari**, an Atari 800XL (**LTari 800**, 64 KB) or 130XE (**LTari 130**, 128 KB) with its own ANTIC, GTIA, POKEY
  and PIA, an SD card disk drive (`.atr`), `.xex` / `.com` programs, cartridges (`.car`) and `.a8s` snapshots.

Status (October 2026): the menu, LSpectrum, L64 and LTari work on hardware.

**Licences, what is our own work, and the complete build guide (including the C64 ROM files you have to get
yourself): [BUILDING_AND_LICENSES.md](BUILDING_AND_LICENSES.md).**

## Features

- **ZX Spectrum 128K**: T80 Z80 core at the exact 3.5469 MHz, or 28 MHz turbo; 128 KB RAM with 7FFD paging; 128K
  ROM set and DiagROM; AY-3-8912 (JT49); beeper; Kempston joystick; 50 Hz interrupt; memory contention (128K
  timing, memory and I/O cycles; not cycle-exact) and the floating bus, so most timing-critical games and border
  effects run as on the real machine.
- **Memory in SDRAM**: own 112 MHz controller for the W9825G6KH (open-row, CAS latency 2); the CPU is stepped by a
  clock enable and simply waits when the SDRAM is busy. The screen is mirrored in block RAM for the video.
- **Video**: VGA 720x576@50 (576p) or 640x480@60, 2 bits per colour, switchable at run time.
- **USB keyboard** through a CH9350-style UART module, with machine keys: DiagROM, 50/60 Hz, reset.
- **SD card tape loader** on an ESP32 system controller (firmware in C, SPI link to the FPGA):
  - on-screen browser (folders, long names, up to 320 entries), FAT16 / FAT32;
  - plays TAP and TZX (incl. turbo blocks, pure tones, pulse sequences, direct recordings, loops, jumps, calls,
    stop blocks) T-state exact, in turbo (8x) or at normal speed;
  - saves: everything the Spectrum `SAVE`s goes into a `.tap` file on the card;
  - pause, back one block, stop;
  - **snapshots**: F2 saves the whole machine as a `.z80` (version 3, 128K) at any moment; the browser loads
    `.z80` files (versions 1-3, 48K and 128K).
- **Bluetooth audio**: the same ESP32-WROOM-32 (`LSpectrum/esp32/`, Arduino) takes the sound as I2S and sends it to Bluetooth
  speakers / headphones (A2DP), including old PIN-only devices; F3 opens the on-screen Bluetooth menu.
- **L64** (`L64/README.md`): VIC-II Kawari, T65 as 6510, the MiSTer SID 6581/8580 and CIAs, our bus, PLA
  and 1541 drive (T65, two VIAs, GCR on the fly from a track buffer the ESP32 fills from the `.d64`). The
  picture goes through a frame buffer in SDRAM: 800x600 at 60 Hz, or the C64's own 50 Hz (F8). Turbo loading (F6):
  CPU, CIAs and 1541 up to 4x while a motor runs. F2 snapshots (`.a64`). The C64 ROMs are not part of the project:
  the ESP32 installs your own ROM files from the SD card into the flash.
- **Machine menu** (`AMenu/`): the factory image at flash 0 starts a machine through the Cyclone IV remote update
  block; KEY1 in a machine returns to it.
- **Fully constrained timing**: every clock and I/O constrained, timing met at all corners.

## Hardware

| Part | Notes |
|---|---|
| QMTECH Cyclone IV core board | EP4CE15F23C8N, 50 MHz oscillator, W9825G6KH-6 SDRAM (32 MB), W25Q64 configuration flash |
| I/O board (own design, `Extra_PCB_CycloneIV/`) | 4-bit-per-colour VGA DAC, two Kempston DB9, 3.5 mm audio jack (AY + beeper, line level), USB keyboard module (UART, 3.3 V), microSD socket, sockets for the ESP32; wired to the core board's U8 |
| ESP32-WROOM-32 dev board | system controller on the I/O board: SD card, tape loader, Bluetooth audio (`LSpectrum/esp32/README.md`) |

Pin assignments: `docs/BOARD_PINOUT.md`.

## Repository layout

| Folder | Contents |
|---|---|
| `AMenu/` | machine menu shown at power-up (factory image); `L.cof` -> `output_files/L.jic`, the ready-to-program image with all machines |
| `LSpectrum/` | **The Spectrum**: Quartus project, `rtl/` (Verilog), `esp32/` (ESP32 firmware for both machines: loader + Bluetooth), `sim/` (Questa testbenches) |
| `L64/` | **The Commodore 64**: Quartus project, `rtl/` (our bus, 1541, video; Kawari VIC-II, SID, CIA, VIA), `sim/`, `tools/` (ROM image, test disk) |
| `T65/` | 6502 core (VHDL), from the MiSTer C64 core, unchanged (`T65/SOURCE.md`) |
| `tests/` | hardware test tools: `Test_wires/` (ESP32 <-> FPGA wiring), `ESPLinkTest/` (SPI link), `t80_fmax/` |
| `T80/` | Z80 core (VHDL), from the MiSTer ZX Spectrum core, unchanged (`T80/SOURCE.md`) |
| `DDR_TEST/` | stand-alone SDRAM controller + memory test (the controller used by LSpectrum) |
| `VGA_TEST/` | stand-alone VGA test (colour bars, both video modes) |
| `Extra_PCB_CycloneIV/` | **the I/O board, revision 1**: KiCad 10 project (schematic + PDF, routed 2-layer layout, project symbols / footprints), JLCPCB order files (`jlcpcb/`: Gerbers, drill, BOM, CPL), wiring to the core board (`README.md`) |
| `docs/` | design notes, user documents, data sheets (see below) |

## Building

Step by step, from the tools to the SD card: [BUILDING_AND_LICENSES.md](BUILDING_AND_LICENSES.md), section 4.
Tools: Quartus Prime 25.1std Lite (Windows) for the FPGA; Arduino (core esp32 3.3.2, `arduino-cli`) for the ESP32
(libraries: `LSpectrum/esp32/README.md`). The scripts are written for WSL on Windows and call the Windows tools;
paths are at the top of each script.

```
cd LSpectrum
quartus_sh --flow compile LSpectrum              # -> output_files/LSpectrum.sof
cd ../L64
quartus_sh --flow compile L64                # -> output_files/L64.sof
cd ../AMenu
quartus_sh --flow compile AMenu                  # machine menu
quartus_cpf -c L.cof                      # -> output_files/L.jic (menu + machines + ROMs)
cd ../LSpectrum
arduino-cli compile -b esp32:esp32:esp32 -u -p COM10 esp32       # ESP32 firmware (loader + Bluetooth)
```

Flash layout (1 MB per image): menu at 0, LSpectrum at 0x100000, L64 at 0x200000, LTari 800 at 0x300000, LTari 130 at
0x400000, the Spectrum ROMs (`roms48k.hex`) at 0x500000, the Atari ROMs at 0x540000, the C64 ROMs (installed by the
ESP32) at 0x580000; ROMs are copied into SDRAM at every reset.
A change in `LSpectrum/esp32/` needs only the ESP32 flashed again; a change in `LSpectrum/rtl/` a new compile.

## Programming

Quartus Programmer, JTAG, add `AMenu/output_files/L.jic`, tick Program/Configure, program, then
power-cycle the board. After that, `.sof` loads over JTAG are enough during development (the ROMs stay in the flash).

## Using it

The keys below are LSpectrum's; L64's (mostly the same F keys) are in `docs/L64_Keys.docx` and `L64/README.md`.

| Key | Function |
|---|---|
| F12 | tape browser (Enter plays a tape / loads a `.z80` snapshot; first line *[Save to this folder]* starts saving) |
| F2 | save a snapshot: type a name, Enter (`NAME.Z80` in the browser's current folder) |
| F12 while saving | stop saving and close the file |
| Keypad 5 / F11 | pause / continue the tape |
| Keypad - | back one block |
| F7 | stop the tape |
| F5 | memory contention and floating bus on (default) / off |
| F6 | tape speed: turbo (default) / normal |
| F8 | 60 / 50 Hz video (starts at 640x480@60; border effects line up only at 50 Hz) |
| Page Up / Page Down | browser open: page through the list; closed: move the 50 Hz frame interrupt 1/8 line to line up border effects (default 24.1, set for Aquaplane) |
| F1 held at start | the diagnostics ROM slot instead of the 128K ROM (the public image has 48K BASIC there; add DiagROM yourself with `LSpectrum/tools/mk_roms48k.py`) |
| KEY0 (board) | reset everything |
| Ctrl+Alt+Del, KEY1 (board) | back to the machine menu (Ctrl+Alt+Del when released) |

Loading: `LOAD ""` (or *Tape Loader* in the 128K menu), F12, choose the file, Enter.
Saving: F12, *[Save to this folder]*, type a name, Enter, then `SAVE` on the Spectrum as often as you like; F12 ends.
Snapshot: F2 at any moment, type a name, Enter; load it later from the F12 browser.
SD card: FAT32 or FAT16 (not exFAT).

At power-up the machine menu (`AMenu/`) appears: Up/Down + Enter, the digit, or a joystick starts a machine.

The complete key list with step-by-step usage is in `docs/LSpectrum_Keys.docx`.

## Testing

```
bash LSpectrum/esp32/test/run_host_test.sh       # PC: FAT reading/writing, every TAP/TZX signal vs a Python reference, saving, .z80
bash LSpectrum/sim/run_esp_link_sim.sh           # RTL: loader hardware driven over the SPI link by an ESP32 model
bash LSpectrum/sim/run_sim.sh                    # RTL: whole machine boots the 128K ROM
bash LSpectrum/sim/run_snap_sim.sh               # RTL: snapshot freeze / restore with the real T80
bash LSpectrum/sim/run_cont_sim.sh               # RTL: memory contention (NOPs per line in contended RAM: 57 / 41)
bash LSpectrum/sim/run_float_sim.sh              # RTL: floating bus (IN A,(FF) against Fuse's 128K rule)
bash LSpectrum/sim/run_floatgame_sim.sh          # RTL: a .z80 game's floating-bus sync vs Fuse (default Sidewize)
bash AMenu/sim/run_sim.sh                        # RTL: machine menu with a model of the remote update block
bash L64/sim/run_sim.sh ROMIMAGE.mem         # RTL: whole C64 boots to READY (your own ROM image); +define+DISK: 1541 directory
bash L64/sim/run_gcr_sim.sh                  # RTL: 1541 GCR encoder / decoder
```

The PC tests need a Windows gcc (w64devkit); the simulations need Questa (Intel FPGA Starter Edition).

## Documentation

| Document | Contents |
|---|---|
| `docs/LSpectrum_Architecture.docx` | architecture of the whole machine: block diagram, clocks, memory, video, tape loader, pins, timing |
| `docs/LSpectrum_Keys.docx` | all keys and usage cases |
| `docs/LSpectrum_FKeys.docx` | short sheet of the F keys |
| `docs/L_Build_and_Install.docx` | step by step: building the three FPGA images, the one .jic, programming, the ESP32, the SD card and its ROM files, how the ROMs are used |
| `docs/L64_Keys.docx` | the machine menu and L64: all keys, the C64 keyboard layout, usage cases (ROMs, disk, tape, snapshots, 60 / 50 Hz) |
| `docs/SD_TAPE_LOADER.md` | SD tape loader: design, registers, firmware, saving, snapshots |
| `docs/SDRAM_CONTROLLER.md`, `docs/SDRAM_TUTORIAL.md` | the SDRAM controller in detail, and an SDRAM tutorial |
| `docs/T80_CEN_ANALYSIS.md` | running the T80 from a clock enable at 112 MHz |
| `docs/BOARD_PINOUT.md` | core board headers and the I/O board wiring |
| `docs/KNOWN_ISSUES.md` | open issues and limitations |
| `docs/L_Third_Party.docx` | every external core and library: origin, licence, how much of it is used |
| `docs/PLAN.md` | design decisions and development log |

## Licences

The project's own files are under the MIT licence (`LICENSE`). Third-party parts keep their own licences:

| Part | Licence |
|---|---|
| `T80/` (Z80 core, Daniel Wallner; Sorgelig) | BSD-style, see the file headers |
| `T65/` (6502 core, Daniel Wallner et al.) | BSD-style, see the file headers |
| `LSpectrum/rtl/jt49/` (AY-3-8910 core, Jose Tejada) | **GPL-3**: a bitstream that includes it is a GPL-3 work |
| `L64/rtl/vicii/` (VIC-II Kawari, Randy Rossi) | **GPL-3** |
| `L64/rtl/via/` (VIA 6522, Gideon Zweijtzer) | **GPL-3** |
| `L64/rtl/sid/`, `L64/rtl/cia/` (MiSTer C64 core) | CERN-OHL-S v2 (`sid_dac.sv`, `sid_filter.sv`) and GPL (the MiSTer C64 core) |
| `LSpectrum/esp32/` uses ESP32-A2DP (Phil Schatzmann) | Apache-2.0 (library, not included) |
| ROM images in `LSpectrum/roms48k.hex` and `LSpectrum/sim/roms.mem` | ZX Spectrum 128 ROMs (c) Amstrad, distributed for emulator use with permission, copyright messages unchanged. Retroleum's DiagROM is not included (its licence is not known): the published image has a copy of the 48K BASIC ROM in that slot; `LSpectrum/tools/mk_roms48k.py` builds the image with your own copy |
| `LTari/roms/` (AltirraOS, Altirra BASIC, Avery Lee) | permissive notice: copying and distribution permitted, notice preserved |
| Commodore 64 / 1541 ROMs | **not included**: copyrighted; bring your own (`L64/README.md`) |
| `Extra_PCB_CycloneIV/Extra_PCB_CycloneIV.pretty/`: footprints adapted from the KiCad libraries (D-Sub 15 HD, pin headers) | CC-BY-SA 4.0 with the KiCad library exception (designs made with them, the board files and Gerbers included, are not bound by it); the rest of the board is MIT |

Because of the GPL-3 parts, the LSpectrum and L64 bitstreams (and `L.jic`) are GPL-3 works. Details, the
notices the BSD-style cores require, and what was changed in external code: [BUILDING_AND_LICENSES.md](BUILDING_AND_LICENSES.md);
how much of each part is used: `docs/L_Third_Party.docx`.
