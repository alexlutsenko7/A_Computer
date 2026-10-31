#!/usr/bin/env python3
"""z80ref.py -- independent .z80 reference for the snapshot tests (snap_test.c, snap.c)

  z80ref.py gen DIR EXPDIR        sample .z80 files (versions 1/2/3, 48K/128K, compressed,
                                  stored, bad ones) into DIR, the machine state snap_test
                                  must dump after loading each into EXPDIR/NAME.dump
  z80ref.py check DUMP EXPECTED   compare two dumps
  z80ref.py checksave Z80 EXPECTED
                                  decode a saved file (must be version 3, 128K) and
                                  compare its state with the dump of the saved machine

Dump (snap_test.c): 128K RAM (pages 0-7), 7 register words (cpu_t80 layout, LE),
16 AY registers (masked as the AY reads them), AY select, 7FFD, border."""
import os
import random
import struct
import sys

PAGE = 16384
AY_MASK = [0xFF, 0x0F, 0xFF, 0x0F, 0xFF, 0x0F, 0x1F, 0xFF, 0x1F, 0x1F, 0x1F, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF]


# ---- compression ------------------------------------------------------------
def pack(data):
    out, i, n = bytearray(), 0, len(data)
    while i < n:
        b, run = data[i], 1
        while i + run < n and run < 255 and data[i + run] == b:
            run += 1
        if run >= 5 or (b == 0xED and run >= 2):
            out += bytes([0xED, 0xED, run, b])
            i += run
        elif b == 0xED:
            out.append(b)
            i += 1
            if i < n:
                out.append(data[i])
                i += 1
        else:
            out.append(b)
            i += 1
    return bytes(out)


def unpack(src, n):
    out, i = bytearray(), 0
    while len(out) < n:
        if src[i] == 0xED and i + 1 < len(src) and src[i + 1] == 0xED:
            out += bytes([src[i + 3]]) * src[i + 2]
            i += 4
        else:
            out.append(src[i])
            i += 1
    if len(out) != n:
        raise ValueError("block decodes to %d bytes" % len(out))
    return bytes(out), i


# ---- machine state ----------------------------------------------------------
class State:
    def __init__(self, fill=0x55):
        self.ram = bytearray([fill]) * (8 * PAGE)
        self.regs = [0xA5A5A5A5] * 7
        self.ay = [0x33 & m for m in AY_MASK]
        self.ay_sel, self.p7ffd, self.border = 9, 0x17, 5

    def dump(self):
        return (bytes(self.ram) + struct.pack("<7I", *self.regs) +
                bytes(a & m for a, m in zip(self.ay, AY_MASK)) + bytes([self.ay_sel, self.p7ffd, self.border]))

    @staticmethod
    def parse(d):
        s = State()
        s.ram = bytearray(d[:8 * PAGE])
        s.regs = list(struct.unpack_from("<7I", d, 8 * PAGE))
        o = 8 * PAGE + 28
        s.ay = list(d[o:o + 16])
        s.ay_sel, s.p7ffd, s.border = d[o + 16], d[o + 17], d[o + 18]
        return s


def w16(h, o):
    return h[o] | h[o + 1] << 8


def regs_from_header(h, pc):
    """cpu_t80 register words from a .z80 header (A F A' F' I R SP PC BC DE HL IX BC' DE' HL' IY IM IFF1 IFF2)"""
    r = (h[11] & 0x7F) | (h[12] & 1) << 7
    im = h[29] & 3
    im = 2 if im == 3 else im
    return [h[0] | h[1] << 8 | h[21] << 16 | h[22] << 24,
            h[10] | r << 8 | w16(h, 8) << 16,
            pc | w16(h, 2) << 16,
            w16(h, 13) | w16(h, 4) << 16,
            w16(h, 25) | w16(h, 15) << 16,
            w16(h, 17) | w16(h, 19) << 16,
            w16(h, 23) | im << 16 | (h[27] != 0) << 18 | (h[28] != 0) << 19]


def load(data, st):
    """the state after loading data into st (as the machine does); raises ValueError if bad"""
    h = bytearray(data[:30])
    if len(data) < 31:
        raise ValueError("short")
    if h[12] == 0xFF:
        h[12] = 1
    pc = w16(h, 6)
    if pc:
        mem, _ = unpack(data[30:], 3 * PAGE) if h[12] & 0x20 else (data[30:30 + 3 * PAGE], 0)
        if len(mem) != 3 * PAGE:
            raise ValueError("v1 short")
        blocks, is128, ext = {5: mem[:PAGE], 2: mem[PAGE:2 * PAGE], 0: mem[2 * PAGE:]}, False, b""
    else:
        el = w16(data, 30)
        if el not in (23, 54, 55):
            raise ValueError("ext")
        ext = data[32:32 + el]
        pc, hw = w16(ext, 0), ext[2]
        is128 = hw >= 3 if el == 23 else (hw >= 4 and hw not in (14, 15, 128))
        pos, blocks = 32 + el, {}
        while pos < len(data):
            if pos + 3 > len(data):
                raise ValueError("block header")
            ln, pg = w16(data, pos), data[pos + 2]
            raw = ln == 0xFFFF
            ln = PAGE if raw else ln
            if ln == 0 or pos + 3 + ln > len(data):
                raise ValueError("block length")
            body = data[pos + 3:pos + 3 + ln]
            page = (pg - 3 if 3 <= pg <= 10 else None) if is128 else {8: 5, 4: 2, 5: 0}.get(pg)
            if page is not None:
                blocks[page] = body if raw else unpack(body, PAGE)[0]
            pos += 3 + ln
        need = set(range(8)) if is128 else {5, 2, 0}
        if not need <= set(blocks):
            raise ValueError("missing pages")
    for p, b in blocks.items():
        st.ram[p * PAGE:(p + 1) * PAGE] = b
    h = h + (data[30:32] + ext[:54] if ext else b"")
    h = h + bytes(86 - len(h))
    ay_on = is128 or (not pc_is_v1(data) and h[37] & 4)
    st.ay = [(h[39 + i] if ay_on else 0) & AY_MASK[i] for i in range(16)]
    st.ay_sel = h[38] if ay_on else 0
    st.p7ffd = h[35] if is128 else 0x30
    st.border = (h[12] >> 1) & 7
    st.regs = regs_from_header(h, pc)
    return st


def pc_is_v1(data):
    return w16(data, 6) != 0


# ---- sample files -----------------------------------------------------------
def page_data(rng, kind):
    if kind == 0:
        return bytes(rng.randrange(256) for _ in range(PAGE))
    out = bytearray()
    while len(out) < PAGE:
        c = rng.random()
        if c < 0.3:
            out += bytes([0xED]) * rng.randrange(1, 7)
        elif c < 0.5:
            out += bytes([rng.randrange(256)]) * rng.randrange(1, 300)
        elif c < 0.6:
            out += bytes([0xED, rng.randrange(256)])
        else:
            out += bytes(rng.randrange(256) for _ in range(rng.randrange(1, 20)))
    return bytes(out[:PAGE])


def header(rng, pc_v1=0):
    h = bytearray(rng.randrange(256) for _ in range(30))
    h[6], h[7] = pc_v1 & 0xFF, pc_v1 >> 8
    h[12] = (h[12] & 0x1F & ~0x20) | (h[12] & 1)
    h[27], h[28], h[29] = rng.randrange(2), rng.randrange(2), rng.randrange(3)
    return h


def ext_bytes(rng, n, pc, hw, p7ffd, ay_flag):
    e = bytearray(rng.randrange(256) for _ in range(n))
    e[0], e[1], e[2], e[3] = pc & 0xFF, pc >> 8, hw, p7ffd
    e[5] = (e[5] & ~4) | (4 if ay_flag else 0)          # byte 37
    return e


def blocks_bytes(pages, order, stored=()):
    out = bytearray()
    for num, data in order:
        if num in stored:
            out += struct.pack("<HB", 0xFFFF, num) + data
        else:
            c = pack(data)
            out += struct.pack("<HB", len(c), num) + c
    return out


def gen(d, expd):
    rng = random.Random(1234)
    os.makedirs(d, exist_ok=True)
    os.makedirs(expd, exist_ok=True)
    files = {}
    p48 = [page_data(rng, k % 2) for k in range(3)]            # 4000, 8000, C000
    stream = p48[0] + p48[1] + p48[2]
    h = header(rng, 0x8123)
    h[12] |= 0x20
    files["V1C.Z80"] = bytes(h) + pack(stream) + bytes([0, 0xED, 0xED, 0])
    h = header(rng, 0x5CB0)
    files["V1U.Z80"] = bytes(h) + stream
    p128 = [page_data(rng, k % 3) for k in range(8)]
    h = header(rng)
    files["V2128.Z80"] = bytes(h) + struct.pack("<H", 23) + ext_bytes(rng, 23, 0x1234, 3, 0x15, 0) + \
        blocks_bytes(p128, [(n + 3, p128[n]) for n in range(8)])
    h = header(rng)
    files["V348.Z80"] = bytes(h) + struct.pack("<H", 54) + ext_bytes(rng, 54, 0xC000, 0, 0x07, 1) + \
        blocks_bytes(None, [(8, p48[0]), (4, p48[1]), (5, p48[2])], stored=(4,))
    h = header(rng)
    order = [(n + 3, p128[(n * 5) % 8]) for n in (7, 2, 5, 0, 1, 3, 6, 4)]
    files["V3128.Z80"] = bytes(h) + struct.pack("<H", 54) + ext_bytes(rng, 54, 0xFFFF, 4, 0x2B, 0) + \
        blocks_bytes(None, order, stored=(6, 10))
    h = header(rng)
    files["V355P2.Z80"] = bytes(h) + struct.pack("<H", 55) + ext_bytes(rng, 55, 0x0001, 12, 0x10, 0) + \
        blocks_bytes(None, [(n + 3, p128[7 - n]) for n in range(8)])
    good = dict(files)
    full = files["V3128.Z80"]
    files["BADTRUNC.Z80"] = full[:len(full) - 100]
    files["BADMISS.Z80"] = bytes(h) + struct.pack("<H", 54) + ext_bytes(rng, 54, 0x4000, 4, 0, 0) + \
        blocks_bytes(None, [(n + 3, p128[n]) for n in range(7)])
    files["BADEXT.Z80"] = bytes(h) + struct.pack("<H", 40) + bytes(40) + blocks_bytes(None, [(8, p48[0])])
    files["BADSHORT.Z80"] = bytes(20)
    for name, data in files.items():
        open(os.path.join(d, name), "wb").write(data)
        try:
            st = load(data, State())
            if name not in good:
                raise SystemExit("reference accepts bad file " + name)
        except ValueError:
            if name in good:
                raise
            st = State()
        open(os.path.join(expd, name + ".dump"), "wb").write(st.dump())
    print("z80ref: %d sample files (%d bad)" % (len(files), len(files) - len(good)))


def compare(a, b, what):
    sa, sb = State.parse(a), State.parse(b)
    bad = []
    for p in range(8):
        if sa.ram[p * PAGE:(p + 1) * PAGE] != sb.ram[p * PAGE:(p + 1) * PAGE]:
            first = next(i for i in range(PAGE) if sa.ram[p * PAGE + i] != sb.ram[p * PAGE + i])
            bad.append("RAM page %d differs (first at %04X)" % (p, first))
    for i in range(7):
        if sa.regs[i] != sb.regs[i]:
            bad.append("register word %d: %08X, expected %08X" % (i, sa.regs[i], sb.regs[i]))
    if sa.ay != sb.ay:
        bad.append("AY %s, expected %s" % (sa.ay, sb.ay))
    for f in ("ay_sel", "p7ffd", "border"):
        if getattr(sa, f) != getattr(sb, f):
            bad.append("%s %02X, expected %02X" % (f, getattr(sa, f), getattr(sb, f)))
    for m in bad:
        print("  ERROR %s: %s" % (what, m))
    return not bad


def main():
    if sys.argv[1] == "gen":
        gen(sys.argv[2], sys.argv[3])
    elif sys.argv[1] == "check":
        ok = compare(open(sys.argv[2], "rb").read(), open(sys.argv[3], "rb").read(), os.path.basename(sys.argv[2]))
        sys.exit(0 if ok else 1)
    elif sys.argv[1] == "checksave":
        data = open(sys.argv[2], "rb").read()
        exp = open(sys.argv[3], "rb").read()
        if w16(data, 6) != 0 or w16(data, 30) != 54 or data[34] != 4:
            print("  ERROR: not a version 3 128K file")
            sys.exit(1)
        n, pos = 0, 86
        while pos < len(data):
            ln = w16(data, pos)
            pos += 3 + (PAGE if ln == 0xFFFF else ln)
            n += 1
        if pos != len(data) or n != 8:
            print("  ERROR: %d blocks, end %d of %d" % (n, pos, len(data)))
            sys.exit(1)
        st = load(data, State(0))
        ok = compare(st.dump(), exp, os.path.basename(sys.argv[2]))
        print("  %s: %d bytes, version 3, 128K, %s" % (os.path.basename(sys.argv[2]), len(data), "ok" if ok else "FAILED"))
        sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
