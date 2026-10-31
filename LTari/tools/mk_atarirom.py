#!/usr/bin/env python3
"""mk_atarirom.py OS.rom BASIC.rom OUT -- LTari ROM image (28 KB) for the configuration flash.

  OUT.mem  one byte per line (hex) for the testbench's flash model
  OUT.hex  Intel HEX from address 0, for the .cof (hex block at the image's flash address)

Layout (rtl/atari_system.v): 0x0000 header page (F3 "LTARI ROMS" + 3 spaces, rest FF; the ROM loader
checks byte 0), 0x1000 OS (16 KB, $C000-$FFFF), 0x5000 BASIC (8 KB, $A000-$BFFF).
Default ROMs: ../roms/altirraos_xl.rom and ../roms/altirra_basic.rom (Avery Lee, freely
distributable, see ../roms/README.md).
"""
import sys

def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    os_rom = open(sys.argv[1], 'rb').read()
    basic = open(sys.argv[2], 'rb').read()
    if len(os_rom) != 16384 or len(basic) != 8192:
        sys.exit('OS must be 16 KB and BASIC 8 KB')
    hdr = bytearray(b'\xFF' * 4096)
    hdr[0] = 0xF3
    hdr[1:14] = b'LTARI ROMS   '
    img = bytes(hdr) + os_rom + basic
    assert len(img) == 28672
    with open(sys.argv[3] + '.mem', 'w') as f:
        f.write(''.join('%02x\n' % b for b in img))
    with open(sys.argv[3] + '.hex', 'w') as f:
        for a in range(0, len(img), 16):
            rec = bytes([16, a >> 8, a & 0xFF, 0]) + img[a:a + 16]
            f.write(':%s%02X\n' % (rec.hex().upper(), (-sum(rec)) & 0xFF))
        f.write(':00000001FF\n')
    print('%s.mem / .hex: %d bytes' % (sys.argv[3], len(img)))

main()
