# Known issues (LSpectrum, L64)

Open problems seen on the hardware, plus design limitations. Not being fixed now (user, 2026-10-08).
L64 (the Commodore 64) has its own section below.

## Seen on the hardware

| # | Date | Issue | How often | Workaround | Probable cause (not confirmed) | Possible fix |
|---|---|---|---|---|---|---|
| 1 | 2026-10-08 | The SD card was not recognised ("No SD card, or not FAT16/FAT32") | once, not reproducible | Enter in the browser ("try again") | Card not ready yet when the firmware initialised it right after FPGA configuration (some cards need up to ~250 ms after power-up; CMD0 is retried only for a few ms). Or one failed sector read, which marks the card absent until a manual retry. | Firmware only (`LSpectrum/esp32_v2/src/esp_hw.cpp` `sd_init`, `main.cpp`): retry the full init 3-5 times over ~0.5 s before reporting no card; after a failed read, re-initialise and retry once. |
| 2 | 2026-10-08 | The keyboard did not work, from power-up: the 128K start menu was shown but ignored all keys | once, not reproducible | **KEY0 fixed it** (Ctrl+Alt+Del was not tried) | KEY0 resets the machine and the tape loader (ROM copy flash -> SDRAM again, CPU restart) but **not** the keyboard decoder (power-up reset only) and not the USB keyboard module, so the keyboard path was most likely fine. Candidates: (a) a bad ROM copy at power-up — the menu still draws but its keyboard code is damaged; `rom_loader` only checks the first byte; (b) a power-up-only start condition (CPU waits <= 1.5 s for the keyboard, SDRAM/video starting together); the 128K menu reads the keys from the 50 Hz interrupt, so a missing interrupt would also look like this (less likely: the picture, hence vsync, was there). | Next time, **before KEY0** try Ctrl+Alt+Del and F12: both are decoded by the FPGA, not the Spectrum software. They work = Spectrum side (a/b); they do not = keyboard path. Possible improvement: `rom_loader` verifies a checksum of the whole 48 KB copy and repeats the copy if it is wrong. |

If either happens again, note: power-up or after a reset, card type/size, keyboard model, whether Ctrl+Alt+Del / F12
still worked, whether KEY0 or only a power cycle helped, and what the screen/LED showed.

## Design limitations (by design or not done yet)

- Memory contention is emulated at Level 1 (2026-10-09: memory and I/O cycles, 128K timing; F5 switches it off);
  not the internal contended T-states of some instructions (DJNZ, PUSH, INC rr, ...). Floating bus emulated
  (2026-10-09, 128K timing, with contention; read point corrected 2026-10-11 to Fuse 1.6's: start of the I/O
  cycle's 4th T-state after its contention. Sidewize, Arkanoid and Cobra, which sync with it, work on the hardware). Not emulated: ULA snow (I register in 40-7F); DiagROM's snow test fails. The 50 Hz
  frame interrupt sits at VGA line 24, pixel 166, measured with Aquaplane's horizon stripe (calculated for a real
  128K: line 12.7; the ~11.5 lines between are most likely the missing Level-2 contention). Other border-effect
  games may need Page Up / Page Down (1/8 line steps, browser closed). In 60 Hz mode border effects cannot line up.
- AY output is mono (also on Bluetooth); MIC is not output (no tape saving).
- Bluetooth (ESP32, `LSpectrum/esp32_v2/`): controlled from the F3 menu (USB on the ESP32 is for debugging only); SBC latency
  ~150-250 ms (A2DP), so it suits music more than fast games. ESP-IDF 5.5 crashed when the headphones opened the
  stream themselves (Bose, 38/40 connects): fixed in the sketch by a link-time wrapper (`LSpectrum/esp32_v2/README.md`).
- Tape loader: TZX 0x19 (generalized data), 0x18 (CSW) and 0x28 (select block) are not played; text/message blocks
  are not shown; `LOAD ""` is not typed automatically; at most 320 entries per folder; long names cut to 27 characters;
  exFAT cards are not supported (format FAT32).
- Saving: only the ROM's standard format/speed is decoded (custom turbo savers are not); new files get 8.3 names;
  an existing name is refused (no overwrite); no file dates (no clock); switching off during a save can leave a lost
  cluster (a disk check on the PC fixes it).
- Block RAM: 19 of 56 M9K used (screen shadows 14, FIFOs, OSD font and text); 37 free.
- The ESP32 is needed for the SD card, the browser, saving, snapshots and Bluetooth; without it the Spectrum boots
  and runs, but F12 does nothing. KEY0 restarts the ESP32 (Bluetooth reconnects after a few seconds).
- Snapshots (.z80): the position inside the video frame is not saved (after a load the next interrupt comes at a
  different point of the frame); no .sna; an existing name is refused (no overwrite); 48K snapshots run on the
  128's 48 BASIC ROM with paging locked; +3 / Pentagon extras (1FFD, ...) are ignored.
- Tape loader in turbo: long runs of TZX 0x13 pulse sequences shorter than ~300 T-states could underrun (not seen
  in real files).
- Turbo stays on until the pause after the last block has played (TZX files with a long final pause keep the game
  at 28 MHz for a moment after loading). Possible fix: cut the final pause to 1 ms.
- At power-up the CPU waits up to 1.5 s for the first keyboard packet (so F1 is seen); with no keyboard attached the
  machine always starts after 1.5 s.

## L64: design limitations (by design or not done yet)

- Video: the picture goes through a frame buffer. At 60 Hz (power-up) every 5th C64 frame is shown twice, so smooth
  scrolling is very slightly uneven; F8 gives the C64's own 50 Hz (each frame once, one frame late). No NTSC machine.
- Turbo (F6, on by default) runs while the cassette or the 1541 motor runs: music or animation that a game plays
  while loading runs up to 4x too fast, and a game that keeps the drive motor running stays fast (F6 off). The
  picture, the SID and the TOD clock keep the real time, so a loader that times itself by the raster or the TOD
  gains less (or, rarely, may fail: F6 off).
- Snapshots (.a64): the 1541's state is not saved (save while the drive is idle); timers restart from their latch,
  the SID's notes restart, the CIAs' serial / TOD registers and the raster position are not restored; an NMI in the
  last few cycles of the restore program would be lost. Own format (not VICE .vsf); an existing name is refused.
- Disk: a disk change is signalled through the write-protect sensor (as a real disk sliding in); a loader that
  watches for the change some other way may not notice it. LOAD is typed only at the BASIC prompt.
- No cartridges, no REU, no 1541 fast-loader extras beyond what the real drive does; one drive (device 8).
- The C64 ROMs are not part of the project: without your own ROM files on the card the machine cannot start.

## Monitor compatibility (VGA output)

| Display | 640x480@60 | 576p50 (F8) | Notes |
|---|---|---|---|
| User's LCD monitor | works | works, shown as "800x600@50" | 576p centred vertically, sharp (2026-10-06). L64: 800x600@60 and its 50 Hz mode (1008x624, 31.26 kHz) both work (2026-10-28) |
| User's home TV (CVT Electronics "LCD TV", 2010, 40") | works | **not possible** | EDID (2026-10-09): analog input, EDID 1.3, no extension blocks; range limits V **59-71 Hz**, H 30-80 kHz, max pixel clock 150 MHz. The TV refuses any 50 Hz input. |

- 50 Hz needs a display whose VGA input accepts 50 Hz. Many TVs and PC monitors only take 60 Hz on VGA: their EDID lists
  only PC modes, with no CEA block (576p50 = VIC 17/18 is usually only offered on HDMI inputs).
- Hence the power-up default is 640x480@60 (since 2026-10-09). At 60 Hz the 50 Hz Spectrum frames are shown with every
  5th output frame repeated (slight judder in smooth scrollers; border effects cannot line up).
- Our 640x480 uses a 25.208 MHz pixel clock (60.02 Hz): CEA-861 VIC 1 is 25.200 MHz (60.00 Hz), VESA 25.175 MHz
  (59.94 Hz); both allow +-0.5 %. The TV's 59 Hz minimum is not an issue. Do not go below 59 Hz.
- HSYNC crosstalk (I/O board): the HSYNC edge couples onto the colour lines, a ~+-40 mV spike ringing for ~100 ns
  (scope, 2026-10-29). A monitor that auto-adjusts on a black screen can take it for the picture's right edge and
  show a coloured line one pixel after the picture (L64: 40 pixels of front porch squeezed into one column).
  L64 keeps the syncs off at each start until BASIC is on the screen, and drives HSYNC / VSYNC at 2 mA.
  Next board: a 47-100 ohm series resistor in HSYNC and VSYNC at the VGA connector.

## Resolved

- L64 started into a flashing-border screen after a game and Ctrl+Alt+Del, KEY0 did not help (2026-10-29):
  Krackout's reset protection (`CBM80` at $8004) stayed in the SDRAM, which keeps its contents through a
  reconfiguration. Fixed: the C64 RAM is cleared at every start.
- A .d64 loaded once and was broken afterwards (2026-10-28/29, Krackout: one track all FF): Ctrl+Alt+Del or KEY0
  during the drive write-back, the ESP32 read the gone FPGA as all ones (every sector dirty, data FF) and wrote that
  into the file. Fixed in the ESP32 (implausible status ignored, link checked before each sector is saved).
- The menu reported "reason 08" for L64 (2026-10-29): a .jic programmed without Verify had stopped 27 KB into
  the L64 image. Program with Verify (docs/L_Build_and_Install.docx).

- Saving split header and data into two files (2026-10-08, first save version): the automatic end-of-save after 3 s
  of tape time was hit by the ROM's 1 s pause between blocks (counted in real-time interrupts, 8x longer in turbo
  T-states). Replaced by recording mode, started and stopped explicitly (browser line, F12).
- "Ramparts (1988)(Go!).tzx" failed to load (2026-10-08): the downloaded file was broken; a copy from another site
  loads fine.
