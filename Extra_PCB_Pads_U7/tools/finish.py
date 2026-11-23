# finish.py -- KiCad python, after route.py import + pour: tracks nearer than 0.3 mm to the board edge moved in,
# silkscreen (no reference texts for the small parts, board texts), zones refilled.
import os, pcbnew
PRJ = r"C:\work\My\AlteraZX\Extra_PCB_Pads_U7"
PCB = os.path.join(PRJ, "Extra_PCB_Pads_U7.kicad_pcb")
PRO = os.path.join(PRJ, "Extra_PCB_Pads_U7.kicad_pro")
MM = pcbnew.FromMM
EDGE = 0.3
b = pcbnew.LoadBoard(PCB)
e = b.GetBoardEdgesBoundingBox()
X0, Y0, X1, Y1 = (pcbnew.ToMM(v) + 0.05 * s for v, s in ((e.GetLeft(), 1), (e.GetTop(), 1), (e.GetRight(), -1), (e.GetBottom(), -1)))

def pull(p, half):
    lim = EDGE + half
    x = min(max(pcbnew.ToMM(p.x), X0 + lim), X1 - lim)
    y = min(max(pcbnew.ToMM(p.y), Y0 + lim), Y1 - lim)
    return pcbnew.VECTOR2I(MM(x), MM(y))

n = 0
for t in b.GetTracks():
    if t.GetClass() == "PCB_TRACK":
        half = pcbnew.ToMM(t.GetWidth()) / 2
        s, d = pull(t.GetStart(), half), pull(t.GetEnd(), half)
        if s != t.GetStart() or d != t.GetEnd():
            t.SetStart(s); t.SetEnd(d); n += 1
# a wide track along the edge is narrowed to 0.3 mm (room for the parts beside it); tracks of no length are deleted
m = 0
for t in b.GetTracks():
    if t.GetClass() == "PCB_TRACK":
        half = pcbnew.ToMM(t.GetWidth()) / 2
        near = any(min(pcbnew.ToMM(p.x) - X0, X1 - pcbnew.ToMM(p.x), pcbnew.ToMM(p.y) - Y0, Y1 - pcbnew.ToMM(p.y)) < EDGE + half + 0.01
                   for p in (t.GetStart(), t.GetEnd()))
        if near and t.GetWidth() > MM(0.3):
            t.SetWidth(MM(0.3)); m += 1
dead = [t for t in b.GetTracks() if t.GetClass() == "PCB_TRACK" and t.GetStart() == t.GetEnd()]
for t in dead:
    b.Remove(t)
print("tracks moved in", n, "narrowed", m)

for fp in b.GetFootprints():
    ref = fp.GetReference()
    r = fp.Reference()
    if ref[0] in "RCJ" or ref == "U3":
        r.SetVisible(False)
    else:
        # U1, U2: below the chip, between its output tracks
        r.SetTextSize(pcbnew.VECTOR2I(MM(0.8), MM(0.8))); r.SetTextThickness(MM(0.13))
        r.SetPosition(pcbnew.VECTOR2I(fp.GetPosition().x, fp.GetPosition().y + MM(4.7)))
        r.SetTextAngleDegrees(0)
    fp.Value().SetVisible(False)

# board texts: an existing text of the same wording and layer is moved (removing texts crashes this pcbnew)
HAVE = {(d.GetText(), d.GetLayer()): d for d in b.GetDrawings() if d.GetClass() == "PCB_TEXT"}
def text(s, x, y, layer, size=1.0):
    t = HAVE.get((s, layer))
    if t is None:
        t = pcbnew.PCB_TEXT(b)
        t.SetText(s); t.SetLayer(layer)
        b.Add(t)
    t.SetPosition(pcbnew.VECTOR2I(MM(X0 - 0.05 + x), MM(Y0 - 0.05 + y)))
    t.SetTextSize(pcbnew.VECTOR2I(MM(size), MM(size))); t.SetTextThickness(MM(size * 0.15))
    t.SetMirrored(layer == pcbnew.B_SilkS)
text("PAD 1", 27.3, 12.9, pcbnew.B_SilkS)
text("PAD 2", 75.2, 12.6, pcbnew.B_SilkS)
text("L pads U7 r1", 59.0, 12.9, pcbnew.B_SilkS)
text("1", 2.68, 13.2, pcbnew.B_SilkS)
text("1", 1.1, 12.9, pcbnew.F_SilkS)
text("63 5V", 74.5, 13.75, pcbnew.F_SilkS, 0.8)
text("PAD 1", 27.2, 4.0, pcbnew.F_SilkS)
text("PAD 2", 56.6, 4.0, pcbnew.F_SilkS)

pcbnew.ZONE_FILLER(b).Fill([z for z in b.Zones() if not z.GetIsRuleArea()])
keep = open(PRO, "rb").read()
pcbnew.SaveBoard(PCB, b)
open(PRO, "wb").write(keep)
