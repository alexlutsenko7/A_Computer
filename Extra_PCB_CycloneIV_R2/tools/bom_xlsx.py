"""bom_xlsx.py BOM.csv OUT.xlsx -- the JLCPCB BOM (made by jlc_export.py) as an .xlsx for another assembly house:
one line per part with quantity, description, manufacturer and manufacturer part number; the LCSC number stays as a
reference. Needs openpyxl (the Windows Python has it).

Manufacturer part numbers are given only where the project records them (jlc_export.py's comments, the part's own
name, docs/vendor datasheets); the other passives are described by value, tolerance and size, with "any" as maker.
"""
import csv
import sys
from openpyxl import Workbook
from openpyxl.styles import Font, Alignment, PatternFill, Border, Side

# the sheet's font and sizes
FONT_NAME = "Arial"
FONT_SIZE = 10
# header fill (dark blue) and its text colour
HEAD_FILL = "1F3864"
HEAD_TEXT = "FFFFFF"
# thin grey cell borders
LINE_COLOUR = "A6A6A6"
# first data row (row 1 is the header)
FIRST_ROW = 2
# column titles and widths (characters)
COLUMNS = [("Item", 6), ("Qty", 6), ("Designator", 34), ("Value", 24), ("Description", 44), ("Manufacturer", 22),
           ("Manufacturer Part #", 28), ("Footprint", 40), ("Mount", 8), ("LCSC Part #", 13)]
# what any maker's part may replace
ANY = "any"

# LCSC part -> (description, manufacturer, manufacturer part number, mount)
PARTS = {
    "C318672": ("Capacitor 6.8 pF C0G / NP0 0603, 50 V", ANY, "", "SMD"),
    "C14663": ("Capacitor 100 nF X7R 0603, 16 V or more", ANY, "", "SMD"),
    "C15850": ("Capacitor 10 uF X5R 0805, 25 V", "Samsung", "CL21A106KAYNNNE", "SMD"),
    "C15849": ("Capacitor 1 uF X5R 0603, 50 V", "Samsung", "CL10A105KB8NNNC", "SMD"),
    "C45783": ("Capacitor 22 uF X5R 0805, 25 V", "Samsung", "CL21A226MAQNNNE", "SMD"),
    "C19666": ("Capacitor 4.7 uF X5R 0603, 16 V", "Samsung", "CL10A475KO8NNNC", "SMD"),
    "C15008": ("Capacitor 100 uF X5R 1206, 6.3 V", "Samsung", "CL31A107MQHNNNE", "SMD"),
    "C75754": ("D-sub HD 15 socket (VGA), right angle, through hole", "CONNFLY", "DS1038 series", "THT"),
    "C95562": ("3.5 mm audio jack, 4 pole, SMD", "Korean Hroparts", "PJ-320D-4A", "SMD"),
    "C75750": ("D-sub 9 plug (pins), right angle, through hole", "CONNFLY", "DS1037 series", "THT"),
    "C165948": ("USB Type-C receptacle, 16 pin, SMD", "Korean Hroparts", "TYPE-C-31-M-12", "SMD"),
    "C585350": ("microSD card socket, push-push", "Molex", "104031-0811", "SMD"),
    "C19944603": ("USB Type-A receptacle, right angle, through hole", "CONNFLY", "DS1095-WNR0", "THT"),
    "C20526": ("NPN transistor SOT-23", "JSCJ (or any)", "MMBT3904", "SMD"),
    "C23199": ("Resistor 523 R 1 % 0603", ANY, "", "SMD"),
    "C22832": ("Resistor 1.05 k 1 % 0603", ANY, "", "SMD"),
    "C22902": ("Resistor 2.1 k 1 % 0603", ANY, "", "SMD"),
    "C23042": ("Resistor 4.22 k 1 % 0603", ANY, "", "SMD"),
    "C23345": ("Resistor 22 R 1 % 0603", ANY, "", "SMD"),
    "C22978": ("Resistor 3.3 k 1 % 0603", ANY, "", "SMD"),
    "C25804": ("Resistor 10 k 1 % 0603", ANY, "", "SMD"),
    "C27592": ("Resistor 68 R 1 % 0603", ANY, "", "SMD"),
    "C4190": ("Resistor 2.2 k 1 % 0603", ANY, "", "SMD"),
    "C21190": ("Resistor 1 k 1 % 0603", ANY, "", "SMD"),
    "C23186": ("Resistor 5.1 k 1 % 0603", "UNI-ROYAL (or any)", "0603WAF5101T5E", "SMD"),
    "C31850": ("Resistor 22 k 1 % 0603", "UNI-ROYAL (or any)", "0603WAF2202T5E", "SMD"),
    "C23061": ("Resistor 47.5 k 1 % 0603", ANY, "", "SMD"),
    "C116501": ("Tactile switch SMD", "C&K", "PTS810 series", "SMD"),
    "C435835": ("LDO regulator 3.3 V 1.2 A, SOT-223", "STMicroelectronics", "LDL1117S33R", "SMD"),
    "C529589": ("Wi-Fi / Bluetooth module, 16 MB flash, 8 MB PSRAM", "Espressif", "ESP32-WROVER-E-N16R8", "SMD"),
    "C969151": ("USB to UART bridge, QFN-24", "Silicon Labs", "CP2102N-A02-GQFN24", "SMD"),
    "C109472": ("USB keyboard / mouse to UART, LQFP-48", "WCH", "CH9350L", "SMD"),
    "C7519": ("USB ESD protection, SOT-23-6", "STMicroelectronics", "USBLC6-2SC6", "SMD"),
}

src, out = sys.argv[1:3]
rows = list(csv.DictReader(open(src, newline="")))
# every line of the BOM must be known here
unknown = [r["LCSC Part #"] for r in rows if r["LCSC Part #"] not in PARTS]
assert not unknown, unknown

wb = Workbook()
ws = wb.active
ws.title = "BOM"
side = Side(style="thin", color=LINE_COLOUR)
box = Border(left=side, right=side, top=side, bottom=side)

# the header row
for col, (title, width) in enumerate(COLUMNS, start=1):
    c = ws.cell(row=1, column=col, value=title)
    c.font = Font(name=FONT_NAME, size=FONT_SIZE, bold=True, color=HEAD_TEXT)
    c.fill = PatternFill("solid", fgColor=HEAD_FILL)
    # centred, wrapped
    c.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)
    c.border = box
    ws.column_dimensions[c.column_letter].width = width

# one row per BOM line
total = 0
for n, r in enumerate(rows):
    desc, maker, mpn, mount = PARTS[r["LCSC Part #"]]
    refs = r["Designator"].split(",")
    total += len(refs)
    # the cells in the order of COLUMNS
    cells = [n + 1, len(refs), ", ".join(refs), r["Comment"], desc, maker, mpn, r["Footprint"], mount, r["LCSC Part #"]]
    for col, value in enumerate(cells, start=1):
        c = ws.cell(row=FIRST_ROW + n, column=col, value=value)
        c.font = Font(name=FONT_NAME, size=FONT_SIZE)
        # long texts wrap; all cells sit at the top
        c.alignment = Alignment(vertical="top", wrap_text=True)
        c.border = box

# the header stays in view; the columns can be filtered
ws.freeze_panes = ws.cell(row=FIRST_ROW, column=1)
ws.auto_filter.ref = ws.dimensions
wb.save(out)
print("%d BOM lines, %d parts -> %s" % (len(rows), total, out))
