# mk_pro.py -- (WSL python, run in the project folder) writes Extra_PCB_Pads_U7.kicad_pro: the I/O board revision 2's
# rules and net classes (signals 0.2 mm, GND and +3V3 0.3 mm, 5 V nets 0.4 mm, copper to edge 0.3 mm) for this board.
import json, re
NAME = "Extra_PCB_Pads_U7"
SRC = "../Extra_PCB_CycloneIV_R2/Extra_PCB_CycloneIV_R2.kicad_pro"
d = json.load(open(SRC))
d["net_settings"]["netclass_patterns"] = [{"netclass": "Power_0.4", "pattern": "+5V"},
                                          {"netclass": "Power_0.4", "pattern": "/PAD?_5V"},
                                          {"netclass": "Power_0.3", "pattern": "+3V3"},
                                          {"netclass": "GND", "pattern": "GND"}]
root = re.search(r'\(uuid "([^"]+)"', open(NAME + ".kicad_sch").read()).group(1)
d["sheets"] = [[root, "Root"]]
for t in d["schematic"]["top_level_sheets"]:
    t["uuid"] = root
d["board"]["design_settings"]["rules"]["min_copper_edge_clearance"] = 0.3
s = json.dumps(d, indent=2).replace("Extra_PCB_CycloneIV_R2", NAME)
open(NAME + ".kicad_pro", "w", newline="\n").write(s + "\n")
r = d["board"]["design_settings"]["rules"]
print("classes", [(c["name"], c["track_width"]) for c in d["net_settings"]["classes"]],
      "edge", r.get("min_copper_edge_clearance"), "min track", r.get("min_track_width"), "clearance", r.get("min_clearance"))
