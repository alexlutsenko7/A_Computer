# Extra_PCB_CycloneIV_R2 — I/O board, revision 2

KiCad 10 project for the second revision of the L I/O board (revision 1 = `../Extra_PCB_CycloneIV/`, as built).
The board sits beside the QMTECH Cyclone IV core board and is wired to its U8 through J1, exactly as revision 1
(same J1 pinout, same pair-swapped wiring), so the FPGA images do not change. The ESP32 firmware is
`LSpectrum/esp32_v2` (control UART on other pins, PSRAM build).

J1 also fits the **QMTECH Cyclone 10 LP 10CL025 core board** (10CL025YU256, schematic V1 2023-11-09). The board is the
same size (84.1 x 67.1 mm), and its U8 sits at the same place and the same way round: pin 1 at the left end of the outer
row, VIN at the right end. Its U8 power pins match (1/2 GND, 3/4 3V3, 61/62 GND, 63/64 VIN), except that pins **5/6 are
GND** on the 10CL025 (clock inputs on the EP4CE15). J1 leaves 5/6 unconnected, and they must stay that way. U8 pins 7-60
are all 3.3 V I/O on both boards. The 10CL025 needs its own FPGA pin list (other ball names).

Status (2026-11-03): **schematic** generated from `tools/design.py`, drawn with wires, then edited in KiCad (the KiCad
schematic is the source of truth; `tools/check_net.py` checks it against `design.py`). **PCB: 4 layers, placed and fully
routed**: DRC 0 unconnected, 0 clearance errors, 0 schematic parity issues; only silkscreen text warnings left (reference
texts not tidied yet). The KiCad board is the source of truth (mounting holes moved by the user). Placement backup
(before routing): `archive/2026-11-03_before_routing/`.

## Board rules and checks

- Copper to board edge 0.3 mm (JLCPCB); the microSD socket J7 sits 0.25 mm inside the left edge for this.
- No vias inside small SMD pads; vias only in the large GND pads of U2 (pad 39) and U3 and in U1's tab.
- Silkscreen references 0.8 mm / 0.13 mm, each beside its part (`tools/silk.py`), connector outlines clipped at the
  board edge (DRC therefore notes "footprint differs from library" for J2-J6).
- The ESP32-WROVER-E footprint matches the datasheet land pattern (Fig. 15): pad size, pitch, pin 1 / pin 19 and
  GND pad position.
- Checks: ERC 0 / 0, `tools/check_net.py` PASS, DRC 0 errors, 0 unconnected, 0 schematic parity issues.

## Parts choice

All resistors and small capacitors are JLCPCB **Basic** parts (no per-line fee): the VGA DAC is 510 / 1k / 2k / 4.7k per
colour (full scale 0.71 V into 75 Ohm, steps even within about 0.2 LSB), 10p C0G on the VGA lines, 100 Ohm in the AY
low-pass (16 kHz with 0.1 uF). Extended parts: ESP32-WROVER-E, CP2102N, CH9350L, LDL1117S33R (kept over the Basic
AMS1117 for its lower dropout and better PSRR), USBLC6-2SC6, PTS810 buttons, and the connectors. USB-A J8 / J9:
SOFNG USB-302-T (C112456; datasheet `../docs/vendor/SOFNG_USB-302-T_C112456.pdf`, hole pattern identical to the DS1095
footprint). Older states of the board and its order files are in `archive/` (the ordered set: `archive/2026-11-03_as_ordered/`).

## JLCPCB order files (`jlcpcb/`, made by `python3 tools/jlc_export.py` in WSL)

Gerbers for 4 layers (F.Cu, In1.Cu GND, In2.Cu +3V3, B.Cu) + drill, BOM and CPL with LCSC numbers checked 2026-11-03
(identity checked on lcsc.com / jlcpcb.com; stock shows in JLCPCB's BOM check). Order: 4 layers, 1.6 mm, default
stack-up; option "via in pad, epoxy filled + capped" for the vias in the ESP32 / CP2102N centre pads. Check part
rotations in JLCPCB's placement preview (custom footprints U2, J2; U3 is rotated 180 deg). J1 and the holes are not
in the BOM / CPL.

## PCB layers and routing

| Layer | Use |
|---|---|
| F.Cu | signals + fan-out of the plane nets (no copper under the ESP32 body except its pads, see rule areas) |
| In1.Cu | **GND plane** (power layer) |
| In2.Cu | **+3V3 plane** (power layer) |
| B.Cu | signals |

- Net classes (`.kicad_pro`): signals 0.2 mm / 0.15 mm clearance, +3V3 0.3 mm, +5V and VBUS_C 0.4 mm, vias 0.6 / 0.3 mm;
  board minimum track 0.1 mm (short neck-downs at the 0.5 mm pitch CP2102N / CH9350L pins; JLCPCB minimum 0.09 mm).
- Every SMD pad on GND / +3V3 has its own via to its plane (`tools/route.py fan`); the ESP32's pad 39 has 4 GND vias
  (in the hole of the top-layer rule area); U3's centre pad connects to GND through pin 2's track and its own vias.
- USB-C corner (`tools/usbc.py`, by hand): D+ pads joined left of the pads, D- pads joined right of them under the
  connector (track only), VBUS pad pairs through vias to a B.Cu joiner and a via under U5 to its pin 5, CC1 through a
  tented via under the connector, J5's GND pins straight to the shield pads.
- CP2102N (U3) rotated 180 deg (user) so D+ / D- face the ESD part; D- crosses D+ through a B.Cu hop (`tools/dmfix.py`).
- The rest: FreeRouting 2.5.0 (plane nets ignored), driven by `tools/route.py` (prep / fan / free / import / unlock).

## PCB placement

Revision 1's outline (84.1 x 83.4 mm) and J1 position. Connectors on the edges:

| Edge | Top to bottom / left to right |
|---|---|
| Top | DB9 joystick 1 (J4), DB9 joystick 2 (J6), audio jack J3 (opening up); the corner beyond it is antenna clearance |
| Left | USB 2 J9 (5 V for a VGA2HDMI dongle) beside VGA J2, then VGA J2, microSD J7 |
| Right | ESP32-WROVER-E U2 with the antenna end 1 mm inside the edge (nothing sticks out; keep-out in the footprint), USB-C J5, USB 1 J8 (keyboard) |
| Bottom | J1 host connector (as revision 1) |

Groups: joystick pull-ups under their DB9s; VGA DAC resistors and 10p caps beside J2; microSD pull-ups beside J7;
audio filter left of the ESP32; ESP32 decoupling and EN RC above its pins 2 / 3, left of the antenna; CP2102N, ESD, CC resistors and
the auto-reset transistors between the ESP32 and USB-C; EN / BOOT buttons left of them; LDO in the middle; CH9350L
with the ESD part and bulk caps beside J8. Mounting holes H1-H4 inside the board (the corners hold connectors or the antenna clearance).
Rule area "ESP32 antenna clearance" (all 4 copper layers: no tracks, vias, pads, pour or parts): x 127.2 to the right edge, y 76.0-119.0 = the antenna, 15 mm of edge beside it on the side away from the feed point (Espressif "Keepout Zone for ESP32 Module's Antenna (Antenna feed point on the right)"; the feed side faces USB-C) and the strip down to USB-C.
Rule area "ESP32 body: top layer clear" (F.Cu only: no tracks, vias or pour; pads allowed) between the module's pad rows up to the antenna, with a hole around pad 39 (GND) for its vias: nothing but the module's own pads touches its underside; B.Cu under the module is for the GND fill (user's choice after a XIAO board failed on a GND fill).
The ESP32 footprint has no via pads: GND vias under its centre pad are added when routing.

Built by `tools/mk_pcb.py build` (KiCad python) from the netlist (`kicad-cli sch export netlist --format kicadxml -o
netlist.xml`) and `tools/placement.py`. Once the board is edited in KiCad, the KiCad file is the source of truth: do
not rebuild over it.

## What changes against revision 1

| Revision 1 | Revision 2 |
|---|---|
| ESP32 DevKit on two 1x15 sockets | **ESP32-WROVER-E-N16R8** module (U2, JLCPCB C529589: 16 MB flash, 8 MB PSRAM for large folder lists); the DevKit's GPIOs except the control UART (IO16 / IO17 drive the PSRAM): RX2 on IO27, TX2 on IO21; antenna at a board edge |
| (console = the DevKit's USB) | **CP2102N** (U3) on **USB-C** (J5), DTR/RTS auto-reset (Q1, Q2), EN / BOOT buttons |
| keyboard module on J5 (4-pin header) | **CH9350L** (U4) + right-angle **USB-A** J8 for the keyboard at the board edge near the CH9350L; a second right-angle USB-A J9 beside the VGA socket carries **5 V only** (power for a VGA2HDMI dongle) |
| 5 V from the core board (J1 63/64) | **5 V from USB-C** on this board, straight to +5V (no diode), which also feeds the core board via J1 63/64. Power the system from USB-C **or** the core board's DC jack, never both (no back-feed protection) |
| K7803 switching module | **LDL1117S33R** LDO (U1, 1.2 A, SOT-223) |
| THT audio capacitors | SMD (same circuit) |

Unchanged: VGA (4-bit DAC per colour, J2 CONNFLY DS1038), two DB9 joysticks (J4, J6, 3k3 pull-ups), microSD (J7, on the
ESP32), audio line-out jack (J3), four M3 holes.

## Circuit notes

- **USB-C (J5)**: 5.1k on CC1 / CC2 (a USB-C source gives 5 V), USBLC6-2SC6 (U5) on D+/D-. VBUS is +5V directly (no
  diode): supply the system from USB-C (a self-powered hub or charger, >= 1.5 A) or from the core board's input, not both.
- **CP2102N (U3)**: self-powered from +3V3 (VREGIN = VDD = VIO), VBUS sensed through 22k / 47k (3.4 V at 5 V), RST pulled up (1k).
  TXD -> ESP32 RXD0, RXD <- TXD0. Auto-reset as on the DevKit: Q1 (base from DTR, emitter RTS) pulls EN,
  Q2 (base from RTS, emitter DTR) pulls IO0.
- **ESP32 (U2)**: EN 10k + 1 uF, IO0 10k pull-up, 22 uF + 0.1 uF. GPIOs: link SCK 14, MOSI 13, CS 33, MISO 35, IRQ 34;
  I2S BCLK 26, LRCK 25, DATA 22; control UART RX2 27 <- BT_TX, TX2 21 -> BT_RX (the DevKit of revision 1: 16 / 17);
  SD SCK 18, MISO 19, MOSI 23, CS 5. Footprint `ESP32-WROVER-E` (tools/fp_wrover.py) from the datasheet v2.4
  land pattern: 19 pads per side, pitch 1.27, pads 1.5 x 0.9 at x +-8.75, pin 1 7.44 mm below the antenna end,
  3.7 mm GND pad; antenna keep-out zone (7.44 mm, no copper on either layer) in the footprint. Firmware: `LSpectrum/esp32_v2`
  (UART2 on 27 / 21), built with PSRAM enabled; the revision 1 DevKit takes `LSpectrum/esp32_v1` (16 / 17).
- **CH9350L (U4)**, WCH datasheet V2.6: VIN5 from +5V (0.1 uF), VDD33 4.7 uF (internal regulator), RST to GND, SEL / S0 /
  S1 / BAUD0 / BAUD1 / xOSC open (internal pull-ups: keyboard / mouse side, state 0, 115200 baud) = the frames
  `zx_keyboard.v` already decodes. TXD -> KB_IN, RXD <- KB_OUT (the FPGA reads KB_OUT AND KB_IN). Port 2 (HP/HM) is
  not used (a keyboard and a mouse together need a USB hub on J8). J8: 5 V straight from +5V (no fuse: a short on J8 / J9 trips the upstream USB port's current limit and resets the board), 100 uF + 0.1 uF, USBLC6-2SC6.
  J9 (5 V only): 5 V from +5V, 100 uF + 0.1 uF, data pins open.
- **3.3 V**: LDL1117S33R (600 mV max dropout at 1.2 A), from +5V.

## Files

| Path | Role |
|---|---|
| `Extra_PCB_CycloneIV_R2.kicad_sch` / `.pdf` | Schematic, ANSI B (11 x 17 in) |
| `Extra_PCB_CycloneIV_R2.kicad_sym` | Project symbols: DB15_Female_HighDensity (from revision 1), CH9350L (new, LQFP-48), ESP32-WROVER-E (KiCad's WROOM-32E symbol, pins 27 / 28 NC) |
| `Extra_PCB_CycloneIV_R2.pretty/` | Project footprints: CONNFLY DS1038 VGA, 2x32 J1 (rows swapped) from revision 1; ESP32-WROVER-E (new) |
| `tools/fp_wrover.py` | Writes the ESP32-WROVER-E footprint from the datasheet land pattern |
| `tools/design.py` | Component list and nets (single source) |
| `tools/gen_sch.py` | Generates the schematic + symbol library from design.py: parts of one circuit joined by wires (`w()` calls), labels for the nets between blocks; checks that no pin, stub or wire touches another net |
| `tools/check_net.py [file]` | Netlist of the schematic (kicad-cli) against design.py |
| `tools/mk_pcb.py`, `tools/placement.py` | KiCad python: `info` (footprint sizes), `build` (board from the netlist + placement, no tracks), `pads <pcb> refs...` |
| `tools/route.py`, `tools/usbc.py`, `tools/u3fix.py`, `tools/dmfix.py` | KiCad python: the routing steps above (history of how the board was routed; the board itself is the source of truth now) |

The generator is for the first version only: once the schematic is edited in KiCad, the KiCad files are the source.
