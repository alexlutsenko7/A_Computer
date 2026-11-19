# Second assembly quote (7pcb.com), started 2026-11-12

State: the parts are being chosen on the manufacturer's website. **The BOM spreadsheet still lists the JLCPCB parts:**
it is changed only when the choice is final.

## Files

- `Extra_PCB_CycloneIV_R2_BOM.xlsx`: 33 lines, 89 parts. Made from the JLCPCB BOM by `tools/bom_xlsx.py`
  (Windows Python, it has openpyxl):
  `python tools/bom_xlsx.py jlcpcb/Extra_PCB_CycloneIV_R2_BOM.csv 7pcb/Extra_PCB_CycloneIV_R2_BOM.xlsx`
- Centroid (pick and place) file: `../jlcpcb/Extra_PCB_CycloneIV_R2_CPL.csv` (Designator, Mid X, Mid Y, Layer,
  Rotation; millimetres; KiCad's rotations, unchanged; the through-hole connectors are in the list too).
- Gerbers and drill files: `../jlcpcb/`.

## Board data asked for by the quote form

| Item | Value |
|---|---|
| Size | 84.10 x 83.43 mm, rectangle |
| Layers, thickness | 4, 1.6 mm |
| Smallest trace | 0.1 mm (3.94 mil); signals 0.2 mm |
| Smallest clearance | 0.15 mm (5.9 mil) |
| Copper | 1 oz outer, 0.5 oz inner (the JLCPCB default the boards were ordered with; not stored in the KiCad files) |
| Vias | 170, all 0.6 mm pad / 0.3 mm drill; via in pad: epoxy filled and capped |
| Smallest drill | 0.3 mm |
| Slots | four plated, 0.6 mm wide (USB-C shell) |
| Largest hole | 3.2 mm |

## Substitute parts, checked against the footprints

| Part on the board | JLCPCB part | Substitute | Result |
|---|---|---|---|
| VGA socket | CONNFLY DS1038 | Amphenol L77HDE15SD1CH4FVGA | fits; its pins want 1.10 mm holes, the board has 1.0 mm; sits 0.26 mm further out |
| Audio jack | PJ-320D-4A | Same Sky SJ2-3574A-SMT-TR | fits; its pegs are 1.0 mm in 1.6 mm holes: align it to the pads |
| Audio jack | PJ-320D-4A | Same Sky SJ-3524-SMT-TR | **does not fit** |
| DB9 (2) | CONNFLY DS1037 | ASSMANN A-DS09A/KG-T1 | fits the holes; **must be the male A-DS, the offered A-DF is female**; 9.4 mm footprint: sits 2.2 mm further out |
| USB-C | TYPE-C-31-M-12 | Same Sky UJ20-C-H-G-SMT-1-P16-TR | fits; shell legs about 1 mm on a 1.6 mm board: soldered in the slots |
| USB-A | SOFNG USB-302-T (the quote of 2026-11-12 named CONNFLY DS1095-WNR0, same footprint) | Stewart SS-52100-001 | drop-in (only the -001 version) |
| Transistor | JSCJ MMBT3904 | Diotec MMBT3904 | same part |
| Buttons | C&K PTS810 | Würth 434133025816 | same pad pattern (KiCad library footprint); Alps SKRPABE010 is a second choice, not checked |

The substitutes' datasheets are in the project's top folder (not part of the public repository).
