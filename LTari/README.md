# LTari — Atari 800XL / 130XE (PAL)

The third machine of the L board, after LSpectrum (ZX Spectrum 128K) and L64 (Commodore 64).
It is an Atari 130XE (128 KB) that can also run as an 800XL (64 KB). The machine menu has an entry for each,
**LTari 800** and **LTari 130**. The plan and the decisions behind it are in `../docs/PLAN.md`
("LTari: Atari 8-bit machine").

ANTIC, GTIA, POKEY and the PIA are our own designs (clean-room). They are written only from documentation (the
Altirra Hardware Reference Manual in `ref/`, De Re Atari, Atari's manuals) and checked against behaviour
(Altirra / atari800, Acid800). No other Atari FPGA core's HDL is opened. The CPU is T65 (`../T65`). The ROMs are
AltirraOS and Altirra BASIC by Avery Lee, which are free to distribute (`roms/README.md`).

## Status (2026-10-30)

- **On the board (user):** LTari 800 (64 KB) and LTari 130 (128 KB) start from the menu, each the right model
  (banking test `tools/mk_modeltest.py`); BASIC, keyboard, joysticks, 640x480@60 / 720x576@50 video, sound.
  Disks (.atr): Pac-Man, M.U.L.E. (BASIC off); cartridge: Prince of Persia (Atarimax 1 MB, 130 only, as it should be).
- **Disk drive D1:** `.atr` images (128 / 256-byte sectors) through the SIO bridge and the ESP32
  (`../LSpectrum/esp32_v2/src/atari.cpp`): status, read, write / put, format. A header size beyond the file's end is cut
  to the file (old images).
- **.xex:** served as a read-only boot disk: sectors 1-3 our loader (`tools/mk_xexboot.py`), then the file.
  The loader switches BASIC off, loads the segments, calls INITAD, jumps to RUNAD. It uses $0700-$08FF, so a
  program that loads there does not work.
- **.car:** standard 8 KB ($A000) and 16 KB ($8000) cartridges, Atarimax 128 KB and 1 MB (the manual's 8.2:
  bank select by any access to $D500-$D5FF). Other bank-switched types (XEGS, OSS, ...) not yet: the manual does
  not describe them.
- **GTIA:** players / missiles, priorities (the manual's equations, fifth player, multicolour), collisions,
  GTIA modes 9 / 10 / 11 (`sim/run_gtia_sim.sh`: unit test).
- **BASIC on / off:** Enter on an .atr asks "How do you want to load it: <F1> No BASIC <F2> with BASIC" (three OSD
  lines; Esc = back). F1: the ESP32 sets MCTL[24], which holds OPTION through the cold start until the first SIO
  command (at most 5 s), so the OS starts without BASIC. .xex and .car are not asked (the .xex loader switches
  BASIC off itself).
- **Disk change:** Shift + Enter on an .atr changes the disk without a cold start (multi-disk programs).
- **Snapshots (F2 / .a8s):** freeze at an instruction boundary (the whole machine stops at a cycle boundary
  before a CPU opcode fetch), I/O shadow at SDRAM 0x3D000 (every CPU write to $D000-$D7FF), PIA and
  Atarimax state read out directly; loading runs a restore program in restore mode (restore bank 0x30000),
  as L64. File: 128-byte header + 1,280-byte shadow + 64 KB RAM (+ 64 KB on the 130).
  `sim/run_sim.sh +define+CART=1 +define+SNAPTEST`.
- **Not done:** other cartridge types, D2:-D4:, tape (.cas, dropped), turbo (dropped), paddles / light pen,
  high-speed SIO, the GTIA mid-line write delays, NTSC.

## Flash layout (one `.jic`: `../AMenu/L.cof`)

| Address | Contents |
|---|---|
| 0x300000 | LTari 800 image (revision `LTari800`, **800XL**, 64 KB) |
| 0x400000 | LTari 130 image (revision `LTari`, **130XE**, 128 KB) |
| 0x540000 | ROM image, 28 KB (`roms/atarirom.hex`, from `tools/mk_atarirom.py`) |

Both images come from the same sources; the revision sets the top-level parameter `MODEL130` (`set_parameter` at the
end of `LTari.qsf` / `LTari800.qsf`, otherwise identical: keep them in step). An application image cannot learn
its own start address from the remote update block (the current state reads back the same value for both), so the
model is built in.

## Build

```
cd LTari
python3 tools/mk_atarirom.py roms/altirraos_xl.rom roms/altirra_basic.rom roms/atarirom   # -> .hex (+ .mem)
python3 tools/mk_palette.py rtl/atari_palette.hex                                          # only if changed
quartus_sh --flow compile LTari                  # LTari 130
quartus_sh --flow compile LTari -c LTari800   # LTari 800
cd ../AMenu && quartus_cpf -c L.cof        # the board's .jic (menu + all machines + ROMs)
```

## Keys

| Key | Function |
|---|---|
| letters, digits, Return, Esc, Tab, Space, Caps Lock, Backspace | as on the Atari |
| `-` `=` `;` `,` `.` `/` | as on the Atari |
| `'` `\` `[` `]` `` ` `` | Atari `+` `*` `<` `>` and Inverse |
| arrows | Atari cursor keys (Control + `-` `=` `+` `*`) |
| Home / Delete / Insert | Clear / delete character / insert character |
| Shift, Ctrl | Shift, Control |
| Alt+F2 / Alt+F3 / Alt+F4 | START / SELECT / OPTION (held as long as the keys are held; Alt+F4 held with KEY0 without a disk = start without BASIC) |
| Alt+F5 | Reset (the XL/XE system reset) |
| Alt+F6 | Help |
| Pause, Alt+F7 | Break |
| F8 | video 60 Hz (power-up) / 50 Hz |
| F12 | ESP32 file browser: `.atr` into disk drive D1:, `.xex` runs (through our boot loader), `.car` (standard 8 / 16 KB, Atarimax 128 KB / 1 MB) plugs in; each cold-starts the Atari (an `.atr` first asks F1 no BASIC / F2 with BASIC); Shift+Enter on an `.atr` only changes the disk; `.a8s` loads a snapshot |
| F2 | snapshot: the Atari stops, type a name, Enter: `NAME.A8S` in the browser's folder |
| F3 / F4 | Bluetooth audio menu / joystick menu (which DB9 port is stick 0) |
| Print Screen | the picture as SCRNnnnn.BMP (376 x 240, 256 colours) in the browser's current folder |
| Ctrl+Alt+Del, KEY1 | back to the machine menu |
| KEY0 | reset everything (the ESP32 restarts) |

The two DB9 ports are stick 0 (DB9-1) and stick 1 (DB9-2). The F4 menu can swap them.

## Files

| Path | Role |
|---|---|
| `LTari.qpf/.qsf/.sdc` | Quartus project (top `LTari`, pins as L64) |
| `rtl/LTari.v` | board top level: PLLs, resets, video clock switch (F8), remote update (model, KEY1), keyboard, joysticks, audio, tape loader + ESP32 link, memory commands, frame buffer + OSD, sync hold |
| `rtl/atari_system.v` | the machine without PLLs and pins (what the testbench runs): T65, bus timing, MMU / PORTB, SDRAM arbiter (bus, frame buffer, ESP32), ROM loader, RAM clear |
| `rtl/antic.v` | ANTIC: DMA, display list, modes 2-F, scrolling, NMIs, WSYNC, VCOUNT |
| `rtl/gtia.v` | GTIA: colours, hi-res, players / missiles, priorities, collisions, GTIA modes 9-11, CONSOL, triggers, PAL |
| `rtl/pokey.v` | POKEY: timers, IRQs, keyboard, RANDOM, serial port, audio |
| `rtl/pia.v` | 6520 PIA: joysticks, PORTB, SIO control lines |
| `rtl/atari_keyboard.v` | USB keyboard (CH9350 UART) -> POKEY key codes, console keys, loader keys |
| `rtl/atari_sio.v` | SIO bus bridge: POKEY's bytes (with the command line state) to the ESP32, the ESP32's bytes as a 19,200-baud bit stream to POKEY (tape loader MCTL / MSTAT / MCLR) |
| `rtl/atari_fb.v` | triple frame buffer in SDRAM: GTIA's 376 x 240 at 2 x 2: 640 x 480 @ 60 Hz (middle 320 x 240) / 720 x 576 @ 50 Hz (middle 360 x 240), PAL palette |
| `rtl/atari_palette.hex` | 256-colour PAL palette (from `tools/mk_palette.py`) |
| `rtl/atari_pll.v`, `rtl/atari_vpll.v` | machine / SDRAM clocks; VGA pixel clocks 25.208 / 27.009 MHz (as LSpectrum) |
| `sim/run_sim.sh`, `sim/tb_atari.sv` | boot simulation (Questa): ROMs from the flash model, SDRAM model, the frame buffer, the SIO bridge; text screen every 50 ms, `screen.png` (GTIA) and `vga.png` (VGA output); `+define+DISK`: a drive model boots our test boot sector ("DISK BOOT OK") |
| `tools/mk_atarirom.py` | ROM image for the flash (header page, OS, BASIC) |
| `tools/mk_xexboot.py` | the .xex boot loader (our 6502 code, with a small assembler) -> `../LSpectrum/esp32_v2/src/atari_xexboot.h` |
| `sim/run_gtia_sim.sh`, `sim/tb_gtia.sv` | GTIA unit test: players / missiles, sizes, priorities, collisions, hi-res, fifth player, GTIA modes |
| `sim/mk_xextest.py` | test disk for `tb_atari +define+XEX`: the loader + a test .xex (INIT, BASIC off, RUN) |
| `tools/mk_palette.py` | the palette, from the PAL hue angles of the hardware manual (also `../LSpectrum/esp32_v2/src/atari_palette.h` for screenshots) |
| `NOTES.md` | the clean-room facts from the manual, in our own words, and the implementation notes |
| `ref/` | local only (not in the repository): Altirra Hardware Reference Manual (PDF + text; free download from virtualdub.org / Altirra), AltirraOS / Altirra BASIC sources as published in atari800 |
| `roms/` | `altirraos_xl.rom`, `altirra_basic.rom`, `atarirom.hex`, licence notes |
| `syn_check/` | synthesis-only project from the first skeleton (size check) |
