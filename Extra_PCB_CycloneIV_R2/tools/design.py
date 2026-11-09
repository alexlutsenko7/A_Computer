# Extra_PCB_CycloneIV_R2 (I/O board revision 2): component list + nets, the single source for the schematic
# generator (gen_sch.py) and the BOM. Revision 1 = ../../Extra_PCB_CycloneIV (as built, not changed).
#
# Changes against revision 1 (same J1 pinout, so the FPGA images stay as they are):
#   ESP32 DevKit on sockets -> ESP32-WROVER-E-N16R8 module (16 MB flash, 8 MB PSRAM) + CP2102N USB-UART with
#                              auto-reset on USB-C; the same GPIOs except the control UART (IO16/IO17 belong to the
#                              PSRAM): RX2 on IO27, TX2 on IO21 (the firmware picks them when it finds PSRAM)
#   keyboard module (J5)    -> CH9350L with a USB-A host socket (J8); a second USB-A (J9, 5 V only) beside the VGA
#                              socket powers a VGA2HDMI dongle
#   5 V from the core board -> 5 V from USB-C on this board, fed to the core board through J1 63/64
#   K7803 module            -> LDL1117S33R LDO (1.2 A, SOT-223)
#   audio THT capacitors    -> SMD (same circuit)
LIB = "Extra_PCB_CycloneIV_R2"

FP_R = "Resistor_SMD:R_0603_1608Metric"
FP_C = "Capacitor_SMD:C_0603_1608Metric"
FP_C10 = "Capacitor_SMD:C_0805_2012Metric"
FP_C100 = "Capacitor_SMD:C_1206_3216Metric"
FP_DB9 = "Connector_Dsub:DSUB-9_Pins_Horizontal_P2.77x2.84mm_EdgePinOffset7.70mm_Housed_MountingHolesOffset9.12mm"
FP_DB15 = LIB + ":DSUB-15-HD_Socket_Horizontal_P2.29x2.54mm_CONNFLY_DS1038"
FP_SOT23 = "Package_TO_SOT_SMD:SOT-23"
FP_SOT236 = "Package_TO_SOT_SMD:SOT-23-6"
FP_USBA = "Connector_USB:USB_A_Connfly_DS1095"
FP_SW = "Button_Switch_SMD:SW_SPST_PTS810"

# J1: 2x32 host connector, wired to the core board's U8 with each pin pair swapped (as revision 1).
# The nets per J1 pin are revision 1's; the FPGA pin of each is in ../README.md.
HDR = {1: "GND", 2: "GND",
       7: "ESP_SCK", 8: "ESP_MOSI", 9: "ESP_CS_N", 10: "ESP_MISO", 11: "ESP_IRQ",
       12: "BT_BCLK", 13: "BT_LRCK", 14: "BT_DATA", 15: "BT_TX", 16: "BT_RX",
       17: "KB_IN", 18: "AUDIO_AY", 19: "KB_OUT", 20: "AUDIO_BEEP",
       21: "JOY1_UP", 22: "JOY1_DOWN", 23: "JOY1_LEFT", 24: "JOY1_RIGHT", 25: "JOY1_FIRE",
       26: "JOY2_UP", 27: "JOY2_DOWN", 28: "JOY2_LEFT", 29: "JOY2_RIGHT", 30: "JOY2_FIRE",
       45: "VGA_VS", 47: "VGA_HS",
       49: "VGA_R3", 50: "VGA_R1", 51: "VGA_R2", 52: "VGA_R0",
       53: "VGA_G3", 54: "VGA_G1", 55: "VGA_G2", 56: "VGA_G0",
       57: "VGA_B3", 58: "VGA_B1", 59: "VGA_B2", 60: "VGA_B0",
       61: "GND", 62: "GND", 63: "+5V", 64: "+5V"}

DAC_R = {3: "523", 2: "1.05k", 1: "2.1k", 0: "4.22k"}

# comp: ref, lib_id, value, footprint, {pin: net or None (no connect)}, mpn (manufacturer part number for the BOM)
comps = []
def add(ref, lib, val, fp, pins, mpn="", **kw):
    comps.append(dict(ref=ref, lib=lib, val=val, fp=fp, pins=pins, mpn=mpn, **kw))

add("J1", "Connector_Generic:Conn_02x32_Odd_Even", "Host", LIB + ":PinHeader_2x32_P2.54mm_Vertical_RowsSwapped",
    {str(k): HDR.get(k) for k in range(1, 65)}, dnp=True)

# ---------------- VGA (as revision 1) ----------------
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
add("J2", LIB + ":DB15_Female_HighDensity", "VGA", FP_DB15, db15, mpn="DS1038-15FBNSiA74-0CC")

# ---------------- joysticks (as revision 1) ----------------
dirs = ("UP", "DOWN", "LEFT", "RIGHT", "FIRE")
rn = 15
for j, jref in ((1, "J4"), (2, "J6")):
    for d in dirs:
        add(f"R{rn}", "Device:R_Small_US", "3k3", FP_R, {"1": "+3V3", "2": f"JOY{j}_{d}"}, grp=f"joy{j}")
        rn += 1
    add(jref, "Connector:DE9_Pins_MountingHoles", f"Joystick {j}", FP_DB9,
        {"SH": "GND", "1": f"JOY{j}_UP", "2": f"JOY{j}_DOWN", "3": f"JOY{j}_LEFT", "4": f"JOY{j}_RIGHT",
         "5": None, "6": f"JOY{j}_FIRE", "7": None, "8": "GND", "9": None}, mpn="DS1037-09MNAKT74-0CC")

# ---------------- microSD on the ESP32 (as revision 1) ----------------
add("J7", "Connector:Micro_SD_Card", "microSD", "Connector_Card:microSD_HC_Molex_104031-0811",
    {"1": "SD_DAT2", "2": "SD_CS_N", "3": "SD_MOSI", "4": "+3V3", "5": "SD_SCK", "6": "GND",
     "7": "SD_MISO", "8": "SD_DAT1", "SH": "GND"}, mpn="104031-0811")
for r, net in zip(range(25, 30), ("SD_CS_N", "SD_MOSI", "SD_MISO", "SD_DAT1", "SD_DAT2")):
    add(f"R{r}", "Device:R_Small_US", "10k", FP_R, {"1": "+3V3", "2": net}, grp="sd")
add("C6", "Device:C_Small", "0.1u", FP_C, {"1": "+3V3", "2": "GND"}, grp="sd")
add("C7", "Device:C_Small", "10u", FP_C10, {"1": "+3V3", "2": "GND"}, grp="sd")

# ---------------- audio line out (revision 1's circuit, SMD capacitors) ----------------
add("R30", "Device:R_Small_US", "68", FP_R, {"1": "AUDIO_AY", "2": "AY_LP"}, grp="audio")
add("C8", "Device:C_Small", "0.1u", FP_C, {"1": "AY_LP", "2": "GND"}, grp="audio")
add("C9", "Device:C_Small", "10u", FP_C10, {"1": "AY_LP", "2": "AY_AC"}, grp="audio")
add("C10", "Device:C_Small", "10u", FP_C10, {"1": "AUDIO_BEEP", "2": "BEEP_AC"}, grp="audio")
add("R31", "Device:R_Small_US", "2.2k", FP_R, {"1": "AY_AC", "2": "AUDIO_OUT"}, grp="audio")
add("R32", "Device:R_Small_US", "2.2k", FP_R, {"1": "BEEP_AC", "2": "AUDIO_OUT"}, grp="audio")
add("R33", "Device:R_Small_US", "1k", FP_R, {"1": "AUDIO_OUT", "2": "GND"}, grp="audio")
add("J3", "Connector_Audio:AudioJack4", "Audio out",
    "Connector_Audio:Jack_3.5mm_KoreanHropartsElec_PJ-320D-4A_Horizontal",
    {"S": "GND", "T": "AUDIO_OUT", "R1": "AUDIO_OUT", "R2": "GND"}, mpn="PJ-320D-4A")

# ---------------- USB-C: 5 V input + CP2102N console ----------------
add("J5", "Connector:USB_C_Receptacle_USB2.0_16P", "USB-C 5V / console",
    "Connector_USB:USB_C_Receptacle_HRO_TYPE-C-31-M-12",
    {"A1": "GND", "A12": "GND", "B1": "GND", "B12": "GND", "A4": "+5V", "A9": "+5V", "B4": "+5V", "B9": "+5V",
     "A5": "CC1", "B5": "CC2", "A6": "USBC_DP", "B6": "USBC_DP", "A7": "USBC_DM", "B7": "USBC_DM",
     "A8": None, "B8": None, "SH": "GND"}, mpn="TYPE-C-31-M-12")
add("R38", "Device:R_Small_US", "5.1k", FP_R, {"1": "CC1", "2": "GND"}, grp="usbc")
add("R39", "Device:R_Small_US", "5.1k", FP_R, {"1": "CC2", "2": "GND"}, grp="usbc")
add("U5", "Power_Protection:USBLC6-2SC6", "USBLC6-2SC6", FP_SOT236,
    {"1": "USBC_DP", "6": "USBC_DP", "3": "USBC_DM", "4": "USBC_DM", "2": "GND", "5": "+5V"}, mpn="USBLC6-2SC6")
add("C27", "Device:C_Small", "10u", FP_C10, {"1": "+5V", "2": "GND"}, grp="usbc")
# VBUS straight to +5V (no diode: the board is fed from USB-C or the core board, not both at once)

# CP2102N, self-powered from +3V3 (VREGIN = VDD = VIO), VBUS sensed through a divider
add("U3", "Interface_USB:CP2102N-Axx-xQFN24", "CP2102N-A02-GQFN24",
    "Package_DFN_QFN:QFN-24-1EP_4x4mm_P0.5mm_EP2.6x2.6mm",
    {"1": None, "2": "GND", "3": "USBC_DP", "4": "USBC_DM", "5": "+3V3", "6": "+3V3", "7": "+3V3", "8": "CP_VBUS",
     "9": "CP_RST_N", "10": None, "11": None, "12": None, "13": None, "14": None, "15": None, "16": None, "17": None,
     "18": None, "19": "CP_RTS", "20": "ESP_TXD0", "21": "ESP_RXD0", "22": None, "23": "CP_DTR", "24": None,
     "25": "GND"}, mpn="CP2102N-A02-GQFN24R")
add("R40", "Device:R_Small_US", "22k", FP_R, {"1": "+5V", "2": "CP_VBUS"}, grp="cp")
add("R41", "Device:R_Small_US", "47.5k", FP_R, {"1": "CP_VBUS", "2": "GND"}, grp="cp")
add("R42", "Device:R_Small_US", "1k", FP_R, {"1": "+3V3", "2": "CP_RST_N"}, grp="cp")
add("C14", "Device:C_Small", "1u", FP_C, {"1": "+3V3", "2": "GND"}, grp="cp")
add("C15", "Device:C_Small", "0.1u", FP_C, {"1": "+3V3", "2": "GND"}, grp="cp")
add("C16", "Device:C_Small", "0.1u", FP_C, {"1": "+3V3", "2": "GND"}, grp="cp")

# auto-reset (DevKit circuit): DTR low + RTS high -> EN low; DTR high + RTS low -> IO0 low
add("Q1", "Transistor_BJT:MMBT3904", "MMBT3904", FP_SOT23, {"1": "QB1", "2": "CP_RTS", "3": "ESP_EN"}, mpn="MMBT3904")
add("Q2", "Transistor_BJT:MMBT3904", "MMBT3904", FP_SOT23, {"1": "QB2", "2": "CP_DTR", "3": "ESP_IO0"}, mpn="MMBT3904")
add("R34", "Device:R_Small_US", "10k", FP_R, {"1": "CP_DTR", "2": "QB1"}, grp="ar")
add("R35", "Device:R_Small_US", "10k", FP_R, {"1": "CP_RTS", "2": "QB2"}, grp="ar")

# ---------------- ESP32-WROVER-E-N16R8 (JLCPCB C529589): the DevKit's GPIOs, control UART on IO27 / IO21 ----------------
esp = {"1": "GND", "15": "GND", "38": "GND", "39": "GND", "2": "+3V3", "3": "ESP_EN",
       "4": None, "5": None, "6": "ESP_IRQ", "7": "ESP_MISO", "8": None, "9": "ESP_CS_N",
       "10": "BT_LRCK", "11": "BT_BCLK", "12": "BT_TX", "13": "ESP_SCK", "14": None, "16": "ESP_MOSI",
       "17": None, "18": None, "19": None, "20": None, "21": None, "22": None,
       "23": None, "24": None, "25": "ESP_IO0", "26": None, "27": None, "28": None, "29": "SD_CS_N",
       "30": "SD_SCK", "31": "SD_MISO", "32": None, "33": "BT_RX", "34": "ESP_RXD0", "35": "ESP_TXD0",
       "36": "BT_DATA", "37": "SD_MOSI"}
add("U2", LIB + ":ESP32-WROVER-E", "ESP32-WROVER-E-N16R8", LIB + ":ESP32-WROVER-E", esp,
    mpn="ESP32-WROVER-E-N16R8")
add("R36", "Device:R_Small_US", "10k", FP_R, {"1": "+3V3", "2": "ESP_EN"}, grp="esp")
add("C11", "Device:C_Small", "1u", FP_C, {"1": "ESP_EN", "2": "GND"}, grp="esp")
add("R37", "Device:R_Small_US", "10k", FP_R, {"1": "+3V3", "2": "ESP_IO0"}, grp="esp")
add("SW1", "Switch:SW_Push", "EN", FP_SW, {"1": "ESP_EN", "2": "GND"}, mpn="PTS810SJM250SMTRLFS")
add("SW2", "Switch:SW_Push", "BOOT", FP_SW, {"1": "ESP_IO0", "2": "GND"}, mpn="PTS810SJM250SMTRLFS")
add("C12", "Device:C_Small", "22u", FP_C10, {"1": "+3V3", "2": "GND"}, grp="esp")
add("C13", "Device:C_Small", "0.1u", FP_C, {"1": "+3V3", "2": "GND"}, grp="esp")

# ---------------- CH9350L: USB keyboard -> UART (state 0, 115200 baud, host side); port 2 (HP/HM) not used ----------------
# SEL / S0 / S1 / BAUD0 / BAUD1 / xOSC have internal pull-ups: left open = the datasheet's reference circuit.
ch = {"41": "+5V", "42": "CH_VDD33", "18": "GND", "3": "GND", "28": "KB_IN", "27": "KB_OUT",
      "31": "KB1_DP", "32": "KB1_DM", "29": None, "30": None}
for p in (1, 2, 4, 5, 6, 7, 16, 17, 21, 22, 23, 24, 26, 37, 38, 45, 48):
    ch[str(p)] = None
add("U4", LIB + ":CH9350L", "CH9350L", "Package_QFP:LQFP-48_7x7mm_P0.5mm", ch, mpn="CH9350L")
add("C17", "Device:C_Small", "0.1u", FP_C, {"1": "+5V", "2": "GND"}, grp="ch")
add("C18", "Device:C_Small", "4.7u", FP_C, {"1": "CH_VDD33", "2": "GND"}, grp="ch")
# USB 1 (J8): keyboard, at the board edge near the CH9350L
add("C19", "Device:C_Small", "100u", FP_C100, {"1": "+5V", "2": "GND"}, grp="usba")
add("C21", "Device:C_Small", "0.1u", FP_C, {"1": "+5V", "2": "GND"}, grp="usba")
add("U6", "Power_Protection:USBLC6-2SC6", "USBLC6-2SC6", FP_SOT236,
    {"1": "KB1_DP", "6": "KB1_DP", "3": "KB1_DM", "4": "KB1_DM", "2": "GND", "5": "+5V"}, mpn="USBLC6-2SC6")
add("J8", "Connector:USB_A", "USB keyboard", FP_USBA,
    {"1": "+5V", "2": "KB1_DM", "3": "KB1_DP", "4": "GND", "SH": "GND"}, mpn="DS1095-WNR0")
# USB 2 (J9): 5 V only, beside the VGA socket, for a VGA2HDMI dongle's power lead (data pins open)
add("C20", "Device:C_Small", "100u", FP_C100, {"1": "+5V", "2": "GND"}, grp="usba")
add("C22", "Device:C_Small", "0.1u", FP_C, {"1": "+5V", "2": "GND"}, grp="usba")
add("J9", "Connector:USB_A", "USB 5V (HDMI dongle)", FP_USBA,
    {"1": "+5V", "2": None, "3": None, "4": "GND", "SH": "GND"}, mpn="DS1095-WNR0")

# ---------------- power: +5V -> LDO -> +3V3 ----------------
add("U1", "Regulator_Linear:AMS1117-3.3", "LDL1117S33R", "Package_TO_SOT_SMD:SOT-223-3_TabPin2",
    {"1": "GND", "2": "+3V3", "3": "+5V"}, mpn="LDL1117S33R")
add("C23", "Device:C_Small", "10u", FP_C10, {"1": "+5V", "2": "GND"}, grp="pwr")
add("C24", "Device:C_Small", "10u", FP_C10, {"1": "+3V3", "2": "GND"}, grp="pwr")
add("C25", "Device:C_Small", "10u", FP_C10, {"1": "+5V", "2": "GND"}, grp="pwr")
add("C26", "Device:C_Small", "0.1u", FP_C, {"1": "+5V", "2": "GND"}, grp="pwr")
add("C28", "Device:C_Small", "0.1u", FP_C, {"1": "+3V3", "2": "GND"}, grp="pwr")
add("C29", "Device:C_Small", "0.1u", FP_C, {"1": "+3V3", "2": "GND"}, grp="pwr")

POWER = {"GND", "+5V", "+3V3"}

for i in range(1, 5):
    add(f"H{i}", "Mechanical:MountingHole", "M3", "MountingHole:MountingHole_3.2mm_M3", {})
