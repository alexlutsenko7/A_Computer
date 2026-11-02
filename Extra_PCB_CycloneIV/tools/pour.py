import pcbnew
P = r"C:\work\My\AlteraZX\Extended\qm_atrix_ext.kicad_pcb"
b = pcbnew.LoadBoard(P); MM = 1e6; mm = lambda v: int(round(v * MM))
e = b.GetBoardEdgesBoundingBox(); w = mm(0.05)   # edge line half width
L, T, R, B = e.GetLeft() + w, e.GetTop() + w, e.GetRight() - w, e.GetBottom() - w
gnd = b.FindNet("GND"); zones = []
for layer in (pcbnew.F_Cu, pcbnew.B_Cu):
    z = pcbnew.ZONE(b); z.SetLayer(layer); z.SetNet(gnd)
    ol = z.Outline(); ol.NewOutline()
    for x, y in ((L, T), (R, T), (R, B), (L, B)): ol.Append(x, y)
    z.SetLocalClearance(mm(0.3)); z.SetMinThickness(mm(0.25))
    z.SetPadConnection(pcbnew.ZONE_CONNECTION_THERMAL)
    z.SetThermalReliefGap(mm(0.5)); z.SetThermalReliefSpokeWidth(mm(0.5))
    z.SetIslandRemovalMode(pcbnew.ISLAND_REMOVAL_MODE_ALWAYS)
    b.Add(z); zones.append(z)
pcbnew.ZONE_FILLER(b).Fill(zones)
for z in zones:
    l = z.GetLayer(); fp = z.GetFilledPolysList(l)
    print(b.GetLayerName(l), "pieces", fp.OutlineCount(), "area mm2", round(fp.Area() / 1e12, 1))
print("board mm2", round((R - L) * (B - T) / 1e12, 1))
pcbnew.SaveBoard(P, b)
