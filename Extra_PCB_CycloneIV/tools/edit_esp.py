# Surgical schematic edit: J1 2x20 -> 2x32 (+BT pins), add ESP32 30-pin dev board U2.
import re, uuid, math
from sx import find_symbol, block_at, pins as sym_pins

P = "/mnt/c/work/My/AlteraZX/Extended/qm_atrix_ext.kicad_sch"
LIBF = "/mnt/c/work/My/AlteraZX/Extended/qm_atrix_ext.kicad_sym"
KLIB = "/mnt/c/Program Files/KiCad/10.0/share/kicad/symbols/"
s = open(P).read()
ROOT = re.search(r'\(uuid "([^"]+)"\)', s).group(1)
PROJ = "qm_atrix_ext"
U = lambda: str(uuid.uuid4())
r2 = lambda v: float(f"{v:.2f}")

# ---------------- ESP32 symbol (local lib) ----------------
LEFT = ["EN", "VP/GPIO36", "VN/GPIO39", "D34", "D35", "D32", "D33", "D25", "D26", "D27", "D14", "D12", "D13", "GND", "VIN"]
RIGHT = ["D23", "D22", "TX0", "RX0", "D21", "D19", "D18", "D5", "TX2/GPIO17", "RX2/GPIO16", "D4", "D2", "D15", "GND", "3V3"]
def pin(num, name, x, y, ang):
    return (f'\t\t\t(pin passive line\n\t\t\t\t(at {x} {y} {ang})\n\t\t\t\t(length 2.54)\n'
            f'\t\t\t\t(name "{name}"\n\t\t\t\t\t(effects\n\t\t\t\t\t\t(font\n\t\t\t\t\t\t\t(size 1.27 1.27)\n\t\t\t\t\t\t)\n\t\t\t\t\t)\n\t\t\t\t)\n'
            f'\t\t\t\t(number "{num}"\n\t\t\t\t\t(effects\n\t\t\t\t\t\t(font\n\t\t\t\t\t\t\t(size 1.27 1.27)\n\t\t\t\t\t\t)\n\t\t\t\t\t)\n\t\t\t\t)\n\t\t\t)\n')
def prop_l(n, v, y, hide=False):
    h = "\n\t\t\t(hide yes)" if hide else ""
    return (f'\t\t(property "{n}" "{v}"\n\t\t\t(at 0 {y} 0){h}\n\t\t\t(show_name no)\n\t\t\t(do_not_autoplace no)\n'
            f'\t\t\t(effects\n\t\t\t\t(font\n\t\t\t\t\t(size 1.27 1.27)\n\t\t\t\t)\n\t\t\t)\n\t\t)\n')
ESP = "ESP32_DevKit_30pin"
pins_txt = "".join(pin(i + 1, n, -15.24, 17.78 - i * 2.54, 0) for i, n in enumerate(LEFT)) + \
           "".join(pin(i + 16, n, 15.24, 17.78 - i * 2.54, 180) for i, n in enumerate(RIGHT))
esp_sym = (f'(symbol "{ESP}"\n\t\t(exclude_from_sim no)\n\t\t(in_bom yes)\n\t\t(on_board yes)\n'
           + prop_l("Reference", "U", 21.59) + prop_l("Value", ESP, -21.59) + prop_l("Footprint", "qm_atrix_ext:ESP32_DevKit_30pin_Socket", -24.13, True)
           + prop_l("Datasheet", "", 0, True)
           + prop_l("Description", "ESP32-WROOM-32 dev board, 30 pins (DOIT DEVKIT V1 pinout), on 2x 1x15 sockets 25.4 mm apart", 0, True)
           + f'\t\t(symbol "{ESP}_0_1"\n\t\t\t(rectangle\n\t\t\t\t(start -12.7 20.32)\n\t\t\t\t(end 12.7 -20.32)\n'
             '\t\t\t\t(stroke\n\t\t\t\t\t(width 0.254)\n\t\t\t\t\t(type default)\n\t\t\t\t)\n\t\t\t\t(fill\n\t\t\t\t\t(type background)\n\t\t\t\t)\n\t\t\t)\n\t\t)\n'
           + f'\t\t(symbol "{ESP}_1_1"\n{pins_txt}\t\t)\n\t\t(embedded_fonts no)\n\t)')
lib = open(LIBF).read()
if f'(symbol "{ESP}"' not in lib:
    lib = lib.rstrip()[:-1].rstrip() + "\n\t" + esp_sym + "\n)\n"
    open(LIBF, "w", newline="\n").write(lib)

# ---------------- lib_symbols in schematic ----------------
c32 = find_symbol(open(KLIB + "Connector_Generic.kicad_sym").read(), "Conn_02x32_Odd_Even")
c32 = c32.replace('(symbol "Conn_02x32_Odd_Even"', '(symbol "Connector_Generic:Conn_02x32_Odd_Even"', 1)
espe = esp_sym.replace(f'(symbol "{ESP}"', f'(symbol "qm_atrix_ext:{ESP}"', 1)
li = s.index("\t(lib_symbols\n") + len("\t(lib_symbols\n")
add = ""
if "Connector_Generic:Conn_02x32_Odd_Even" not in s: add += "\t\t" + c32 + "\n"
if f"qm_atrix_ext:{ESP}" not in s: add += "\t\t" + espe + "\n"
s = s[:li] + add + s[li:]
PINS = {"Connector_Generic:Conn_02x32_Odd_Even": sym_pins(c32), f"qm_atrix_ext:{ESP}": sym_pins(espe),
        "power:GND": None, "power:+5V": None}

# ---------------- J1: swap symbol, shift +15.24 so pins 1..40 stay put ----------------
jm = None
for m in re.finditer(r'\n\t\(symbol\n', s):
    i = m.start() + 1; t = s[i:block_at(s, i)]
    if '(property "Reference" "J1"' in t: jm = (i, i + len(t), t)
i, j, t = jm
t2 = t.replace('(lib_id "Connector_Generic:Conn_02x20_Odd_Even")', '(lib_id "Connector_Generic:Conn_02x32_Odd_Even")')
t2 = t2.replace("PinHeader_2x20_P2.54mm_Vertical", "PinHeader_2x32_P2.54mm_Vertical")
ax, ay = map(float, re.search(r'\(lib_id [^)]*\)\s*\(at ([-\d.]+) ([-\d.]+)', t2).groups())
t2 = re.sub(r'(\(lib_id [^)]*\)\s*\(at [-\d.]+ )([-\d.]+)', lambda m: m.group(1) + f"{ay + 15.24:.2f}", t2, count=1)
# reference above the taller body
t2 = re.sub(r'(\(property "Reference" "J1"\s*\(at [-\d.]+ )([-\d.]+)', lambda m: m.group(1) + f"{ay - 38.1 - 3:.2f}", t2, count=1)
t2 = re.sub(r'(\(property "Value" "[^"]*"\s*\(at [-\d.]+ )([-\d.]+)', lambda m: m.group(1) + f"{ay + 15.24 + 40.64 + 4:.2f}", t2, count=1)
last_pin = list(re.finditer(r'\t\t\(pin "\d+"\n\t\t\t\(uuid "[^"]+"\)\n\t\t\)', t2))[-1]
extra = "".join(f'\n\t\t(pin "{n}"\n\t\t\t(uuid "{U()}")\n\t\t)' for n in range(41, 65))
t2 = t2[:last_pin.end()] + extra + t2[last_pin.end():]
s = s[:i] + t2 + s[j:]
J1X, J1Y = ax, ay + 15.24

# ---------------- new items ----------------
items = []
pwr_n = [max(int(x) for x in re.findall(r'"#PWR(\d+)"', s))]
def font(sz=1.27, just=None):
    jj = f"\n\t\t\t\t(justify {just})" if just else ""
    return f"(effects\n\t\t\t\t(font\n\t\t\t\t\t(size {sz} {sz})\n\t\t\t\t){jj}\n\t\t\t)"
def prop(name, val, x, y, hide=False, just=None):
    h = "\n\t\t\t(hide yes)" if hide else ""
    return (f'\t\t(property "{name}" "{val}"\n\t\t\t(at {r2(x)} {r2(y)} 0){h}\n\t\t\t(show_name no)\n'
            f'\t\t\t(do_not_autoplace no)\n\t\t\t{font(just=just)}\n\t\t)')
def symbol(lid, ref, val, fp, x, y, rot, refpos, valpos, npins, bom=True):
    pl = "\n".join(f'\t\t(pin "{p}"\n\t\t\t(uuid "{U()}")\n\t\t)' for p in npins)
    items.append(f'\t(symbol\n\t\t(lib_id "{lid}")\n\t\t(at {r2(x)} {r2(y)} {rot})\n\t\t(unit 1)\n\t\t(body_style 1)\n'
                 f'\t\t(exclude_from_sim no)\n\t\t(in_bom {"yes" if bom else "no"})\n\t\t(on_board {"yes" if bom else "no"})\n'
                 f'\t\t(in_pos_files yes)\n\t\t(dnp no)\n\t\t(uuid "{U()}")\n'
                 + prop("Reference", ref, *refpos, hide=ref.startswith("#"), just="left") + "\n"
                 + prop("Value", val, *valpos, just="left") + "\n"
                 + prop("Footprint", fp, x, y, hide=True) + "\n" + prop("Datasheet", "", x, y, hide=True) + "\n"
                 + prop("Description", "", x, y, hide=True) + "\n" + pl +
                 f'\n\t\t(instances\n\t\t\t(project "{PROJ}"\n\t\t\t\t(path "/{ROOT}"\n\t\t\t\t\t(reference "{ref}")\n'
                 f'\t\t\t\t\t(unit 1)\n\t\t\t\t)\n\t\t\t)\n\t\t)\n\t)')
def wire(x1, y1, x2, y2):
    items.append(f'\t(wire\n\t\t(pts\n\t\t\t(xy {r2(x1)} {r2(y1)}) (xy {r2(x2)} {r2(y2)})\n\t\t)\n'
                 f'\t\t(stroke\n\t\t\t(width 0)\n\t\t\t(type default)\n\t\t)\n\t\t(uuid "{U()}")\n\t)')
def label(net, x, y, d):
    ang, just = {(1, 0): (0, "left bottom"), (-1, 0): (180, "right bottom")}[d]
    items.append(f'\t(label "{net}"\n\t\t(at {r2(x)} {r2(y)} {ang})\n\t\t{font(just=just)}\n\t\t(uuid "{U()}")\n\t)')
def nc(x, y): items.append(f'\t(no_connect\n\t\t(at {r2(x)} {r2(y)})\n\t\t(uuid "{U()}")\n\t)')
def power(net, x, y, d):
    pwr_n[0] += 1
    rot = ({(0, 1): 0, (1, 0): 90, (0, -1): 180, (-1, 0): 270} if net == "GND" else {(0, -1): 0, (-1, 0): 90, (0, 1): 180, (1, 0): 270})[d]
    tx = x + d[0] * 5.08 - (3.0 if d[0] < 0 else 0)
    symbol(f"power:{net}", f"#PWR{pwr_n[0]:02d}", net, "", x, y, rot, (tx, y + 2.5), (tx, y), ["1"], bom=False)
def text(t, x, y, sz=2.0):
    items.append(f'\t(text "{t}"\n\t\t(exclude_from_sim no)\n\t\t(at {r2(x)} {r2(y)} 0)\n\t\t{font(sz, "left bottom")}\n\t\t(uuid "{U()}")\n\t)')
def hook(px, py, ang, net, x, y):
    ex, ey = x + px, y - py
    d = (-1, 0) if ang == 0 else (1, 0)
    if net is None: nc(ex, ey); return
    sx_, sy_ = ex + d[0] * 2.54, ey
    wire(ex, ey, sx_, sy_)
    if net in ("GND", "+5V"): power(net, sx_, sy_, d)
    else: label(net, sx_, sy_, d)

# J1 pins 41..64
J1NEW = {41: "BT_BCLK", 42: "BT_LRCK", 43: "BT_DATA", 44: "BT_TX", 45: "BT_RX", 46: "GND", 63: "GND", 64: "GND"}
jp = PINS["Connector_Generic:Conn_02x32_Odd_Even"]
for n in range(41, 65):
    px, py, ang, _ = jp[str(n)]
    hook(px, py, ang, J1NEW.get(n), J1X, J1Y)

# ESP32 U2
EX, EY = 80.01, 38.1
ESPNET = {"8": "BT_LRCK", "9": "BT_BCLK", "14": "GND", "15": "+5V", "17": "BT_DATA", "24": "BT_RX", "25": "BT_TX", "29": "GND"}
ep = PINS[f"qm_atrix_ext:{ESP}"]
symbol(f"qm_atrix_ext:{ESP}", "U2", "ESP32 DevKit 30-pin", "qm_atrix_ext:ESP32_DevKit_30pin_Socket", EX, EY, 0,
       (EX - 12.7, EY - 22.5), (EX - 2.0, EY - 22.5), list(ep))
for n, (px, py, ang, _) in ep.items():
    hook(px, py, ang, ESPNET.get(n), EX, EY)
text("Bluetooth audio bridge: ESP32 dev board (30-pin, DOIT pinout) on 2x 1x15 sockets; 3V3 pin not connected", 22.86, 12.7)

si = s.rindex("\t(sheet_instances")
s = s[:si] + "\n".join(items) + "\n" + s[si:]
open(P, "w", newline="\n").write(s)
print("J1 at", J1X, J1Y, "| added", len(items), "items")
