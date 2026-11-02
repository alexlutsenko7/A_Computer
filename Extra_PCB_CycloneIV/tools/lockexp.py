import pcbnew
P = r"C:\work\My\AlteraZX\Extended\qm_atrix_ext.kicad_pcb"
b = pcbnew.LoadBoard(P)
items = list(b.GetTracks()); zones = list(b.Zones())
was = sum(1 for t in items if t.IsLocked())
for t in items: t.SetLocked(True)
print("tracks+vias", len(items), "already locked", was, "zones", len(zones))
pcbnew.SaveBoard(P, b)
print("dsn", pcbnew.ExportSpecctraDSN(b, r"C:\Users\Public\fr\r3.dsn"))
