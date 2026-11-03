# check_net.py -- the generated schematic's netlist (kicad-cli) against design.py: every pin on its intended net,
# no two intended nets merged, no-connect pins on no net of their own design.
import sys, os, subprocess, xml.etree.ElementTree as ET
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from design import comps
here = os.path.dirname(os.path.abspath(__file__))
sch = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "..", "Extra_PCB_CycloneIV_R2.kicad_sch")
xml = os.path.join(here, "..", "netlist.xml")
cli = "/mnt/c/Program Files/KiCad/10.0/bin/kicad-cli.exe"
w = lambda p: subprocess.run(["wslpath", "-w", p], capture_output=True, text=True).stdout.strip()
subprocess.run([cli, "sch", "export", "netlist", "--format", "kicadxml", "-o", w(xml), w(sch)], check=True,
               capture_output=True)
root = ET.parse(xml).getroot()
got = {}
for n in root.find("nets"):
    name = n.get("name").lstrip("/")
    for nd in n.findall("node"):
        got[(nd.get("ref"), nd.get("pin"))] = name
os.remove(xml)
err = 0
want_to_got = {}
for c in comps:
    for p, net in c["pins"].items():
        g = got.get((c["ref"], p))
        if net is None:
            if g and not g.startswith("unconnected-"):
                print(f"{c['ref']}.{p}: should be open, is on {g}"); err += 1
            continue
        if g != net:
            print(f"{c['ref']}.{p}: want {net}, got {g}"); err += 1
        want_to_got.setdefault(g, set()).add(net)
for g, ws in want_to_got.items():
    if len(ws) > 1:
        print(f"nets merged into {g}: {sorted(ws)}"); err += 1
print("netlist check:", "PASS" if not err else f"{err} errors")
sys.exit(1 if err else 0)
