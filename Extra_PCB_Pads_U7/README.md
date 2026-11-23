# Extra_PCB_Pads_U7 — pad board for the 10CL025 core board's header U7

KiCad 10 project. Two DB9 sockets for **Sega Mega Drive pads** (3 and 6 buttons) on 5 V, with level shifters to
the FPGA's 3.3 V pins. Atari-style joysticks and Master System pads work in the same sockets.

Status (2026-11-23): designed, routed, rules check clean. **Bare boards and parts ordered separately (user, 2026-11-23); the user assembles them by hand.** Not built yet, no FPGA logic for it yet.

## Size and mounting

- **84.1 x 19.5 mm**, 2 layers, no mounting holes. As long as the core board and flush with it on both sides.
- It lies under the core board's U7 edge the way the I/O board lies under the U8 edge: the two header rows are
  soldered through both boards, the core board covers the last 6.04 mm of this board, 3 mm above it.
- Top side (the side facing the core board): the two DB9 sockets, openings away from the core board.
- Bottom side: all other parts.
- The height is set by the DB9 socket (CONNFLY DS1037-09M, as on the I/O board): 12.9 mm of socket, 0.6 mm gap
  to the core board's edge, 6.04 mm under the core board.

## Circuit

| Part | Does |
|---|---|
| J1 | 2x32 holes = U7, pin for pin (no pair swap) |
| J2, J3 | DB9 sockets, pad 1 and pad 2 |
| U1, U2 (74LVC245 on 3.3 V) | six lines per socket from the pad to the FPGA; the inputs tolerate 5 V |
| U3 (74HCT2G34 on 5 V, dual buffer in SOT-23-6) | both select lines from the FPGA to the pads; reads a 3.3 V high as high |
| R1-R6, R9-R14 (3k3 to 5 V) | pull-ups on the socket lines (a joystick only shorts them to ground) |
| R7, R15 (10k to 3.3 V) | select is high while the FPGA pin is not driven |
| R8, R16 (100 Ohm) | in series with the select pin of the socket |
| C1-C6 | decoupling, 10 uF on the 5 V input |

DB9 pin 5 is connected straight to the 5 V (no fuse, user's choice): a short in a pad or its cable loads the
board's 5 V input directly, as the I/O board's USB sockets do.

DB9 pins: 1 Up, 2 Down, 3 Left, 4 Right, 5 supply 5 V, 6 B (A with select low), 7 select, 8 ground,
9 C (Start with select low).

## Header pins and FPGA balls

The balls are read from the QMTECH 10CL025 schematic V1. **Check the header with a meter before soldering**: pins 1 / 2
and 61 / 62 ground, 3 / 4 3.3 V, 63 / 64 5 V; the silkscreen marks pin 1 and pin 63.

| Signal | U7 pin | FPGA ball | Direction |
|---|---|---|---|
| PAD1_UP | 21 | D6 | pad -> FPGA |
| PAD1_DOWN | 23 | B5 | pad -> FPGA |
| PAD1_LEFT | 26 | B6 | pad -> FPGA |
| PAD1_RIGHT | 27 | A6 | pad -> FPGA |
| PAD1_B | 30 | A7 | pad -> FPGA |
| PAD1_C | 31 | D8 | pad -> FPGA |
| PAD1_SEL | 32 | C8 | FPGA -> pad |
| PAD2_SEL | 33 | C9 | FPGA -> pad |
| PAD2_UP | 34 | D9 | pad -> FPGA |
| PAD2_DOWN | 35 | F9 | pad -> FPGA |
| PAD2_LEFT | 36 | E9 | pad -> FPGA |
| PAD2_RIGHT | 37 | E10 | pad -> FPGA |
| PAD2_B | 38 | E11 | pad -> FPGA |
| PAD2_C | 44 | B10 | pad -> FPGA |

Not used on purpose: pin 7 (G1, the machines' menu key input), the configuration pins (17, 20, 22, 24, 25, 28, 29),
the clock inputs (39-42). Pins 5 / 6 and 47-60 are not connected.

All lines are low when a button is pressed. The 5 V comes from the core board's input (U7 63 / 64), so from the
I/O board's USB-C socket.

## Open points

- The header's row order (even pins on the row nearer the core board's edge) is read from the photo in QMTECH's
  manual. If it is the other way round, every signal sits on its pair's partner pin: a change of the FPGA pin
  list, not of the board; the supply pairs carry the same net on both pins.
- Part numbers for an assembly order are not checked (74LVC245 in TSSOP-20, 74HCT2G34GV in SOT-457 on the SOT-23-6
  footprint); Gerbers in `jlcpcb/` (no parts list or placement file: hand assembly).
- The printed case has no openings on this side.
- Rules check: no errors; left are three ground pads with one thermal spoke (they also have a track) and one
  silkscreen note.

## Files and tools

| File | What |
|---|---|
| `Extra_PCB_Pads_U7.kicad_sch` / `.pdf` | schematic (generated; every pin carries a net label) |
| `Extra_PCB_Pads_U7.kicad_pcb` | board |
| `out/top.png`, `out/bottom.png` | pictures of both sides |
| `tools/design.py` | parts and nets, the single source |
| `tools/gen_sch.py`, `tools/mk_pro.py` | schematic and project file (WSL python, run in this folder) |
| `tools/placement.py`, `tools/mk_pcb.py build` | positions, board from the netlist (KiCad python) |
| `tools/route.py dsn / import / pour` | FreeRouting 2.5.0 in between (`-de pads.dsn -do pads.ses -mp 40`) |
| `tools/finish.py` | tracks off the board edge, silkscreen |

Once the board is edited in KiCad, the KiCad files are the source of truth: do not rebuild over them.
