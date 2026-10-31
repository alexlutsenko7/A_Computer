# QM_Atrix adapter — the user's existing ZX I/O board

KiCad project in `QM_Atrix_adapter/`, originally made (Mar 2024) as a plug-on board for a QMTECH **Artix-7**
core board (two 2x25 headers named JP2/JP3). It is **not** pin- or size-compatible with the QMTECH Cyclone IV
board (two 2x32 headers U7/U8, see `BOARD_PINOUT.md`). Prototype connection: J2 plugged into U8, J1 wired to U7 (see below).

Netlists below were extracted with `kicad-cli` (schematic) and by parsing the `.kicad_pcb` pad nets (2026-10-06).

## Files

| Path | Role |
|---|---|
| `qm_atrix.kicad_sch` | Schematic, Mar 2024 (KiCad 6), **auto-converted to KiCad 10.0.1 on 2026-10-06** (no intentional edits; the conversion re-annotated parts) |
| `qm_atrix.pdf` | Plot of the converted schematic (2026-10-06) |
| `qm_atrix.kicad_pcb` | Layout, Mar 2024 (KiCad 6 format) = **what was built**; reference designators differ from the converted schematic (see "Schematic vs PCB") |
| `qm_atrix.kicad_pro/.kicad_prl` | Project files |
| `pcb_manufactoring/` (+ `.zip`) | Gerbers + drill files of the 2024 PCB (what was manufactured) |
| `qm_atrix.dsn/.ses/.rules` | FreeRouting export/import of the 2024 PCB |
| `qm_atrix-backups/`, `.history/`, `fp-info-cache` | KiCad autosaves / local history / footprint cache |

## Board

- 60 x 68 mm, 2 layers, SMD 0603 passives + THT connectors.
- J1 (JP2) and J2 (JP3): 2x25 2.54 mm headers on the **bottom** side, 50.8 mm (2.0") apart — they plug into the
  Artix board. Only the odd-numbered side of a few pins is used; all signals are 3.3 V.
- Front side: VGA DB15 (J7, at the board edge), Atari/Kempston DB9 male (J4), 50/60 Hz slide switch (S1),
  pin headers for the keyboard module (J5), audio module (J3) and two volume pots (RV1, RV2).

## Signals on the host headers

J1 = JP2, J2 = JP3. Pins not listed are unconnected.

| Header pin | Net | Dir (FPGA) | Function / circuit on the adapter |
|---|---|---|---|
| J1.1, J2.1 | 5v0 | power | 5 V: audio module J3.4, keyboard module J5.4 (and U1 input, schematic only) |
| J1.2, J2.2 | 3v3 | power | 3.3 V from the host (built PCB). The schematic leaves them open and draws 3v3 from U1 instead |
| J1.3, J1.4, J1.49, J1.50, J2.3, J2.4, J2.49, J2.50 | GND | | |
| J1.5 | Vrf | in | S1: GND or 3v3 via R1 3k3 — 50/60 Hz vertical refresh switch |
| J1.7 | Rght | in | DB9 pin 4 **and pin 7**, 3k3 pull-up to 3v3 |
| J1.9 | Lft | in | DB9 pin 3, 3k3 pull-up |
| J1.11 | Dwn | in | DB9 pin 2, 3k3 pull-up |
| J1.13 | Btn | in | DB9 pin 6 (fire), 3k3 pull-up |
| J1.15 | Up | in | DB9 pin 1, 3k3 pull-up |
| J1.17 | AY | out | R2 68 Ω + C1 100 nF to GND (RC low-pass, fc ≈ 23 kHz) → C2 10 µF → RV1 → J3.3 |
| J1.19 | Beeper | out | C3 10 µF (no resistor/filter) → RV2 → J3.1 |
| J2.6 / J2.8 | BL / BH | out | blue low / high bit |
| J2.10 / J2.12 | GL / GH | out | green low / high bit |
| J2.14 / J2.16 | RL / RH | out | red low / high bit |
| J2.18 | HS | out | 6p8 to GND, R 22 Ω → VGA pin 13 |
| J2.20 | VS | out | 6p8 to GND, R 22 Ω → VGA pin 14 |
| J2.46 | Kb_out | out? | J5.2 (3.3 V logic) |
| J2.48 | Kb_in | in? | J5.3 (3.3 V logic) |

18 signals on the headers: 8 VGA, 2 audio, 2 keyboard UART, 1 switch, 5 joystick.

## On-board circuits

- **VGA DAC** (J7): per colour, high bit via 130 Ω and low bit via 340 Ω into the 75 Ω monitor load, 6p8 to GND
  on each colour line. Weights ≈ 2.6:1 (4 levels per colour, matches the reference design's 2-bit RGB).
  Full scale at 3.3 V ≈ 3.3·75/(75+130‖340) ≈ 1.46 V (above the 0.7 V standard), but it worked fine on the Artix
  board — **kept as is** (user's decision 2026-10-06).
- **Joystick** (J4, DB9 male): Atari/Kempston pinout 1 Up, 2 Down, 3 Left, 4 Right, 6 Fire, 8 GND; 3k3 pull-ups to
  3v3. Pin 7 is also tied to Rght (both schematic and PCB). Only a plain switch joystick is used (no autofire,
  nothing drives pin 7), so this is harmless; just never plug in an autofire (+5 V on pin 7) or Sega pad.
- **Keyboard** (J5, footprint `USB_MODULE_KEYB_V2`): 1 GND, 2 Kb_out, 3 Kb_in, 4 5 V — the USB-HID→UART module
  (CH9350-style, 115200 baud, as in `Reference_ZX_On_DE10_Lite`). 5 V is only the USB power pass-through; the
  UART levels are 3.3 V (confirmed by the user), so it connects directly to Cyclone IV pins.
- **Audio** (J3, footprint `audio_pcb`): 1 Beeper channel, 2 GND, 3 AY channel, 4 5 V, 5 GND — header for a 5 V
  audio amplifier module. RV1 (AY) / RV2 (beeper) are 1 kΩ volume pots on 3-pin headers (wiper → J3).
- **Power**: 4x 100 nF on 3v3, 4x 100 nF on 5v0. The schematic also has U1 `7803_switcing` (switching 7803
  drop-in, 5v0 → 3v3). It is missing from the PCB file but **fitted on the real board** (user, 2026-10-06), so the
  adapter makes its own 3v3 from 5v0 (feeds the joystick 3k3 pull-ups and the 50/60 switch).
  Only 5v0 + GND are needed from the host. Do not also tie the host 3V3 to the adapter's 3v3 rail (two regulators in
  parallel) unless a continuity check shows the header 3v3 pins are isolated on the real board.

## Schematic vs PCB

Both date from Mar 2024. The 2024 schematic already contained **unannotated** parts (`U?` = 7803 regulator) that
were never transferred to the PCB file. The KiCad 10 conversion (2026-10-06) annotated them, which shifted the
resistor numbering. The netlists differ as follows. **The PCB file is not exactly the real board**: the 7803 is
fitted on the real board (user, 2026-10-06), so for it the real board follows the **schematic**, not the PCB file.

| Item | PCB / gerbers (built) | Converted schematic |
|---|---|---|
| 3v3 source | host header pins J1.2 / J2.2 | U1 7803 from 5v0; J1.2 / J2.2 unconnected — **real board: 7803 fitted** |
| Joystick pull-ups | R9 Up, R10 Btn, R11 Dwn, R14 Lft, R15 Rght | R10 Up, R11 Btn, R12 Dwn, R15 Lft, R16 Rght |
| HS / VS series 22 Ω | R12 / R13 | R13 / R14 |
| DB9 shield (J4 pad 0) | no net | GND |

## Connecting to the Cyclone IV board — prototype (decided 2026-10-06)

**Prototype only, not the final hardware.** The user's last schematic/PCB revision was lost; the KiCad files are an
earlier one (which is why the 7803 is fitted on the board but missing from the PCB file).

As built by the user:
- Adapter **J2 plugged straight into U8**, J2 pin 1 on U8 pin 64 (J2 pin k -> U8 pin 65-k). The analog VGA
  lines get a short, rigid path and 5 V + GND come through the header (J2.1 -> VIN, J2.3/J2.4 -> GND 62/61).
- **J2.2 cut** on the adapter (it would sit on VIN 5 V; on the real board it might reach the 3v3 rail).
- One side of the adapter is aligned with U8; **J1 hangs outside the Cyclone board**, so it touches nothing there.
  J1.1 still carries 5 V (same net as J2.1): keep loose wires and metal away. Support the overhanging side mechanically.
- J1 signals (joystick, AY, beeper, 50/60) go to **U7 by wires**, plus one GND wire; J1 5 V and 3v3 are not wired.

Full pin tables: `BOARD_PINOUT.md`, section "ZX Spectrum I/O assignment — prototype". Summary:

| Adapter | Cyclone | Signal |
|---|---|---|
| BL BH GL GH RL RH (J2.6-16) | U8 59 57 55 53 51 49 = M20 N20 B22 C22 D22 E22 | VGA_B_LOW VGA_B VGA_G_LOW VGA_G VGA_R_LOW VGA_R |
| HS, VS (J2.18, J2.20) | U8 47, 45 = F22, H22 | VGA_HSYNC, VGA_VSYNC |
| Kb_out, Kb_in (J2.46, J2.48) | U8 19, 17 = AA19, AA18 | keyboard UART (direction to confirm) |
| GND (J2.49, J2.50) | U8 16, 15 = AB17, AA17 | FPGA I/O tied to GND: never drive high |
| AY, Beeper (J1.17, J1.19) | U7 15, 16 = J1, J2 | AUDIO_AY, AUDIO_BEEPER |
| Vrf (J1.5) | U7 22 = D2 | SW_50_60 |
| Up Dwn Lft Rght Btn (J1.15 11 9 7 13) | U7 23-27 = C1 C2 B1 B2 B3 | JOY_* |
| GND (J1.3) | U7 1 | ground wire |

How the fit was chosen: every alignment of J2 (2x25) on a 2x32 header was checked (row offset, both directions,
both column parities). Only "J2 pin 1 at the VIN end" (U7 or U8) puts 5 V on VIN, GND on GND and all VGA lines on
I/O. The alternative (J2 pin 1 at U7 pin 5) gives no power or ground through the header.

Not on the adapter:
- **Reset**: on-board KEY0 (W13), as on the Artix board (its own reset button).
- **ROM select**: on-board KEY1 (Y13) held during reset/power-up -> DiagROM, otherwise 128K ROM (agreed 2026-10-06).

## Open decisions (user)
- ~~Physical connection~~ — decided for the prototype: J2 into U8 (pin 1 on U8.64, J2.2 cut), J1 wired to U7.
- Keyboard UART direction (which of Kb_out/Kb_in is the module's TX): confirm on the module.
- ~~ROM select method~~ — decided: KEY1 held at reset (see above).
