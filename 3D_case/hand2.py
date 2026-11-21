# Stand 2 for the L computer case: a realistic human hand that holds the case upright, like a phone
# shown to the viewer. The joystick end of the case is down. The thumb lies under the case's lower
# back edge and carries it; the four fingers reach round the USB-C side, index and middle finger
# below the two sockets, ring and little finger above them (the plugs pass between middle and ring
# finger). The forearm stands on a base plate. The case is pushed in from above.
# Run: C:\Tools\cadquery_env\Scripts\python.exe hand2.py [voxel size in mm]   (in this folder)
# Output: out/L_hand2.stl, out/hand2_*.png
#
# The hand is not a CAD solid: it is a smooth surface around a skeleton (joints with radii, blended
# cones), sampled on a grid and turned into a mesh. The pose is found by a solver from the points
# the fingers have to reach on the case. The case (with play) and the room of every plug are cut out.
#
# Design coordinates (mm): A = case X - middle (USB-C wall at +A, VGA wall at -A), V = distance from
# the joystick end along the case, W = height above the case's underside. Seen from the front they
# are a mirror image of the real thing (that makes the hand a left hand).
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
LIFT = 75.0
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
# VGA wall: USB-A J9, VGA, microSD; free from the lowest socket up to the top, because the case is
# pushed in from above and the VGA socket's shell stands out of this wall
SIDE_N_V0 = CASE_Y1 - (case.J9_Y + case.USBA_POCKET_W * case.HALF) - 1.00
SIDE_W0 = 5.00

# ---------------------------------------------------------------- anatomy (mm, a man's hand, before scaling)
# hand coordinates: x from the wrist to the fingers, y to the thumb side, z out of the palm
# the hand is larger than life: the case is 89.5 mm wide and 25.5 mm thick
SCALE = 1.30
# knuckles (MCP joints): index, middle, ring, little finger
MCP = [(95.0, 27.0, 0.0), (100.0, 5.0, -1.0), (94.0, -15.0, 0.0), (83.0, -33.0, 3.0)]
# lengths of the three bones of each finger
F_LEN = [(45.0, 26.0, 22.0), (50.0, 30.0, 23.0), (46.0, 28.0, 23.0), (36.0, 20.0, 20.0)]
# radii at knuckle, middle joint, end joint, fingertip
F_RAD = [(10.5, 9.2, 8.0, 6.8), (10.8, 9.4, 8.1, 6.9), (10.0, 8.8, 7.6, 6.5), (9.0, 7.8, 6.8, 5.8)]
# where the hand bones start at the wrist, and their radius there
CARPAL = [(8.0, 15.0, -3.0), (6.0, 4.0, -4.0), (6.0, -8.0, -3.0), (8.0, -19.0, -1.0)]
CARPAL_R = 11.0
# thumb: base joint, lengths of its three bones, radii
T_BASE = (20.0, 30.0, 6.0)
T_LEN = (46.0, 33.0, 28.0)
T_RAD = (15.0, 11.5, 9.8, 8.0)
# pads of the palm: (from, to, radius from, radius to)
PAD_LITTLE = ((10.0, -25.0, 6.0), (72.0, -34.0, 6.0), 13.0, 10.0)
PAD_MIDDLE = ((30.0, -2.0, 3.0), (80.0, -4.0, 3.0), 10.0, 9.0)
# skin between thumb and index finger: from the thumb's first bone (fraction of its length) to here
WEB_TO = (62.0, 25.0, 2.0)
WEB_AT = 0.60
WEB_R = 6.50
# wrist and forearm: half width, half thickness at the wrist and at the cut end; length
WRIST_HW = 29.0
WRIST_HT = 19.5
ARM_HW = 34.0
ARM_HT = 26.0
ARM_LEN = 220.0
# the forearm reaches its full size this far from the wrist
ARM_GROW = 95.0
# how soft the parts run into each other (mm): finger joints, fingers into the palm, palm, wrist
K_JOINT = 2.00
K_FINGER = 5.00
K_PALM = 9.00
K_WRIST = 12.0

# ---------------------------------------------------------------- pose of the hand
# points the joints have to reach (design coordinates): middle joint, end joint, tip
# index and middle finger go round the USB-C wall under the USB-C socket, tips on the lid
# ring and little finger do the same above the USB-A socket of that wall
AIM = [[(60.5, 11.5, -4.0), (58.5, 11.5, 31.0), (30.0, 11.5, 35.0)],
       [(61.0, 35.5, -4.0), (59.0, 35.5, 33.0), (27.0, 35.5, 35.5)],
       [(61.0, 98.0, -4.0), (58.5, 99.0, 31.0), (30.0, 100.0, 35.0)],
       [(58.0, 120.0, -2.0), (56.5, 121.0, 24.0), (38.0, 122.0, 33.0)]]
# thumb: its knuckle stands beside the VGA wall's lowest corner, the two outer bones lie under the
# case's lower back edge
AIM_THUMB = [(-58.0, -3.0, -6.0), (-14.0, -5.0, -7.0), (22.0, -5.0, -6.5)]
# fingernails, in parts of the last bone's length and radius: position along the bone, how far
# out of the bone's axis, half length, half width, half thickness
NAIL_AT = 0.56
NAIL_OUT = 0.80
NAIL_L = 0.40
NAIL_W = 0.80
NAIL_T = 0.32
# first guess of the hand's axes in design coordinates (x of the hand, y of the hand) and its wrist
X_START = (0.80, 0.10, 0.59)
Y_START = (0.05, -1.00, 0.10)
WRIST_START = (-95.0, -45.0, -75.0)
# joint limits (degrees): spread, knuckle, middle joint, end joint; thumb joints
LIM_LO = (-24.0, -15.0, 0.0, 0.0)
LIM_HI = (24.0, 90.0, 110.0, 85.0)
THUMB_BEND = (60.0, 80.0)
# weights of the solver: bone lengths, limits, clearance behind the case
W_LEN = 5.00
W_LIM = 3.00
W_CLEAR = 2.00
# the knuckles of index and middle finger stay this far behind the case (cupped hand)
CUP = 6.00
# the forearm runs from the wrist down to the table, as steep as this bend of the wrist allows (degrees)
WRIST_BEND = 70.0
# base plate on the table (an oval): centre, half sizes, thickness, soft run into the forearm
PLATE_C = (52.0, 48.0)
PLATE_R = (86.0, 66.0)
PLATE_T = 5.00
K_PLATE = 8.00

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


def frame(a_p):
# the hand's axes (columns x, y, z in design coordinates) and its wrist from the solver's parameters
    a_x = unit(X_START)
    a_y = np.asarray(Y_START, dtype=float)
    a_r = rot(a_p[0:3])
# y square to x; z = y cross x points out of the palm (mirror: see the header)
    a_y = unit(a_y - np.dot(a_y, a_x) * a_x)
    a_x = a_r @ a_x
    a_y = a_r @ a_y
    a_m = np.column_stack([a_x, a_y, np.cross(a_y, a_x)])
    a_t = np.asarray(WRIST_START, dtype=float) + a_p[3:6]
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
# what the solver makes small: distances to the aimed points, bone length errors, limits, clearance
    a_res = []
    (a_m, a_t) = frame(a_p)
# the four fingers: joints at their aimed points, angles inside the limits
    for i_f in range(4):
        a_ang = a_p[6 + 4 * i_f:10 + 4 * i_f]
        a_j = [a_t + SCALE * (a_m @ a_pt) for a_pt in finger_joints(i_f, a_ang)]
        for i_k in range(3):
            a_res.extend(a_j[1 + i_k] - np.asarray(AIM[i_f][i_k]))
        for i_k in range(4):
            a_res.append(W_LIM * max(0.0, LIM_LO[i_k] - a_ang[i_k]))
            a_res.append(W_LIM * max(0.0, a_ang[i_k] - LIM_HI[i_k]))
# the knuckle stays behind the case
        a_res.append(W_CLEAR * max(0.0, a_j[0][2] + F_RAD[i_f][0] * SCALE + CUP))
# thumb: three free points; bone lengths, aimed points, bend of its two joints
    a_th = [a_t + SCALE * (a_m @ np.asarray(T_BASE))]
    for i_k in range(3):
        a_th.append(a_p[22 + 3 * i_k:25 + 3 * i_k])
        a_res.extend(a_th[-1] - np.asarray(AIM_THUMB[i_k]))
        a_res.append(W_LEN * (np.linalg.norm(a_th[-1] - a_th[-2]) - T_LEN[i_k] * SCALE))
    a_res.append(W_LIM * max(0.0, bend(a_th[0], a_th[1], a_th[2]) - THUMB_BEND[0]))
    a_res.append(W_LIM * max(0.0, bend(a_th[1], a_th[2], a_th[3]) - THUMB_BEND[1]))
    return np.asarray(a_res, dtype=float)


def solve_pose():
# the pose: hand axes, wrist, joint points of the five fingers (design coordinates) and the angles
    a_p0 = np.zeros(31)
    a_fing = []
    a_th = []
    a_ang_all = []
    s_sol = None
# first guess: fingers half bent, thumb at its aimed points
    a_p0[6:22] = [0.0, 20.0, 60.0, 70.0] * 4
    a_p0[22:31] = np.asarray(AIM_THUMB).ravel()
    s_sol = least_squares(residuals, a_p0)
    (a_m, a_t) = frame(s_sol.x)
    for i_f in range(4):
        a_ang = s_sol.x[6 + 4 * i_f:10 + 4 * i_f]
        a_ang_all.append(a_ang)
        a_fing.append(finger_joints(i_f, a_ang))
# the thumb's points go back into hand coordinates (everything is built there)
    a_th = [np.asarray(T_BASE, dtype=float)]
    for i_k in range(3):
        a_th.append(a_m.T @ (s_sol.x[22 + 3 * i_k:25 + 3 * i_k] - a_t) / SCALE)
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
# distance to a fingernail on the bone a_p1..a_p2 (a_p0 = the joint before, it tells the back of
# the finger from its pad); f_r1, f_r2 = radii at the bone's ends
    a_e = unit(a_p2 - a_p1)
    a_s = unit(np.cross(unit(a_p1 - a_p0), a_e))
    a_back = np.cross(a_e, a_s)
    f_len = float(np.linalg.norm(a_p2 - a_p1))
    f_r = f_r1 + NAIL_AT * (f_r2 - f_r1)
    a_c = a_p1 + NAIL_AT * f_len * a_e + NAIL_OUT * f_r * a_back
# a flat ellipsoid
    a_rel = a_q - a_c
    a_n = np.sqrt(((a_rel @ a_e) / (NAIL_L * f_len)) ** 2 + ((a_rel @ a_s) / (NAIL_W * f_r)) ** 2
                  + ((a_rel @ a_back) / (NAIL_T * f_r)) ** 2)
    a_d = (a_n - 1.0) * NAIL_T * f_r
    return a_d


def nail_thumb(a_q, a_th):
# the thumb's nail: its last joint is nearly straight, so the back of the thumb is told by the
# bend of the joint before (a point is made that bends the same way)
    a_d = nail(a_q, a_th[2] - (a_th[1] - a_th[0]), a_th[2], a_th[3], T_RAD[2], T_RAD[3])
    return a_d


def hand_dist(a_q, s_pose):
# distance to the whole hand; a_q = points in hand coordinates (before scaling)
    (a_m, a_t, a_fing, a_th, a_arm) = s_pose[0:5]
    a_palm = None
    a_all = None
# the palm: the four hand bones, the pads, the thumb's first bone, the skin to the index finger
    for i_f in range(4):
        a_d = cone(a_q, np.asarray(CARPAL[i_f]), a_fing[i_f][0], CARPAL_R, F_RAD[i_f][0] + 0.5)
        a_palm = a_d if a_palm is None else blend(a_palm, a_d, K_PALM)
    for (t_a, t_b, f_ra, f_rb) in (PAD_LITTLE, PAD_MIDDLE):
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
        a_all = np.minimum(a_all, nail(a_q, a_fing[i_f][1], a_fing[i_f][2], a_fing[i_f][3],
                                       F_RAD[i_f][2], F_RAD[i_f][3]))
    a_fd = blend(cone(a_q, a_th[1], a_th[2], T_RAD[1], T_RAD[2]),
                 cone(a_q, a_th[2], a_th[3], T_RAD[2], T_RAD[3]), K_JOINT)
    a_all = np.minimum(a_all, blend(a_palm, a_fd, K_FINGER))
# the thumb's last joint is nearly straight: its back is told by the bend of the joint before
    a_all = np.minimum(a_all, nail_thumb(a_q, a_th))
    return a_all


def room_dist(a_d3):
# distance to everything the hand must not touch: the case with play, the room of the plugs
# a_d3 = points in design coordinates
    a_case = box_dist(a_d3[:, [0, 1]], (-HALF_W, 0.0), (HALF_W, CASE_L), CASE_R)
    a_case = np.maximum(a_case, np.maximum(-a_d3[:, 2], a_d3[:, 2] - CASE_H)) - PLAY
    a_big = case.BIG
# under the joystick end, beside the USB-C wall, beside the VGA wall
    a_end = box_dist(a_d3, (-HALF_W - 1.0, -a_big, PLUG_W0), (END_A1, 0.0, a_big), 0.0)
    a_sp = box_dist(a_d3, (HALF_W, SIDE_P_V0, SIDE_W0), (a_big, SIDE_P_V1, a_big), 0.0)
    a_sn = box_dist(a_d3, (-a_big, SIDE_N_V0, SIDE_W0), (-HALF_W, a_big, a_big), 0.0)
    a_d = np.minimum(np.minimum(a_case, a_end), np.minimum(a_sp, a_sn))
    return a_d


def model_dist(a_xyz, s_pose):
# the stand: the hand without the case, the plugs' room and what is under the table (world points)
    (a_m, a_t) = (s_pose[0], s_pose[1])
    a_d3 = to_design(a_xyz)
    a_q = ((a_d3 - a_t) @ a_m) / SCALE
    a_d = hand_dist(a_q, s_pose) * SCALE
    a_d = np.maximum(a_d, -room_dist(a_d3))
# the base plate: an oval disc with a round upper edge
    a_r = np.sqrt(((a_xyz[:, 0] - PLATE_C[0]) / PLATE_R[0]) ** 2 + ((a_xyz[:, 1] - PLATE_C[1]) / PLATE_R[1]) ** 2)
    a_e = np.column_stack([(a_r - 1.0) * min(PLATE_R) + PLATE_T * case.HALF, a_xyz[:, 2] - PLATE_T * case.HALF])
    a_pl = np.linalg.norm(np.maximum(a_e, 0.0), axis=1) + np.minimum(a_e.max(axis=1), 0.0) - PLATE_T * case.HALF
    a_d = blend(a_d, a_pl, K_PLATE)
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


def picture(a_parts, c_name, a_from):
# a shaded picture of meshes [(mesh, colour)] seen from the direction a_from
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
    s_cam.Zoom(1.25)
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
        print("  %-6s spread %5.1f, joints %5.1f %5.1f %5.1f deg" % (a_names[i_f], a_ang[i_f][0],
              a_ang[i_f][1], a_ang[i_f][2], a_ang[i_f][3]))
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
    a_lo[0:2] = np.minimum(a_lo[0:2], np.asarray(PLATE_C) - np.asarray(PLATE_R) - BORDER)
    a_hi[0:2] = np.maximum(a_hi[0:2], np.asarray(PLATE_C) + np.asarray(PLATE_R) + BORDER)
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
