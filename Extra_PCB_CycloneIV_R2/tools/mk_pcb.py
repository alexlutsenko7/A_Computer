# mk_pcb.py -- KiCad python (C:\Program Files\KiCad\10.0\bin\python.exe):
#   mk_pcb.py info   : courtyard size of every footprint (rotation 0, relative to its anchor)
#   mk_pcb.py build  : new Extra_PCB_CycloneIV_R2.kicad_pcb: outline + holes as revision 1, every footprint from the
#                      netlist (linked to its schematic symbol, nets assigned) at the position in placement.py; no tracks
# Paths are Windows paths (the KiCad python cannot read WSL paths). Netlist: kicad-cli sch export netlist (kicadxml).
import sys, os, shutil, xml.etree.ElementTree as ET
import pcbnew

HERE = os.path.dirname(os.path.abspath(__file__))
PRJ = os.path.normpath(os.path.join(HERE, ".."))
NAME = "Extra_PCB_CycloneIV_R2"
NETLIST = os.path.join(PRJ, "netlist.xml")
KFP = r"C:\Program Files\KiCad\10.0\share\kicad\footprints"
MM = pcbnew.FromMM

def lib_path(lib):
    if lib == NAME:
        return os.path.join(PRJ, NAME + ".pretty")
    return os.path.join(KFP, lib + ".pretty")

def read_netlist():
    root = ET.parse(NETLIST).getroot()
    comps = {}
    for c in root.find("components"):
        ref = c.get("ref")
        fp = c.findtext("footprint") or ""
        val = c.findtext("value") or ""
        path = c.find("sheetpath").get("tstamps")
        tst = c.findtext("tstamps") or c.findtext("tstamp")
        dnp = any(p.get("name") == "dnp" for p in c.findall("property"))
        flds = {f.get("name"): f.text or "" for f in c.findall("fields/field")}
        comps[ref] = dict(fp=fp, val=val, path=path, tst=tst, dnp=dnp, mpn=flds.get("MPN", ""))
    nets = {}
    for n in root.find("nets"):
        for nd in n.findall("node"):
            nets[(nd.get("ref"), nd.get("pin"))] = n.get("name")
    return comps, nets

def load_fp(fpid):
    lib, name = fpid.split(":")
    fp = pcbnew.FootprintLoad(lib_path(lib), name)
    assert fp, fpid
    return fp

if sys.argv[1] == "info":
    comps, _ = read_netlist()
    seen = {}
    for ref, c in sorted(comps.items()):
        if c["fp"] in seen:
            continue
        fp = load_fp(c["fp"])
        cy = fp.GetCourtyard(pcbnew.F_CrtYd)
        bb = cy.BBox() if cy.OutlineCount() else fp.GetBoundingBox(False)
        seen[c["fp"]] = ref
        print(f"{ref:5s} {c['fp'].split(':')[1][:60]:60s} x {pcbnew.ToMM(bb.GetLeft()):7.2f}..{pcbnew.ToMM(bb.GetRight()):7.2f}"
              f"  y {pcbnew.ToMM(bb.GetTop()):7.2f}..{pcbnew.ToMM(bb.GetBottom()):7.2f}")
        for p in fp.Pads():
            if p.GetNumber() in ("1",) and ref[0] in "JU":
                print(f"      pad 1 at {pcbnew.ToMM(p.GetPosition().x):.2f}, {pcbnew.ToMM(p.GetPosition().y):.2f}")
    sys.exit(0)

# ---------------- build ----------------
sys.path.insert(0, HERE)
from placement import OUTLINE, PLACE, KEEPOUT

def build(out):
    comps, nets = read_netlist()
    b = pcbnew.BOARD()
    b.SetCopperLayerCount(2)
    x0, y0, x1, y1 = OUTLINE
    for (ax, ay), (bx, by) in (((x0, y0), (x1, y0)), ((x1, y0), (x1, y1)), ((x1, y1), (x0, y1)), ((x0, y1), (x0, y0))):
        seg = pcbnew.PCB_SHAPE(b)
        seg.SetShape(pcbnew.SHAPE_T_SEGMENT)
        seg.SetStart(pcbnew.VECTOR2I(MM(ax), MM(ay))); seg.SetEnd(pcbnew.VECTOR2I(MM(bx), MM(by)))
        seg.SetLayer(pcbnew.Edge_Cuts); seg.SetWidth(MM(0.1))
        b.Add(seg)
    netitems = {}
    for name in sorted(set(nets.values())):
        ni = pcbnew.NETINFO_ITEM(b, name)
        b.Add(ni)
        netitems[name] = ni
    for name, (ax, ay, bx, by), layers, allowed, holes in KEEPOUT:
        z = pcbnew.ZONE(b)
        z.SetIsRuleArea(True)
        z.SetZoneName(name)
        ls = pcbnew.LSET()
        for l in layers:
            ls.AddLayer(b.GetLayerID(l))
        z.SetLayerSet(ls)
        z.SetDoNotAllowTracks("tracks" not in allowed); z.SetDoNotAllowVias("vias" not in allowed)
        z.SetDoNotAllowPads("pads" not in allowed); z.SetDoNotAllowZoneFills("pour" not in allowed)
        z.SetDoNotAllowFootprints("footprints" not in allowed)
        ol = z.Outline(); ol.NewOutline()
        for px, py in ((ax, ay), (bx, ay), (bx, by), (ax, by)):
            ol.Append(MM(px), MM(py))
        for k, (hx0, hy0, hx1, hy1) in enumerate(holes):
            ol.NewHole()
            for px, py in ((hx0, hy0), (hx1, hy0), (hx1, hy1), (hx0, hy1)):
                ol.Append(MM(px), MM(py), 0, k)
        b.Add(z)
    missing = []
    for ref, c in sorted(comps.items()):
        if ref not in PLACE:
            missing.append(ref); continue
        fp = load_fp(c["fp"])
        fp.SetParent(b)
        fp.SetReference(ref)
        fp.SetValue(c["val"])
        fp.SetFPIDAsString(c["fp"]) if hasattr(fp, "SetFPIDAsString") else None
        fp.SetPath(pcbnew.KIID_PATH(c["path"] + c["tst"]))
        x, y, rot = PLACE[ref][:3]
        b.Add(fp)
        fp.SetPosition(pcbnew.VECTOR2I(MM(x), MM(y)))
        fp.SetOrientationDegrees(rot)
        if len(PLACE[ref]) > 3 and PLACE[ref][3] == "B":
            fp.Flip(fp.GetPosition(), pcbnew.FLIP_DIRECTION_LEFT_RIGHT)
        if ref[0] in "RCQDF" or ref in ("U1", "U3", "U5", "U6"):   # small parts: 0.8 mm reference text
            t = fp.Reference()
            t.SetTextSize(pcbnew.VECTOR2I(MM(0.8), MM(0.8))); t.SetTextThickness(MM(0.12))
        if c["mpn"]:
            f = pcbnew.PCB_FIELD(fp, fp.GetNextFieldOrdinal(), "MPN")
            f.SetText(c["mpn"]); f.SetVisible(False); f.SetLayer(pcbnew.F_Fab)
            f.SetPosition(fp.GetPosition())
            fp.Add(f)
        if c["dnp"]:
            fp.SetDNP(True); fp.SetExcludedFromBOM(True); fp.SetExcludedFromPosFiles(True)
        for p in fp.Pads():
            n = nets.get((ref, p.GetNumber()))
            if n:
                p.SetNet(netitems[n])
    if missing:
        print("not placed:", " ".join(missing))
    b.BuildConnectivity()
    pcbnew.SaveBoard(out, b)
    print("saved", out, len(comps) - len(missing), "footprints")

def pads(path):
    b = pcbnew.LoadBoard(path)
    for fp in sorted(b.GetFootprints(), key=lambda f: f.GetReference()):
        if fp.GetReference() in sys.argv[3:]:
            for p in fp.Pads():
                print(f"{fp.GetReference()}.{p.GetNumber():4s} {pcbnew.ToMM(p.GetPosition().x):8.2f} {pcbnew.ToMM(p.GetPosition().y):8.2f} {p.GetNetname()}")

if sys.argv[1] == "build":
    build(sys.argv[2] if len(sys.argv) > 2 and sys.argv[2].endswith(".kicad_pcb") else os.path.join(PRJ, NAME + ".kicad_pcb"))
elif sys.argv[1] == "pads":
    pads(sys.argv[2])
