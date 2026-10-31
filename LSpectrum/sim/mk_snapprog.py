#!/usr/bin/env python3
"""mk_snapprog.py OUT.hex -- Z80 test program for tb_snap.sv (ROM 0, address 0000).

A loop of ITER iterations over many instruction kinds (DD/FD indexed, DD CB, CB, ED
incl. LDIR/CPIR/RLD/NEG/ADC/SBC, EX AF/EXX/EX (SP), DJNZ, CALL/RET, OUT to FE / 7FFD /
the AY, HALT every 4th iteration, IM 2 interrupts counted at 9E00), folding the
registers into a checksum at 9F00. At the end: R at 9FFE, 55 at 9FFF, then DI + HALT."""
import sys

ITER = 40
code = bytearray()
labels, fixups = {}, []


def b(*x):
    code.extend(x)


def w(v):
    if isinstance(v, str):
        fixups.append((len(code), v, "abs"))
        v = 0
    b(v & 0xFF, v >> 8)


def lab(n):
    labels[n] = len(code)


def rel(n):
    fixups.append((len(code), n, "rel"))
    b(0)


def d(v):
    b(v & 0xFF)


# --- init
b(0xF3)                                     # di
b(0x31); w(0xBF00)                          # ld sp,BF00
b(0x01); w(0x1357); b(0x11); w(0x2468); b(0x21); w(0x0F0F)   # every register known (sim: no X)
b(0xD9)                                     # exx
b(0x01); w(0x9ABC); b(0x11); w(0xDEF0); b(0x21); w(0x1234)
b(0xD9); b(0x08); b(0xAF); b(0x08)          # exx ; ex af,af' ; xor a ; ex af,af'
b(0x21); w("isr"); b(0x22); w(0x80FF)       # ld hl,isr ; ld (80FF),hl  (IM 2 vector, bus = FF)
b(0x3E, 0x80); b(0xED, 0x47)                # ld a,80 ; ld i,a
b(0xED, 0x5E)                               # im 2
b(0x21); w(0); b(0x22); w(0x9E00)           # ld hl,0 ; ld (9E00),hl
b(0x22); w(0x9F00)                          # ld (9F00),hl
b(0x3E, ITER); b(0x32); w(0x9F02)           # ld a,ITER ; ld (9F02),a
b(0x21); w(0x9000); b(0x06, 0x00)           # ld hl,9000 ; ld b,0
lab("fill"); b(0x70, 0x23); b(0x10); rel("fill")   # ld (hl),b ; inc hl ; djnz
b(0xDD, 0x21); w(0x9000)                    # ld ix,9000
b(0xFD, 0x21); w(0x9100)                    # ld iy,9100
b(0xFB)                                     # ei

lab("main")
b(0x3A); w(0x9F02); b(0xE6, 0x07)           # ld a,(9F02) ; and 7
b(0x01); w(0x7FFD); b(0xED, 0x79)           # ld bc,7FFD ; out (c),a     (RAM page at C000)
b(0x32); w(0xC123)                          # ld (C123),a
b(0xDD, 0x7E); d(5)                         # ld a,(ix+5)
b(0xFD, 0x86); d(-3)                        # add a,(iy-3)
b(0xDD, 0x77); d(7)                         # ld (ix+7),a
b(0xFD, 0x34); d(1)                         # inc (iy+1)
b(0xDD, 0xCB); d(2); b(0x06)                # rlc (ix+2)
b(0xFD, 0xCB); d(4); b(0xDE)                # set 3,(iy+4)
b(0xDD, 0xCB); d(2); b(0x7E)                # bit 7,(ix+2)
b(0x47)                                     # ld b,a
b(0xCB, 0x10); b(0xCB, 0x39); b(0xCB, 0x1A); b(0xCB, 0x23)   # rl b ; srl c ; rr d ; sla e
b(0x2A); w(0x9F00)                          # ld hl,(9F00)
b(0x11); w(0x1234); b(0xED, 0x5A)           # ld de,1234 ; adc hl,de
b(0x01); w(0x0F0F); b(0xED, 0x42)           # ld bc,0F0F ; sbc hl,bc
b(0x22); w(0x9F00)                          # ld (9F00),hl
b(0xED, 0x44)                               # neg
b(0x21); w(0x9010); b(0xED, 0x6F)           # ld hl,9010 ; rld
b(0x21); w(0x9000); b(0x11); w(0x9200); b(0x01); w(0x0020); b(0xED, 0xB0)   # ldir
b(0x21); w(0x9000); b(0x01); w(0x0040); b(0x3E, 0x17); b(0xED, 0xB1)       # cpir
b(0x08); b(0xD9)                            # ex af,af' ; exx
b(0x21); w(0x5555); b(0x01); w(0x0101); b(0x09)   # ld hl,5555 ; ld bc,0101 ; add hl,bc
b(0x11); w(0x2222); b(0x19)                 # ld de,2222 ; add hl,de
b(0xD9); b(0x08)                            # exx ; ex af,af'
b(0xEB); b(0xE5); b(0xE3); b(0xE1)          # ex de,hl ; push hl ; ex (sp),hl ; pop hl
b(0x06, 0x05); lab("dj"); b(0xDD, 0x34); d(0); b(0x10); rel("dj")    # ld b,5 ; inc (ix+0) ; djnz
b(0xCD); w("sub")                           # call sub
b(0x3A); w(0x9F02); b(0xE6, 0x07); b(0xD3, 0xFE)   # border
b(0x01); w(0xFFFD); b(0x3A); w(0x9F02); b(0xE6, 0x0F); b(0xED, 0x79)   # AY select = counter & 15
b(0x06, 0xBF); b(0xED, 0x41)                # ld b,BF ; out (c),b      (AY data = BF)
b(0x3A); w(0x9F02); b(0xE6, 0x03); b(0x20); rel("nohalt")
b(0x76)                                     # halt
lab("nohalt")
b(0x2A); w(0x9F00)                          # ld hl,(9F00)
b(0x09); b(0x19)                            # add hl,bc ; add hl,de
b(0xDD, 0xE5); b(0xC1); b(0x09)             # push ix ; pop bc ; add hl,bc
b(0xFD, 0xE5); b(0xC1); b(0xED, 0x4A)       # push iy ; pop bc ; adc hl,bc
b(0xF5); b(0xC1); b(0x09)                   # push af ; pop bc ; add hl,bc
b(0xD9); b(0xE5); b(0xD9); b(0xC1); b(0x09) # exx ; push hl ; exx ; pop bc ; add hl,bc
b(0x08); b(0xF5); b(0x08); b(0xC1); b(0x09) # ex af,af' ; push af ; ex af,af' ; pop bc ; add hl,bc
b(0x22); w(0x9F00)                          # ld (9F00),hl
b(0x21); w(0x9F02); b(0x35)                 # ld hl,9F02 ; dec (hl)
b(0xC2); w("main")                          # jp nz,main
b(0xED, 0x5F); b(0x32); w(0x9FFE)           # ld a,r ; ld (9FFE),a  (R before the endless HALT)
b(0xAF)                                     # xor a  (flags no longer depend on R)
b(0x3E, 0x55); b(0x32); w(0x9FFF)           # done marker
b(0xF3); lab("end"); b(0x76); b(0x18); rel("end")   # di ; halt ; jr end

lab("sub")
b(0xDD, 0x7E); d(1); b(0xFD, 0xAE); d(2); b(0xDD, 0x77); d(3); b(0xC9)   # ld a,(ix+1) ; xor (iy+2) ; ld (ix+3),a ; ret

lab("isr")
b(0xF5); b(0xE5)                            # push af ; push hl
b(0x2A); w(0x9E00); b(0x23); b(0x22); w(0x9E00)
b(0xE1); b(0xF1); b(0xFB); b(0xED, 0x4D)    # pop hl ; pop af ; ei ; reti

for pos, n, kind in fixups:
    t = labels[n]
    if kind == "abs":
        code[pos], code[pos + 1] = t & 0xFF, t >> 8
    else:
        off = t - (pos + 1)
        assert -128 <= off <= 127
        code[pos] = off & 0xFF

open(sys.argv[1], "w").write("".join("%02x\n" % x for x in code))
print("mk_snapprog: %d bytes, main %04X, end %04X, isr %04X" % (len(code), labels["main"], labels["end"], labels["isr"]))
