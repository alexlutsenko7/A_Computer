import pcbnew
from collections import Counter
P = r"C:\work\My\AlteraZX\Extended\qm_atrix_ext.kicad_pcb"
b = pcbnew.LoadBoard(P)
vias = [t for t in b.GetTracks() if t.GetClass() == "PCB_VIA"]
print("vias", len(vias), Counter(v.GetNetname() or "<no net>" for v in vias).most_common(4))
zones = list(b.Zones())
def rep(tag):
    for z in zones:
        l = z.GetLayer(); fp = z.GetFilledPolysList(l); print(tag, b.GetLayerName(l), "pieces", fp.OutlineCount(), "area", round(fp.Area() / 1e12, 1))
rep("before"); pcbnew.ZONE_FILLER(b).Fill(zones); rep("after ")
pcbnew.SaveBoard(P, b)
