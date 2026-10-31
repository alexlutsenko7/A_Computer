#!/usr/bin/env python3
"""mkfont.py ROM OUT.hex -- OSD font for rtl/zx_video.v: the Spectrum character set
(48K BASIC ROM, 0x3D00: characters 0x20-0x7F, 8 bytes each) as 128 x 8 bytes
(codes 0x00-0x1F blank), one hex byte per line. ROM = roms/zx128.rom (ROM 1 at 0x4000)."""
import sys

rom = open(sys.argv[1], "rb").read()
assert len(rom) == 32768, "expected the 32 KB 128K ROM set"
font = rom[0x4000 + 0x3D00:0x4000 + 0x4000]
assert len(font) == 96 * 8
data = bytes(32 * 8) + font
with open(sys.argv[2], "w", newline="\n") as f:
    f.write("".join(f"{b:02x}\n" for b in data))
