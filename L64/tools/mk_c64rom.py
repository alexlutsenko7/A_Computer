#!/usr/bin/env python3
"""mk_c64rom.py -- builds the L64 ROM image (48 KB) from the user's own ROM files.

Layout (c64_system.v, loaded from flash 0x200000 to SDRAM 0x10000 by rom_loader):
  0x0000  header, 4 KB: byte 0 = F3 (the loader's bit-order mark), 1..12 "L64 ROMS" + 4 spaces,
          13 = 1 if a 1541 ROM is included, rest FF
  0x1000  CHAR    4 KB  (chargen / characters.901225-01.bin)
  0x2000  BASIC   8 KB  (basic.901226-01.bin)
  0x4000  KERNAL  8 KB  (kernal.901227-03.bin)
  0x6000  FF      8 KB
  0x8000  1541    16 KB (DOS 2.6, e.g. VICE dos1541-325302-01+901229-05.bin), optional (else FF)
The Commodore ROMs are not part of this project (copyright): bring your own, e.g. from VICE.
c64.cpp (ESP32) builds the same image from /ROMS/C64/ on the SD card.

  python3 mk_c64rom.py KERNAL BASIC CHAR [D1541] OUT    OUT.hex = Intel HEX for a .cof (local tests),
                                                       OUT.mem = one byte per line for the testbench
"""
import sys

def load(path, size):
    data = open(path, 'rb').read()
    if len(data) != size:
        sys.exit(f"{path}: {len(data)} bytes, expected {size}")
    return data

def main():
    if len(sys.argv) not in (5, 6):
        sys.exit(__doc__)
    kernal = load(sys.argv[1], 8192)
    basic  = load(sys.argv[2], 8192)
    char   = load(sys.argv[3], 4096)
    d1541  = load(sys.argv[4], 16384) if len(sys.argv) == 6 else None
    hdr = bytearray(b'\xff' * 4096)
    hdr[0] = 0xF3
    hdr[1:13] = b'L64 ROMS    '
    hdr[13] = 1 if d1541 else 0
    img = bytes(hdr) + char + basic + kernal + b'\xff' * 8192 + (d1541 or b'\xff' * 16384)
    out = sys.argv[-1]
    with open(out + '.mem', 'w', newline='\n') as f:
        for b in img:
            f.write(f"{b:02X}\n")
    with open(out + '.hex', 'w', newline='\n') as f:     # Intel HEX, relative addresses (cof: hex_offset)
        for a in range(0, len(img), 16):
            rec = bytes([16, a >> 8 & 0xFF, a & 0xFF, 0]) + img[a:a + 16]
            f.write(':' + rec.hex().upper() + f"{(-sum(rec)) & 0xFF:02X}\n")
        f.write(':00000001FF\n')
    print(f"{out}.hex / {out}.mem: {len(img)} bytes")

if __name__ == '__main__':
    main()
