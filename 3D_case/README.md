# 3D_case: case for the L computer (10CL025 core board on the I/O board revision 2)

Two printed halves, glued together (the case is not meant to be opened). Only the I/O board's connectors are reachable.
Outside 89.5 x 151.3 x 25.5 mm (the D-sub shells and the microSD card stand out of the walls).

| File | Role |
|---|---|
| `case.py` | The model (CadQuery 2.8, Python): every dimension is a named constant at the top |
| `check_walls.py` | Wall thickness check of the two STL files: nothing may be thinner than `WALL_MIN` (1 mm) |
| `out/L_case_bottom.stl`, `out/L_case_top.stl` | For the printer, in print orientation (the top half lies on its ceiling); no supports needed |
| `out/L_case_bottom.step`, `out/L_case_top.step` | The same halves for a CAD program, in assembled position |
| `out/L_case_assembly.step` | Both halves + I/O board (KiCad model) + core board (blocks) for a look in a CAD program; made by `case.py`, not in the repository (16 MB) |
| `out/*.svg`, `out/*.png` | Line drawings |
| `hand.py` | The stand: a stylized open hand that holds the case (takes the case's outside size from `case.py`) |
| `out/L_hand.stl`, `out/L_hand.step` | The hand as it stands on the table (= print orientation) |
| `out/L_hand_assembly.step` | Hand + closed case for a look in a CAD program; made by `hand.py` |
| `out/hand*.svg`, `out/hand_render*.png` | Line drawings (from `hand.py`) and shaded pictures of the hand |
| `hand2.py` | Stand 2: a life-size human hand on a rock that holds the case upright, made after the user's photos (numpy / scipy / VTK; no CAD solid, a mesh) |
| `out/L_hand2.stl` | Stand 2 as it stands on the table (= print orientation) |
| `out/hand2_*.png` | Shaded pictures of stand 2, with and without the case (`hand2_case_photo1/2.png` = from where the photos were taken, `hand2_nails.png` = the nails); made by `hand2.py` |
| `ref/io_board_r2.step` | I/O board with parts for the fit check (no models: J1, J3, J5, J7, J8, J9); not in the repository: `kicad-cli pcb export step --subst-models -o 3D_case/ref/io_board_r2.step Extra_PCB_CycloneIV_R2/Extra_PCB_CycloneIV_R2.kicad_pcb`. Without it `case.py` checks the core board only |

Build (in this folder): `C:\Tools\cadquery_env\Scripts\python.exe case.py` (prints the sizes and the fit check: common volume
of each half with the two boards, must be 0). Then `C:\Tools\cadquery_env\Scripts\python.exe check_walls.py` (about 2 minutes):
it slices both STL files on a 0.1 mm grid and reports every wall, fin or lip thinner than 1 mm (it sees what is thinner than 0.9 mm).

## Design

- **Bottom half**: tray up to the top side of the I/O board. Four posts (7 mm) stand under the I/O board's holes H1-H4, each
  with a **2.8 mm pin through the hole**, 2.5 mm above the board: the pin tops are melted down onto the board (heat
  staking), so the board is fixed to the bottom half and can be tested before the top is glued on. 5 mm under the board for header pins and DB9 legs.
  Three ribs on the far wall stand 0.3 mm under the core board's free edge (the empty U7 strip).
- **Top half**: no posts (user). Three ribs stand 0.5 mm over the core board's free edge. Two tongues on the
  far wall reach 2.5 mm into the bottom half; each fills the space between two of the bottom half's ribs (0.2 mm play), so
  they line the halves up in both directions. The side walls carry nothing: the core board is as wide as the case inside
  and the top half has to pass it.
- **Joint** = top side of the I/O board: all sockets sit on that side, so the top half drops over them.
- **Openings**: 2 x DB9 and VGA (flange, shell and jack screws), 2 x USB-A, USB-C (the whole plug goes in), microSD (wide
  enough to pinch the card), audio jack. Around them the wall is thinned from outside to 1 mm so plugs seat fully.
  The D-sub openings are open up to the ceiling. **No wall is thinner than 1 mm.**
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

## Hand 2 (hand on a rock, case upright)

State 2026-11-22: made after the user's two photos of the printed case in the hand, then changed to a left hand and given
new nails (user); not printed.

Build: `C:\Tools\cadquery_env\Scripts\python.exe hand2.py` (some minutes; `hand2.py 1.5` = quick look with 1.5 mm
grid cells). It prints the pose, the size, the smallest distance to the case and to the room of the plugs, and the
stability check.

- The case stands 70 degrees steep (`LEAN`), **joystick end down, lid to the viewer**, its lowest edge 50 mm above the
  table (`LIFT`): the joystick plugs and the audio plug go in from below.
- A **left hand, life size** (`SCALE` 1.0; the thumb on the viewer's left: user), holds it from behind, palm on the case's
  underside: the **thumb** lies flat on the USB-C wall above its two sockets, the **little finger** on the VGA wall above
  the microSD slot, **index, middle and ring finger** stand behind the case, their tips show above its upper end and bend
  a little forward. Each nail is a thin plate with a groove along its root and sides and a free edge at the fingertip.
- The case's lower back edge sits on the **heel of the hand** (a step 5.5 mm deep; the joystick sockets begin above it),
  thumb and little finger keep it from moving sideways (0.5 mm play, `PLAY`), its weight leans it onto the palm.
  It is put in from the front: lower edge onto the heel, then leaned back. It is not fixed; hold it when a plug goes in.
- The forearm grows out of a **rock** (three boulders with flat faces, `ROCKS`), which is the base; under the joystick end
  the rock is cut back for the plugs.
- Nothing covers a socket: the case with 0.5 mm play, the room under the joystick end and beside the sockets of both side
  walls are cut out of the stand (`room_dist`).
- How it is made: a skeleton with joint radii (anatomy tables at the top of the file), the hand's place and the angles of
  three fingers as constants (`HAND_*`, `POSE`), thumb and little finger from a solver (the points their joints have to
  reach on the case: `AIM_THUMB`, `AIM_LITTLE`), blended round cones sampled on a grid, surface by marching cubes.
- Printing: as it stands, on the rock, **with supports** (thumb, little finger, fingertips and palm overhang).
  About 170 x 125 mm on the bed and 235 mm high (`LIFT` lower = less height, less room for the joystick plugs),
  0.65 litres in volume: 10-15 % infill.

Printing: 0.2 mm layers, 3 perimeters; PETG or PLA. First print: check the fit of the board on the pins and of the plugs
before gluing.
