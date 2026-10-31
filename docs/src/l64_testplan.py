"""l64_testplan.py OUT.xlsx -- the final L64 hardware test plan (docs/L64_Test_Plan.xlsx,
sheets Test Plan and Summary). Needs openpyxl (the Windows Python has it).
"""
import sys
from openpyxl import Workbook
from openpyxl.styles import Font, Alignment, PatternFill, Border, Side
from openpyxl.worksheet.datavalidation import DataValidation
from openpyxl.formatting.rule import CellIsRule

OUT = sys.argv[1]
F = "Arial"

# (area, test, steps, expected, needs)
T = [
 ("Start", "Clean start into BASIC",
  "Power on. In the menu choose 2 L64.",
  "Monitor: no signal for ~2-3 s, then the BASIC screen. No coloured line at the right. Board LED off.",
  "-"),
 ("Start", "KEY0 restart",
  "In BASIC type 10 PRINT \"X\", then press KEY0.",
  "No signal ~2-3 s, then a fresh BASIC screen; LIST shows nothing (RAM cleared). ESP32 OSD works afterwards (F12).",
  "-"),
 ("Start", "Krackout + Ctrl+Alt+Del",
  "Load Krackout (.d64), let it start. Ctrl+Alt+Del, choose L64 again, load Krackout again.",
  "C64 starts into BASIC (no flashing pattern). Krackout loads and runs the second time too.",
  "Good copy of cp krackout.d64 on the card"),
 ("Start", "Krackout + KEY0",
  "Load Krackout, let it start, press KEY0. Load Krackout again.",
  "BASIC after KEY0; Krackout loads again. On the PC the card's .d64 is unchanged (compare with the local copy).",
  "Good copy of cp krackout.d64"),
 ("Start", "Machine switching",
  "Menu -> LSpectrum -> KEY1 -> L64 -> Ctrl+Alt+Del -> LSpectrum, a few rounds.",
  "Each machine starts; the ESP32 OSD (F12) works in each; no restart loop of the ESP32.",
  "-"),
 ("Video", "No right-edge line",
  "Do 5 starts (menu and KEY0) in BASIC, light-blue border.",
  "Never a line next to the right border. Optional scope: HSYNC spike on a colour line smaller than before (+-40 mV).",
  "Optional: scope"),
 ("Video", "F8 50 / 60 Hz",
  "F8, wait, F8 again.",
  "50 Hz picture, then 60 Hz again; the C64 runs on.",
  "Monitor with 50 Hz"),
 ("Disk", "Directory",
  "F12, choose a .d64. Esc if the LOAD starts. LOAD\"$\",8 and LIST.",
  "LOAD\"*\",8,1 typed at the prompt; directory listed.",
  "Any .d64"),
 ("Disk", "Save to disk",
  "On a COPY of a .d64 with free blocks: 10 PRINT \"DISK OK\" ; SAVE \"DTEST\",8",
  "LED on while saving, READY., no blinking afterwards. LOAD\"$\",8 / LIST: DTEST listed, blocks free reduced.",
  "Spare .d64 (copy)"),
 ("Disk", "Saved file survives a restart",
  "Ctrl+Alt+Del, L64, F12 the same .d64, LOAD\"DTEST\",8, RUN.",
  "Prints DISK OK. On the PC: only BAM / directory / DTEST sectors differ from the copy; no track of FF.",
  "Same .d64; PC to compare"),
 ("Disk", "Scratch and rename",
  "SAVE \"DTEST2\",8 ; OPEN15,8,15,\"R:NEW=DTEST2\":CLOSE15 ; OPEN15,8,15,\"S:DTEST\":CLOSE15 ; directory.",
  "NEW listed, DTEST and DTEST2 gone, blocks free back up.",
  "Same .d64"),
 ("Disk", "Read-only .d64",
  "On the PC make a .d64 copy read-only (Properties > Read-only). F12 it, then SAVE \"RO\",8.",
  "?WRITE PROTECT / LED blinks (DOS error 26); on the PC the file is unchanged.",
  "Read-only .d64 copy"),
 ("Disk", "Disk change in BASIC",
  "F12 disk A, LOAD\"$\",8, LIST. F12 disk B, LOAD\"$\",8, LIST.",
  "Second listing shows disk B's name and files (not disk A's).",
  "Two different .d64"),
 ("Disk", "Disk change in a running game",
  "Start a multi-disk game (or any program), then F12 another .d64 while it runs.",
  "Nothing is typed into the program; a game asking for disk 2 continues loading from it.",
  "Multi-disk game, or any game + 2nd .d64"),
 ("Disk", "Normal speed load",
  "F6 (normal), load a .d64 game.",
  "Loads at 1541 speed (~1-2 min) and runs. F6 back to turbo.",
  "Any .d64 game"),
 ("Tape", "Save to tape, load back",
  "10 PRINT \"TAPE OK\". F12, [Save to this folder], name TTEST, Enter. SAVE \"TTEST\". READY., then F12. KEY0, LOAD, F12 TTEST.TAP.",
  "TTEST.TAP on the card; FOUND TTEST, LIST shows the line, RUN prints TAPE OK.",
  "-"),
 ("Tape", "Tape at normal speed",
  "As above with F6 = normal.",
  "Same result, slower.",
  "-"),
 ("Tape", "Commercial .tap game",
  "LOAD, then F12 a .tap game. Try F11 (pause / continue) and F7 (stop).",
  "Loads and runs in turbo; pause and stop work. If a turbo loader fails: F6 normal and retry.",
  ".tap game"),
 ("Files", "BASIC .prg",
  "F12 a BASIC .prg.",
  "Program in memory and started (RUN typed).",
  "BASIC .prg"),
 ("Files", "Machine-code .prg",
  "F12 a machine-code .prg.",
  "Bottom line shows the load range (e.g. $C000-$C3FF); the program's SYS starts it.",
  "Machine-code .prg"),
 ("Files", ".t64",
  "F12 a .t64.",
  "Loaded as the .prg tests.",
  ".t64 file"),
 ("Sound", "SID 6581 / 8580 (F5)",
  "Play music with filter, press F5, again F5. Listen on the jack and Bluetooth.",
  "Audible filter difference; OSD shows the SID type; no silence or glitch.",
  "Game with music; BT speaker"),
 ("Sound", "Bluetooth volume",
  "Connect the BT speaker (F3).",
  "Volume right from the start; reconnects after KEY0.",
  "BT speaker"),
 ("Joystick", "F4 mode 1: DB9-1 = port 2",
  "F4, choose mode 1. In BASIC: PRINT PEEK(56320) with DB9-1 directions / fire; PRINT PEEK(56321) with DB9-2.",
  "DB9-1 changes port 2 ($DC00), DB9-2 port 1 ($DC01). Game control works.",
  "2 joysticks"),
 ("Joystick", "F4 mode 2: swapped",
  "F4, mode 2; same checks.",
  "DB9-1 on port 1, DB9-2 on port 2.",
  "2 joysticks"),
 ("Joystick", "F4 mode 3: both on port 2",
  "F4, mode 3; same checks.",
  "Both DB9 move port 2.",
  "2 joysticks"),
 ("Snapshots", "F2 save / load",
  "In a game (drive idle) F2, name, Enter. KEY0. F12 the .A64.",
  "Game continues where it was saved.",
  "Any game"),
 ("Snapshots", "Print Screen",
  "Print Screen in BASIC and in a game.",
  "SCRNnnnn.BMP on the card shows the screen (400 x 284).",
  "-"),
 ("ROMs", "1541 ROM added later",
  "Optional (needs a ROM image without the 1541 ROM in flash): with DOS1541* in /ROMS/C64, start L64.",
  "OSD 'Adding the 1541 ROM to the flash', C64 restarts, the drive works.",
  "Optional"),
 ("LSpectrum", "Spectrum regression",
  "Start LSpectrum: F12 a .tap and a .z80, F2 snapshot, Print Screen, KEY0.",
  "All work as before (the ESP link changed in both machines).",
  "ZX .tap and .z80"),
]

wb = Workbook()
ws = wb.active
ws.title = "Test Plan"
hdr = ["ID", "Area", "Test", "Steps", "Expected result", "Needs", "Result", "Notes"]
widths = [6, 11, 24, 48, 48, 22, 11, 32]
thin = Side(style="thin", color="A6A6A6")
box = Border(left=thin, right=thin, top=thin, bottom=thin)
hfill = PatternFill("solid", fgColor="1F3864")
infill = PatternFill("solid", fgColor="FFF2CC")       # cells to fill in

for c, (h, w) in enumerate(zip(hdr, widths), 1):
    cell = ws.cell(row=1, column=c, value=h)
    cell.font = Font(name=F, bold=True, color="FFFFFF", size=10)
    cell.fill = hfill
    cell.alignment = Alignment(vertical="center", wrap_text=True)
    cell.border = box
    ws.column_dimensions[cell.column_letter].width = w
ws.row_dimensions[1].height = 20

for r, (area, test, steps, exp, needs) in enumerate(T, 2):
    vals = ["T%02d" % (r - 1), area, test, steps, exp, needs, None, None]
    for c, v in enumerate(vals, 1):
        cell = ws.cell(row=r, column=c, value=v)
        cell.font = Font(name=F, size=9, bold=(c == 3))
        cell.alignment = Alignment(vertical="top", wrap_text=True)
        cell.border = box
        if c >= 7:
            cell.fill = infill
last = len(T) + 1

dv = DataValidation(type="list", formula1='"Pass,Fail,Skipped"', allow_blank=True)
ws.add_data_validation(dv)
dv.add("G2:G%d" % last)
ws.conditional_formatting.add("G2:G%d" % last, CellIsRule(operator="equal", formula=['"Pass"'], fill=PatternFill("solid", fgColor="C6EFCE")))
ws.conditional_formatting.add("G2:G%d" % last, CellIsRule(operator="equal", formula=['"Fail"'], fill=PatternFill("solid", fgColor="FFC7CE")))
ws.freeze_panes = "D2"
ws.auto_filter.ref = "A1:H%d" % last
ws.page_setup.orientation = "landscape"
ws.page_setup.paperSize = ws.PAPERSIZE_LETTER
ws.page_setup.fitToWidth = 1
ws.page_setup.fitToHeight = 0
ws.sheet_properties.pageSetUpPr.fitToPage = True
ws.print_title_rows = "1:1"
ws.page_margins.left = ws.page_margins.right = 0.5
ws.page_margins.top = ws.page_margins.bottom = 0.75

# Summary
s = wb.create_sheet("Summary")
s.column_dimensions["A"].width = 26
s.column_dimensions["B"].width = 12
s.column_dimensions["C"].width = 60
s["A1"] = "L64 final test round"
s["A1"].font = Font(name=F, bold=True, size=14, color="1F3864")
s["A2"] = "Hardware: L.jic 2026-10-29 12:06 (programmed with verify), ESP32 sketch 1,175,375 bytes"
s["A2"].font = Font(name=F, size=9, italic=True)
rows = [("Tests", "=COUNTA('Test Plan'!A2:A%d)" % last),
        ("Pass", "=COUNTIF('Test Plan'!G2:G%d,\"Pass\")" % last),
        ("Fail", "=COUNTIF('Test Plan'!G2:G%d,\"Fail\")" % last),
        ("Skipped", "=COUNTIF('Test Plan'!G2:G%d,\"Skipped\")" % last),
        ("Not run yet", "=B4-B5-B6-B7"),
        ("Done", "=IF(B4=0,0,(B5+B6+B7)/B4)")]
for i, (k, f) in enumerate(rows, 4):
    s.cell(row=i, column=1, value=k).font = Font(name=F, size=10, bold=True)
    c = s.cell(row=i, column=2, value=f)
    c.font = Font(name=F, size=10)
    if k == "Done":
        c.number_format = "0%"
s["A11"] = "How to use"
s["A11"].font = Font(name=F, bold=True, size=11)
legend = [
    "Fill in only the yellow columns of 'Test Plan': Result (drop-down: Pass / Fail / Skipped) and Notes.",
    "Notes example: \"Fail: LED blinks after SAVE, PRINT shows 26 WRITE PROTECT ON\" or \"Pass, 1:40 min at normal speed\".",
    "Keep a PC copy of every .d64 you write to, and compare after the disk tests.",
    "The counts above update by themselves.",
]
for i, t in enumerate(legend, 12):
    c = s.cell(row=i, column=1, value=t)
    c.font = Font(name=F, size=9)
s.page_setup.paperSize = s.PAPERSIZE_LETTER
wb.calculation.fullCalcOnLoad = True
wb.save(OUT)
print("written", OUT, len(T), "tests")
