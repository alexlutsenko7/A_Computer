import pcbnew
P = r"C:\work\My\AlteraZX\Extended\qm_atrix_ext.kicad_pcb"
b = pcbnew.LoadBoard(P); print("import", pcbnew.ImportSpecctraSES(b, r"C:\Users\Public\fr\r4.ses"))
t = list(b.GetTracks()); print("tracks", sum(1 for x in t if x.GetClass() == "PCB_TRACK"), "vias", sum(1 for x in t if x.GetClass() == "PCB_VIA"))
pcbnew.SaveBoard(P, b)
