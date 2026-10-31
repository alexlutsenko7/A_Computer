"""ltari_testplan.py OUT.xlsx -- the first LTari hardware test plan (docs/LTari_Test_Plan.xlsx,
sheets Test Plan and Summary; layout as l64_testplan.py). Needs openpyxl (the Windows Python has it).
"""
import sys
from openpyxl import Workbook
from openpyxl.styles import Font, Alignment, PatternFill, Border, Side
from openpyxl.worksheet.datavalidation import DataValidation
from openpyxl.formatting.rule import CellIsRule

OUT = sys.argv[1]
F = "Arial"
HW = "Hardware: L.jic and ESP32 sketch built 2026-10-29 evening (ESP32 still to upload)"

# (area, test, steps, expected, needs)
T = [
 ("Start", "Menu with four machines",
  "Power on.",
  "The menu lists 1 LSpectrum, 2 L64, 3 LTari 800, 4 LTari 130.",
  "-"),
 ("Start", "LTari 130 boots",
  "Choose 4 LTari 130 (no disk inserted).",
  "No signal ~2 s, blue screen; ~1 s later \"Altirra 8K BASIC 1.59\" and \"Ready\".",
  "-"),
 ("Start", "130XE extra memory",
  "In LTari 130 type: POKE 16384,11:POKE 54017,225:POKE 16384,77:POKE 54017,253:?PEEK(16384)",
  "Prints 11 (the 77 went into extended bank 0, not main RAM).",
  "-"),
 ("Start", "LTari 800 has no extra memory",
  "Ctrl+Alt+Del, choose 3 LTari 800, type the same line as the test before.",
  "Prints 77 (no banking on the 800XL).",
  "-"),
 ("Keys", "Typing",
  "Type letters, digits, Shift+digits, - = ; , . / and ' \\ [ ] ` , Caps Lock, Backspace.",
  "Each key gives the Atari character from the README table; ` toggles inverse video.",
  "-"),
 ("Keys", "Cursor and editing",
  "Arrows, Home, Delete, Insert on a typed line.",
  "Arrows move the cursor; Home clears the screen; Delete removes / Insert opens a character.",
  "-"),
 ("Keys", "Break",
  "Type 10 GOTO 10, RUN, then press Pause.",
  "\"Stopped at line 10\" (or similar) and Ready.",
  "-"),
 ("Keys", "Console keys",
  "Type 10 ?PEEK(53279):GOTO 10, RUN; hold Alt+F2, then Alt+F3, then Alt+F4; Pause to stop.",
  "7 with nothing held; 6 / 5 / 3 while START / SELECT / OPTION are held.",
  "-"),
 ("Keys", "Reset key",
  "Type 10 ?1, then Alt+F5, then LIST.",
  "Screen restarts into Ready; LIST still shows line 10 (warm start keeps the program).",
  "-"),
 ("Keys", "No BASIC with OPTION",
  "In LTari 130 hold Alt+F4, press KEY0, keep holding until the screen comes up.",
  "No Altirra BASIC banner (the OS's own screen instead).",
  "-"),
 ("Sound", "POKEY tone",
  "SOUND 0,121,10,8 then SOUND 0,0,0,0",
  "A steady tone (about middle C) on the audio jack and Bluetooth; silence after the second command.",
  "Speaker or headphones"),
 ("Sound", "Keyboard click",
  "Type a few keys with sound on.",
  "A short click per key (console speaker).",
  "-"),
 ("Joystick", "Stick 0",
  "Type 10 ?STICK(0),STRIG(0):GOTO 10, RUN; move the joystick in DB9-1, press fire.",
  "15 1 at rest; 14 up, 13 down, 11 left, 7 right; STRIG 0 while fire is held.",
  "Joystick"),
 ("Joystick", "Stick 1 and F4 swap",
  "Same with STICK(1),STRIG(1) and the joystick in DB9-2; then F4 -> DB9-1 = stick 1.",
  "DB9-2 drives stick 1; after the swap DB9-1 drives stick 1.",
  "Joystick"),
 ("Video", "F8 50 / 60 Hz",
  "F8, wait, F8 again.",
  "50 Hz picture, then 60 Hz again; the Atari keeps running; no line at the right edge.",
  "-"),
 ("Video", "Graphics modes",
  "GRAPHICS 7:COLOR 1:PLOT 0,0:DRAWTO 159,79   then   GRAPHICS 8:COLOR 1:PLOT 0,0:DRAWTO 319,159",
  "A diagonal line in each mode, the second one thinner (hi-res).",
  "-"),
 ("Video", "GTIA mode 9 (16 shades)",
  "GRAPHICS 9:FOR I=0 TO 15:COLOR I:PLOT I*4,0:DRAWTO I*4,150:NEXT I:FOR I=1 TO 2000:NEXT I",
  "16 vertical bars from black to white in one colour.",
  "-"),
 ("Video", "Colours",
  "SETCOLOR 2,3,6   then   SETCOLOR 4,9,4",
  "Background turns red-orange; then the border turns blue.",
  "-"),
 ("Video", "Player graphics",
  "10 POKE 54279,128:POKE 559,46:POKE 53277,3:POKE 704,68:POKE 53248,120  20 FOR I=0 TO 127:POKE 33280+I,0:NEXT I  30 FOR I=50 TO 57:POKE 33280+I,255:NEXT I   RUN",
  "A small purple-red square in the middle of the screen, over the text.",
  "-"),
 ("Disk", ".atr boot",
  "F12, choose a bootable .atr (a DOS disk or a game).",
  "Note \"D1: name\", the Atari restarts and boots it (the ESP32's serial log shows no errors).",
  ".atr on the card"),
 ("Disk", ".atr write",
  "Boot a DOS 2.x .atr (with BASIC), type 10 ?1, SAVE \"D:TEST\", NEW, LOAD \"D:TEST\", LIST.",
  "Line 10 comes back; on the PC the .atr has changed (compare with the copy).",
  "DOS .atr, PC copy"),
 ("Disk", ".xex",
  "F12, choose an .xex game.",
  "Note \"Run: name\", the Atari restarts, loads (a few seconds) and runs the program.",
  ".xex on the card"),
 ("Disk", ".car",
  "F12, choose a standard 8 KB or 16 KB .car, then an Atarimax 128 KB / 1 MB .car (many newer games).",
  "Note \"Cartridge: name\", the Atari restarts into the cartridge. Other types: \"Cart type not yet\".",
  ".car on the card"),
 ("System", "Screenshot",
  "In BASIC with some text on the screen press Print Screen.",
  "Note \"Saved SCRNnnnn.BMP\"; on the PC the BMP shows the Atari screen (376 x 240) in the right colours.",
  "SD card"),
 ("System", "Back to the menu",
  "Ctrl+Alt+Del in LTari; then KEY1 in LTari.",
  "The menu each time; LSpectrum and L64 still start and work (F12 OSD in each).",
  "-"),
 ("System", "KEY0",
  "In LTari press KEY0.",
  "A fresh start into BASIC (cartridge removed); the ESP32 restarts, F12 works.",
  "-"),
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
s["A1"] = "LTari first test round"
s["A1"].font = Font(name=F, bold=True, size=14, color="1F3864")
s["A2"] = HW
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
    "Notes example: \"Fail: Error 138 after the second sector\" or \"Pass, booted in 6 s\".",
    "Keep a PC copy of every .atr you write to, and compare after the disk tests.",
    "Type the BASIC lines exactly; on this keyboard + is the ' key, \" is Shift+2, : is Shift+;, * is \\.",
    "The counts above update by themselves.",
]
for i, t in enumerate(legend, 12):
    c = s.cell(row=i, column=1, value=t)
    c.font = Font(name=F, size=9)
s.page_setup.paperSize = s.PAPERSIZE_LETTER
wb.calculation.fullCalcOnLoad = True
wb.save(OUT)
print("written", OUT, len(T), "tests")
