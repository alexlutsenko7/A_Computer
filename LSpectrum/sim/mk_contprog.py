#!/usr/bin/env python3
"""mk_contprog.py OUT.hex -- tb_cont.sv program: 8000 NOPs at 6000 (contended RAM), JP back;
the ROM loop: HALT, JP 6000 (IM 1, handler at 0038 = EI; RET)."""
import sys
c = bytearray(0x40)
p = bytes([0xF3, 0x31, 0x00, 0xBF,                    # di ; ld sp,BF00
           0x21, 0x00, 0x60, 0x36, 0x00,              # ld hl,6000 ; ld (hl),0
           0x11, 0x01, 0x60, 0x01, 0x3F, 0x1F,        # ld de,6001 ; ld bc,1F3F
           0xED, 0xB0,                                # ldir            (6000-7F3F = NOP)
           0x3E, 0xC3, 0x32, 0x40, 0x7F,              # ld a,C3 ; ld (7F40),a
           0x21, 0x40, 0x00, 0x22, 0x41, 0x7F,        # ld hl,0040 ; ld (7F41),hl   (JP 0040)
           0xED, 0x56, 0xFB, 0xC3, 0x40, 0x00])       # im 1 ; ei ; jp 0040
c[0:len(p)] = p
c[0x38:0x3A] = bytes([0xFB, 0xC9])                    # 0038: ei ; ret
c += bytes([0x76, 0xC3, 0x00, 0x60])                  # 0040: halt ; jp 6000
open(sys.argv[1], "w").write("".join("%02x\n" % x for x in c))
