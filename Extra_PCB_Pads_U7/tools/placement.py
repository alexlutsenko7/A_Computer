# placement.py -- board outline and footprint positions for mk_pcb.py build: ref -> (x, y, rotation[, "B"]) in mm,
# measured from the board's top left corner (ORIGIN is added). Seen from the top side (the DB9 side).
# The board lies under the core board's U7 edge as the I/O board lies under its U8 edge: the core board covers
# y > CORE_EDGE, 3 mm above this board.
ORIGIN = (100.0, 100.0)
WIDTH = 84.1          # the core board's width; the board is flush with it on both sides
HEIGHT = 19.5         # DB9 courtyard (12.89) + 0.57 gap + the 6.04 mm under the core board
CORE_EDGE = HEIGHT - 6.04
ROW_ODD = HEIGHT - 1.70       # U7's inner row (pins 1, 3, ...), 1.7 mm from this board's edge
ROW_EVEN = HEIGHT - 4.24      # U7's outer row (pins 2, 4, ...), 1.8 mm from the core board's edge
COL_1 = 2.68                  # pins 1 / 2; pins 63 / 64 are 78.74 mm to the right
J2_X = 23.54                  # pad 1 socket: DB9 pin 1 (the socket's centre is 5.54 mm to the left)
SHIFT = 48.1                  # pad 2's socket and its parts: the same, this far to the right
OUTLINE = (0.0, 0.0, WIDTH, HEIGHT)
KEEPOUT = []
PLACE = {
    "J1": (COL_1, ROW_ODD, 90),
    "J2": (J2_X, 10.54, 180),
    # between the sockets: the two buffers (inputs on the upper pin row, outputs towards the header), between them
    # the select buffer with its capacitor and the two pull-ups
    "U1": (36.6, 6.3, 270, "B"), "C1": (33.0, 12.6, 0, "B"),
    "U2": (47.4, 6.3, 270, "B"), "C4": (43.6, 12.6, 0, "B"),
    "U3": (42.0, 5.0, 90, "B"), "C2": (42.0, 1.4, 0, "B"), "R7": (41.2, 9.0, 90, "B"), "R15": (42.8, 9.0, 90, "B"),
    # under the front of socket 1: pull-ups (each above its socket pin), select resistor, supply capacitor
    "R6": (13.2, 5.3, 270, "B"), "R4": (15.1, 5.3, 270, "B"), "R3": (17.4, 5.3, 270, "B"),
    "R2": (20.6, 5.3, 270, "B"), "R5": (22.5, 5.3, 270, "B"), "R1": (24.4, 5.3, 270, "B"),
    "R8": (19.0, 1.8, 0, "B"), "C3": (9.6, 8.6, 90, "B"),
    # bulk capacitor at the 5 V pins
    "C6": (80.5, 12.8, 0, "B"),
}
for _a, _b in (("J2", "J3"), ("R8", "R16"), ("C3", "C5")):
    PLACE[_b] = (PLACE[_a][0] + SHIFT,) + PLACE[_a][1:]
for _k in range(6):
    PLACE[f"R{9 + _k}"] = (PLACE[f"R{1 + _k}"][0] + SHIFT,) + PLACE[f"R{1 + _k}"][1:]
PLACE = {r: (v[0] + ORIGIN[0], v[1] + ORIGIN[1]) + v[2:] for r, v in PLACE.items()}
OUTLINE = (OUTLINE[0] + ORIGIN[0], OUTLINE[1] + ORIGIN[1], OUTLINE[2] + ORIGIN[0], OUTLINE[3] + ORIGIN[1])
