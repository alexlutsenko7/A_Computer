# gen_sch.py OUTDIR -- writes Extra_PCB_CycloneIV_R2.kicad_sch + .kicad_sym from design.py (ANSI B sheet, 17 x 11 in).
# One-shot generator: once the schematic is edited in KiCad, the KiCad file is the source of truth.
import sys, uuid, math, re, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sx import find_symbol
from design import comps, LIB, POWER

OUT = sys.argv[1]
R1 = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../Extra_PCB_CycloneIV/Extra_PCB_CycloneIV.kicad_sym")
KLIB = "/mnt/c/Program Files/KiCad/10.0/share/kicad/symbols/"
PROJ = LIB
ROOT = str(uuid.uuid4())
U = lambda: str(uuid.uuid4())

# ---------- CH9350L symbol (WCH datasheet V2.6: LQFP-48; NC pins must stay open: hidden no-connect pins) ----------
def pin_sx(typ, x, y, ang, name, num, hide=False, length=2.54):
    h = "\n\t\t\t\t(hide yes)" if hide else ""
    f = "(effects\n\t\t\t\t\t\t(font\n\t\t\t\t\t\t\t(size 1.27 1.27)\n\t\t\t\t\t\t)\n\t\t\t\t\t)"
    return (f'\t\t\t(pin {typ} line\n\t\t\t\t(at {x} {y} {ang})\n\t\t\t\t(length {length}){h}\n'
            f'\t\t\t\t(name "{name}"\n\t\t\t\t\t{f}\n\t\t\t\t)\n\t\t\t\t(number "{num}"\n\t\t\t\t\t{f}\n\t\t\t\t)\n\t\t\t)')

def prop_sx(name, val, x, y, hide=False):
    h = "\n\t\t\t(hide yes)" if hide else ""
    return (f'\t\t(property "{name}" "{val}"\n\t\t\t(at {x} {y} 0)\n\t\t\t(show_name no)\n\t\t\t(do_not_autoplace no){h}\n'
            f'\t\t\t(effects\n\t\t\t\t(font\n\t\t\t\t\t(size 1.27 1.27)\n\t\t\t\t)\n\t\t\t)\n\t\t)')

def ch9350_symbol():
    left = [("power_in", "VIN5", 41), ("power_out", "VDD33", 42), ("input", "RST", 3), ("input", "SEL", 45),
            ("input", "S0", 4), ("input", "S1", 5), ("input", "BAUD0", 38), ("input", "BAUD1", 37),
            ("input", "~{xOSC}", 6), ("input", "XI", 16), ("input", "RXD", 27)]
    right = [("output", "TXD", 28), ("output", "TNOW", 26), ("bidirectional", "DP", 31), ("bidirectional", "DM", 32),
             ("bidirectional", "HP", 29), ("bidirectional", "HM", 30), ("output", "LED0", 48), ("output", "LED1", 1),
             ("output", "LED2", 2), ("bidirectional", "IO1", 21), ("bidirectional", "IO2", 22),
             ("bidirectional", "IO3", 23), ("bidirectional", "IO4", 24), ("output", "DEBUG", 7), ("output", "XO", 17)]
    nc = [8, 9, 10, 11, 12, 13, 14, 15, 19, 20, 25, 33, 34, 35, 36, 39, 40, 43, 44, 46, 47]
    top = 17.78
    pins = []
    ly = [top, top - 5.08, top - 10.16] + [round(top - 15.24 - k * 2.54, 2) for k in range(len(left) - 3)]
    for (t, nm, n), yy in zip(left, ly):
        pins.append(pin_sx(t, -15.24, yy, 0, nm, n))
    for i, (t, nm, n) in enumerate(right):
        pins.append(pin_sx(t, 15.24, round(top - i * 2.54, 2), 180, nm, n))
    bot = round(min(top - len(right) * 2.54, ly[-1] - 2.54), 2)
    pins.append(pin_sx("power_in", 0, round(bot - 2.54, 2), 90, "GND", 18))
    for n in nc:
        pins.append(pin_sx("no_connect", 0, 0, 0, "NC", n, hide=True))
    rect = (f'\t\t(symbol "CH9350L_0_1"\n\t\t\t(rectangle\n\t\t\t\t(start -12.7 {top + 2.54})\n\t\t\t\t(end 12.7 {bot})\n'
            f'\t\t\t\t(stroke\n\t\t\t\t\t(width 0.254)\n\t\t\t\t\t(type default)\n\t\t\t\t)\n\t\t\t\t(fill\n\t\t\t\t\t(type background)\n\t\t\t\t)\n\t\t\t)\n\t\t)')
    return ('(symbol "CH9350L"\n\t\t(pin_names\n\t\t\t(offset 1.016)\n\t\t)\n\t\t(exclude_from_sim no)\n\t\t(in_bom yes)\n'
            '\t\t(on_board yes)\n\t\t(in_pos_files yes)\n\t\t(duplicate_pin_numbers_are_jumpers no)\n'
            + prop_sx("Reference", "U", -12.7, top + 5.08) + "\n" + prop_sx("Value", "CH9350L", 0, top + 5.08) + "\n"
            + prop_sx("Footprint", "Package_QFP:LQFP-48_7x7mm_P0.5mm", 0, 0, True) + "\n"
            + prop_sx("Datasheet", "https://www.wch.cn/downloads/CH9350DS1_PDF.html", 0, 0, True) + "\n"
            + prop_sx("Description", "USB keyboard / mouse to UART, 2 USB host ports, LQFP-48", 0, 0, True) + "\n"
            + rect + '\n\t\t(symbol "CH9350L_1_1"\n' + "\n".join(pins) + "\n\t\t)\n\t)")

# ---------- library symbols ----------
libtext = {}
BASE = {}   # derived lib id -> base lib id
r1 = open(R1).read()
t = find_symbol(r1, "DB15_Female_HighDensity")
libtext[f"{LIB}:DB15_Female_HighDensity"] = t
libtext[f"{LIB}:CH9350L"] = ch9350_symbol()
# ESP32-WROVER-E: KiCad's ESP32-WROOM-32E symbol (the same pin numbers) with pins 27 / 28 (IO16 / IO17 on the WROOM,
# the PSRAM's on the WROVER) as NC
def wrover_symbol():
    s = open(KLIB + "RF_Module.kicad_sym").read()
    t = find_symbol(s, "ESP32-WROOM-32E")
    t = t.replace('(symbol "ESP32-WROOM-32E', '(symbol "ESP32-WROVER-E')
    t = re.sub(r'(\(property "Value" ")[^"]*', r'\1ESP32-WROVER-E', t, count=1)
    t = re.sub(r'(\(property "Footprint" ")[^"]*', r'\1' + LIB + ':ESP32-WROVER-E', t, count=1)
    for io, num in (("IO16", "27"), ("IO17", "28")):
        m = re.search(r'\(pin \w+ (\w+)(\s*\(at [^)]*\)\s*\(length [\d.]+\)\s*\(name ")' + io + r'"(.*?)\(number "' + num + '"', t, re.S)
        assert m, io
        t = t[:m.start()] + f'(pin no_connect {m.group(1)}{m.group(2)}NC"{m.group(3)}(number "{num}"' + t[m.end():]
    return t
libtext[f"{LIB}:ESP32-WROVER-E"] = wrover_symbol()
need = sorted({c["lib"] for c in comps} | {"power:GND", "power:+5V", "power:+3V3", "power:PWR_FLAG"})
for lid in need:
    if lid in libtext:
        continue
    lib, name = lid.split(":")
    s = open(KLIB + lib + ".kicad_sym").read()
    t = find_symbol(s, name)
    assert t, lid
    m = re.search(r'\(extends "([^"]+)"\)', t)
    if m:   # derived symbol: use the base symbol (same pins); the value names the part
        base = m.group(1)
        BASE[lid] = f"{lib}:{base}"
        t = find_symbol(s, base)
        lid = BASE[lid]
    libtext[lid] = t

PIN_RE = re.compile(r'\(pin (\w+) \w+\s*\(at ([-\d.]+) ([-\d.]+) ([-\d.]+)\)\s*\(length ([\d.]+)\)(.*?)\(number "([^"]*)"', re.S)
def sym_pins(t):
    return {m.group(7): (float(m.group(2)), float(m.group(3)), int(float(m.group(4))), m.group(1)) for m in PIN_RE.finditer(t)}
PINS = {lid: sym_pins(t) for lid, t in libtext.items()}

# ---------- geometry / items ----------
def xf(px, py, rot):
    dx, dy = px, -py
    for _ in range((rot // 90) % 4):
        dx, dy = dy, -dx
    return dx, dy
def r2(v): return float(f"{v:.2f}")
items = []
pwr_n = [0]

def font(sz=1.27, just=None):
    j = f"\n\t\t\t\t(justify {just})" if just else ""
    return f"(effects\n\t\t\t\t(font\n\t\t\t\t\t(size {sz} {sz})\n\t\t\t\t){j}\n\t\t\t)"

def prop(name, val, x, y, hide=False, just=None, ang=0):
    h = "\n\t\t\t(hide yes)" if hide else ""
    return (f'\t\t(property "{name}" "{val}"\n\t\t\t(at {r2(x)} {r2(y)} {ang}){h}\n\t\t\t(show_name no)\n'
            f'\t\t\t(do_not_autoplace no)\n\t\t\t{font(just=just)}\n\t\t)')

def symbol(lid, ref, val, fp, x, y, rot, refpos, valpos, in_bom=True, on_board=True, dnp=False, mpn="", hide_val=False,
           mirror=False):
    pl = "\n".join(f'\t\t(pin "{p}"\n\t\t\t(uuid "{U()}")\n\t\t)' for p in PINS[lid])
    hide_ref = ref.startswith("#")
    fa = rot if rot in (90, 270) else 0
    extra = ("\n" + prop("MPN", mpn, x, y, hide=True)) if mpn else ""
    s = (f'\t(symbol\n\t\t(lib_id "{lid}")\n\t\t(at {r2(x)} {r2(y)} {rot})\n{chr(9)*2 + "(mirror y)" + chr(10) if mirror else ""}\t\t(unit 1)\n\t\t(body_style 1)\n'
         f'\t\t(exclude_from_sim no)\n\t\t(in_bom {"yes" if in_bom else "no"})\n\t\t(on_board {"yes" if on_board else "no"})\n'
         f'\t\t(in_pos_files yes)\n\t\t(dnp {"yes" if dnp else "no"})\n\t\t(uuid "{U()}")\n'
         + prop("Reference", ref, *refpos, hide=hide_ref, just="left", ang=fa) + "\n"
         + prop("Value", val, *valpos, hide=hide_val, just="left", ang=fa) + "\n"
         + prop("Footprint", fp, x, y, hide=True) + "\n"
         + prop("Datasheet", "", x, y, hide=True) + "\n"
         + prop("Description", "", x, y, hide=True) + extra + "\n"
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

PWR_AT = []   # (net, x, y) of placed power symbols
def power(net, x, y, d):
    pwr_n[0] += 1
    # GND symbols need no text; a second symbol of the same net on an adjacent pin neither
    hide = net == "GND" or any(n == net and abs(px - x) < 3.5 and abs(py - y) < 3.5 for n, px, py in PWR_AT)
    PWR_AT.append((net, x, y))
    if net == "GND":
        rot = {(0, 1): 0, (1, 0): 90, (0, -1): 180, (-1, 0): 270}[d]
    else:
        rot = {(0, -1): 0, (-1, 0): 90, (0, 1): 180, (1, 0): 270}[d]
    tx, ty = x + d[0] * 5.08, y + d[1] * 5.08
    if d[0] < 0: tx -= 3.0
    symbol(f"power:{net}", f"#PWR{pwr_n[0]:03d}", net, "", x, y, rot, (tx, ty + 2.5), (tx, ty), in_bom=False, on_board=True,
           hide_val=hide)

def text(t, x, y, sz=2.0):
    items.append(f'\t(text "{t}"\n\t\t(exclude_from_sim no)\n\t\t(at {r2(x)} {r2(y)} 0)\n\t\t{font(sz, "left bottom")}\n\t\t(uuid "{U()}")\n\t)')

STUB = 2.54
SEGS = []   # (net, x1, y1, x2, y2, what): every stub, for the collision check
def place(c, x, y, rot=0, refpos=None, valpos=None, mirror=False):
    m = -1 if mirror else 1   # mirror y (left-right), only used with rot 0
    lid = BASE.get(c["lib"], c["lib"])
    pts = PINS[lid]
    vis = {p: v for p, v in pts.items() if v[3] != "no_connect"}
    xs = [(m * xf(px, py, rot)[0], xf(px, py, rot)[1]) for px, py, a, t in vis.values()] or [(0, 0)]
    minx = min(p[0] for p in xs); miny = min(p[1] for p in xs); maxy = max(p[1] for p in xs)
    if refpos is None:
        if len(vis) <= 3:
            refpos = (x + 2.0, y - 1.0) if rot % 180 == 0 else (x - 2.5, y - 2.5)
            valpos = (x + 2.0, y + 2.2) if rot % 180 == 0 else (x - 2.5, y + 3.6)
        else:
            refpos = (x + minx, y + miny - 3.0); valpos = (x + minx, y + maxy + 12.7)
    symbol(lid, c["ref"], c["val"], c["fp"], x, y, rot, refpos, valpos,
           in_bom=not c["ref"].startswith("H") and not c.get("dnp"), on_board=True, dnp=c.get("dnp", False),
           mpn=c.get("mpn", ""), mirror=mirror)
    for p, (px, py, a, t) in vis.items():
        dx, dy = xf(px, py, rot)
        ex, ey = x + m * dx, y + dy
        bx, by = xf(round(math.cos(math.radians(a))), round(math.sin(math.radians(a))), rot)
        bx *= m
        d = (-bx, -by)
        net = c["pins"].get(p)
        if net is None:
            nc(ex, ey); continue
        sx_, sy_ = ex + d[0] * STUB, ey + d[1] * STUB
        SEGS.append((net, r2(ex), r2(ey), r2(sx_), r2(sy_), f"{c['ref']}.{p}"))
        PINEND.append((net, r2(ex), r2(ey), f"{c['ref']}.{p}"))
        wire(ex, ey, sx_, sy_)
        STUBEND[f"{c['ref']}.{p}"] = (r2(sx_), r2(sy_), d, net)

# ---------- wires between stub ends ----------
# w(net, pts...): a polyline through pin stub ends ("R30.2") and points (x, y); every pin named joins the group.
# Each wired group gets one label (or power symbol): lab=("R30.2" or (x, y), direction) or the first pin's stub end.
# Pins not named in any w() call keep their own label / power symbol as before.
PINEND = []      # (net, x, y, pin) pin connection points
STUBEND = {}     # pin -> (x, y, dir, net)
GROUPS = []      # dict(net, pins, segs, lab)
def P(a):
    if isinstance(a, str):
        return STUBEND[a][:2]
    return (r2(a[0]), r2(a[1]))
def w(net, *pts, lab=None, nolab=False):
    xy = [P(a) for a in pts]
    pins = [a for a in pts if isinstance(a, str)]
    for a in pins:
        assert STUBEND[a][3] == net, f"{a} is on {STUBEND[a][3]}, not {net}"
    segs = []
    for (x1, y1), (x2, y2) in zip(xy, xy[1:]):
        assert x1 == x2 or y1 == y2, f"{net}: diagonal {x1, y1} -> {x2, y2}"
        if (x1, y1) != (x2, y2):
            segs.append((x1, y1, x2, y2))
    GROUPS.append(dict(net=net, pins=pins, segs=segs, lab=lab, nolab=nolab))
WIRED = lambda: {p for g in GROUPS for p in g["pins"]}

C = {c["ref"]: c for c in comps}
def row(refs, x0, y, dx, rot=0):
    for k, r in enumerate(refs):
        place(C[r], x0 + k * dx, y, rot)

# ---------- placement (ANSI B landscape, 431.8 x 279.4 mm, 1.27 grid) ----------
# Pins of parts that belong together are joined by wires (w() calls in the wiring section below); labels remain for
# the nets between blocks (J1 <-> FPGA side, ESP32 GPIOs, SD card, CP2102N <-> ESP32).
def side(x, y):   # reference + value side by side above a horizontal two-pin part
    return dict(refpos=(x - 5.08, y - 2.54), valpos=(x + 0.64, y - 2.54))

# column 1: host connector, power
text("J1: host connector to the core board's U8 (pairs swapped)", 15.24, 17.78, 1.6)
place(C["J1"], 50.8, 68.58)
text("Power: USB-C 5 V -> SS34 -> +5V (core board via J1) -> LDO -> +3V3", 15.24, 132.08, 1.6)
place(C["J5"], 33.02, 172.72)
place(C["R38"], 58.42, 162.56, 90, **side(58.42, 162.56))
place(C["R39"], 76.2, 165.1, 90, refpos=(71.12, 168.91), valpos=(76.84, 168.91))
place(C["C27"], 86.36, 162.56, refpos=(88.36, 161.56), valpos=(88.36, 164.76))
place(C["D1"], 99.06, 157.48, 180, refpos=(92.71, 154.94), valpos=(102.87, 154.94))
place(C["U5"], 116.84, 170.18, refpos=(121.92, 160.02), valpos=(113.03, 184.15))
place(C["U1"], 66.04, 210.82, refpos=(59.69, 203.2), valpos=(64.77, 203.2))
for r, x in (("C25", 27.94), ("C23", 35.56), ("C26", 43.18), ("C24", 83.82), ("C28", 91.44), ("C29", 99.06)):
    place(C[r], x, 215.9)
for k in range(4):
    place(C[f"H{k+1}"], 205.74 + k * 10.16, 254.0, refpos=(203.5 + k * 10.16, 248.0), valpos=(203.5 + k * 10.16, 259.5))
for k, net in enumerate(("+5V", "GND")):
    x, y = 205.74 + k * 12.7, 233.68
    symbol("power:PWR_FLAG", f"#FLG{k+1:02d}", "PWR_FLAG", "", x, y, 0, (x + 1.5, y - 6), (x + 1.5, y - 3.5), in_bom=False)
    wire(x, y, x, y + 2.54)
    if net in POWER: power(net, x, y + 2.54, (0, 1))
    else: label(net, x, y + 2.54, (0, 1))

# column 2: ESP32, CP2102N, auto-reset
text("ESP32-WROVER-E-N16R8 (control UART on IO27 / IO21)", 134.62, 17.78, 1.6)
place(C["U2"], 170.18, 66.04)
place(C["SW1"], 132.08, 43.18, 270, refpos=(134.62, 46.99), valpos=(134.62, 49.53))
place(C["C11"], 139.7, 40.64)
place(C["R36"], 147.32, 30.48)
place(C["R37"], 195.58, 30.48)
place(C["SW2"], 205.74, 43.18, 270, refpos=(208.28, 46.99), valpos=(208.28, 49.53))
row(["C12", "C13"], 213.36, 66.04, 10.16)
text("CP2102N USB-UART on USB-C, DTR/RTS auto-reset", 134.62, 118.11, 1.6)
place(C["U3"], 170.18, 160.02)
place(C["R42"], 149.86, 132.08, refpos=(143.51, 130.81), valpos=(143.51, 133.35))
place(C["R40"], 129.54, 149.86, 90, **side(129.54, 149.86))
place(C["R41"], 139.7, 154.94, refpos=(133.35, 156.21), valpos=(133.35, 158.75))
row(["C14", "C15", "C16"], 210.82, 157.48, 10.16)
place(C["R34"], 134.62, 213.36, 90, **side(134.62, 213.36))
place(C["Q1"], 152.4, 213.36, refpos=(157.48, 212.09), valpos=(157.48, 214.63))
place(C["R35"], 180.34, 213.36, 90, **side(180.34, 213.36))
place(C["Q2"], 198.12, 213.36, refpos=(203.2, 212.09), valpos=(203.2, 214.63))

# column 3: CH9350L + USB-A, joysticks
text("CH9350L: USB keyboard -> UART 115200", 251.46, 17.78, 1.6)
place(C["U4"], 279.4, 60.96, refpos=(266.7, 37.6), valpos=(273.05, 37.6))
place(C["C17"], 236.22, 48.26)
place(C["C18"], 246.38, 53.34)
text("USB 1: keyboard", 306.07, 72.39, 1.6)
place(C["C19"], 317.5, 93.98)
place(C["C21"], 325.12, 93.98)
place(C["U6"], 314.96, 106.68, refpos=(311.15, 121.92), valpos=(311.15, 124.46))
place(C["J8"], 342.9, 106.68, mirror=True, refpos=(337.82, 124.46), valpos=(337.82, 127.0))
text("USB 2: 5 V only", 251.46, 129.54, 1.6)
place(C["C20"], 274.32, 142.24)
place(C["C22"], 284.48, 142.24)
place(C["J9"], 304.8, 142.24, mirror=True, refpos=(299.72, 160.02), valpos=(299.72, 162.56))

text("Joysticks 1 / 2 (Atari / Kempston, DB9 male): 3k3 pull-ups", 238.76, 172.72, 1.6)
JOY_ORDER = ("UP", "FIRE", "DOWN", "LEFT", "RIGHT")      # left to right: lowest DB9 pin first, so no wire crosses
JOY_R = {}
for j, (x0, jx, jref, r0) in enumerate(((241.3, 284.48, "J4", 15), (294.64, 337.82, "J6", 20))):
    for k, d in enumerate(JOY_ORDER):
        ref = f"R{r0 + ('UP', 'DOWN', 'LEFT', 'RIGHT', 'FIRE').index(d)}"
        JOY_R[(j + 1, d)] = ref
        place(C[ref], x0 + k * 7.62, 184.15)
    place(C[jref], jx, 213.36, refpos=(jx + 5.08, 228.6), valpos=(jx + 5.08, 231.14))

# column 4: VGA, microSD, audio
text("VGA: 4-bit DAC per colour", 350.52, 17.78, 1.6)
for i in range(12):
    col, rw = divmod(i, 4)
    place(C[f"R{i+1}"], 358.14 + col * 22.86, 27.94 + rw * 10.16, 90)
place(C["R13"], 358.14, 68.58, 90); place(C["R14"], 391.16, 68.58, 90)
row(["C1", "C2", "C3", "C4", "C5"], 358.14, 86.36, 10.16)
place(C["J2"], 393.7, 115.57, refpos=(398.78, 97.79), valpos=(402.59, 97.79))

text("microSD (SPI, on the ESP32)", 365.76, 134.62, 1.6)
place(C["J7"], 383.54, 151.13, refpos=(361.95, 135.89), valpos=(365.76, 135.89))
row(["R25", "R26", "R27", "R28", "R29", "C6", "C7"], 355.6, 184.15, 8.89)

text("Audio line out (AY + beeper, mono on tip and ring)", 15.24, 236.22, 1.6)
place(C["R30"], 33.02, 243.84, 90, refpos=(30.48, 247.65), valpos=(34.29, 247.65))
place(C["C8"], 43.18, 248.92)
place(C["C9"], 55.88, 243.84, 90)
place(C["R31"], 73.66, 243.84, 90)
place(C["C10"], 55.88, 260.35, 90, refpos=(52.07, 264.16), valpos=(57.79, 264.16))
place(C["R32"], 73.66, 260.35, 90)
place(C["R33"], 96.52, 259.08)
place(C["J3"], 116.84, 248.92, mirror=True, refpos=(118.11, 238.76), valpos=(118.11, 241.3))

# ---------- wires (per block) ----------
if os.environ.get("DUMP"):
    for k in sorted(STUBEND, key=lambda k: (re.sub(r'\d', '', k.split('.')[0]), int(re.sub(r'\D', '', k.split('.')[0]) or 0), k)):
        x, y, d, net = STUBEND[k]
        print(f"{k:8s} {x:8.2f} {y:8.2f} {str(d):8s} {net}")
    sys.exit(0)
L, R_, U_, D_ = (-1, 0), (1, 0), (0, -1), (0, 1)
# USB-C: VBUS -> C27, D1 (+5V), the ESD part's VBUS and the CP2102N's VBUS divider; CC pull-downs; D+/D- pairs; GND
w("VBUS_C", "J5.A4", "J5.A9", "J5.B4", "J5.B9", "C27.1", "D1.2", lab=("J5.A4", R_))
w("VBUS_C", "C27.1", (86.36, 152.4), (116.84, 152.4), "U5.5")
w("VBUS_C", "R40.1", (124.46, 152.4), (116.84, 152.4))
w("CC1", "J5.A5", "R38.1")
w("CC2", "J5.B5", "R39.1")
w("USBC_DM", "J5.A7", "J5.B7")
w("USBC_DP", "J5.A6", "J5.B6")
w("GND", "J5.SH", "J5.A1", "J5.A12", "J5.B1", "J5.B12", lab=("J5.A1", D_))
# LDO with its input and output capacitors
w("+5V", (22.86, 210.82), "C25.1", "C23.1", "C26.1", "U1.3", lab=((22.86, 210.82), U_))
w("+3V3", "U1.2", "C24.1", "C28.1", "C29.1", (104.14, 210.82), lab=((104.14, 210.82), U_))
# audio: AY low-pass + coupling, beeper coupling, both 2.2k into AUDIO_OUT (1k load) -> tip and ring
w("AY_LP", "R30.2", "C8.1", "C9.1", lab=("R30.2", R_))
w("AY_AC", "C9.2", "R31.1", lab=("C9.2", R_))
w("BEEP_AC", "C10.2", "R32.1", lab=("C10.2", R_))
w("AUDIO_OUT", "R31.2", (86.36, 243.84), (86.36, 254.0), (86.36, 260.35), "R32.2", lab=("R31.2", R_))
w("AUDIO_OUT", (86.36, 254.0), "R33.1", "J3.T")
w("AUDIO_OUT", "J3.R1", "J3.T")
w("GND", "J3.S", "J3.R2", lab=("J3.R2", L))
# ESP32 EN (pull-up, RC, button) and IO0 (pull-up, BOOT button)
w("ESP_EN", (124.46, 35.56), "SW1.1", "C11.1", "R36.2", "U2.3", lab=((124.46, 35.56), L))
w("ESP_IO0", "U2.25", "R37.2", "SW2.1", (213.36, 35.56), lab=((213.36, 35.56), R_))
# CP2102N: reset pull-up, VBUS sense divider
w("CP_RST_N", "R42.2", "U3.9", lab=("R42.2", L))
w("CP_VBUS", "R40.2", "R41.1", "U3.8", lab=("R40.2", R_))
# auto-reset: DTR -> R34 -> Q1 base, Q1 emitter = RTS; RTS -> R35 -> Q2 base, Q2 emitter = DTR
w("QB1", "R34.2", "Q1.1", lab=("R34.2", R_))
w("QB2", "R35.2", "Q2.1", lab=("R35.2", R_))
w("CP_RTS", "Q1.2", (154.94, 223.52), (170.18, 223.52), (170.18, 218.44), (170.18, 213.36), "R35.1",
  lab=((170.18, 218.44), L))
w("CP_DTR", "Q2.2", (200.66, 228.6), (175.26, 228.6), (124.46, 228.6), (124.46, 213.36), "R34.1",
  lab=((175.26, 228.6), R_))
# CH9350L supply, USB 1 (keyboard): D+/D- through the ESD part to J8, 5 V from the +5V rail (the upstream USB port limits the current)
w("+5V", "C17.1", "U4.41", lab=("C17.1", U_))
w("CH_VDD33", "C18.1", "U4.42", lab=("U4.42", L))
w("KB1_DP", "U4.31", (302.26, 48.26), (302.26, 96.52), (302.26, 106.68), "U6.1", lab=((302.26, 96.52), R_))
w("KB1_DM", "U4.32", (299.72, 50.8), (299.72, 93.98), (299.72, 109.22), "U6.3", lab=((299.72, 93.98), L))
w("KB1_DP", "U6.6", "J8.3", lab=("U6.6", R_))
w("KB1_DM", "U6.4", "J8.2", lab=("U6.4", R_))
w("+5V", (337.82, 88.9), (332.74, 88.9), "C21.1", "C19.1", (314.96, 88.9), "U6.5", lab=((337.82, 88.9), U_))
w("+5V", (332.74, 88.9), "J8.1")
w("GND", "J8.4", "J8.SH", lab=("J8.4", D_))
# USB 2: 5 V only
w("+5V", (266.7, 137.16), "C20.1", "C22.1", "J9.1", lab=((266.7, 137.16), U_))
w("GND", "J9.4", "J9.SH", lab=("J9.4", D_))
# joysticks: one +3V3 rail per port, each pull-up wired to its DB9 pin
JPIN = {"UP": "1", "DOWN": "2", "LEFT": "3", "RIGHT": "4", "FIRE": "6"}
for j, jref in ((1, "J4"), (2, "J6")):
    rs = [JOY_R[(j, d)] for d in JOY_ORDER]
    w("+3V3", *[r + ".1" for r in rs], lab=(rs[0] + ".1", U_))
    for d in JOY_ORDER:
        r, pin = JOY_R[(j, d)], f"{jref}.{JPIN[d]}"
        w(f"JOY{j}_{d}", r + ".2", (STUBEND[r + ".2"][0], STUBEND[pin][1]), pin, lab=(r + ".2", D_))
# VGA: the four DAC resistors of each colour on one node
for col, net in ((0, "RED"), (1, "GRN"), (2, "BLU")):
    w(net, *[f"R{col * 4 + k + 1}.2" for k in range(4)], lab=(f"R{col * 4 + 1}.2", R_))


# ---------- labels / power symbols, wires, junctions ----------
def on_seg(px, py, sg):
    _, x1, y1, x2, y2, _ = sg
    return min(x1, x2) - 0.01 <= px <= max(x1, x2) + 0.01 and min(y1, y2) - 0.01 <= py <= max(y1, y2) + 0.01 and \
        abs((x2 - x1) * (py - y1) - (y2 - y1) * (px - x1)) < 0.01
wired = WIRED()
for pin, (x, y, d, net) in STUBEND.items():
    if pin in wired:
        continue
    if net in POWER: power(net, x, y, d)
    else: label(net, x, y, d)
# merge groups of one net that touch (a w() ending on another's wire)
par = list(range(len(GROUPS)))
def root(i):
    while par[i] != i: i = par[i]
    return i
def gsegs(g): return [(g["net"], *s, "wire") for s in g["segs"]] + \
    [(g["net"], *P(p), *P(p), "pt") for p in g["pins"]]
for i, a in enumerate(GROUPS):
    for j, b in enumerate(GROUPS):
        if i < j and a["net"] == b["net"] and any(on_seg(s[1], s[2], t) or on_seg(s[3], s[4], t)
                                                  for s in gsegs(a) for t in gsegs(b)):
            par[root(i)] = root(j)
merged = {}
for i, g in enumerate(GROUPS):
    merged.setdefault(root(i), []).append(g)
for gs in merged.values():
    net = gs[0]["net"]
    for g in gs:
        for s in g["segs"]:
            wire(*s)
            SEGS.append((net, *s, f"wire {net}"))
    if any(g["nolab"] for g in gs):
        continue
    lab = next((g["lab"] for g in gs if g["lab"]), None)
    if lab is None:
        p0 = next(p for g in gs for p in g["pins"])
        lab = (p0, STUBEND[p0][2])
    pt, d = lab
    x, y = P(pt)
    if net in POWER: power(net, x, y, d)
    else: label(net, x, y, d)
# junctions: a wire end in the middle of a same-net wire, or 3+ wire ends on one point
ends = {}
for s in SEGS:   # stubs and wires
    for pt in ((s[1], s[2]), (s[3], s[4])):
        ends[(s[0], pt)] = ends.get((s[0], pt), 0) + 1
for (net, (px, py)), n in ends.items():
    mid = any(s[0] == net and on_seg(px, py, s) and (px, py) not in ((s[1], s[2]), (s[3], s[4])) for s in SEGS)
    if n >= 3 or mid:
        items.append(f'\t(junction\n\t\t(at {px} {py})\n\t\t(diameter 0)\n\t\t(color 0 0 0 0)\n\t\t(uuid "{U()}")\n\t)')

# ---------- collision check: a point of one net on another net's stub / wire (KiCad would join them) ----------
bad = 0
for net, px, py, pin in PINEND:
    for b in SEGS:
        if b[0] != net and on_seg(px, py, b):
            print(f"COLLISION pin {pin} ({net}) at {px, py} on {b[5]} ({b[0]})"); bad += 1
for a in SEGS:
    for pt in ((a[1], a[2]), (a[3], a[4])):
        for b in SEGS:
            if b is not a and b[0] != a[0] and on_seg(pt[0], pt[1], b):
                print(f"COLLISION {a[5]} ({a[0]}) at {pt} touches {b[5]} ({b[0]})"); bad += 1
if bad:
    sys.exit(f"{bad} collisions")

# ---------- write ----------
def embed(lid, t):
    name = lid.split(":")[1]
    t = t.replace(f'(symbol "{name}"', f'(symbol "{lid}"', 1)
    return "\n".join("\t" + l for l in t.split("\n"))

hdr = (f'(kicad_sch\n\t(version 20260306)\n\t(generator "eeschema")\n\t(generator_version "10.0")\n'
       f'\t(uuid "{ROOT}")\n\t(paper "B")\n\t(title_block\n\t\t(title "L I/O board (Extra_PCB_CycloneIV) revision 2")\n'
       f'\t\t(date "2026-11-02")\n\t\t(rev "2")\n'
       f'\t\t(comment 1 "Beside the QMTECH Cyclone IV core board, wired to its U8")\n'
       f'\t\t(comment 2 "ESP32-WROVER-E, CP2102N, CH9350L, 2 USB-A, VGA, 2x DB9, SD, audio")\n\t)\n\t(lib_symbols\n')
body = hdr + "\n".join(embed(l, libtext[l]) for l in sorted(libtext)) + "\n\t)\n" + "\n".join(items) + \
    '\n\t(sheet_instances\n\t\t(path "/"\n\t\t\t(page "1")\n\t\t)\n\t)\n\t(embedded_fonts no)\n)\n'
open(os.path.join(OUT, f"{PROJ}.kicad_sch"), "w", newline="\n").write(body)

lib = '(kicad_symbol_lib\n\t(version 20251024)\n\t(generator "kicad_symbol_editor")\n\t(generator_version "10.0")\n'
for lid in sorted(libtext):
    if lid.startswith(LIB + ":"):
        lib += "\n".join("\t" + l for l in libtext[lid].split("\n")) + "\n"
open(os.path.join(OUT, f"{LIB}.kicad_sym"), "w", newline="\n").write(lib + ")\n")
print("ok", len(items), "items")
