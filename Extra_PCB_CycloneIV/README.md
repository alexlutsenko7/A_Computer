# Extra_PCB_CycloneIV — separate I/O board for the Cyclone IV board (QM_Atrix Extended)

KiCad 10 project for the ZX/retro I/O board, built as a **separate board** that connects to the QMTECH
Cyclone IV core board with short wires through one 2x32 pin header (J1). It is derived from the earlier QM_Atrix adapter and adds a 4-bit-per-colour VGA DAC, a second joystick port and a microSD socket.

**Revision 1** (these files): ordered from JLCPCB 2026-10-14 (`jlcpcb/`), delivered 2026-10-23, works on hardware
with all machines (LSpectrum, L64, LTari). J1 is wired to U8 with each pin pair swapped (below).
Design: schematic (SD card on the ESP32, ESP32 link on J1, J1 opposite the core board's U8, one
3.5 mm audio jack, volume pots removed; ERC clean). Placement reviewed by the user (J1 at the bottom edge against U8,
mounting holes H3/H4 moved up, jack J3 on the right edge, R31-R33 above the ESP32, U1 with a 15 x 12 mm reserved
courtyard, footprint `Module_7803_SIP-3_P2.54mm_Reserve15x12mm`). **Routed** with FreeRouting 2.5.0 (724 track
segments, 55 vias, no neckdown) + GND pours on F.Cu and B.Cu; the user then added ground stitching vias (271 vias in
all, 224 on GND). DRC: 0 unconnected, 0 clearance errors, 0 schematic parity issues; remaining: DB9 / jack bodies over
the board edge (silkscreen only). Net classes: Default 0.25 mm, Power_0.4 (+5V) 0.4 mm, Power_0.3 (+3V3, GND) 0.3 mm;
clearance 0.2 mm, vias 0.8/0.4 mm.

## Files

| Path | Role |
|---|---|
| `Extra_PCB_CycloneIV.kicad_pro` | Project (design rules copied from the QM_Atrix adapter: 0.25 mm tracks, 0.8/0.4 mm vias) |
| `Extra_PCB_CycloneIV.kicad_sch` / `.pdf` | Schematic (A3) and its plot |
| `Extra_PCB_CycloneIV.kicad_pcb` | Layout: 84.1 x 83.43 mm, 2 layers, routed, GND pours on F.Cu and B.Cu |
| `Extra_PCB_CycloneIV.kicad_sym`, `sym-lib-table` | Project symbols: DB15_Female_HighDensity, Conn_01x04_Male, 7803_switcing |
| `Extra_PCB_CycloneIV.pretty/`, `fp-lib-table` | Project footprints: DB15 VGA for CONNFLY DS1038-15F, ESP32 dev-board sockets, keyboard module (from the as-built adapter) |
| `jlcpcb/` | Order files of revision 1 (below); `jlcpcb/gerbers/` = the unpacked zip |
| `tools/` | Helper scripts used to generate, place and route the board, FreeRouting workflow, KiCad python notes (`tools/README.md`) |

## J1 — host connector (2x32 holes, wired to the core board's U8 with each pin pair swapped)

The board sits **beside** the Cyclone IV core board, level with it, its bottom edge against the core board's U8 edge.
J1 lies directly opposite U8 (pin 1 2.5 mm from the common right edge, pin 63 2.86 mm from the left edge, outer row
1.7 mm from this board's edge; U8: 1.7 mm from the core board's edge; core board 84.1 x 67.1 mm, same width as this
board). J1 is **not fitted** (DNP, no BOM entry): 64 plated holes for the user's wire link. Footprint
`Extra_PCB_CycloneIV:PinHeader_2x32_P2.54mm_Vertical_RowsSwapped` (standard header with the rows swapped). U7 is not used.

**Wiring: each pin pair is swapped**: J1 pin 2k-1 -> U8 pin 2k, J1 pin 2k -> U8 pin 2k-1 (J1.1 -> U8.2,
J1.2 -> U8.1, ...). The power pairs carry the same net on both pins, so power and ground stay correct; each signal
lands on the FPGA pin in the table below (the LSpectrum pin assignment, `../docs/BOARD_PINOUT.md`).

| J1 | wired to U8 | FPGA | Signal |
|---|---|---|---|
| 1 | 2 | - | GND |
| 2 | 1 | - | GND |
| 3 | 4 | - | (core board 3V3, not used) |
| 4 | 3 | - | (3V3, not used) |
| 5 | 6 | AB11 | (clock input only, not used) |
| 6 | 5 | AA11 | (not used) |
| 7 | 8 | AB13 | ESP_SCK (ESP32 D14 -> FPGA) |
| 8 | 7 | AA13 | ESP_MOSI (D13 -> FPGA) |
| 9 | 10 | AB14 | ESP_CS_N (D33 -> FPGA) |
| 10 | 9 | AA14 | ESP_MISO (FPGA -> D35) |
| 11 | 12 | AB15 | ESP_IRQ (FPGA -> D34) |
| 12 | 11 | AA15 | BT_BCLK (D26 -> FPGA) |
| 13 | 14 | AB16 | BT_LRCK (D25 -> FPGA) |
| 14 | 13 | AA16 | BT_DATA (FPGA -> D22) |
| 15 | 16 | AB17 | BT_TX (FPGA -> RX2/GPIO16) |
| 16 | 15 | AA17 | BT_RX (TX2/GPIO17 -> FPGA) |
| 17 | 18 | AB18 | KB_IN (J5.3) |
| 18 | 17 | AA18 | AUDIO_AY |
| 19 | 20 | AB19 | KB_OUT (J5.2) |
| 20 | 19 | AA19 | AUDIO_BEEP |
| 21 | 22 | AB20 | JOY1_UP |
| 22 | 21 | AA20 | JOY1_DOWN |
| 23 | 24 | Y21 | JOY1_LEFT |
| 24 | 23 | Y22 | JOY1_RIGHT |
| 25 | 26 | W21 | JOY1_FIRE |
| 26 | 25 | W22 | JOY2_UP |
| 27 | 28 | V21 | JOY2_DOWN |
| 28 | 27 | V22 | JOY2_LEFT |
| 29 | 30 | U21 | JOY2_RIGHT |
| 30 | 29 | U22 | JOY2_FIRE |
| 31-44, 46, 48 | 31-44, 45, 47 | | spare (not connected) |
| 45 | 46 | H21 | VGA_VS |
| 47 | 48 | F21 | VGA_HS |
| 49 | 50 | E21 | VGA_R3 (MSB) |
| 50 | 49 | E22 | VGA_R1 |
| 51 | 52 | D21 | VGA_R2 |
| 52 | 51 | D22 | VGA_R0 (LSB) |
| 53 | 54 | C21 | VGA_G3 |
| 54 | 53 | C22 | VGA_G1 |
| 55 | 56 | B21 | VGA_G2 |
| 56 | 55 | B22 | VGA_G0 |
| 57 | 58 | N19 | VGA_B3 |
| 58 | 57 | N20 | VGA_B1 |
| 59 | 60 | M19 | VGA_B2 |
| 60 | 59 | M20 | VGA_B0 |
| 61 | 62 | - | GND |
| 62 | 61 | - | GND |
| 63 | 64 | - | +5V (VIN) |
| 64 | 63 | - | +5V (VIN) |

All signals 3.3 V.

## Circuits

- **Connector parts (JLCPCB/LCSC, Extended)**: VGA J2 = CONNFLY DS1038-15FBNSiA74-0CC (C75754, pins 2.29 x 2.54 mm, rows
  8.63/11.17/13.71 mm behind the front plate, which is flush with the board edge); joysticks J4/J6 = CONNFLY
  DS1037-09MNAKT74-0CC (C75750) on the KiCad P2.77x2.84 EdgePinOffset7.70 footprint (the part's rows are 0.4 mm deeper:
  its flange ends 0.4 mm past the board edge, holes all line up).
- **VGA (J2, DB15 HD female)**: per colour a binary-weighted DAC, R3..R0 = 523 / 1.05k / 2.1k / 4.22k (1 %), into the
  monitor's 75 Ohm: 0.70 V full scale, 15 steps of ~47 mV (4096 colours). 6p8 to GND on each colour line and on HS/VS
  (FPGA side), 22 Ohm series on HS/VS. Pins 5-8 and 10 + shell to GND. Designs with 2-bit colour drive the two MSBs
  (R3/R2 etc.) and hold the LSBs low.
- **Joysticks (J4, J6, standard right-angle DB9 male)**: footprint `DSUB-9_Pins_Horizontal_P2.77x2.84mm_EdgePinOffset7.70mm_Housed_MountingHolesOffset9.12mm`
  (pins 7.7 mm from the board edge, 25 mm mounting holes; shell/mounting holes to GND). Atari/Kempston pinout:
  1 Up, 2 Down, 3 Left, 4 Right, 6 Fire, 8 GND, 3k3 pull-ups to 3.3 V. Pins 5, 7, 9 not connected.
- **microSD (J7, Molex 104031-0811)**: on the ESP32 (D18 SCK, D19 MISO, D23 MOSI, D5 CS), SPI mode, 10k pull-ups on CS (DAT3), CMD, DAT0, DAT1, DAT2; 100 nF + 10 uF
  at the socket; card-detect pads (9/10) not connected. Card slot at the left board edge (card overhangs it by ~3 mm).
- **Audio out (J3, 3.5 mm jack, Hroparts PJ-320D-4A, LCSC C95562, opening at the right edge)**: AY: 68 Ohm + 100 nF
  low-pass, 10 uF coupling, 2.2k; beeper: 10 uF coupling, 2.2k; both into one node with 1k to GND, to the tip and
  ring 1 (mono on both channels of a stereo plug); ring 2 and sleeve to GND. Line level, about 0.75 V peak-to-peak per
  source at full swing into 10k, output impedance ~600 Ohm: for an amplifier with its own volume control, not for
  headphones directly. A quieter beeper: raise R32 (3.3k-4.7k).
- **Keyboard (J5, USB-HID -> UART module)**: 1 GND, 2 KB_OUT, 3 KB_IN, 4 +5 V; UART levels 3.3 V.
- **ESP32 system controller (U2)**: ESP32-WROOM-32 dev board, 30 pins (DOIT DEVKIT V1 pinout, CP2102, USB-C), plugged into
  two 1x15 female sockets 25.4 mm apart (footprint `Extra_PCB_CycloneIV:ESP32_DevKit_30pin_Socket`; courtyard = socket rows only,
  low parts sit under the module; module outline on F.Fab). VIN <- +5V, GND x2; D26/D25/D22 = I2S BCLK/LRCK/DATA,
  RX2/TX2 = control UART, D14/D13/D33/D35/D34 = SPI link + IRQ to the FPGA, D18/D19/D23/D5 = microSD (see
  `../LSpectrum/esp32_v1/README.md`). The module's 3V3 pin is not connected.
- **Power**: +5 V from J1 (core board VIN, U8.63/64) feeds the keyboard module and U1, a small 7803 switching module (SIP-3,
  2.54 mm, 1 = in, 2 = GND, 3 = out) -> +3.3 V for the pull-ups and the SD card. 10 uF at U1 in/out, 100 nF x3 on
  3.3 V, x2 on 5 V. Do not connect the host's 3V3 to this board.
- 4 x M3 mounting holes (H1, H3, H4, H5).

## JLCPCB order files (`jlcpcb/`, made by `tools/jlc_export.py`)

| File | Use |
|---|---|
| `Extra_PCB_CycloneIV_gerbers.zip` (`gerbers/`) | PCB order: Gerbers (2 layers, mask, paste, silk, outline, Protel extensions) + Excellon PTH / NPTH drill files |
| `Extra_PCB_CycloneIV_BOM.csv` | Assembly BOM (Comment, Designator, Footprint, LCSC Part #) |
| `Extra_PCB_CycloneIV_CPL.csv` | Assembly placement (Designator, Mid X, Mid Y, Layer, Rotation) |

Re-run `python3 tools/jlc_export.py` (WSL) after any change. Not fitted (DNP, no BOM / placement entry): J1 (host
holes, wired by hand), U2 (ESP32 DevKit, plugs into sockets), J5 (keyboard module); the mounting holes. Fitted: 56
parts, all top side. THT parts in the BOM (JLCPCB THT assembly): J2, J4, J6 (D-Sub), U1 (YLPTEC K7803-500R3,
C5369643: 4.75-36 V in, 3.3 V / 0.5 A, 11.5 x 7.55 x 10.2 mm SIP, pins 1 Vin 2 GND 3 Vo), C8, C9, C10. Extended (non-basic) LCSC parts: the 1 % DAC resistors 523 / 1.05k / 2.1k /
4.22k, 68 Ohm, 6p8, the THT capacitors, the connectors and U1. Check part rotations in JLCPCB's placement preview
(connectors especially) before ordering. The U2 sockets (2 x 1x15 female, 2.54 mm) are not in the BOM.

## Layout notes

- Edge connectors: both DB9 along the top edge, VGA and microSD on the left edge (connector fronts overhang the
  edges), J1 at the bottom edge (facing the core board's U8), the audio jack on the right edge; the keyboard module sits on its 4 header pins
  and its own board (with the USB socket) overhangs the right edge by ~24 mm.
- DAC resistors and the 6p8 caps sit right next to the VGA socket, keeping the colour traces short.
- Joystick pull-ups sit under their DB9 pins in pin order, so the DB9 -> resistor traces run straight without crossing.
