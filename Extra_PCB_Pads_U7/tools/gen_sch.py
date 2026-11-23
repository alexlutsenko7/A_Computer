# gen_sch.py OUTDIR -- writes Extra_PCB_Pads_U7.kicad_sch from design.py (ANSI B sheet, 17 x 11 in).
# The drawing functions are those of the I/O board revision 2's generator. Every pin carries a net label or a power
# symbol. Once the schematic is edited in KiCad, the KiCad file is the source of truth.
import sys, uuid, math, re, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sx import find_symbol
from design import comps, LIB, POWER

OUT = sys.argv[1]
KLIB = "/mnt/c/Program Files/KiCad/10.0/share/kicad/symbols/"
PROJ = LIB
ROOT = str(uuid.uuid5(uuid.NAMESPACE_DNS, LIB))
U = lambda: str(uuid.uuid4())

# ---------- library symbols ----------
def pin_sx(typ, x, y, ang, name, num, hide=False, length=2.54):
    h = "\n\t\t\t\t(hide yes)" if hide else ""
    f = "(effects\n\t\t\t\t\t\t(font\n\t\t\t\t\t\t\t(size 1.27 1.27)\n\t\t\t\t\t\t)\n\t\t\t\t\t)"
    return (f'\t\t\t(pin {typ} line\n\t\t\t\t(at {x} {y} {ang})\n\t\t\t\t(length {length}){h}\n'
            f'\t\t\t\t(name "{name}"\n\t\t\t\t\t{f}\n\t\t\t\t)\n\t\t\t\t(number "{num}"\n\t\t\t\t\t{f}\n\t\t\t\t)\n\t\t\t)')

def prop_sx(name, val, x, y, hide=False):
    h = "\n\t\t\t(hide yes)" if hide else ""
    return (f'\t\t(property "{name}" "{val}"\n\t\t\t(at {x} {y} 0)\n\t\t\t(show_name no)\n\t\t\t(do_not_autoplace no){h}\n'
            f'\t\t\t(effects\n\t\t\t\t(font\n\t\t\t\t\t(size 1.27 1.27)\n\t\t\t\t)\n\t\t\t)\n\t\t)')


def buf2_symbol():
    # dual buffer in one symbol (the KiCad library draws it as three units)
    pins = [pin_sx("input", -10.16, 2.54, 0, "1A", 1), pin_sx("input", -10.16, -2.54, 0, "2A", 3),
            pin_sx("output", 10.16, 2.54, 180, "1Y", 6), pin_sx("output", 10.16, -2.54, 180, "2Y", 4),
            pin_sx("power_in", 0, 7.62, 270, "VCC", 5), pin_sx("power_in", 0, -7.62, 90, "GND", 2)]
    rect = ('\t\t(symbol "74HCT2G34_0_1"\n\t\t\t(rectangle\n\t\t\t\t(start -7.62 5.08)\n\t\t\t\t(end 7.62 -5.08)\n'
            '\t\t\t\t(stroke\n\t\t\t\t\t(width 0.254)\n\t\t\t\t\t(type default)\n\t\t\t\t)\n\t\t\t\t(fill\n\t\t\t\t\t(type background)\n\t\t\t\t)\n\t\t\t)\n\t\t)')
    return ('(symbol "74HCT2G34"\n\t\t(pin_names\n\t\t\t(offset 1.016)\n\t\t)\n\t\t(exclude_from_sim no)\n\t\t(in_bom yes)\n'
            '\t\t(on_board yes)\n\t\t(in_pos_files yes)\n\t\t(duplicate_pin_numbers_are_jumpers no)\n'
            + prop_sx("Reference", "U", -7.62, 7.62) + "\n" + prop_sx("Value", "74HCT2G34", 2.54, 7.62) + "\n"
            + prop_sx("Footprint", "Package_TO_SOT_SMD:SOT-23-6", 0, 0, True) + "\n"
            + prop_sx("Datasheet", "", 0, 0, True) + "\n"
            + prop_sx("Description", "Dual buffer, TTL input levels, 5 V", 0, 0, True) + "\n"
            + rect + '\n\t\t(symbol "74HCT2G34_1_1"\n' + "\n".join(pins) + "\n\t\t)\n\t)")

libtext = {}
BASE = {}   # derived lib id -> base lib id
libtext[f"{LIB}:74HCT2G34"] = buf2_symbol()
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
text("J1: the core board's header U7, pin for pin", 30.48, 30.48, 1.6)
place(C["J1"], 60.96, 119.38)
for k, net in enumerate(("+5V", "GND", "+3V3")):
    x, y = 40.64 + k * 12.7, 220.98
    symbol("power:PWR_FLAG", f"#FLG{k+1:02d}", "PWR_FLAG", "", x, y, 0, (x + 1.5, y - 6), (x + 1.5, y - 3.5), in_bom=False)
    wire(x, y, x, y + 2.54)
    power(net, x, y + 2.54, (0, 1))
place(C["C6"], 93.98, 223.52)
for j in (1, 2):
    y0 = 30.48 + (j - 1) * 96.52
    r0 = 1 + (j - 1) * 8
    text(f"Pad {j}: DB9 socket on 5 V, 3k3 pull-ups to 5 V, 74LVC245 on 3.3 V towards the FPGA", 119.38, y0, 1.6)
    row([f"R{r0 + k}" for k in range(6)], 132.08, y0 + 17.78, 12.7)
    place(C[f"U{j}"], 233.68, y0 + 40.64)
    place(C[f"C{1 + (j - 1) * 3}"], 266.7, y0 + 25.4)
    place(C[f"J{j + 1}"], 330.2, y0 + 40.64)
    place(C[f"C{3 + (j - 1) * 2}"], 363.22, y0 + 25.4)
text("Select lines: one dual buffer 74HCT2G34 on 5 V, 10k pull-ups, 100 Ohm in series", 119.38, 223.52, 1.6)
place(C["R7"], 132.08, 243.84)
place(C["R15"], 144.78, 243.84)
place(C["U3"], 180.34, 243.84, refpos=(170.18, 233.68), valpos=(182.88, 233.68))
place(C["C2"], 205.74, 238.76)
place(C["R8"], 228.6, 241.3, 90)
place(C["R16"], 251.46, 246.38, 90)

L, R_, U_, D_ = (-1, 0), (1, 0), (0, -1), (0, 1)
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
       f'\t(uuid "{ROOT}")\n\t(paper "B")\n\t(title_block\n\t\t(title "L pad board (Extra_PCB_Pads_U7)")\n'
       f'\t\t(date "2026-11-23")\n\t\t(rev "1")\n'
       f'\t\t(comment 1 "On the QMTECH 10CL025 core board\'s header U7")\n'
       f'\t\t(comment 2 "2x DB9 for Mega Drive pads on 5 V, level shifters to the 3.3 V FPGA pins")\n\t)\n\t(lib_symbols\n')
body = hdr + "\n".join(embed(l, libtext[l]) for l in sorted(libtext)) + "\n\t)\n" + "\n".join(items) + \
    '\n\t(sheet_instances\n\t\t(path "/"\n\t\t\t(page "1")\n\t\t)\n\t)\n\t(embedded_fonts no)\n)\n'
open(os.path.join(OUT, f"{PROJ}.kicad_sch"), "w", newline="\n").write(body)
lib = '(kicad_symbol_lib\n\t(version 20251024)\n\t(generator "kicad_symbol_editor")\n\t(generator_version "10.0")\n'
for lid in sorted(libtext):
    if lid.startswith(LIB + ":"):
        lib += "\n".join("\t" + l for l in libtext[lid].split("\n")) + "\n"
open(os.path.join(OUT, f"{LIB}.kicad_sym"), "w", newline="\n").write(lib + ")\n")
print("ok", len(items), "items")
