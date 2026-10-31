#!/usr/bin/env python3
"""mk_menufont.py -- rtl/menu_font.hex from font/spleen-8x16.bdf: characters 0-127, 16 rows each (2048 bytes,
one hex byte per line, address = character * 16 + row, leftmost pixel = bit 7). Characters the font does not have
stay blank. Run from AMenu/: python3 tools/mk_menufont.py"""
import os

here = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
rom = [0] * 2048
enc, rows, bmp = None, [], False
with open(os.path.join(here, 'font', 'spleen-8x16.bdf'), encoding='ascii') as f:
    for line in f:
        w = line.split()
        if not w:
            continue
        if w[0] == 'ENCODING':
            enc = int(w[1])
        elif w[0] == 'BBX':
            assert w[1:3] == ['8', '16'], line
        elif w[0] == 'BITMAP':
            bmp, rows = True, []
        elif w[0] == 'ENDCHAR':
            if enc is not None and 0 <= enc < 128:
                assert len(rows) == 16, enc
                rom[enc * 16:enc * 16 + 16] = rows
            bmp, enc = False, None
        elif bmp:
            rows.append(int(w[0], 16))
with open(os.path.join(here, 'rtl', 'menu_font.hex'), 'w', newline='\n') as f:
    f.write(''.join('%02X\n' % b for b in rom))
print('rtl/menu_font.hex: %d characters' % sum(1 for c in range(128) if any(rom[c * 16:c * 16 + 16])))
