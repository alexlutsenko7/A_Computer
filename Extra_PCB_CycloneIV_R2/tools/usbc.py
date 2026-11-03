# usbc.py -- KiCad python: hand layout of the USB-C (J5) corner on the 4-layer board (pads at x 127.36):
#   D+ pads B6 / A6 joined left of the pads (x 126.2), D- pads A7 / B7 joined right of them under the connector
#   (x 128.45, track only); VBUS pad pairs (y 122.05, 126.95) -> vias at x 126.0 -> B.Cu joiner -> via under U5 ->
#   U5 pin 5; CC2 straight to R39; CC1 through a tented via under the connector, B.Cu round to R38; R39's GND via moved.
#   Removes ESP_SCK (re-routed by FreeRouting), any older CC1 route and the old R39.2 fan-out. All new items locked.
import pcbnew, math
P = r"C:\work\My\AlteraZX\Extra_PCB_CycloneIV_R2\Extra_PCB_CycloneIV_R2.kicad_pcb"; PRO = P.replace(".kicad_pcb", ".kicad_pro")
b = pcbnew.LoadBoard(P); MM = pcbnew.FromMM; V = lambda x, y: pcbnew.VECTOR2I(MM(x), MM(y))
net = lambda n: b.FindNet(n)
dead = [t for t in list(b.Tracks()) if t.GetNetname() in ("/ESP_SCK", "/CC1")]
for t in list(b.Tracks()):   # fan-outs of R39.2 and of J5's GND pins (vias + tracks): replaced below
    if t.GetNetname() == "GND":
        pts = [t.GetPosition()] if t.GetClass() == "PCB_VIA" else [t.GetStart(), t.GetEnd()]
        if any(abs(pcbnew.ToMM(p.x) - x) < 0.05 and abs(pcbnew.ToMM(p.y) - y) < 0.05 for p in pts
               for x, y in ((125.72, 121.80), (126.65, 128.31), (126.65, 120.69))):
            dead.append(t)
for t in dead: b.Remove(t)
def trk(n, w, layer, *pts):
    for (x1, y1), (x2, y2) in zip(pts, pts[1:]):
        t = pcbnew.PCB_TRACK(b); t.SetStart(V(x1, y1)); t.SetEnd(V(x2, y2)); t.SetWidth(MM(w))
        t.SetLayer(layer); t.SetNet(net(n)); t.SetLocked(True); b.Add(t)
def via(n, x, y, tent=False):
    v = pcbnew.PCB_VIA(b); v.SetPosition(V(x, y)); v.SetWidth(MM(0.6)); v.SetDrill(MM(0.3)); v.SetNet(net(n))
    v.SetViaType(pcbnew.VIATYPE_THROUGH); v.SetLocked(True)
    if tent:
        for f in ("SetFrontTentingMode", "SetBackTentingMode"):
            if hasattr(v, f): getattr(v, f)(pcbnew.TENTING_MODE_TENTED)
    b.Add(v)
F, Bc = pcbnew.F_Cu, pcbnew.B_Cu
# D+ : B6 (123.75) + A6 (124.75) joined at x 126.2, out at y 124.05 to U5 pin 6
trk("/USBC_DP", 0.2, F, (127.36, 123.75), (126.2, 123.75), (126.2, 124.05), (126.2, 124.75), (127.36, 124.75))
trk("/USBC_DP", 0.2, F, (126.2, 124.05), (124.34, 124.05))
# D- : A7 (124.25) + B7 (125.25) joined at x 128.45 (under the connector), out from B7 to U5 pin 4
trk("/USBC_DM", 0.2, F, (127.36, 124.25), (128.45, 124.25), (128.45, 125.25), (127.36, 125.25))
trk("/USBC_DM", 0.2, F, (127.36, 125.25), (126.0, 125.25), (125.3, 125.95), (124.34, 125.95))
# VBUS: pad pairs -> vias -> B.Cu joiner -> via under U5 -> U5 pin 5
trk("/VBUS_C", 0.4, F, (127.36, 122.05), (126.0, 122.05)); via("/VBUS_C", 126.0, 122.05)
trk("/VBUS_C", 0.4, F, (127.36, 126.95), (126.0, 126.95)); via("/VBUS_C", 126.0, 126.95)
trk("/VBUS_C", 0.4, Bc, (126.0, 122.05), (126.0, 125.0), (126.0, 126.95))
trk("/VBUS_C", 0.4, Bc, (126.0, 125.0), (123.2, 125.0)); via("/VBUS_C", 123.2, 125.0)
trk("/VBUS_C", 0.3, F, (124.34, 125.0), (123.2, 125.0))
# CC2 straight to R39 pin 1
trk("/CC2", 0.2, F, (127.36, 122.75), (123.6, 122.75), (123.17, 122.32), (123.17, 121.8))
# CC1: tented via under the connector, B.Cu round the VBUS joiner, via beside R38, up to R38 pin 1
trk("/CC1", 0.2, F, (127.36, 125.75), (128.6, 125.75), (128.7, 125.85)); via("/CC1", 128.7, 125.85, tent=True)
trk("/CC1", 0.2, Bc, (128.7, 125.85), (127.6, 126.95), (126.9, 127.65), (126.9, 130.4), (124.2, 130.4), (123.17, 129.37))
via("/CC1", 123.17, 129.35)
trk("/CC1", 0.2, F, (123.17, 129.35), (123.17, 128.2))
# U4 pin 3 GND fan-out track: 0.2 mm (was 0.01 mm too close to the unused pin 4)
for t in list(b.Tracks()):
    if t.GetClass() == "PCB_TRACK" and t.GetNetname() == "GND" and abs(pcbnew.ToMM(t.GetStart().x) - 101.8375) < 0.01 \
            and abs(pcbnew.ToMM(t.GetStart().y) - 138.25) < 0.6:
        t.SetWidth(MM(0.2))
# J5 GND pins A1/B12 and A12/B1 straight to the shield pads (GND, through all layers)
trk("GND", 0.3, F, (127.36, 127.75), (127.7, 128.6)); trk("GND", 0.3, F, (127.36, 121.25), (127.7, 120.4))
# R39 pin 2 GND: new fan-out via above the pad
trk("GND", 0.25, F, (124.83, 121.8), (124.83, 120.8)); via("GND", 124.83, 120.8)
keep = open(PRO, "rb").read(); pcbnew.SaveBoard(P, b); open(PRO, "wb").write(keep)
print("removed", len(dead), "done")
