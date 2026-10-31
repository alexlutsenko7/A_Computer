import sys, runpy
OUT = '/tmp/claude-1000/-mnt-c-work-My-AlteraZX/8749e485-4f6c-4753-8708-9647c6b2685a/scratchpad/dis/ref_trace.txt'
sys.argv = ['run6502.py', sys.argv[1], sys.argv[2], '/dev/null']
g = runpy.run_path(__file__.rsplit('/', 1)[0] + '/run6502.py')['step'].__globals__
g['PC'] = g['rd'](0xD4) | g['rd'](0xD5) << 8
with open(OUT, 'w') as f:
    for n in range(15000):
        f.write('%04x\n' % g['PC'])
        g['step']()
