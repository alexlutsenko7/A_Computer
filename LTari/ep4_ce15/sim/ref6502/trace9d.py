import sys, runpy
sys.argv = ['run6502.py', sys.argv[1], sys.argv[2], '/dev/null']
g = runpy.run_path('/tmp/claude-1000/-mnt-c-work-My-AlteraZX/8749e485-4f6c-4753-8708-9647c6b2685a/scratchpad/dis/run6502.py')            # depacks, leaves the machine state in g
g = g['step'].__globals__                   # the live module state (run_path returns a copy)
step, rd = g['step'], g['rd']
# continue from the jump through ($00D4)
import types
mod = sys.modules.get('__main__')
g['PC'] = g['rd'](0xD4) | g['rd'](0xD5) << 8
seen = []
for n in range(200000):
    pc = g['PC']
    seen.append(pc)
    if len(seen) > 3 and seen[-1] in (0xA40F, 0xA3CB, 0xA4A9) :
        print('reached frame wait at $%04X after %d instructions' % (pc, n)); break
    if pc >= 0xC000 and g['portb'] & 1:
        print('ENTERED OS ROM at $%04X after %d instructions; last PCs:' % (pc, n), ' '.join('%04X' % p for p in seen[-12:])); break
    step()
else:
    print('no frame wait within 200000 instructions; last', ' '.join('%04X' % p for p in seen[-12:]))
print('first 40 PCs:', ' '.join('%04X' % p for p in seen[:40]))
