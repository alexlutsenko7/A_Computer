# Stand 2 for the L computer case: a human hand, life size, that holds the case upright, made after
# the user's two photos (2026-11-22). The joystick end of the case is down, the lid faces the viewer.
# The case lies with its underside on the palm of a left hand (user, 2026-11-22: the thumb on the
# viewer's left): the thumb lies flat on the USB-C wall above its two sockets, the little finger on
# the VGA wall above the microSD slot, index, middle and
# ring finger stand behind the case and their tips show above its upper end. The case's lower back
# edge sits on the heel of the hand. The forearm grows out of a rock, which is the base.
# Run: C:\Tools\cadquery_env\Scripts\python.exe hand2.py [voxel size in mm]   (in this folder)
# Output: out/L_hand2.stl, out/hand2_*.png
#
# The hand is not a CAD solid: it is a smooth surface around a skeleton (joints with radii, blended
# cones), sampled on a grid and turned into a mesh. Thumb and little finger are posed by a solver
# from the points they have to reach on the case. The case (with play) and the room of every plug
# are cut out.
#
# Design coordinates (mm): A = case X - middle (USB-C wall at +A, VGA wall at -A), V = distance from
# the joystick end along the case, W = height above the case's underside. They are a mirror image of
# the real thing (V runs against the case's Y).
# World coordinates: x = -A (to the viewer's right), y = to the back, z = up, table at z = 0.

import math
import os
import sys
import numpy as np
from scipy.optimize import least_squares
from scipy.spatial import ConvexHull
import cadquery as cq
import vtk
from vtk.util import numpy_support
import case

# ---------------------------------------------------------------- the case (from case.py)
CASE_W = case.XR - case.XL + 2 * case.WALL
CASE_L = case.YT - case.YB + 2 * case.WALL
CASE_H = case.Z_CEIL + case.CEIL - case.Z_FLOOR + case.FLOOR
CASE_R = case.R_IN + case.WALL
# case coordinates of the design origin: middle in X, the joystick end in Y, the underside in Z
CASE_XC = (case.XL + case.XR) * case.HALF
CASE_Y1 = case.YT + case.WALL
CASE_Z0 = case.Z_FLOOR - case.FLOOR
HALF_W = CASE_W * case.HALF

# ---------------------------------------------------------------- pose of the case
# the case leans back: angle between its long axis and the table
LEAN = 70.0
# height of the case's lowest edge above the table (room for the joystick plugs and their cables)
LIFT = 50.0
# play between the case and the hand
PLAY = 0.50

# ---------------------------------------------------------------- room of the plugs (design coordinates)
# under the joystick end: everything in front of W = PLUG_W0 is free, but for the strip beside the
# audio jack at the USB-C wall (the wall there has no opening)
PLUG_W0 = case.POCKET_Z0 - CASE_Z0 - 0.50
END_A1 = case.J3_X + case.JACK35_POCKET_W * case.HALF - CASE_XC + 0.50
# USB-C wall: USB-C and USB-A J8
SIDE_P_V0 = CASE_Y1 - (case.J5_Y + case.USBC_W * case.HALF) - 1.50
SIDE_P_V1 = CASE_Y1 - (case.J8_Y - case.USBA_POCKET_W * case.HALF) + 1.00
# VGA wall: USB-A J9, VGA, microSD (the thumb lies above the microSD slot)
SIDE_N_V0 = CASE_Y1 - (case.J9_Y + case.USBA_POCKET_W * case.HALF) - 1.00
SIDE_N_V1 = CASE_Y1 - (case.J7_Y - case.SD_W * case.HALF) + 1.00
# beside both walls the hand stays behind this level (plug bodies are taller than the sockets)
SIDE_W0 = 5.00

# ---------------------------------------------------------------- anatomy (mm, a man's hand, before scaling)
# hand coordinates: x from the wrist to the fingers, y to the thumb side, z out of the palm
# life size: a man's hand holds the case as in the photos
SCALE = 1.00
# knuckles (MCP joints): index, middle, ring, little finger
# (the little finger's knuckle is turned forward: the hand is cupped round the case)
MCP = [(92.0, 27.0, 0.0), (96.0, 5.0, -1.0), (91.0, -16.0, 0.0), (81.0, -38.0, 4.0)]
# lengths of the three bones of each finger
F_LEN = [(42.0, 24.0, 20.0), (46.0, 27.0, 21.0), (43.0, 25.0, 21.0), (33.0, 18.0, 19.0)]
# radii at knuckle, middle joint, end joint, fingertip
F_RAD = [(11.0, 10.2, 8.9, 7.6), (11.3, 10.4, 9.0, 7.7), (10.5, 9.7, 8.5, 7.3), (9.5, 8.6, 7.6, 6.6)]
# where the hand bones start at the wrist, and their radius there
CARPAL = [(8.0, 17.0, -3.0), (6.0, 5.0, -4.0), (6.0, -9.0, -3.0), (8.0, -22.0, -1.0)]
CARPAL_R = 12.0
# thumb: base joint, lengths of its three bones, radii
T_BASE = (20.0, 30.0, 0.0)
T_LEN = (46.0, 33.0, 28.0)
T_RAD = (15.5, 12.0, 10.8, 9.0)
# pads of the palm: (from, to, radius from, radius to)
PAD_LITTLE = ((10.0, -25.0, 2.0), (72.0, -34.0, 2.0), 13.0, 10.0)
PAD_MIDDLE = ((30.0, -2.0, 2.0), (80.0, -4.0, 2.0), 10.0, 9.0)
# the back of the hand between the bones
PAD_BACK = ((35.0, -4.0, -4.0), (80.0, -6.0, -3.0), 11.5, 10.5)
# the heel of the hand across the wrist: the case's lower back edge sits on it
PAD_HEEL = ((-3.0, 20.0, 9.0), (-3.0, -22.0, 9.0), 12.0, 12.0)
# skin between thumb and index finger: from the thumb's first bone (fraction of its length) to here
WEB_TO = (62.0, 25.0, 2.0)
WEB_AT = 0.60
WEB_R = 6.50
# wrist and forearm: half width, half thickness at the wrist and at the cut end; length
WRIST_HW = 31.0
WRIST_HT = 20.0
ARM_HW = 34.0
ARM_HT = 26.0
ARM_LEN = 90.0
# the forearm reaches its full size this far from the wrist
ARM_GROW = 95.0
# how soft the parts run into each other (mm): finger joints, fingers into the palm, palm, wrist
K_JOINT = 2.00
K_FINGER = 5.00
K_PALM = 12.0
K_WRIST = 12.0

# ---------------------------------------------------------------- pose of the hand
# the hand lies along the case: its x axis is V, its y axis (thumb side) is +A, z is W
# A of the hand's middle line, V of the wrist, W of the hand's bones (behind the case's underside)
HAND_A = -10.0
HAND_V = 2.00
HAND_W = -14.0
# joint angles of index, middle and ring finger (degrees): spread, knuckle, middle joint, end joint
# they lie against the underside and bend forward above the case's upper end
POSE = [(3.0, 3.0, 8.0, 28.0), (0.0, 2.0, 10.0, 28.0), (-3.0, 3.0, 8.0, 28.0)]
LITTLE = 3
# points the joints have to reach (design coordinates): middle joint, end joint, tip
# the little finger comes round the back edge onto the VGA wall, its tip at the upper corner
AIM_LITTLE = [(-53.8, 112.0, 4.0), (-53.3, 130.0, 8.0), (-52.3, 148.5, 11.0)]
# thumb: its knuckle stays behind the USB-C wall's sockets, the two outer bones cross the wall above
# the USB-A socket, the pad lies on the wall
AIM_THUMB = [(53.0, 58.0, -8.0), (56.5, 92.0, 1.0), (54.0, 118.0, 9.0)]
# fingernails: a thin plate that lies in the back of the last bone, flush with the skin at its root
# and standing a little proud at the fingertip (free edge), with a groove (nail fold) along its
# root and its two sides
# where the nail begins, in parts of the last bone's length
NAIL_U0 = 0.46
# how far it reaches past the bone's end, in parts of the fingertip's radius
NAIL_OVER = 0.50
# half width as an angle round the bone (rad), corner radius in parts of the half width
NAIL_ANG = 0.95
NAIL_CORNER = 0.45
# height of the plate above the skin at its free edge (mm), thickness of the plate (mm)
NAIL_LIFT = 0.50
NAIL_THICK = 1.10
# half width of the groove (mm); the groove ends this far before the free edge (mm)
NAIL_GROOVE = 0.65
NAIL_OPEN = 2.00
# size of the step towards the palm that makes the point "before" the last bone
NAIL_HINT = 0.30
# joint limits (degrees): spread, knuckle, middle joint, end joint; thumb joints
LIM_LO = (-24.0, -15.0, 0.0, 0.0)
LIM_HI = (24.0, 90.0, 110.0, 85.0)
THUMB_BEND = (60.0, 80.0)
# weights of the solver: bone lengths, limits
W_LEN = 5.00
W_LIM = 3.00
# first guess of the little finger's angles
LITTLE_START = (-15.0, 30.0, 30.0, 20.0)
# the forearm runs from the wrist down to the table, as steep as this bend of the wrist allows (degrees)
WRIST_BEND = 70.0
# ---------------------------------------------------------------- the rock (base)
# boulders in world coordinates: centre on the table, half sizes, number of faces, seed of the faces
ROCKS = [((0.0, 40.0), (70.0, 64.0, 30.0), 17, 7),
         ((57.0, 80.0), (30.0, 27.0, 22.0), 11, 11),
         ((-58.0, 6.0), (26.0, 23.0, 14.0), 9, 23)]
# each face is moved in by up to this part of the boulder's size; faces are tilted by up to this (rad)
ROCK_ROUGH = 0.26
ROCK_TILT = 0.25
# roundness of the rock's edges, soft run of the forearm into the rock
K_EDGE = 0.80
K_ROCK = 3.00
# golden angle (rad): spreads the faces evenly round the boulder
GOLDEN = 2.39996

# ---------------------------------------------------------------- mesh and output
# size of a grid cell (the first command line argument replaces it), cells per block, border
VOXEL = 0.60
BLOCK = 24
BORDER = 6.00
# blocks farther from the surface than this factor times their half diagonal are not sampled
SKIP = 1.60
FAR = 1.0e3
# triangles kept after thinning the mesh
TRI_KEEP = 400000
# weight of the closed case with both boards (g), density of the print (g/cm3) with its infill
CASE_MASS = 220.0
PRINT_DENSITY = 0.35
OUT_DIR = "out"
PIC_W = 1100
PIC_H = 900
PIC_ZOOM = 1.25
PIC_ZOOM_NAILS = 3.00
EPS = 1.0e-9


def unit(a_v):
# a vector scaled to length 1
    a_out = np.asarray(a_v, dtype=float)
    a_out = a_out / np.linalg.norm(a_out)
    return a_out


def rot(a_rv):
# rotation matrix from a rotation vector (axis * angle in rad)
    a_m = np.eye(3)
    f_ang = float(np.linalg.norm(a_rv))
    if f_ang > EPS:
        a_k = a_rv / f_ang
        a_x = np.array([[0, -a_k[2], a_k[1]], [a_k[2], 0, -a_k[0]], [-a_k[1], a_k[0], 0]])
        a_m = np.eye(3) + math.sin(f_ang) * a_x + (1 - math.cos(f_ang)) * (a_x @ a_x)
    return a_m


def frame():
# the hand's axes (columns x, y, z in design coordinates) and its wrist
    a_m = np.array([[0.0, 1.0, 0.0], [1.0, 0.0, 0.0], [0.0, 0.0, 1.0]])
    a_t = np.array([HAND_A, HAND_V, HAND_W])
    return (a_m, a_t)


def finger_joints(i_f, a_ang):
# the four joint points of a finger in hand coordinates (before scaling) from its four angles
    a_pts = [np.asarray(MCP[i_f], dtype=float)]
    f_abd = math.radians(a_ang[0])
    f_sum = 0.0
    a_d0 = np.array([math.cos(f_abd), math.sin(f_abd), 0.0])
# every joint bends the finger towards the palm (+z), in the plane of its first bone
    for i_k in range(3):
        f_sum = f_sum + math.radians(a_ang[1 + i_k])
        a_dir = a_d0 * math.cos(f_sum) + np.array([0.0, 0.0, 1.0]) * math.sin(f_sum)
        a_pts.append(a_pts[-1] + F_LEN[i_f][i_k] * a_dir)
    return a_pts


def bend(a_p0, a_p1, a_p2):
# angle (degrees) by which the line p0-p1-p2 is bent at p1
    a_u = unit(a_p1 - a_p0)
    a_w = unit(a_p2 - a_p1)
    f_ang = math.degrees(math.acos(max(-1.0, min(1.0, float(np.dot(a_u, a_w))))))
    return f_ang


def residuals(a_p):
# what the solver makes small: distances to the aimed points, bone length errors, limits
# a_p = the little finger's four angles, then the thumb's three joint points
    a_res = []
    (a_m, a_t) = frame()
# the little finger: joints at their aimed points, angles inside the limits
    a_ang = a_p[0:4]
    a_j = [a_t + SCALE * (a_m @ a_pt) for a_pt in finger_joints(LITTLE, a_ang)]
    for i_k in range(3):
        a_res.extend(a_j[1 + i_k] - np.asarray(AIM_LITTLE[i_k]))
    for i_k in range(4):
        a_res.append(W_LIM * max(0.0, LIM_LO[i_k] - a_ang[i_k]))
        a_res.append(W_LIM * max(0.0, a_ang[i_k] - LIM_HI[i_k]))
# thumb: three free points; bone lengths, aimed points, bend of its two joints
    a_th = [a_t + SCALE * (a_m @ np.asarray(T_BASE))]
    for i_k in range(3):
        a_th.append(a_p[4 + 3 * i_k:7 + 3 * i_k])
        a_res.extend(a_th[-1] - np.asarray(AIM_THUMB[i_k]))
        a_res.append(W_LEN * (np.linalg.norm(a_th[-1] - a_th[-2]) - T_LEN[i_k] * SCALE))
    a_res.append(W_LIM * max(0.0, bend(a_th[0], a_th[1], a_th[2]) - THUMB_BEND[0]))
    a_res.append(W_LIM * max(0.0, bend(a_th[1], a_th[2], a_th[3]) - THUMB_BEND[1]))
    return np.asarray(a_res, dtype=float)


def solve_pose():
# the pose: hand axes, wrist, joint points of the five fingers (hand coordinates) and the angles
    a_p0 = np.zeros(13)
    a_fing = []
    a_th = []
    a_ang_all = []
    s_sol = None
    (a_m, a_t) = frame()
# first guess: little finger half bent, thumb at its aimed points
    a_p0[0:4] = LITTLE_START
    a_p0[4:13] = np.asarray(AIM_THUMB).ravel()
    s_sol = least_squares(residuals, a_p0)
    a_ang_all = [np.asarray(t_ang) for t_ang in POSE] + [s_sol.x[0:4]]
    for i_f in range(4):
        a_fing.append(finger_joints(i_f, a_ang_all[i_f]))
# the thumb's points go back into hand coordinates (everything is built there)
    a_th = [np.asarray(T_BASE, dtype=float)]
    for i_k in range(3):
        a_th.append(a_m.T @ (s_sol.x[4 + 3 * i_k:7 + 3 * i_k] - a_t) / SCALE)
    return (a_m, a_t, a_fing, a_th, a_ang_all, s_sol)


def lean_axes():
# world direction of the design axes V and W (the A axis is world -x)
    f_s = math.sin(math.radians(LEAN))
    f_c = math.cos(math.radians(LEAN))
    a_v = np.array([0.0, f_c, f_s])
    a_w = np.array([0.0, -f_s, f_c])
    return (a_v, a_w)


def to_design(a_xyz):
# world points (N, 3) -> design coordinates
    (a_v, a_w) = lean_axes()
    a_rel = a_xyz - np.array([0.0, 0.0, LIFT])
    a_out = np.column_stack([-a_rel[:, 0], a_rel @ a_v, a_rel @ a_w])
    return a_out


def to_world(a_avw):
# design points (N, 3) -> world coordinates
    (a_v, a_w) = lean_axes()
    a_out = np.outer(a_avw[:, 1], a_v) + np.outer(a_avw[:, 2], a_w)
    a_out[:, 0] = -a_avw[:, 0]
    a_out[:, 2] = a_out[:, 2] + LIFT
    return a_out


def cone(a_q, a_a, a_b, f_ra, f_rb):
# distance to a round cone: spheres of radius f_ra at a_a and f_rb at a_b and what lies between
    a_ab = a_b - a_a
    a_t = np.clip(((a_q - a_a) @ a_ab) / float(a_ab @ a_ab), 0.0, 1.0)
    a_d = np.linalg.norm(a_q - a_a - np.outer(a_t, a_ab), axis=1) - (f_ra + a_t * (f_rb - f_ra))
    return a_d


def blend(a_d1, a_d2, f_k):
# union of two shapes with a soft joint of size f_k
    a_h = np.clip(case.HALF + case.HALF * (a_d2 - a_d1) / f_k, 0.0, 1.0)
    a_d = a_d2 * (1 - a_h) + a_d1 * a_h - f_k * a_h * (1 - a_h)
    return a_d


def box_dist(a_q, a_lo, a_hi, f_r):
# distance to a box given by two corners, edges rounded with f_r
    a_c = (np.asarray(a_lo) + np.asarray(a_hi)) * case.HALF
    a_h = (np.asarray(a_hi) - np.asarray(a_lo)) * case.HALF - f_r
    a_e = np.abs(a_q - a_c) - a_h
    a_d = np.linalg.norm(np.maximum(a_e, 0.0), axis=1) + np.minimum(a_e.max(axis=1), 0.0) - f_r
    return a_d


def arm_dist(a_q, a_dir, a_side):
# distance to wrist + forearm: an oval that grows from the wrist to the cut end
# a_dir = its axis (from the wrist), a_side = direction of its width; both in hand coordinates
    a_n = np.cross(a_dir, a_side)
    a_t = a_q @ a_dir
    a_f = np.clip(a_t / ARM_GROW, 0.0, 1.0)
    a_hw = WRIST_HW + a_f * (ARM_HW - WRIST_HW)
    a_ht = WRIST_HT + a_f * (ARM_HT - WRIST_HT)
# in front of the wrist the oval closes like an egg
    a_ax = np.minimum(a_t, 0.0) / WRIST_HT
    a_r = np.sqrt(((a_q @ a_side) / a_hw) ** 2 + ((a_q @ a_n) / a_ht) ** 2 + a_ax ** 2)
    a_d = (a_r - 1.0) * a_ht
    a_d = np.maximum(a_d, a_t - ARM_LEN)
    return a_d


def nail(a_q, a_p0, a_p1, a_p2, f_r1, f_r2):
# a fingernail on the bone a_p1..a_p2 (a_p0 = the joint before, it tells the back of the finger
# from its pad); f_r1, f_r2 = radii at the bone's ends
# returns two distances: to the nail's plate (added to the finger), to its groove (cut out)
    a_e = unit(a_p2 - a_p1)
    a_s = unit(np.cross(unit(a_p1 - a_p0), a_e))
    a_back = np.cross(a_e, a_s)
    f_len = float(np.linalg.norm(a_p2 - a_p1))
    f_u0 = NAIL_U0 * f_len
    f_u1 = f_len + NAIL_OVER * f_r2
    f_hl = (f_u1 - f_u0) * case.HALF
    f_hw = NAIL_ANG * (f_r1 + (f_r2 - f_r1) * (f_u0 + f_hl) / f_len)
    f_rc = NAIL_CORNER * f_hw
# the point in the bone's coordinates: along it, distance from its axis, arc length round it
    a_rel = a_q - a_p1
    a_u = a_rel @ a_e
    a_rho = np.sqrt((a_rel @ a_s) ** 2 + (a_rel @ a_back) ** 2)
    a_arc = f_hw / NAIL_ANG * np.arctan2(a_rel @ a_s, a_rel @ a_back)
# the skin's radius there (past the bone's end the plate runs straight on: the free edge)
    a_skin = f_r1 + (f_r2 - f_r1) * np.clip(a_u / f_len, 0.0, 1.0)
# the nail's outline on the skin: a rectangle with round corners
    a_ex = np.abs(a_u - f_u0 - f_hl) - f_hl + f_rc
    a_ey = np.abs(a_arc) - f_hw + f_rc
    a_out = np.sqrt(np.maximum(a_ex, 0.0) ** 2 + np.maximum(a_ey, 0.0) ** 2) + np.minimum(np.maximum(a_ex, a_ey), 0.0) - f_rc
# the plate rises from the skin's level at the root to NAIL_LIFT at the free edge
    a_top = a_skin + NAIL_LIFT * np.clip((a_u - f_u0) / (2 * f_hl), 0.0, 1.0)
    a_plate = np.maximum(a_out, np.maximum(a_rho - a_top, a_top - NAIL_THICK - a_rho))
# the groove follows the outline on the skin, but not round the free edge
    a_groove = np.sqrt(a_out ** 2 + (a_rho - a_skin) ** 2) - NAIL_GROOVE
    a_groove = np.maximum(a_groove, a_u - (f_u1 - NAIL_OPEN))
    return (a_plate, a_groove)


def nail_thumb(a_q, a_th):
# the thumb's nail: its last joint is nearly straight, so the back of the thumb is told by the
# bend of the joint before (a point is made that bends the same way)
    t_d = nail(a_q, a_th[2] - (a_th[1] - a_th[0]), a_th[2], a_th[3], T_RAD[2], T_RAD[3])
    return t_d


def hand_dist(a_q, s_pose):
# distance to the whole hand; a_q = points in hand coordinates (before scaling)
    (a_m, a_t, a_fing, a_th, a_arm) = s_pose[0:5]
    a_palm = None
    a_all = None
    a_nails = []
# the palm: the four hand bones, the pads, the thumb's first bone, the skin to the index finger
    for i_f in range(4):
        a_d = cone(a_q, np.asarray(CARPAL[i_f]), a_fing[i_f][0], CARPAL_R, F_RAD[i_f][0] + 0.5)
        a_palm = a_d if a_palm is None else blend(a_palm, a_d, K_PALM)
    for (t_a, t_b, f_ra, f_rb) in (PAD_LITTLE, PAD_MIDDLE, PAD_BACK, PAD_HEEL):
        a_palm = blend(a_palm, cone(a_q, np.asarray(t_a), np.asarray(t_b), f_ra, f_rb), K_PALM)
    a_palm = blend(a_palm, cone(a_q, a_th[0], a_th[1], T_RAD[0], T_RAD[1]), K_PALM)
    a_web = a_th[0] + WEB_AT * (a_th[1] - a_th[0])
    a_palm = blend(a_palm, cone(a_q, a_web, np.asarray(WEB_TO), WEB_R, WEB_R), K_PALM)
    a_palm = blend(a_palm, arm_dist(a_q, a_arm[0], a_arm[1]), K_WRIST)
    a_all = a_palm
# the fingers: three bones each, small joints between the bones, a soft run into the palm; two
# fingers that touch do not run into each other
    for i_f in range(4):
        a_fd = None
        for i_k in range(3):
            a_d = cone(a_q, a_fing[i_f][i_k], a_fing[i_f][i_k + 1], F_RAD[i_f][i_k], F_RAD[i_f][i_k + 1])
            a_fd = a_d if a_fd is None else blend(a_fd, a_d, K_JOINT)
        a_all = np.minimum(a_all, blend(a_palm, a_fd, K_FINGER))
# the nail's side is told by the way the finger bends (towards +z), also when its end joint is straight
        a_before = a_fing[i_f][2] - unit(a_fing[i_f][3] - a_fing[i_f][2]) + NAIL_HINT * np.array([0.0, 0.0, 1.0])
        a_nails.append(nail(a_q, a_before, a_fing[i_f][2], a_fing[i_f][3], F_RAD[i_f][2], F_RAD[i_f][3]))
    a_fd = blend(cone(a_q, a_th[1], a_th[2], T_RAD[1], T_RAD[2]),
                 cone(a_q, a_th[2], a_th[3], T_RAD[2], T_RAD[3]), K_JOINT)
    a_all = np.minimum(a_all, blend(a_palm, a_fd, K_FINGER))
# the thumb's last joint is nearly straight: its back is told by the bend of the joint before
    a_nails.append(nail_thumb(a_q, a_th))
# the nails: every plate is added, then every groove is cut
    for (a_plate, a_groove) in a_nails:
        a_all = np.minimum(a_all, a_plate)
    for (a_plate, a_groove) in a_nails:
        a_all = np.maximum(a_all, -a_groove)
    return a_all


def room_dist(a_d3):
# distance to everything the stand must not touch: the case with play, the room of the plugs
# a_d3 = points in design coordinates
    a_case = box_dist(a_d3[:, [0, 1]], (-HALF_W, 0.0), (HALF_W, CASE_L), CASE_R)
    a_case = np.maximum(a_case, np.maximum(-a_d3[:, 2], a_d3[:, 2] - CASE_H)) - PLAY
    a_big = case.BIG
# under the joystick end, beside the USB-C wall, beside the VGA wall
    a_end = box_dist(a_d3, (-HALF_W - 1.0, -a_big, PLUG_W0), (END_A1, 0.0, a_big), 0.0)
    a_sp = box_dist(a_d3, (HALF_W, SIDE_P_V0, SIDE_W0), (a_big, SIDE_P_V1, a_big), 0.0)
    a_sn = box_dist(a_d3, (-a_big, SIDE_N_V0, SIDE_W0), (-HALF_W, SIDE_N_V1, a_big), 0.0)
    a_d = np.minimum(np.minimum(a_case, a_end), np.minimum(a_sp, a_sn))
    return a_d


def rock_faces():
# the faces of every boulder: (centre, unit normals (N, 3), distances of the faces from the centre)
    a_out = []
    for (t_c, t_r, i_n, i_seed) in ROCKS:
        s_rnd = np.random.RandomState(i_seed)
        a_i = np.arange(i_n)
# normals spread over the upper half (none points down: the rock gets wider towards the table)
        a_up = (a_i + case.HALF) / i_n
        a_ang = a_i * GOLDEN + s_rnd.uniform(-ROCK_TILT, ROCK_TILT, i_n)
        a_up = np.clip(a_up + s_rnd.uniform(-ROCK_TILT, ROCK_TILT, i_n) * case.HALF, 0.0, 1.0)
        a_flat = np.sqrt(1.0 - a_up ** 2)
        a_nrm = np.column_stack([a_flat * np.cos(a_ang), a_flat * np.sin(a_ang), a_up])
# a face touches the boulder's ellipsoid, moved in by a random part
        a_h = np.linalg.norm(a_nrm * np.asarray(t_r), axis=1) * (1.0 - ROCK_ROUGH * s_rnd.uniform(0.0, 1.0, i_n))
        a_out.append((np.array([t_c[0], t_c[1], 0.0]), a_nrm, a_h))
    return a_out


G_ROCKS = rock_faces()


def rock_dist(a_xyz):
# distance to the rock (world points): every boulder is what lies behind all of its faces
    a_all = None
    for (a_c, a_nrm, a_h) in G_ROCKS:
        a_f = (a_xyz - a_c) @ a_nrm.T - a_h
# the largest face distance, with rounded edges
        a_max = a_f.max(axis=1)
        a_d = a_max + K_EDGE * np.log(np.exp((a_f - a_max[:, None]) / K_EDGE).sum(axis=1))
        a_all = a_d if a_all is None else np.minimum(a_all, a_d)
    return a_all


def model_dist(a_xyz, s_pose):
# the stand: hand and rock without the case, the plugs' room and what is under the table (world points)
    (a_m, a_t) = (s_pose[0], s_pose[1])
    a_d3 = to_design(a_xyz)
    a_q = ((a_d3 - a_t) @ a_m) / SCALE
    a_d = hand_dist(a_q, s_pose) * SCALE
    a_d = blend(a_d, rock_dist(a_xyz), K_ROCK)
    a_d = np.maximum(a_d, -room_dist(a_d3))
    a_d = np.maximum(a_d, -a_xyz[:, 2])
    return a_d


def arm_axes(a_m):
# the forearm in hand coordinates: its axis (from the wrist) and the direction of its width,
# which follows the width of the hand
    (a_v, a_w) = lean_axes()
    a_wm = np.column_stack([np.array([-1.0, 0.0, 0.0]), a_v, a_w])
    a_down = np.array([0.0, 0.0, -1.0])
# straight on from the hand (world), then turned towards "down" by the bend of the wrist
    a_on = -(a_wm @ a_m[:, 0])
    f_all = math.acos(max(-1.0, min(1.0, float(np.dot(a_on, a_down)))))
    f_turn = min(f_all, math.radians(WRIST_BEND))
    a_axis = unit(np.cross(a_on, a_down))
    a_dir_w = rot(a_axis * f_turn) @ a_on
# world vector -> design -> hand
    a_dir = unit((a_dir_w @ a_wm) @ a_m)
    a_side = np.array([0.0, 1.0, 0.0])
    a_side = unit(a_side - np.dot(a_side, a_dir) * a_dir)
    return (a_dir, a_side, a_dir_w)


def sample(s_pose, a_lo, a_hi, f_cell):
# the distance on a grid over the box a_lo..a_hi; blocks far from the surface are filled, not sampled
    a_n = np.ceil((a_hi - a_lo) / f_cell).astype(int) + 1
    a_grid = np.empty((a_n[0], a_n[1], a_n[2]), dtype=np.float32)
    f_half = BLOCK * f_cell * math.sqrt(3.0) * case.HALF
    for i_x in range(0, a_n[0], BLOCK):
        for i_y in range(0, a_n[1], BLOCK):
            for i_z in range(0, a_n[2], BLOCK):
                a_i0 = np.array([i_x, i_y, i_z])
                a_i1 = np.minimum(a_i0 + BLOCK, a_n)
                a_mid = a_lo + (a_i0 + a_i1 - 1) * case.HALF * f_cell
                f_d = float(model_dist(a_mid.reshape(1, 3), s_pose)[0])
                if abs(f_d) > SKIP * f_half:
                    a_grid[i_x:a_i1[0], i_y:a_i1[1], i_z:a_i1[2]] = math.copysign(FAR, f_d)
                else:
                    a_ax = [a_lo[i_k] + np.arange(a_i0[i_k], a_i1[i_k]) * f_cell for i_k in range(3)]
                    a_pts = np.stack(np.meshgrid(a_ax[0], a_ax[1], a_ax[2], indexing="ij"), axis=-1)
                    a_grid[i_x:a_i1[0], i_y:a_i1[1], i_z:a_i1[2]] = model_dist(
                        a_pts.reshape(-1, 3), s_pose).reshape(a_pts.shape[0:3])
    return a_grid


def mesh(a_grid, a_lo, f_cell):
# the surface of the sampled shape as triangles (largest connected piece, thinned, with normals)
    s_img = vtk.vtkImageData()
    s_arr = None
    s_out = None
    s_img.SetDimensions(a_grid.shape[0], a_grid.shape[1], a_grid.shape[2])
    s_img.SetOrigin(float(a_lo[0]), float(a_lo[1]), float(a_lo[2]))
    s_img.SetSpacing(f_cell, f_cell, f_cell)
    s_arr = numpy_support.numpy_to_vtk(np.clip(a_grid, -BORDER, BORDER).ravel(order="F"), deep=True)
    s_img.GetPointData().SetScalars(s_arr)
    s_iso = vtk.vtkFlyingEdges3D()
    s_iso.SetInputData(s_img)
    s_iso.SetValue(0, 0.0)
    s_iso.ComputeNormalsOff()
    s_con = vtk.vtkPolyDataConnectivityFilter()
    s_con.SetInputConnection(s_iso.GetOutputPort())
    s_con.SetExtractionModeToLargestRegion()
    s_con.Update()
    s_out = s_con.GetOutput()
# thin the mesh if it has more triangles than wanted
    if s_out.GetNumberOfCells() > TRI_KEEP:
        s_dec = vtk.vtkQuadricDecimation()
        s_dec.SetInputData(s_out)
        s_dec.SetTargetReduction(1.0 - TRI_KEEP / s_out.GetNumberOfCells())
        s_dec.Update()
        s_out = s_dec.GetOutput()
    s_nrm = vtk.vtkPolyDataNormals()
    s_nrm.SetInputData(s_out)
    s_nrm.SetFeatureAngle(50.0)
    s_nrm.AutoOrientNormalsOn()
    s_nrm.Update()
    s_out = s_nrm.GetOutput()
    return s_out


def case_mesh():
# the closed case as a mesh in world coordinates (pictures only)
    s_shell = case.prism(case.WALL, case.Z_FLOOR - case.FLOOR, case.Z_CEIL + case.CEIL).cut(
        case.prism(0, case.Z_FLOOR, case.Z_CEIL))
    s_cut = case.cutters()
    s_body = case.bottom_half(s_shell, s_cut).fuse(case.top_half(s_shell, s_cut))
    c_tmp = os.path.join(OUT_DIR, "_case_tmp.stl")
    s_body.exportStl(c_tmp, 0.05, 0.3)
    s_rd = vtk.vtkSTLReader()
    s_rd.SetFileName(c_tmp)
    s_rd.Update()
    s_poly = s_rd.GetOutput()
# case coordinates -> design -> world, point by point
    a_p = numpy_support.vtk_to_numpy(s_poly.GetPoints().GetData()).astype(float)
    a_d3 = np.column_stack([a_p[:, 0] - CASE_XC, CASE_Y1 - a_p[:, 1], a_p[:, 2] - CASE_Z0])
    s_poly.GetPoints().SetData(numpy_support.numpy_to_vtk(to_world(a_d3), deep=True))
    s_nrm = vtk.vtkPolyDataNormals()
    s_nrm.SetInputData(s_poly)
    s_nrm.SetFeatureAngle(30.0)
    s_nrm.AutoOrientNormalsOn()
    s_nrm.Update()
    os.remove(c_tmp)
    return s_nrm.GetOutput()


def picture(a_parts, c_name, a_from, f_zoom=PIC_ZOOM, a_at=None):
# a shaded picture of meshes [(mesh, colour)] seen from the direction a_from; a_at = the point in
# the middle of the picture (None = the middle of the meshes)
    s_ren = vtk.vtkRenderer()
    s_win = vtk.vtkRenderWindow()
    s_ren.SetBackground(1.0, 1.0, 1.0)
    for (s_poly, t_col) in a_parts:
        s_map = vtk.vtkPolyDataMapper()
        s_map.SetInputData(s_poly)
        s_map.ScalarVisibilityOff()
        s_act = vtk.vtkActor()
        s_act.SetMapper(s_map)
        s_act.GetProperty().SetColor(t_col[0], t_col[1], t_col[2])
        s_act.GetProperty().SetSpecular(0.15)
        s_ren.AddActor(s_act)
    s_win.SetOffScreenRendering(1)
    s_win.AddRenderer(s_ren)
    s_win.SetSize(PIC_W, PIC_H)
    s_cam = s_ren.GetActiveCamera()
    s_cam.SetFocalPoint(0.0, 0.0, 0.0)
    s_cam.SetPosition(a_from[0], a_from[1], a_from[2])
    s_cam.SetViewUp(0.0, 0.0, 1.0)
    s_ren.ResetCamera()
    if a_at is not None:
# the camera is moved sideways until it looks at the wanted point
        a_f = np.asarray(s_cam.GetFocalPoint())
        a_c = np.asarray(s_cam.GetPosition())
        s_cam.SetFocalPoint(a_at[0], a_at[1], a_at[2])
        s_cam.SetPosition(a_c[0] - a_f[0] + a_at[0], a_c[1] - a_f[1] + a_at[1], a_c[2] - a_f[2] + a_at[2])
    s_cam.Zoom(f_zoom)
    s_win.Render()
    s_w2i = vtk.vtkWindowToImageFilter()
    s_w2i.SetInput(s_win)
    s_w2i.Update()
    s_png = vtk.vtkPNGWriter()
    s_png.SetFileName(os.path.join(OUT_DIR, c_name))
    s_png.SetInputConnection(s_w2i.GetOutputPort())
    s_png.Write()


def stability(a_grid, a_lo, f_cell):
# volume and weight of the stand, and how far the common centre of gravity (stand + case) lies
# inside the footprint on the table (mm; negative = it falls over)
    a_in = a_grid < 0
    a_c = np.zeros(3)
    f_margin = 0.0
    f_n = float(a_in.sum())
    f_vol = f_n * f_cell ** 3
# centre of the stand: mean position of the cells inside it
    for i_k in range(3):
        a_cnt = a_in.sum(axis=tuple(i_j for i_j in range(3) if i_j != i_k))
        a_c[i_k] = a_lo[i_k] + float((a_cnt * np.arange(a_grid.shape[i_k])).sum()) / f_n * f_cell
    a_cc = to_world(np.array([[0.0, CASE_L * case.HALF, CASE_H * case.HALF]]))[0]
    f_mh = f_vol / 1000.0 * PRINT_DENSITY
    a_c = (a_c * f_mh + a_cc * CASE_MASS) / (f_mh + CASE_MASS)
# footprint: the cells inside the stand in the first layer above the table, their convex outline
    i_z = int(round(-a_lo[2] / f_cell)) + 1
    a_ij = np.argwhere(a_in[:, :, i_z])
    a_foot = a_lo[0:2] + a_ij * f_cell
    s_hull = ConvexHull(a_foot)
    f_margin = float(-np.max(s_hull.equations[:, 0:2] @ a_c[0:2] + s_hull.equations[:, 2]))
    return (f_vol, f_mh, a_c, f_margin, a_foot)


def main():
    f_cell = VOXEL
    i_bad = 0
    a_names = ["index", "middle", "ring", "little"]
    if len(sys.argv) > 1:
        f_cell = float(sys.argv[1])
    os.makedirs(OUT_DIR, exist_ok=True)
# the pose
    (a_m, a_t, a_fing, a_th, a_ang, s_sol) = solve_pose()
    print("pose solver: cost %.2f; wrist at A %.1f, V %.1f, W %.1f" % (s_sol.cost, a_t[0], a_t[1], a_t[2]))
    for i_f in range(4):
        a_tip = a_t + SCALE * (a_m @ a_fing[i_f][3])
        print("  %-6s spread %5.1f, joints %5.1f %5.1f %5.1f deg; tip at A %.1f, V %.1f, W %.1f" % (
              a_names[i_f], a_ang[i_f][0], a_ang[i_f][1], a_ang[i_f][2], a_ang[i_f][3], a_tip[0], a_tip[1], a_tip[2]))
    print("  thumb  joints %5.1f %5.1f deg; bones %.1f %.1f %.1f mm (wanted %.1f %.1f %.1f)"
          % (bend(a_th[0], a_th[1], a_th[2]), bend(a_th[1], a_th[2], a_th[3]),
             np.linalg.norm(a_th[1] - a_th[0]) * SCALE, np.linalg.norm(a_th[2] - a_th[1]) * SCALE,
             np.linalg.norm(a_th[3] - a_th[2]) * SCALE, T_LEN[0] * SCALE, T_LEN[1] * SCALE, T_LEN[2] * SCALE))
    a_arm = arm_axes(a_m)
    a_ww = to_world(a_t.reshape(1, 3))[0]
    a_ft = a_ww - a_arm[2] * a_ww[2] / a_arm[2][2]
    print("  wrist bent by %.0f deg, %.0f mm above the table; the forearm is %.0f deg steep and meets the table "
          "at x %.0f, y %.0f" % (math.degrees(math.acos(float(np.dot(-a_arm[0], [1.0, 0.0, 0.0])))), a_ww[2],
                                 math.degrees(math.asin(-a_arm[2][2])), a_ft[0], a_ft[1]))
    s_pose = (a_m, a_t, a_fing, a_th, a_arm)
# the box to sample: all joints and the forearm's end, with room for the flesh
    a_pts = [a_pt for a_f in a_fing for a_pt in a_f] + a_th + [np.zeros(3)]
    a_pw = to_world(a_t + SCALE * (np.asarray(a_pts) @ a_m.T))
    f_room = ARM_HW * SCALE + BORDER
    a_lo = a_pw.min(axis=0) - f_room
    a_hi = a_pw.max(axis=0) + f_room
    for (t_c, t_r, i_n, i_seed) in ROCKS:
        a_lo[0:2] = np.minimum(a_lo[0:2], np.asarray(t_c) - np.asarray(t_r[0:2]) - BORDER)
        a_hi[0:2] = np.maximum(a_hi[0:2], np.asarray(t_c) + np.asarray(t_r[0:2]) + BORDER)
    a_lo[2] = -2 * f_cell
    a_grid = sample(s_pose, a_lo, a_hi, f_cell)
    s_poly = mesh(a_grid, a_lo, f_cell)
    a_b = s_poly.GetBounds()
    print("hand: %.0f x %.0f x %.0f mm, %d triangles" % (a_b[1] - a_b[0], a_b[3] - a_b[2], a_b[5] - a_b[4],
                                                           s_poly.GetNumberOfCells()))
# check 1: no point of the mesh inside the case or inside the room of the plugs
    a_p = numpy_support.vtk_to_numpy(s_poly.GetPoints().GetData()).astype(float)
    f_min = float(room_dist(to_design(a_p)).min())
    print("smallest distance to the case (with %.1f mm play) and the plugs' room: %.2f mm" % (PLAY, f_min))
    if f_min < -f_cell:
        i_bad = i_bad + 1
# check 2: it stands
    (f_vol, f_mh, a_c, f_margin, a_foot) = stability(a_grid, a_lo, f_cell)
    print("volume %.0f cm3 (about %.0f g printed), footprint %.0f x %.0f mm"
          % (f_vol / 1000.0, f_mh, np.ptp(a_foot[:, 0]), np.ptp(a_foot[:, 1])))
    print("centre of gravity with the case (%.0f g): x %.0f, y %.0f, z %.0f; %.1f mm inside the footprint"
          % (CASE_MASS, a_c[0], a_c[1], a_c[2], f_margin))
    if f_margin < 0:
        i_bad = i_bad + 1
    print("top of the case: %.0f mm above the table" % to_world(np.array([[0.0, CASE_L, CASE_H]]))[0][2])
# files
    s_wr = vtk.vtkSTLWriter()
    s_wr.SetFileName(os.path.join(OUT_DIR, "L_hand2.stl"))
    s_wr.SetFileTypeToBinary()
    s_wr.SetInputData(s_poly)
    s_wr.Write()
    t_skin = (0.87, 0.72, 0.60)
    t_dark = (0.27, 0.27, 0.31)
    s_case = case_mesh()
# pictures: the first two from where the user's photos were taken
    picture([(s_poly, t_skin), (s_case, t_dark)], "hand2_case_photo1.png", (520.0, -230.0, 60.0))
    picture([(s_poly, t_skin), (s_case, t_dark)], "hand2_case_photo2.png", (-30.0, -520.0, 90.0))
# close look at the nails: the point between the fingertips and the thumb's tip
    a_look = to_world(np.array([[20.0, 150.0, 0.0]]))[0]
    picture([(s_poly, t_skin)], "hand2_nails.png", (-250.0, 420.0, 330.0), PIC_ZOOM_NAILS, a_look)
    picture([(s_poly, t_skin)], "hand2_front.png", (-150.0, -500.0, 220.0))
    picture([(s_poly, t_skin)], "hand2_back.png", (250.0, 450.0, 250.0))
    picture([(s_poly, t_skin), (s_case, t_dark)], "hand2_case_front.png", (-150.0, -500.0, 220.0))
    picture([(s_poly, t_skin), (s_case, t_dark)], "hand2_case_left.png", (-500.0, -150.0, 120.0))
    picture([(s_poly, t_skin), (s_case, t_dark)], "hand2_case_right.png", (500.0, -120.0, 120.0))
    picture([(s_poly, t_skin), (s_case, t_dark)], "hand2_case_back.png", (200.0, 500.0, 250.0))
    picture([(s_poly, t_skin), (s_case, t_dark)], "hand2_case_below.png", (-100.0, -350.0, -60.0))
    picture([(s_poly, t_skin), (s_case, t_dark)], "hand2_case_top.png", (-120.0, -200.0, 500.0))
    if i_bad == 0:
        print("CHECK PASS")
    else:
        print("CHECK FAIL: %d" % i_bad)
    return i_bad


if __name__ == "__main__":
    sys.exit(main())
