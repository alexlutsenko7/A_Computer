#!/usr/bin/env python3
"""tzxref.py FILE [START_BLOCK] -- reference TAP/TZX -> signal timeline, written independently of
fw/tape.c with the same conventions (docs/SD_TAPE_LOADER.md):
  - the line starts low with a 100 ms (350000 T) lead-in;
  - a pulse holds the current level for its length, then the level toggles;
  - a pause: if the level is high, 1 ms high, then low for the rest;
  - TAP blocks = standard ROM blocks with a 1000 ms pause;
  - "stop the tape" (0x20, pause 0) produces nothing (the test plays straight on);
  - 0x2A is ignored (128K machine), 0x18/0x19/0x28 and info blocks are skipped.
Output: merged (level, T-states) segments, one "level length" per line."""
import struct
import sys

T_MS = 3500


class Line:
    def __init__(self):
        self.level = 0
        self.seg = []                   # [level, length]

    def hold(self, level, n):
        if n <= 0:
            return
        if self.seg and self.seg[-1][0] == level:
            self.seg[-1][1] += n
        else:
            self.seg.append([level, n])

    def pulse(self, n):
        self.hold(self.level, n)
        self.level ^= 1

    def set_level(self, lvl, n=0):
        self.level = lvl
        self.hold(lvl, n)

    def pause(self, ms):
        t = ms * T_MS
        if t == 0:
            return
        if self.level:
            h = min(t, T_MS)
            self.hold(1, h)
            t -= h
            if t == 0:
                return
        self.level = 0
        self.hold(0, t)

    def data(self, data, zero, one, last_bits):
        for i, b in enumerate(data):
            bits = last_bits if (i == len(data) - 1 and 1 <= last_bits <= 8) else 8
            for k in range(bits):
                n = one if (b >> (7 - k)) & 1 else zero
                self.pulse(n)
                self.pulse(n)


def std_block(line, data, pause_ms):
    if data:
        for _ in range(3223 if data[0] & 0x80 else 8063):
            line.pulse(2168)
        line.pulse(667)
        line.pulse(735)
        line.data(data, 855, 1710, 8)
    line.pause(pause_ms)


def play_tap(buf, line, start=0):
    p = 0
    for _ in range(start):
        if p + 2 > len(buf):
            return
        p += 2 + struct.unpack_from("<H", buf, p)[0]
    while p + 2 <= len(buf):
        n = struct.unpack_from("<H", buf, p)[0]
        std_block(line, buf[p + 2:p + 2 + n], 1000)
        p += 2 + n


def parse_tzx(buf):
    """list of (id, fields dict, offset of the block body)"""
    assert buf[:8] == b"ZXTape!\x1a", "not a TZX file"
    p, blocks = 10, []
    u8 = lambda: buf[p]
    while p < len(buf):
        bid = buf[p]; p += 1
        f = {}
        def h(o): return struct.unpack_from("<H", buf, p + o)[0]
        def t(o): return buf[p + o] | buf[p + o + 1] << 8 | buf[p + o + 2] << 16
        def w(o): return struct.unpack_from("<I", buf, p + o)[0]
        if bid == 0x10:
            f = dict(pause=h(0), data=buf[p + 4:p + 4 + h(2)]); n = 4 + h(2)
        elif bid == 0x11:
            ln = t(15)
            f = dict(pilot=h(0), s1=h(2), s2=h(4), zero=h(6), one=h(8), count=h(10), last=buf[p + 12],
                     pause=h(13), data=buf[p + 18:p + 18 + ln]); n = 18 + ln
        elif bid == 0x12:
            f = dict(len=h(0), count=h(2)); n = 4
        elif bid == 0x13:
            c = buf[p]; f = dict(pulses=[h(1 + 2 * i) for i in range(c)]); n = 1 + 2 * c
        elif bid == 0x14:
            ln = t(7)
            f = dict(zero=h(0), one=h(2), last=buf[p + 4], pause=h(5), data=buf[p + 10:p + 10 + ln]); n = 10 + ln
        elif bid == 0x15:
            ln = t(5)
            f = dict(tps=h(0), pause=h(2), last=buf[p + 4], data=buf[p + 8:p + 8 + ln]); n = 8 + ln
        elif bid in (0x20, 0x23, 0x24):
            f = dict(v=h(0)); n = 2
        elif bid in (0x21, 0x30):
            n = 1 + buf[p]
        elif bid in (0x22, 0x25, 0x27):
            n = 0
        elif bid == 0x26:
            c = h(0); f = dict(offs=[struct.unpack_from("<h", buf, p + 2 + 2 * i)[0] for i in range(c)]); n = 2 + 2 * c
        elif bid in (0x28, 0x32):
            n = 2 + h(0)
        elif bid == 0x2B:
            f = dict(level=buf[p + 4]); n = 4 + w(0)
        elif bid == 0x31:
            n = 2 + buf[p + 1]
        elif bid == 0x33:
            n = 1 + 3 * buf[p]
        elif bid == 0x34:
            n = 8
        elif bid == 0x35:
            n = 14 + w(10)
        elif bid == 0x40:
            n = 4 + t(1)
        elif bid == 0x5A:
            n = 9
        else:
            n = 4 + w(0)
        blocks.append((bid, f))
        p += n
    return blocks


def play_tzx(buf, line, start=0):
    blocks = parse_tzx(buf)
    i, loop, call = start, None, None
    steps = 0
    while i < len(blocks):
        steps += 1
        assert steps < 100000, "runaway control flow"
        bid, f = blocks[i]
        nxt = i + 1
        if bid == 0x10:
            std_block(line, f["data"], f["pause"])
        elif bid == 0x11:
            for _ in range(f["count"]):
                line.pulse(f["pilot"])
            line.pulse(f["s1"]); line.pulse(f["s2"])
            line.data(f["data"], f["zero"], f["one"], f["last"])
            line.pause(f["pause"])
        elif bid == 0x12:
            for _ in range(f["count"]):
                line.pulse(f["len"])
        elif bid == 0x13:
            for n in f["pulses"]:
                line.pulse(n)
        elif bid == 0x14:
            line.data(f["data"], f["zero"], f["one"], f["last"])
            line.pause(f["pause"])
        elif bid == 0x15:
            d = f["data"]
            for k, b in enumerate(d):
                bits = f["last"] if (k == len(d) - 1 and 1 <= f["last"] <= 8) else 8
                for j in range(bits):
                    line.set_level((b >> (7 - j)) & 1, f["tps"])
            line.pause(f["pause"])
        elif bid == 0x20:
            line.pause(f["v"])
        elif bid == 0x23:
            nxt = i + (struct.unpack("<h", struct.pack("<H", f["v"]))[0] or 1)
        elif bid == 0x24:
            loop = [f["v"], i + 1]
        elif bid == 0x25:
            if loop and loop[0] > 1:
                loop[0] -= 1
                nxt = loop[1]
        elif bid == 0x26:
            if f["offs"]:
                call = [i, 0, f["offs"]]
                nxt = i + f["offs"][0]
        elif bid == 0x27:
            if call:
                call[1] += 1
                if call[1] < len(call[2]):
                    nxt = call[0] + call[2][call[1]]
                else:
                    nxt = call[0] + 1
                    call = None
        elif bid == 0x2B:
            line.set_level(f["level"] & 1)
        i = nxt


def main():
    buf = open(sys.argv[1], "rb").read()
    start = int(sys.argv[2]) if len(sys.argv) > 2 else 0
    line = Line()
    line.set_level(0, 100 * T_MS)
    if buf[:8] == b"ZXTape!\x1a":
        play_tzx(buf, line, start)
    else:
        play_tap(buf, line, start)
    sys.stdout.write("".join(f"{l} {n}\n" for l, n in line.seg))


if __name__ == "__main__":
    main()
