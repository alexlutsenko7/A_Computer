#!/usr/bin/env python3
"""mksave.py OUTDIR -- TAP files for the save tests:
  save1.tap  header ("hello", Bytes) + 300-byte data block
  save2.tap  two header + data pairs (one save session)
  save3.tap  one 2000-byte block without a header (longer than the first-block buffer)"""
import os
import random
import struct
import sys

r = random.Random(7)


def blk(flag, data):
    d = bytes([flag]) + data
    cs = 0
    for b in d:
        cs ^= b
    d += bytes([cs])
    return struct.pack("<H", len(d)) + d


def hdr(name, typ, length):
    return blk(0x00, bytes([typ]) + name.ljust(10)[:10].encode() + struct.pack("<HHH", length, 32768, 0))


out = sys.argv[1]
rd = lambda n: bytes(r.randrange(256) for _ in range(n))
open(os.path.join(out, "save1.tap"), "wb").write(hdr("hello", 3, 300) + blk(0xFF, rd(300)))
open(os.path.join(out, "save2.tap"), "wb").write(hdr("part1", 0, 50) + blk(0xFF, rd(50)) +
                                                 hdr("part2", 3, 700) + blk(0xFF, rd(700)))
open(os.path.join(out, "save3.tap"), "wb").write(blk(0xFF, rd(2000)))
