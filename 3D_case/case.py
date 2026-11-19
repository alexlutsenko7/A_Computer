# L computer case: QMTECH 10CL025 core board soldered on top of the I/O board revision 2.
# Run: C:\Tools\cadquery_env\Scripts\python.exe case.py   (in this folder; CadQuery 2.8)
# Output: out/L_case_bottom.*, out/L_case_top.* (STEP + STL), out/L_case_assembly.step, out/*.svg
#
# Coordinates (mm): X = KiCad x - 50.95, Y = 155.40 - KiCad y, Z = 0 at the I/O board's bottom side.
# The I/O board covers X 0..84.1, Y 0..83.43; J1 is at Y = 0, the DB9 sockets are at Y = 83.43.
# The core board hangs over the J1 edge towards -Y, 3 mm above the I/O board.

import os
import sys
import cadquery as cq

# ---------------------------------------------------------------- boards (from the KiCad board file)
# I/O board outline
IO_X1 = 84.10
IO_Y1 = 83.43
# board thickness (both boards)
PCB_T = 1.60
# mounting holes H1..H4 of the I/O board (3.2 mm)
HOLES = [(20.31, 52.46), (65.40, 23.21), (31.54, 10.76), (47.55, 46.40)]
# core board: 84.1 x 67.1, U8 outer row 1.8 mm from its edge, soldered into J1 (row at Y = 4.24)
CORE_X0 = 0.18
CORE_X1 = 84.28
CORE_Y0 = -61.06
CORE_Y1 = 6.04
# gap between the top side of the I/O board and the bottom side of the core board (measured by the
# user, 2026-11-19)
CORE_GAP = 3.00
# bottom and top side of the core board
CORE_ZB = PCB_T + CORE_GAP
CORE_ZT = CORE_ZB + PCB_T
# the core board's DC jack: 9.5 mm high, in line with the board edge on the VGA side (user's
# measurements), not used, behind a closed wall; its position along the edge is from a photo
JACK_OVERHANG = 0.00
JACK_Y0 = -47.60
JACK_Y1 = -37.80
JACK_H = 9.50
JACK_LEN = 14.20
# the core board's JTAG header (box header at the other short edge), only for the fit check
JTAG_X0 = 74.50
JTAG_Y0 = -46.00
JTAG_Y1 = -25.00
JTAG_H = 9.20

# ---------------------------------------------------------------- case body
# wall, floor and ceiling thickness
WALL = 2.00
FLOOR = 2.00
CEIL = 2.00
# clearance between a board edge and the inner wall
EDGE_GAP = 0.60
# the DB9 bodies stand 0.47 mm over the board edge: the wall behind them is 0.77 mm from the edge
DB9_GAP = 0.77
# room behind the core board's far edge (for the locating tongues)
FAR_GAP = 2.00
# room for the solder side: header pins (up to 4.5 mm) and DB9 legs (3.8 mm) under the I/O board
STANDOFF = 5.00
# free height above the DC jack
TOP_GAP = 0.80
# inner corner radius (the outer one is this + WALL)
R_IN = 1.00
# inner faces of the walls
XL = -EDGE_GAP
XR = CORE_X1 + EDGE_GAP
YT = IO_Y1 + DB9_GAP
YB = CORE_Y0 - FAR_GAP
# levels: inner floor, inner ceiling, the joint between the two halves (= top side of the I/O board)
Z_FLOOR = -STANDOFF
Z_CEIL = CORE_ZT + JACK_H + TOP_GAP
Z_SPLIT = PCB_T
# a length that is longer than anything in the case (cutting tools)
BIG = 400.0

# ---------------------------------------------------------------- board supports
# bottom posts under the four holes, with a pin through the hole; the pin stands PIN_H above the
# board and is melted down onto it (heat staking), which fixes the board to the bottom half
POST_D = 7.00
PIN_D = 2.80
PIN_H = 2.50
# supports under / over the core board's free edge (the empty U7 strip): centres, width, depth
RIB_X = [12.0, 42.0, 72.0]
RIB_W = 8.00
RIB_DEPTH = 3.50
# they do not clamp the board: gaps below and above it
RIB_GAP_LOW = 0.30
RIB_GAP_HIGH = 0.50
# tongues of the top half that reach into the bottom half: thickness, depth, play, height in the top
TNG_T = 1.20
TNG_DOWN = 2.50
TNG_PLAY = 0.20
TNG_UP = 3.00
# tongues on the far wall (between the ribs) and on both side walls beside the core board; the side
# ones pass under the core board's edge, so their glued part is lower
TNG_FAR = [(20.0, 34.0), (50.0, 64.0)]
TNG_SIDE = (-58.0, -42.0)
TNG_UP_SIDE = 2.50

# ---------------------------------------------------------------- openings
# every opening is cut through the wall; a pocket thins the wall around it to POCKET_LEFT so that a
# plug's body comes close to the socket
POCKET_LEFT = 1.00
# lower edge of the pockets (below the joint: plug bodies are taller than the sockets)
POCKET_Z0 = -1.00
# D-sub (DB9 male, VGA): flange 30.8 wide, shell top 10.4 above the board
DSUB_W = 31.40
DSUB_H = 10.90
DSUB_POCKET_W = 35.60
DSUB_POCKET_H = 15.20
# USB-A (USB-302-T): 14.5 wide at the lips, 7.0 high
USBA_W = 15.20
USBA_H = 7.40
USBA_POCKET_W = 20.00
USBA_POCKET_H = 9.60
# USB-C: the opening takes the plug's body (12.35 x 6.5 at most), centre 1.63 above the board
USBC_W = 13.00
USBC_H = 7.20
USBC_ZC = 1.63
# microSD: wide and tall enough to pinch the card; its upper end meets the VGA opening
SD_W = 14.56
SD_Z0 = -1.40
SD_Z1 = 5.60
# audio jack PJ-320D: barrel centre 2.5 above the board
JACK35_W = 6.40
JACK35_ZC = 2.50
JACK35_POCKET_W = 13.00
JACK35_POCKET_H = 9.40
# USB-A J8 and USB-C stand side by side: the 1 mm of wall between their openings is cut away
J8_J5_Y0 = 23.00
J8_J5_Y1 = 24.60
# ribs of the top half behind the narrow wall strips between two openings: they run from the wall
# into the gaps between the sockets (DB9 / DB9, DB9 / audio jack, VGA / USB-A)
RIB_T = [(32.25, 34.65), (66.45, 68.35)]
RIB_L = [(52.45, 54.05)]
RIB_IN = 4.50
RIB_Z0 = PCB_T + 0.30
# positions along the walls (centres)
J4_X = 16.23
J6_X = 50.63
J3_X = 71.99
J9_Y = 61.70
J2_Y = 36.60
J7_Y = 13.52
J5_Y = 30.90
J8_Y = 15.83

# ---------------------------------------------------------------- output
OUT_DIR = "out"
BOARD_STEP = os.path.join("ref", "io_board_r2.step")
# the board model's origin in case coordinates
BOARD_DX = -50.95
BOARD_DY = 155.40
STL_TOL = 0.02
STL_ANG = 0.2
# interference below this volume (mm3) is numerical noise
VOL_EPS = 0.01
HALF = 0.5
SVG_SIZE = 900


def box(f_x0, f_x1, f_y0, f_y1, f_z0, f_z1):
# a box from its two corners
    s_box = cq.Solid.makeBox(f_x1 - f_x0, f_y1 - f_y0, f_z1 - f_z0, cq.Vector(f_x0, f_y0, f_z0))
    return s_box


def cyl(f_x, f_y, f_d, f_z0, f_z1):
# an upright cylinder
    s_cyl = cq.Solid.makeCylinder(f_d * HALF, f_z1 - f_z0, cq.Vector(f_x, f_y, f_z0), cq.Vector(0, 0, 1))
    return s_cyl


def fuse_all(as_parts):
# union of a list of solids
    s_sum = as_parts[0]
    for s_part in as_parts[1:]:
        s_sum = s_sum.fuse(s_part)
    return s_sum


def prism(f_grow, f_z0, f_z1):
# the case outline (inner walls grown by f_grow) as a solid between two levels
    a_pts = []
    s_wire = None
    s_solid = None
# inner outline: a rectangle, counter-clockwise
    a_pts = [(XR, YB), (XR, YT), (XL, YT), (XL, YB)]
    s_wire = cq.Wire.makePolygon([cq.Vector(f_x, f_y, f_z0) for (f_x, f_y) in a_pts], close=True)
    s_wire = s_wire.fillet2D(R_IN, s_wire.Vertices())
# the outer outline is the inner one moved out by the wall thickness (round corners)
    if f_grow > 0:
        s_wire = s_wire.offset2D(f_grow, "arc")[0]
    s_solid = cq.Solid.extrudeLinear(cq.Face.makeFromWires(s_wire), cq.Vector(0, 0, f_z1 - f_z0))
    return s_solid


def wall_cut(c_wall, f_c, f_w, f_z0, f_z1, f_left):
# a cutting box in wall 'T' (DB9 side), 'L' (VGA side) or 'R' (USB-C side), centred at f_c along the
# wall; f_left = 0 cuts through, otherwise that much of the wall is left (pocket from outside)
    s_cut = None
    f_a = f_c - f_w * HALF
    f_b = f_c + f_w * HALF
    f_in = f_left - EDGE_GAP
# the box starts inside the wall (pocket) or inside the case (opening) and ends far outside
    if c_wall == "T":
        s_cut = box(f_a, f_b, YT + f_in, YT + BIG, f_z0, f_z1)
    elif c_wall == "L":
        s_cut = box(XL - BIG, XL - f_in, f_a, f_b, f_z0, f_z1)
    else:
        s_cut = box(XR + f_in, XR + BIG, f_a, f_b, f_z0, f_z1)
    return s_cut


def cutters():
# all openings and pockets as one solid
    as_cut = []
    s_all = None
    f_zb = Z_SPLIT
# the two joystick sockets and the VGA socket: opening for flange, shell and jack screws + pocket
    for (c_wall, f_c) in (("T", J4_X), ("T", J6_X), ("L", J2_Y)):
        as_cut.append(wall_cut(c_wall, f_c, DSUB_W, f_zb, f_zb + DSUB_H, 0))
        as_cut.append(wall_cut(c_wall, f_c, DSUB_POCKET_W, POCKET_Z0, f_zb + DSUB_POCKET_H, POCKET_LEFT))
# the two USB-A sockets
    for (c_wall, f_c) in (("L", J9_Y), ("R", J8_Y)):
        as_cut.append(wall_cut(c_wall, f_c, USBA_W, f_zb, f_zb + USBA_H, 0))
        as_cut.append(wall_cut(c_wall, f_c, USBA_POCKET_W, POCKET_Z0, f_zb + USBA_POCKET_H, POCKET_LEFT))
# USB-C: one opening for the whole plug
    as_cut.append(wall_cut("R", J5_Y, USBC_W, f_zb + USBC_ZC - USBC_H * HALF, f_zb + USBC_ZC + USBC_H * HALF, 0))
    as_cut.append(wall_cut("R", (J8_J5_Y0 + J8_J5_Y1) * HALF, J8_J5_Y1 - J8_J5_Y0, f_zb, f_zb + USBA_H, 0))
# microSD card
    as_cut.append(wall_cut("L", J7_Y, SD_W, SD_Z0, SD_Z1, 0))
# audio jack: slot with a round top around the barrel + pocket for the plug
    as_cut.append(wall_cut("T", J3_X, JACK35_W, f_zb, f_zb + JACK35_ZC, 0))
    as_cut.append(cq.Solid.makeCylinder(JACK35_W * HALF, BIG, cq.Vector(J3_X, YT - EDGE_GAP, f_zb + JACK35_ZC),
                                        cq.Vector(0, 1, 0)))
    as_cut.append(wall_cut("T", J3_X, JACK35_POCKET_W, POCKET_Z0, f_zb + JACK35_POCKET_H, POCKET_LEFT))
    s_all = fuse_all(as_cut)
    return s_all


def bottom_half(s_shell, s_cut):
# the bottom half: tray up to the top side of the I/O board, posts with pins, core board supports
    as_add = []
    s_part = None
    s_part = s_shell.intersect(box(-BIG, BIG, -BIG, BIG, -BIG, Z_SPLIT))
# posts under the four holes of the I/O board, each with a pin through the hole
    for (f_x, f_y) in HOLES:
        as_add.append(cyl(f_x, f_y, POST_D, Z_FLOOR, 0))
        as_add.append(cyl(f_x, f_y, PIN_D, 0, PCB_T + PIN_H))
# ribs from the far wall under the core board's free edge
    for f_x in RIB_X:
        as_add.append(box(f_x - RIB_W * HALF, f_x + RIB_W * HALF, YB, CORE_Y0 + RIB_DEPTH,
                          Z_FLOOR, CORE_ZB - RIB_GAP_LOW))
    s_part = fuse_all([s_part] + as_add).cut(s_cut).clean()
    return s_part


def top_half(s_shell, s_cut):
# the top half: walls above the I/O board, core board hold-downs, tongues
    as_add = []
    s_part = None
    s_part = s_shell.intersect(box(-BIG, BIG, -BIG, BIG, Z_SPLIT, BIG))
# ribs from the ceiling over the core board's free edge
    for f_x in RIB_X:
        as_add.append(box(f_x - RIB_W * HALF, f_x + RIB_W * HALF, YB, CORE_Y0 + RIB_DEPTH,
                          CORE_ZT + RIB_GAP_HIGH, Z_CEIL))
# tongues on the far wall: glued part above the joint, free part (with play) below it
    for (f_a, f_b) in TNG_FAR:
        as_add.append(box(f_a, f_b, YB, YB + TNG_PLAY + TNG_T, Z_SPLIT, Z_SPLIT + TNG_UP))
        as_add.append(box(f_a, f_b, YB + TNG_PLAY, YB + TNG_PLAY + TNG_T, Z_SPLIT - TNG_DOWN, Z_SPLIT))
# ribs behind the narrow wall strips between the openings
    for (f_a, f_b) in RIB_T:
        as_add.append(box(f_a, f_b, YT - RIB_IN, YT, RIB_Z0, Z_CEIL))
    for (f_a, f_b) in RIB_L:
        as_add.append(box(XL, XL + RIB_IN, f_a, f_b, RIB_Z0, Z_CEIL))
# the same on the two side walls, under the core board's edges
    f_t = TNG_PLAY + TNG_T
    f_zu = Z_SPLIT + TNG_UP_SIDE
    f_zd = Z_SPLIT - TNG_DOWN
    as_add.append(box(XL, XL + f_t, TNG_SIDE[0], TNG_SIDE[1], Z_SPLIT, f_zu))
    as_add.append(box(XL + TNG_PLAY, XL + f_t, TNG_SIDE[0], TNG_SIDE[1], f_zd, Z_SPLIT))
    as_add.append(box(XR - f_t, XR, TNG_SIDE[0], TNG_SIDE[1], Z_SPLIT, f_zu))
    as_add.append(box(XR - f_t, XR - TNG_PLAY, TNG_SIDE[0], TNG_SIDE[1], f_zd, Z_SPLIT))
    s_part = fuse_all([s_part] + as_add).cut(s_cut).clean()
    return s_part


def core_board():
# the core board with its two tall parts, as blocks (fit check and pictures)
    s_core = None
    s_core = fuse_all([box(CORE_X0, CORE_X1, CORE_Y0, CORE_Y1, CORE_ZB, CORE_ZT),
                       box(CORE_X0 - JACK_OVERHANG, CORE_X0 - JACK_OVERHANG + JACK_LEN, JACK_Y0, JACK_Y1,
                           CORE_ZT, CORE_ZT + JACK_H),
                       box(JTAG_X0, CORE_X1, JTAG_Y0, JTAG_Y1, CORE_ZT, CORE_ZT + JTAG_H)])
    return s_core


def io_board():
# the I/O board with its parts (KiCad STEP export), moved into case coordinates; None if missing
    s_board = None
    if os.path.exists(BOARD_STEP):
        s_board = cq.importers.importStep(BOARD_STEP).val().translate(cq.Vector(BOARD_DX, BOARD_DY, 0))
    return s_board


def overlap(s_a, s_b):
# common volume of two shapes in mm3
    f_vol = 0.0
    f_vol = sum(s_solid.Volume() for s_solid in s_a.intersect(s_b).Solids())
    return f_vol


def picture(s_shape, c_name, t_dir):
# a line drawing of a shape seen from t_dir
    cq.exporters.export(cq.Workplane("XY").add(s_shape), os.path.join(OUT_DIR, c_name),
                        opt={"width": SVG_SIZE, "height": SVG_SIZE, "projectionDir": t_dir,
                             "showAxes": False, "showHidden": False})


def main():
    s_shell = None
    s_cut = None
    s_bottom = None
    s_top = None
    s_core = None
    s_board = None
    s_asm = None
    i_bad = 0
    os.makedirs(OUT_DIR, exist_ok=True)
# closed hollow body, then the two halves
    s_shell = prism(WALL, Z_FLOOR - FLOOR, Z_CEIL + CEIL).cut(prism(0, Z_FLOOR, Z_CEIL))
    s_cut = cutters()
    s_bottom = bottom_half(s_shell, s_cut)
    s_top = top_half(s_shell, s_cut)
    s_core = core_board()
    s_board = io_board()
# sizes
    s_bb = s_shell.BoundingBox()
    print("case outside: %.1f x %.1f x %.1f mm" % (s_bb.xlen, s_bb.ylen, s_bb.zlen))
    print("inside height above the I/O board: %.1f mm, above the core board: %.1f mm"
          % (Z_CEIL - PCB_T, Z_CEIL - CORE_ZT))
    print("bottom: %d solid(s), %.1f cm3; top: %d solid(s), %.1f cm3"
          % (len(s_bottom.Solids()), s_bottom.Volume() / 1000.0, len(s_top.Solids()), s_top.Volume() / 1000.0))
# fit check: nothing of the case may touch a board or a part
    for (c_what, s_obj) in (("core board", s_core), ("I/O board", s_board)):
        if s_obj is not None:
            for (c_half, s_half) in (("bottom", s_bottom), ("top", s_top)):
                f_vol = overlap(s_half, s_obj)
                print("overlap %s / %s: %.3f mm3" % (c_half, c_what, f_vol))
                if f_vol > VOL_EPS:
                    i_bad = i_bad + 1
    if overlap(s_bottom, s_top) > VOL_EPS:
        print("the two halves overlap")
        i_bad = i_bad + 1
# files: STEP as assembled; STL as printed (the top half upside down, ceiling on the bed)
    s_bottom.exportStep(os.path.join(OUT_DIR, "L_case_bottom.step"))
    s_top.exportStep(os.path.join(OUT_DIR, "L_case_top.step"))
    s_bottom.exportStl(os.path.join(OUT_DIR, "L_case_bottom.stl"), STL_TOL, STL_ANG)
    s_top.rotate(cq.Vector(0, 0, 0), cq.Vector(1, 0, 0), 180).exportStl(
        os.path.join(OUT_DIR, "L_case_top.stl"), STL_TOL, STL_ANG)
# assembly with the boards for a look in a CAD program
    s_asm = cq.Assembly()
    s_asm.add(s_bottom, name="case_bottom", color=cq.Color(0.25, 0.25, 0.28))
    s_asm.add(s_top, name="case_top", color=cq.Color(0.80, 0.80, 0.82, 0.5))
    s_asm.add(s_core, name="core_board_10CL025", color=cq.Color(0.1, 0.1, 0.1))
    if s_board is not None:
        s_asm.add(s_board, name="io_board_r2", color=cq.Color(0.0, 0.35, 0.3))
    s_asm.save(os.path.join(OUT_DIR, "L_case_assembly.step"))
# pictures
    picture(s_bottom, "bottom.svg", (-1.0, -1.2, 1.5))
    picture(s_top, "top_inside.svg", (-1.0, -1.2, -1.5))
    picture(fuse_all([s_bottom, s_top]), "closed_db9_vga.svg", (-1.2, 1.0, 0.9))
    picture(fuse_all([s_bottom, s_top]), "closed_usb.svg", (1.2, 1.0, 0.9))
    if i_bad == 0:
        print("FIT CHECK PASS")
    else:
        print("FIT CHECK FAIL: %d" % i_bad)
    return i_bad


if __name__ == "__main__":
    sys.exit(main())
