# L — licences, own work, and how to build it

L is a set of 8-bit home computers on one FPGA board (QMTECH Cyclone IV EP4CE15 core board plus an I/O board
with an ESP32): a machine menu and three machines, **LSpectrum** (ZX Spectrum 128K), **L64** (Commodore 64 with
1541 drive) and **LTari** (Atari 800XL / 130XE). This document says what in the repository comes from elsewhere
and under which licence, what was written or changed for this project, and how to build and install everything.

Contents: [1 Licences](#1-licences) · [2 Own work and local changes](#2-own-work-and-local-changes) ·
[3 What is not in the repository](#3-what-is-not-in-the-repository) · [4 Building and installing](#4-building-and-installing) ·
[Appendix A](#appendix-a-notices-for-the-bitstreams)

---

## 1. Licences

The project's own files are under the **MIT licence** (`LICENSE`). The external parts keep their own licences,
listed below; their licence texts and copyright headers are kept in the files.

### 1.1 Summary

| Part | Used in | Licence | Changed here? |
|---|---|---|---|
| **T80** Z80 CPU | LSpectrum | BSD-style | no |
| **JT49** AY-3-8910 / 8912 | LSpectrum | **GPL-3 or later** | no |
| **T65** 6502 CPU | L64 (6510, 1541 CPU), LTari (6502C) | BSD-style | no |
| **VIC-II Kawari** | L64 (video chip) | **GPL-3** | small, marked `// L64:` |
| **SID** 6581 / 8580 | L64 (sound) | CERN-OHL-S v2 (`sid_dac`, `sid_filter`) + GPL-2 or later (rest) | no |
| **CIA** 6526 (`mos6526.v`) | L64 (2 CIAs) | GPL-2 or later (MiSTer C64 core) | small, marked `// L64:` |
| **VIA** 6522 (`iecdrv_via6522.vhd`) | L64 (1541 drive) | **GPL-3** | no |
| Intel FPGA IP (megafunctions) | all FPGA images | Intel FPGA software licence (Quartus) | generated from parameters |
| **Arduino-ESP32** core 3.3.2 + ESP-IDF | ESP32 firmware | LGPL-2.1 or later / Apache-2.0 | no (linked) |
| **ESP32-A2DP** 1.8.11 | ESP32 Bluetooth audio | Apache-2.0 | no (installed separately) |
| **Spleen 8x16** font | all on-screen text (menu and the machines' OSD) | BSD 2-Clause | no (converted to a ROM file) |
| ZX Spectrum 128K ROMs | LSpectrum | (c) Amstrad: redistribution for emulator use allowed | no |
| AltirraOS 3.11 + Altirra BASIC 1.59 | LTari | permissive notice (Avery Lee) | no |
| Commodore 64 + 1541 ROMs | L64 | (c) Commodore | **not included** (section 3) |
| Retroleum DiagROM | LSpectrum (F1) | not known | **not included** (section 3) |
| KiCad library footprints | I/O board (`Extra_PCB_CycloneIV.pretty/`: D-Sub 15 HD, pin headers) | CC-BY-SA 4.0 + KiCad library exception (the board design and its Gerbers are not bound) | adapted (CONNFLY DS1038 pins, rows swapped, keyboard module) |

**What GPL / CERN-OHL-S mean for the bitstreams:** the L64 image contains GPL-3 and CERN-OHL-S parts and the
LSpectrum image contains JT49 (GPL-3). Whoever passes on those `.sof` files or `L.jic` must make the complete
corresponding source available, which this repository is. The MIT files stay MIT; the combined images are
distributed under the terms of the strongest licence they contain.

### 1.2 FPGA cores

**T80 (Z80)** — `T80/`. From the MiSTer ZX Spectrum core (`rtl/T80`, commit `af0e6723`), copied unchanged
(`T80/SOURCE.md` has the SHA-256 of every file). Authors: Daniel Wallner, MikeJ, Sorgelig. BSD-style licence
(header of `T80.vhd`): source and synthesised redistribution allowed; the copyright notice must be kept in the
source and reproduced in the documentation of a bitstream distribution: the full notice is in
[Appendix A](#appendix-a-notices-for-the-bitstreams). Only `T80_Pack`, `T80_ALU`, `T80_MCode`, `T80_Reg` and `T80.vhd` are compiled; the wrapper `LSpectrum/rtl/cpu_t80.v`
is ours.

**JT49 (AY-3-8910 / 8912)** — `LSpectrum/rtl/jt49/`. By Jose Tejada Gomez (jotego), version 1.0. GPL-3 or later.
All 7 files, unchanged.

**T65 (6502)** — `T65/`. From the MiSTer Commodore 64 core (`rtl/t65`, commit `fe6dfe5`), T65(b) version 315,
copied unchanged (`T65/SOURCE.md`). Authors: Daniel Wallner, Mike Johnson, Wolfgang Scherr, Morten Leikvoll, SzGy.
BSD-style licence (header of `T65.vhd`; full notice in [Appendix A](#appendix-a-notices-for-the-bitstreams)). Used three times: the C64's 6510 (its I/O port at $00/$01 is ours, in
`c64_system.v`), the 1541's 6502 and the Atari's 6502C.

**VIC-II Kawari** — `L64/rtl/vicii/` (with `LICENSE` and `SOURCE.md`). By Randy Rossi,
github.com/randyrossi/vicii-kawari, commit `95ed201`, path `hdl/`. GPL-3. Only the plain VIC-II is built
(`config.vh`); Kawari's extensions, outputs and scan doubler are not.

**SID 6581 / 8580** — `L64/rtl/sid/` (`SOURCE.md`). From the MiSTer C64 core, commit `fe6dfe5`. `sid_dac.sv` and
`sid_filter.sv` (Dag Lem's reDIP-SID, Alexey Melnikov) are CERN-OHL-S v2; `sid_top.sv`, `sid_voice.sv`,
`sid_envelope.sv`, `sid_tables.sv` have no header and are part of the MiSTer C64 core, distributed under the GPL
(2 or later). Unchanged.

**CIA 6526** — `L64/rtl/cia/mos6526.v`. From the MiSTer C64 core, commit `fe6dfe5` ("by Rayne, timers and
interrupts rewritten by slingshot"). No header; GPL (2 or later) as part of that core.

**VIA 6522** — `L64/rtl/via/iecdrv_via6522.vhd`. By Gideon Zweijtzer, from the MiSTer C64 core
(`rtl/iec_drive/`, commit `fe6dfe5`). GPL-3. Unchanged.

**Intel FPGA IP** — `altpll`, `altclkctrl`, `altddio_out`, `altremote_update`, `cycloneive_asmiblock` and inferred
`altsyncram` block RAMs are generated by Quartus from parameters; no Intel source is copied into the repository.
They are covered by the Intel FPGA software licence that comes with Quartus Prime Lite.

**Spleen 8x16** — `AMenu/font/` (with its `LICENSE`). By Frederic Cambus, github.com/fcambus/spleen, version 2.1.0.
BSD 2-Clause. The menu's screens and the machines' on-screen displays use its ASCII characters (`AMenu/tools/mk_menufont.py` -> `AMenu/rtl/menu_font.hex`);
its notice for the bitstream is in [Appendix A](#appendix-a-notices-for-the-bitstreams).

### 1.3 ESP32 firmware libraries

| Library | Licence | Use |
|---|---|---|
| Arduino-ESP32 core 3.3.2 (Espressif) | core LGPL-2.1 or later; SD, Preferences, ESP-IDF Apache-2.0 | SPI (FPGA link, SD card), raw SD sectors (the FAT code is ours), Preferences, I2S, FreeRTOS, Bluedroid. Linked, not copied. |
| ESP32-A2DP 1.8.11 (Phil Schatzmann) | Apache-2.0 | The A2DP source (Bluetooth audio). Not in the repository: install it (section 4.4). |
| AAudioLinkFix (`LSpectrum/esp32/libraries/`) | ours (MIT) | A linker option that wraps one Bluetooth stack function (A2DP source crash fix); the stub archive carries no code. |

### 1.4 ROMs and data in the repository

- **ZX Spectrum 128K ROMs** (`LSpectrum/roms48k.hex`, `LSpectrum/sim/roms.mem`, inside `L.jic`): (c) Amstrad, who
  allow redistribution for emulator use with the copyright messages unchanged and not for sale.
- **AltirraOS 3.11 and Altirra BASIC 1.59** (`LTari/roms/`, inside `L.jic`): free replacement ROMs by Avery Lee,
  taken from the atari800 emulator's source. Licence (in both files): *"Copying and distribution of this file, with
  or without modification, are permitted in any medium without royalty provided the copyright notice and this
  notice are preserved. This file is offered as-is, without any warranty."*

---

## 2. Own work and local changes

### 2.1 Written for this project (MIT)

| Area | Files | What |
|---|---|---|
| I/O board | `Extra_PCB_CycloneIV/` | KiCad 10 project, revision 1 (ordered 2026-10-14): VGA DAC, two DB9, audio, keyboard module, microSD and ESP32 sockets; JLCPCB order files |
| Machine menu | `AMenu/` | Factory image at flash 0: menu screen, joystick / keyboard choice, remote update into a machine, error report after a failed start |
| SDRAM controller | `LSpectrum/rtl/sdram_ram.v`, `DDR_TEST/` | Byte / 16-bit RAM over the W9825G6KH at up to 112 MHz, open-row policy, refresh; tested on hardware (`DDR_TEST`, `docs/SDRAM_CONTROLLER.md`) |
| Shared infrastructure | `LSpectrum/rtl/` (`rom_loader`, `flash_if`, `tape_loader`, `esp_link`, `bt_i2s`, `sd_dac`, `vga_*`) | Flash ROM loader, ESP32 SPI link and register bus, on-screen display, Bluetooth audio I2S, sigma-delta audio, video clock switch |
| LSpectrum | `LSpectrum/rtl/zx_*.v`, `LSpectrum.v`, `cpu_t80.v` | The Spectrum 128K around T80 and JT49: bus with clock enables, paging, ULA video, contention, floating bus, keyboard, snapshot freeze |
| L64 | `L64/rtl/c64_*.v`, `c1541*.v`, `L64.v` | The C64 around the cores of 1.2: bus and PLA, 6510 port, frame buffer (VGA 800x600), keyboard, turbo, snapshot restore mode; the 1541 drive logic (address decode, serial bus, stepper, GCR encoder / decoder, track buffer) |
| LTari | `LTari/rtl/` | **ANTIC, GTIA, POKEY and the PIA written from scratch** from the Altirra Hardware Reference Manual (no other Atari FPGA core was looked at), MMU / banking, cartridges, SIO bridge to the ESP32, frame buffer, snapshots; only the CPU (T65) is external |
| ESP32 firmware | `LSpectrum/esp32/` | SD card browser, FAT16 / FAT32, TAP / TZX player and recorder, .z80 / .a64 / .a8s snapshots, C64 loaders and 1541 track service, C64 ROM installer, Atari disk drive (.atr, .xex / .com, .car), Bluetooth menu, screenshots |
| Tools, tests, docs | `*/tools/`, `*/sim/`, `tests/`, `docs/` | Image generators, testbenches and models, the user documentation |

### 2.2 Changes to external code

All external code is unchanged except these, each marked in the source with `// L64:`:

- **VIC-II Kawari:** the 14-bit VIC address, the half-cycle tick and the colour index per dot are brought out;
  an `ext_rst` input restarts its reset sequence; the character line buffer is read through a register so that
  it fits a block RAM; power-up values for simulation.
- **CIA `mos6526.v`:** four signals are declared before their first use (so that Questa accepts the file); an
  output `state` gives CRA, CRB and the interrupt mask for snapshots.

Synthesis settings only (no source change): JT49's volume table is kept in logic (ROM recognition off); the SID is
built with one filter curve set and one SID.

---

## 3. What is not in the repository

These are needed or useful but may not be published here. Get them yourself:

| What | Why | Where it is needed |
|---|---|---|
| **Commodore 64 ROMs**: KERNAL (8 KB), BASIC (8 KB), character ROM (4 KB), **1541 DOS** (16 KB) | (c) Commodore | L64. Put them on the SD card (section 4.5); the ESP32 installs them into the flash. VICE and other licensed emulator distributions include them. |
| **Retroleum DiagROM** (ZX Spectrum diagnostics, 16 KB) | licence not known | Optional: started with F1 at LSpectrum power-up. The published ROM image has a copy of the 48K BASIC ROM in that slot instead (section 4.2, step 2). |
| ESP32-A2DP library | separate project | ESP32 firmware build (section 4.4) |
| Datasheets and schematics | third-party documents | `docs/vendor/README.md` lists them and their publishers |
| Altirra Hardware Reference Manual | Avery Lee's document | Free download (Altirra / virtualdub.org); the reference LTari's chips are written from |
| Games, tapes, disk images | their authors' copyright | SD card |

The C64 files named exactly:

| File name on the card starts with | Size | Typical file (as in VICE) |
|---|---|---|
| `KERNAL` | 8,192 bytes | `kernal-901227-03.bin` |
| `BASIC` | 8,192 bytes | `basic-901226-01.bin` |
| `CHAR` | 4,096 bytes | `chargen-901225-01.bin` |
| `DOS1541` or `1541` | 16,384 bytes | `dos1541-325302-01+901229-05.bin` (without it, no disk drive) |

**Never publish a `.jic`, `.hex` or `.mem` that contains the C64 ROMs or DiagROM.** The tools that can make such
files for local tests (`L64/tools/mk_c64rom.py`, `LSpectrum/tools/mk_roms48k.py` with a DiagROM file) write into
git-ignored or local folders.

---

## 4. Building and installing

### 4.0 What goes where

| Place | Holds | How |
|---|---|---|
| Configuration flash on the core board (8 MB) | menu, the three machines, Spectrum and Atari ROMs; later the C64 ROMs | `AMenu/output_files/L.jic` over JTAG (USB-Blaster); C64 ROMs written by the ESP32 |
| ESP32 on the I/O board | SD card loader, on-screen menus, ROM installer, Bluetooth audio | Arduino sketch `LSpectrum/esp32`, uploaded over USB |
| microSD card | games, disks, snapshots, your C64 ROM files | copied on a PC |

Flash layout (`AMenu/L.cof`):

| Address | Contents |
|---|---|
| 0x000000 | AMenu, the machine menu (factory image, loaded at power-up) |
| 0x100000 | LSpectrum |
| 0x200000 | L64 |
| 0x300000 | LTari 800 (revision `LTari800`, 800XL, 64 KB) |
| 0x400000 | LTari 130 (revision `LTari`, 130XE, 128 KB) |
| 0x500000 | Spectrum ROMs, 48 KB (`LSpectrum/roms48k.hex`) |
| 0x540000 | Atari ROMs, 28 KB (`LTari/roms/atarirom.hex`) |
| 0x580000 | C64 ROMs, 48 KB — **not in the .jic**, written by the ESP32 from the SD card |

Each machine has a 1 MB slot (room for larger FPGAs' images).

Ready-made files: every `output_files/*.sof`, `AMenu/output_files/L.jic`, the SD card update
`AMenu/output_files/LUPDATE.BIN` and the loader `AMenu/output_files/L_loader.jic` are in the repository, so you can
program or update a board without building (go to 4.3 or 4.6).

### 4.1 Tools

| Tool | Notes |
|---|---|
| **Quartus Prime 25.1std Lite** (Windows) | Free; includes the Programmer and `quartus_cpf` |
| **USB-Blaster** | JTAG cable to the core board |
| **Arduino IDE** (or the `arduino-cli` it contains) | Core **esp32 3.3.2** by Espressif; board **ESP32 Dev Module**, default partition scheme |
| Python 3 | ROM image and test tools |
| Questa FSE (optional) | Intel's free simulator, for the testbenches in `*/sim/` |

### 4.2 The FPGA images and `L.jic`

1. Compile the five Quartus builds (GUI: open the `.qpf`, *Processing > Start Compilation*; or from a shell with
   Quartus' `bin64` on the PATH):

   ```
   cd AMenu     && quartus_sh --flow compile AMenu
   cd LSpectrum && quartus_sh --flow compile LSpectrum
   cd L64       && quartus_sh --flow compile L64
   cd LTari     && quartus_sh --flow compile LTari
   cd LTari     && quartus_sh --flow compile LTari -c LTari800
   ```

   Each makes `output_files/<name>.sof`. Check the Timing Analyzer summary: no negative slack (all designs are
   fully constrained; L64 is 97 % full and uses a fixed fitter seed in `L64.qsf`). Keep
   `STRATIXIII_UPDATE_MODE REMOTE` in the `.qsf` files, or the menu cannot start the machines.
2. (Optional) Your own DiagROM: put `zx128.rom` (32 KB, the two 128K ROMs) and your DiagROM file somewhere local and
   rebuild the Spectrum ROM image:

   ```
   cd LSpectrum
   python3 tools/mk_roms48k.py zx128.rom diagrom.rom roms48k.hex sim/roms.mem
   ```

   Without the DiagROM argument it writes the published version (48K BASIC in the F1 slot).
3. Assemble the one flash image:

   ```
   cd AMenu && quartus_cpf -c L.cof
   ```

   (GUI: *File > Convert Programming Files > Open Conversion Setup Data* `L.cof` > *Generate*.) The result is
   `AMenu/output_files/L.jic`; `L.map` lists the addresses.

### 4.3 Programming the board

1. Connect the USB-Blaster to the core board's JTAG header and power the board.
2. Quartus Programmer: Hardware Setup = USB-Blaster, mode **JTAG**, Add File `AMenu/output_files/L.jic`, tick
   **Program/Configure** and **Verify**, Start; wait for 100 %. Command line:

   ```
   quartus_pgm -c USB-Blaster -m JTAG -o "ipv;AMenu/output_files/L.jic"
   ```

3. Switch the board off and on: the machine menu appears. (Programming the `.jic` also erases the C64 ROMs in the
   flash; the ESP32 installs them again from the card at the next L64 start.)

### 4.4 The ESP32 firmware

1. Arduino IDE: install the **esp32** core 3.3.2 (Boards Manager). Copy the **ESP32-A2DP** library, release 1.8.11
   from github.com/pschatzmann/ESP32-A2DP, into the sketchbook's `libraries` folder (it is not in the Library
   Manager), and copy `LSpectrum/esp32/libraries/AAudioLinkFix` there too.
2. Connect the ESP32 board by USB and note its port.
3. Open `LSpectrum/esp32/esp32.ino`, board **ESP32 Dev Module**, Upload. Or from `LSpectrum/`:

   ```
   arduino-cli compile -b esp32:esp32:esp32 -u -p COMx esp32
   ```

The same firmware serves all machines; it recognises the running machine by its core ID on the SPI link.

### 4.5 The SD card

1. Format a microSD card **FAT32** (or FAT16). exFAT is not supported (most cards above 32 GB need reformatting).
2. For L64, make the folder **`/ROMS/C64/`** and copy the four Commodore ROM files of section 3 into it.
3. Put games anywhere, in folders (up to 320 entries per folder): Spectrum `.tap .tzx .z80`; C64
   `.d64 .prg .t64 .tap .a64`; Atari `.atr .xex .com .car .a8s`.

On the first L64 start the ESP32 shows "No ROMs in the flash yet", reads the four files, writes them into the flash,
verifies them and restarts the C64 — a few seconds. From then on L64 starts without the card.

### 4.6 Updating from the SD card (LUPDATE.BIN)

A board that has the machine menu (any `L.jic` or `L_loader.jic` from 30 October 2026 on) updates itself from the
card; no USB-Blaster is needed:

1. Copy `LUPDATE.BIN` to the **root folder** of the SD card and put the card in.
2. Switch the board on. While the machine menu is shown, the ESP32 finds the file, checks it (CRC-32 over the whole
   image) and writes the flash: only the 4 KB sectors that differ, the machines first and the menu last, each sector
   read back. The screen shows the progress; **do not switch off** (a few seconds for a small change, about 3-4
   minutes for a full install).
3. When everything checked out, the ESP32 deletes `LUPDATE.BIN`. If the menu itself changed, the screen asks to
   switch the board off and on; otherwise the menu comes back and the new machines start at once.

The C64 ROMs the ESP32 installed (flash 0x580000-0x5FFFFF) are never touched. A damaged file is rejected before
anything is written. If the power fails during the update, the file is still on the card and the update simply
runs again at the next start; only a power failure while the menu's own sectors are written (rare: only when the
menu changed) can leave a board that needs the USB-Blaster again.

Making the file (from `AMenu/`, after building the images, the same contents as `L.jic`):

```
python3 tools/mk_update.py --label "L 2026-10-30"     # -> output_files/LUPDATE.BIN
```

### 4.7 Boards shipped with the loader

`AMenu/output_files/L_loader.jic` (`python3 tools/mk_update.py --loader`) holds only the machine menu, followed by
blank data up to the end of the 8 MB flash: no machines, no ROMs. Program it as in 4.3. The blank part matters: the
Programmer erases only where a `.jic` has data (its Erase option did not clear old machines on hardware), so this
file wipes a used board completely, C64 ROMs included. Then install the ESP32 firmware (4.4); the board then shows **"No machines installed"**
until the user copies `LUPDATE.BIN` from this repository to the SD card (4.6). So a board can be passed on without
any ROM in it: the user gets the machines and the Spectrum / Atari ROMs from the public release, and supplies the
C64 ROMs as in 4.5.

### 4.8 Hardware

The I/O board (revision 1) is `Extra_PCB_CycloneIV/`: KiCad 10 project and the JLCPCB order files in `jlcpcb/`
(Gerber zip, BOM, CPL; J1, the ESP32 dev board and the keyboard module are fitted by hand). Its README has the
J1-to-U8 wiring (each pin pair swapped). The FPGA pin assignments are in each `.qsf`; `docs/BOARD_PINOUT.md` maps the core board's headers to FPGA pins and
describes the I/O board wiring (VGA, two DB9 joysticks, audio, keyboard UART, ESP32 link). `docs/L_Build_and_Install.docx`
and `docs/LSpectrum_Connection.docx` have the same steps and the wiring with pictures; the keys of each machine are
in `docs/LSpectrum_Keys.docx`, `docs/L64_Keys.docx` and `docs/LTari_Keys.docx`.

### 4.9 Check after installing

| Check | Expected |
|---|---|
| Power on | The menu: 1 LSpectrum, 2 L64, 3 LTari 800, 4 LTari 130 |
| 1 LSpectrum | The 128K menu; F12 opens the SD card browser |
| KEY1, then 2 L64 | First time the ROM install, then `38911 BASIC BYTES FREE` |
| Ctrl+Alt+Del, then 4 LTari 130 | "Altirra 8K BASIC 1.59", Ready |
| F8 in a machine | The picture switches between 60 Hz and 50 Hz |

---

## Appendix A: notices for the bitstreams

The LSpectrum, L64 and LTari bitstreams (`.sof`, `L.jic`) contain T80 or T65, and all images the Spleen font. Their
licences require these notices in the documentation of a synthesised / binary distribution. They are reproduced verbatim from the source headers.

### T80 (in LSpectrum), `T80/T80.vhd`

```
T80(c) core. Copyright (c) 2018 Sorgelig
T80(b) core, MikeJ March 2005
Z80 compatible microprocessor core, Version 0250
Copyright (c) 2001-2002 Daniel Wallner (jesus@opencores.org)
All rights reserved

Redistribution and use in source and synthezised forms, with or without
modification, are permitted provided that the following conditions are met:

Redistributions of source code must retain the above copyright notice,
this list of conditions and the following disclaimer.

Redistributions in synthesized form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the distribution.

Neither the name of the author nor the names of other contributors may
be used to endorse or promote products derived from this software without
specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
```

### T65 (in L64 and LTari), `T65/T65.vhd`

```
65xx compatible microprocessor core
Copyright (c) 2002...2015
              Daniel Wallner (jesus <at> opencores <dot> org)
              Mike Johnson   (mikej <at> fpgaarcade <dot> com)
              Wolfgang Scherr (WoS <at> pin4 <dot> at>
              Morten Leikvoll ()

All rights reserved

Redistribution and use in source and synthezised forms, with or without
modification, are permitted provided that the following conditions are met:

Redistributions of source code must retain the above copyright notice,
this list of conditions and the following disclaimer.

Redistributions in synthesized form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the distribution.

Neither the name of the author nor the names of other contributors may
be used to endorse or promote products derived from this software without
specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
```

### Spleen 8x16 (in the machine menu, AMenu), `AMenu/font/LICENSE`

```
Copyright (c) 2018-2024, Frederic Cambus
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

  * Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.

  * Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in the
    documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS
BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
```

The GPL-3, GPL-2 and CERN-OHL-S parts (JT49, VIC-II Kawari, the VIA, the SID, the CIA) have their licence texts and
headers in their source folders; the complete source of every bitstream is this repository.
