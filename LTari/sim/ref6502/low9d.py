import sys, runpy
sys.argv = ['run6502.py', sys.argv[1], sys.argv[2], '/dev/null']
g = runpy.run_path(__file__.rsplit('/', 1)[0] + '/run6502.py')
g = g['step'].__globals__
orig_rd, orig_wr = g['rd'], g['wr']
written = set(); hits = {}
fetch = [False]
def rd(a):
    a &= 0xFFFF
    if a < 0x800 and a not in written and not (0x100 <= a < 0x200): hits.setdefault(a, g['PC'])
    return orig_rd(a)
def wr(a, v):
    written.add(a & 0xFFFF); return orig_wr(a, v)
g['rd'] = rd; g['wr'] = wr
g['PC'] = orig_rd(0xD4) | orig_rd(0xD5) << 8
for n in range(11445): g['step']()
print('pages 0-7 read before written (the depacker state matters):', len(hits))
for a in sorted(hits)[:40]: print('  $%04X first read at $%04X, value $%02X' % (a, hits[a], g['ram'][a]))
