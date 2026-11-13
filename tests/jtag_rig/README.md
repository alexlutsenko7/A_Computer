# jtag_rig — testing a core board that has no I/O board yet

A core board alone has no monitor, keyboard or ESP32. With this rig the PC stands in for them over the JTAG cable:
it presses a key, reads status bits, measures the video timing and reads the picture, one video line at a time
(Quartus "In-System Sources and Probes", no extra hardware). Used on 2026-11-11 for the first run of the menu and
all four machines on the QMTECH 10CL025 board (`results/screens.png`, book Chapter 26).

The rig is never part of a product image: `setup.sh` copies the sources to `tmp/jtagtest/work`, and `patch.py` adds
`jtag_test.v` to the four tops there (the menu's keyboard word gets a key code from JTAG; KEY1 of each machine can be
pressed from JTAG; the VGA outputs and 16 status bits are read).

| File | Role |
|---|---|
| `jtag_test.v` | the rig: source (key, key code, line, first pixel, step, colour bit) and two probes (400 samples of a video line; ID, status, frame counter, lines per frame, pixels per line, 50 MHz clocks per frame and per 64 lines) |
| `setup.sh`, `patch.py` | scratch copy of the sources with the rig in the tops and in the 10cl025 project files |
| `jt.tcl`, `stp.sh` | the driver: `stp.sh stat`, `stp.sh src KEY CODE`, `stp.sh grab FILE Y0 YSTEP NY "X0 ..." XSTEP "PLANES"` |
| `mkpng.py`, `mkfig.py` | grabbed lines -> PNG; several screens in one figure (pure Python) |

## One run

```
bash tests/jtag_rig/setup.sh
cd tmp/jtagtest/work/AMenu/10cl025 && quartus_sh --flow compile AMenu      # and LSpectrum, L64, LTari, LTari800
quartus_cpf -c L.cof                                                       # the test flash image (rig in every image)
quartus_pgm -c USB-Blaster -m JTAG -o "ipv;output_files/L.jic"             # into the flash
quartus_pgm -c USB-Blaster -m JTAG -o "p;output_files/AMenu.sof"           # start the menu
bash tests/jtag_rig/stp.sh stat                       # ID 4D4E0002, 60.02 Hz, 25.208 MHz
bash tests/jtag_rig/stp.sh src 0 1E; bash tests/jtag_rig/stp.sh src 0 00   # key "1": the menu starts LSpectrum
bash tests/jtag_rig/stp.sh stat                       # ID 5A580001 now (a new image: a new JTAG session)
bash tests/jtag_rig/stp.sh grab zx.txt 33 2 240 "46" 2 "11 7 3"            # the picture, every 2nd line and pixel
python3 tests/jtag_rig/mkpng.py zx.txt zx.png 2 2
bash tests/jtag_rig/stp.sh src 1 00; bash tests/jtag_rig/stp.sh src 0 00   # KEY1: back to the menu
```

Key codes for the menu: `1E`..`21` = keys 1..4. Colour bits: 11..8 red, 7..4 green, 3..0 blue. Line and pixel numbers
count from the rising edges of the syncs (640 x 480: first line 33, first pixel 46; 800 x 600: 27 and 216).
After the test, program the product image again (`AMenu/10cl025/output_files/L.jic`).

For the C64 the test image needs the C64 ROMs in the flash (the ESP32 normally installs them): add
`L64/ep4_ce15/roms_local/c64roms.hex` at offset 5767168 (0x580000) to the scratch `L.cof`.

What the rig cannot test: everything behind the I/O board's connectors (keyboard, sound, joysticks, the ESP32 link,
the SD update) and the monitor itself.
