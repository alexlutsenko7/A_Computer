#!/usr/bin/env python3
"""mk_xextest.py -- test disk for tb_atari +define+XEX: the .xex boot loader (xexboot.mem, from
../tools/mk_xexboot.py) + a test .xex as the ESP32 serves it (atari.cpp): sectors 1-3 loader with the
file length at LEN_OFS, sectors 4.. the file. Writes disk.mem (one byte per line).
The test program: an INIT segment ($3000: $AA -> $3100), a byte at $A000 (RAM only with BASIC off), the
main program ($3010) printing "XEX OK" if both are there, else "XEX BAD"; RUNAD = $3010."""
import re
hdr = open('../../../ESP32/v2/src/atari_xexboot.h').read()
lofs = int(re.search(r'XEXBOOT_LEN_OFS (\d+)', hdr).group(1))
boot = bytearray(int(l, 16) for l in open('xexboot.mem'))
init = bytes([0xA9, 0xAA, 0x8D, 0x00, 0x31, 0x60]) + bytes(10)                  # $3000-$300F
main = bytes([0xAD, 0x00, 0x31, 0xC9, 0xAA, 0xD0, 0x13,                          # $3010 LDA $3100 / CMP / BNE bad
              0xAD, 0x00, 0xA0, 0xC9, 0x55, 0xD0, 0x0C,                          # $3017 LDA $A000 / CMP / BNE bad
              0xA0, 0x00, 0xB9, 0x40, 0x30, 0x30, 0x11, 0x91, 0x58, 0xC8, 0xD0, 0xF6,   # $301E ok loop
              0xA0, 0x00, 0xB9, 0x50, 0x30, 0x30, 0x05, 0x91, 0x58, 0xC8, 0xD0, 0xF6,   # $302A bad loop
              0x4C, 0x36, 0x30])                                                 # $3036 hang
main = main + bytes(0x30 - len(main))                                            # to $3040
main += bytes([0x38, 0x25, 0x38, 0x00, 0x2F, 0x2B, 0xFF]) + bytes(9)             # $3040 XEX OK
main += bytes([0x38, 0x25, 0x38, 0x00, 0x22, 0x21, 0x24, 0xFF]) + bytes(8)       # $3050 XEX BAD
assert len(main) == 0x50
def seg(a, d): return bytes([a & 255, a >> 8, (a + len(d) - 1) & 255, (a + len(d) - 1) >> 8]) + d
xex = b'\xFF\xFF' + seg(0x3000, init) + seg(0x02E2, b'\x00\x30') + seg(0x3010, main) + \
      seg(0xA000, b'\x55') + seg(0x02E0, b'\x10\x30')
boot[lofs:lofs + 3] = bytes([len(xex) & 255, (len(xex) >> 8) & 255, len(xex) >> 16])
disk = bytes(boot) + xex + bytes(-len(xex) % 128)
open('disk.mem', 'w').write(''.join('%02x\n' % b for b in disk))
print('disk.mem: %d sectors, xex %d bytes' % (len(disk) // 128, len(xex)))
