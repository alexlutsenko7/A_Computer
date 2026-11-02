#!/usr/bin/env python3
"""jlc_export.py -- JLCPCB fabrication + assembly files for Extra_PCB_CycloneIV (run from WSL).

Writes into ../jlcpcb/:
  Extra_PCB_CycloneIV_gerbers.zip   Gerbers (2 layers, mask, paste, silk, outline) + Excellon drill files
  Extra_PCB_CycloneIV_BOM.csv       Comment, Designator, Footprint, LCSC Part #  (JLCPCB BOM format)
  Extra_PCB_CycloneIV_CPL.csv       Designator, Mid X, Mid Y, Layer, Rotation    (JLCPCB placement format)
Do-not-fit parts (J1 host holes, U2 ESP32 DevKit, J5 keyboard module) and the mounting holes are left out.
LCSC numbers below were checked against JLCPCB's parts library on 2026-10-14 (all in stock that day).
"""
import csv, os, re, shutil, subprocess, sys, zipfile

KICAD_CLI = "/mnt/c/Program Files/KiCad/10.0/bin/kicad-cli.exe"
HERE = os.path.dirname(os.path.abspath(__file__))
PRJ = os.path.dirname(HERE)
NAME = "Extra_PCB_CycloneIV"
OUT = os.path.join(PRJ, "jlcpcb")

# (value, footprint) -> LCSC part
LCSC = {
    ("523",   "Resistor_SMD:R_0603_1608Metric"): "C23199",   # UNI-ROYAL 0603WAF5230T5E 1 %
    ("1.05k", "Resistor_SMD:R_0603_1608Metric"): "C22832",   # 0603WAF1051T5E
    ("2.1k",  "Resistor_SMD:R_0603_1608Metric"): "C22902",   # 0603WAF2101T5E
    ("4.22k", "Resistor_SMD:R_0603_1608Metric"): "C23042",   # 0603WAF4221T5E
    ("22",    "Resistor_SMD:R_0603_1608Metric"): "C23345",   # 0603WAF220JT5E (basic)
    ("3k3",   "Resistor_SMD:R_0603_1608Metric"): "C22978",   # 0603WAF3301T5E (basic)
    ("10k",   "Resistor_SMD:R_0603_1608Metric"): "C25804",   # 0603WAF1002T5E (basic)
    ("68",    "Resistor_SMD:R_0603_1608Metric"): "C27592",   # 0603WAF680JT5E
    ("2.2k",  "Resistor_SMD:R_0603_1608Metric"): "C4190",    # 0603WAF2201T5E (basic)
    ("1k",    "Resistor_SMD:R_0603_1608Metric"): "C21190",   # 0603WAF1001T5E (basic)
    ("6p8",   "Capacitor_SMD:C_0603_1608Metric"): "C318672", # Samsung CL10C6R8CB8NNNC C0G 50 V
    ("0.1u",  "Capacitor_SMD:C_0603_1608Metric"): "C14663",  # Yageo CC0603KRX7R9BB104 (basic)
    ("10u",   "Capacitor_SMD:C_0805_2012Metric"): "C15850",  # Samsung CL21A106KAYNNNE 25 V (basic)
    ("0.1u",  "Capacitor_THT:C_Disc_D4.7mm_W2.5mm_P5.00mm"): "C84772",   # CT4-0805B104K500F3 X7R, P 5.08
    ("10u",   "Capacitor_THT:C_Disc_D4.7mm_W2.5mm_P5.00mm"): "C531341",  # TDK FG26X7R1E106KRT06 X7R, P 5
    ("Audio out", "Connector_Audio:Jack_3.5mm_KoreanHropartsElec_PJ-320D-4A_Horizontal"): "C95562",
    ("microSD", "Connector_Card:microSD_HC_Molex_104031-0811"): "C585350",
    ("VGA", NAME + ":DSUB-15-HD_Socket_Horizontal_P2.29x2.54mm_CONNFLY_DS1038"): "C75754",
    ("Joystick 1", "Connector_Dsub:DSUB-9_Pins_Horizontal_P2.77x2.84mm_EdgePinOffset7.70mm_Housed_MountingHolesOffset9.12mm"): "C75750",
    ("Joystick 2", "Connector_Dsub:DSUB-9_Pins_Horizontal_P2.77x2.84mm_EdgePinOffset7.70mm_Housed_MountingHolesOffset9.12mm"): "C75750",
    ("7803 module", NAME + ":Module_7803_SIP-3_P2.54mm_Reserve15x12mm"): "C5369643",  # YLPTEC K7803-500R3: 4.75-36 V in, 3.3 V 0.5 A, pins 1 Vin 2 GND 3 Vo (datasheet checked)
}


def win(p):
    return subprocess.run(["wslpath", "-w", p], capture_output=True, text=True).stdout.strip()


def cli(*args):
    r = subprocess.run([KICAD_CLI] + list(args), capture_output=True, text=True)
    if r.returncode:
        sys.exit("kicad-cli failed: %s\n%s" % (" ".join(args), r.stdout + r.stderr))


def symbols():
    """(ref, value, footprint) of every schematic part that is fitted and in the BOM."""
    s = open(os.path.join(PRJ, NAME + ".kicad_sch")).read()
    out = []
    for m in re.finditer(r'\n\t\(symbol\n\t\t\(lib_id "[^"]+"\)', s):
        blk = s[m.start():s.index("(instances", m.start())]
        ref = re.search(r'\(property "Reference" "([^"]+)"', blk).group(1)
        if ref.startswith("#") or "(dnp yes)" in blk or "(in_bom no)" in blk or ref.startswith("H"):
            continue
        val = re.search(r'\(property "Value" "([^"]*)"', blk).group(1)
        fp = re.search(r'\(property "Footprint" "([^"]*)"', blk).group(1)
        out.append((ref, val, fp))
    return out


def refkey(r):
    return (re.sub(r"\d", "", r), int(re.sub(r"\D", "", r) or 0))


def main():
    shutil.rmtree(OUT, ignore_errors=True)
    gdir = os.path.join(OUT, "gerbers")
    os.makedirs(gdir)
    pcb = win(os.path.join(PRJ, NAME + ".kicad_pcb"))
    pro = os.path.join(PRJ, NAME + ".kicad_pro")
    keep = open(pro, "rb").read()                      # kicad-cli may rewrite the project file
    try:
        cli("pcb", "export", "gerbers", "-o", win(gdir) + "\\",
            "--layers", "F.Cu,B.Cu,F.Paste,B.Paste,F.Silkscreen,B.Silkscreen,F.Mask,B.Mask,Edge.Cuts",
            "--no-x2", "--subtract-soldermask", pcb)
        cli("pcb", "export", "drill", "-o", win(gdir) + "\\", "--format", "excellon", "--excellon-units", "mm",
            "--excellon-zeros-format", "decimal", "--excellon-oval-format", "alternate", "--excellon-separate-th", pcb)
        raw = os.path.join(OUT, "pos_raw.csv")
        cli("pcb", "export", "pos", "-o", win(raw), "--format", "csv", "--units", "mm", "--side", "both",
            "--exclude-dnp", pcb)
    finally:
        open(pro, "wb").write(keep)

    with zipfile.ZipFile(os.path.join(OUT, NAME + "_gerbers.zip"), "w", zipfile.ZIP_DEFLATED) as z:
        for f in sorted(os.listdir(gdir)):
            z.write(os.path.join(gdir, f), f)

    parts = symbols()
    fitted = {r for r, _, _ in parts}
    groups = {}
    missing = []
    for ref, val, fp in parts:
        part = LCSC.get((val, fp))
        if not part:
            missing.append((ref, val, fp))
        g = groups.setdefault((part, fp), [[], []])    # one BOM line per LCSC part: JLCPCB splits stock between
        g[0].append(ref)                               # duplicate lines (two DB9 lines showed 0 available)
        if val not in g[1]:
            g[1].append(val)
    if missing:
        sys.exit("no LCSC part for: %s" % missing)
    with open(os.path.join(OUT, NAME + "_BOM.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["Comment", "Designator", "Footprint", "LCSC Part #"])
        for (part, fp), (refs, vals) in sorted(groups.items(), key=lambda g: refkey(sorted(g[1][0], key=refkey)[0])):
            w.writerow([" / ".join(vals), ",".join(sorted(refs, key=refkey)), fp.split(":")[1], part])

    rows = list(csv.DictReader(open(raw)))
    placed = set()
    with open(os.path.join(OUT, NAME + "_CPL.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["Designator", "Mid X", "Mid Y", "Layer", "Rotation"])
        for r in sorted(rows, key=lambda r: refkey(r["Ref"])):
            if r["Ref"] not in fitted:
                continue
            placed.add(r["Ref"])
            w.writerow([r["Ref"], "%.3fmm" % float(r["PosX"]), "%.3fmm" % float(r["PosY"]),
                        "Top" if r["Side"].lower().startswith("top") else "Bottom", "%g" % float(r["Rot"])])
    os.remove(raw)
    lost = fitted - placed
    if lost:
        sys.exit("parts in the BOM but not in the placement file: %s" % sorted(lost, key=refkey))
    print("gerber files:", len(os.listdir(gdir)), "| BOM lines:", len(groups), "| parts placed:", len(placed))


if __name__ == "__main__":
    main()
