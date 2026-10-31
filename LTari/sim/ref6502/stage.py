import sys
src = open(__file__.rsplit('/', 1)[0] + '/run6502.py').read()
# stop before the depacker run, then step it here with markers
src = src.split("PC = 0x2600; cnt = 0")[0]
g = {'__file__': __file__.rsplit('/', 1)[0] + '/run6502.py'}
sys.argv = ['x', sys.argv[1], sys.argv[2], '/dev/null']
exec(compile(src, 'run6502', 'exec'), g)
CYC = {'imp': 2, 'acc': 2, 'imm': 2, 'zp': 3, 'zpx': 4, 'zpy': 4, 'rel': 3, 'abs': 4, 'absx': 5, 'absy': 5, 'izx': 6, 'izy': 6, 'ind': 5}
g['PC'] = 0x2600
n = cyc = 0; first0836 = None; marks = []
while True:
    pc = g['PC']
    if g['rd'](pc) == 0x6C and g['rd'](pc + 1) == 0xD4 and g['rd'](pc + 2) == 0: break
    m, mode = g['T'][g['rd'](pc)]
    c = CYC[mode] + (2 if m in ('JSR', 'RTS', 'RTI') else 0) + (2 if m in ('INC', 'DEC', 'ASL', 'LSR', 'ROL', 'ROR') and mode != 'acc' else 0)
    if pc == 0x0836 and first0836 is None: first0836 = (n, cyc)
    g['step'](); n += 1; cyc += c
print('stage 1: %d instructions, ~%.2f M cycles' % (first0836[0], first0836[1] / 1e6))
print('stage 2: %d instructions, ~%.2f M cycles' % (n - first0836[0], (cyc - first0836[1]) / 1e6))
print('total ~%.2f M cycles = %.2f s at 1.77 MHz without DMA' % (cyc / 1e6, cyc / 1.7734e6))
