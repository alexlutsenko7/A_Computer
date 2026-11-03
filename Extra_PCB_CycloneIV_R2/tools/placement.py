# placement.py -- board outline and footprint positions for mk_pcb.py build: ref -> (x, y, rotation[, "B"]) in mm
OUTLINE = (50.95, 71.97, 135.05, 155.4)      # revision 1's outline, 84.1 x 83.43 mm
PLACE = {
    # ---- edges ----
    # bottom: host connector (revision 1's position)
    "J1": (132.55, 151.16, -90),
    # top: DB9 1, DB9 2, audio jack (opening up)
    "J4": (72.72, 82.22, 180), "J6": (107.12, 82.22, 180), "J3": (122.94, 78.28, -90),
    # left: USB 2 (5 V only), VGA, microSD
    "J9": (63.94, 90.2, -90), "J2": (64.66, 123.12, -90), "J7": (57.04, 141.9, 90),
    # right: ESP32 (antenna end at the edge), USB-C, USB 1 (keyboard)
    "U2": (118.35, 100.04, -90), "J5": (131.4, 124.5, 90), "J8": (122.06, 143.07, 90),
    # mounting holes
    "H1": (71.26, 102.94, 0), "H2": (116.35, 132.19, 0), "H3": (82.49, 144.64, 0), "H4": (98.5, 109.0, 0),

    # ---- joystick pull-ups under their DB9 ----
    "R15": (72.0, 87.0, 90), "R16": (74.0, 87.0, 90), "R17": (76.0, 87.0, 90), "R18": (78.0, 87.0, 90), "R19": (80.0, 87.0, 90),
    "R20": (91.0, 87.0, 90), "R21": (93.0, 87.0, 90), "R22": (95.0, 87.0, 90), "R23": (97.0, 87.0, 90), "R24": (99.0, 87.0, 90),

    # ---- USB 2 (J9) bulk + decoupling ----
    "C20": (69.5, 91.0, 90), "C22": (69.5, 95.5, 90),

    # ---- VGA DAC next to J2: rows blue / green / red, sync resistors, 6p8 caps ----
    "R9": (69.0, 119.0, 90), "R10": (71.0, 119.0, 90), "R11": (73.0, 119.0, 90), "R12": (75.0, 119.0, 90),
    "R5": (69.0, 122.5, 90), "R6": (71.0, 122.5, 90), "R7": (73.0, 122.5, 90), "R8": (75.0, 122.5, 90),
    "R1": (69.0, 126.0, 90), "R2": (71.0, 126.0, 90), "R3": (73.0, 126.0, 90), "R4": (75.0, 126.0, 90),
    "R13": (69.0, 115.5, 90), "R14": (71.0, 115.5, 90),
    "C3": (77.5, 119.0, 90), "C2": (77.5, 122.5, 90), "C1": (77.5, 126.0, 90), "C4": (73.5, 115.5, 90), "C5": (75.5, 115.5, 90),

    # ---- microSD pull-ups + supply caps next to J7 ----
    "R25": (67.0, 139.0, 90), "R26": (69.0, 139.0, 90), "R27": (71.0, 139.0, 90), "R28": (73.0, 139.0, 90),
    "R29": (75.0, 139.0, 90), "C6": (77.0, 139.0, 90), "C7": (79.5, 139.0, 90),

    # ---- audio filter (AY low-pass + coupling, beeper coupling, mix, load) ----
    "R30": (88.0, 96.0, 0), "C8": (88.0, 98.5, 0), "C9": (92.0, 96.0, 0), "R31": (96.0, 96.0, 0),
    "C10": (92.0, 100.5, 0), "R32": (96.0, 100.5, 0), "R33": (99.5, 98.5, 90),

    # ---- ESP32: decoupling + EN RC near pins 2 / 3 (all left of the antenna area), IO0 pull-up, EN / BOOT buttons ----
    "C13": (124.5, 88.3, 0), "R36": (121.2, 88.3, 0), "C11": (117.9, 88.3, 0), "C12": (114.3, 88.3, 0),
    "R37": (106.0, 112.5, 0), "SW1": (96.0, 117.0, 0), "SW2": (96.0, 122.5, 0),

    # ---- USB-C: CC resistors, ESD, VBUS cap, back-feed diode ----
    "R39": (124.0, 121.8, 0), "U5": (123.2, 125.0, 0), "R38": (124.0, 128.2, 0),
    "C27": (120.0, 113.5, 0), "D1": (113.0, 113.5, 0),

    # ---- CP2102N + VBUS divider, reset pull-up, decoupling; auto-reset transistors ----
    "U3": (116.0, 121.0, 0), "C14": (116.0, 116.6, 0), "C15": (119.8, 121.0, 90), "C16": (116.0, 125.4, 0),
    "R40": (111.5, 119.5, 0), "R41": (111.5, 121.5, 0), "R42": (111.5, 123.5, 0),
    "Q1": (106.5, 119.5, 0), "Q2": (106.5, 124.5, 0), "R34": (102.5, 119.5, 0), "R35": (102.5, 124.5, 0),

    # ---- 3.3 V LDO with input / output caps ----
    "U1": (91.5, 128.5, 0),
    "C23": (84.0, 126.0, 0), "C25": (84.0, 128.5, 0), "C26": (84.0, 131.0, 0),
    "C24": (99.0, 126.0, 0), "C28": (99.0, 128.5, 0), "C29": (99.0, 131.0, 0),

    # ---- CH9350L + USB 1 (J8): decoupling, ESD, bulk ----
    "U4": (106.0, 140.0, 0), "C17": (103.5, 132.6, 0), "C18": (107.5, 132.6, 0),
    "U6": (116.5, 139.5, 0), "C21": (116.5, 143.8, 0), "C19": (116.5, 146.5, 0),
}

# rule area (F.Cu + B.Cu: no tracks, vias, pads, copper pour or footprints) for the ESP32 antenna = the last 7.44 mm
# of the module (x 127.61..135.05; the area starts at 128.2, clear of pads 1 / 38). Espressif's "Keepout Zone for ESP32
# Module's Antenna (Antenna feed point on the right)": 15 mm clear beside the antenna on the side away from the feed
# point. Module top view: feed on the right = the pin 20-38 side, which faces down here (towards USB-C), so the 15 mm
# go up along the edge: module y 91.04..109.04 -> area from 76.04. Below the module it runs on to the USB-C socket.
# KEEPOUT entries: (name, (x0, y0, x1, y1), layers, allowed, holes): allowed = what may still be in the area
KEEPOUT = [("ESP32 antenna clearance", (128.2, 76.04, 135.05, 119.0), ("F.Cu", "B.Cu"), (), []),
# top layer under the module body (between its pad rows, up to the antenna): no tracks, vias or pour, so nothing but the
# module's own pads touches its underside; the hole leaves room around pad 39 (GND, 3.7 mm) for its vias. B.Cu below
# stays free for the GND fill.
           ("ESP32 body: top layer clear", (103.65, 92.3, 127.61, 107.8), ("F.Cu",), ("pads", "footprints"),
            [(117.35, 96.09, 122.25, 100.99)])]
