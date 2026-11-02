# QM_Atrix Extended: component list + nets (single source for schematic and PCB generators)
LIB = "qm_atrix_ext"

FP_R = "Resistor_SMD:R_0603_1608Metric"
FP_C = "Capacitor_SMD:C_0603_1608Metric"
FP_C10 = "Capacitor_SMD:C_0805_2012Metric"
FP_DISC = "Capacitor_THT:C_Disc_D4.7mm_W2.5mm_P5.00mm"
FP_POT = "Connector_PinHeader_2.54mm:PinHeader_1x03_P2.54mm_Vertical"
FP_DB9 = "Connector_Dsub:DSUB-9_Pins_Horizontal_P2.77x2.84mm_EdgePinOffset7.70mm_Housed_MountingHolesOffset9.12mm"
FP_DB15 = LIB + ":DSUB-15-HD_Female_Horizontal_P2.29x1.98mm_EdgePinOffset3.03mm_Housed_MountingHolesOffset4.94mm"

# host header: 2x20, wires to the Cyclone IV board
HDR = {1: "+5V", 2: "+5V", 3: "GND", 4: "GND",
       5: "VGA_R3", 6: "VGA_R2", 7: "VGA_R1", 8: "VGA_R0",
       9: "VGA_G3", 10: "VGA_G2", 11: "VGA_G1", 12: "VGA_G0",
       13: "VGA_B3", 14: "VGA_B2", 15: "VGA_B1", 16: "VGA_B0",
       17: "VGA_HS", 18: "VGA_VS", 19: "GND", 20: "GND",
       21: "AUDIO_AY", 22: "AUDIO_BEEP", 23: "KB_OUT", 24: "KB_IN",
       25: "SD_SCK", 26: "SD_MOSI", 27: "SD_MISO", 28: "SD_CS_N",
       29: "JOY1_UP", 30: "JOY1_DOWN", 31: "JOY1_LEFT", 32: "JOY1_RIGHT", 33: "JOY1_FIRE",
       34: "JOY2_UP", 35: "JOY2_DOWN", 36: "JOY2_LEFT", 37: "JOY2_RIGHT", 38: "JOY2_FIRE",
       39: "GND", 40: "GND"}

# 4-bit binary-weighted DAC per colour, 0.7 V full scale into 75 Ohm from 3.3 V
DAC_R = {3: "523", 2: "1.05k", 1: "2.1k", 0: "4.22k"}

# comp: ref, lib_id, value, footprint, {pin: net or None (no connect)}
comps = []
def add(ref, lib, val, fp, pins, **kw):
    comps.append(dict(ref=ref, lib=lib, val=val, fp=fp, pins=pins, **kw))

add("J1", "Connector_Generic:Conn_02x20_Odd_Even", "Host", "Connector_PinHeader_2.54mm:PinHeader_2x20_P2.54mm_Vertical",
    {str(k): v for k, v in HDR.items()})

n = 1
for col, out in (("R", "RED"), ("G", "GRN"), ("B", "BLU")):
    for bit in (3, 2, 1, 0):
        add(f"R{n}", "Device:R_Small_US", DAC_R[bit], FP_R, {"1": f"VGA_{col}{bit}", "2": out}, grp="dac")
        n += 1
add("R13", "Device:R_Small_US", "22", FP_R, {"1": "VGA_HS", "2": "HSYNC"}, grp="sync")
add("R14", "Device:R_Small_US", "22", FP_R, {"1": "VGA_VS", "2": "VSYNC"}, grp="sync")
for i, net in enumerate(("RED", "GRN", "BLU", "VGA_HS", "VGA_VS")):
    add(f"C{i+1}", "Device:C_Small", "6p8", FP_C, {"1": net, "2": "GND"}, grp="vgac")
db15 = {"0": "GND", "1": "RED", "2": "GRN", "3": "BLU", "4": None, "5": "GND", "6": "GND", "7": "GND",
        "8": "GND", "9": None, "10": "GND", "11": None, "12": None, "13": "HSYNC", "14": "VSYNC", "15": None}
add("J2", LIB + ":DB15_Female_HighDensity", "VGA", FP_DB15, db15)

dirs = ("UP", "DOWN", "LEFT", "RIGHT", "FIRE")
rn = 15
for j, jref in ((1, "J4"), (2, "J6")):
    for d in dirs:
        add(f"R{rn}", "Device:R_Small_US", "3k3", FP_R, {"1": "+3V3", "2": f"JOY{j}_{d}"}, grp=f"joy{j}")
        rn += 1
    add(jref, "Connector:DE9_Pins_MountingHoles", f"Joystick {j}", FP_DB9,
        {"SH": "GND", "1": f"JOY{j}_UP", "2": f"JOY{j}_DOWN", "3": f"JOY{j}_LEFT", "4": f"JOY{j}_RIGHT",
         "5": None, "6": f"JOY{j}_FIRE", "7": None, "8": "GND", "9": None})

add("J7", "Connector:Micro_SD_Card", "microSD", "Connector_Card:microSD_HC_Molex_104031-0811",
    {"1": "SD_DAT2", "2": "SD_CS_N", "3": "SD_MOSI", "4": "+3V3", "5": "SD_SCK", "6": "GND",
     "7": "SD_MISO", "8": "SD_DAT1", "SH": "GND"})
for r, net in zip(range(25, 30), ("SD_CS_N", "SD_MOSI", "SD_MISO", "SD_DAT1", "SD_DAT2")):
    add(f"R{r}", "Device:R_Small_US", "10k", FP_R, {"1": "+3V3", "2": net}, grp="sd")
add("C6", "Device:C_Small", "0.1u", FP_C, {"1": "+3V3", "2": "GND"}, grp="sd")
add("C7", "Device:C_Small", "10u", FP_C10, {"1": "+3V3", "2": "GND"}, grp="sd")

add("R30", "Device:R_Small_US", "68", FP_R, {"1": "AUDIO_AY", "2": "AY_LP"}, grp="audio")
add("C8", "Device:C_Small", "0.1u", FP_DISC, {"1": "AY_LP", "2": "GND"}, grp="audio")
add("C9", "Device:C_Small", "10u", FP_DISC, {"1": "AY_LP", "2": "AY_AC"}, grp="audio")
add("C10", "Device:C_Small", "10u", FP_DISC, {"1": "AUDIO_BEEP", "2": "BEEP_AC"}, grp="audio")
add("RV1", "Device:R_Potentiometer_US", "1k", FP_POT, {"1": "AY_AC", "2": "AY_VOL", "3": "GND"}, grp="audio")
add("RV2", "Device:R_Potentiometer_US", "1k", FP_POT, {"1": "BEEP_AC", "2": "BEEP_VOL", "3": "GND"}, grp="audio")
add("J3", "Connector_Generic:Conn_01x03", "Audio out", "Connector_PinHeader_2.54mm:PinHeader_1x03_P2.54mm_Vertical",
    {"1": "BEEP_VOL", "2": "GND", "3": "AY_VOL"})
add("J5", LIB + ":Conn_01x04_Male", "Keyb", LIB + ":USB_MODULE_KEYB_V2",
    {"1": "GND", "2": "KB_OUT", "3": "KB_IN", "4": "+5V"})

add("U1", LIB + ":7803_switcing", "7803 module", "Connector_PinHeader_2.54mm:PinHeader_1x03_P2.54mm_Vertical",
    {"1": "+5V", "2": "GND", "3": "+3V3"})
add("C11", "Device:C_Small", "10u", FP_C10, {"1": "+5V", "2": "GND"}, grp="pwr")
add("C12", "Device:C_Small", "10u", FP_C10, {"1": "+3V3", "2": "GND"}, grp="pwr")
for i in (13, 14, 15):
    add(f"C{i}", "Device:C_Small", "0.1u", FP_C, {"1": "+3V3", "2": "GND"}, grp="pwr")
for i in (16, 17):
    add(f"C{i}", "Device:C_Small", "0.1u", FP_C, {"1": "+5V", "2": "GND"}, grp="pwr")

POWER = {"GND", "+5V", "+3V3"}

for i in range(1, 5):
    add(f"H{i}", "Mechanical:MountingHole", "M3", "MountingHole:MountingHole_3.2mm_M3", {})
