import pcbnew
P = r"C:\work\My\AlteraZX\Extended\qm_atrix_ext.kicad_pcb"
b = pcbnew.LoadBoard(P)
items = list(b.GetTracks())
for t in items: b.Remove(t)
pcbnew.SaveBoard(P, b)
print("removed", len(items), "| dsn", pcbnew.ExportSpecctraDSN(b, r"C:\Users\Public\fr\r4.dsn"))
