# generates Extended/qm_atrix_ext.kicad_sch + qm_atrix_ext.kicad_sym from design.py
import sys, uuid, math, re
from sx import find_symbol, block_at, pins as sym_pins
from design import comps, LIB, POWER

OUT = sys.argv[1]
OLD = "/mnt/c/work/My/AlteraZX/QM_Atrix_adapter/qm_atrix.kicad_sch"
KLIB = "/mnt/c/Program Files/KiCad/10.0/share/kicad/symbols/"
PROJ = "qm_atrix_ext"
ROOT = str(uuid.uuid4())
U = lambda: str(uuid.uuid4())
old = open(OLD).read()

# ---------- library symbols ----------
LOCAL = {"DB15_Female_HighDensity": "Connector:DB15_Female_HighDensity",
         "Conn_01x04_Male": "Connector:Conn_01x04_Male", "7803_switcing": "Regulator_Linear:7803_switcing"}
libtext = {}   # full lib_id -> symbol text with unprefixed name
for name, oldid in LOCAL.items():
    t = find_symbol(old, oldid)
    t = t.replace(f'(symbol "{oldid}"', f'(symbol "{name}"', 1)
    if name == "DB9_Male":   # the as-built DB9 footprint has no shell pad: drop pin 0
        m = re.search(r'\(pin \w+ \w+\s*\(at [^)]*\)(?:(?!\(pin ).)*?\(number "0"', t, re.S)
        i = m.start(); t = t[:i] + t[block_at(t, i):]
    libtext[f"{LIB}:{name}"] = t
need = sorted({c["lib"] for c in comps} | {"power:GND", "power:+5V", "power:+3V3", "power:PWR_FLAG"})
for lid in need:
    if lid in libtext: continue
    lib, name = lid.split(":")
    t = find_symbol(open(KLIB + lib + ".kicad_sym").read(), name)
    assert t and "(extends" not in t, lid
    libtext[lid] = t
PINS = {lid: sym_pins(t) for lid, t in libtext.items()}

def indent(t, n):
    return "\n".join(("\t" * n + l.lstrip("\t")) if False else ("\t" * n + l) for l in t.split("\n"))

# ---------- geometry ----------
def xf(px, py, rot):
    """lib point -> schematic offset for a symbol rotated rot degrees (CCW on screen)"""
    dx, dy = px, -py
    for _ in range((rot // 90) % 4):
        dx, dy = dy, -dx
    return dx, dy
def g(v): return round(v / 1.27) * 1.27
def r2(v): return float(f"{v:.2f}")

items = []   # schematic text blocks
pwr_n = [0]

def font(sz=1.27, just=None, hide=False):
    j = f"\n\t\t\t\t(justify {just})" if just else ""
    return f"(effects\n\t\t\t\t(font\n\t\t\t\t\t(size {sz} {sz})\n\t\t\t\t){j}\n\t\t\t)"

def prop(name, val, x, y, hide=False, just=None, ang=0):
    h = "\n\t\t\t(hide yes)" if hide else ""
    return (f'\t\t(property "{name}" "{val}"\n\t\t\t(at {r2(x)} {r2(y)} {ang}){h}\n\t\t\t(show_name no)\n'
            f'\t\t\t(do_not_autoplace no)\n\t\t\t{font(just=just)}\n\t\t)')

def symbol(lid, ref, val, fp, x, y, rot, refpos, valpos, in_bom=True, on_board=None):
    on_board = in_bom if on_board is None else on_board
    pl = "\n".join(f'\t\t(pin "{p}"\n\t\t\t(uuid "{U()}")\n\t\t)' for p in PINS[lid])
    hide_ref = ref.startswith("#")
    fa = rot if rot in (90, 270) else 0
    s = (f'\t(symbol\n\t\t(lib_id "{lid}")\n\t\t(at {r2(x)} {r2(y)} {rot})\n\t\t(unit 1)\n\t\t(body_style 1)\n'
         f'\t\t(exclude_from_sim no)\n\t\t(in_bom {"yes" if in_bom else "no"})\n\t\t(on_board {"yes" if on_board else "no"})\n'
         f'\t\t(in_pos_files yes)\n\t\t(dnp no)\n\t\t(uuid "{U()}")\n'
         + prop("Reference", ref, *refpos, hide=hide_ref, just="left", ang=fa) + "\n"
         + prop("Value", val, *valpos, just="left", ang=fa) + "\n"
         + prop("Footprint", fp, x, y, hide=True) + "\n"
         + prop("Datasheet", "", x, y, hide=True) + "\n"
         + prop("Description", "", x, y, hide=True) + "\n"
         + pl + f'\n\t\t(instances\n\t\t\t(project "{PROJ}"\n\t\t\t\t(path "/{ROOT}"\n\t\t\t\t\t(reference "{ref}")\n'
         f'\t\t\t\t\t(unit 1)\n\t\t\t\t)\n\t\t\t)\n\t\t)\n\t)')
    items.append(s)

def wire(x1, y1, x2, y2):
    items.append(f'\t(wire\n\t\t(pts\n\t\t\t(xy {r2(x1)} {r2(y1)}) (xy {r2(x2)} {r2(y2)})\n\t\t)\n'
                 f'\t\t(stroke\n\t\t\t(width 0)\n\t\t\t(type default)\n\t\t)\n\t\t(uuid "{U()}")\n\t)')

def label(net, x, y, d):
    ang, just = {(1, 0): (0, "left bottom"), (-1, 0): (180, "right bottom"),
                 (0, -1): (90, "left bottom"), (0, 1): (270, "right bottom")}[d]
    items.append(f'\t(label "{net}"\n\t\t(at {r2(x)} {r2(y)} {ang})\n\t\t{font(just=just)}\n\t\t(uuid "{U()}")\n\t)')

def nc(x, y):
    items.append(f'\t(no_connect\n\t\t(at {r2(x)} {r2(y)})\n\t\t(uuid "{U()}")\n\t)')

def power(net, x, y, d):
    """power symbol whose body points along d, pin at (x,y)"""
    pwr_n[0] += 1
    if net == "GND":
        rot = {(0, 1): 0, (1, 0): 90, (0, -1): 180, (-1, 0): 270}[d]
    else:
        rot = {(0, -1): 0, (-1, 0): 90, (0, 1): 180, (1, 0): 270}[d]
    tx, ty = x + d[0] * 5.08, y + d[1] * 5.08
    if d[0] < 0: tx -= 3.0
    symbol(f"power:{net}", f"#PWR{pwr_n[0]:02d}", net, "", x, y, rot, (tx, ty + 2.5), (tx, ty), in_bom=False)

def text(t, x, y, sz=2.0):
    items.append(f'\t(text "{t}"\n\t\t(exclude_from_sim no)\n\t\t(at {r2(x)} {r2(y)} 0)\n\t\t{font(sz, "left bottom")}\n\t\t(uuid "{U()}")\n\t)')

STUB = 2.54
def place(c, x, y, rot=0, refpos=None, valpos=None):
    lid = c["lib"]
    pts = PINS[lid]
    xs = [xf(px, py, rot) for px, py, a, t in pts.values()] or [(0, 0)]
    minx = min(p[0] for p in xs); maxx = max(p[0] for p in xs); miny = min(p[1] for p in xs)
    maxy = max(p[1] for p in xs)
    if refpos is None:
        if len(pts) <= 3:
            refpos = (x + 2.0, y - 1.0) if rot % 180 == 0 else (x - 2.5, y - 2.5)
            valpos = (x + 2.0, y + 2.2) if rot % 180 == 0 else (x - 2.5, y + 3.6)
        else:
            refpos = (x + minx, y + miny - 3.0); valpos = (x + minx, y + maxy + 4.0)
    symbol(lid, c["ref"], c["val"], c["fp"], x, y, rot, refpos, valpos, in_bom=not c["ref"].startswith("H"), on_board=True)
    for p, (px, py, a, t) in pts.items():
        dx, dy = xf(px, py, rot)
        ex, ey = x + dx, y + dy
        # direction from pin end into body, flip it for the stub
        bx, by = xf(round(math.cos(math.radians(a))), round(math.sin(math.radians(a))), rot)
        d = (-bx, -by)
        net = c["pins"].get(p)
        if net is None:
            nc(ex, ey); continue
        sx_, sy_ = ex + d[0] * STUB, ey + d[1] * STUB
        wire(ex, ey, sx_, sy_)
        if net in POWER: power(net, sx_, sy_, d)
        else: label(net, sx_, sy_, d)

C = {c["ref"]: c for c in comps}

# ---------- placement (A3, mm, on 2.54 grid) ----------
text("Host connector (wires to the Cyclone IV board, all signals 3.3 V)", 30.48, 63.5)
place(C["J1"], 63.5, 101.6)
for i, (net, x) in enumerate((("+5V", 25.4), ("GND", 38.1))):
    pass

text("VGA: 4-bit DAC per colour (523/1.05k/2.1k/4.22k = 0.7 V full scale into 75 Ohm)", 139.7, 38.1)
for i in range(12):
    col, row = divmod(i, 4)
    place(C[f"R{i+1}"], 160.02 + col * 50.8, 45.72 + row * 10.16, 90)
place(C["R13"], 160.02, 88.9, 90); place(C["R14"], 210.82, 88.9, 90)
for i in range(5):
    place(C[f"C{i+1}"], 160.02 + i * 17.78, 106.68)
place(C["J2"], 330.2, 76.2)

for j, (y, jref, r0) in enumerate(((147.32, "J4", 15), (198.12, "J6", 20))):
    text(f"Joystick {j+1} (Atari/Kempston, right-angle DB9 male, pin 7 not connected)", 139.7, y - 12.7)
    for k in range(5):
        place(C[f"R{r0+k}"], 157.48 + k * 15.24, y)
    place(C[jref], 251.46, y + 7.62)

text("microSD (SPI mode)", 292.1, 147.32)
place(C["J7"], 360.68, 177.8)
for k in range(5):
    place(C[f"R{25+k}"], 299.72 + k * 12.7, 220.98)
place(C["C6"], 368.3, 220.98); place(C["C7"], 381.0, 220.98)

text("Audio out: volume pots, line level to an external amplifier", 22.86, 152.4)
place(C["R30"], 38.1, 167.64, 90)
place(C["C8"], 55.88, 177.8)
place(C["C9"], 73.66, 167.64, 90)
place(C["C10"], 38.1, 195.58, 90)
place(C["RV1"], 101.6, 167.64, refpos=(93.0, 172.0), valpos=(93.0, 174.5))
place(C["RV2"], 101.6, 195.58, refpos=(93.0, 200.0), valpos=(93.0, 202.5))
place(C["J3"], 132.08, 182.88)

text("Keyboard module (USB HID -> UART, 3.3 V levels)", 22.86, 218.44)
place(C["J5"], 33.02, 232.41)

text("Power: 5 V in, 7803 switching module (SIP-3) -> 3.3 V", 22.86, 251.46)
place(C["U1"], 40.64, 266.7, refpos=(36.0, 259.0), valpos=(44.0, 259.0))
for k, r in enumerate(("C11", "C12", "C13", "C14", "C15", "C16", "C17")):
    place(C[r], 71.12 + k * 12.7, 266.7)
for k in range(4):
    place(C[f"H{k+1}"], 228.6 + k * 12.7, 266.7, refpos=(226.0 + k * 12.7, 261.0), valpos=(226.0 + k * 12.7, 272.0))
text("Mounting holes", 223.52, 254.0)
# PWR_FLAGs: flag -> wire down -> power symbol
for k, net in enumerate(("+5V", "GND")):
    x, y = 165.1 + k * 15.24, 261.62
    pwr_n[0] += 1
    symbol("power:PWR_FLAG", f"#FLG{k+1:02d}", "PWR_FLAG", "", x, y, 0, (x + 1.5, y - 6), (x + 1.5, y - 3.5), in_bom=False)
    wire(x, y, x, y + 2.54)
    power(net, x, y + 2.54, (0, 1))

# ---------- write schematic ----------
def embed(lid, t):
    name = lid.split(":")[1]
    t = t.replace(f'(symbol "{name}"', f'(symbol "{lid}"', 1)
    return "\n".join("\t\t" + l.lstrip("\t") if False else re.sub(r"^", "\t", l) for l in t.split("\n"))

hdr = (f'(kicad_sch\n\t(version 20260306)\n\t(generator "eeschema")\n\t(generator_version "10.0")\n'
       f'\t(uuid "{ROOT}")\n\t(paper "A3")\n\t(title_block\n\t\t(title "QM_Atrix Extended I/O board")\n'
       f'\t\t(date "2026-10-13")\n\t\t(rev "1")\n\t\t(comment 1 "Separate board, wired to the QMTECH Cyclone IV board via J1")\n'
       f'\t\t(comment 2 "4-bit VGA DAC, 2 joysticks, microSD, audio out (2 volume pots), keyboard module header")\n\t)\n\t(lib_symbols\n')
body = hdr + "\n".join(embed(l, libtext[l]) for l in sorted(libtext)) + "\n\t)\n" + "\n".join(items) + \
    '\n\t(sheet_instances\n\t\t(path "/"\n\t\t\t(page "1")\n\t\t)\n\t)\n\t(embedded_fonts no)\n)\n'
open(OUT + f"/{PROJ}.kicad_sch", "w", newline="\n").write(body)

# local symbol library
lib = '(kicad_symbol_lib\n\t(version 20251024)\n\t(generator "kicad_symbol_editor")\n\t(generator_version "10.0")\n'
for lid in sorted(libtext):
    if lid.startswith(LIB + ":"):
        lib += "\n".join("\t" + l for l in libtext[lid].split("\n")) + "\n"
open(OUT + f"/{LIB}.kicad_sym", "w", newline="\n").write(lib + ")\n")
print("ok", len(items))
