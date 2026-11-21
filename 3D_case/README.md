# 3D_case: case for the L computer (10CL025 core board on the I/O board revision 2)

Two printed halves, glued together (the case is not meant to be opened). Only the I/O board's connectors are reachable.
Outside 89.5 x 151.3 x 25.5 mm (the D-sub shells and the microSD card stand out of the walls).

| File | Role |
|---|---|
| `case.py` | The model (CadQuery 2.8, Python): every dimension is a named constant at the top |
| `out/L_case_bottom.stl`, `out/L_case_top.stl` | For the printer, in print orientation (the top half lies on its ceiling); no supports needed |
| `out/L_case_bottom.step`, `out/L_case_top.step` | The same halves for a CAD program, in assembled position |
| `out/L_case_assembly.step` | Both halves + I/O board (KiCad model) + core board (blocks) for a look in a CAD program; made by `case.py`, not in the repository (16 MB) |
| `out/*.svg`, `out/*.png` | Line drawings |
| `hand.py` | The stand: a stylized open hand that holds the case (takes the case's outside size from `case.py`) |
| `out/L_hand.stl`, `out/L_hand.step` | The hand as it stands on the table (= print orientation) |
| `out/L_hand_assembly.step` | Hand + closed case for a look in a CAD program; made by `hand.py` |
| `out/hand*.svg`, `out/hand_render*.png` | Line drawings (from `hand.py`) and shaded pictures of the hand |
| `hand2.py` | Stand 2: a realistic human hand that holds the case upright (numpy / scipy / VTK; no CAD solid, a mesh) |
| `out/L_hand2.stl` | Stand 2 as it stands on the table (= print orientation) |
| `out/hand2_*.png` | Shaded pictures of stand 2, with and without the case; made by `hand2.py` |
| `ref/io_board_r2.step` | I/O board with parts for the fit check (no models: J1, J3, J5, J7, J8, J9); not in the repository: `kicad-cli pcb export step --subst-models -o 3D_case/ref/io_board_r2.step Extra_PCB_CycloneIV_R2/Extra_PCB_CycloneIV_R2.kicad_pcb`. Without it `case.py` checks the core board only |

Build (in this folder): `C:\Tools\cadquery_env\Scripts\python.exe case.py` (prints the sizes and the fit check: common volume
of each half with the two boards, must be 0).

## Design

- **Bottom half**: tray up to the top side of the I/O board. Four posts (7 mm) stand under the I/O board's holes H1-H4, each
  with a **2.8 mm pin through the hole**, 2.5 mm above the board: the pin tops are melted down onto the board (heat
  staking), so the board is fixed to the bottom half and can be tested before the top is glued on. 5 mm under the board for header pins and DB9 legs.
  Three ribs on the far wall stand 0.3 mm under the core board's free edge (the empty U7 strip).
- **Top half**: no posts (user). Three ribs stand 0.5 mm over the core board's free edge. Tongues on the
  far wall and both side walls reach 2.5 mm into the bottom half and line the halves up.
- **Joint** = top side of the I/O board: all sockets sit on that side, so the top half drops over them.
- **Openings**: 2 x DB9 and VGA (flange, shell and jack screws), 2 x USB-A, USB-C (the whole plug goes in), microSD (wide
  enough to pinch the card), audio jack. Around them the wall is thinned from outside to 1 mm so plugs seat fully.
- The core board's DC jack is in line with the board edge and is not used: it sits behind a closed wall.

## Taken from measurements / to check on the real boards before printing

| Constant | Value | Source |
|---|---|---|
| `CORE_GAP` | 3.0 mm | user's measurement: gap between the two boards; boards alone 84 x 145 mm (the model: 84.3 x 144.5) |
| `JACK_H` | 9.5 mm | user's measurement: DC jack above the core board |
| `JACK_OVERHANG` | 0 | user: the DC jack is in line with the board edge |
| `STANDOFF` | 5.0 mm | longest pin under the I/O board must be shorter |
| core board position | X 0.18..84.28 | from the QMTECH drawing (header rows 1.8 mm from the edges), 0.6 mm to the walls |
| USB-C, microSD, audio jack, USB-A heights | datasheets | these parts have no 3D model in the fit check |

## The hand (stand)

Build: `C:\Tools\cadquery_env\Scripts\python.exe hand.py` (prints the size and the fit check: the hand must not touch the
case nor the room of the plugs).

- One part, 121 x 163 x 49 mm; with the case on it 77 mm high. The case lies on the palm, tilted 15 degrees (`TILT`) towards
  the user, its closed short end down; the DB9 end is the high end and hangs 11 mm over the wrist.
- **Four curled fingertips** (13 to 19 mm high) stop the case at the low end. The palm is **cupped**: its edge stands 3 mm
  (`RIM`) above the surface the case lies on and keeps the case from moving sideways; 0.5 mm play (`PLAY`) on every side.
- **The thumb** stands 14 mm high beside the case on the USB-C side, in front of the sockets (they begin 70 mm from the
  low end); behind it and on the other side nothing is higher than the rim, so every plug and the microSD card stay free.
- The case is not fixed: it lies in the hand and is lifted out.
- Printing: as it stands, flat underside on the bed, no supports (steepest overhang 15 degrees). It is a solid block of
  472 cm3: print it with 10-15 % infill. The palm surface is a 15 degree slope and shows the layer steps.

## Hand 2 (realistic hand, case upright)

State 2026-11-20: first version, not printed. The user finds that it looks like an alien; it will be redone from a picture the
user sends after the case is printed.

Build: `C:\Tools\cadquery_env\Scripts\python.exe hand2.py` (about 15 minutes; `hand2.py 1.5` = quick look with 1.5 mm
grid cells). It prints the pose, the size, the smallest distance to the case and to the room of the plugs, and the
stability check.

- The case stands 70 degrees steep (`LEAN`), **joystick end down**, its lowest edge 75 mm above the table (`LIFT`) so that the
  two joystick plugs and the audio plug go in from below.
- A hand 1.3 times life size (`SCALE`; the case is 89.5 mm wide) holds it from behind:
  the **thumb** lies under the lower back edge and carries the case (a ledge 3 to 5 mm deep; the sockets start 6 mm from the
  back), its knuckle stands beside the VGA wall's lowest 13 mm; the **four fingers** reach round the USB-C wall with their
  tips on the lid: index and middle finger below the USB-C socket, ring and little finger above the USB-A socket, so the
  two plugs of that wall pass between middle and ring finger. The forearm stands on an oval base plate (172 x 132 mm).
- Nothing covers a socket: the case with 0.5 mm play, the room under the joystick end, beside the USB-C / USB-A sockets
  and the whole VGA wall above its lowest socket are cut out of the hand (`room_dist`).
- **The case is pushed in from above**, along its length, until it sits on the thumb. It is not fixed; hold it when a
  joystick plug is pushed in from below.
- How it is made: a skeleton with joint radii (anatomy tables at the top of the file), the pose from a solver (the points
  each joint has to reach on the case: `AIM`, `AIM_THUMB`), blended round cones sampled on a grid, surface by marching cubes.
- Printing: as it stands, on the base plate, **with supports** (fingers, thumb and palm overhang). It needs a bed of
  about 250 x 170 mm and 210 mm height, and it is about 1.2 litres in volume: 10-15 % infill.

Printing: 0.2 mm layers, 3 perimeters; PETG or PLA. First print: check the fit of the board on the pins and of the plugs
before gluing.
