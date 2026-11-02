import pcbnew, re, math, sys
P = r"C:\work\My\AlteraZX\Extended\qm_atrix_ext.kicad_pcb"
SCH = r"C:\work\My\AlteraZX\Extended\qm_atrix_ext.kicad_sch"
K = r"C:\Program Files\KiCad\10.0\share\kicad\footprints\\"
L = r"C:\work\My\AlteraZX\Extended\qm_atrix_ext.pretty"
MM = 1e6; mm = lambda v: int(round(v * MM))
L0, T0, R0, B0 = 50.95, 71.97, 135.05, 155.4
X1 = L0 + (84.1 - 31 * 2.54) / 2; Y1 = 145.4
st = sys.argv[1]
b = pcbnew.LoadBoard(P)
def net(n):
    ni = b.FindNet(n)
    if not ni: ni = pcbnew.NETINFO_ITEM(b, n); b.Add(ni)
    return ni
def crt(g):
    c = g.GetCourtyard(pcbnew.F_CrtYd); return c.BBox() if c.OutlineCount() else g.GetBoundingBox(False)
if st == "A":
    edges = [d for d in b.GetDrawings() if d.GetLayer() == pcbnew.Edge_Cuts]
    zones = list(b.Zones())
    kill = [t for t in b.GetTracks() if not (t.GetClass() == "PCB_VIA" and t.GetNetname() == "GND")]
    keep = [t for t in b.GetTracks() if t.GetClass() == "PCB_VIA" and t.GetNetname() == "GND"]
    pts = [(L0, T0), (R0, T0), (R0, B0), (L0, B0)]
    for z in zones:
        ol = z.Outline(); ol.RemoveAllContours(); ol.NewOutline()
        for x, y in pts: ol.Append(mm(x), mm(y))
    for v in keep: v.SetLocked(False)
    for d in edges: b.Remove(d)
    for t in kill: b.Remove(t)
    for i in range(4):
        s = pcbnew.PCB_SHAPE(b); s.SetShape(pcbnew.SHAPE_T_SEGMENT); s.SetLayer(pcbnew.Edge_Cuts); s.SetWidth(mm(0.1))
        s.SetStart(pcbnew.VECTOR2I(mm(pts[i][0]), mm(pts[i][1]))); s.SetEnd(pcbnew.VECTOR2I(mm(pts[(i + 1) % 4][0]), mm(pts[(i + 1) % 4][1]))); b.Add(s)
    print("A: removed", len(kill), "track items, kept", len(keep), "GND vias")
elif st == "B":
    old = b.FindFootprintByReference("J1")
    padnet = {p.GetNumber(): p.GetNetname() for p in old.Pads()}
    path, val = old.GetPath(), old.GetValue()
    texts = [d for d in b.GetDrawings() if isinstance(d, pcbnew.PCB_TEXT)]
    moves = {r: b.FindFootprintByReference(r) for r in ("H3", "H4", "H5", "J5")}
    moves["H3"].SetPosition(pcbnew.VECTOR2I(mm(54.45), mm(151.4)))
    moves["H4"].SetPosition(pcbnew.VECTOR2I(mm(131.55), mm(151.4)))
    moves["H5"].SetPosition(pcbnew.VECTOR2I(mm(131.55), mm(88.8)))
    moves["J5"].Move(pcbnew.VECTOR2I(mm(17.45), 0))
    for d in texts:
        if d.GetText().startswith("HOST"): d.SetPosition(pcbnew.VECTOR2I(mm(X1 + 12), mm(140.6)))
    f = pcbnew.FootprintLoad(K + "Connector_PinHeader_2.54mm.pretty", "PinHeader_2x32_P2.54mm_Vertical")
    f.SetFPID(pcbnew.LIB_ID("Connector_PinHeader_2.54mm", "PinHeader_2x32_P2.54mm_Vertical"))
    f.SetReference("J1"); f.SetValue(val); f.SetPath(path); f.SetSheetname("/"); f.SetSheetfile("qm_atrix_ext.kicad_sch")
    b.Remove(old); b.Add(f)
    f.SetPosition(pcbnew.VECTOR2I(mm(X1), mm(Y1))); f.SetOrientationDegrees(90)
    NEW = {"41": "/BT_BCLK", "42": "/BT_LRCK", "43": "/BT_DATA", "44": "/BT_TX", "45": "/BT_RX", "46": "GND", "63": "GND", "64": "GND"}
    for p in f.Pads(): p.SetNet(net(padnet.get(p.GetNumber()) or NEW.get(p.GetNumber()) or f"unconnected-(J1-Pad{p.GetNumber()})"))
    rf = f.Reference(); rf.SetTextSize(pcbnew.VECTOR2I(mm(0.8), mm(0.8))); rf.SetTextThickness(mm(0.12))
    rf.SetTextAngleDegrees(90); rf.SetPosition(pcbnew.VECTOR2I(mm(X1 - 2.6), mm(Y1 - 1.27)))
    f.Value().SetVisible(False)
    print("B: J1 2x32 at", round(X1, 2), Y1, "crtyd", [round(v / MM, 2) for v in (crt(f).GetLeft(), crt(f).GetTop(), crt(f).GetRight(), crt(f).GetBottom())])
elif st == "C":
    sch = open(SCH, encoding="utf8").read()
    i = sch.index('(property "Reference" "U2"'); j = sch.rindex("\n\t(symbol\n", 0, i)
    uid = re.search(r'\(uuid "([^"]+)"\)', sch[j:i]).group(1)
    MOVABLE = set(sys.argv[2].split(",")) if len(sys.argv) > 2 else set()
    others = [g for g in b.GetFootprints() if g.GetReference() not in MOVABLE]
    padboxes = [p.GetBoundingBox() for g in others for p in g.Pads()]
    TALL = {"J1", "J2", "J4", "J6", "J5", "U1", "RV1", "RV2", "J3", "H1", "H3", "H4", "H5"} - MOVABLE
    tallboxes = [crt(g) for g in others if g.GetReference() in TALL]
    u = pcbnew.FootprintLoad(L, "ESP32_DevKit_30pin_Socket")
    u.SetFPID(pcbnew.LIB_ID("qm_atrix_ext", "ESP32_DevKit_30pin_Socket"))
    u.SetReference("U2"); u.SetValue("ESP32 DevKit 30-pin"); u.SetPath(pcbnew.KIID_PATH("/" + uid))
    u.SetSheetname("/"); u.SetSheetfile("qm_atrix_ext.kicad_sch")
    rf = u.Reference(); rf.SetTextSize(pcbnew.VECTOR2I(mm(0.8), mm(0.8))); rf.SetTextThickness(mm(0.12))
    b.Add(u)
    ESPNET = {"8": "/BT_LRCK", "9": "/BT_BCLK", "14": "GND", "15": "+5V", "17": "/BT_DATA", "24": "/BT_RX", "25": "/BT_TX", "29": "GND"}
    for p in u.Pads(): p.SetNet(net(ESPNET.get(p.GetNumber()) or f"unconnected-(U2-Pad{p.GetNumber()})"))
    def modbox():
        mb = None
        for it in u.GraphicalItems():
            if it.GetLayer() == pcbnew.F_Fab and isinstance(it, pcbnew.PCB_SHAPE):
                bb = it.GetBoundingBox()
                if mb is None: mb = pcbnew.BOX2I(bb.GetPosition(), bb.GetSize())
                else: mb.Merge(bb)
        return mb
    def ok():
        for p in u.Pads():
            pb = p.GetBoundingBox(); pb.Inflate(mm(0.4))
            if any(pb.Intersects(o) for o in padboxes): return False
        mb = modbox()
        if mb.GetLeft() < mm(L0 + 0.5) or mb.GetRight() > mm(R0 + 20) or mb.GetTop() < mm(T0 + 0.5) or mb.GetBottom() > mm(B0 - 0.5): return False
        for p in u.Pads():
            if p.GetBoundingBox().GetRight() > mm(R0 - 1.5): return False
        return not any(mb.Intersects(t) for t in tallboxes)
    cx, cy = (L0 + R0) / 2, (T0 + B0) / 2; best = None
    for rot in (0, 90, 180, 270):
        u.SetOrientationDegrees(rot)
        for gi in range(-50, 51):
            for gj in range(-50, 51):
                u.SetPosition(pcbnew.VECTOR2I(0, 0)); c = modbox().GetCenter()
                u.SetPosition(pcbnew.VECTOR2I(mm(cx + gi * 0.635) - c.x, mm(cy + gj * 0.635) - c.y))
                if ok():
                    d = math.hypot(gi, gj)
                    if best is None or d < best[0]: best = (d, rot, u.GetPosition().x, u.GetPosition().y)
    print("C: best", best and (round(best[0] * 0.635, 2), "mm off centre, rot", best[1]))
    if not best: sys.exit(0)
    if best:
        u.SetOrientationDegrees(best[1]); u.SetPosition(pcbnew.VECTOR2I(best[2], best[3]))
        mb = modbox(); print("   module outline", [round(v / MM, 2) for v in (mb.GetLeft(), mb.GetTop(), mb.GetRight(), mb.GetBottom())])
elif st == "E":   # keyboard module to the lower right, USB end still past the right edge
    j5 = b.FindFootprintByReference("J5")
    c = crt(j5); dy = mm(140.6) - c.GetBottom()
    j5.Move(pcbnew.VECTOR2I(0, dy)); c = crt(j5)
    print("E: J5 crtyd", [round(v / MM, 2) for v in (c.GetLeft(), c.GetTop(), c.GetRight(), c.GetBottom())])
elif st == "F":   # put RV1, RV2, J3 on free spots outside everything (incl. the ESP32 module outline)
    fps = list(b.GetFootprints())
    mov = [g for g in fps if g.GetReference() in ("RV2", "RV1", "J3", "C8", "C9", "C10", "H5")]
    u = [g for g in fps if g.GetReference() == "U2"][0]
    mb = None
    for it in u.GraphicalItems():
        if it.GetLayer() == pcbnew.F_Fab and isinstance(it, pcbnew.PCB_SHAPE):
            bb = it.GetBoundingBox()
            if mb is None: mb = pcbnew.BOX2I(bb.GetPosition(), bb.GetSize())
            else: mb.Merge(bb)
    obst = [crt(g) for g in fps if g not in mov] + [p.GetBoundingBox() for g in fps if g not in mov for p in g.Pads()] + [mb]
    for g in mov:
        home = g.GetPosition(); best = None
        for rot in (90, 0):
            g.SetOrientationDegrees(rot)
            for i in range(-120, 121):
                for j in range(-120, 121):
                    g.SetPosition(pcbnew.VECTOR2I(home.x + mm(i * 0.5), home.y + mm(j * 0.5)))
                    c = crt(g); c.Inflate(mm(0.3))
                    if c.GetLeft() < mm(L0 + 0.5) or c.GetRight() > mm(R0 - 0.5) or c.GetTop() < mm(T0 + 0.5) or c.GetBottom() > mm(B0 - 0.5): continue
                    if any(c.Intersects(o) for o in obst): continue
                    d = i * i + j * j
                    if best is None or d < best[0]: best = (d, rot, g.GetPosition().x, g.GetPosition().y)
        g.SetOrientationDegrees(best[1]); g.SetPosition(pcbnew.VECTOR2I(best[2], best[3])); obst.append(crt(g))
        print("F:", g.GetReference(), "moved to", round(best[2] / MM, 2), round(best[3] / MM, 2), "rot", best[1])
elif st == "G":   # exact schematic net names on J1/U2; nudge R13/R14 clear of the ESP32 row courtyard
    import json
    pn = json.load(open(r"C:\Users\Public\fr\pinnets.json"))
    fps = {g.GetReference(): g for g in b.GetFootprints()}
    for ref in ("J1", "U2"):
        for p in fps[ref].Pads():
            n = pn.get(f"{ref}.{p.GetNumber()}")
            if n and p.GetNetname() != n: p.SetNet(net(n))
    u = crt(fps["U2"])
    ucy = fps["U2"].GetCourtyard(pcbnew.F_CrtYd)
    for r in ("R13", "R14"):
        g = fps[r]; tries = 0
        while ucy.Collide(g.GetCourtyard(pcbnew.F_CrtYd)) and tries < 40:
            g.Move(pcbnew.VECTOR2I(mm(-0.1), 0)); tries += 1
        print("G:", r, "now at x", round(g.GetPosition().x / MM, 2))
elif st == "D":
    fps = list(b.GetFootprints())
    special = [crt(g) for g in fps if g.GetReference() in ("J1", "U2")]
    pads = [(p.GetBoundingBox(), p.GetNetname(), g.GetReference()) for g in fps for p in g.Pads()]
    vias = [t for t in b.GetTracks() if t.GetClass() == "PCB_VIA"]
    zones = list(b.Zones())
    bad = []
    for v in vias:
        vb = v.GetBoundingBox(); vb.Inflate(mm(0.25))
        if any(vb.Intersects(pb) for pb, n, r in pads if n != "GND" or r in ("J1", "U2")) or any(vb.Intersects(s) for s in special): bad.append(v)
    for v in bad: b.Remove(v)
    pcbnew.ZONE_FILLER(b).Fill(zones)
    print("D: removed", len(bad), "colliding GND vias, kept", len(vias) - len(bad))
pcbnew.SaveBoard(P, b)
