#!/usr/bin/env python3
"""mk_testrom.py -- LMega: a small test cartridge for the simulation (testrom.bin, 64 KB).

The 68000 program (written here word by word) sets the VDP up for a 320 x 224 picture, loads two
colours and one tile, fills plane A with that tile, checks its RAM and then loops:
  - the picture must become vertical stripes (the tile's left half colour 1, right half colour 2)
  - RAM $FF0010 must hold $600D (RAM test passed) and $FF0012 a counter that keeps running
"""
import struct

ROM_LEN = 0x10000
STACK = 0x00FF8000
START = 0x200
VDP_DATA = 0xC00000
VDP_CTRL = 0xC00004
# VDP register writes: mode 5, display on, plane A at $C000, plane B at $E000, 40 columns, step 2, 64 x 32 cells
VDP_REGS = (0x8004, 0x8144, 0x8230, 0x8407, 0x8C81, 0x8F02, 0x9001)
# colour 1 red, colour 2 green (CRAM words: ----BBB-GGG-RRR-)
COLOURS = (0x0000, 0x000E, 0x00E0)
# cells of plane A that are written: 64 x 28
CELLS = 64 * 28
PASS_MARK = 0x600D
FAIL_MARK = 0xBAD0


def main():
    code = []

    def w(*words):
        code.extend(words)

    def move_w_imm_abs(value, addr):
        # move.w #value,addr.l
        w(0x33FC, value, addr >> 16, addr & 0xFFFF)

    def move_l_imm_abs(value, addr):
        # move.l #value,addr.l
        w(0x23FC, value >> 16, value & 0xFFFF, addr >> 16, addr & 0xFFFF)

    # move.w #$2700,sr: interrupts off
    w(0x46FC, 0x2700)
    for reg in VDP_REGS:
        move_w_imm_abs(reg, VDP_CTRL)
    # CRAM write at 0, three colours
    move_l_imm_abs(0xC0000000, VDP_CTRL)
    for colour in COLOURS:
        move_w_imm_abs(colour, VDP_DATA)
    # VRAM write at $0020: tile 1, eight rows of 1111 2222
    move_l_imm_abs(0x40200000, VDP_CTRL)
    for _ in range(8):
        move_l_imm_abs(0x11112222, VDP_DATA)
    # VRAM write at $C000: plane A, every cell tile 1
    move_l_imm_abs(0x40000003, VDP_CTRL)
    # move.w #CELLS-1,d0 ; loop: move.w #1,VDP_DATA ; dbra d0,loop
    w(0x303C, CELLS - 1)
    w(0x33FC, 0x0001, VDP_DATA >> 16, VDP_DATA & 0xFFFF)
    w(0x51C8, 0xFFF6)
    # RAM test: write $1234 and $5678, read both back
    move_w_imm_abs(0x1234, 0x00FF0000)
    move_w_imm_abs(0x5678, 0x00FF0002)
    # move.w $FF0000,d1 ; cmpi.w #$1234,d1 ; bne fail
    w(0x3239, 0x00FF, 0x0000, 0x0C41, 0x1234, 0x6600, 0x001A)
    # move.w $FF0002,d1 ; cmpi.w #$5678,d1 ; bne fail
    w(0x3239, 0x00FF, 0x0002, 0x0C41, 0x5678, 0x6600, 0x000C)
    move_w_imm_abs(PASS_MARK, 0x00FF0010)
    # bra.s count
    w(0x6008)
    # fail:
    move_w_imm_abs(FAIL_MARK, 0x00FF0010)
    # count: addq.w #1,$FF0012 ; bra.s count
    w(0x5279, 0x00FF, 0x0012, 0x60F8)

    rom = bytearray(b'\xFF' * ROM_LEN)
    rom[0:8] = struct.pack('>II', STACK, START)
    # every other vector to the start as well
    for vector in range(2, 64):
        rom[vector * 4:vector * 4 + 4] = struct.pack('>I', START)
    rom[0x100:0x110] = b'SEGA MEGA DRIVE '
    rom[0x1F0:0x1F3] = b'JUE'
    for index, word in enumerate(code):
        rom[START + 2 * index:START + 2 * index + 2] = struct.pack('>H', word)
    open('testrom.bin', 'wb').write(rom)
    print('testrom.bin: %d words of code' % len(code))


main()
