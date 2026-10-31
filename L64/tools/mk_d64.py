#!/usr/bin/env python3
"""mk_d64.py -- makes a 1541 disk image (.d64, 35 tracks) holding .prg files.

  python3 mk_d64.py OUT.d64 "DISK NAME" ID [FILE.prg ...]
  python3 mk_d64.py OUT.d64 "TEST" 2A --hello        a one-line BASIC program HELLO (10 PRINT"HELLO")

Files go from track 17 down (then 19 up), interleave 10 as the DOS writes them; BAM and
directory on track 18 as the 1541 formats them. For the L64 drive tests (sim/).
"""
import sys

SPT = [0] + [21] * 17 + [19] * 7 + [18] * 6 + [17] * 5          # sectors per track 1..35


def offset(t, s):
    return (sum(SPT[1:t]) + s) * 256


def petscii(name, n=16):
    b = name.upper().encode('ascii')[:n]
    return b + b'\xa0' * (n - len(b))


def hello_prg():
    # 0801: link, line 10, PRINT "HELLO", end
    line = bytes([0x99]) + b' "HELLO"' + b'\x00'
    nxt = 0x0801 + 4 + len(line)
    body = bytes([nxt & 0xFF, nxt >> 8, 10, 0]) + line + b'\x00\x00'
    return bytes([0x01, 0x08]) + body


def main():
    args = sys.argv[1:]
    if len(args) < 3:
        sys.exit(__doc__)
    out, dname, did = args[0], args[1], args[2]
    files = []
    for a in args[3:]:
        if a == '--hello':
            files.append(('HELLO', hello_prg()))
        else:
            nm = a.rsplit('/', 1)[-1].rsplit('.', 1)[0]
            files.append((nm, open(a, 'rb').read()))

    img = bytearray(offset(36, 0))
    used = {t: set() for t in range(1, 36)}
    used[18].update({0, 1})

    order = list(range(17, 0, -1)) + list(range(19, 36))
    dirents = []
    for name, data in files:
        chain = []
        for t in order:
            s = 0
            while len(used[t]) < SPT[t] and len(chain) * 254 < len(data):
                while s in used[t]:
                    s = (s + 1) % SPT[t]
                used[t].add(s)
                chain.append((t, s))
                s = (s + 10) % SPT[t]
            if len(chain) * 254 >= len(data):
                break
        for i, (t, s) in enumerate(chain):
            part = data[i * 254:(i + 1) * 254]
            o = offset(t, s)
            if i + 1 < len(chain):
                img[o], img[o + 1] = chain[i + 1]
            else:
                img[o], img[o + 1] = 0, len(part) + 1
            img[o + 2:o + 2 + len(part)] = part
        dirents.append((name, chain[0], len(chain)))

    # BAM (18/0)
    b = offset(18, 0)
    img[b:b + 4] = bytes([18, 1, 0x41, 0])
    for t in range(1, 36):
        free = [s for s in range(SPT[t]) if s not in used[t]]
        bits = 0
        for s in free:
            bits |= 1 << s
        img[b + 4 * t:b + 4 * t + 4] = bytes([len(free), bits & 0xFF, (bits >> 8) & 0xFF, (bits >> 16) & 0xFF])
    img[b + 0x90:b + 0xA0] = petscii(dname)
    img[b + 0xA0:b + 0xA2] = b'\xa0\xa0'
    img[b + 0xA2:b + 0xA4] = did.upper().encode('ascii')[:2].ljust(2, b' ')
    img[b + 0xA4] = 0xA0
    img[b + 0xA5:b + 0xA7] = b'2A'
    img[b + 0xA7:b + 0xAB] = b'\xa0' * 4

    # directory (18/1), up to 8 entries
    d = offset(18, 1)
    img[d:d + 2] = bytes([0, 0xFF])
    for i, (name, (t, s), blocks) in enumerate(dirents[:8]):
        e = d + 32 * i
        img[e + 2] = 0x82                                       # PRG, closed
        img[e + 3], img[e + 4] = t, s
        img[e + 5:e + 21] = petscii(name)
        img[e + 30], img[e + 31] = blocks & 0xFF, blocks >> 8

    open(out, 'wb').write(img)
    print(f"{out}: {len(img)} bytes, {len(dirents)} file(s)")


if __name__ == '__main__':
    main()
