# AMenu — machine menu (factory image)

AMenu is the bitstream at flash address 0, so it is the one the FPGA loads at every power-up. It shows a
menu of the machines, and the one you choose is loaded through the Cyclone IV remote update block. Each
machine is its own application image in the same flash. Inside any machine, **KEY1** brings you back to
the menu.

```
        Choose a machine

 1  LSpectrum  ZX Spectrum 128K

 2  L64   Commodore 64
            ...
 Up/Down + Enter, 1-2, joystick
  KEY1 in a machine: back here
```

- **Keys:** Up/Down (also keypad 8/2) moves the cursor, and Enter or keypad Enter starts the machine.
  A digit 1..N (also on the keypad) starts that machine at once. On either joystick, up/down moves and
  fire starts. Keys already held at power-up are ignored.
- **If a machine cannot start** (image missing or damaged), the FPGA falls back to the menu. The cursor
  is then on that machine, a red line says "Could not start", and the LED blinks.
  After a normal return with KEY1, the cursor is on the machine you just left.
- **No ESP32 is needed** for the menu itself. The ESP32 waits until a machine's core ID answers on the
  link and restarts when the ID changes, for example after KEY1.
- **Video:** 640x480@60 at 25.208 MHz (`vga_pll` c0), with LSpectrum's OSD font and layout.
- **Size:** 823 LEs, 2 M9K, 1 PLL. The SDRAM, the ESP32 link and BT pins are not used: they stay
  inputs with weak pull-ups, so the SDRAM is deselected.

## Flash layout (docs/PLAN.md)

| Address | Contents |
|---|---|
| 0x000000 | AMenu (factory) |
| 0x080000 | LSpectrum |
| 0x100000 | ZX ROMs (`../LSpectrum/roms48k.hex`) |
| 0x180000 | L64 |
| 0x200000 | C64 ROMs (installed by the ESP32) |
| 0x280000 | LTari (started from here: LTari 800) |
| 0x300000 | LTari, the same image (started from here: LTari 130) |
| 0x380000 | LTari ROMs (`../LTari/roms/atarirom.hex`) |

The machine addresses are AMenu's `MACHINE_ADDR` parameter. The menu text comes from
`tools/menu_text.py`, which writes `rtl/menu_text.hex`. Keep the two in the same order.

## Files

| Path | Role |
|---|---|
| `rtl/AMenu.v` | top level: clocks, keyboard (`../LSpectrum/rtl/zx_keyboard.v`, raw report only), joysticks, menu logic |
| `rtl/menu_boot.v` | remote update: reads the previous trigger and boot address, then writes watchdog off + boot address and reconfigures |
| `rtl/menu_video.v` | 32 x 24 text screen, highlighted entry, error line |
| `rtl/menu_text.hex` | text screen (generated) |
| `tools/menu_text.py` | writes `menu_text.hex` |
| `sim/tb_amenu.sv`, `sim/run_sim.sh` | Questa: power-up case (Down + Enter -> 0x180000) and failed-image case (cursor + error, '1' -> 0x080000); writes `menu.png` / `menu_fail.png` |
| `L.cof` | **the one .jic for the board**: AMenu + all machines + ZX ROMs |

## Remote update notes

- Every image is compiled with `STRATIXIII_UPDATE_MODE REMOTE`. AMenu uses `altremote_update` with
  read/write; the machines use it for `reconfig`, at CLOCK_50 / 4 = 12.5 MHz (the block allows at most 20 MHz), and
  An application image cannot read its own start address (the current state's boot address reads back the same
  value for every image), so LTari's model is a build parameter (two revisions).
- The boot address is the flash byte address. The megafunction takes `data_in[23:2]`.
- **Writes must use `read_source = 00`**: the generated block decodes no other combination for a write and drops it
  silently (that made every machine start fail at first: the boot address stayed 0).
- After a failed start the menu shows three red rows: the reason (02 watchdog, ...), the address the chip tried, its
  mode and the reason before. A machine's address that reads back shifted left by 2 is shown as written (`180000`,
  not `600000`).
- Trigger bits as seen on this board: 02 = watchdog (an image ran without a watchdog reset); the others as reported
  for Cyclone IV: [2] nSTATUS (no image), [3] CRC error, [4] nCONFIG / reconfiguration request; 0 = power-up.
  The menu shows the error for bits 1..3.
- The watchdog is set to its longest time-out and switched off before every start; the machines also reset it
  every 82 us. KEY1 needs a press and a release.

## Build and program

```
cd AMenu
quartus_sh --flow compile AMenu
(cd ../LSpectrum && quartus_sh --flow compile LSpectrum)
quartus_cpf -c L.cof                 # -> output_files/L.jic (+ .map with the addresses)
quartus_pgm -c USB-Blaster -m JTAG -o "pi;output_files/L.jic"
```

For development, a machine's `.sof` can still be loaded straight over JTAG. KEY1 then reconfigures from
flash, which means AMenu.

## Flash update from the SD card, loader image

The menu also talks to the ESP32 (the machines' `tape_loader` + `esp_link` at 75 MHz from `rtl/menu_pll.v`, core ID
4D4E_0002 "MN", link version 2): the ESP32 can draw on an OSD screen (shown instead of the menu; the menu takes no input
meanwhile) and read / write the configuration flash (FLASH register, `flash_if`, DCLK 18.75 MHz; the link's FLS frame
streams flash bytes at 1 us each: a first install takes about 1 minute instead of 5, most of it the flash's own
erase / program time, and checking an up-to-date flash a few seconds; an older menu (4D4E_0001) is updated byte-wise). With `LUPDATE.BIN` in the card's root folder
the ESP32 updates the flash at power-up (`LSpectrum/esp32/src/update.cpp`, test `esp32/test/update_test.cpp`); with no
machine image in the flash it shows "No machines installed".

| File | What |
|---|---|
| `tools/mk_update.py` | `LUPDATE.BIN` from `L.cof` (.pof -> .rpd -> header + image); `--loader`: `output_files/L_loader.jic` (the menu, the rest of the 8 MB blank, so programming it wipes old machines) |
| `rtl/menu_pll.v` | 75 MHz for the ESP32 link |

Details and the update procedure: `../BUILDING_AND_LICENSES.md`, sections 4.6 and 4.7.

## Font

The menu's screens use **Spleen 8x16** (`font/`, BSD 2-Clause, with its `LICENSE`): `tools/mk_menufont.py` makes
`rtl/menu_font.hex` (128 characters x 16 rows); each character is 8 x 16 font pixels shown 16 x 16 VGA pixels.
