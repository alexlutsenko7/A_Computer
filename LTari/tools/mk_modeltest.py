#!/usr/bin/env python3
"""mk_modeltest.py OUT.xex -- LTari model test (our own 6502 code, runs from the F12 browser).

Prints the 130XE banking test: 11 into $4000, PORTB to extended bank 0 (bits 4:2 = 0), 77 into $4000,
    PORTB back, read $4000: 0B = the 77 went into the extended bank (130XE, 128 KB),
    4D = no banking (800XL, 64 KB).
The .xex loader switches BASIC off; the program sits at $3000, the screen at the top of RAM, so
$4000 is free.
"""
import sys

ORG = 0x3000
CIOV, ICCOM, ICBLL, ICBLH, PORTB, EOL = 0xE456, 0x0342, 0x0348, 0x0349, 0xD301, 0x9B

# opcodes used: (mnemonic, mode) -> code; modes imp, imm, abs, absx, rel
OPS = {('lda', 'imm'): 0xA9, ('lda', 'abs'): 0xAD, ('lda', 'absx'): 0xBD, ('sta', 'abs'): 0x8D,
       ('ldx', 'imm'): 0xA2, ('stx', 'abs'): 0x8E, ('ldx', 'abs'): 0xAE, ('inx', 'imp'): 0xE8,
       ('cpx', 'imm'): 0xE0, ('cmp', 'imm'): 0xC9, ('and', 'imm'): 0x29, ('adc', 'imm'): 0x69,
       ('lsr', 'imp'): 0x4A, ('pha', 'imp'): 0x48, ('pla', 'imp'): 0x68, ('jsr', 'abs'): 0x20,
       ('jmp', 'abs'): 0x4C, ('rts', 'imp'): 0x60, ('beq', 'rel'): 0xF0, ('bne', 'rel'): 0xD0,
       ('bcc', 'rel'): 0x90}
SIZE = dict(imp=1, imm=2, rel=2, abs=3, absx=3)

def text(s):
    return list(s.encode('ascii')) + [EOL]

# program: (label, mnemonic, mode, operand) or (label, '.bytes', list)
P = [
    ('start', 'ldx', 'imm', 0),
    ('t1',    'lda', 'absx', 'msg_t'), (None, 'beq', 'rel', 't1e'), (None, 'jsr', 'abs', 'putc'),
    (None,    'inx', 'imp', None),     (None, 'bne', 'rel', 't1'),
    # the banking test
    ('t1e',   'lda', 'abs', PORTB),    (None, 'sta', 'abs', 'save'),
    (None,    'lda', 'imm', 11),       (None, 'sta', 'abs', 0x4000),
    (None,    'lda', 'abs', 'save'),   (None, 'and', 'imm', 0xE3), (None, 'sta', 'abs', PORTB),
    (None,    'lda', 'imm', 77),       (None, 'sta', 'abs', 0x4000),
    (None,    'lda', 'abs', 'save'),   (None, 'sta', 'abs', PORTB),
    (None,    'lda', 'abs', 0x4000),   (None, 'sta', 'abs', 'res'),
    (None,    'ldx', 'imm', 0),
    ('t3',    'lda', 'absx', 'msg_b'), (None, 'beq', 'rel', 't3e'), (None, 'jsr', 'abs', 'putc'),
    (None,    'inx', 'imp', None),     (None, 'bne', 'rel', 't3'),
    ('t3e',   'lda', 'abs', 'res'),    (None, 'jsr', 'abs', 'hex'),
    (None,    'ldx', 'imm', 0),
    (None,    'lda', 'abs', 'res'),    (None, 'cmp', 'imm', 11), (None, 'beq', 'rel', 'is130'),
    ('t4',    'lda', 'absx', 'msg_8'), (None, 'beq', 'rel', 'stop'), (None, 'jsr', 'abs', 'putc'),
    (None,    'inx', 'imp', None),     (None, 'bne', 'rel', 't4'),
    ('is130', 'lda', 'absx', 'msg_1'), (None, 'beq', 'rel', 'stop'), (None, 'jsr', 'abs', 'putc'),
    (None,    'inx', 'imp', None),     (None, 'bne', 'rel', 'is130'),
    ('stop',  'jmp', 'abs', 'stop'),
    # hex: A as two hex digits
    ('hex',   'pha', 'imp', None),
    (None,    'lsr', 'imp', None), (None, 'lsr', 'imp', None), (None, 'lsr', 'imp', None), (None, 'lsr', 'imp', None),
    (None,    'jsr', 'abs', 'nib'),    (None, 'pla', 'imp', None), (None, 'and', 'imm', 0x0F),
    ('nib',   'cmp', 'imm', 10),       (None, 'bcc', 'rel', 'dig'), (None, 'adc', 'imm', 6),
    ('dig',   'adc', 'imm', 0x30),
    # putc: A to the screen editor (CIO channel 0, length 0 = the byte in A); keeps X
    ('putc',  'stx', 'abs', 'sx'),     (None, 'pha', 'imp', None),
    (None,    'ldx', 'imm', 0),        (None, 'lda', 'imm', 0x0B), (None, 'sta', 'abs', ICCOM),
    (None,    'lda', 'imm', 0),        (None, 'sta', 'abs', ICBLL), (None, 'sta', 'abs', ICBLH),
    (None,    'pla', 'imp', None),     (None, 'jsr', 'abs', CIOV),
    (None,    'ldx', 'abs', 'sx'),     (None, 'rts', 'imp', None),
    ('msg_t', '.bytes', text('') + text('LTari model test') + text('') + [0]),
    ('msg_b', '.bytes', list(b'Bank test $4000 = ') + [0]),
    ('msg_8', '.bytes', text('') + text('= 800XL (64 KB)') + [0]),
    ('msg_1', '.bytes', text('') + text('= 130XE (128 KB)') + [0]),
    ('save',  '.bytes', [0]), ('res', '.bytes', [0]), ('sx', '.bytes', [0]),
]

def assemble():
    labels = {}
    for final in (False, True):
        pc, out = ORG, bytearray()
        for item in P:
            lab, mn = item[0], item[1]
            if lab: labels[lab] = pc
            if mn == '.bytes':
                out += bytes(item[2]); pc += len(item[2]); continue
            mode, arg = item[2], item[3]
            v = labels.get(arg, 0 if not final else None) if isinstance(arg, str) else (arg or 0)
            if v is None: sys.exit('unknown label ' + arg)
            code = OPS[(mn, mode)]
            if mode == 'rel':
                d = v - (pc + 2)
                if final and not -128 <= d <= 127: sys.exit('branch out of range to ' + arg)
                b = [code, d & 0xFF]
            elif SIZE[mode] == 3: b = [code, v & 0xFF, (v >> 8) & 0xFF]
            elif SIZE[mode] == 2: b = [code, v & 0xFF]
            else: b = [code]
            out += bytes(b); pc += len(b)
    return bytes(out)

def main():
    if len(sys.argv) != 2: sys.exit(__doc__)
    code = assemble()
    end = ORG + len(code) - 1
    xex = bytes([0xFF, 0xFF, ORG & 0xFF, ORG >> 8, end & 0xFF, end >> 8]) + code
    xex += bytes([0xE0, 0x02, 0xE1, 0x02, ORG & 0xFF, ORG >> 8])          # RUNAD = start
    with open(sys.argv[1], 'wb') as f:
        f.write(xex)
    print('%s: %d bytes ($%04X-$%04X)' % (sys.argv[1], len(xex), ORG, end))

main()
