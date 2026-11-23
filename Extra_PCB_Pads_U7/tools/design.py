# Extra_PCB_Pads_U7 (pad board on the 10CL025 core board's header U7): component list + nets, the single source
# for the schematic generator (gen_sch.py), the placement and the BOM.
#
# Two DB9 sockets for Sega Mega Drive pads (3 and 6 buttons); Atari-style joysticks and Master System pads work too.
# The pads run on 5 V, the FPGA pins take 3.3 V only:
#   pad -> FPGA : six lines per socket through a 74LVC245 on 3.3 V (its inputs tolerate 5 V)
#   FPGA -> pad : the two select lines (DB9 pin 7) through one dual buffer 74HCT2G34 on 5 V (reads a 3.3 V high as high)
#   pad supply  : 5 V from the core board (U7 pins 63 / 64), straight to DB9 pin 5
LIB = "Extra_PCB_Pads_U7"

FP_R = "Resistor_SMD:R_0603_1608Metric"
FP_C = "Capacitor_SMD:C_0603_1608Metric"
FP_C10 = "Capacitor_SMD:C_0805_2012Metric"
FP_DB9 = "Connector_Dsub:DSUB-9_Pins_Horizontal_P2.77x2.84mm_EdgePinOffset7.70mm_Housed_MountingHolesOffset9.12mm"
FP_HDR = "Connector_PinHeader_2.54mm:PinHeader_2x32_P2.54mm_Vertical"
FP_TSSOP20 = "Package_SO:TSSOP-20_4.4x6.5mm_P0.65mm"
FP_SOT236 = "Package_TO_SOT_SMD:SOT-23-6"

# the six pad lines of a socket: DB9 pin -> name (Mega Drive: select high / select low)
#   1 Up, 2 Down, 3 Left / low, 4 Right / low, 6 B / A, 9 C / Start; 7 = select (TH), 5 = supply, 8 = ground
LINES = ((1, "UP"), (2, "DOWN"), (3, "LEFT"), (4, "RIGHT"), (6, "B"), (9, "C"))

# J1 = the core board's U7, pin for pin (pins 5 / 6 and 47-60 are not used; pin 7 is the machines' menu key input).
# FPGA balls of the 10CL025 (QMTECH schematic V1): see ../README.md.
HDR = {1: "GND", 2: "GND", 3: "+3V3", 4: "+3V3",
       21: "PAD1_UP", 23: "PAD1_DOWN", 26: "PAD1_LEFT", 27: "PAD1_RIGHT", 30: "PAD1_B", 31: "PAD1_C", 32: "PAD1_SEL",
       33: "PAD2_SEL", 34: "PAD2_UP", 35: "PAD2_DOWN", 36: "PAD2_LEFT", 37: "PAD2_RIGHT", 38: "PAD2_B", 44: "PAD2_C",
       61: "GND", 62: "GND", 63: "+5V", 64: "+5V"}

# comp: ref, lib_id, value, footprint, {pin: net or None (no connect)}, mpn (manufacturer part number for the BOM)
comps = []
def add(ref, lib, val, fp, pins, mpn="", **kw):
    comps.append(dict(ref=ref, lib=lib, val=val, fp=fp, pins=pins, mpn=mpn, **kw))

add("J1", "Connector_Generic:Conn_02x32_Odd_Even", "U7", FP_HDR, {str(k): HDR.get(k) for k in range(1, 65)}, dnp=True)

# 74LVC245 pins: 1 DIR (high = A to B), 2-9 A, 10 GND, 11-18 B (pin 18 opposite pin 2), 19 /OE, 20 VCC.
# Which A / B pair carries which line is chosen for the layout (ORDER: the lines on pins 2, 3, ... of the buffer).
ORDER = {1: ("UP", "DOWN", "LEFT", "RIGHT", "B", "C"), 2: ("UP", "DOWN", "LEFT", "RIGHT", "B", "C")}
rn = 1
for j in (1, 2):
    jref, uref = f"J{j + 1}", f"U{j}"
    # the socket: lines with 3k3 pull-ups to 5 V (an Atari-style joystick only shorts them to ground)
    add(jref, "Connector:DE9_Pins_MountingHoles", f"Pad {j}", FP_DB9,
        {"SH": "GND", "5": "+5V", "7": f"PAD{j}_SEL_J", "8": "GND",
         **{str(p): f"PAD{j}_{n}_J" for p, n in LINES}}, mpn="DS1037-09MNAKT74-0CC")
    for p, n in LINES:
        add(f"R{rn}", "Device:R_Small_US", "3k3", FP_R, {"1": "+5V", "2": f"PAD{j}_{n}_J"}, grp=f"pull{j}")
        rn += 1
    # pad -> FPGA
    pins = {"1": "+3V3", "19": "GND", "10": "GND", "20": "+3V3"}
    for k in range(8):
        n = ORDER[j][k] if k < len(ORDER[j]) else None
        pins[str(2 + k)] = f"PAD{j}_{n}_J" if n else "GND"
        pins[str(18 - k)] = f"PAD{j}_{n}" if n else None
    add(uref, "74xx:74HC245", "74LVC245", FP_TSSOP20, pins, mpn="SN74LVC245APWR")
    # select: high while the FPGA pin is not driven; 100 Ohm in series with the socket pin
    add(f"R{rn}", "Device:R_Small_US", "10k", FP_R, {"1": "+3V3", "2": f"PAD{j}_SEL"}, grp=f"sel{j}")
    rn += 1
    add(f"R{rn}", "Device:R_Small_US", "100", FP_R, {"1": f"PAD{j}_SEL_O", "2": f"PAD{j}_SEL_J"}, grp=f"sel{j}")
    rn += 1
# FPGA -> pad: both select lines. 74HCT2G34 pins: 1 1A, 2 GND, 3 2A, 4 2Y, 5 VCC, 6 1Y
add("U3", LIB + ":74HCT2G34", "74HCT2G34", FP_SOT236,
    {"1": "PAD1_SEL", "2": "GND", "3": "PAD2_SEL", "4": "PAD2_SEL_O", "5": "+5V", "6": "PAD1_SEL_O"}, mpn="74HCT2G34GV")
# decoupling: U1, U3, socket 1, U2, socket 2, 10 uF on the 5 V input
add("C1", "Device:C_Small", "0.1u", FP_C, {"1": "+3V3", "2": "GND"}, grp="dec")
add("C2", "Device:C_Small", "0.1u", FP_C, {"1": "+5V", "2": "GND"}, grp="dec")
add("C3", "Device:C_Small", "0.1u", FP_C, {"1": "+5V", "2": "GND"}, grp="dec")
add("C4", "Device:C_Small", "0.1u", FP_C, {"1": "+3V3", "2": "GND"}, grp="dec")
add("C5", "Device:C_Small", "0.1u", FP_C, {"1": "+5V", "2": "GND"}, grp="dec")
add("C6", "Device:C_Small", "10u", FP_C10, {"1": "+5V", "2": "GND"}, grp="dec")

POWER = {"GND", "+5V", "+3V3"}

if __name__ == "__main__":
    nets = {}
    for c in comps:
        for p, n in c["pins"].items():
            if n:
                nets.setdefault(n, []).append(f"{c['ref']}.{p}")
    for n in sorted(nets):
        print(f"{n:14s} {' '.join(nets[n])}")
    print(len(comps), "parts,", len(nets), "nets")
