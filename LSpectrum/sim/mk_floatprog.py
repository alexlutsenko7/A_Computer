#!/usr/bin/env python3
"""mk_floatprog.py OUT.hex -- tb_float.sv program: IM 1, then after each interrupt 3000 x IN A,(FF)."""
import sys
c = bytearray(0x40)
p = bytes([0xF3, 0x31, 0x00, 0xBF, 0xED, 0x56, 0xFB, 0xC3, 0x40, 0x00])   # di ; ld sp,BF00 ; im 1 ; ei ; jp 0040
c[0:len(p)] = p
c[0x38:0x3A] = bytes([0xFB, 0xC9])                                      # 0038: ei ; ret
c += bytes([0x76]) + bytes([0xDB, 0xFF]) * 3000 + bytes([0xC3, 0x40, 0x00])   # halt ; IN A,(FF) x 3000 ; jp 0040
open(sys.argv[1], "w").write("".join("%02x\n" % x for x in c))
