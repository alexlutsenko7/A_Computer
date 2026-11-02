import pcbnew
P = r"C:\work\My\AlteraZX\Extended\qm_atrix_ext.kicad_pcb"
b = pcbnew.LoadBoard(P); MM = 1e6; mm = lambda v: int(round(v * MM))
r = lambda bb: [round(v / MM, 2) for v in (bb.GetLeft(), bb.GetTop(), bb.GetRight(), bb.GetBottom())]
def crt(g):
    c = g.GetCourtyard(pcbnew.F_CrtYd); return c.BBox() if c.OutlineCount() else g.GetBoundingBox(False)
fps = {g.GetReference(): g for g in b.GetFootprints()}
tracks = list(b.GetTracks())
MOVED = ["J2", "J7", "U1", "R1", "R2", "R3", "R4", "C1"]
# tracks ending on pads of parts that will move (old positions)
kill = {}
for ref in MOVED:
    for p in fps[ref].Pads():
        for t in tracks:
            pts = [t.GetPosition()] if t.GetClass() == "PCB_VIA" else [t.GetStart(), t.GetEnd()]
            if t.GetNetCode() == p.GetNetCode() and any(p.HitTest(q) for q in pts): kill[t.m_Uuid.AsString()] = t
old = fps["J2"]; path, val = old.GetPath(), old.GetValue(); padnet = {p.GetNumber(): p.GetNetname() for p in old.Pads()}
y0 = old.GetPosition().y
n = pcbnew.FootprintLoad(r"C:\work\My\AlteraZX\Extended\qm_atrix_ext.pretty", "DSUB-15-HD_Socket_Horizontal_P2.29x2.54mm_CONNFLY_DS1038")
n.SetFPID(pcbnew.LIB_ID("qm_atrix_ext", "DSUB-15-HD_Socket_Horizontal_P2.29x2.54mm_CONNFLY_DS1038"))
n.SetReference("J2"); n.SetValue(val); n.SetPath(path); n.SetSheetname("/"); n.SetSheetfile("qm_atrix_ext.kicad_sch")
b.Add(n); n.SetOrientationDegrees(-90); n.SetPosition(pcbnew.VECTOR2I(mm(50.95 + 13.71), y0))
n.Move(pcbnew.VECTOR2I(0, mm(91.2) - crt(n).GetTop()))
for p in n.Pads():
    nm = padnet.get(p.GetNumber())
    if nm: p.SetNet(b.FindNet(nm))
rf = n.Reference(); rf.SetTextSize(pcbnew.VECTOR2I(mm(0.8), mm(0.8))); rf.SetTextThickness(mm(0.12))
n.Value().SetVisible(False)
b.Remove(old)
fps["J7"].Move(pcbnew.VECTOR2I(0, mm(0.33)))
fps["U1"].Move(pcbnew.VECTOR2I(mm(1.5), 0))
for x in ("R1", "R2", "R3", "R4", "C1"): fps[x].Move(pcbnew.VECTOR2I(mm(1.5), 0))
print("J2", r(crt(n)), "| J7", r(crt(fps["J7"])), "| U1", r(crt(fps["U1"])), "| R1", r(crt(fps["R1"])))
# tracks/vias that collide with any moved pad now
allfp = [g for g in b.GetFootprints()]
movedfp = [n] + [fps[x] for x in MOVED if x != "J2"]
for t in tracks:
    if t.m_Uuid.AsString() in kill: continue
    for g in movedfp:
        for p in g.Pads():
            for L in (pcbnew.F_Cu, pcbnew.B_Cu):
                if t.IsOnLayer(L) and p.IsOnLayer(L) and p.GetEffectiveShape(L).Collide(t.GetEffectiveShape(L), mm(0.2)) and not (p.GetNetCode() == t.GetNetCode() and p.GetNetCode() > 0):
                    kill[t.m_Uuid.AsString()] = t
    # also tracks crossing the new J2 courtyard area (its pins sit there now)
for t in list(kill.values()): b.Remove(t)
print("removed", len(kill), "track items")
pcbnew.SaveBoard(P, b)
