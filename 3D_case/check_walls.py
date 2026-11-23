# Wall thickness check of the two printed case halves (out/L_case_bottom.stl, out/L_case_top.stl).
# Run after case.py: C:\Tools\cadquery_env\Scripts\python.exe check_walls.py
#
# Two measurements on a grid of CELL:
# - slices across Z: the material that a disc of WALL_MIN diameter cannot reach is a wall, fin or
#   sliver thinner than WALL_MIN (all walls of the case stand upright). Sharp outer corners leave a
#   small mark too: marks below AREA_MIN are not counted.
# - slices across X: material that is less than WALL_MIN high (a thin floor, ceiling or lip).
# The grid makes both blind to the last TOLERANCE: what they catch is thinner than WALL_MIN - TOLERANCE.

import os
import sys
import numpy as np
import vtk
from scipy import ndimage
from vtk.util.numpy_support import vtk_to_numpy
from case import WALL_MIN, OUT_DIR

# grid cell (mm) and distance between two slices (mm)
CELL = 0.10
STEP = 0.50
# the disc is this much smaller than WALL_MIN: a wall of exactly WALL_MIN must pass on the grid
TOLERANCE = 0.10
# marks smaller than this (mm2) are corner rounding, not walls
AREA_MIN = 0.12
# free cells around the part in the grid
MARGIN = 10
HALF = 0.5
AXES = 3
NAMES = ["L_case_bottom.stl", "L_case_top.stl"]
AXIS_NAME = ["X", "Y", "Z"]
AXIS_X = 0
AXIS_Z = 2
# at most this many places are printed per half
SHOW_MAX = 40


def read_stl(c_file):
# the STL file as a VTK surface
    s_reader = vtk.vtkSTLReader()
    s_mesh = None
    s_reader.SetFileName(c_file)
    s_reader.Update()
    s_mesh = s_reader.GetOutput()
    return s_mesh


def one_slice(s_mesh, ai_dim, af_origin, i_axis, i_n):
# one layer of grid cells across i_axis at index i_n: 2-D bool array of the filled cells
    s_image = vtk.vtkImageData()
    s_stencil = vtk.vtkPolyDataToImageStencil()
    s_fill = vtk.vtkImageStencil()
    ai_ext = [0, ai_dim[0] - 1, 0, ai_dim[1] - 1, 0, ai_dim[2] - 1]
    ab_slice = None
# the layer is one cell thick
    ai_ext[2 * i_axis] = i_n
    ai_ext[2 * i_axis + 1] = i_n
    s_image.SetExtent(ai_ext)
    s_image.SetSpacing(CELL, CELL, CELL)
    s_image.SetOrigin(af_origin)
    s_image.AllocateScalars(vtk.VTK_UNSIGNED_CHAR, 1)
    s_image.GetPointData().GetScalars().Fill(1)
# cells outside the surface become 0
    s_stencil.SetInputData(s_mesh)
    s_stencil.SetOutputOrigin(af_origin)
    s_stencil.SetOutputSpacing(CELL, CELL, CELL)
    s_stencil.SetOutputWholeExtent(ai_ext)
    s_fill.SetInputData(s_image)
    s_fill.SetStencilConnection(s_stencil.GetOutputPort())
    s_fill.ReverseStencilOff()
    s_fill.SetBackgroundValue(0)
    s_fill.Update()
    ab_slice = np.squeeze(vtk_to_numpy(s_fill.GetOutput().GetPointData().GetScalars()).reshape(
        ai_ext[5] - ai_ext[4] + 1, ai_ext[3] - ai_ext[2] + 1, ai_ext[1] - ai_ext[0] + 1) > 0)
    return ab_slice


def thin_places(s_mesh):
# list of (area, axis, slice position, the two other coordinates of the centre) of every thin place
    a_found = []
    af_bounds = s_mesh.GetBounds()
    f_r = (WALL_MIN - TOLERANCE) * HALF / CELL
    i_step = int(round(STEP / CELL))
    i_low = int(round((WALL_MIN - TOLERANCE) / CELL))
    ab_thin = None
# grid around the part
    ai_dim = [int((af_bounds[2 * i_k + 1] - af_bounds[2 * i_k]) / CELL) + 2 * MARGIN for i_k in range(AXES)]
    af_origin = [af_bounds[2 * i_k] - MARGIN * CELL + CELL * HALF for i_k in range(AXES)]
    for i_axis in (AXIS_Z, AXIS_X):
# the slice's array is indexed by the two other axes, the higher one first
        ai_other = [i_k for i_k in (2, 1, 0) if i_k != i_axis]
        for i_n in range(MARGIN + 1, ai_dim[i_axis] - MARGIN, i_step):
            ab_slice = one_slice(s_mesh, ai_dim, af_origin, i_axis, i_n)
            if ab_slice.any():
                if i_axis == AXIS_Z:
# opening with a disc: what the disc cannot reach is thin
                    ab_core = ndimage.distance_transform_edt(ab_slice) > f_r
                    ab_open = ndimage.distance_transform_edt(~ab_core) <= f_r
                    ab_thin = ab_slice & ~ab_open
                else:
# opening along Z with a line of the smallest allowed height: what it cannot reach is thin
                    ab_thin = ab_slice & ~ndimage.binary_opening(ab_slice, structure=np.ones((i_low, 1), bool))
                ai_label, i_count = ndimage.label(ab_thin)
                if i_count > 0:
                    ai_idx = list(range(1, i_count + 1))
                    af_area = ndimage.sum(ab_thin, ai_label, ai_idx) * CELL * CELL
                    a_cent = ndimage.center_of_mass(ab_thin, ai_label, ai_idx)
                    for i_k in range(i_count):
                        if af_area[i_k] >= AREA_MIN:
                            a_found.append((af_area[i_k], i_axis, af_origin[i_axis] + i_n * CELL,
                                            AXIS_NAME[ai_other[0]], af_origin[ai_other[0]] + a_cent[i_k][0] * CELL,
                                            AXIS_NAME[ai_other[1]], af_origin[ai_other[1]] + a_cent[i_k][1] * CELL))
    return a_found


def main():
    i_bad = 0
    for c_name in NAMES:
        a_found = thin_places(read_stl(os.path.join(OUT_DIR, c_name)))
        print("%s: %d thin place(s) in the slices (STL coordinates, mm)" % (c_name, len(a_found)))
        a_found.sort(key=lambda t_f: -t_f[0])
        for (f_area, i_axis, f_pos, c_a, f_a, c_b, f_b) in a_found[:SHOW_MAX]:
            print("  slice %s = %7.2f: %5.2f mm2 at %s = %7.2f, %s = %7.2f"
                  % (AXIS_NAME[i_axis], f_pos, f_area, c_a, f_a, c_b, f_b))
        i_bad = i_bad + len(a_found)
    if i_bad == 0:
        print("WALL CHECK PASS: nothing thinner than %.2f mm" % WALL_MIN)
    else:
        print("WALL CHECK FAIL")
    return i_bad


if __name__ == "__main__":
    sys.exit(main())
