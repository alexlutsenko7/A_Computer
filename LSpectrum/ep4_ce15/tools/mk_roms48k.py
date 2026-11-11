#!/usr/bin/env python3
"""mk_roms48k.py ZX128.ROM [DIAG.ROM] OUT.hex [OUT.mem] -- LSpectrum's 48 KB ROM image for flash 0x500000.

  0x0000-0x7FFF  ZX Spectrum 128 ROMs (ROM 0 editor, ROM 1 48K BASIC; (c) Amstrad, redistribution for
                 emulator use allowed with the copyright messages unchanged, not for sale)
  0x8000-0xBFFF  the ROM started by F1 at power-up: a diagnostics ROM (e.g. Retroleum's DiagROM, which is
                 not in the public repository: its licence is not known) or, without DIAG.ROM, a copy
                 of the 48K BASIC ROM (F1 then simply starts 48K BASIC)
OUT.hex: Intel hex, 32 bytes per record (the .cof reads it; the .jic stores it bit-reversed, the loader
detects that). OUT.mem: one byte per line (the simulation's flash model).
Run from LSpectrum/ep4_ce15/: python3 tools/mk_roms48k.py ../../roms/zx128.rom ../../roms/diagrom_v159.rom roms48k.hex sim/roms.mem
"""
import sys

def main():
    a = sys.argv[1:]
    if len(a) < 2:
        sys.exit(__doc__)
    zx = open(a[0], 'rb').read()
    if len(zx) != 32768:
        sys.exit('ZX128.ROM must be 32 KB')
    diag = None
    if len(a) >= 3 and a[1].lower().endswith('.rom'):
        diag = open(a[1], 'rb').read()
        if len(diag) != 16384:
            sys.exit('DIAG.ROM must be 16 KB')
        a = a[2:]
    else:
        a = a[1:]
    img = zx + (diag if diag else zx[0x4000:0x8000])
    with open(a[0], 'w', newline='\n') as f:
        for o in range(0, len(img), 32):
            rec = bytes([32, o >> 8, o & 0xFF, 0]) + img[o:o + 32]
            f.write(':%s%02X\n' % (rec.hex().upper(), (-sum(rec)) & 0xFF))
        f.write(':00000001FF\n')
    if len(a) > 1:
        with open(a[1], 'w', newline='\n') as f:
            for b in img:
                f.write('%02X\n' % b)
    print('%s: 48 KB (%s at 0x8000)' % (a[0], 'diagnostics ROM' if diag else '48K BASIC copy'))

main()
