# fp_wrover.py -- writes ../Extra_PCB_CycloneIV_R2.pretty/ESP32-WROVER-E.kicad_mod from Espressif's
# "ESP32-WROVER-E & ESP32-WROVER-IE Datasheet v2.4", Figure 15 "Recommended PCB Land Pattern" (dimensions decoded
# from the drawing's vector data, docs/vendor/esp32-wrover-e_esp32-wrover-ie_datasheet_en.pdf page 45):
#   module 18 x 31.4 mm; 38 pads 1.5 x 0.9 mm, pitch 1.27, 19 per side, centres at x = +-8.75 (0.5 mm outside the
#   module edge); pin 1 centre 7.44 mm below the antenna end, pin 19 centre 1.12 mm above the other end;
#   pins 1-19 down the left side, 20-38 up the right side (top view); GND pad 3.7 x 3.7 mm at x = -1.5 mm,
#   7.81 mm below pin 1. Antenna area: the 7.44 mm at the antenna end (no copper on any layer under it).
import os, uuid
U = lambda: str(uuid.uuid4())
L, W = 31.4, 18.0
Y1 = -L / 2 + 7.44                       # pin 1 centre (origin = module centre, y down)
PITCH, PX = 1.27, 8.75
ANT = 7.44

def pad(num, x, y, w, h, extra=""):
    return (f'\t(pad "{num}" smd rect\n\t\t(at {x:.3f} {y:.3f})\n\t\t(size {w} {h})\n'
            f'\t\t(layers "F.Cu" "F.Mask" "F.Paste"){extra}\n\t\t(uuid "{U()}")\n\t)')

def line(x1, y1, x2, y2, layer, w):
    return (f'\t(fp_line\n\t\t(start {x1:.3f} {y1:.3f})\n\t\t(end {x2:.3f} {y2:.3f})\n\t\t(stroke\n\t\t\t(width {w})\n'
            f'\t\t\t(type solid)\n\t\t)\n\t\t(layer "{layer}")\n\t\t(uuid "{U()}")\n\t)')

def rect(x1, y1, x2, y2, layer, w):
    return [line(x1, y1, x2, y1, layer, w), line(x2, y1, x2, y2, layer, w),
            line(x2, y2, x1, y2, layer, w), line(x1, y2, x1, y1, layer, w)]

def text(kind, val, x, y, layer, hide=False):
    h = "\n\t\t(hide yes)" if hide else ""
    return (f'\t(property "{kind}" "{val}"\n\t\t(at {x} {y} 0)\n\t\t(layer "{layer}"){h}\n\t\t(uuid "{U()}")\n'
            f'\t\t(effects\n\t\t\t(font\n\t\t\t\t(size 1 1)\n\t\t\t\t(thickness 0.15)\n\t\t\t)\n\t\t)\n\t)')

items = []
for i in range(19):                                   # left: 1..19 top to bottom
    items.append(pad(i + 1, -PX, Y1 + i * PITCH, 1.5, 0.9))
for i in range(19):                                   # right: 20..38 bottom to top
    items.append(pad(20 + i, PX, Y1 + (18 - i) * PITCH, 1.5, 0.9))
# GND pad: copper 3.7 x 3.7, paste as 3 x 3 squares of 0.9 (the datasheet's pattern); GND vias are added on the board
# (via pads in the footprint would make it a through-hole part for KiCad)
gx, gy = -1.5, Y1 + 7.81
items.append(pad(39, gx, gy, 3.7, 3.7).replace('(layers "F.Cu" "F.Mask" "F.Paste")', '(layers "F.Cu" "F.Mask")'))
for dx in (-1.4, 0, 1.4):
    for dy in (-1.4, 0, 1.4):
        items.append(f'\t(fp_rect\n\t\t(start {gx+dx-0.45:.3f} {gy+dy-0.45:.3f})\n\t\t(end {gx+dx+0.45:.3f} {gy+dy+0.45:.3f})\n'
                     f'\t\t(stroke\n\t\t\t(width 0)\n\t\t\t(type solid)\n\t\t)\n\t\t(fill yes)\n\t\t(layer "F.Paste")\n\t\t(uuid "{U()}")\n\t)')
top, bot = -L / 2, L / 2
items += rect(-W / 2, top, W / 2, bot, "F.Fab", 0.1)
items.append(line(-W / 2, top + ANT, W / 2, top + ANT, "F.Fab", 0.1))
items += rect(-W / 2 - 1.0, top - 0.5, W / 2 + 1.0, bot + 0.5, "F.CrtYd", 0.05)
# silkscreen: module outline outside the pad rows, pin 1 mark
s = 0.12
yp1, yp19 = Y1 - 0.45 - 0.3, Y1 + 18 * PITCH + 0.45 + 0.3
items += [line(-W / 2 - s, top - s, W / 2 + s, top - s, "F.SilkS", s),
          line(-W / 2 - s, top - s, -W / 2 - s, yp1, "F.SilkS", s), line(W / 2 + s, top - s, W / 2 + s, yp1, "F.SilkS", s),
          line(-W / 2 - s, bot + s, W / 2 + s, bot + s, "F.SilkS", s),
          line(-W / 2 - s, yp19, -W / 2 - s, bot + s, "F.SilkS", s), line(W / 2 + s, yp19, W / 2 + s, bot + s, "F.SilkS", s),
          line(-W / 2 - 1.2, Y1, -W / 2 - 0.6, Y1, "F.SilkS", s)]
# antenna keep-out: no copper, vias or tracks on any layer under the antenna area
z = (f'\t(zone\n\t\t(net 0)\n\t\t(net_name "")\n\t\t(layers "F.Cu" "B.Cu")\n\t\t(uuid "{U()}")\n\t\t(name "Antenna keep-out")\n'
     f'\t\t(hatch edge 0.5)\n\t\t(connect_pads\n\t\t\t(clearance 0)\n\t\t)\n\t\t(min_thickness 0.25)\n\t\t(filled_areas_thickness no)\n'
     f'\t\t(keepout\n\t\t\t(tracks not_allowed)\n\t\t\t(vias not_allowed)\n\t\t\t(pads not_allowed)\n\t\t\t(copperpour not_allowed)\n'
     f'\t\t\t(footprints allowed)\n\t\t)\n\t\t(placement\n\t\t\t(enabled no)\n\t\t\t(sheetname "")\n\t\t)\n\t\t(fill\n\t\t\t(thermal_gap 0.5)\n'
     f'\t\t\t(thermal_bridge_width 0.5)\n\t\t)\n\t\t(polygon\n\t\t\t(pts\n\t\t\t\t(xy {-W/2:.3f} {top:.3f}) (xy {W/2:.3f} {top:.3f}) '
     f'(xy {W/2:.3f} {top+ANT:.3f}) (xy {-W/2:.3f} {top+ANT:.3f})\n\t\t\t)\n\t\t)\n\t)')
items.append(z)
fp = ('(footprint "ESP32-WROVER-E"\n\t(version 20241229)\n\t(generator "fp_wrover.py")\n\t(layer "F.Cu")\n'
      '\t(descr "ESP32-WROVER-E / -IE module, 18 x 31.4 mm, land pattern from the Espressif datasheet v2.4 Fig. 15")\n'
      '\t(tags "ESP32 WROVER Espressif module")\n'
      + text("Reference", "REF**", 0, top - 1.8, "F.SilkS") + "\n" + text("Value", "ESP32-WROVER-E", 0, bot + 1.8, "F.Fab") + "\n"
      + text("Footprint", "", 0, 0, "F.Fab", True) + "\n" + text("Datasheet", "", 0, 0, "F.Fab", True) + "\n"
      + text("Description", "", 0, 0, "F.Fab", True) + "\n\t(attr smd)\n" + "\n".join(items) + "\n)\n")
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Extra_PCB_CycloneIV_R2.pretty", "ESP32-WROVER-E.kicad_mod")
open(out, "w", newline="\n").write(fp)
print("written", out)
