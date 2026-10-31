"""stage 2 of the Delirium Tremens depacker: state at its first instruction ($0812) and a reference log of
the depacker pointers every STEP instructions from there, plus the full PC trace (for a mismatch window)"""
import sys
here = __file__.rsplit('/', 1)[0]
src = open(here + '/run6502.py').read().split("PC = 0x2600; cnt = 0")[0]
g = {'__file__': here + '/run6502.py'}
sys.argv = ['x', sys.argv[1], sys.argv[2], '/dev/null']
exec(compile(src, 'run6502', 'exec'), g)
g['PC'] = 0x2600
while g['PC'] != 0x0812: g['step']()
ram = g['ram']
open(here + '/s2_ram.bin', 'wb').write(bytes(ram))
P = g['C'] | g['Z'] << 1 | g['I'] << 2 | g['D'] << 3 | 0x30 | g['V'] << 6 | g['N'] << 7
print('stage 2 at $0812: A %02X X %02X Y %02X S %02X P %02X PORTB %02X' % (g['A'], g['X'], g['Y'], g['S'], P, g['portb']))
open(here + '/s2_regs.txt', 'w').write('%02x %02x %02x %02x\n' % (g['A'], g['X'], g['Y'], g['S']))
STEP = 500
ZP = [0xD0, 0xD1, 0xD2, 0xD3, 0xF0, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6]
n = 0
with open(here + '/s2_ref.txt', 'w') as f, open(here + '/s2_pcs.txt', 'w') as fp:
    while True:
        pc = g['PC']
        if n % STEP == 0:
            f.write(' '.join('%02x' % ram[z] for z in ZP) + '\n')
        fp.write('%04x\n' % pc)
        if g['rd'](pc) == 0x6C and g['rd'](pc + 1) == 0xD4 and g['rd'](pc + 2) == 0: break
        g['step'](); n += 1
print('stage 2: %d instructions, %d reference lines' % (n, n // STEP + 1))
