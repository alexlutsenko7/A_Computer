# u3fix.py -- KiCad python: frees the left side of U3 (CP2102N) for the USB pair (pins 3 / 4):
#   pin 2 (GND) -> the centre pad instead of a via; pins 5 / 6 / 7 (+3V3) joined, one via below pin 7;
#   R41 pin 2 (GND) via moved between R41 and R42. New items locked.
import pcbnew
P = r"C:\work\My\AlteraZX\Extra_PCB_CycloneIV_R2\Extra_PCB_CycloneIV_R2.kicad_pcb"; PRO = P.replace(".kicad_pcb", ".kicad_pro")
b = pcbnew.LoadBoard(P); MM = pcbnew.FromMM; T = pcbnew.ToMM; V = lambda x, y: pcbnew.VECTOR2I(MM(x), MM(y))
old = ((113.17, 120.39, "GND"), (113.22, 121.50, "GND"), (113.50, 122.45, "+3V3"))
dead = []
for t in list(b.Tracks()):
    pts = [t.GetPosition()] if t.GetClass() == "PCB_VIA" else [t.GetStart(), t.GetEnd()]
    if any(t.GetNetname() == n and abs(T(p.x) - x) < 0.05 and abs(T(p.y) - y) < 0.05 for p in pts for x, y, n in old):
        dead.append(t)
for t in dead: b.Remove(t)
def trk(n, w, *pts):
    for (x1, y1), (x2, y2) in zip(pts, pts[1:]):
        t = pcbnew.PCB_TRACK(b); t.SetStart(V(x1, y1)); t.SetEnd(V(x2, y2)); t.SetWidth(MM(w))
        t.SetLayer(pcbnew.F_Cu); t.SetNet(b.FindNet(n)); t.SetLocked(True); b.Add(t)
def via(n, x, y):
    v = pcbnew.PCB_VIA(b); v.SetPosition(V(x, y)); v.SetWidth(MM(0.6)); v.SetDrill(MM(0.3)); v.SetNet(b.FindNet(n))
    v.SetViaType(pcbnew.VIATYPE_THROUGH); v.SetLocked(True); b.Add(v)
trk("GND", 0.25, (114.06, 120.25), (114.85, 120.25))                       # pin 2 -> centre pad
trk("+3V3", 0.2, (114.06, 121.75), (114.06, 122.25), (114.4, 122.6), (114.75, 122.94))   # pins 5, 6, 7
trk("+3V3", 0.25, (114.75, 122.94), (114.75, 123.45), (114.45, 124.0)); via("+3V3", 114.45, 124.0)
trk("GND", 0.25, (112.33, 121.5), (112.33, 122.5)); via("GND", 112.33, 122.5)   # R41 pin 2
keep = open(PRO, "rb").read(); pcbnew.SaveBoard(P, b); open(PRO, "wb").write(keep); print("removed", len(dead))
