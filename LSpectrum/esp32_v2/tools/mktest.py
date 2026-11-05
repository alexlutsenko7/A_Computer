#!/usr/bin/env python3
"""mktest.py OUTDIR -- generate the test card tree:
  TEST1.TAP                       standard ROM header + 2000-byte data block
  test2.tzx                       every TZX block type the player handles, incl. loops/jumps/calls,
                                  a stop block and skipped/unknown blocks
  short.tzx                       small and fast (used by the RTL simulation)
  Big Folder Name/Long named game file number one.tzx   (= test2.tzx)
  GAMES/game_NN *.tap             30 short TAP files (multi-cluster directory, sorting)
  readme.txt                      must not be listed"""
import os
import random
import struct
import sys

rnd = random.Random(1234)


def tap_block(data):
    cs = 0
    for b in data:
        cs ^= b
    blk = bytes(data) + bytes([cs])
    return struct.pack("<H", len(blk)) + blk


def header(name, length):
    return bytes([0x00, 3]) + name.ljust(10)[:10].encode() + struct.pack("<HHH", length, 32768, 0)


def tzx(blocks):
    return b"ZXTape!\x1a\x01\x14" + b"".join(blocks)


h16 = lambda v: struct.pack("<H", v)
h24 = lambda v: struct.pack("<I", v)[:3]
h32 = lambda v: struct.pack("<I", v)


def b10(pause, data):           return b"\x10" + h16(pause) + h16(len(data)) + data
def b11(pl, s1, s2, z, o, n, last, pause, data):
    return b"\x11" + h16(pl) + h16(s1) + h16(s2) + h16(z) + h16(o) + h16(n) + bytes([last]) + h16(pause) + h24(len(data)) + data
def b12(ln, n):                 return b"\x12" + h16(ln) + h16(n)
def b13(pulses):                return b"\x13" + bytes([len(pulses)]) + b"".join(h16(p) for p in pulses)
def b14(z, o, last, pause, data):
    return b"\x14" + h16(z) + h16(o) + bytes([last]) + h16(pause) + h24(len(data)) + data
def b15(tps, pause, last, data):
    return b"\x15" + h16(tps) + h16(pause) + bytes([last]) + h24(len(data)) + data
def b20(ms):                    return b"\x20" + h16(ms)
def b21(name):                  return b"\x21" + bytes([len(name)]) + name
def b23(rel):                   return b"\x23" + struct.pack("<h", rel)
def b24(n):                     return b"\x24" + h16(n)
def b26(offs):                  return b"\x26" + h16(len(offs)) + b"".join(struct.pack("<h", o) for o in offs)
def b2b(level):                 return b"\x2b" + h32(1) + bytes([level])
def b30(text):                  return b"\x30" + bytes([len(text)]) + text


def rand(n):
    return bytes(rnd.randrange(256) for _ in range(n))


def test2():
    flagged = lambda flag, d: bytes([flag]) + d + bytes([0])
    return tzx([
        b30(b"LSpectrum test"),                                         # 0
        b"\x32" + h16(5) + b"\x01\x00\x03abc",                         # 1 archive info
        b10(500, flagged(0x00, rand(17))),                              # 2 standard, header
        b11(1500, 400, 500, 300, 600, 300, 5, 200, rand(100)),          # 3 turbo, 5 bits in last byte
        b21(b"grp"),                                                    # 4 group start
        b12(1000, 50),                                                  # 5 tone
        b13([300, 400, 500]),                                           # 6 pulses
        b"\x22",                                                        # 7 group end
        b14(250, 500, 8, 0, rand(40)),                                  # 8 pure data, no pause
        b2b(1),                                                         # 9 level high
        b15(79, 100, 3, rand(30)),                                      # 10 direct recording
        b20(300),                                                       # 11 pause
        b24(3),                                                         # 12 loop x3
        b12(700, 10),                                                   # 13
        b13([123]),                                                     # 14
        b"\x25",                                                        # 15 loop end
        b26([3, 5]),                                                    # 16 call 19, 21
        b23(6),                                                         # 17 jump to 23
        b12(999, 7),                                                    # 18 never played
        b12(555, 9),                                                    # 19
        b"\x27",                                                        # 20 return
        b13([111, 222]),                                                # 21
        b"\x27",                                                        # 22 return
        b"\x35" + b"CUSTOMINFO" + h32(3) + b"xyz",                      # 23 custom info
        b"\x5a" + b"XTape!\x1a\x01\x14",                                # 24 glue
        b20(0),                                                         # 25 stop the tape
        b"\x19" + h32(6) + rand(6),                                     # 26 generalized data (skipped)
        b"\x2a" + h32(0),                                               # 27 stop if 48K (ignored)
        b"\x33" + bytes([1, 0, 1, 2]),                                  # 28 hardware info
        b"\x31" + bytes([5, 3]) + b"hi!",                               # 29 message
        b"\x18" + h32(4) + rand(4),                                     # 30 CSW (skipped)
        b10(1000, flagged(0xFF, rand(300))),                            # 31 standard, data
        b"\x99" + h32(2) + b"??",                                       # 32 unknown block
        b12(2168, 5),                                                   # 33
    ])


def short():
    return tzx([
        b11(300, 100, 120, 60, 120, 12, 6, 1, rand(6)),
        b12(80, 4),
        b13([70, 90]),
        b2b(1),
        b15(40, 0, 4, rand(2)),
        b14(50, 100, 8, 1, rand(3)),
        b20(0),
        b12(60, 6),
    ])


def main():
    out = sys.argv[1]
    os.makedirs(os.path.join(out, "Big Folder Name"), exist_ok=True)
    os.makedirs(os.path.join(out, "GAMES"), exist_ok=True)
    data = bytes([0xFF]) + rand(2000)
    open(os.path.join(out, "TEST1.TAP"), "wb").write(tap_block(header("test1", 2000)) + tap_block(data))
    t2 = test2()
    open(os.path.join(out, "test2.tzx"), "wb").write(t2)
    open(os.path.join(out, "Big Folder Name", "Long named game file number one.tzx"), "wb").write(t2)
    open(os.path.join(out, "short.tzx"), "wb").write(short())
    for i in range(30):
        name = f"game_{29 - i:02d} {'Zx' if i % 2 else 'aB'}.tap"
        d = bytes([0xFF]) + rand(20 + i)
        open(os.path.join(out, "GAMES", name), "wb").write(tap_block(header(f"g{i}", len(d) - 1)) + tap_block(d))
    open(os.path.join(out, "readme.txt"), "w").write("not a tape\n")


if __name__ == "__main__":
    main()
