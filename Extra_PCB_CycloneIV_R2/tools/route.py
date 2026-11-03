# route.py -- KiCad python. Routing steps for the I/O board revision 2 (FreeRouting 2.5.0 in between):
#   route.py prep    : GND vias in the ESP32's pad 39, export C:\Users\Public\fr\r2.dsn
#   route.py import  : import C:\Users\Public\fr\r2.ses (FreeRouting result) into the board
#   route.py free x0 y0 x1 y1 NET... : lock all tracks, delete the tracks of NET... inside the box, export the DSN
#                                      (FreeRouting then routes only what is missing)
#   route.py unlock  : unlock all tracks except the pad 39 vias
#   route.py pour    : GND fill on F.Cu + B.Cu, stitching vias on a grid where both layers are GND, refill
# The .kicad_pro is restored after every save (pcbnew.SaveBoard rewrites it with defaults).
import sys, os, shutil, pcbnew
PRJ = r"C:\work\My\AlteraZX\Extra_PCB_CycloneIV_R2"
PCB = os.path.join(PRJ, "Extra_PCB_CycloneIV_R2.kicad_pcb")
PRO = os.path.join(PRJ, "Extra_PCB_CycloneIV_R2.kicad_pro")
FR = r"C:\Users\Public\fr"
MM = pcbnew.FromMM

def save(b):
    keep = open(PRO, "rb").read()
    pcbnew.SaveBoard(PCB, b)
    open(PRO, "wb").write(keep)

def via(b, x, y, net, d=0.6, drill=0.3):
    v = pcbnew.PCB_VIA(b)
    v.SetPosition(pcbnew.VECTOR2I(MM(x), MM(y)))
    v.SetWidth(MM(d)); v.SetDrill(MM(drill)); v.SetNet(net)
    v.SetViaType(pcbnew.VIATYPE_THROUGH)
    b.Add(v)
    return v

b = pcbnew.LoadBoard(PCB)
gnd = b.FindNet("GND")
step = sys.argv[1]
if step == "prep":
    p39 = [p for p in b.FindFootprintByReference("U2").Pads() if p.GetNumber() == "39"][0]
    cx, cy = pcbnew.ToMM(p39.GetPosition().x), pcbnew.ToMM(p39.GetPosition().y)
    have = [t for t in b.GetTracks() if t.GetClass() == "PCB_VIA" and t.GetNetname() == "GND"
            and abs(pcbnew.ToMM(t.GetPosition().x) - cx) < 1.5 and abs(pcbnew.ToMM(t.GetPosition().y) - cy) < 1.5]
    for dx in (() if have else (-0.9, 0.9)):
        for dy in (-0.9, 0.9):
            v = via(b, cx + dx, cy + dy, gnd)
            v.SetLocked(True)
    save(b)
    b = pcbnew.LoadBoard(PCB)
    os.makedirs(FR, exist_ok=True)
    print("DSN", pcbnew.ExportSpecctraDSN(b, os.path.join(FR, "r2.dsn")))
elif step == "free":
    x0, y0, x1, y1 = map(float, sys.argv[2:6]); nets = set(sys.argv[6:])
    inbox = lambda p: x0 <= pcbnew.ToMM(p.x) <= x1 and y0 <= pcbnew.ToMM(p.y) <= y1
    dead = []
    for t in b.GetTracks():
        if t.GetNetname() in nets and (inbox(t.GetStart()) or inbox(t.GetEnd()) or inbox(t.GetPosition())):
            dead.append(t)
        else:
            t.SetLocked(True)
    for t in dead:
        b.Remove(t)
    print("removed", len(dead))
    save(b)
    b = pcbnew.LoadBoard(PCB)
    print("DSN", pcbnew.ExportSpecctraDSN(b, os.path.join(FR, "r2.dsn")))
elif step == "unlock":
    n = 0
    for t in b.GetTracks():
        if t.IsLocked() and not (t.GetClass() == "PCB_VIA" and t.GetNetname() == "GND" and abs(pcbnew.ToMM(t.GetPosition().y) - 98.54) < 1.5 and abs(pcbnew.ToMM(t.GetPosition().x) - 119.8) < 1.5):
            t.SetLocked(False); n += 1
    save(b); print("unlocked", n)
elif step == "import":
    print("SES", pcbnew.ImportSpecctraSES(b, os.path.join(FR, "r2.ses")))
    save(b)
    print("tracks", len(b.GetTracks()))
if step == "move":   # route.py move REF x y rot : move a footprint and delete the tracks touching its pads
    ref, x, y, rot = sys.argv[2], float(sys.argv[3]), float(sys.argv[4]), float(sys.argv[5])
    fp = b.FindFootprintByReference(ref)
    pads = [(p.GetPosition(), p.GetNetname()) for p in fp.Pads()]
    dead = []
    for t in b.GetTracks():
        for pos, net in pads:
            if t.GetNetname() == net and t.GetClass() != "PCB_VIA" and (t.GetStart() == pos or t.GetEnd() == pos):
                dead.append(t); break
    for t in dead:
        b.Remove(t)
    fp.SetPosition(pcbnew.VECTOR2I(MM(x), MM(y))); fp.SetOrientationDegrees(rot)
    save(b); print("moved", ref, "removed", len(dead))
if step == "clean":   # delete dangling track ends (one pass per load, until none), widen tracks below 0.15 mm
    total = 0
    while True:
        b.BuildConnectivity()
        conn = b.GetConnectivity()
        dead = [t for t in list(b.Tracks()) if t.GetClass() == "PCB_TRACK" and conn.TestTrackEndpointDangling(t, False)]
        if not dead:
            break
        for t in dead:
            b.Remove(t)
        total += len(dead)
        save(b)
        b = pcbnew.LoadBoard(PCB)
    narrow = 0
    for t in list(b.Tracks()):
        if t.GetClass() == "PCB_TRACK" and t.GetWidth() < MM(0.15):
            t.SetWidth(MM(0.15)); narrow += 1
    save(b); print("removed", total, "widened", narrow)
if step == "pour":   # GND fill on both layers + stitching vias every STEP mm where both layers are GND fill
    STEP = float(sys.argv[2]) if len(sys.argv) > 2 else 4.0
    e = b.GetBoardEdgesBoundingBox(); w = MM(0.05)
    L, T, R, B = e.GetLeft() + w, e.GetTop() + w, e.GetRight() - w, e.GetBottom() - w
    for z in [z for z in b.Zones() if not z.GetIsRuleArea()]:
        b.Remove(z)
    zones = []
    for layer in (pcbnew.F_Cu, pcbnew.B_Cu):
        z = pcbnew.ZONE(b); z.SetLayer(layer); z.SetNet(gnd); z.SetZoneName("GND " + b.GetLayerName(layer))
        ol = z.Outline(); ol.NewOutline()
        for x, y in ((L, T), (R, T), (R, B), (L, B)): ol.Append(x, y)
        z.SetLocalClearance(MM(0.25)); z.SetMinThickness(MM(0.25))
        z.SetPadConnection(pcbnew.ZONE_CONNECTION_THERMAL)
        z.SetThermalReliefGap(MM(0.4)); z.SetThermalReliefSpokeWidth(MM(0.4))
        z.SetIslandRemovalMode(pcbnew.ISLAND_REMOVAL_MODE_ALWAYS)
        b.Add(z); zones.append(z)
    pcbnew.ZONE_FILLER(b).Fill(zones)
    # stitching vias: the via plus 0.35 mm around it inside both fills
    import math
    fF, fB = zones[0].GetFilledPolysList(pcbnew.F_Cu), zones[1].GetFilledPolysList(pcbnew.B_Cu)
    rules = [z for z in b.Zones() if z.GetIsRuleArea() and z.GetDoNotAllowVias()]
    def inside(fill, x, y, r):
        pts = [(x, y)] + [(x + r * math.cos(a * math.pi / 4), y + r * math.sin(a * math.pi / 4)) for a in range(8)]
        return all(fill.Contains(pcbnew.VECTOR2I(MM(px), MM(py))) for px, py in pts)
    def blocked(x, y):
        p = pcbnew.VECTOR2I(MM(x), MM(y))
        for z in rules:
            for l in (pcbnew.F_Cu, pcbnew.B_Cu):
                if z.IsOnLayer(l) and z.Outline().Contains(p):
                    return True
        return False
    n = 0
    x0, y0 = pcbnew.ToMM(L) + 2, pcbnew.ToMM(T) + 2
    yy = y0
    while yy < pcbnew.ToMM(B) - 1.5:
        xx = x0
        while xx < pcbnew.ToMM(R) - 1.5:
            if inside(fF, xx, yy, 0.65) and inside(fB, xx, yy, 0.65) and not blocked(xx, yy):
                via(b, xx, yy, gnd); n += 1
            xx += STEP
        yy += STEP
    pcbnew.ZONE_FILLER(b).Fill(zones)
    save(b)
    for z in zones:
        l = z.GetLayer(); fp = z.GetFilledPolysList(l)
        print(b.GetLayerName(l), "pieces", fp.OutlineCount(), "area mm2", round(fp.Area() / 1e12, 1))
    print("stitching vias", n)
if step == "gndfix":   # route.py gndfix [REF.PAD ...]: a GND via in every F.Cu fill island without one, and a via +
                       # short track next to each listed GND pad; every via / track checked against other nets
    import math
    zones = [z for z in b.Zones() if not z.GetIsRuleArea()]
    zF = [z for z in zones if z.GetLayer() == pcbnew.F_Cu][0]; zB = [z for z in zones if z.GetLayer() == pcbnew.B_Cu][0]
    fF, fB = zF.GetFilledPolysList(pcbnew.F_Cu), zB.GetFilledPolysList(pcbnew.B_Cu)
    rules = [z for z in b.Zones() if z.GetIsRuleArea() and z.GetDoNotAllowVias()]
    others = [t for t in b.Tracks() if t.GetNetname() != "GND"] + \
             [p for fp in b.GetFootprints() for p in fp.Pads() if p.GetNetname() != "GND" and p.GetNumber() != ""]
    V = lambda x, y: pcbnew.VECTOR2I(MM(x), MM(y))
    def ring(x, y, r): return [(x, y)] + [(x + r * math.cos(a * math.pi / 4), y + r * math.sin(a * math.pi / 4)) for a in range(8)]
    def free_at(x, y, r):   # nothing of another net within r (both layers), not in a no-via rule area
        p = V(x, y)
        if any(z.Outline().Contains(p) for z in rules): return False
        return not any(o.HitTest(p, MM(r)) for o in others)
    def via_ok(x, y): return free_at(x, y, 0.3 + 0.2) and all(fB.Contains(V(px, py)) for px, py in ring(x, y, 0.45))
    added = 0; extra = []
    u2c = b.FindFootprintByReference("U2").GetPosition()
    # 1) islands
    gvias = [t for t in b.Tracks() if t.GetClass() == "PCB_VIA" and t.GetNetname() == "GND"]
    gth = [p for fp in b.GetFootprints() for p in fp.Pads() if p.GetNetname() == "GND" and p.GetAttribute() == pcbnew.PAD_ATTRIB_PTH]
    for i in range(fF.OutlineCount()):
        piece = pcbnew.SHAPE_POLY_SET(fF.Outline(i))
        if any(piece.Contains(v.GetPosition()) for v in gvias) or any(piece.Contains(p.GetPosition()) for p in gth):
            continue
        bb = piece.BBox(); done = False
        y = pcbnew.ToMM(bb.GetTop()) + 0.5
        while y < pcbnew.ToMM(bb.GetBottom()) and not done:
            x = pcbnew.ToMM(bb.GetLeft()) + 0.5
            while x < pcbnew.ToMM(bb.GetRight()) and not done:
                if all(piece.Contains(V(px, py)) for px, py in ring(x, y, 0.45)) and via_ok(x, y):
                    via(b, x, y, gnd); added += 1; done = True
                x += 0.2
            y += 0.2
        if not done:   # no room for a via inside: connect one of its GND pads with a track + via outside
            pads_in = [f"{fp.GetReference()}.{p.GetNumber()}" for fp in b.GetFootprints() for p in fp.Pads()
                       if p.GetNetname() == "GND" and piece.Contains(p.GetPosition())]
            print("island", round(pcbnew.ToMM(bb.GetCenter().x), 2), round(pcbnew.ToMM(bb.GetCenter().y), 2), "pads", pads_in)
            if pads_in: extra.append(pads_in[0])
    # 2) pads: via within 3.5 mm, straight track pad -> via clear of other nets (ESP32 pads: only away from the module)
    for xy in [a[1:] for a in sys.argv[2:] if a.startswith("@")]:   # @x,y : a GND via there if it is free
        x, y = map(float, xy.split(","))
        if free_at(x, y, 0.3 + 0.2):
            via(b, x, y, gnd); added += 1; print("via", x, y)
        else:
            hits = [o for o in others if o.HitTest(V(x, y), MM(0.5))]
            print("not free", x, y, [(o.GetClass(), o.GetNetname(), b.GetLayerName(o.GetLayer())) for o in hits][:4])
    for rp in extra + [a for a in sys.argv[2:] if not a.startswith("@")]:
        ref, num = rp.split(".")
        pad = [p for p in b.FindFootprintByReference(ref).Pads() if p.GetNumber() == num][0]
        px, py = pcbnew.ToMM(pad.GetPosition().x), pcbnew.ToMM(pad.GetPosition().y)
        best = None
        for d in [0.9 + 0.1 * k for k in range(27)]:
            for a in range(0, 360, 15):
                x, y = px + d * math.cos(math.radians(a)), py + d * math.sin(math.radians(a))
                if ref == "U2" and (y - py) * (py - pcbnew.ToMM(u2c.y)) < 0.5 * d: continue
                if not via_ok(x, y): continue
                n = 12
                if all(free_at(px + (x - px) * k / n, py + (y - py) * k / n, 0.1 + 0.2) for k in range(n + 1)):
                    best = (x, y); break
            if best: break
        if not best:   # fallback: a straight F.Cu track to an existing GND via within 5 mm
            vs = sorted((math.hypot(pcbnew.ToMM(v.GetPosition().x) - px, pcbnew.ToMM(v.GetPosition().y) - py), v)
                        for v in b.Tracks() if v.GetClass() == "PCB_VIA" and v.GetNetname() == "GND")
            for dist, v in vs:
                if dist > 5: break
                vx, vy = pcbnew.ToMM(v.GetPosition().x), pcbnew.ToMM(v.GetPosition().y)
                n = int(dist / 0.1) + 2
                if all(free_at(px + (vx - px) * k / n, py + (vy - py) * k / n, 0.1 + 0.2) for k in range(n + 1)):
                    t = pcbnew.PCB_TRACK(b); t.SetStart(pad.GetPosition()); t.SetEnd(v.GetPosition()); t.SetWidth(MM(0.2))
                    t.SetLayer(pcbnew.F_Cu); t.SetNet(gnd); b.Add(t); added += 1
                    print(rp, "track to via at", round(vx, 2), round(vy, 2)); break
            else:
                print("no room at", rp)
            continue
        via(b, *best, gnd)
        t = pcbnew.PCB_TRACK(b); t.SetStart(pad.GetPosition()); t.SetEnd(V(*best)); t.SetWidth(MM(0.25))
        t.SetLayer(pcbnew.F_Cu); t.SetNet(gnd); b.Add(t); added += 1
        print(rp, "via at", round(best[0], 2), round(best[1], 2))
    pcbnew.ZONE_FILLER(b).Fill(zones)
    save(b); print("added", added)
if step == "four":   # 4 layers: In1.Cu = GND plane, In2.Cu = +3V3 plane (both "power" layers, no signal routing);
                     # the antenna keep-out on all copper layers
    b.SetCopperLayerCount(4)
    ls = b.GetEnabledLayers(); ls.AddLayer(pcbnew.In1_Cu); ls.AddLayer(pcbnew.In2_Cu); b.SetEnabledLayers(ls)
    b.SetLayerType(pcbnew.In1_Cu, pcbnew.LT_POWER); b.SetLayerType(pcbnew.In2_Cu, pcbnew.LT_POWER)
    for z in b.Zones():
        if z.GetIsRuleArea() and z.GetZoneName() == "ESP32 antenna clearance":
            l = pcbnew.LSET(); [l.AddLayer(x) for x in (pcbnew.F_Cu, pcbnew.In1_Cu, pcbnew.In2_Cu, pcbnew.B_Cu)]
            z.SetLayerSet(l)
    e = b.GetBoardEdgesBoundingBox(); w = MM(0.05)
    L, T, R, B = e.GetLeft() + w, e.GetTop() + w, e.GetRight() - w, e.GetBottom() - w
    for layer, net in ((pcbnew.In1_Cu, "GND"), (pcbnew.In2_Cu, "+3V3")):
        z = pcbnew.ZONE(b); z.SetLayer(layer); z.SetNet(b.FindNet(net)); z.SetZoneName(net + " plane")
        ol = z.Outline(); ol.NewOutline()
        for x, y in ((L, T), (R, T), (R, B), (L, B)): ol.Append(x, y)
        z.SetLocalClearance(MM(0.25)); z.SetMinThickness(MM(0.25))
        z.SetPadConnection(pcbnew.ZONE_CONNECTION_FULL)   # vias / THT pins of the plane net: solid
        z.SetIslandRemovalMode(pcbnew.ISLAND_REMOVAL_MODE_ALWAYS)
        b.Add(z)
    save(b); print("4 layers, planes added")
if step == "fan":   # a via + short track at every SMD pad of the plane nets (GND, +3V3), pointing away from its part
    import math
    PLANE = ("GND", "+3V3")
    rules = [z for z in b.Zones() if z.GetIsRuleArea() and z.GetDoNotAllowVias()]
    e = b.GetBoardEdgesBoundingBox()
    V = lambda x, y: pcbnew.VECTOR2I(MM(x), MM(y))
    allpads = [p for fp in b.GetFootprints() for p in fp.Pads() if p.GetNumber() != ""]
    vias = [(pcbnew.ToMM(t.GetPosition().x), pcbnew.ToMM(t.GetPosition().y), t.GetNetname()) for t in b.Tracks() if t.GetClass() == "PCB_VIA"]
    segs = []   # (x1, y1, x2, y2, net) tracks added here
    def seg_d(px, py, s):
        x1, y1, x2, y2 = s[:4]; dx, dy = x2 - x1, y2 - y1; L2 = dx * dx + dy * dy
        t = 0 if L2 == 0 else max(0, min(1, ((px - x1) * dx + (py - y1) * dy) / L2))
        return math.hypot(px - x1 - t * dx, py - y1 - t * dy)
    def clear(x, y, r, net):   # point x,y with radius r clear of other nets' pads / vias / new tracks
        p = V(x, y)
        if any(pp.GetNetname() != net and pp.HitTest(p, MM(r + 0.15)) for pp in allpads): return False
        if any(n != net and math.hypot(x - vx, y - vy) < r + 0.3 + 0.15 for vx, vy, n in vias): return False
        if any(s[4] != net and seg_d(x, y, s) < r + 0.1 + 0.15 for s in segs): return False
        return True
    def via_ok(x, y, net):
        p = V(x, y)
        if not (pcbnew.ToMM(e.GetLeft()) + 0.8 < x < pcbnew.ToMM(e.GetRight()) - 0.8 and
                pcbnew.ToMM(e.GetTop()) + 0.8 < y < pcbnew.ToMM(e.GetBottom()) - 0.8): return False
        if any(z.Outline().Contains(p) for z in rules): return False
        if any(math.hypot(x - vx, y - vy) < 0.9 for vx, vy, n in vias): return False   # hole spacing
        # no via under another part's body (courtyard) except its own part's
        return clear(x, y, 0.3, net)
    done = fail = 0
    for fp in b.GetFootprints():
        cx, cy = pcbnew.ToMM(fp.GetPosition().x), pcbnew.ToMM(fp.GetPosition().y)
        crt = fp.GetCourtyard(pcbnew.F_CrtYd)
        for pad in fp.Pads():
            net = pad.GetNetname()
            if net not in PLANE or pad.GetAttribute() != pcbnew.PAD_ATTRIB_SMD or pad.GetNumber() == "": continue
            if fp.GetReference() == "U2" and pad.GetNumber() == "39": continue
            if any(t.GetClass() == "PCB_TRACK" and t.GetNetname() == net and (t.GetStart() == pad.GetPosition() or
                   t.GetEnd() == pad.GetPosition()) for t in b.Tracks()): continue
            px, py = pcbnew.ToMM(pad.GetPosition().x), pcbnew.ToMM(pad.GetPosition().y)
            # a same-net via already close and reachable: connect to it
            near = sorted((math.hypot(px - vx, py - vy), vx, vy) for vx, vy, n in vias if n == net)
            hit = None
            for d, vx, vy in near:
                if d > 1.6: break
                if all(clear(px + (vx - px) * k / 10, py + (vy - py) * k / 10, 0.1, net) for k in range(11)):
                    hit = (vx, vy); break
            if not hit:
                base = math.atan2(py - cy, px - cx) if (px, py) != (cx, cy) else 0.0
                for d in (0.9, 1.1, 1.3, 1.5, 1.8, 2.1, 2.5):
                    for da in (0, 30, -30, 60, -60, 90, -90, 120, -120, 150, -150, 180):
                        a = base + math.radians(da)
                        x, y = px + d * math.cos(a), py + d * math.sin(a)
                        if not via_ok(x, y, net): continue
                        if crt.Contains(V(x, y)) and d < 1.0: pass
                        if all(clear(px + (x - px) * k / 10, py + (y - py) * k / 10, 0.1, net) for k in range(11)):
                            hit = (x, y); break
                    if hit: break
                if hit:
                    v = via(b, hit[0], hit[1], b.FindNet(net)); v.SetLocked(True); vias.append((hit[0], hit[1], net))
            if not hit:
                print("no fan-out for", fp.GetReference(), pad.GetNumber(), net); fail += 1; continue
            t = pcbnew.PCB_TRACK(b); t.SetStart(pad.GetPosition()); t.SetEnd(V(*hit)); t.SetWidth(MM(0.25))
            t.SetLayer(pad.GetLayer() if pad.IsOnLayer(pcbnew.F_Cu) else pcbnew.B_Cu); t.SetNet(b.FindNet(net)); t.SetLocked(True)
            b.Add(t); segs.append((px, py, hit[0], hit[1], net)); done += 1
    save(b); print("fanned out", done, "failed", fail)
    b = pcbnew.LoadBoard(PCB)
    print("DSN", pcbnew.ExportSpecctraDSN(b, os.path.join(FR, "r2.dsn")))
if step == "clearbox":   # route.py clearbox x0 y0 x1 y1 : delete every track / via inside the box (also locked ones)
    x0, y0, x1, y1 = map(float, sys.argv[2:6])
    inb = lambda p: x0 <= pcbnew.ToMM(p.x) <= x1 and y0 <= pcbnew.ToMM(p.y) <= y1
    dead = [t for t in b.Tracks() if (inb(t.GetPosition()) if t.GetClass() == "PCB_VIA" else (inb(t.GetStart()) or inb(t.GetEnd())))]
    for t in dead: b.Remove(t)
    save(b); print("cleared", len(dead))
if step == "rot":   # route.py rot REF x y deg
    fp = b.FindFootprintByReference(sys.argv[2])
    fp.SetPosition(pcbnew.VECTOR2I(MM(float(sys.argv[3])), MM(float(sys.argv[4])))); fp.SetOrientationDegrees(float(sys.argv[5]))
    save(b); print("placed", sys.argv[2])
