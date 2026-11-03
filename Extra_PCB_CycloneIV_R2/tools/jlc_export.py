#!/usr/bin/env python3
"""jlc_export.py -- JLCPCB fabrication + assembly files for Extra_PCB_CycloneIV_R2 (run from WSL).

Writes into ../jlcpcb/:
  Extra_PCB_CycloneIV_R2_gerbers.zip   Gerbers (4 layers: F.Cu, In1.Cu GND, In2.Cu +3V3, B.Cu; mask, paste, silk,
                                       outline) + Excellon drill files
  Extra_PCB_CycloneIV_R2_BOM.csv       Comment, Designator, Footprint, LCSC Part #  (JLCPCB BOM format)
  Extra_PCB_CycloneIV_R2_CPL.csv       Designator, Mid X, Mid Y, Layer, Rotation    (JLCPCB placement format)
Do-not-fit parts (J1 host holes) and the mounting holes are left out.
LCSC numbers checked on lcsc.com / jlcpcb.com 2026-11-03 (part identity; stock shows in JLCPCB's BOM check).
Order: 4 layers, 1.6 mm, JLC04161H-7628 (default) stack-up; consider "via in pad: epoxy filled + capped" for the
vias in the ESP32 / CP2102N centre pads.
"""
import csv, os, re, shutil, subprocess, sys, zipfile

KICAD_CLI = "/mnt/c/Program Files/KiCad/10.0/bin/kicad-cli.exe"
HERE = os.path.dirname(os.path.abspath(__file__))
PRJ = os.path.dirname(HERE)
NAME = "Extra_PCB_CycloneIV_R2"
OUT = os.path.join(PRJ, "jlcpcb")

R = "Resistor_SMD:R_0603_1608Metric"; C6 = "Capacitor_SMD:C_0603_1608Metric"; C8 = "Capacitor_SMD:C_0805_2012Metric"
DB9 = "Connector_Dsub:DSUB-9_Pins_Horizontal_P2.77x2.84mm_EdgePinOffset7.70mm_Housed_MountingHolesOffset9.12mm"
# (value, footprint) -> LCSC part
LCSC = {
    ("510", R): "C23193", ("1k", R): "C21190", ("2k", R): "C22975", ("4.7k", R): "C23162",     # DAC (all Basic)
    ("22", R): "C23345", ("3k3", R): "C22978", ("10k", R): "C25804", ("100", R): "C22775", ("2.2k", R): "C4190",
    ("5.1k", R): "C23186",                                            # 0603WAF5101T5E (USB-C CC)
    ("22k", R): "C31850",                                             # 0603WAF2202T5E (CP2102N VBUS divider)
    ("47k", R): "C25819",                                             # 0603WAF4702T5E (CP2102N VBUS divider)
    ("10p", C6): "C1634", ("0.1u", C6): "C14663",                     # 10p: Samsung CL10C100JB8NNNC C0G
    ("1u", C6): "C15849",                                             # Samsung CL10A105KB8NNNC 50 V X5R
    ("4.7u", C6): "C19666",                                           # Samsung CL10A475KO8NNNC 16 V X5R
    ("10u", C8): "C15850",                                            # Samsung CL21A106KAYNNNE 25 V
    ("22u", C8): "C45783",                                            # Samsung CL21A226MAQNNNE 25 V X5R
    ("100u", "Capacitor_SMD:C_1206_3216Metric"): "C15008",            # Samsung CL31A107MQHNNNE 6.3 V X5R (on 5 V)
    ("Audio out", "Connector_Audio:Jack_3.5mm_KoreanHropartsElec_PJ-320D-4A_Horizontal"): "C95562",
    ("microSD", "Connector_Card:microSD_HC_Molex_104031-0811"): "C585350",
    ("VGA", NAME + ":DSUB-15-HD_Socket_Horizontal_P2.29x2.54mm_CONNFLY_DS1038"): "C75754",
    ("Joystick 1", DB9): "C75750", ("Joystick 2", DB9): "C75750",
    ("EN", "Button_Switch_SMD:SW_SPST_PTS810"): "C116501", ("BOOT", "Button_Switch_SMD:SW_SPST_PTS810"): "C116501",
    ("CH9350L", "Package_QFP:LQFP-48_7x7mm_P0.5mm"): "C109472",
    ("CP2102N-A02-GQFN24", "Package_DFN_QFN:QFN-24-1EP_4x4mm_P0.5mm_EP2.6x2.6mm"): "C969151",
    ("ESP32-WROVER-E-N16R8", NAME + ":ESP32-WROVER-E"): "C529589",
    ("LDL1117S33R", "Package_TO_SOT_SMD:SOT-223-3_TabPin2"): "C435835",
    ("MMBT3904", "Package_TO_SOT_SMD:SOT-23"): "C20526",                # JSCJ MMBT3904
    ("USBLC6-2SC6", "Package_TO_SOT_SMD:SOT-23-6"): "C7519",            # ST
    ("USB keyboard", "Connector_USB:USB_A_Connfly_DS1095"): "C112456",     # SOFNG USB-302-T, THT R/A (user's JLCPCB choice)
    ("USB 5V (HDMI dongle)", "Connector_USB:USB_A_Connfly_DS1095"): "C112456",
    ("USB-C 5V / console", "Connector_USB:USB_C_Receptacle_HRO_TYPE-C-31-M-12"): "C165948",
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
            "--layers", "F.Cu,In1.Cu,In2.Cu,B.Cu,F.Paste,B.Paste,F.Silkscreen,B.Silkscreen,F.Mask,B.Mask,Edge.Cuts",
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
