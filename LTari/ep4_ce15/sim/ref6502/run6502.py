"""Minimal 6502 interpreter (documented opcodes) to run Delirium Tremens' depacker:
the Atari state after loading, then from $2600 until the jump through ($00D4)."""
import sys
sys.path.insert(0, __file__.rsplit('/', 1)[0])
from d6502 import T, SZ, dis

xex, osrom = sys.argv[1], sys.argv[2]
ram = bytearray(65536)
os_rom = open(osrom, 'rb').read()          # $C000-$FFFF (self-test at $D000-$D7FF unused here)
portb = 0xFF
d = open(xex, 'rb').read()
segs = []
i = 0
while i < len(d):
    if d[i:i + 2] == b'\xff\xff': i += 2
    s = d[i] | d[i + 1] << 8; e = d[i + 2] | d[i + 3] << 8; i += 4
    segs.append((s, e, d[i:i + e - s + 1])); i += e - s + 1


def load(k):
    s, e, b = segs[k]
    ram[s:s + len(b)] = b


def rd(a):
    a &= 0xFFFF
    if 0xD000 <= a < 0xD800:
        if a == 0xD40B: return 0                   # VCOUNT: the waits end at once
        if a == 0xD301: return portb
        return 0xFF
    if portb & 1 and a >= 0xC000:                  # OS ROM in
        return os_rom[a - 0xC000]
    return ram[a]


def wr(a, v):
    global portb
    a &= 0xFFFF
    if 0xD000 <= a < 0xD800:
        if a == 0xD301: portb = v
        return
    if portb & 1 and a >= 0xC000: return            # ROM
    ram[a] = v & 0xFF


A = X = Y = 0; S = 0xFF; C = Z = N = V = I = D = 0; PC = 0


def setnz(v):
    global Z, N
    Z = int((v & 0xFF) == 0); N = (v >> 7) & 1
    return v & 0xFF


def ea(mode):
    lo = rd(PC + 1); w = lo | rd(PC + 2) << 8
    if mode == 'zp': return lo
    if mode == 'zpx': return (lo + X) & 0xFF
    if mode == 'zpy': return (lo + Y) & 0xFF
    if mode == 'abs': return w
    if mode == 'absx': return (w + X) & 0xFFFF
    if mode == 'absy': return (w + Y) & 0xFFFF
    if mode == 'izx': p = (lo + X) & 0xFF; return rd(p) | rd((p + 1) & 0xFF) << 8
    if mode == 'izy': return ((rd(lo) | rd((lo + 1) & 0xFF) << 8) + Y) & 0xFFFF
    if mode == 'ind': return rd(w) | rd((w & 0xFF00) | ((w + 1) & 0xFF)) << 8
    raise Exception(mode)


def push(v):
    global S
    ram[0x100 + S] = v & 0xFF; S = (S - 1) & 0xFF


def pull():
    global S
    S = (S + 1) & 0xFF; return ram[0x100 + S]


def adc(v):
    global A, C, V
    r = A + v + C
    V = int(((A ^ r) & (v ^ r) & 0x80) != 0); C = int(r > 0xFF); A = setnz(r)


def cmp(r, v):
    global C
    C = int(r >= v); setnz(r - v)


def step():
    global A, X, Y, S, C, Z, N, V, I, D, PC
    op = rd(PC)
    if op not in T: raise Exception('opcode %02X at %04X' % (op, PC))
    m, mode = T[op]; n = SZ[mode]; npc = (PC + n) & 0xFFFF
    if mode == 'imm': val = rd(PC + 1)
    elif mode not in ('imp', 'acc', 'rel'): addr = ea(mode)
    if m == 'LDA': A = setnz(val if mode == 'imm' else rd(addr))
    elif m == 'LDX': X = setnz(val if mode == 'imm' else rd(addr))
    elif m == 'LDY': Y = setnz(val if mode == 'imm' else rd(addr))
    elif m == 'STA': wr(addr, A)
    elif m == 'STX': wr(addr, X)
    elif m == 'STY': wr(addr, Y)
    elif m in ('ADC', 'SBC', 'AND', 'ORA', 'EOR', 'CMP', 'CPX', 'CPY', 'BIT'):
        v = val if mode == 'imm' else rd(addr)
        if m == 'ADC': adc(v)
        elif m == 'SBC': adc(v ^ 0xFF)
        elif m == 'AND': A = setnz(A & v)
        elif m == 'ORA': A = setnz(A | v)
        elif m == 'EOR': A = setnz(A ^ v)
        elif m == 'CMP': cmp(A, v)
        elif m == 'CPX': cmp(X, v)
        elif m == 'CPY': cmp(Y, v)
        elif m == 'BIT': Z = int((A & v) == 0); N = (v >> 7) & 1; V = (v >> 6) & 1
    elif m in ('ASL', 'LSR', 'ROL', 'ROR', 'INC', 'DEC'):
        v = A if mode == 'acc' else rd(addr)
        if m == 'ASL': C = (v >> 7) & 1; r = v << 1
        elif m == 'LSR': C = v & 1; r = v >> 1
        elif m == 'ROL': r = (v << 1) | C; C = (v >> 7) & 1
        elif m == 'ROR': r = (v >> 1) | (C << 7); C = v & 1
        elif m == 'INC': r = v + 1
        else: r = v - 1
        r = setnz(r)
        if mode == 'acc': A = r
        else: wr(addr, r)
    elif m == 'INX': X = setnz(X + 1)
    elif m == 'INY': Y = setnz(Y + 1)
    elif m == 'DEX': X = setnz(X - 1)
    elif m == 'DEY': Y = setnz(Y - 1)
    elif m == 'TAX': X = setnz(A)
    elif m == 'TAY': Y = setnz(A)
    elif m == 'TXA': A = setnz(X)
    elif m == 'TYA': A = setnz(Y)
    elif m == 'TSX': X = setnz(S)
    elif m == 'TXS': S = X
    elif m == 'PHA': push(A)
    elif m == 'PLA': A = setnz(pull())
    elif m == 'PHP': push(C | Z << 1 | I << 2 | D << 3 | 0x30 | V << 6 | N << 7)
    elif m == 'PLP':
        p = pull(); C, Z, I, D, V, N = p & 1, p >> 1 & 1, p >> 2 & 1, p >> 3 & 1, p >> 6 & 1, p >> 7 & 1
    elif m in ('CLC', 'SEC', 'CLI', 'SEI', 'CLD', 'SED', 'CLV'):
        if m == 'CLC': C = 0
        elif m == 'SEC': C = 1
        elif m == 'CLI': I = 0
        elif m == 'SEI': I = 1
        elif m == 'CLD': D = 0
        elif m == 'SED': D = 1
        else: V = 0
    elif mode == 'rel':
        off = rd(PC + 1); off = off - 256 if off > 127 else off
        f = {'BCC': not C, 'BCS': C, 'BEQ': Z, 'BNE': not Z, 'BMI': N, 'BPL': not N, 'BVC': not V, 'BVS': V}[m]
        if f: npc = (npc + off) & 0xFFFF
    elif m == 'JMP': npc = addr
    elif m == 'JSR': ret = (PC + 2) & 0xFFFF; push(ret >> 8); push(ret); npc = addr
    elif m == 'RTS': lo = pull(); npc = ((pull() << 8 | lo) + 1) & 0xFFFF
    elif m == 'NOP': pass
    else: raise Exception('%s at %04X' % (m, PC))
    if D and m in ('ADC', 'SBC'): raise Exception('decimal mode at %04X' % PC)
    PC = npc


# the loader: segments 0, 1, INITAD -> the init routine (it copies $8000-$B7FF under the OS), then the rest
for k in range(3): load(k)
PC = 0x2400; push(0xFF); push(0xFE)        # a return address that ends the run
cnt = 0
while PC != 0xFFFF:
    step(); cnt += 1
print('init done after %d instructions, PORTB %02X' % (cnt, portb))
for k in range(3, len(segs)): load(k)
PC = 0x2600; cnt = 0
while True:
    if rd(PC) == 0x6C and rd(PC + 1) == 0xD4 and rd(PC + 2) == 0x00:
        break
    step(); cnt += 1
    if cnt > 50_000_000: raise Exception('runaway')
print('depacker done after %d instructions; PORTB %02X, jump to $%02X%02X' % (cnt, portb, ram[0xD5], ram[0xD4]))
open(sys.argv[3], 'wb').write(bytes(ram))
