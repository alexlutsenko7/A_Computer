# LNES — Nintendo Entertainment System (NTSC)

The fourth machine of the L board. It exists for both core boards (`ep4_ce15/` holds the sources, `../10cl025/`
the second board's project). It is not in `L.jic`: it is a machine file (`LNES_<board>.LMC`) that the machine
menu installs from the SD card's `MACHINES` folder into one of the flash's three positions (F12 in the menu).

The picture chip (PPU), the sound part of the CPU chip (APU) and the cartridge mappers are our own designs, written
from the public NESdev documentation only; no other NES core's HDL was used. The CPU is T65 (`../../T65`) with
decimal mode switched off, as in the NES's 2A03. The NES has no system ROM, so nothing is loaded from the flash:
a game is a `.nes` file that the ESP32 writes into the SDRAM (`../../ESP32/vN/src/nes.cpp`).

## Status (2026-11-17)

Built for both boards, timing met. In simulation the CPU test `01-basics` (instr_test-v5) passes and the PPU test
`vram_access` shows its "passed" screen. **Not on hardware yet.** Other test programs were still being run when
this was written: see `../../docs/PLAN.md`.

| | EP4CE15 | 10CL025 |
|---|---|---|
| logic elements | 6,857 (45 %) | 6,811 (28 %) |
| worst setup / hold slack | +2.11 ns / +0.14 ns | +2.58 ns / +0.11 ns |

- **Mappers:** 0 (NROM), 1 (MMC1), 2 (UxROM), 3 (CNROM), 4 (MMC3, with its line counter interrupt), 7 (AxROM),
  11 (Color Dreams), 66 (GxROM). Program ROM up to 1 MB, picture ROM up to 512 KB. A file with another mapper
  is refused with its number ("No mapper 9: ...").
- **Battery RAM:** a game whose header has the battery bit keeps its 8 KB in `NAMEhhhh.SAV` beside the game (four
  characters of the game's name and a check value of the whole name). The ESP32 writes it when the game has
  stopped writing for 1.5 s, or every 10 s while it keeps writing.
- **Video:** 640 x 480 @ 60 Hz through a triple frame buffer in the SDRAM (`rtl/nes_fb.v`): the 256 x 240 picture
  at 2 x 2 in the middle. The machine's clock is chosen so that its frame lasts as long as the VGA frame within
  9 ppm (`rtl/nes_pll.v`): a frame is repeated or dropped about once in half an hour, so scrolling stays smooth.
  The machine runs 0.13 % slower than a real NES. No 50 Hz mode (no PAL machine).
- **Colours:** the PPU has no RGB output; `tools/mk_nestables.py` decodes each of the 64 colours' NTSC signal
  (and the three emphasis bits: 512 entries) into the 12-bit palette.
- **Not done:** snapshots, other mappers, the Famicom Disk System, the extra sound chips of Japanese cartridges,
  the Zapper, PAL timing.

## Controllers

The joystick gives the four directions and one button; the other buttons are keys.

| Button | Controller 1 | Controller 2 |
|---|---|---|
| Up, Down, Left, Right | DB9-1 | DB9-2 |
| A | DB9-1 button; also `X`, Space | DB9-2 button; also `G` |
| B | `Z` or left Ctrl | `F` |
| Select | Tab | `R` |
| Start | Enter | `T` |

F4 opens the joystick menu: which DB9 port is controller 1, and whether the joystick's button is A (default) or
B (then A is on the keys only).

## Keys

| Key | Function |
|---|---|
| F12 | the list of games (`.nes`); Enter loads one and starts it. The list opens by itself when the machine starts |
| Alt+F5 | the console's Reset button |
| F3 / F4 | Bluetooth audio menu / joystick menu |
| Print Screen | the picture as SCRNnnnn.BMP (256 x 240) in the browser's current folder |
| Ctrl+Alt+Del, KEY1 | back to the machine menu |
| KEY0 | reset everything (the ESP32 restarts; load the game again) |

## Build

```
cd LNES/ep4_ce15
python3 tools/mk_nestables.py                 # sound tables + palette (only if changed)
quartus_sh --flow compile LNES                # EP4CE15
cd ../10cl025 && quartus_sh --flow compile LNES   # 10CL025 (project made by tools/mk_10cl025_qsf.py)
cd ../../AMenu/ep4_ce15 && python3 tools/mk_flash.py     # output_files/machines/LNES_ep4ce15.LMC
```

## Files

| Path | Role |
|---|---|
| `LNES.qpf/.qsf/.sdc` | Quartus project (top `LNES`, pins as the other machines) |
| `rtl/LNES.v` | board top level: PLLs, resets, remote update (KEY1), keyboard, controllers, audio, tape loader + ESP32 link, memory commands, frame buffer + OSD |
| `rtl/nes_system.v` | the machine without PLLs and pins (what the testbench runs): T65, bus timing, DMA, controllers, SDRAM arbiter, RAM clear |
| `rtl/nes_ppu.v` | the PPU: registers, background and sprite fetches, sprite evaluation, sprite 0 hit, palette |
| `rtl/nes_apu.v` | the APU: two pulse channels, triangle, noise, sample channel, frame counter, mixer tables |
| `rtl/nes_mapper.v` | the cartridge mappers |
| `rtl/nes_fb.v` | triple frame buffer in SDRAM -> 640 x 480 @ 60 Hz |
| `rtl/nes_keyboard.v` | USB keyboard -> controller buttons, Reset, loader keys (also used by LMega) |
| `rtl/nes_pll.v` | machine / SDRAM clocks |
| `rtl/nes_pulse.hex`, `nes_tnd.hex`, `nes_palette.hex` | tables from `tools/mk_nestables.py` |
| `sim/run_sim.sh`, `sim/tb_nes.sv` | simulation (Questa): runs a `.nes` file; test programs that report through the cartridge RAM stop the run with their text; `frame.png` |
| `sim/fast_ram.v` | a plain memory instead of the SDRAM controller for long runs (`+define+FAST`) |
| `sim/queue.sh` | runs a list of test programs (the free Questa licence allows one session at a time) |
