# Convert the testbench's ASCII PPM (P3) to PNG (no external libraries), scaled 2x.
import sys, zlib, struct
src, dst = sys.argv[1], sys.argv[2]
tok = open(src).read().split()
assert tok[0] == 'P3'
w, h = int(tok[1]), int(tok[2])
px = list(map(int, tok[4:4 + 3 * w * h]))
S = 2
raw = bytearray()
for y in range(h):
    row = bytearray()
    for x in range(w):
        row += bytes(px[3 * (y * w + x):3 * (y * w + x) + 3]) * S
    for _ in range(S):
        raw += b'\x00' + row
def chunk(t, d):
    c = struct.pack('>I', len(d)) + t + d
    return c + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w * S, h * S, 8, 2, 0, 0, 0)) \
      + chunk(b'IDAT', zlib.compress(bytes(raw), 9)) + chunk(b'IEND', b'')
open(dst, 'wb').write(png)
