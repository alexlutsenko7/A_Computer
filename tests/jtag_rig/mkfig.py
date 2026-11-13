#!/usr/bin/env python3
"""mkfig.py OUT.png GRAB.txt:XSTEP:X0:W ... -- several grabbed screens side by side in a 2-column grid, each cut to
W samples from X0 and scaled to 640 x 480 (nearest neighbour); pure Python, no image library"""
import sys, zlib, struct

def screen(path, step):
    """the picture of one grab file as rows of (r, g, b)"""
    segs = {}
    for l in open(path):
        i, pl, x0, bits = l.split()
        segs.setdefault((int(i), int(pl)), []).append((int(x0), bits[::-1]))
    rows = {}
    for (i, pl), parts in segs.items():
        parts.sort()
        line = ''
        for x0, bits in parts:
            line = line[:(x0 - parts[0][0]) // step] + bits
        rows.setdefault(i, {})[pl] = line
    out = []
    for y in range(max(rows) + 1):
        planes = rows[y]
        full = [sum(1 << (pl % 4) for pl in planes if 2 - pl // 4 == c) or 1 for c in range(3)]
        w = len(next(iter(planes.values())))
        row = []
        for x in range(w):
            rgb = [0, 0, 0]
            for pl, bits in planes.items():
                if bits[x] == '1':
                    rgb[2 - pl // 4] |= 1 << (pl % 4)
            row.append(tuple(rgb[c] * 255 // full[c] for c in range(3)))
        out.append(row)
    return out

W, H, GAP = 640, 480, 12
shots = []
for arg in sys.argv[2:]:
    path, step, x0, w = arg.split(':')
    pic = [r[int(x0):int(x0) + int(w)] for r in screen(path, int(step))]
    shots.append([[pic[y * len(pic) // H][x * len(pic[0]) // W] for x in range(W)] for y in range(H)])
cols = 2 if len(shots) > 1 else 1
lines = (len(shots) + cols - 1) // cols
fw, fh = cols * W + (cols + 1) * GAP, lines * H + (lines + 1) * GAP
img = [[(255, 255, 255)] * fw for _ in range(fh)]
for k, s in enumerate(shots):
    ox, oy = GAP + (k % cols) * (W + GAP), GAP + (k // cols) * (H + GAP)
    for y in range(H):
        img[oy + y][ox:ox + W] = s[y]
raw = b''.join(b'\0' + bytes(v for p in row for v in p) for row in img)
def chunk(t, d):
    return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xFFFFFFFF)
open(sys.argv[1], 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', fw, fh, 8, 2, 0, 0, 0))
                              + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))
print('%s: %d x %d' % (sys.argv[1], fw, fh))
