# LNext — ZX Spectrum Next

The seventh machine of the L board, **for the QMTECH 10CL025 core board only** (about 18,700 logic elements; the
EP4CE15 has 15,408). So there is no `ep4_ce15/` folder here; everything is in `10cl025/`.
It is not in `L.jic`: it is a machine file (`LNext_10cl025.LMC`) installed from the SD card's `MACHINES` folder
(F12 in the machine menu).

The machine is the open Spectrum Next core in its MiSTer port, as an unchanged copy:

| Part | Core | Licence | Folder |
|---|---|---|---|
| The whole machine: Z80N, ULA, Layer 2, sprites, tilemap, copper, DMA, CTC, three AY chips, DACs, DivMMC, Multiface, UARTs | ZX Spectrum Next core (Albrecht, Trucco, Belavenuto), MiSTer port (Melnikov) | GPL-3 | `../../ZXNEXT/rtl` |
| SD card made of logic | MiSTer framework (Harbaum, Sorgelig) | LGPL-3 | `../../ZXNEXT/sys/sd_card.sv` |

`../../ZXNEXT/SOURCE.md` has the origin, the commit and the checksums. Ours are the memories for this FPGA
(`rtl/next_bram.vhd`), the SDRAM controller (`rtl/next_sdram.v`, the MiSTer port's cycle scheme written for our
pins), the SD card's link to the ESP32 (`rtl/next_sd.v`), the keyboard, the video output and the board top level.

## How it starts

A Spectrum Next has no ROMs of its own: a small boot ROM inside the core loads the firmware `TBBLUE.FW` from the
SD card, which loads the ROMs and NextZXOS from the card too. So **the card must hold the Spectrum Next
distribution** (https://www.specnext.com/latestdistro/): `TBBLUE.FW`, the `machines` and `nextzxos` folders and
the rest, copied as they come **into a folder `ZXNEXT` in the root of the card** (FAT32). They are not part of
this project and are not in the repository.

The Next looks for its files in the root directory, so the ESP32 shows it the folder as the root: FAT32 names
the root directory's first cluster in its boot sector, and that one number is changed on the way to the machine
(`../../ESP32/vN/src/next.cpp`). The Next's `C:/` is the folder; it cannot reach the other machines' files, and
on a PC the card is an ordinary one with an ordinary folder. A card without the folder is given as it is (the
distribution in the card's root, FAT16 too).

On this board the card is on the ESP32, not on the FPGA. The core talks SPI to an SD card made of logic and the
ESP32 moves the 512-byte sectors between it and the real card (`../../ESP32/vN/src/next.cpp`): the card's sectors go to the Next as they are, read and write, except what makes the folder its root. The machine is held in reset until the ESP32 has found the card.
While a sector is on its way the Next's CPU waits (`rtl/next_sd.v`): the link takes milliseconds where a real
card port answers at once, and the core must not send its next command meanwhile.

## Status (2026-11-19)

Built for the 10CL025: 18,347 logic elements (75 %), all 66 block RAMs, timing met (setup + 0.53 ns in the
112 MHz domain, worst slack of all corners + 0.08 ns). **First run on hardware 2026-11-19** (the 10CL025 with the rev 2 I/O board; the
bitstream loaded over JTAG, not yet installed from a machine file):

- From a complete distribution (a disk image served by the PC, see Tests): the firmware's video test, the
  settings written to the card, NextZXOS 2.09 to its menu (1792K), the Browser, the Guide (80-column tilemap),
  a `.nex` Layer 2 picture (320 x 256), the game Spectron 2084 (sprites, Layer 2; 25 minutes of its attract
  mode without a fault).
- 2026-11-20, the distribution in the folder `ZXNEXT` (the same image with everything moved into the folder):
  video test, settings written, NextZXOS to its menu, the Browser shows the folder's contents as `C:/`.
- From the user's card (the real path: card on the ESP32): the boot ROM and `TBBLUE.FW` started and stopped at
  "Error opening 'menu.ini/.def'" (2026-11-19: the card held `TBBLUE.FW` only). Not run again with a complete
  folder yet.
- Not tested: the USB keyboard on this machine (the keys came over JTAG; `rtl/next_keyboard.v` passes its
  simulation), joysticks, sound, the picture on a monitor (it was read over JTAG), the start from the flash
  (machine file, back to the menu), F3 Bluetooth menu, the 28 MHz CPU speed in programs.

Open points are in `../../docs/PLAN.md`.

- **Memory:** the Next's 2 MB are in the SDRAM (`rtl/next_sdram.v`, 112 MHz = 4 x the machine's 28 MHz). The
  CPU's port has wait states at 14 and 28 MHz (as on MiSTer); Layer 2 has its own port.
- **Block RAM:** the machine needs every block the FPGA has (66). The core was written for an FPGA with small
  asynchronous memories, which the Cyclone 10 LP does not have: `rtl/next_bram.vhd` makes them from block RAM
  read on the opposite clock edge. To fit, the five sprite attribute memories are one (`rtl/next_sprites.vhd`),
  the boot ROM is three block ROMs of 4, 2 and 1 KB with its last kilobyte in logic (`rtl/next_bootrom.vhd`;
  both files are made from the unchanged ones by `tools/mk_c10_files.py`), the video output has one line buffer, and the loader is a copy of the shared
  one without the tape player's command memory (`rtl/next_loader.v`).
- **Video:** a line doubler (`rtl/next_video.v`): the core's 15 kHz picture, every line twice at 28 MHz, at the
  machine's own frame rate. Measured in the Next's own timing: 912 pixel times per line = 30.70 kHz, 622 lines
  = 49.36 Hz or 528 lines = 58.15 Hz. Whether a given monitor takes these is not tested; the real Next has
  slightly faster master clocks to choose from for this reason (its VGA modes 1 to 6), which are not built
  here: the firmware's video test shows the same picture for all of them. 3 bits per colour.
- **Sound:** both channels mixed to one, on the audio jack and over Bluetooth.
- **Clocks:** two PLLs. The first makes the machine's 28 / 14 / 7 MHz and the SDRAM's 112 MHz; the second makes
  56 MHz for the loader with the ESP32 link and the keyboard, which is treated as asynchronous to the machine.
- **Not there:** HDMI, the Raspberry Pi port, the expansion bus, the mouse, the real-time clock, the Wi-Fi
  module (the core's UARTs are not connected), tape loading through the ESP32 (the Next loads its files from
  the card itself), Print Screen, core updates from NextZXOS.

## Keys

The PC keyboard is the Next's keyboard as on the MiSTer port (letters, digits, cursor keys, Backspace,
punctuation ...; the core maps them onto the Spectrum's matrix).

| Key | Function |
|---|---|
| F1 | hard reset: the machine starts again from the card |
| F4 | soft reset |
| F6 | CPU speed: 3.5 -> 7 -> 14 -> 28 MHz |
| F8 | 50 / 60 Hz |
| F9 | the Multiface button (NMI): NextZXOS's NMI menu |
| F10 | the Drive button (DivMMC NMI) |
| F3 | Bluetooth audio menu (ESP32) |
| Ctrl+Alt+Del, KEY1 | back to the machine menu |
| KEY0 | reset everything (the ESP32 restarts, the Next starts again from the card) |

Joysticks: DB9-1 is the Next's left joystick, DB9-2 its right one (directions and one button); their type
(Kempston, Sinclair, cursor ...) is chosen in NextZXOS.

The DB9 ports carry one button (the Next's button B, fire). Three more buttons of each joystick are keys, which
the Next does not get as keyboard keys:

| Key | Joystick | Button |
|---|---|---|
| Insert / Home / Page Up | left (DB9-1) | C (Kempston fire 2) / A (fire 3) / Start |
| Delete / End / Page Down | right (DB9-2) | C (Kempston fire 2) / A (fire 3) / Start |

## Tests

- `sim/run_kbd_sim.sh`: `rtl/next_keyboard.v` alone (Questa): keyboard reports in, key events out. PASS.
- `sim/run_video_sim.sh`: `rtl/next_video.v` alone with a made-up picture in the Next's timing and the OSD on:
  622 lines of 912 pixel times, every line twice, the OSD in the middle (`sim/video.png`). PASS.
- `../../ESP32_test/vN/test/next_test.cpp` (in `run_host_test.sh`): the firmware's sector server against a model
  of the FPGA's card port, and a FAT32 card image with the folder `ZXNEXT` read as a machine would. PASS.
- On the board without a keyboard and monitor: `../../tests/jtag_rig` (`setup_next.py` builds a scratch copy of
  this project with the rig; `keys.tcl` presses keys, `stp.sh grab` reads the picture).
- Without a distribution on the card: the firmware's test option `NEXT_SERIAL_CARD`
  (`../../ESP32/vN/src/pccard.h`) takes the card's sectors from a disk image on the PC
  (`../../ESP32_test/v2/tools/next_pccard.py`); the real card is not touched. Never in a product build.

## Build

```
cd LNext/10cl025
python3 tools/mk_c10_files.py          # only after ZXNEXT/ changed: rtl/next_sprites.vhd, rtl/next_bootrom.vhd
quartus_sh --flow compile LNext
cd ../../AMenu/10cl025 && python3 ../ep4_ce15/tools/mk_flash.py     # output_files/machines/LNext_10cl025.LMC
```

`LNext.qsf` is written by hand (as LMega's); its pins are those of the generated 10cl025 projects.

## Files

| Path | Role |
|---|---|
| `LNext.qpf/.qsf/.sdc` | Quartus project (top `LNext`) |
| `rtl/LNext.v` | board top level: PLLs, resets, remote update (KEY1), keyboard, joysticks, the core, SDRAM, SD card, audio, loader + ESP32 link, video |
| `rtl/next_sdram.v` | SDRAM controller: the CPU's port with wait, Layer 2's port, bursts of two words kept for the next reads |
| `rtl/next_sd.v` | the SD card of logic and the ESP32's side of it (machine word, memory commands) |
| `rtl/next_bram.vhd` | the core's memories for the Cyclone 10 LP |
| `rtl/next_keyboard.v` | USB keyboard reports -> key events (PS/2 codes) for the core, loader keys |
| `rtl/next_video.v` | line doubler with one line buffer, OSD |
| `rtl/next_loader.v` | copy of the shared tape loader with a 16-command pulse memory in registers |
| `rtl/next_pll.v`, `rtl/next_pll2.v` | the two PLLs |
| `rtl/next_sprites.vhd`, `rtl/next_bootrom.vhd`, `rtl/next_bootrom_*.mif` | made by `tools/mk_c10_files.py` from the files in `ZXNEXT/` |
| `sim/run_kbd_sim.sh`, `sim/run_video_sim.sh` (+ `tb_next_keyboard.sv`, `tb_next_video.sv`) | the keyboard test and the video output test |
