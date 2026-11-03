# u2fan.py -- KiCad python: plane vias for the ESP32's GND / +3V3 pins after the module moved to x 118.35:
#   pin 1 GND (126.61, 91.29), pin 2 +3V3 (125.34, 91.29), pin 15 GND (108.83, 91.29) up; pin 38 GND (126.61, 108.79) down.
import pcbnew
P = r"C:\work\My\AlteraZX\Extra_PCB_CycloneIV_R2\Extra_PCB_CycloneIV_R2.kicad_pcb"; PRO = P.replace(".kicad_pcb", ".kicad_pro")
b = pcbnew.LoadBoard(P); MM = pcbnew.FromMM; V = lambda x, y: pcbnew.VECTOR2I(MM(x), MM(y))
for n, (px, py), (vx, vy) in (("GND", (126.61, 91.29), (126.75, 89.75)), ("+3V3", (125.34, 91.29), (125.34, 89.75)),
                              ("GND", (108.83, 91.29), (108.83, 89.75)), ("GND", (126.61, 108.79), (126.61, 110.3))):
    t = pcbnew.PCB_TRACK(b); t.SetStart(V(px, py)); t.SetEnd(V(vx, vy)); t.SetWidth(MM(0.3)); t.SetLayer(pcbnew.F_Cu)
    t.SetNet(b.FindNet(n)); t.SetLocked(True); b.Add(t)
    v = pcbnew.PCB_VIA(b); v.SetPosition(V(vx, vy)); v.SetWidth(MM(0.6)); v.SetDrill(MM(0.3)); v.SetNet(b.FindNet(n))
    v.SetViaType(pcbnew.VIATYPE_THROUGH); v.SetLocked(True); b.Add(v)
keep = open(PRO, "rb").read(); pcbnew.SaveBoard(P, b); open(PRO, "wb").write(keep); print("u2 fan-out done")
