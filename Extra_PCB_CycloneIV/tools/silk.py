import pcbnew, math
P = r"C:\work\My\AlteraZX\Extended\qm_atrix_ext.kicad_pcb"
b = pcbnew.LoadBoard(P); MM = 1e6
CLR = 0.1 * MM
MOVE_REFS = ["R17", "R18", "U1"]
edge = b.GetBoardEdgesBoundingBox(); EI = 0.35 * MM
EL, ET, ER, EB = edge.GetLeft() + EI, edge.GetTop() + EI, edge.GetRight() - EI, edge.GetBottom() - EI

def rect(bb, m=0): return (bb.GetLeft() - m, bb.GetTop() - m, bb.GetRight() + m, bb.GetBottom() + m)
def rr(a, c): return a[0] < c[2] and c[0] < a[2] and a[1] < c[3] and c[1] < a[3]
def seg_hits(r, x1, y1, x2, y2):
    # Liang-Barsky clip of segment against rect r
    t0, t1, dx, dy = 0.0, 1.0, x2 - x1, y2 - y1
    for p, q in ((-dx, x1 - r[0]), (dx, r[2] - x1), (-dy, y1 - r[1]), (dy, r[3] - y1)):
        if p == 0:
            if q < 0: return False
        else:
            t = q / p
            if p < 0: t0 = max(t0, t)
            else: t1 = min(t1, t)
            if t0 > t1: return False
    return True

rects, segs = [], []          # obstacles
movable = set()
title = None
for d in b.GetDrawings():
    if isinstance(d, pcbnew.PCB_TEXT) and d.GetText().startswith("QM_Atrix"): title = d
for f in b.GetFootprints():
    for p in f.Pads():
        if p.IsOnLayer(pcbnew.F_Cu) or p.IsOnLayer(pcbnew.F_Mask): rects.append(rect(p.GetBoundingBox(), CLR))
    for g in f.GraphicalItems():
        if g.GetLayer() == pcbnew.F_SilkS and isinstance(g, pcbnew.PCB_SHAPE):
            w = g.GetWidth() / 2 + CLR
            if g.GetShape() == pcbnew.SHAPE_T_SEGMENT:
                segs.append((g.GetStart().x, g.GetStart().y, g.GetEnd().x, g.GetEnd().y, w))
            else:
                bb = g.GetBoundingBox(); x0, y0, x1, y1 = bb.GetLeft(), bb.GetTop(), bb.GetRight(), bb.GetBottom()
                if g.GetShape() == pcbnew.SHAPE_T_RECT:
                    for s in ((x0, y0, x1, y0), (x1, y0, x1, y1), (x1, y1, x0, y1), (x0, y1, x0, y0)): segs.append(s + (w,))
                else: rects.append(rect(bb, CLR))
        if isinstance(g, pcbnew.PCB_TEXT) and g.GetLayer() == pcbnew.F_SilkS and g.IsVisible(): rects.append(rect(g.GetBoundingBox(), CLR))
    for fld in (f.Reference(), f.Value()):
        if fld.GetLayer() == pcbnew.F_SilkS and fld.IsVisible() and f.GetReference() not in MOVE_REFS:
            rects.append(rect(fld.GetBoundingBox(), CLR))
for t in b.GetTracks():
    if t.GetClass() == "PCB_VIA": rects.append(rect(t.GetBoundingBox(), CLR))
for d in b.GetDrawings():
    if isinstance(d, pcbnew.PCB_TEXT) and d is not title and d.GetLayer() == pcbnew.F_SilkS: rects.append(rect(d.GetBoundingBox(), CLR))

def free(t):
    r = rect(t.GetBoundingBox())
    if r[0] < EL or r[1] < ET or r[2] > ER or r[3] > EB: return False
    if any(rr(r, o) for o in rects): return False
    for x1, y1, x2, y2, w in segs:
        if seg_hits((r[0] - w, r[1] - w, r[2] + w, r[3] + w), x1, y1, x2, y2): return False
    return True

FP = [(g.GetReference(), g.GetPosition()) for g in b.GetFootprints()]
def own_nearest(t, ref):
    if ref is None: return True
    q = t.GetPosition()
    d = sorted((math.hypot(p.x - q.x, p.y - q.y), r) for r, p in FP)
    return d[0][1] == ref
def place(t, cx, cy, maxr, step=0.2 * MM, angles=(0, 90), ref=None):
    best = None
    n = int(maxr / step)
    cands = sorted(((i * step, j * step) for i in range(-n, n + 1) for j in range(-n, n + 1)), key=lambda v: v[0] ** 2 + v[1] ** 2)
    for dx, dy in cands:
        if dx * dx + dy * dy > maxr * maxr: break
        for a in angles:
            t.SetTextAngleDegrees(a); t.SetPosition(pcbnew.VECTOR2I(int(cx + dx), int(cy + dy)))
            if free(t) and own_nearest(t, ref): return True
    return False

for ref in MOVE_REFS:
    f = b.FindFootprintByReference(ref); t = f.Reference()
    t.SetHorizJustify(pcbnew.GR_TEXT_H_ALIGN_CENTER)
    c = f.GetPosition(); old = (t.GetPosition().x, t.GetPosition().y, t.GetTextAngleDegrees())
    ok = place(t, c.x, c.y, 7 * MM, step=0.1 * MM, ref=ref)
    if not ok: t.SetPosition(pcbnew.VECTOR2I(old[0], old[1])); t.SetTextAngleDegrees(old[2])
    rects.append(rect(t.GetBoundingBox(), CLR))
    print(ref, "ok" if ok else "NOT PLACED", round(t.GetTextSize().x / MM, 2), "mm text", round(t.GetPosition().x / MM, 2), round(t.GetPosition().y / MM, 2), t.GetTextAngleDegrees())
if False:
    c = title.GetPosition()
    ok = place(title, c.x, c.y, 30 * MM, step=0.5 * MM, angles=(0, 90))
    print("title", "ok" if ok else "NOT PLACED", round(title.GetPosition().x / MM, 2), round(title.GetPosition().y / MM, 2), title.GetTextAngleDegrees())
pcbnew.SaveBoard(P, b)
