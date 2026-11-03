# silk.py -- KiCad python: silkscreen tidy for the I/O board revision 2.
#   1. every footprint reference on F.Silkscreen: 0.8 mm text, 0.13 mm stroke, horizontal
#   2. each reference moved to the nearest free spot around its part: no overlap with pads (+0.15 mm), holes, other
#      references, the large connectors / modules (courtyard + 0.8 mm),
#      references, footprint silkscreen lines, and 0.4 mm inside the board edge; parts with the least room first
#   3. footprint silkscreen lines clipped 0.2 mm inside the board edge (connector outlines that overhang the edge);
#      lines entirely outside the board go to F.Fab
import pcbnew, math
P = r"C:\work\My\AlteraZX\Extra_PCB_CycloneIV_R2\Extra_PCB_CycloneIV_R2.kicad_pcb"; PRO = P.replace(".kicad_pcb", ".kicad_pro")
b = pcbnew.LoadBoard(P); MM = pcbnew.FromMM; T = pcbnew.ToMM
e = b.GetBoardEdgesBoundingBox()
EL, ET, ER, EB = T(e.GetLeft()) + 0.05, T(e.GetTop()) + 0.05, T(e.GetRight()) - 0.05, T(e.GetBottom()) - 0.05
H, W1 = 0.8, 0.13          # text height, stroke
CW = 0.82 * H              # character advance incl. spacing (KiCad stroke font, measured against DRC)

# ---- 3. clip footprint silkscreen segments to the board ----
def clip(x1, y1, x2, y2, L, T_, R, B):   # Liang-Barsky
    dx, dy = x2 - x1, y2 - y1; t0, t1 = 0.0, 1.0
    for p, q in ((-dx, x1 - L), (dx, R - x1), (-dy, y1 - T_), (dy, B - y1)):
        if p == 0:
            if q < 0: return None
        else:
            r = q / p
            if p < 0: t0 = max(t0, r)
            else: t1 = min(t1, r)
    if t0 > t1: return None
    return x1 + t0 * dx, y1 + t0 * dy, x1 + t1 * dx, y1 + t1 * dy
def gitems(fp):   # KiCad 10: look the footprint up by reference, then the DRAWINGS proxy: indexed access + Cast()
    d = fp.GraphicalItems()
    return [d[i].Cast() for i in range(d.size())]
M = 0.2
clipped = removed = 0
for fp in b.GetFootprints():
    for g in gitems(fp):
        if g.GetLayer() != pcbnew.F_SilkS or g.GetClass() != "PCB_SHAPE" or g.GetShape() != pcbnew.SHAPE_T_SEGMENT: continue
        s, en = g.GetStart(), g.GetEnd()
        c = clip(T(s.x), T(s.y), T(en.x), T(en.y), EL + M, ET + M, ER - M, EB - M)
        if c is None:
            g.SetLayer(pcbnew.F_Fab); removed += 1   # entirely off the board: to F.Fab (no Remove: it leaves stale SWIG objects)
        elif (abs(c[0] - T(s.x)) + abs(c[1] - T(s.y)) + abs(c[2] - T(en.x)) + abs(c[3] - T(en.y))) > 1e-4:
            g.SetStart(pcbnew.VECTOR2I(MM(c[0]), MM(c[1]))); g.SetEnd(pcbnew.VECTOR2I(MM(c[2]), MM(c[3]))); clipped += 1

# ---- obstacles ----
rects = []    # (x0, y0, x1, y1) keep-out rectangles in mm
for fp in b.GetFootprints():
    for p in fp.Pads():
        if not (p.IsOnLayer(pcbnew.F_Cu) or p.IsOnLayer(pcbnew.F_Mask)) and p.GetAttribute() != pcbnew.PAD_ATTRIB_NPTH: continue
        bb = p.GetBoundingBox(); g = 0.15
        rects.append((T(bb.GetLeft()) - g, T(bb.GetTop()) - g, T(bb.GetRight()) + g, T(bb.GetBottom()) + g))
segs = []     # footprint silk segments (x1, y1, x2, y2, half width)
for fp in b.GetFootprints():
    for g in gitems(fp):
        if g.GetLayer() != pcbnew.F_SilkS or g.GetClass() != "PCB_SHAPE": continue
        if g.GetShape() == pcbnew.SHAPE_T_SEGMENT:
            segs.append((T(g.GetStart().x), T(g.GetStart().y), T(g.GetEnd().x), T(g.GetEnd().y), T(g.GetWidth()) / 2))
        else:   # rect / circle / arc / poly: their bounding box outline
            bb = g.GetBoundingBox(); x0, y0, x1, y1 = T(bb.GetLeft()), T(bb.GetTop()), T(bb.GetRight()), T(bb.GetBottom())
            for a in ((x0, y0, x1, y0), (x1, y0, x1, y1), (x1, y1, x0, y1), (x0, y1, x0, y0)):
                segs.append(a + (T(g.GetWidth()) / 2,))
for v in b.Tracks():   # via holes / rings need no silk on them either
    if v.GetClass() == "PCB_VIA":
        x, y, r = T(v.GetPosition().x), T(v.GetPosition().y), T(v.GetWidth(pcbnew.F_Cu)) / 2 + 0.1
        rects.append((x - r, y - r, x + r, y + r))

# large parts (connectors, modules): their bodies are larger than the courtyard (VGA housing): references stay
# 0.8 mm clear of their courtyards, their own reference included
BIG = ("J2", "J3", "J4", "J5", "J6", "J7", "J8", "J9", "U2")
for fp in b.GetFootprints():
    if fp.GetReference() in BIG:
        bb = fp.GetCourtyard(pcbnew.F_CrtYd).BBox(); g = 0.8
        rects.append((T(bb.GetLeft()) - g, T(bb.GetTop()) - g, T(bb.GetRight()) + g, T(bb.GetBottom()) + g))

def rect_hits_seg(r, s):
    x0, y0, x1, y1 = r; ax, ay, bx, by, hw = s
    x0 -= hw + 0.1; y0 -= hw + 0.1; x1 += hw + 0.1; y1 += hw + 0.1
    return clip(ax, ay, bx, by, x0, y0, x1, y1) is not None
def overl(a, c): return a[0] < c[2] and c[0] < a[2] and a[1] < c[3] and c[1] < a[3]
placed = []
def free(r):
    if r[0] < EL + 0.4 or r[1] < ET + 0.4 or r[2] > ER - 0.4 or r[3] > EB - 0.4: return False
    if any(overl(r, o) for o in rects): return False
    if any(overl(r, o) for o in placed): return False
    if any(rect_hits_seg(r, s) for s in segs): return False
    return True

# ---- 1 + 2. references ----
fps = []
for fp in b.GetFootprints():
    ref = fp.Reference()
    if not ref.IsVisible() or ref.GetLayer() != pcbnew.F_SilkS: continue
    cy = fp.GetCourtyard(pcbnew.F_CrtYd)
    bb = cy.BBox() if cy.OutlineCount() else fp.GetBoundingBox(False, False)
    fps.append((fp, (T(bb.GetLeft()), T(bb.GetTop()), T(bb.GetRight()), T(bb.GetBottom()))))
fps.sort(key=lambda f: (f[1][2] - f[1][0]) * (f[1][3] - f[1][1]))
fail = []
FIXED = {"J2": (69.2, 108.5, 0)}   # J2's nearest free spot is inside the DAC block: pinned right of the VGA body
for fp, _ in fps:
    if fp.GetReference() in FIXED:
        x, y, ang = FIXED[fp.GetReference()]; txt = fp.Reference()
        txt.SetTextSize(pcbnew.VECTOR2I(MM(H), MM(H))); txt.SetTextThickness(MM(W1)); txt.SetKeepUpright(True)
        txt.SetTextAngleDegrees(ang); txt.SetHorizJustify(pcbnew.GR_TEXT_H_ALIGN_CENTER); txt.SetVertJustify(pcbnew.GR_TEXT_V_ALIGN_CENTER)
        txt.SetPosition(pcbnew.VECTOR2I(MM(x), MM(y)))
        w = CW * len(txt.GetText()) + 0.15; h = H + 0.2
        placed.append((x - w / 2, y - h / 2, x + w / 2, y + h / 2))
fps = [f for f in fps if f[0].GetReference() not in FIXED]
for fp, (l, t, r, bt) in fps:
    txt = fp.Reference()
    txt.SetTextSize(pcbnew.VECTOR2I(MM(H), MM(H))); txt.SetTextThickness(MM(W1))
    txt.SetKeepUpright(True)
    wt = CW * len(txt.GetText()) + 0.15; ht = H + 0.2
    cx, cyc = (l + r) / 2, (t + bt) / 2
    best = None
    for ang in (0, 90):   # horizontal first, vertical text where a row is too tight
        w, h = (wt, ht) if ang == 0 else (ht, wt)
        cands = []
        for gap in (0.05, 0.3, 0.6, 1.0, 1.5, 2.2, 3.0, 4.0, 5.0):
            for sx in [0, -0.5, 0.5, -1.0, 1.0, -1.5, 1.5, -2.5, 2.5]:
                cands += [(cx + sx, t - gap - h / 2), (cx + sx, bt + gap + h / 2)]
            for sy in [0, -0.5, 0.5, -1.0, 1.0, -1.75, 1.75, -2.5, 2.5]:
                cands += [(l - gap - w / 2, cyc + sy), (r + gap + w / 2, cyc + sy)]
        cands.sort(key=lambda c: math.hypot(c[0] - cx, c[1] - cyc))
        for x, y in cands:
            rr = (x - w / 2, y - h / 2, x + w / 2, y + h / 2)
            if free(rr):
                best = (x, y, rr, ang); break
        if best: break
    if best is None:
        fail.append(txt.GetText()); continue
    txt.SetTextAngleDegrees(best[3])
    txt.SetHorizJustify(pcbnew.GR_TEXT_H_ALIGN_CENTER); txt.SetVertJustify(pcbnew.GR_TEXT_V_ALIGN_CENTER)
    txt.SetPosition(pcbnew.VECTOR2I(MM(best[0]), MM(best[1])))
    placed.append(best[2])
keep = open(PRO, "rb").read(); pcbnew.SaveBoard(P, b); open(PRO, "wb").write(keep)
print("silk lines clipped", clipped, "moved to F.Fab", removed, "| references placed", len(fps) - len(fail), "no room:", fail)
