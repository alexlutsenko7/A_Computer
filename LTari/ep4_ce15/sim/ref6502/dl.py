import sys
src = open(__file__.rsplit('/', 1)[0] + '/run6502.py').read().split("PC = 0x2600; cnt = 0")[0]
g = {'__file__': __file__.rsplit('/', 1)[0] + '/run6502.py'}
sys.argv = ['x', sys.argv[1], sys.argv[2], '/dev/null']
exec(compile(src, 'run6502', 'exec'), g)
g['PC'] = 0x2600
while g['PC'] != 0x0812: g['step']()
ram = g['ram']
a = 0x0458; lines = 0; out = []
for i in range(40):
    b = ram[a]; a += 1
    mode = b & 0x0F
    if b & 0x40 and mode: out.append('LMS %02X->$%02X%02X' % (b, ram[a+1], ram[a])); a += 2
    elif mode == 1: out.append('JMP/JVB %02X $%02X%02X' % (b, ram[a+1], ram[a])); break
    else: out.append('%02X' % b)
print(' '.join(out))
