"""mkpng.py GRAB.txt OUT.png [SCALE [XSTEP]] -- picture from the lines the JTAG rig read (planes = rgb bit numbers)"""
import sys, zlib, struct
rows = {}
segs = {}
step = int(sys.argv[4]) if len(sys.argv) > 4 else 1
for l in open(sys.argv[1]):
    i, pl, x0, bits = l.split()
    segs.setdefault((int(i), int(pl)), []).append((int(x0), bits[::-1]))   # the first sample was shifted in first: the LSB
for (i, pl), parts in segs.items():
    parts.sort()
    base = parts[0][0]; line = ''
    for x0, bits in parts:
        at = (x0 - base) // step                                          # samples of this part that are already there
        line = line[:at] + bits
    rows.setdefault(i, {})[pl] = line
scale = int(sys.argv[3]) if len(sys.argv) > 3 else 2
h = max(rows) + 1; w = len(next(iter(rows[0].values())))
img = []
for y in range(h):
    line = bytearray()
    for x in range(w):
        rgb = [0, 0, 0]
        for pl, bits in rows[y].items():
            if bits[x] == '1':
                rgb[2 - pl // 4] |= 1 << (pl % 4)              # channel: 11..8 R, 7..4 G, 3..0 B
        got = [[pl % 4 for pl in rows[y] if 2 - pl // 4 == c] for c in range(3)]
        for c in range(3):
            # scale by the bits that were read of this channel
            full = sum(1 << b for b in got[c]) or 1
            line += bytes([rgb[c] * 255 // full]) * 1
        if scale > 1:
            line += line[-3:] * (scale - 1)
    for _ in range(scale):
        img.append(b'\0' + bytes(line))
raw = b''.join(img)
def chunk(t, d):
    return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xFFFFFFFF)
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w * scale, h * scale, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b'')
open(sys.argv[2], 'wb').write(png)
print('%s: %d x %d' % (sys.argv[2], w * scale, h * scale))
