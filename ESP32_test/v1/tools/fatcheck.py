#!/usr/bin/env python3
"""fatcheck.py IMAGE [--get PATH OUT] [PATH EXPECTED_FILE] ... -- independent FAT16/FAT32 check (for the save tests):
  - every FAT copy identical;
  - every cluster used by a file or folder is allocated exactly once (no cross links),
    every allocated cluster is used (no lost clusters), chains end properly;
  - file sizes fit their chains;
  - each PATH (8.3, e.g. /GAMES/SAVE.TAP) exists and its contents equal EXPECTED_FILE;
  --get copies the file PATH out of the image into OUT."""
import struct
import sys

SEC = 512


def main():
    img = open(sys.argv[1], "rb").read()
    rd16 = lambda o: struct.unpack_from("<H", img, o)[0]
    rd32 = lambda o: struct.unpack_from("<I", img, o)[0]
    vbr = 0
    if not (img[0] in (0xEB, 0xE9) and rd16(11) == 512):
        for i in range(4):
            e = 446 + 16 * i
            if img[e + 4] in (1, 4, 6, 0x0B, 0x0C, 0x0E):
                vbr = rd32(e + 8) * SEC
                break
    b = lambda o: vbr + o
    spc, rsv, nf, rootents = img[b(13)], rd16(b(14)), img[b(16)], rd16(b(17))
    tot = rd16(b(19)) or rd32(b(32))
    fsz = rd16(b(22)) or rd32(b(36))
    root_secs = (rootents * 32 + SEC - 1) // SEC
    fat_off = vbr + rsv * SEC
    root_off = fat_off + nf * fsz * SEC
    data_off = root_off + root_secs * SEC
    nclus = (tot - (data_off - vbr) // SEC) // spc
    fat32 = nclus >= 65525
    w = 4 if fat32 else 2
    errors = []

    fats = [img[fat_off + i * fsz * SEC:fat_off + (i + 1) * fsz * SEC] for i in range(nf)]
    for i in range(1, nf):
        if fats[i] != fats[0]:
            errors.append(f"FAT copy {i} differs from copy 0")
    fat = fats[0]
    def ent(c):
        v = struct.unpack_from("<I" if fat32 else "<H", fat, c * w)[0]
        return v & 0x0FFFFFFF if fat32 else v
    eoc = 0x0FFFFFF8 if fat32 else 0xFFF8
    used = {}
    def chain(c, owner):
        out = []
        while 2 <= c < nclus + 2:
            if c in used:
                errors.append(f"cluster {c} used by {owner} and {used[c]}")
                break
            used[c] = owner
            out.append(c)
            n = ent(c)
            if n >= eoc:
                break
            if n < 2:
                errors.append(f"{owner}: chain breaks at {c} -> {n}")
                break
            c = n
        return out
    coff = lambda c: data_off + (c - 2) * spc * SEC

    def entries(raw):
        for i in range(0, len(raw), 32):
            d = raw[i:i + 32]
            if d[0] == 0:
                return
            if d[0] == 0xE5 or d[11] == 0x0F or d[11] & 0x08:
                continue
            yield d

    files = {}
    def walk(raw, path):
        for d in entries(raw):
            nm = d[0:8].decode("latin1").rstrip()
            ex = d[8:11].decode("latin1").rstrip()
            full = path + nm + ("." + ex if ex else "")
            if nm in (".", ".."):
                continue
            clus = rd16_d(d, 26) | (rd16_d(d, 20) << 16 if fat32 else 0)
            size = struct.unpack_from("<I", d, 28)[0]
            ch = chain(clus, full) if clus else []
            if d[11] & 0x10:
                walk(b"".join(img[coff(c):coff(c) + spc * SEC] for c in ch), full + "/")
            else:
                if len(ch) * spc * SEC < size:
                    errors.append(f"{full}: size {size} > chain {len(ch)} clusters")
                if size and len(ch) > (size + spc * SEC - 1) // (spc * SEC):
                    errors.append(f"{full}: chain longer than needed")
                data = b"".join(img[coff(c):coff(c) + spc * SEC] for c in ch)[:size]
                files[full] = data
    rd16_d = lambda d, o: struct.unpack_from("<H", d, o)[0]

    if fat32:
        root_clus = rd32(b(44))
        rch = chain(root_clus, "/")
        root = b"".join(img[coff(c):coff(c) + spc * SEC] for c in rch)
    else:
        root = img[root_off:root_off + root_secs * SEC]
    walk(root, "/")
    lost = [c for c in range(2, nclus + 2) if ent(c) != 0 and c not in used]
    if lost:
        errors.append(f"{len(lost)} lost clusters, e.g. {lost[:5]}")

    args = sys.argv[2:]
    if args[:1] == ["--get"]:                       # --get PATH OUT: copy a file out of the image
        p = args[1].upper()
        if p in files:
            open(args[2], "wb").write(files[p])
        else:
            errors.append(f"{p}: not found")
        args = args[3:]
    for i in range(0, len(args), 2):
        p, exp = args[i].upper(), open(args[i + 1], "rb").read()
        if p not in files:
            errors.append(f"{p}: not found")
        elif files[p] != exp:
            got = files[p]
            k = next((j for j in range(min(len(got), len(exp))) if got[j] != exp[j]), min(len(got), len(exp)))
            errors.append(f"{p}: contents differ at byte {k} (got {len(got)} bytes, expected {len(exp)})")
    print(f"  FAT{'32' if fat32 else '16'}: {len(files)} files, {len(used)} clusters in use, "
          f"{len(args) // 2} saved files compared" + ("" if not errors else ""))
    for e in errors:
        print("  ERROR:", e)
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
