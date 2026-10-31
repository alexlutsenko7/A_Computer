#!/usr/bin/env python3
"""mk_inputprog.py OUT.hex -- tb_input.sv program (input latency).

Border = (Kempston Fire ? 2 : 0) | (Space ? 4 : 0), recomputed by
  mode 0 (byte at 8000 = 0): a tight loop, interrupts off (raw hardware latency);
  mode 1 (byte at 8000 != 0): HALT, then one read per frame (as a game does).
"""
import sys

code = bytearray(0x40)
code[0:10] = bytes([0xF3, 0x31, 0x00, 0xBF, 0xED, 0x56, 0xC3, 0x00, 0x01, 0x00])  # di ; ld sp,BF00 ; im 1 ; jp 0100
code[0x38:0x3A] = bytes([0xFB, 0xC9])                                             # 0038: ei ; ret
code += bytes(0x100 - len(code))

def body():
    # ld e,0 ; in a,(1F) ; and 10 ; jr z,+2 ; ld e,2 ;
    # ld a,7F ; in a,(FE) ; rra ; jr c,+2 ; set 2,e ; ld a,e ; out (FE),a
    return bytes([0x1E, 0x00, 0xDB, 0x1F, 0xE6, 0x10, 0x28, 0x02, 0x1E, 0x02,
                  0x3E, 0x7F, 0xDB, 0xFE, 0x1F, 0x38, 0x02, 0xCB, 0xD3, 0x7B, 0xD3, 0xFE])

# 0100: tight loop
loop = bytes([0x3A, 0x00, 0x80, 0xB7]) + bytes([0x20, 0x00]) + body()   # ld a,(8000) ; or a ; jr nz,FRAME
loop += bytes([0x18, (-(len(loop) + 2)) & 0xFF])                          # jr 0100
loop = bytearray(loop)
loop[5] = len(loop) - 6                                                   # jr nz -> FRAME (right after the loop)
code += loop
# FRAME: ei ; F: halt ; body ; jr F
frame = bytes([0xFB, 0x76]) + body()
frame += bytes([0x18, (-(len(frame) - 1 + 2)) & 0xFF])
code += frame

open(sys.argv[1], "w").write("".join("%02x\n" % x for x in code))
