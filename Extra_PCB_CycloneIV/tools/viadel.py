import pcbnew
P = r"C:\work\My\AlteraZX\Extended\qm_atrix_ext.kicad_pcb"
pts = [tuple(map(float, l.split())) for l in open(r"C:\Users\Public\fr\vias.txt") if l.strip()]
b = pcbnew.LoadBoard(P); MM = 1e6
dead = [v for v in list(b.GetTracks()) if v.GetClass() == "PCB_VIA" and any(abs(v.GetPosition().x / MM - x) < 0.01 and abs(v.GetPosition().y / MM - y) < 0.01 for x, y in pts)]
for v in dead: b.Remove(v)
pcbnew.SaveBoard(P, b); print(len(dead))
