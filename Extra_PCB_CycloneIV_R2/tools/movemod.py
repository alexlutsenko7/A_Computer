# movemod.py X Y DXZ -- KiCad python: put the ESP32 module U2 at X, Y; move its pad 39 vias and both ESP32 rule areas
#   by DXZ mm in x; delete every track that ends on one of its pads (re-routed afterwards).
import pcbnew, sys
X, Y, DX = map(float, sys.argv[1:4])
P = r"C:\work\My\AlteraZX\Extra_PCB_CycloneIV_R2\Extra_PCB_CycloneIV_R2.kicad_pcb"; PRO = P.replace(".kicad_pcb", ".kicad_pro")
b = pcbnew.LoadBoard(P); MM = pcbnew.FromMM; T = pcbnew.ToMM
u2 = b.FindFootprintByReference("U2")
p39 = [p for p in u2.Pads() if p.GetNumber() == "39"][0]; c39 = p39.GetPosition()
pads = [p for p in u2.Pads() if p.GetNumber() not in ("39", "")]
dead, moved = [], 0
for t in list(b.Tracks()):
    if t.GetClass() == "PCB_VIA" and t.GetNetname() == "GND" and abs(t.GetPosition().x - c39.x) < MM(1.6) and abs(t.GetPosition().y - c39.y) < MM(1.6):
        t.Move(pcbnew.VECTOR2I(MM(DX), 0)); moved += 1; continue
    if t.GetClass() == "PCB_TRACK" and any(p.HitTest(e) for p in pads for e in (t.GetStart(), t.GetEnd())):
        dead.append(t)
for t in dead: b.Remove(t)
u2.SetPosition(pcbnew.VECTOR2I(MM(X), MM(Y)))
for z in b.Zones():
    if z.GetIsRuleArea() and z.GetZoneName().startswith("ESP32"):
        z.Move(pcbnew.VECTOR2I(MM(DX), 0))
        if z.GetZoneName() == "ESP32 antenna clearance":   # keep it reaching the board edge
            ol = z.Outline()
            for i in range(ol.TotalVertices()):
                v = ol.CVertex(i)
                if T(v.x) > 133: ol.SetVertex(i, pcbnew.VECTOR2I(MM(135.05), v.y))
keep = open(PRO, "rb").read(); pcbnew.SaveBoard(P, b); open(PRO, "wb").write(keep)
print("moved U2", DX, "pad-39 vias", moved, "removed tracks", len(dead), "U2 at", T(u2.GetPosition().x), T(u2.GetPosition().y))
