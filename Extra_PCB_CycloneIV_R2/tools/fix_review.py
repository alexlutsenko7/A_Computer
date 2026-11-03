# fix_review.py -- KiCad python, review fixes 2026-11-03:
#   d1   : remove D1 (SS34), VBUS_C copper -> +5V, a 0.4 mm track where D1's pads were
#   u1via: the GND via inside U1 pin 1's pad moved next to the pad
#   edge : copper-to-edge 0.3 mm: bottom-edge track ends at y 155.0246 moved up 0.05 mm
import pcbnew, sys
P = r"C:\work\My\AlteraZX\Extra_PCB_CycloneIV_R2\Extra_PCB_CycloneIV_R2.kicad_pcb"; PRO = P.replace(".kicad_pcb", ".kicad_pro")
b = pcbnew.LoadBoard(P); MM = pcbnew.FromMM; T = pcbnew.ToMM; V = lambda x, y: pcbnew.VECTOR2I(MM(x), MM(y))
step = sys.argv[1]
if step == "d1":
    d1 = b.FindFootprintByReference("D1")
    pa = {p.GetNumber(): p.GetPosition() for p in d1.Pads()}
    n5 = b.FindNet("+5V"); nv = b.FindNet("/VBUS_C")
    for t in b.Tracks():
        if t.GetNetname() == "/VBUS_C": t.SetNet(n5)
    for fp in b.GetFootprints():
        for p in fp.Pads():
            if p.GetNetname() == "/VBUS_C": p.SetNet(n5)
    for z in b.Zones():
        if z.GetNetname() == "/VBUS_C": z.SetNet(n5)
    b.Remove(d1)
    t = pcbnew.PCB_TRACK(b); t.SetStart(pa["1"]); t.SetEnd(pa["2"]); t.SetWidth(MM(0.4)); t.SetLayer(pcbnew.F_Cu); t.SetNet(n5); b.Add(t)
    print("D1 removed; bridge", T(pa["1"].x), T(pa["1"].y), "->", T(pa["2"].x), T(pa["2"].y))
elif step == "u1via":   # GND via out of U1 pin 1's pad (to 86.65, 125.67); the +3V3 via in pin 2's small pad removed
    u1 = b.FindFootprintByReference("U1"); pads = {p.GetNumber(): p for p in u1.Pads() if abs(p.GetSize(pcbnew.F_Cu).y - MM(1.5)) < 10}
    for v in list(b.Tracks()):
        if v.GetClass() != "PCB_VIA": continue
        if v.GetNetname() == "+3V3" and pads["2"].HitTest(v.GetPosition()):
            b.Remove(v); print("removed +3V3 via in U1.2"); continue
        if v.GetNetname() == "GND" and pads["1"].HitTest(v.GetPosition()):
            old = v.GetPosition(); new = V(86.65, 125.67); v.SetPosition(new)
            for t in b.Tracks():
                if t.GetClass() == "PCB_TRACK" and t.GetNetname() == "GND":
                    if t.GetStart() == old: t.SetStart(new)
                    if t.GetEnd() == old: t.SetEnd(new)
            t = pcbnew.PCB_TRACK(b); t.SetStart(pads["1"].GetPosition()); t.SetEnd(new); t.SetWidth(MM(0.3))
            t.SetLayer(pcbnew.F_Cu); t.SetNet(b.FindNet("GND")); b.Add(t)
            print("U1.1 GND via", round(T(old.x), 2), round(T(old.y), 2), "-> 86.65 125.67")
elif step == "edge":
    n = 0
    for t in b.Tracks():
        if t.GetClass() != "PCB_TRACK": continue
        for get, set_ in ((t.GetStart, t.SetStart), (t.GetEnd, t.SetEnd)):
            p = get()
            if abs(T(p.y) - 155.0246) < 0.003:
                set_(pcbnew.VECTOR2I(p.x, MM(T(p.y) - 0.05))); n += 1
    print("moved track ends", n)
keep = open(PRO, "rb").read(); pcbnew.SaveBoard(P, b); open(PRO, "wb").write(keep)
if step == "more":
    def move_via(net, ox, oy, nx, ny):
        for v in list(b.Tracks()):
            if v.GetClass() == "PCB_VIA" and v.GetNetname() == net and abs(T(v.GetPosition().x) - ox) < 0.02 and abs(T(v.GetPosition().y) - oy) < 0.02:
                old = v.GetPosition(); new = V(nx, ny); v.SetPosition(new)
                for t in b.Tracks():
                    if t.GetClass() == "PCB_TRACK" and t.GetNetname() == net:
                        if t.GetStart() == old: t.SetStart(new)
                        if t.GetEnd() == old: t.SetEnd(new)
                print("via", net, ox, oy, "->", nx, ny); return
        print("via not found", net, ox, oy)
    move_via("GND", 86.65, 125.67, 86.15, 125.5)
    for v in b.Tracks():   # the JOY via near the bottom edge
        if v.GetClass() == "PCB_VIA" and abs(T(v.GetPosition().x) - 83.02) < 0.02 and abs(T(v.GetPosition().y) - 154.8634) < 0.02:
            move_via(v.GetNetname(), T(v.GetPosition().x), T(v.GetPosition().y), 83.02, 154.78); break
    # U1 pin 2 (small pad) to the tab under the package
    t = pcbnew.PCB_TRACK(b); t.SetStart(V(88.35, 128.5)); t.SetEnd(V(94.65, 128.5)); t.SetWidth(MM(0.4))
    t.SetLayer(pcbnew.F_Cu); t.SetNet(b.FindNet("+3V3")); b.Add(t)
    # J7 (microSD) 0.25 mm inward, its tracks' pad ends dragged along
    j7 = b.FindFootprintByReference("J7"); d = MM(0.25)
    ends = [p.GetPosition() for p in j7.Pads()]
    for t in b.Tracks():
        if t.GetClass() != "PCB_TRACK": continue
        if t.GetStart() in ends: t.SetStart(pcbnew.VECTOR2I(t.GetStart().x + d, t.GetStart().y))
        if t.GetEnd() in ends: t.SetEnd(pcbnew.VECTOR2I(t.GetEnd().x + d, t.GetEnd().y))
    j7.Move(pcbnew.VECTOR2I(d, 0)); print("J7 moved 0.25 mm in")
    keep = open(PRO, "rb").read(); pcbnew.SaveBoard(P, b); open(PRO, "wb").write(keep)
if step == "joy":
    for t in b.Tracks():
        if t.GetClass() == "PCB_TRACK" and t.GetNetname() == "/JOY1_UP":
            for get, set_ in ((t.GetStart, t.SetStart), (t.GetEnd, t.SetEnd)):
                p = get()
                if abs(T(p.x) - 83.02) < 0.01 and abs(T(p.y) - 154.78) < 0.01 and T(t.GetLength()) > 5:
                    set_(V(83.3, 154.8634))
                    s = pcbnew.PCB_TRACK(b); s.SetStart(V(83.3, 154.8634)); s.SetEnd(V(83.02, 154.78)); s.SetWidth(t.GetWidth())
                    s.SetLayer(t.GetLayer()); s.SetNet(t.GetNet()); b.Add(s); print("JOY1_UP track straightened")
    keep = open(PRO, "rb").read(); pcbnew.SaveBoard(P, b); open(PRO, "wb").write(keep)
