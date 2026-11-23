# route.py -- KiCad python. Routing steps for the pad board (FreeRouting 2.5.0 in between):
#   route.py dsn     : export C:\Users\Public\fr\pads.dsn
#   route.py import  : import C:\Users\Public\fr\pads.ses (FreeRouting result) into the board
#   route.py pour    : GND fill on F.Cu + B.Cu, stitching vias on a grid where both layers are GND, refill
# The .kicad_pro is restored after every save (pcbnew.SaveBoard rewrites it with defaults).
import sys, os, shutil, pcbnew
PRJ = r"C:\work\My\AlteraZX\Extra_PCB_Pads_U7"
PCB = os.path.join(PRJ, "Extra_PCB_Pads_U7.kicad_pcb")
PRO = os.path.join(PRJ, "Extra_PCB_Pads_U7.kicad_pro")
FR = r"C:\Users\Public\fr"
MM = pcbnew.FromMM

def save(b):
    keep = open(PRO, "rb").read()
    pcbnew.SaveBoard(PCB, b)
    open(PRO, "wb").write(keep)

def via(b, x, y, net, d=0.6, drill=0.3):
    v = pcbnew.PCB_VIA(b)
    v.SetPosition(pcbnew.VECTOR2I(MM(x), MM(y)))
    v.SetWidth(MM(d)); v.SetDrill(MM(drill)); v.SetNet(net)
    v.SetViaType(pcbnew.VIATYPE_THROUGH)
    b.Add(v)
    return v

b = pcbnew.LoadBoard(PCB)
gnd = b.FindNet("GND")
step = sys.argv[1]
if step == "dsn":
    os.makedirs(FR, exist_ok=True)
    print("DSN", pcbnew.ExportSpecctraDSN(b, os.path.join(FR, "pads.dsn")))
elif step == "import":
    print("SES", pcbnew.ImportSpecctraSES(b, os.path.join(FR, "pads.ses")))
    save(b)
    print("tracks", len(b.GetTracks()))
if step == "pour":   # GND fill on both layers + stitching vias every STEP mm where both layers are GND fill
    STEP = float(sys.argv[2]) if len(sys.argv) > 2 else 4.0
    e = b.GetBoardEdgesBoundingBox(); w = MM(0.05)
    L, T, R, B = e.GetLeft() + w, e.GetTop() + w, e.GetRight() - w, e.GetBottom() - w
    for z in [z for z in b.Zones() if not z.GetIsRuleArea()]:
        b.Remove(z)
    zones = []
    for layer in (pcbnew.F_Cu, pcbnew.B_Cu):
        z = pcbnew.ZONE(b); z.SetLayer(layer); z.SetNet(gnd); z.SetZoneName("GND " + b.GetLayerName(layer))
        ol = z.Outline(); ol.NewOutline()
        for x, y in ((L, T), (R, T), (R, B), (L, B)): ol.Append(x, y)
        z.SetLocalClearance(MM(0.25)); z.SetMinThickness(MM(0.25))
        z.SetPadConnection(pcbnew.ZONE_CONNECTION_THERMAL)
        z.SetThermalReliefGap(MM(0.4)); z.SetThermalReliefSpokeWidth(MM(0.4))
        z.SetIslandRemovalMode(pcbnew.ISLAND_REMOVAL_MODE_ALWAYS)
        b.Add(z); zones.append(z)
    pcbnew.ZONE_FILLER(b).Fill(zones)
    # stitching vias: the via plus 0.35 mm around it inside both fills
    import math
    fF, fB = zones[0].GetFilledPolysList(pcbnew.F_Cu), zones[1].GetFilledPolysList(pcbnew.B_Cu)
    rules = [z for z in b.Zones() if z.GetIsRuleArea() and z.GetDoNotAllowVias()]
    def inside(fill, x, y, r):
        pts = [(x, y)] + [(x + r * math.cos(a * math.pi / 4), y + r * math.sin(a * math.pi / 4)) for a in range(8)]
        return all(fill.Contains(pcbnew.VECTOR2I(MM(px), MM(py))) for px, py in pts)
    def blocked(x, y):
        p = pcbnew.VECTOR2I(MM(x), MM(y))
        for z in rules:
            for l in (pcbnew.F_Cu, pcbnew.B_Cu):
                if z.IsOnLayer(l) and z.Outline().Contains(p):
                    return True
        return False
    n = 0
    x0, y0 = pcbnew.ToMM(L) + 2, pcbnew.ToMM(T) + 2
    yy = y0
    while yy < pcbnew.ToMM(B) - 1.5:
        xx = x0
        while xx < pcbnew.ToMM(R) - 1.5:
            if inside(fF, xx, yy, 0.65) and inside(fB, xx, yy, 0.65) and not blocked(xx, yy):
                via(b, xx, yy, gnd); n += 1
            xx += STEP
        yy += STEP
    pcbnew.ZONE_FILLER(b).Fill(zones)
    save(b)
    for z in zones:
        l = z.GetLayer(); fp = z.GetFilledPolysList(l)
