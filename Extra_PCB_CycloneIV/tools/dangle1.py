import pcbnew
P = r"C:\work\My\AlteraZX\Extended\qm_atrix_ext.kicad_pcb"
b = pcbnew.LoadBoard(P); b.BuildConnectivity(); conn = b.GetConnectivity()
items = list(b.GetTracks()); dead = []
for t in items:
    if t.GetClass() == "PCB_TRACK" and conn.TestTrackEndpointDangling(t, False): dead.append(t)
    elif t.GetClass() == "PCB_VIA" and len(list(conn.GetConnectedItems(t))) < 2: dead.append(t)
for t in dead: b.Remove(t)
pcbnew.SaveBoard(P, b); print(len(dead))
