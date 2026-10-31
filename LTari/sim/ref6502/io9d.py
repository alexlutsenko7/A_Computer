import sys, runpy
sys.argv = ['run6502.py', sys.argv[1], sys.argv[2], '/dev/null']
g = runpy.run_path(__file__.rsplit('/', 1)[0] + '/run6502.py')
g = g['step'].__globals__
orig_rd = g['rd']
reads = []
def rd(a):
    v = orig_rd(a)
    if 0xD000 <= (a & 0xFFFF) < 0xD800: reads.append((g['PC'], a & 0xFFFF))
    return v
g['rd'] = rd
g['PC'] = orig_rd(0xD4) | orig_rd(0xD5) << 8
for n in range(11445): g['step']()
import collections
c = collections.Counter(reads)
print('I/O reads before the frame wait:', len(reads))
for (pc, a), k in sorted(c.items()): print('  at $%04X reads $%04X  (%d x)' % (pc, a, k))
