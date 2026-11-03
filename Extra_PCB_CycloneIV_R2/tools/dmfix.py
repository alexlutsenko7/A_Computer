# dmfix.py -- KiCad python: the USB pair at U3 (CP2102N, rotated 180 deg): D- (pin 4) leaves upwards to a via, runs
#   down on B.Cu left of the ESP32 lines and comes back up to U5 pin 3; D+ (pin 3) runs between C15's pads to U5 pin 1.
#   Pin 2 (GND) goes to the centre pad, pins 5 / 6 (+3V3) to pin 7 (its via), freeing the space right of U3.
import pcbnew
P = r"C:\work\My\AlteraZX\Extra_PCB_CycloneIV_R2\Extra_PCB_CycloneIV_R2.kicad_pcb"; PRO = P.replace(".kicad_pcb", ".kicad_pro")
b = pcbnew.LoadBoard(P); MM = pcbnew.FromMM; T = pcbnew.ToMM; V = lambda x, y: pcbnew.VECTOR2I(MM(x), MM(y))
near = lambda p, x, y: abs(T(p.x) - x) < 0.03 and abs(T(p.y) - y) < 0.03
dead = []
for t in list(b.Tracks()):
    n = t.GetNetname()
    pts = [t.GetPosition()] if t.GetClass() == "PCB_VIA" else [t.GetStart(), t.GetEnd()]
    if n == "GND" and any(near(p, 118.83, 121.61) for p in pts): dead.append(t)
    elif n == "+3V3" and any(near(p, 118.78, 119.93) for p in pts): dead.append(t)
    elif n == "/USBC_DP" and t.GetClass() == "PCB_TRACK" and all(117.9 <= T(p.x) <= 120.22 and 120.9 <= T(p.y) <= 121.3 for p in pts):
        dead.append(t)
for t in dead: b.Remove(t)
def trk(n, w, layer, *pts):
    for (x1, y1), (x2, y2) in zip(pts, pts[1:]):
        t = pcbnew.PCB_TRACK(b); t.SetStart(V(x1, y1)); t.SetEnd(V(x2, y2)); t.SetWidth(MM(w))
        t.SetLayer(layer); t.SetNet(b.FindNet(n)); t.SetLocked(True); b.Add(t)
def via(n, x, y):
    v = pcbnew.PCB_VIA(b); v.SetPosition(V(x, y)); v.SetWidth(MM(0.6)); v.SetDrill(MM(0.3)); v.SetNet(b.FindNet(n))
    v.SetViaType(pcbnew.VIATYPE_THROUGH); v.SetLocked(True); b.Add(v)
F, Bc = pcbnew.F_Cu, pcbnew.B_Cu
trk("GND", 0.25, F, (117.94, 121.75), (117.2, 121.75))
trk("+3V3", 0.2, F, (117.94, 120.25), (117.94, 119.75), (117.6, 119.4), (117.25, 119.06))
trk("/USBC_DP", 0.2, F, (117.94, 121.25), (118.75, 121.25), (119.02, 120.98), (120.21, 120.98))
trk("/USBC_DM", 0.2, F, (117.94, 120.75), (118.55, 120.75), (118.85, 120.45), (118.85, 119.55)); via("/USBC_DM", 118.85, 119.55)
trk("/USBC_DM", 0.2, Bc, (118.85, 119.55), (118.85, 127.3)); via("/USBC_DM", 118.85, 127.3)
trk("/USBC_DM", 0.2, F, (118.85, 127.3), (121.0, 127.3), (121.6, 126.7), (121.7, 126.1))
keep = open(PRO, "rb").read(); pcbnew.SaveBoard(P, b); open(PRO, "wb").write(keep); print("removed", len(dead))
