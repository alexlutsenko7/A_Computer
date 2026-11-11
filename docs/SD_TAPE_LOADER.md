# SD tape loader (TAP/TZX) and snapshots (.z80)

The loader plays **unmodified .tap and .tzx** files from an SD card, in turbo (28 MHz CPU = 8x) or at normal
speed, T-state exact; it records everything the Spectrum saves into .tap files and saves / loads `.z80` snapshots.
F3 opens the Bluetooth audio menu. Works on hardware (loading, saving, snapshots, Bluetooth menu).
The same hardware and firmware also serve L64, the Commodore 64 (.prg / .t64 / C64 .tap / .d64 / .a64 snapshots,
turbo, ROM install): see `../L64/ep4_ce15/README.md`; this document describes the Spectrum side.

It is split between the two chips:

- **ESP32** (`ESP32/v2/`, the system controller): the SD card, FAT16/32, the browser and all dialogs,
  TAP/TZX parsing, the recording decoder, .z80 files, the Bluetooth menu. The firmware is portable C in
  `ESP32/v2/src/` (tested on the PC too), running as a task next to the Bluetooth audio.
- **FPGA** (`rtl/tape_loader.v` behind `rtl/esp_link.v`): the parts that need exact timing or direct access to the
  machine: the pulse player (512-command FIFO, timed in CPU T-states), the MIC recorder that holds the Z80 while an
  event is unread, the snapshot freeze and command port, the OSD, the loader keys, frame-interrupt position and
  contention switch.
- Between them an **SPI link** (ESP32 = master, mode 0, 8 MHz): frames for register read/write, pulse
  commands, OSD text and Spectrum memory bursts (~900 KB/s), plus an IRQ line. After an FPGA reset or start
  the first frame decoded is the next one whose chip select falls (a frame already running is ignored).

## Design rules

- **No PC preprocessing**: the firmware parses TAP/TZX directly from the card.
- UI: **USB keyboard** (numpad, F-key fallback, arrows/Enter/Esc in the browser) and an **OSD** (32 x 24
  characters, Spectrum font, white on blue). No long/short-press dual use: one function per key.
- Machine keys: DiagROM = F1 held at start, 50/60 = F8; Ctrl+Alt+Del or KEY1 = back to the machine menu.
- The FPGA's loader hardware runs at **56 MHz** (sys_pll c2, edges aligned with the 112 MHz system clock), so the
  crossings to the 112 MHz domain are normal timed paths.

## Hardware

- microSD on the ESP32 in SPI mode (VSPI): SCK GPIO18, MISO GPIO19, MOSI GPIO23, CS GPIO5, 3.3 V. 20 MHz
  (4 MHz if a card does not start at 20 MHz).
- Socket: microSD J7 on the Extra_PCB_CycloneIV I/O board, 10k pull-ups on CS (DAT3), CMD, DAT0, DAT1, DAT2,
  100 nF + 10 uF at the socket, no card detect. The ESP32 also turns on its internal pull-up on MISO.
- Link and Bluetooth wiring: `ESP32/v2/README.md`, `docs/LSpectrum_Connection.docx`.
- Turbo and EAR come from the loader.

## Using it

Card: FAT32 or FAT16 (MBR-partitioned or not), 512-byte sectors. **Not exFAT** (most cards > 32 GB come exFAT:
reformat as FAT32). Folders are supported; the browser shows folders and `.tap` / `.tzx` / `.z80` files, sorted,
folders first, up to **320 entries per folder**; long names are shown (first 27 characters). With I/O board
revision 2 (`ESP32/v2`, list in the WROVER module's PSRAM): up to **4,096 entries**, first 29 characters.

| Key | Browser closed | Browser open |
|---|---|---|
| F12, keypad /, NumLock | open the browser | close it |
| keypad 8 / 2, F9 / F10, Up / Down | (Up/Down go to the Spectrum) | move |
| keypad 4 / 6, Left / Right, Page Up / Page Down | | page up / down (20 lines; held: repeats) |
| Enter, keypad Enter, F11 | (F11: pause / continue) | play the tape file / **load the .z80 snapshot** / open the folder |
| Esc, Backspace | (go to the Spectrum) | parent folder (root: close) |
| keypad 5 | pause / continue the tape | same |
| keypad - | back one block (pause first to rewind several) | same |
| **F7**, keypad * | **stop**: tape off, EAR and speed back to normal, no OSD; choose the file again to replay; while recording: stop recording | same |
| **F6** | **speed**: loading and saving in turbo (default) or at normal speed; "Speed: normal" / "Speed: turbo" for 2 s; a playing tape or a block being saved changes at once | same |
| F12 while recording | stop recording (the browser is not available while recording) | - |
| **F2** | **save a snapshot** (.z80) into the browser's current folder (see below) | same, then the browser closes |

While the browser is open the Spectrum keyboard is blocked (all keys released). Typical use: `LOAD ""` (or the 128K
menu "Tape Loader"), then F12, pick the file, Enter. Playing switches the CPU to 28 MHz (unless F6 chose normal speed) and feeds EAR from the
player; at the end of the tape, or at a TZX "stop the tape" block, turbo and EAR are released (stop: the bottom row
shows "Tape stopped (5=go on)"; keypad 5 continues — multi-load games). Pause also shows a status row.

| Machine key | Action |
|---|---|
| F2 | save a snapshot (.z80) |
| **F3** | **Bluetooth audio menu**: scan, connect, PIN, volume, Spectrum sound / test tone; F3 or Esc closes it; a playing tape goes on |
| **F4** | **joystick menu**: both DB9 Kempston (default) / DB9-1 Kempston + DB9-2 Cursor (5 6 7 8, fire 0) / Interface 2 (DB9-1 Sinclair 1 = 6-0, DB9-2 Sinclair 2 = 1-5); Up/Down, Enter selects ("Joystick: ..." for 4 s), F4 or Esc closes. Mode in INTPOS[29:28]; back to Kempston after KEY0 |
| F6 | tape speed for loading and saving: turbo (default) / normal (see above) |
| F1 held while the CPU starts (power-up, KEY0, started from the menu) | DiagROM instead of the 128K ROM |
| F8 | swap 60/50 Hz video (power-up default 640x480@60) |
| Ctrl+Alt+Del | back to the machine menu, as KEY1 (when the keys are released) |
| KEY0 (W13) | reset everything incl. the tape loader (the ESP32 restarts; Bluetooth reconnects after a few seconds) |

At power-up the CPU waits for the first keyboard packet (at most 1.5 s), so F1 held during power-up is seen. If it
is missed anyway, hold F1 and press KEY0.

### Saving (recording mode)

1. F12, then choose the first line **[Save to this folder]** (the cursor starts on the first file, so go up one
   line). Go into the wanted folder first if needed.
2. Type a name (up to 8 letters, digits, `-`, `_`; `.TAP` is added). The default is the next free `SAVEnnnn`.
   Backspace deletes, Enter starts recording, Esc goes back. An existing name is refused.
3. Save on the Spectrum as often as you like (`SAVE "name"`, `CODE`, `SCREEN$`, `DATA`, machine code calling the ROM
   routine): **every block goes into this one file**, however many and however far apart. Each block is saved at
   28 MHz; in between the Spectrum runs at normal speed. The bottom row shows `Rec NAME.TAP: n F12=stop`.
4. **F12** (or F7) stops recording and closes the file ("Saved NAME.TAP (n blocks)"). If nothing was saved the
   empty file is removed. The tape browser is not available while recording.

Only the ROM's standard format is decoded (a block needs 64 pilot pulses; MIC clicks for sound are ignored).
History: the first version (8 October) asked for the name after the first block and ended a save after 3 s of tape
time; the ROM's 1 s pause between header and data (50 Hz interrupts, real time) is 8 times longer in turbo T-states,
so header and data ended up in two files. Hence the explicit start/stop.

### Snapshots (.z80)

**Save: F2.** The Spectrum stops at once (between two instructions; the AY is muted while stopped) and the OSD asks
for a name: up to 8 letters, digits, `-`, `_`; `.Z80` is added; there is no default name, so type one. Enter saves,
Esc cancels. An existing name is refused. The file goes into the browser's current folder (the root after
power-up; open the browser and go into a folder first to save there). Saving takes well under a second; then the
Spectrum runs on exactly where it stopped, and the bottom row shows "Saved NAME.Z80". F2 does nothing while the
tape recorder is recording (stop that with F12 first). A tape that is playing pauses with the Spectrum and goes on.

**Load: F12, choose the .z80 file, Enter.** A playing tape is stopped (it belongs to the old program). The file is
checked first; a file that is not a usable .z80 changes nothing ("Not a usable .z80"). Versions 1, 2 and 3 load,
48K and 128K (and +2 / +2A / +3 / Pentagon files as 128K, without their extras). 48K snapshots run in 48K mode
(48 BASIC ROM, paging locked), as on a real 128.

Saved: all 8 RAM pages (compressed; a page that does not get smaller is stored plain), every CPU register incl.
IFF1/IFF2, IM, R, the alternate set, port 7FFD, the border, all 16 AY registers and the selected AY register.
Version 3, hardware "128K", readable by emulators (Fuse, ZEsarUX, ...). A snapshot taken in HALT stores PC at the
HALT instruction (as emulators do). Not saved: the position inside the video frame (after a load the next
interrupt comes at a different point of the frame: harmless for nearly all programs) and the beeper/MIC level.

How it works: `zx_bus` stops the CPU clock enable at an **instruction boundary**: in T2 of an opcode fetch that is
not an interrupt acknowledge and does not follow a prefix (CB, ED, DD, FD; tracked from the fetched opcodes). There
the T80 has finished the previous instruction (its ALU result is written back at T1) and has not yet taken the
opcode or incremented PC and R. The T80's own `REG` output (all registers) is read; for loading, the T80 alone is
reset and all registers are loaded at once through its `DIRSet`/`DIR` port (the same port MiSTer uses). The loader
reaches RAM, AY and ports through a small command port in `zx_bus` (below); RAM writes also update the screen
shadows. When the freeze ends, the opcode read of the stopped M1 is repeated (the loader's reads changed the data
bus), so the Spectrum continues as if nothing happened (the T-state count is unchanged: tape timing too).

## Implementation

| Part | File | Size (Quartus, EP4CE15) |
|---|---|---|
| SPI link: SPI slave (SCK oversampled at 56 MHz, <= 8 MHz; MISO changes after the falling edge, as the ESP32 samples it late, near that edge), master of the loader register bus; frames WR / RD / OSD / FIFO / MWR / MRD / STAT; core ID, IRQ | `rtl/esp_link.v` | |
| Loader hardware: registers, FIFO 512 x 32, pulse player, recorder, UART to the ESP32's Bluetooth part (512-byte receive FIFO) | `rtl/tape_loader.v` | 3 M9K (2 FIFO + 1 UART) |
| Keyboard: loader keys (17, incl. F2/F3/F5/F6/F7), raw report for typing, F1, F8 toggle, Ctrl+Alt+Del (menu), first-packet flag, ZX key blocking | `rtl/zx_keyboard.v` | 534 LEs |
| Snapshots: instruction-boundary freeze, command port (RAM, registers, AY, ports), T80 REG / DIRSet | `rtl/zx_bus.v`, `rtl/cpu_t80.v` | |
| OSD: text RAM (dual clock), font ROM (`rtl/osd_font.hex`, from the 48K ROM), overlay | `rtl/zx_video.v` | +25 LEs, 2 M9K |
| EAR from the player, T-state toggle `cen_tgl` | `rtl/zx_bus.v` | |
| MIC output (port FE bit 3), CPU hold input | `rtl/zx_bus.v` | |
| Firmware: browser, FAT16/32 (read + create/delete files), TAP/TZX, recording, speed switch, snapshots, Bluetooth menu | `ESP32/v2/src/*.cpp` | ESP32 sketch 1.17 MB (with Bluetooth and L64) |
| Platform: registers as link proxies, SD sectors, OSD shadow, FIFO / memory bursts, loader task | `ESP32/v2/src/hw.h`, `esp_hw.cpp` | |

Whole LSpectrum (2026-10-14): 7,483 LEs (49 %), 19 / 56 M9K, 75 pins, 2 PLLs; worst setup slack +0.45 ns (112 MHz),
worst hold +0.15 ns, no unconstrained paths (fitter at "HIGH PERFORMANCE EFFORT"). The screen shadows are explicit
altsyncrams for Quartus (inferred, synthesis counted 8 M9K per shadow instead of 7). JT49's 128 x 8 volume table
is in logic (QSF `AUTO_ROM_RECOGNITION OFF`). The ROM-loader -> SDRAM owner switch (`rom_loader.done`) has a
justified 2-clock multicycle in the SDC.

### Loader registers (`rtl/tape_loader.v`, firmware names in `ESP32/v2/src/hw.h`)

| Address | Register |
|---|---|
| 0x1000_0000 ID | core ID 5A58_0001 ("ZX", link version 1); L64: 4336_0001 ("C6") |
| 0x1000_0004 IRQ | R: [3:0] causes (FIFO at most half full, key change, recorder event, snapshot port idle), [11:8] mask; W: [11:8] mask |
| 0x1000_0008 KEYS | loader keys (bits as `zx_keyboard` `lkeys`; bit 10 F7 / keypad *, bit 11 F6) |
| 0x1000_000C FIFO | W: push command, R: [9:0] used, [16] player idle |
| 0x1000_0010 TAPE | [0] EAR from player, [1] turbo, [2] flush |
| 0x1000_0014 OSD | [0] on, [1] full screen (else bottom row only; full also blocks the ZX keyboard) |
| 0x1000_0018 TIMER | 56 MHz counter (the ESP32 firmware uses its own clock) |
| 0x1000_001C MARKER | block the player is in (last MARK executed) |
| 0x1000_0020 REC | recorder event, read clears it: [31] pending, [30] gap (8000 T without an edge), [29] edges lost, [23:0] T-states since the previous MIC edge |
| 0x1000_0024 RECCTL | W: [0] armed (hold the Spectrum while an event is unread), [1] hold; R: T-states since the last edge |
| 0x1000_0028 KEYRAW | last keyboard report {modifiers, key 1, key 2, key 3} (text input) |
| 0x1000_002C SNAPCTL | W: [0] freeze the Spectrum CPU; R: [0] frozen (at an instruction boundary, bus idle), [1] command busy |
| 0x1000_0030 SNAPCMD | W: start a command: [31:28] command, [17:0] address (list below) |
| 0x1000_0034 SNAPDAT | W: data for the next command; R: result of the last one |
| 0x1000_0038 INTPOS | 50 Hz frame interrupt position: [9:0] VGA line, [25:16] pixel; [29:28] joystick mode (F4); [31] memory contention off (L64: SID 8580) |
| 0x1000_003C UART | to the ESP32's Bluetooth part, 115200 8N1. W: [8] send [7:0] (ignored while busy), [9] drop the oldest received byte, [10] clear overrun; R: [7:0] oldest received byte, [8] valid, [9] sending, [10] overrun (512-byte FIFO was full) |
| 0x1000_0040 FLASH | configuration flash pass-through (ROM install, L64): W: [10] enable, [9] chip select, [8] start: send [7:0], receive one byte; R: [7:0] byte received, [8] busy, [9] chip select, [10] enabled |
| 0x1000_0044 RELOAD | W: [0] = 1: the machine reloads its ROMs from flash and restarts |
| 0x1000_0048 MCTL | machine-specific, W: kept, R: status (L64: the 1541 and turbo, `../L64/ep4_ce15/rtl/c64_system.v`); LSpectrum: unused |
| 0x1000_004C MCLR | machine-specific, W: one-clock pulse with data (L64: clear the 1541's dirty sectors) |
| 0x2000_0000 | OSD text, 32 x 24 bytes, bit 7 = inverse |

Link frames (`rtl/esp_link.v`): `01 WR r d3..d0`, `02 RD r x -> d3..d0`, `03 OSD a1 a0 b...`, `04 FIFO (d3..d0)...`,
`05 MWR a2 a1 a0 b...` and `06 MRD a2 a1 a0 x -> b...` (Spectrum memory through the snapshot port, while frozen),
`07 STAT x -> {error, 0}`, and only in the machine menu (esp_link parameter FLS, core ID 4D4E_0002) `08 FLS b... ->
-, -, r...` (each byte goes out on the configuration flash; its answer comes back two bytes later: the flash update). The ESP32 collects pulse commands, OSD text and memory writes into one frame each and
reads memory 256 bytes at a time; every other register access is one frame.

Snapshot commands (`zx_bus`, while frozen): 1 MRD SDRAM byte, 2 MWR SDRAM byte (+ screen shadow), 3 REG register
word 0-6, 4 DIR register word for LOAD, 5 LOAD (reset the T80, load all registers), 6 AYRD, 7 AYWR, 8 AYSEL (AY
register select), 9 PORT (7FFD, border, MIC, beeper), 10 STATE {HALT, AY select, beeper, MIC, border, 7FFD}.
Register words (`cpu_t80` = T80 `REG` layout): 0 {F', A', F, A}, 1 {SP, R, I}, 2 {BC, PC}, 3 {HL, DE},
4 {BC', IX}, 5 {HL', DE'}, 6 {IFF2, IFF1, IM, IY}. The request is a toggle with the data held until the
acknowledge toggles back (56 MHz and 112 MHz come from one PLL, edges aligned).

### Pulse player

Commands (32 bit, `ESP32/v2/src/hal.h`); durations in T-states = CPU clock-enable ticks, so the same file is exact at 3.5 MHz
and in turbo, and SDRAM stalls stretch the tape with the CPU:

| Command | Meaning |
|---|---|
| `PULSE n` | hold the level n T-states, then toggle |
| `LEVEL l, n` | set level l, hold n (n = 0: zero time) |
| `DATA b, k` | k bits of b MSB first, each 2 pulses of LEN0 / LEN1 |
| `SAMPLES b, k` | k bits of b MSB first, each sets the level for LEN0 (TZX 0x15) |
| `LEN0 n`, `LEN1 n`, `MARK n` | settings (zero time) |

The next timed command starts in the clock where the running one ends (no gaps). Zero-time commands are taken in
while a command runs and take effect exactly at its end, so they never show on the line. If the CPU is late, the gap
is credited to the next command (up to 255 T-states), so edges stay on time; after a stop the first command starts
fresh.

### Recorder (saving)

MIC edges are timed in T-states like the player. While a save runs the recorder is **armed**: an event the ESP32 has
not read yet **holds the Z80** (the CEN stops, as for an SDRAM wait), so no edge can be lost however long the
firmware needs (SD writes, the dialog). Holding also stops the T-states, so the recorded timing is unchanged and the
Spectrum never notices. The firmware decodes ROM-format blocks (pilot 2168, sync 667 + 735, bits 2 x 855 / 1710;
each bit is decided by its first pulse because the ROM does not always end a block with an edge) into TAP blocks.
TAP lengths are written as 0 and patched when the block ends. New files get 8.3 names; the FAT is written to both
copies, the FAT32 free count is set to "unknown". No real dates (no clock on the board).

### Firmware (`ESP32/v2/src/`)

- `main.cpp`: browser (load, sort, page, [Save to this folder]), keys with auto-repeat, player control
  (pause/continue/back, stop/end), OSD, name entry from the raw keyboard report.
- `save.cpp`: recording mode: recorder events -> ROM-format decoder -> blocks appended to one TAP file until F12.
- `snap.cpp`: snapshots: freeze, state capture, .z80 version 3 writer (compression in two passes over each page:
  length first, then the data), loader for versions 1-3 (checks the whole file before changing anything).
  The file being written (`fw_file`, fat.cpp) is shared by recording and snapshots (never both at once).
- `bt.cpp`: Bluetooth menu (F3): text commands (`info`, `scan`, `connect n`, `disconnect`, `forget`, `pin`, `vol`,
  `src`) through the FPGA's UART to the Bluetooth part of the sketch, its lines read on every main-loop pass
  (OK info / ERR / EV events), info asked every second while the menu is open, PIN typed from the raw keyboard
  report. Protocol: `ESP32/v2/README.md`.
- `fat.cpp`: FAT16/FAT32 on raw 512-byte sectors, MBR or not, long names, cluster chains (fragmented files), seek;
  creating files (free cluster search, write-back FAT cache to all copies, directory entry, growing a full folder).
- `tape.cpp`: TAP and TZX -> commands. TZX blocks played: 10 11 12 13 14 15 20 2B, control 21 22 23 24 25 26 27;
  skipped by length: 18 (CSW) 19 (generalized data) 28 (select) 2A (stop if 48K: this is a 128K) 30-35 40 5A and
  unknown blocks. Conventions: 100 ms low lead-in; a pause holds the level 1 ms if high, then low; TAP blocks =
  standard ROM timing with a 1 s pause.
- `hw.h` + `esp_hw.cpp`: the FPGA's registers as proxy objects over the link, SD card sectors (the Arduino SD
  library's driver only, `sd_read_raw` / `sd_write_raw`; the card is not mounted, which saves 25 KB of heap), the OSD as a shadow sent in changed ranges, the loader task (core 1). Every 0.5 s it checks
  that the FPGA was not reset (KEY0 clears the IRQ mask it set); after a reset the ESP32 restarts.
- The portable files are plain C (built as C++ on the ESP32, as C for the PC tests).

## Build and test

```
quartus_sh --flow compile LSpectrum    # FPGA; the .jic: quartus_cpf -c L.cof in ../AMenu
arduino-cli compile -b esp32:esp32:esp32 -u -p COM10 esp32       # ESP32 (in LSpectrum/ep4_ce15/)
ESP32_test/v2/test/run_host_test.sh  # PC: FAT16/FAT32 images, listing + every TAP/TZX signal vs tools/tzxref.py;
                                       #     saving: ROM SAVE pulse trains -> decoder -> files, checked by tools/fatcheck.py;
                                       #     snapshots: snap.cpp against a model of the hardware: loading reference files
                                       #     (test/z80ref.py: versions 1/2/3, 48K/128K, stored pages, bad files), and
                                       #     save + reload round trips checked by z80ref.py and fatcheck.py;
                                       #     L64 ROM install (c64rom_test.cpp): flash + pass-through model,
                                       #     installs cut off at random points, never a valid header on a wrong image
LSpectrum/ep4_ce15/sim/run_esp_link_sim.sh      # RTL: tape_loader over the SPI link: ID, registers, OSD, FIFO, 256-byte MWR/MRD
                                       #     across a page, error flag with slow commands, IRQ on key change;
                                       #     at 56 / 94.5 MHz, 8 / 4 MHz SPI, MISO sampled 30-140 ns after the rising edge;
                                       #     the menu (75 MHz, FL_HALF 2): a 300-byte FLS stream against a flash model
LSpectrum/ep4_ce15/sim/run_snap_sim.sh          # RTL: zx_bus + T80 + SDRAM: a Z80 test program (prefixes, DD CB, LDIR/CPIR,
                                       #     EXX, IM 2, HALT, paging, AY) run undisturbed, with random freezes + reads,
                                       #     and with random freezes + full restore (LOAD): identical results
```

Hardware checks: `tests/Test_wires/` (every ESP32 <-> FPGA wire, the SD card), `ESP32_test/v1/ESPLinkTest/` (link
throughput, memory round trips, keys, OSD test pages).

Test files are generated by `ESP32_test/v2/tools/mktest.py` (TAP + a TZX with every handled block type incl. loops, jumps,
calls, stop, skipped and unknown blocks) and packed by `ESP32_test/v2/tools/mkimg.py` (FAT16/FAT32 image builder, fragments
files on purpose). `ESP32_test/v2/tools/tzxref.py` is an independent reference implementation of the signal.

Not covered yet: TZX 0x19 (generalized data), 0x18 (CSW), 0x28 (select block menu); text/message blocks are
not shown; no auto-typing of `LOAD ""`; saving only in ROM format, 8.3 names, no overwrite. Snapshots: no
.sna, no overwrite, no frame position.
