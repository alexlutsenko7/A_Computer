#!/usr/bin/env python3
"""mkcart.py DIR -- test cartridge files for cart_test.cpp (made up: no game data)

  T1.NES  mapper 1, 32 KB program, 8 KB pictures, battery     T2.NES  mapper 2, 64 KB program, picture RAM
  T5.NES  mapper 5 (not in the core)                          BAD.NES not a cartridge file
  G1.MD   256 KB, runs in America, battery RAM $200001-$203FFF   G1.SMD the same as an .smd file
  EU.MD   runs in Europe only                                 JP.BIN  runs in Japan only
"""
import os
import struct
import sys

OUT = sys.argv[1]
NES_PRG_UNIT = 16384
NES_CHR_UNIT = 8192
MD_LEN = 0x40000
SMD_BLOCK = 16384
SMD_HDR = 512


def pattern(count, seed):
    """bytes that depend on their position"""
    return bytes(((i * 7) ^ (i >> 8) ^ seed) & 0xFF for i in range(count))


def nes(name, mapper, prg_units, chr_units, flags6):
    header = b'NES\x1a' + bytes([prg_units, chr_units, flags6 | ((mapper & 15) << 4), mapper & 0xF0]) + bytes(8)
    data = header + pattern(prg_units * NES_PRG_UNIT, mapper) + pattern(chr_units * NES_CHR_UNIT, mapper + 100)
    open(os.path.join(OUT, name), 'wb').write(data)


def md(name, region, ram=None):
    rom = bytearray(pattern(MD_LEN, 55))
    rom[0x100:0x110] = b'SEGA GENESIS    '
    rom[0x1B0:0x1BC] = b' ' * 12
    # the battery RAM's range
    if ram:
        rom[0x1B0:0x1B4] = b'RA\xf8\x20'
        rom[0x1B4:0x1BC] = struct.pack('>II', ram[0], ram[1])
    rom[0x1F0:0x1F3] = region.ljust(3).encode()
    open(os.path.join(OUT, name), 'wb').write(rom)
    return bytes(rom)


def smd(name, rom):
    out = bytearray(SMD_HDR)
    out[8:10] = b'\xaa\xbb'
    # each 16 KB block: the odd bytes, then the even bytes
    for block in range(0, len(rom), SMD_BLOCK):
        part = rom[block:block + SMD_BLOCK]
        out += part[1::2] + part[0::2]
    open(os.path.join(OUT, name), 'wb').write(out)


nes('T1.NES', 1, 2, 1, 0x02)
nes('T2.NES', 2, 4, 0, 0x01)
nes('T5.NES', 5, 2, 1, 0x00)
open(os.path.join(OUT, 'BAD.NES'), 'wb').write(b'not a cartridge file at all' * 40)
g1 = md('G1.MD', 'U', (0x200001, 0x203FFF))
smd('G1.SMD', g1)
md('EU.MD', 'E')
md('JP.BIN', 'J')
