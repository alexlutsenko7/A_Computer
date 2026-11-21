# Stand for the L computer case: a stylized open hand. The case lies in the cupped palm, tilted
# towards the user; four curled fingertips stop it at the low end, the thumb stands beside it.
# Run: C:\Tools\cadquery_env\Scripts\python.exe hand.py   (in this folder; CadQuery 2.8)
# Output: out/L_hand.stl + .step, out/L_hand_assembly.step, out/hand*.svg
#
# Palm coordinates (mm), used to build everything: U across the hand, V from the fingertips to the
# wrist, W = normal of the palm. The case's bottom lies on W = 0, its closed short end at V = 0
# (the DB9 end is the high end and hangs over the wrist); U = 0 is the middle of the case.
# The finished hand is turned by TILT around U and cut off at the table.

import math
import os
import sys
import cadquery as cq
import case

# ---------------------------------------------------------------- the case (from case.py)
# outside width, length, height and corner radius
CASE_W = case.XR - case.XL + 2 * case.WALL
CASE_L = case.YT - case.YB + 2 * case.WALL
CASE_H = case.Z_CEIL + case.CEIL - case.Z_FLOOR + case.FLOOR
CASE_R = case.R_IN + case.WALL
# case coordinates of the point that lies at U = 0, V = 0, W = 0
CASE_X0 = (case.XL + case.XR) * case.HALF
CASE_Y0 = case.YB - case.WALL
CASE_Z0 = case.Z_FLOOR - case.FLOOR

# ---------------------------------------------------------------- pose
# tilt of the palm (the case's top side looks at the user)
TILT = 15.0
# thickness of the hand under the palm surface at the front of the fingertips
FRONT_T = 10.0
# play between the case and the hand, on every side
PLAY = 0.50
# the palm is cupped: its edge stands this much above the surface the case lies on
RIM = 3.00
# how far everything is built below the palm before the table cuts it off
DEEP = 90.0

# ---------------------------------------------------------------- fingers
# from the thumb side (index) to the other side (little finger): widths, heights of the tips
# above the palm surface
FINGER_W = [24.0, 24.0, 23.0, 20.0]
FINGER_H = [16.0, 19.0, 17.0, 13.0]
# gap between two fingers
FINGER_GAP = 3.00
# the fingers end inside the palm
FINGER_ROOT = 56.0
# thickness of a curled fingertip (in V), radii of its top (case side, outer side)
TIP_T = 11.0
TIP_R_IN = 4.00
TIP_R_OUT = 6.00
# rounding of the fingers' and the palm's edges
EDGE_R = 3.00

# ---------------------------------------------------------------- palm
# outline (U, V), counter-clockwise from the little finger's root; the hand is as wide as its fingers
HAND_HALF_W = (sum(FINGER_W) + 3 * FINGER_GAP) * case.HALF
PALM_V0 = 50.0
PALM_V1 = 140.0
PALM_MID_HALF_W = 52.0
PALM_MID_V = 98.0
WRIST_HALF_W = 36.0
# radii of the outline at the widest point and at the wrist
PALM_MID_R = 40.0
WRIST_R = 12.0

# ---------------------------------------------------------------- thumb
# axis of the thumb from its root in the palm to the tip beside the case, radius
THUMB_ROOT = (34.0, 108.0)
THUMB_TIP = (58.0, 54.0)
THUMB_R = 11.5
# the raised tip beside the case: a block from THUMB_V0 with a flat top up to THUMB_V_TOP, then
# 45 degrees down to the rim, because the case's sockets (and their plugs) begin at V = 70
THUMB_H = 14.0
THUMB_V0 = 43.0
THUMB_V_TOP = 55.0
THUMB_TIP_W = 13.5
# radii of the block's top: front, start of the slope
THUMB_R_FRONT = 5.00
THUMB_R_BACK = 6.00
# from here on (V) and above this height (W) the plugs need the room beside the case
PLUG_V0 = 70.0
PLUG_W0 = 5.00

# ---------------------------------------------------------------- output
OUT_DIR = "out"
STL_TOL = 0.02
STL_ANG = 0.2
VOL_EPS = 0.01
EPS = 0.01
SVG_SIZE = 900
HALF_TURN = 180.0


def profile_prism(a_vw, f_u0, f_u1, a_round):
# a solid from an outline in the (V, W) plane, between two U positions; a_round = list of
# (radius, list of corner points) rounded before the extrusion
    s_wire = None
    s_solid = None
    s_wire = cq.Wire.makePolygon([cq.Vector(f_u0, f_v, f_w) for (f_v, f_w) in a_vw], close=True)
    for (f_r, a_pts) in a_round:
        s_wire = round_at(s_wire, [(f_u0, f_v, f_w) for (f_v, f_w) in a_pts], f_r)
    s_solid = cq.Solid.extrudeLinear(cq.Face.makeFromWires(s_wire), cq.Vector(f_u1 - f_u0, 0, 0))
    return s_solid


def plan_prism(a_uv, f_w0, f_w1, a_round):
# a solid from an outline in the (U, V) plane, between two W levels; a_round as in profile_prism
    s_wire = None
    s_solid = None
    s_wire = cq.Wire.makePolygon([cq.Vector(f_u, f_v, f_w0) for (f_u, f_v) in a_uv], close=True)
    for (f_r, a_pts) in a_round:
        s_wire = round_at(s_wire, [(f_u, f_v, f_w0) for (f_u, f_v) in a_pts], f_r)
    s_solid = cq.Solid.extrudeLinear(cq.Face.makeFromWires(s_wire), cq.Vector(0, 0, f_w1 - f_w0))
    return s_solid


def round_at(s_wire, a_pts, f_r):
# round the corners of a flat wire that lie at the given points
    as_vtx = []
    s_out = None
    for s_vtx in s_wire.Vertices():
        for t_pt in a_pts:
            if (s_vtx.Center() - cq.Vector(*t_pt)).Length < EPS:
                as_vtx.append(s_vtx)
    s_out = s_wire.fillet2D(f_r, as_vtx)
    return s_out


def finger(f_u0, f_u1, f_h):
# one finger between two U positions: a bar under the case, the tip curled up in front of the case
    a_vw = []
    as_edges = []
    s_part = None
    f_va = -PLAY
    f_vb = -PLAY - TIP_T
# outline: top of the bar, inner side of the tip, top of the tip, front, bottom
    a_vw = [(FINGER_ROOT, RIM), (f_va, RIM), (f_va, f_h), (f_vb, f_h), (f_vb, -DEEP), (FINGER_ROOT, -DEEP)]
    s_part = profile_prism(a_vw, f_u0, f_u1, [(TIP_R_IN, [(f_va, f_h)]), (TIP_R_OUT, [(f_vb, f_h)])])
# round both long sides: every edge of the two side faces but the bottom and the root
    for s_edge in s_part.Edges():
        t_c = s_edge.Center()
        if (abs(t_c.x - f_u0) < EPS) or (abs(t_c.x - f_u1) < EPS):
            if (t_c.z > -DEEP + EPS) and (t_c.y < FINGER_ROOT - EPS):
                as_edges.append(s_edge)
    s_part = s_part.fillet(EDGE_R, as_edges)
    return s_part


def fingers():
# the four fingers, index first (thumb side = +U)
    as_parts = []
    s_all = None
    f_u = HAND_HALF_W
    for (f_w, f_h) in zip(FINGER_W, FINGER_H):
        as_parts.append(finger(f_u - f_w, f_u, f_h))
        f_u = f_u - f_w - FINGER_GAP
    s_all = case.fuse_all(as_parts)
    return s_all


def palm():
# the palm: front edge at the fingers' roots, widest in the middle, narrow at the wrist
    a_uv = []
    as_edges = []
    s_part = None
    f_h = HAND_HALF_W
    f_m = PALM_MID_HALF_W
    f_w = WRIST_HALF_W
    a_uv = [(-f_h, PALM_V0), (f_h, PALM_V0), (f_m, PALM_MID_V), (f_w, PALM_V1), (-f_w, PALM_V1),
            (-f_m, PALM_MID_V)]
    s_part = plan_prism(a_uv, -DEEP, RIM, [(PALM_MID_R, [(f_m, PALM_MID_V), (-f_m, PALM_MID_V)]),
                                           (WRIST_R, [(f_w, PALM_V1), (-f_w, PALM_V1)])])
# round the upper edge, but not at the front where the fingers join
    for s_edge in s_part.Edges():
        t_c = s_edge.Center()
        if (abs(t_c.z - RIM) < EPS) and (t_c.y > PALM_V0 + EPS):
            as_edges.append(s_edge)
    s_part = s_part.fillet(EDGE_R, as_edges)
    return s_part


def capsule(f_w0, f_w1):
# the thumb's outline (two round ends, straight sides) as a solid between two W levels
    a_uv = []
    s_part = None
    f_du = THUMB_TIP[0] - THUMB_ROOT[0]
    f_dv = THUMB_TIP[1] - THUMB_ROOT[1]
    f_len = math.hypot(f_du, f_dv)
# unit vector across the axis, scaled to the radius
    f_pu = -f_dv / f_len * THUMB_R
    f_pv = f_du / f_len * THUMB_R
    a_uv = [(THUMB_ROOT[0] + f_pu, THUMB_ROOT[1] + f_pv), (THUMB_ROOT[0] - f_pu, THUMB_ROOT[1] - f_pv),
            (THUMB_TIP[0] - f_pu, THUMB_TIP[1] - f_pv), (THUMB_TIP[0] + f_pu, THUMB_TIP[1] + f_pv)]
    s_part = case.fuse_all([plan_prism(a_uv, f_w0, f_w1, []),
                            case.cyl(THUMB_ROOT[0], THUMB_ROOT[1], 2 * THUMB_R, f_w0, f_w1),
                            case.cyl(THUMB_TIP[0], THUMB_TIP[1], 2 * THUMB_R, f_w0, f_w1)]).clean()
    return s_part


def thumb():
# the thumb: flat in the palm, its tip stands up beside the case
    a_vw = []
    as_edges = []
    s_low = None
    s_high = None
    s_part = None
    f_u0 = CASE_W * case.HALF + PLAY
    f_u1 = f_u0 + THUMB_TIP_W
    f_v1 = THUMB_V_TOP + THUMB_H - RIM
    s_low = capsule(-DEEP, RIM)
# the raised tip: front, flat top, slope down to the rim; it stands on the thumb and the palm
    a_vw = [(THUMB_V0, 0), (THUMB_V0, THUMB_H), (THUMB_V_TOP, THUMB_H), (f_v1, RIM), (f_v1, 0)]
    s_high = profile_prism(a_vw, f_u0, f_u1, [(THUMB_R_FRONT, [(THUMB_V0, THUMB_H)]),
                                              (THUMB_R_BACK, [(THUMB_V_TOP, THUMB_H)])])
# round its outer side (not the side at the case, not the bottom)
    for s_edge in s_high.Edges():
        t_c = s_edge.Center()
        if (abs(t_c.x - f_u1) < EPS) and (t_c.z > EPS):
            as_edges.append(s_edge)
    s_high = s_high.fillet(EDGE_R, as_edges)
    s_part = s_low.fuse(s_high)
    return s_part


def pocket():
# the room of the case (with play) above the palm surface, open towards the wrist and upwards
    a_uv = []
    s_part = None
    f_h = CASE_W * case.HALF + PLAY
    a_uv = [(-f_h, -PLAY), (f_h, -PLAY), (f_h, case.BIG), (-f_h, case.BIG)]
    s_part = plan_prism(a_uv, 0, case.BIG, [(CASE_R + PLAY, [(-f_h, -PLAY), (f_h, -PLAY)])])
    return s_part


def table_z():
# level of the table in the turned palm coordinates: FRONT_T under the fingertips' front edge
    f_z = 0.0
    f_z = -(PLAY + TIP_T) * math.sin(math.radians(TILT)) - FRONT_T
    return f_z


def stand_up(s_shape):
# from palm coordinates to the table: tilt around U, table at Z = 0
    s_out = None
    s_out = s_shape.rotate(cq.Vector(0, 0, 0), cq.Vector(1, 0, 0), TILT)
    s_out = s_out.translate(cq.Vector(0, 0, -table_z()))
    return s_out


def hand():
# the whole hand in palm coordinates, cut off at the table
    s_pocket = None
    s_part = None
    s_below = None
    s_pocket = pocket()
    s_part = case.fuse_all([palm(), fingers(), thumb()]).cut(s_pocket)
# everything under the table: a big box, turned back into palm coordinates
    s_below = case.box(-case.BIG, case.BIG, -case.BIG, case.BIG, -case.BIG, table_z())
    s_below = s_below.rotate(cq.Vector(0, 0, 0), cq.Vector(1, 0, 0), -TILT)
    s_part = s_part.cut(s_below).clean()
    return s_part


def case_body():
# the closed case (both halves) in palm coordinates
    s_shell = None
    s_cut = None
    s_body = None
    s_shell = case.prism(case.WALL, case.Z_FLOOR - case.FLOOR, case.Z_CEIL + case.CEIL).cut(
        case.prism(0, case.Z_FLOOR, case.Z_CEIL))
    s_cut = case.cutters()
    s_body = case.bottom_half(s_shell, s_cut).fuse(case.top_half(s_shell, s_cut))
    s_body = s_body.translate(cq.Vector(-CASE_X0, -CASE_Y0, -CASE_Z0))
    return s_body


def main():
    s_hand = None
    s_case = None
    s_block = None
    s_plugs = None
    s_asm = None
    s_bb = None
    i_bad = 0
    f_h = CASE_W * case.HALF
    os.makedirs(OUT_DIR, exist_ok=True)
    s_hand = hand()
    s_case = case_body()
# fit check 1: the hand must not touch the case's outline (the outside of the case as a full block)
    s_block = case.prism(case.WALL, 0, CASE_H).translate(cq.Vector(-CASE_X0, -CASE_Y0, 0))
    f_vol = case.overlap(s_hand, s_block)
    print("overlap hand / case: %.3f mm3" % f_vol)
    if f_vol > VOL_EPS:
        i_bad = i_bad + 1
# fit check 2: the room of the plugs beside the case and behind it must be free
    s_plugs = case.fuse_all([case.box(-case.BIG, -f_h, PLUG_V0, case.BIG, PLUG_W0, case.BIG),
                             case.box(f_h, case.BIG, PLUG_V0, case.BIG, PLUG_W0, case.BIG),
                             case.box(-case.BIG, case.BIG, CASE_L, case.BIG, 0, case.BIG)])
    f_vol = case.overlap(s_hand, s_plugs)
    print("overlap hand / room of the plugs: %.3f mm3" % f_vol)
    if f_vol > VOL_EPS:
        i_bad = i_bad + 1
# on the table
    s_hand = stand_up(s_hand)
    s_case = stand_up(s_case)
    s_bb = s_hand.BoundingBox()
    print("hand: %d solid(s), %.1f x %.1f x %.1f mm, %.0f cm3 (solid)"
          % (len(s_hand.Solids()), s_bb.xlen, s_bb.ylen, s_bb.zlen, s_hand.Volume() / 1000.0))
    print("with the case: %.1f mm high" % s_case.BoundingBox().zmax)
# files: the hand as it stands (= print orientation), and with the case for a look in a CAD program
    s_hand.exportStep(os.path.join(OUT_DIR, "L_hand.step"))
    s_hand.exportStl(os.path.join(OUT_DIR, "L_hand.stl"), STL_TOL, STL_ANG)
    s_asm = cq.Assembly()
    s_asm.add(s_hand, name="hand", color=cq.Color(0.85, 0.70, 0.55))
    s_asm.add(s_case, name="case", color=cq.Color(0.25, 0.25, 0.28))
    s_asm.save(os.path.join(OUT_DIR, "L_hand_assembly.step"))
# pictures
    case.picture(s_hand, "hand.svg", (1.0, -1.4, 1.2))
    case.picture(s_hand, "hand_back.svg", (-1.2, 1.2, 1.0))
    case.picture(s_hand.fuse(s_case), "hand_with_case.svg", (1.0, -1.4, 1.2))
    case.picture(s_hand.fuse(s_case), "hand_with_case_side.svg", (1.0, 0, 0))
    if i_bad == 0:
        print("FIT CHECK PASS")
    else:
        print("FIT CHECK FAIL: %d" % i_bad)
    return i_bad


if __name__ == "__main__":
    sys.exit(main())
