# Extra_PCB_CycloneIV (Extended board) — helper scripts

Scripts used to build and route this board (then named `qm_atrix_ext`). **The KiCad files are the source of truth now**: the board has been
edited by hand in KiCad, so do not re-run the generators below on it.

| Script | Run with | What it did |
|---|---|---|
| `design.py`, `gen_sch.py`, `sx.py` | WSL `python3` | First generation of the schematic from a parts/nets list. **Historical**: re-running overwrites the schematic and breaks the PCB links (new symbol UUIDs). |
| `edit_esp.py` | WSL `python3` | In-place schematic edit: J1 2x20 -> 2x32 (pins 41-46, 63-64), ESP32 symbol U2 + labels, local symbol `ESP32_DevKit_30pin`. |
| `stage.py A..G` | KiCad python | Staged PCB edits for the ESP32 step (outline, J1 swap, placement search, via cleanup, net-name fix). |
| `vgamove.py` | KiCad python | Swap J2 to the DS1038 footprint, flush with the left edge; shift neighbours; remove broken tracks. |
| `dangle1.py`, `viadel.py` | KiCad python | Remove dangling track stubs (one pass per run) / vias at positions listed by DRC. |
| `lockexp.py`, `clearexp.py`, `imp4.py` | KiCad python | Lock tracks + export DSN / clear all tracks + export DSN / import a FreeRouting SES. |
| `silk.py` | KiCad python | Move overlapping silkscreen references to a free spot nearest their own part (0.8 mm text). |
| `jlc_export.py` | WSL `python3` | JLCPCB Gerber zip + drill, BOM and CPL into `../jlcpcb/` (LCSC numbers inside; DNP parts left out). Current tool. |
| `pour.py`, `refill.py` | KiCad python | Add GND pours on F.Cu + B.Cu / refill zones. |

Paths inside the scripts point to `C:\work\My\AlteraZX\Extra_PCB_CycloneIV\...` and a temporary `C:\Users\Public\fr\` folder
(the Windows KiCad python cannot read WSL paths); adjust before reuse.

## Routing workflow (FreeRouting 2.5.0)

1. Export: `pcbnew.ExportSpecctraDSN(board, "x.dsn")` (remove zones first, or FreeRouting treats them as planes).
2. Route (Java from Android Studio: `C:\Program Files\Android\Android Studio1\jbr\bin\java.exe`; the jar is
   https://github.com/freerouting/freerouting/releases/download/v2.5.0/freerouting-2.5.0.jar):
   `java -jar freerouting-2.5.0.jar -de x.dsn -do x.ses -mp 500 --gui.enabled=false --router.automatic_neckdown=false`
   (`--router.autorouter.ignore_net_classes=<class>` to leave a class alone).
3. Import: `pcbnew.ImportSpecctraSES(board, "x.ses")` — keeps locked tracks, replaces the rest.
4. `kicad-cli pcb drc --schematic-parity --severity-all ...`; refill zones.

Net classes (in the .kicad_pro): Default 0.25 mm, Power_0.4 (+5V) 0.4 mm, Power_0.3 (+3V3, GND) 0.3 mm.

## KiCad 10 python quirks (pcbnew)

- `pcbnew.SaveBoard()` rewrites the `.kicad_pro` with defaults: back it up and copy it back after every save.
  `kicad-cli pcb drc` can do the same.
- After `board.Remove(...)`, later `GetDrawings()/Zones()/FindFootprintByReference()` return stale SWIG objects or
  crash: collect all lists first, or save and reload between steps.
- `pcbnew.FootprintSave` is broken; to extract a footprint, put it on an empty board, save, and cut the block out.
- Copying a ZONE with `pcbnew.ZONE(z)` moves the original; create a new ZONE instead.
- Local-label nets are named `/NAME` in the PCB; unconnected pins `unconnected-(REF-PinName-PadN)`.
