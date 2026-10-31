# L64 — Commodore 64 (PAL) on the QMTECH Cyclone IV board

L64 is the second machine in the flash, after LSpectrum. You pick it in the machine menu that appears at
power-up (`../AMenu/`), and **KEY1** brings you back to that menu. It runs on the same I/O board as LSpectrum,
with the same ESP32 system controller (SD card loader, OSD, Bluetooth audio).

Status (2026-10-29): **on hardware** BASIC boots, `.d64` games load (Bruce Lee, Krackout, Pac-Man), the frame-buffer
video (800x600 at 60 Hz after power-up, F8 = 50 Hz), turbo loading and snapshots (F2 / .a64) work with the OSD. Not yet tried on
hardware: tape load/save, .prg/.t64, disk writing, disk change, SID 8580, joystick menu.

## Using it

The user sheet with all keys and step-by-step usage is `../docs/L64_Keys.docx`.

| Key | Function |
|---|---|
| F12 / keypad / | SD card browser: `.a64` (snapshot, F2), `.d64` (inserted into the 1541, device 8; at the BASIC prompt `LOAD"*",8,1` is typed for you; loading takes ~1-2 min at the 1541's standard speed, then type `RUN`; choosing another .d64 while a disk is in changes the disk, which the DOS notices, as a game asking for disk 2 needs; a file that is read-only on the card is a write-protected disk), `.prg` / `.t64` (put straight into RAM; a BASIC program at $0801 starts with RUN), `.tap` (C64 tape, played through the cassette port: type `LOAD` first, or Shift+RUN/STOP) |
| [Save to this folder] | first browser line: a name, then everything the C64 saves to tape (`SAVE "NAME"`) goes into NAME.TAP until F12 |
| F7 / keypad * | stop the tape |
| keypad 5 / F11 | pause / continue the tape |
| F3 | Bluetooth audio menu |
| F4 | joystick menu: DB9-1 = control port 2 and DB9-2 = port 1 (default), swapped, or both on port 2 |
| F5 | SID 6581 (default) / 8580 |
| F8 | video 60 Hz (800x600, after power-up) / 50 Hz (the C64's own frame rate); the C64 itself is not affected |
| F6 | turbo (default) / normal: while the cassette or 1541 motor runs, the C64 and the drive run up to 4x faster |
| Print Screen | the picture as `SCRNnnnn.BMP` (400 x 284, 16 colours) in the browser's folder; the C64 runs on |
| F2 | snapshot: the C64 stops, type a name, Enter: `NAME.A64` in the browser's folder; choosing a `.a64` in the browser loads it |
| KEY0 | reset everything: the C64 starts as after power-on (RAM cleared), the ESP32 restarts too |
| Ctrl+Alt+Del, KEY1 | back to the machine menu (Ctrl+Alt+Del when the keys are released) |

The C64 keyboard is mapped by position on a US layout:
- Letters, digits, Return, Space, `, . /` are where you expect them.
- `- = [ ] ; ' `` ` give the C64's `+ - @ * : ; ←`; `\` gives `=`, Insert `£`, End `↑`, Home CLR/HOME.
- Backspace and Delete are DEL. Esc is RUN/STOP, Tab and Ctrl are CTRL, the Windows key is C=, and Page Up is RESTORE.
- The cursor keys work in all four directions (Left/Up add SHIFT).
- **Alt + F1..F8** give the C64's F1..F8. Without Alt, the PC F-keys are the loader functions above.

## ROMs

The Commodore ROMs are copyrighted, so they are not part of this project. Put your own ROM files (for
example from VICE) on the SD card in **`/ROMS/C64/`**. Each name must start with `KERNAL`, `BASIC` or `CHAR`;
the sizes are 8, 8 and 4 KB (`kernal-901227-03.bin`, `basic-901226-01.bin`, `chargen-901225-01.bin`).

For the disk drive, add the 1541 DOS ROM (16 KB, name starting `DOS1541` or `1541`, e.g.
`dos1541-325302-01+901229-05.bin`); without it there is no drive (`DEVICE NOT PRESENT`).

When L64 starts and there are no ROMs in the flash yet (or the flash has no 1541 ROM and the card has one),
the ESP32 writes them to flash 0x200000 and
restarts the C64. After that, the machine boots without the card. The image's header (offset 0,
`F3 "L64 ROMS"` (+ 4 spaces; the ESP32 also accepts the old "ADORE64 ROMS"), which the FPGA's ROM loader and the ESP32 check) is erased first and written last, after
the ROM data checked out, so an install that stops anywhere is simply done again at the next start. A flash
or card error is retried twice; if the files are missing or the install keeps failing, the OSD says why and
F12 tries again (after a card change too).

`tools/mk_c64rom.py KERNAL BASIC CHAR [DOS1541] OUT` builds the same 48 KB image as an Intel HEX file (for a local
`.cof`) and as a `.mem` file (for the testbench). For local tests only, `roms_local/` (git-ignored) holds such files.

## Design

| Part | Source |
|---|---|
| VIC-II | **VIC-II Kawari** (GPL-3), `rtl/vicii/`, small changes listed in `rtl/vicii/SOURCE.md` |
| CPU 6510 | **T65** (BSD), `../T65/`; the I/O port ($00/$01) is in `c64_system.v` |
| SID 6581/8580 | MiSTer C64 (reDIP-SID, CERN-OHL-S / GPL), `rtl/sid/` |
| CIA 6526 × 2 | MiSTer C64 `mos6526.v` (GPL), `rtl/cia/` |
| 1541 drive | our code: `c1541.v` (6502 = T65, RAM, ROM, address decode, serial bus, stepper), `c1541_gcr.v` (disk surface: GCR encoder / decoder); VIA 6522 × 2 by Gideon Zweijtzer (GPL-3), `rtl/via/` |
| Bus, PLA, colour RAM, keyboard, joysticks | our code: `c64_system.v`, `c64_keyboard.v` |
| Video: frame buffer, 60 / 50 Hz VGA, OSD | our code: `c64_fb.v`, `c64_video.v`; the clock switch `../LSpectrum/rtl/vga_clkmux.v` |
| SDRAM, ROM loader, tape loader + ESP32 link, audio DAC, BT I2S | shared with LSpectrum (`../LSpectrum/rtl/`) |

- **Clocks:** `c64_pll` has one 756.25 MHz VCO, the same as LSpectrum's video PLL.
  - 31.510 MHz = the VIC-II dot clock × 4 (PAL 6569, 0.055 % slow). It clocks the whole C64.
  - 94.531 MHz (3×, rising edges aligned) clocks the SDRAM controller, ROM loader, tape loader and the
    frame buffer's SDRAM side.
  - VGA pixel clock through a global clock switch (F8): 39.80 MHz for 60 Hz or 31.51 MHz for 50 Hz.
- **Bus:** each half of the 0.985 MHz cycle has one owner, the VIC-II or the CPU.
  - Tick 2 of 16: that owner's single SDRAM access starts, and is finished well before the data is taken.
  - Ticks 4-12: the frame buffer may use the SDRAM when no C64 access waits, so it never delays one.
- **Turbo (F6, `c64_system.v` header):** while the cassette or the 1541 motor runs and MCTL[2] allows it, the CPU
  starts a cycle every 8 ticks (up to 3.94 MHz) through its own SDRAM port; a cycle that touches the VIC-II, SID
  or colour RAM waits for the normal phi2 slot. The CIAs step once per CPU cycle and the 1541 gets its drive
  cycle from the C64's cycles (1.0156 per cycle, as at normal speed), so tape timing, the serial bus and fast
  loaders keep their ratios; the picture, the SID and the TOD clock stay real time. While the ESP32 refills the
  track buffer after a head step, the C64 and the drive pause together. The frame buffer then uses ticks 4-5 and 9-12.
  - Tick 12: CIA and SID strobes.
  - Tick 15: the CPU clock enable.
  - Timing details are in the header of `c64_system.v`.
- **Memory (SDRAM):** 64 KB RAM at 0, cleared to 0 after each ROM load, i.e. at every start (machine menu, KEY0,
  ROM reload), before the C64 leaves reset. The SDRAM keeps its contents through a reconfiguration and even a
  short power-off, so without the clear a game's reset protection (`CBM80` at $8004) would catch the next start.
  The ROM image goes to 0x10000 (header, CHAR 0x11000, BASIC 0x12000,
  KERNAL 0x14000, 1541 ROM 0x18000, which is also copied into the drive's block RAM while loading).
  Restore bank at 0x30000 (snapshots), with the I/O shadow at 0x3D000. Three frame buffers at 0x40000,
  0x60000 and 0x80000.
- **1541:**
  - The drive has its own 6502 at 1.000 MHz, 2 KB RAM, 16 KB ROM and two VIAs, all in block RAM / logic.
  - The disk surface is made on the fly from an 8 KB track buffer that holds the sectors of the track under
    the head. The ESP32 fills it from the .d64 (snapshot addresses 0x20000+) whenever the head moves, and
    writes back the sectors the DOS changed, each only after checking that the C64 core still answers on the
    link (a reconfiguring or reset FPGA reads as all ones: every sector dirty, data FF).
  - Disk change: the ESP32 holds the write-protect input low for 0.3 s (the new disk covering the sensor
    while it slides in); the DOS sees VIA2 PB4 change and reads the new BAM. Read-only files set MCTL[1].
  - Registers: MCTL/MSTAT 0x48, MCLR 0x4C. The board LED shows the drive LED.
- **Video (`c64_fb.v`):** the VIC-II's colour index of every dot goes into SDRAM: the whole visible PAL picture,
  400 × 284 dots, 4 dots per 16-bit word, through a 256-word FIFO. There are three buffers: a complete frame
  becomes the newest, and the writer goes on in the one that is neither the newest nor on screen. The
  reader takes the newest buffer at each output frame start, so the picture never tears. It fetches every
  line once into a 4-line block RAM and shows it twice at 2 pixels per dot (800 × 568, Kawari's palette):
  - **60 Hz** (power-up): 800 × 600, VESA timing at 39.80 MHz (37.7 kHz, 60.02 Hz). Every 5th C64 frame is
    shown twice, which makes scrolling slightly uneven.
  - **50 Hz** (F8): 800 × 600 active in 1008 × 624 at 31.51 MHz (31.26 kHz, 50.12 Hz), the timing Kawari's
    scan doubler had. Each frame is shown once, one frame late.
  - The ESP32's OSD is shown in the middle (512 × 384). Kawari's own RGB output and scan doubler are not built.
  - At each start (machine menu, KEY0, ROM reload) the VGA syncs stay off until 2 s after the C64 left reset,
    when BASIC is on the screen (`L64.v`): the monitor's auto-adjust then sees a picture. On a black screen
    it could take the HSYNC edge's crosstalk on the colour lines, 40 pixels after the picture, for the picture's
    right edge (a coloured line at the right). HSYNC / VSYNC are 3.3-V LVCMOS at 2 mA (slower edges).
- **Snapshots:** every CPU write to $D000-$DFFF also goes to the I/O shadow (register mirrors folded), so the
  last value of every VIC-II, SID (write-only), colour RAM and CIA register is known; the CIAs' CRA / CRB /
  interrupt mask are read out directly (`mos6526` output `state`). F2: freeze at an instruction boundary, save
  header (registers, CIA state) + 64 KB RAM + 4 KB shadow (69,664 bytes). Loading: RAM back, then a restore
  program (written by the ESP32 into the restore bank) runs after a CPU-only reset in **restore mode**, where
  the CPU sees the restore bank everywhere except $D000-$DFFF (always I/O): it writes the I/O registers, the
  6510 port and the stack, loads A / X / Y / S and does RTI; the first opcode fetch after an RTI ends restore
  mode, so the program continues from real RAM. Not saved: the 1541, running SID / timer states, the raster
  position.
- **ESP32 link:** core ID `43360001` ("C6"). The tape loader registers are the same as LSpectrum's. The
  snapshot port does MRD/MWR (CPU frozen at an opcode fetch; the CIAs and SID stop with it), REG (T65
  registers, CIA state) and CTL (restore mode, CPU reset). New registers: FLASH (0x40, flash pass-through), RELOAD (0x44), MCTL (0x48; bit 2 = turbo allowed)
  and MCLR (0x4C).
  INTPOS[31] selects the 8580 SID and INTPOS[29:28] is the joystick mode.
- **Cassette:**
  - The tape loader's pulse player feeds the CIA1 FLAG input (the read line).
  - It counts C64 cycles only while the KERNAL has the motor on, as a real datasette does.
  - The sense line shows PLAY pressed while a tape plays.

## Build

```
quartus_sh --flow compile L64                # -> output_files/L64.sof
cd ../AMenu && quartus_cpf -c L.cof       # the one .jic: menu, LSpectrum, L64, ZX ROMs
```

Build (2026-10-29): 14,770 LEs (96 %), 78 % of the memory bits, timing met: setup +0.49 ns at 94.5 MHz,
hold +0.16 ns; fully constrained.

Simulation (Questa; registers and memories start at 0 as in the FPGA, `+initreg+0 +initmem+0`):
- `sim/run_sim.sh ROMIMAGE.mem` boots the whole C64 and checks the BASIC banner, `38911 BASIC BYTES FREE`
  and `READY.`; it writes `screen.png` (one VGA frame through the frame buffer, 60 Hz; `+define+M50` for 50 Hz).
  The SID is a silent stand-in there (`sim/sid_stub.sv`).
- `+define+DISK` (with `disk.d64` from `tools/mk_d64.py`) also types `LOAD"$",8` and `LIST`, and checks the
  directory.
- `+define+TURBO`: the same in turbo (with DISK: turbo while the drive motor runs, slow track loads).
- `+define+DIRTYRAM`: the SDRAM holds a game's reset protection at power-up (`CBM80` at $8004 and a
  border-flashing loop at $8209, as Krackout leaves it); the RAM clear must remove it so that BASIC starts.
- `+define+SNAPTEST`: freeze, read registers / CIA state / I/O shadow, restore with a test program, check
  that the registers are back and the C64 runs on.
- `sim/run_vic_sim.sh`: the VIC-II alone (a register write must show in the border, on the colour index output).

On hardware: `tools/SIDSWEEP.PRG` (load with F12) sweeps a resonant low-pass filter over a sawtooth; run it with
each SID model (F5) to hear the 6581 / 8580 difference (test plan T22, `../docs/L64_Test_Plan.xlsx`).
