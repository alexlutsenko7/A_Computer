# AMenu — machine menu (factory image)

AMenu is the bitstream at flash address 0, so it is the one the FPGA loads at every power-up. It shows a
menu of the machines, and the one you choose is loaded through the Cyclone IV remote update block. Each
machine is its own application image in the same flash. Inside any machine, **KEY1** brings you back to
the menu.

The flash holds **three machines**. Which three is the user's choice: every machine is also a file on the
SD card, and **F12** installs one of them in place of any of the three (see "Machines from the SD card").

```
        Choose a machine

 1 LSpectrum    ZX Spectrum 128K

 2 L64          Commodore 64

 3 LTari 800    Atari 800XL

 Up/Down + Enter, 1-3, joystick
  KEY1 in a machine: back here
      F3: Bluetooth audio
 F12: install from the SD card
```

- **Keys:** Up/Down (also keypad 8/2) moves the cursor, and Enter or keypad Enter starts the machine.
  A digit 1..3 (also on the keypad) starts that machine at once. On either joystick, up/down moves and
  fire starts. Keys already held at power-up are ignored. A position without a machine shows "(empty)"
  and cannot be started.
- **If a machine cannot start** (image missing or damaged), the FPGA falls back to the menu. The cursor
  is then on that machine, a red line says "Could not start", and the LED blinks.
  After a normal return with KEY1, the cursor is on the machine you just left.
- **No ESP32 is needed** for the menu itself. The ESP32 waits until a machine's core ID answers on the
  link and restarts when the ID changes, for example after KEY1.
- **Video:** 640x480@60 at 25.208 MHz (`vga_pll` c0), with LSpectrum's OSD font and layout.
- **Size:** 13,205 LEs (EP4CE15, 86 %), 6 M9K, 2 PLLs. The SDRAM is not used: its pins stay inputs with
  weak pull-ups, so it is deselected.

## Flash layout (docs/PLAN.md)

The 8 MB flash holds the menu and three positions of 2 MB. A position is one machine: its bitstream in
the first megabyte, its ROM area in the second.

| Address | Contents |
|---|---|
| 0x000000 | AMenu (factory) |
| 0x100000 | position 1: bitstream |
| 0x200000 | position 1: ROM area |
| 0x300000 | position 2: bitstream |
| 0x400000 | position 2: ROM area |
| 0x500000 | position 3: bitstream |
| 0x600000 | position 3: ROM area |
| 0x700000 | not used |

A ROM area starts with the machine's **info sector** (4 KB); the ROM image follows at + 0x1000:

| Offset | Contents |
|---|---|
| 0x00 | tag `A5 5A <machine byte> <its complement>`: 18 = LSpectrum, 24 = L64, 42 = LTari (both models), 66 = LNES, 3C = LMega, 7E = LNext |
| 0x04 | core ID, 4 bytes, high byte first |
| 0x08 | board (1 = EP4CE15, 2 = 10CL025); 0x09 flags (bit 0: the ROMs are the user's own, installed by the ESP32) |
| 0x10 | the menu line, 29 characters |
| 0x30 | label (version), 32 bytes |

- An application image cannot read which address it was started from, so a machine does not know its
  position. Its ROM loader (`../../LSpectrum/ep4_ce15/rtl/rom_loader.v`) looks at the start of the three ROM
  areas for its tag and loads the ROM image behind the first one that has it. The tag's bytes read the same
  in both bit orders.
- The menu reads the tag and the menu line of each position (`rtl/menu_names.v`): at start, when the ESP32
  gives the flash pins back, and when the ESP32 writes register RELOAD after an install. A position
  without the tag is "(empty)".
- The positions' addresses are AMenu's `MACHINE_ADDR` / `ROM_AREAS` parameters, `rom_loader`'s `ROM_AREAS`,
  `tools/mk_flash.py` and `g_aui32_slot` in the ESP32's `update.cpp`. The fixed part of the menu text comes
  from `tools/menu_text.py`, which writes `rtl/menu_text.hex`.
- `L.jic` holds LSpectrum, L64 and LTari 800 (`INSTALLED` in `tools/mk_flash.py`); LTari 130 comes from the
  SD card. L64's ROM area has only the info sector: the C64 ROMs are the user's, the ESP32 writes them there.
- LNES (both boards) and LMega (10CL025 only) are machine files as well. They have no ROMs: their ROM areas hold
  only the info sector, and the machines do not read the flash at all.

## Machines from the SD card

Every machine is a **machine file** (`output_files/machines/<machine>_<board>.LMC`, made by
`tools/mk_flash.py`): a header with the board, the lengths and CRC-32 checksums, then the info sector, the
ROM data and the bitstream exactly as the flash holds them. Copy the files of your board into the folder
**`MACHINES`** of the SD card.

In the menu, **F12** opens "Install a machine" (ESP32 firmware, `mch_*` in `ESP32/vN/src/update.cpp`):

1. "Which machine?": the files of `MACHINES` that are made for this core board, by their menu lines.
2. "Replace which one?": the three positions with what they hold now.
3. The file is checked whole (CRC-32), then written: the position's info sector is erased first, then the
   bitstream and the ROMs are written where they differ, and the info sector last, each sector read back.
   About 15 seconds. The menu then shows the new machine.

- A power cut during the write leaves that position "(empty)", never a half machine: install it again. The
  menu and the other positions are not touched.
- A file for the other core board is not listed (the menu reports its board to the ESP32).
- L64's file has no ROMs: installed over another machine it clears that machine's ROM image; installed over
  L64 it keeps the C64 ROMs that are there.
- With no machine in the flash the screen says "No machines installed" and points to F12.

## Files

| Path | Role |
|---|---|
| `rtl/AMenu.v` | top level: clocks, keyboard (`../../LSpectrum/ep4_ce15/rtl/zx_keyboard.v`, raw report only), joysticks, menu logic |
| `rtl/menu_boot.v` | remote update: reads the previous trigger and boot address, then writes watchdog off + boot address and reconfigures |
| `rtl/menu_names.v` | reads the three positions' tags and menu lines from the flash into the name RAM |
| `rtl/menu_video.v` | 32 x 24 text screen, highlighted entry, the machines' names from the name RAM, error line |
| `rtl/menu_text.hex` | the fixed text of the screen (generated) |
| `tools/menu_text.py` | writes `menu_text.hex` |
| `tools/mk_flash.py` | writes `L.cof`, `output_files/L.jic`, the machine files `output_files/machines/*.LMC` and `output_files/L_flash.bin` (the flash as SPI reads it); checks that this image is what Quartus puts into the `.jic` |
| `sim/tb_amenu.sv`, `sim/run_sim.sh` | Questa, with a flash model holding machines in positions 1 and 2: the names are read, power-up case (Down + Enter -> 0x300000) and failed-image case (cursor on machine 1 + error, '3' = the empty position does nothing, '2' -> 0x300000); writes `menu.png` / `menu_fail.png` |
| `L.cof` | **the one .jic for the board** (generated by `tools/mk_flash.py`): AMenu + three machines + their ROM areas |

## Remote update notes

- Every image is compiled with `STRATIXIII_UPDATE_MODE REMOTE`. AMenu uses `altremote_update` with
  read/write; the machines use it for `reconfig`, at CLOCK_50 / 4 = 12.5 MHz (the block allows at most 20 MHz), and
  An application image cannot read its own start address (the current state's boot address reads back the same
  value for every image), so LTari's model is a build parameter (two revisions).
- The boot address is the flash byte address. The megafunction takes `data_in[23:2]`.
- **Writes must use `read_source = 00`**: the generated block decodes no other combination for a write and drops it
  silently (that made every machine start fail at first: the boot address stayed 0).
- After a failed start the menu shows three red rows: the reason (02 watchdog, ...), the address the chip tried, its
  mode and the reason before. A machine's address that reads back shifted left by 2 is shown as written (`200000`,
  not `800000`). menu_boot keeps 26 bits of the read-back (0x400000 << 2 needs bit 24); when a shifted address equals
  another machine's written one (0x100000 << 2 = 0x400000), the shifted match wins (seen on hardware: shifted).
- Trigger bits as seen on this board: 02 = watchdog (an image ran without a watchdog reset); the others as reported
  for Cyclone IV: [2] nSTATUS (no image), [3] CRC error, [4] nCONFIG / reconfiguration request; 0 = power-up.
  The menu shows the error for bits 1..3.
- The watchdog is set to its longest time-out and switched off before every start; the machines also reset it
  every 82 us. KEY1 needs a press and a release.

## Build and program

```
cd AMenu/ep4_ce15
quartus_sh --flow compile AMenu
(cd ../../LSpectrum/ep4_ce15 && quartus_sh --flow compile LSpectrum)    # and L64, LTari, LTari -c LTari800
python3 tools/mk_flash.py            # -> L.cof, output_files/L.jic (+ .map), output_files/machines/*.LMC
python3 tools/mk_update.py           # -> output_files/LUPDATE.BIN (the menu alone)
quartus_pgm -c USB-Blaster -m JTAG -o "pi;output_files/L.jic"
```

For development, a machine's `.sof` can still be loaded straight over JTAG. KEY1 then reconfigures from
flash, which means AMenu. The machine finds its ROMs only if it is also installed in a position (its tag).

## Flash update from the SD card, loader image

The menu also talks to the ESP32 (the machines' `tape_loader` + `esp_link` at 75 MHz from `rtl/menu_pll.v`, core ID
4D4E_0003 "MN", link version 3 = the three machine positions; register MCTL reads the core board: 1 = EP4CE15, 2 = 10CL025): the ESP32 can draw on an OSD screen (shown instead of the menu; the menu takes no input
meanwhile) and read / write the configuration flash (FLASH register, `flash_if`, DCLK 18.75 MHz; the link's FLS frame
streams flash bytes at 1 us each: a first install takes about 1 minute instead of 5, most of it the flash's own
erase / program time, and checking an up-to-date flash a few seconds; an older menu (4D4E_0001) is updated byte-wise). With `LUPDATE.BIN` in the card's root folder
the ESP32 updates the menu at power-up (`ESP32/vN/src/update.cpp`, tests `ESP32_test/vN/test/update_test.cpp` and
`machine_test.cpp`). `LUPDATE.BIN` holds the menu alone; the machines are machine files. An older menu (1 MB slots,
4D4E_0001 / 0002) is asked to be updated first; after it the machines are installed with F12.

| File | What |
|---|---|
| `tools/mk_update.py` | `LUPDATE.BIN` from `output_files/L_flash.bin` (header + the menu's image); `--loader`: `output_files/L_loader.jic` (the menu, the rest of the 8 MB blank, so programming it wipes old machines); `--whole`: an update file of the whole flash for the tests |
| `rtl/menu_pll.v` | 75 MHz for the ESP32 link |

Details and the update procedure: `../../BUILDING_AND_LICENSES.md`, sections 4.6 and 4.7.

## Font

The menu's screens use **Spleen 8x16** (`font/`, BSD 2-Clause, with its `LICENSE`): `tools/mk_menufont.py` makes
`rtl/menu_font.hex` (128 characters x 16 rows); each character is 8 x 16 font pixels shown 16 x 16 VGA pixels.
