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

Printing: 0.2 mm layers, 3 perimeters; PETG or PLA. First print: check the fit of the board on the pins and of the plugs
before gluing.
