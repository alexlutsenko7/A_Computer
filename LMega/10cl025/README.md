# LMega — Sega Mega Drive / Genesis

The fifth machine of the L board, **for the QMTECH 10CL025 core board only**: it needs about 17,300 logic
elements and the EP4CE15 has 15,408. So there is no `ep4_ce15/` folder here; everything is in `10cl025/`.
It is not in `L.jic`: it is a machine file (`LMega_10cl025.LMC`) installed from the SD card's `MACHINES` folder
(F12 in the machine menu).

Unlike LTari and LNES this machine is built from existing open cores:

| Part | Core | Licence | Folder |
|---|---|---|---|
| 68000 | fx68k (Jorge Cwik) | GPL-3 | `../../FX68K` |
| Z80 | T80 | BSD-style | `../../T80` |
| YM2612 | jt12 (Jose Tejada) | GPL-3 | `../../JT12` |
| SN76489 | jt89 (Jose Tejada) | GPL-3 | `../../JT89` |
| VDP | MiSTer Genesis core (Estrade, Harbaum, Melnikov, Szombathelyi) | BSD-style | `rtl/genesis` |

Each folder has a `SOURCE.md` (origin, commit, licence, checksums); the copies are unchanged. Ours are the machine's
bus logic (`rtl/md_system.sv`, which follows the MiSTer core's `system.sv` and carries its notice), the memory
(`rtl/md_mem.v`), the controller ports, the video output and the board top level.

A game is a cartridge file that the ESP32 writes into the SDRAM (`../../ESP32/vN/src/md.cpp`); the console has no
system ROM.

## Status (2026-11-17)

Built: 17,335 logic elements (70 %), timing met (worst setup +1.1 ns in the 107.4 MHz domain, +2.75 ns in the
53.7 MHz domain). **First run on hardware 2026-11-18** (with I/O board revision 2): works at first glance, more testing to come. Simulation: `sim/run_sim.sh` (a small test cartridge: VDP setup, a tile
on plane A, RAM check); result in `../../docs/PLAN.md`.

- **Memory:** cartridge ROM up to 4 MB, the 68000's 64 KB RAM, the VDP's 64 KB video RAM and 64 KB of cartridge
  RAM are all in the SDRAM (`rtl/md_mem.v`); the Z80's 8 KB RAM is block RAM.
- **Files:** `.md`, `.gen`, `.bin` (the plain ROM) and `.smd` (interleaved 16 KB blocks, slower to load).
- **Region:** from the cartridge's header: America if the game runs there, else Europe (50 Hz), else Japan.
  The console is always a 60 Hz one after power-up; F8 steps a game for Europe only through its three video
  modes (see Keys).
- **Battery RAM:** as LNES: `NAMEhhhh.SAV` beside the game, for a cartridge whose header declares RAM.
- **Video:** a line doubler (`rtl/md_video.v`): every line of the VDP is shown twice, so the monitor gets
  640 x 480 at the console's own frame rate and scrolling is smooth. The output counts 800 pixel times per line
  with a fraction counter, so the 320 pixels of a line fill exactly 640 monitor pixels (sharp); in the VDP's
  256-pixel mode a pixel is 2 or 3 monitor pixels wide. No Print Screen.
  The monitor's vertical sync changes only where a VDP line starts, so a frame has 524 lines (626 at 50 Hz) also
  while a game uses an interlace mode, in which the VDP delays every second field's sync by half a line.
- **50 Hz game on a 60 Hz screen (third F8 mode):** `rtl/md_fb.v` stores the VDP's pictures in the SDRAM (three
  buffers of 320 x 240 words at 0x500000) and `md_video.v` makes a standard 640 x 480 @ 60 Hz frame from the
  newest complete one. The screen side reads the SDRAM in runs of 8 words; for that LMega has its own
  copy of the SDRAM controller, `rtl/md_sdram.v` (the shared one must not change: the other machines' images).
- **Sound:** FM and PSG mixed to one channel.
- **Not done:** 6-button pads, games larger than 4 MB (bank switching), serial EEPROM saves, cartridge
  processors (Virtua Racing), the interlaced double-resolution mode's field offset, Master System mode, snapshots.

## Controllers

The joystick gives the four directions and one button (B); the other buttons are keys.

| Button | Pad 1 | Pad 2 |
|---|---|---|
| Up, Down, Left, Right | DB9-1 | DB9-2 |
| B | DB9-1 button; also Tab | DB9-2 button; also `R` |
| A | `Z` or left Ctrl | `F` |
| C | `X` or Space | `G` |
| Start | Enter | `T` |

F4 opens the joystick menu: which DB9 port is pad 1.

## Keys

| Key | Function |
|---|---|
| F12 | the list of games; Enter loads one and starts it. The list opens by itself when the machine starts |
| Alt+F5 | the console's Reset button |
| F8 | video mode of a game made for Europe only, step by step: **60 Hz console** (after power-up; the game runs 17 % fast, a few games refuse) -> **its 50 Hz console, 50 Hz on the screen** (right speed, smooth) -> **its 50 Hz console, 60 Hz on the screen** (right speed; the picture goes through a frame buffer and every fifth screen frame is a repeat) -> back to the first. Games for America or Japan: always 60 Hz, F8 does nothing |
| F3 / F4 | Bluetooth audio menu / joystick menu |
| Ctrl+Alt+Del, KEY1 | back to the machine menu |
| KEY0 | reset everything (the ESP32 restarts; load the game again) |

## Build

```
cd LMega/10cl025
quartus_sh --flow compile LMega
cd ../../AMenu/10cl025 && python3 ../ep4_ce15/tools/mk_flash.py     # output_files/machines/LMega_10cl025.LMC
```

`LMega.qsf` is written by hand (the other 10cl025 projects are generated from their ep4_ce15 ones); its pins are
theirs.

## Files

| Path | Role |
|---|---|
| `LMega.qpf/.qsf/.sdc` | Quartus project (top `LMega`) |
| `rtl/LMega.v` | board top level: PLL, resets, remote update (KEY1), keyboard, controllers, audio, tape loader + ESP32 link, memory commands, video |
| `rtl/md_system.sv` | the machine: 68000, Z80, VDP, sound chips, the main bus and the Z80's bus, controller ports |
| `rtl/md_sdram.v` | the shared SDRAM controller with run reads added (a copy, see its header) |
| `rtl/md_mem.v` | SDRAM: ROM, RAM, video RAM, cartridge RAM; arbiter between the VDP, the bus and the ESP32 |
| `rtl/md_video.v` | line doubler with the fraction pixel counter, the 60 Hz frame of the frame buffer mode, OSD |
| `rtl/md_fb.v` | frame buffer of the third video mode: writer, FIFO, line fetch |
| `rtl/md_pll.v` | 53.693 MHz (the console's master clock) and 107.386 MHz |
| `rtl/genesis/` | the VDP (unchanged copy), `SOURCE.md` |
| `sim/run_sim.sh`, `sim/tb_md.sv`, `sim/mk_testrom.py` | smoke test (Questa): a small 68000 test cartridge |
| `sim/run_video_sim.sh [+define+INTERLACE]`, `sim/run_fb_sim.sh` | the video output alone (also with an interlaced VDP's delayed vertical sync), and the frame buffer mode with the SDRAM model, against a made-up VDP timing |
