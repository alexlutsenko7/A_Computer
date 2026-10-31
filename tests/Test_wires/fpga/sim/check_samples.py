# Decodes sim/samples.txt (1 MHz samples of R1 R2 F1 F2) with the same algorithm as Test_wires.ino
import sys
rows = [l.strip() for l in open(sys.argv[1] if len(sys.argv) > 1 else "samples.txt") if l.strip()]
B = 1e6 / 115200
for line in range(4):
    s = [int(r[line]) for r in rows]; n = len(s); by = []; ferr = 0; i = 1; high = 0
    while i < n and high < int(15*B): high = high + 1 if s[i] else 0; i += 1
    while i < n:
        if not (s[i-1] and not s[i]): i += 1; continue
        t0 = i - 0.5; stop = int(t0 + 9.5*B)
        if stop >= n: break
        if s[int(t0 + 0.5*B)]: i += 1; continue
        v = sum(s[int(t0 + (1.5+k)*B)] << k for k in range(8))
        if s[stop]: by.append((i, v))
        else: ferr += 1
        i = stop + 1
    frames = []; k = 0
    while k + 10 <= len(by):
        b = [x[1] for x in by[k:k+10]]
        c = 0x5A
        for x in b[1:9]: c ^= x
        if b[0] == 0xA5 and c == b[9]: frames.append((by[k][0], b)); k += 10
        else: k += 1
    print(f"line {line}: {len(frames)} frames, {ferr} framing errors, ids {sorted(set(f[1][1] for f in frames))}")
    for t, b in frames[::3]:
        print(f"  t={t/1000:6.2f} ms lvl={b[2]:06b} cnt={b[3:9]}")
