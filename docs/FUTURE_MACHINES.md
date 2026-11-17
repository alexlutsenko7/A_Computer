# Future machines: ideas (discussion of 2026-11-13)

Notes of a discussion about which machines could follow LSpectrum, L64 and LTari. Nothing here is decided or
started. Sizes and "fits" are estimates from general knowledge of the machines and of existing cores, not measured
on this project. The DB9 wiring in section 5 was read from the KiCad boards and is a fact.

**2026-11-17:** the NES (LNES, both core boards) and the Sega Mega Drive (LMega, 10CL025 only) were built from
sections 5-12; what was done differently is in `docs/PLAN.md` (entry of that date): the NES got a frame buffer
with a frame-rate-matched clock instead of a line doubler, the flash layout is the three 2 MB machine positions
of 2026-11-16 (section 9 still describes the 1 MB slots), and the Mega Drive's line doubler counts its output
pixels with a fraction counter so that they fall on the monitor's pixels.

Limits of the platform that decide everything below:

- EP4CE15: 15,408 LEs (L64 uses 97 %). 10CL025: 24,624 LEs, the same logic size as the MiST board's FPGA.
- Flash: two free 1 MB slots, 0x600000 and 0x700000.
- 32 MB SDRAM, 4-bit-per-colour VGA (4,096 colours), two DB9 ports, keyboard over the UART, ESP32 with the SD card.
- ROM licensing: nothing that is not free goes into the repo or `L.jic`; the ESP32 installs such ROMs from the SD card.

## 1. Other 8-bit machines

### Z80 (reuse T80, JT49, the SDRAM bridge)

| Machine | New hardware | Effort | ROMs |
|---|---|---|---|
| Spectrum 48K, Pentagon 128, Scorpion, +3 | timing variants; WD1793 (TR-DOS) or uPD765 (+3) | small, modes of LSpectrum, no new slot | Amstrad's OK; clone ROMs unclear |
| ZX80 / ZX81, Jupiter Ace, Galaksija | almost nothing | very small | mixed |
| Amstrad CPC 464 / 6128 | 6845 CRTC, gate array, 8255, uPD765 for .dsk | medium | Amstrad has allowed emulator distribution (verify the wording) |
| MSX1 | TMS9918, 8255, cartridge mappers | medium | C-BIOS is free |
| MSX2 | V9938 on top of MSX1 | large | C-BIOS |
| Sega Master System / SG-1000, ColecoVision | VDP, SN76489 | medium | SMS needs no BIOS; Coleco BIOS is proprietary |
| Game Boy / Game Boy Color | PPU, APU (T80 has an LR35902 mode) | medium | runs without the boot ROM |
| Sam Coupe, Enterprise, TRS-80, Sharp MZ, CP/M machines | varies | small to large | varies |

### 6502 (reuse T65, CIA / VIA, the 1541, the frame buffer)

| Machine | New hardware | Effort | ROMs |
|---|---|---|---|
| VIC-20 | VIC 6560 only; the VIAs and the 1541 exist | small | from SD, like L64 |
| Atari 5200 | same ANTIC / GTIA / POKEY as LTari, other memory map | small; analog sticks are a problem | Altirra 5200 BIOS is free |
| Atari 2600 | TIA, RIOT | small; DB9 sticks are native | none needed |
| Atari 7800 | MARIA | medium | BIOS optional |
| NES / Famicom | PPU, APU, mappers | medium to large (mappers never end) | none needed |
| Apple II / IIe | simple video, Disk II | small to medium | proprietary, from SD |
| BBC Micro B | 6845, video ULA, SAA5050, SN76489, FDC | medium | proprietary, from SD |
| Oric, Acorn Electron / Atom, PET | little | small | proprietary |
| C16 / Plus/4 | TED | medium | from SD |

### Needs a new CPU core

- 6809: Dragon 32/64, Tandy CoCo, Thomson MO5 / TO7 (simple machines around an MC6847).
- 8080: Radio-86RK, Vector-06C, Altair, Space Invaders-class arcade boards (T80 has an 8080 mode).

### Poor fits

- C128: two CPUs plus the VDC do not fit beside what L64 uses on the EP4CE15; perhaps on the 10CL025.
- Vectrex: needs a vector display. PC Engine: probably 10CL025 only.

### Picks for the two free slots

1. Amstrad CPC 6128: most reuse (T80, JT49, .dsk through the ESP32), large library, cleanest ROM situation after
   the Spectrum.
2. NES (no ROMs to license, T65, DB9 pads) or MSX1 with C-BIOS if a computer is preferred.

Cheap extras: the Pentagon (no slot), the VIC-20 (could share a slot if the two LTari revisions were merged).

## 2. Apple II / IIe

| Model | Year | CPU | RAM | Adds |
|---|---|---|---|---|
| Apple II | 1977 | 6502, 1.02 MHz | 4-48 KB | Integer BASIC, 8 slots |
| Apple II+ | 1979 | 6502 | 48 KB (64 KB with the language card) | Applesoft BASIC, autostart ROM |
| Apple IIe | 1983 | 6502 | 64 KB, 128 KB with the auxiliary card | lowercase, 80 columns, double hi-res, MMU + IOU chips |
| Enhanced IIe | 1985 | 65C02 | 128 KB | fixed ROMs, MouseText |

Inside:

- CPU clock 14.318 MHz / 14; every 65th cycle stretched: 65 cycles per line, 262 lines, 17,030 cycles per frame,
  59.92 Hz.
- Video: no video chip, counters reading RAM. Text 40x24, lo-res 40x48 in 16 colours, hi-res 280x192 (7 pixels per
  byte, bit 7 shifts the byte half a pixel). IIe: 80 columns and double hi-res 560x192 in 16 colours by interleaving
  main and auxiliary memory. No sprites, no raster interrupt, no hardware scroll.
- Colour is an NTSC artifact: the core decodes it (sliding 4-bit window over the 14 MHz bit stream -> 16 colours),
  plus a monochrome mode.
- Sound: speaker toggled by any access to $C030. Keyboard: ASCII in a latch at $C000 with a strobe bit.
- Paddles: analog (558 timer read by a timing loop); digital DB9 sticks return minimum / centre / maximum times.
- Soft switches: $C000-$C0FF; each slot has 16 I/O addresses and 256 bytes of ROM.

Disks:

- Disk II: shift register + small state machine + four stepper phases; software does the encoding. 35 tracks,
  140 KB, 6-and-2 GCR, 4 us bit cells. No second CPU: much lighter than the 1541. `.dsk` / `.do` / `.po` = plain
  sectors (143,360 bytes), the ESP32 makes the nibble stream per track and decodes writes; `.woz` = raw bit stream
  for copy-protected originals.
- Hard disk card: ProDOS block device with a tiny slot ROM driver, images up to 32 MB (`.hdv`, `.po`, `.2mg`);
  almost free with the ESP32. Collections such as Total Replay put hundreds of games on one image.

Fit: T65 (65C02 mode), the SDRAM bridge, the ESP32 disk path and the menu are reused. Mockingboard = two 6522 + two
AY-3-8910: both exist here. 262 lines doubled = 524, one short of VGA's 525: a line doubler at 28.636 MHz should do
without a frame buffer (picture about 3/4 of the width). Size estimate: well under LSpectrum's 7,700 LEs. Turbo is
easy but must drop to 1x while the disk motor runs. A Z80 SoftCard (CP/M) is realistic with T80.

Catches: ROMs (section 3); heavy copy protection (cracked `.dsk` cover most, originals need `.woz` and accurate
drive timing); some software reads the floating bus; PAL machines existed but nearly all software assumes NTSC.

What to build: an enhanced IIe with 128 KB (superset), Disk II in slot 6, hard disk in slot 7, Mockingboard in
slot 4. First stage: a II+ with 64 KB (boots DOS 3.3 and most games before 1984).

## 3. Apple II ROM files

Easy to find, none licensed: Apple never released the firmware and Applesoft is also Microsoft's code. There is no
licensed package like C64 Forever.

- AppleWin carries the images in its source repository (tolerated, not permitted). The Asimov archive and
  archive.org have every revision. MAME's sets name them by Apple part number (good for checksums).
- A dump of one's own machine is the only clearly entitled source.
- Printed listings (Apple's reference manuals, Sather's "Understanding the Apple II") are a specification, not a
  licence.

| File | Size | Contents | Avoidable? |
|---|---|---|---|
| II+ system ROM | 12 KB | Applesoft ($D000-$F7FF) + Autostart Monitor ($F800-$FFFF) | no |
| IIe CD + EF ROMs (enhanced: 342-0304 / 342-0303) | 16 KB | same + 80-column and self-test firmware | no |
| Video (character) ROM | 2 KB II+, 4 KB IIe | font, MouseText | yes: own font |
| Keyboard ROM | 2 KB | key matrix to ASCII | yes: not needed |
| Disk II P5 boot PROM (341-0027) | 256 bytes | loads track 0 sector 0 | yes: own boot loader |
| Disk II P6 PROM (341-0028) | 256 bytes | sequencer state table | yes: logic from Sather's description |

Part numbers are from memory: check against a MAME listing. Only the 12 / 16 KB system ROM cannot be replaced; the
ESP32 would install it from the SD card as for L64. Manual wording: copies you are entitled to (own dump).

## 4. 16-bit machines

| Machine | CPU | EP4CE15 | 10CL025 | ROMs |
|---|---|---|---|---|
| Sinclair QL | 68008 | yes | yes | Minerva is free; check the original ROMs' status |
| TI-99/4A | TMS9900 | yes | yes | TI's, proprietary |
| BK-0010 / 0011M | PDP-11 (K1801VM1) | yes | yes | Soviet, unclear status |
| Intellivision | CP1610 | yes | yes | proprietary |
| IBM PC/XT (CGA, Tandy) | 8088 | probably | yes | open BIOSes exist (e.g. GLaBIOS), FreeDOS |
| Macintosh Plus | 68000 | tight | yes | Apple's, proprietary |
| Atari ST / STE | 68000 | tight | yes | EmuTOS is free |
| Amiga 500 (OCS / ECS) | 68000 | very tight | yes | Kickstart licensed (Amiga Forever); AROS a free partial substitute |
| Sega Mega Drive | 68000 + Z80 | no | yes | none needed |
| Apple IIgs | 65C816 | no | probably | Apple's, proprietary |
| SNES | 65C816 | no | tight, no cartridge co-processors | none needed |
| Neo Geo, X68000, 386+ PCs | | no | no | |

What changes against the 8-bit machines:

- A 68000 core is about 5,000-6,000 LEs (FX68K cycle-exact, TG68K faster and not exact; both GPL).
- `sdram_ram.v` is byte-wide with a 256 KB window: these machines want 16-bit access and 1-8 MB (a 16-bit variant;
  the chip is 16-bit already).
- Mouse: Amiga, ST, Mac, QL need one. The CH9350L on the rev 2 I/O board can report a USB mouse; rev 1 has no path.
- Video: 4,096 colours match the Amiga OCS and the STE exactly; the SNES's 15-bit colour would be truncated.
- Disks: `.adf` / `.st` from the ESP32 like `.d64` / `.atr`; hard disk images are block devices.
- A 10CL025 image fits a 1 MB slot.

Picks: (1) Atari ST with EmuTOS on the 10CL025 (free ROM, modest hardware, YM2149 = JT49); (2) Amiga 500 on the
10CL025 (the showpiece, much larger chipset job, Kickstart from SD); (3) QL or TI-99/4A for a machine on both boards.

## 5. Sega Mega Drive: the controller

The pad is not passive: a 74HC157 multiplexer, powered by the console and steered by a select line (TH).

| DB9 pin | Select high | Select low | I/O board J4 / J6 (rev 1 and rev 2, from the KiCad boards) |
|---|---|---|---|
| 1 | Up | Up | JOYn_UP, 3k3 pull-up |
| 2 | Down | Down | JOYn_DOWN |
| 3 | Left | low | JOYn_LEFT |
| 4 | Right | low | JOYn_RIGHT |
| 5 | +5 V | +5 V | not connected |
| 6 | B | A | JOYn_FIRE |
| 7 | Select (from the console) | Select | not connected |
| 8 | Ground | Ground | GND |
| 9 | C | Start | not connected |

- 3-button pad: the game toggles select and reads both halves; Left and Right both low = "Mega Drive pad".
- 6-button pad: on the third select pulse within about 1.5 ms, pins 1-4 return Z, Y, X, Mode.
- The console has no controller logic: each port is a 7-bit I/O register driven by the game.

With the ports as they are: a Mega Drive pad does not work (no power, no select). An Atari-style stick gives the
directions + one button. A Master System pad (passive) gives directions + button 1 (button 2 is on pin 9).

Real pads would need per port: pin 5 to a supply, pin 7 to an FPGA output, pin 9 to an FPGA input with 3k3 pull-up
= four FPGA signals for two ports. J1 pins 31-44 are free (not 35 / 36: N22 / N21 = DEV_OE / DEV_CLRn on the
EP4CE15). The three DB9 pins are unconnected through-hole pads: a wire modification. Voltage: a pad on 5 V drives
5 V into pins that do not tolerate it; either power the pad from 3.3 V (74HC157 works from 2 V, commonly done; some
third-party pads and wireless receivers need 5 V) or keep 5 V and add level shifting on the six inputs.

### The user's approach (no board change)

Existing stick for the four directions + one button, the other buttons on the keyboard. The select line stays
inside the FPGA and the core builds the pad's answer:

- Select high: Up, Down, Left, Right, B, C. Select low: Up, Down, two forced lows, A, Start.

| Pad button | Source |
|---|---|
| Up, Down, Left, Right | DB9 stick (cursor keys as a second source) |
| B | DB9 fire |
| A, C | two keys, e.g. `A` and `D` (`S` as a second B) |
| Start | Enter |

- A menu entry (like LSpectrum's F4 joystick menu) could select A, B or C for the fire line.
- Second player: the second DB9 stick + its own keys.
- 6-button pad: four more keys + the pulse counter with its timeout; start with the 3-button pad.
- Limit: games needing two action buttons at once mean one hand on the stick and one on the keyboard.
- Wiring pins 5, 7, 9 for real pads can come later: the port register stays, only the source of the bits changes.

## 6. Mega Drive: loading games

A cartridge is only a ROM: loading = copy one file into SDRAM and release reset. No tape player or drive to emulate.

1. Pick the file in the ESP32's browser.
2. The ESP32 holds the 68000 in reset and streams the file over the SPI link into the cartridge region of the SDRAM.
3. Reset is released; the game starts as if the cartridge had been plugged in.

Most games are 0.5-2 MB, the largest ordinary ones 4 MB: a few seconds at the link's 8 MHz (estimate from the bit rate).

- Formats: `.bin` / `.md` / `.gen` plain; `.smd` has a 512-byte header and interleaved 16 KB blocks (the ESP32
  untangles it).
- Cartridge header at $100: name, region codes, save-RAM range: the ESP32 sets things up from it.
- Region and 50 / 60 Hz: from the header, with a menu override (some games refuse the wrong region).
- Battery saves (8-64 KB): RAM mapped by the core, written back to a `.sav` file like the `.d64` write-back.
- Not free: serial-EEPROM saves (per-game wiring), games over 4 MB with a mapper (Super Street Fighter II),
  cartridge DSP (Virtua Racing: out of reach). Sega CD and 32X are separate machines and do not fit.
- No BIOS: early consoles have none, the later licence check (TMSS) is simply left out.
- The console's Master System compatibility mode could load `.sms` files the same way if the core implements it.

## 7. Super Mario

Nintendo's: no official Mario game on the Mega Drive. Each game needs the core of its own machine.

| Game | Machine | Cartridge hardware | Board (estimate) |
|---|---|---|---|
| Super Mario Bros. | NES | plain ROM, 40 KB, no mapper | both |
| Super Mario Bros. 2 and 3 | NES | MMC3 | both |
| Super Mario Land 1 and 2 | Game Boy | MBC1 | both |
| Super Mario World, All-Stars | SNES | plain ROM | 10CL025 only, tight |
| Super Mario Kart | SNES | DSP-1 in the cartridge | unlikely |
| Yoshi's Island, Super Mario RPG | SNES | Super FX 2 / SA-1 | no |

SMB4MD ("Super Mario Bros. for Mega Drive"): unofficial fan port by Mairtrus (Argentina), 2010; the NES program
translated to 68000 (the author: at least 75 % of the code untouched, so the original's bugs carry over); music on
the Mega Drive's sound chip. At release it ran only in emulators, not on a real console (later fix not checked):
an accurate FPGA core behaves like the console, so it may not run and is a poor test of a core. Ordinary cartridge
image otherwise. Unlicensed Nintendo code, graphics and music: never in the repo or on a distributed SD image.
Sources: Kotaku and SEGAbits articles of July 2010.

## 8. NES

| Part | What it is |
|---|---|
| CPU | Ricoh 2A03: 6502 without decimal mode + sound + controller ports; 1.79 MHz (NTSC), 1.66 MHz (PAL) |
| RAM | 2 KB work RAM, 2 KB video RAM, 256 bytes sprite table, 32 bytes palette |
| Video (PPU 2C02) | 256x240, 341 dots x 262 lines, 60.1 Hz (PAL 312 lines, 50 Hz); 3 dots per CPU cycle (NTSC) |
| Sound (APU) | two pulse, triangle, noise, 1-bit delta sample channel that steals CPU cycles |
| Controllers | two pads, 8-bit shift register each: A, B, Select, Start, Up, Down, Left, Right |
| System ROM | none |

- Background: 8x8 tiles, 2 bits per pixel, 32x30 map; colour per 16x16 area: one of four palettes of three colours
  + a shared backdrop. Sprites: 64, 8x8 or 8x16, eight per line, four palettes.
- Smooth scrolling through two internal address registers that games also rewrite in mid-frame.
- Vertical blank interrupt and the "sprite 0 hit" flag; no raster interrupt.
- Palette: 64 entries defined only as composite signals: a lookup table to RGB.

Cartridges carry the program ROM, the tile ROM or RAM and usually a mapper:

| Mapper | Adds | Examples |
|---|---|---|
| 0 (NROM) | nothing | Super Mario Bros., Donkey Kong |
| 1 (MMC1) | banking, save RAM | Zelda, Metroid |
| 2, 3 (UxROM, CNROM) | simple banking | Mega Man, Contra |
| 4 (MMC3) | banking, scan-line interrupt | Super Mario Bros. 2 and 3 |

These five cover the large majority of the licensed library; there are hundreds more. A `.nes` file has a 16-byte
header (ROM sizes, mapper number, tile map layout, battery).

Fit: T65 with decimal mode disabled (T65 is an unchanged copy here: check for a switch, else a modified copy);
everything in SDRAM (about 21 system clocks per dot at 112 MHz); APU into the existing DAC and Bluetooth path;
pads are not DB9 (stick + three keys); 8 KB battery RAM to a `.sav` file; probably 5,000-7,000 LEs with the five
mappers, both boards. Clean-room: the NESdev wiki documents PPU and APU to the cycle, and free test ROMs report
pass / fail on screen (usable in simulation).

Hard parts: PPU timing (sprite 0 hit, mid-line scroll changes, the MMC3 interrupt counting edges of a PPU address
line), the sample channel's cycle stealing, the number of mappers, the Japanese extras (Famicom Disk System needs
Nintendo's 8 KB BIOS from SD; cartridges with extra sound chips, one of them an AY variant JT49 covers).

## 9. NES and Mega Drive in the flash

Both fit: the two free 1 MB slots, NES at 0x600000 and Mega Drive at 0x700000; neither needs ROMs in flash. After
them the 8 MB flash is full.

- Image size is fixed per FPGA (from the `L.map` files): 511 KB on the EP4CE15, 719 KB on the 10CL025.
- Each board has its own flash and `L.jic`; the Mega Drive fits only the 10CL025 (estimate), so slot 7 on the
  EP4CE15 board stays empty or takes another machine.
- A further machine needs a slot freed: merge the two LTari revisions (800 / 130 selected at start). Halving the
  slots is not possible (the 10CL025 image is larger than 512 KB).
- Work as for LTari: menu entries, core IDs, `L.cof`, `LUPDATE.BIN`, the generated 10CL025 project files.

## 10. Video: resolution and colour depth

| | NES | Mega Drive |
|---|---|---|
| Resolution | 256x240 | 320x224 (most games) or 256x224; PAL adds 240-line modes |
| Lines per frame | 262 (PAL 312) | 262 (PAL 313) |
| Frame rate | 60.1 Hz (PAL 50.0) | 59.9 Hz (PAL 49.7) |
| Master palette | 64 entries, about 54 distinct | 512 colours (3 bits per channel) |
| On screen at once | 25 | 61, more with shadow / highlight |
| Tiles | 8x8, 4 colours | 8x8, 16 colours |
| Layers | one background, 64 sprites | two scrolling backgrounds, a window, 80 sprites |
| Sprites per line | 8 | 20 |

The 4-bit-per-colour DAC is enough for both: the NES palette is a lookup table (slightly rounded; the three
emphasis bits make it eight times larger); the Mega Drive needs 3 bits per channel and the shadow / highlight
levels need the fourth.

VGA by a line doubler (each console line sent twice at double speed):

- 262 lines -> 524 (VGA has 525); NES 240 -> exactly 480; Mega Drive 224 -> 448 with small borders.
- The picture takes about 3/4 of each line (VGA: 4/5): nearly full width, original 4:3 shape, no scaling.
- The monitor runs at the console's own frame rate: smooth scrolling, no dropped or repeated frames (the advantage
  over the L64 frame buffer for scrolling games).
- PAL: 312 / 313 lines doubled land on 576p's 625.
- Cost: one line of pixels in block RAM. The doubled pixel clock should come from a PLL, not from a clock enable.

## 11. Frame buffer on the 10CL025

It exists there already: the L64 and LTari builds for the 10CL025 use the triple frame buffer in SDRAM (`c64_fb.v`,
`atari_fb.v`) and showed pictures through the JTAG rig on 2026-11-11.

| | L64 today | Mega Drive |
|---|---|---|
| Stored picture | 400x284 | 320x240, or 320x480 interlaced |
| Bits per pixel | 4 (colour index) | 12 (final colour: games change the palette in mid-frame) |
| Pixels per 16-bit word | 4 | 1 |
| Words per frame | 28,400 | 76,800 (153,600 interlaced) |
| Three buffers | 384 KB reserved | 461 KB (922 KB interlaced) |

Space and logic are no problem. The SDRAM traffic is: about 9 million word accesses a second beside the 68000,
the Z80 and the video chip's memory; one word per access gives roughly 20 million a second at 112 MHz at best, so
it needs fixed time slots as in L64 and has little margin. Burst access in the controller would make it comfortable.

Only a frame buffer gives: 800x600 output, the Print Screen screenshot (held buffer), a steady interlaced picture.

## 12. Mega Drive interlace (the user: this may be mandatory)

- Mode 1: the same 224 lines in both fields, only the timing is interlaced: shown as a normal picture.
- Mode 2: 320x448, tiles 8x16, each field carries every other line; the video chip must implement it whatever the
  display. Rare: the two-player screens of Sonic 2 and Combat Cars.
- An interlaced field is 262.5 lines: doubled = exactly 525, a standard VGA frame (PAL 312.5 -> 625 = 576p).

| | Doubler with field offset ("bob") | Frame buffer ("weave") |
|---|---|---|
| How | each field line-doubled, the odd field one VGA line lower | both fields stored into one 320x448 picture |
| Extra hardware | none | three buffers in SDRAM (922 KB) + the traffic |
| Still picture | full detail, 30 Hz shimmer on fine horizontal edges | full detail, steady |
| Moving picture | clean, every field at 60 Hz | comb-shaped tearing |
| SDRAM load | none | about 13 million word accesses a second: needs burst access |

One field does not fit block RAM (320x224x12 bits = about 860 kbit; the 10CL025 has about 594 kbit).

Proposal: the doubler with the field offset first (interlace at no cost, smooth scrolling); a frame buffer later if
the shimmer bothers. To check on the monitor: a game switching between normal and interlaced mode changes the frame
between 524 and 525 lines.
