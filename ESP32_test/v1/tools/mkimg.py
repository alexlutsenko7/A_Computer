#!/usr/bin/env python3
"""mkimg.py -- build a FAT16 or FAT32 SD card image for tests (no external tools).

    mkimg.py OUT.img --fat 16|32 [--mbr] [--spc N] [--mb SIZE] SRC_DIR

Copies the tree under SRC_DIR into the image root. Names that are not plain 8.3
upper case get long-file-name entries. Clusters are handed out "every other free
cluster", so every multi-cluster file and directory is fragmented (tests the
cluster-chain code)."""
import argparse
import os
import struct

SEC = 512


def short_name(name, used):
    base, ext = (name.rsplit(".", 1) + [""])[:2] if "." in name[1:] else (name, "")
    clean = lambda s: "".join(c for c in s.upper() if c.isalnum() or c in "_-$%'@~`!(){}^#&")
    b, e = clean(base), clean(ext)[:3]
    exact = (name.upper() == name and len(base) <= 8 and len(ext) <= 3 and b == base and e == ext)
    if exact and (b, e) not in used:
        used.add((b, e))
        return b.ljust(8) + e.ljust(3), False
    for n in range(1, 1000):
        tail = f"~{n}"
        cand = (b[: 8 - len(tail)] + tail, e)
        if cand not in used:
            used.add(cand)
            return cand[0].ljust(8) + cand[1].ljust(3), True
    raise RuntimeError("too many similar names")


def lfn_checksum(sn):
    s = 0
    for c in sn.encode("ascii"):
        s = (((s & 1) << 7) + (s >> 1) + c) & 0xFF
    return s


def lfn_entries(name, sn):
    u = name.encode("utf-16-le")
    chars = [u[i:i + 2] for i in range(0, len(u), 2)]
    if len(chars) % 13:
        chars += [b"\x00\x00"] + [b"\xff\xff"] * (12 - len(chars) % 13)
    chunks = [chars[i:i + 13] for i in range(0, len(chars), 13)]
    ck = lfn_checksum(sn)
    out = []
    for i in reversed(range(len(chunks))):
        c = chunks[i]
        seq = (i + 1) | (0x40 if i == len(chunks) - 1 else 0)
        e = bytes([seq]) + b"".join(c[0:5]) + bytes([0x0F, 0, ck]) + b"".join(c[5:11]) + b"\0\0" + b"".join(c[11:13])
        out.append(e)
    return out


def dirent(sn, attr, clus, size):
    return (sn.encode("ascii") + bytes([attr, 0, 0]) + b"\0" * 6 + struct.pack("<H", clus >> 16)
            + b"\0" * 4 + struct.pack("<HI", clus & 0xFFFF, size))


class Node:
    def __init__(self, name, path=None, is_dir=False):
        self.name, self.path, self.is_dir = name, path, is_dir
        self.children, self.clus, self.data = [], 0, b""


def scan(src):
    root = Node("", src, True)
    def walk(node):
        for n in sorted(os.listdir(node.path)):
            p = os.path.join(node.path, n)
            ch = Node(n, p, os.path.isdir(p))
            node.children.append(ch)
            if ch.is_dir:
                walk(ch)
            else:
                ch.data = open(p, "rb").read()
    walk(root)
    return root


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("src")
    ap.add_argument("--fat", type=int, choices=(16, 32), required=True)
    ap.add_argument("--mbr", action="store_true")
    ap.add_argument("--spc", type=int, default=1)
    ap.add_argument("--mb", type=int, default=0)
    a = ap.parse_args()

    spc = a.spc
    rsv = 32 if a.fat == 32 else 4
    root_ents = 0 if a.fat == 32 else 512
    root_secs = root_ents * 32 // SEC
    want_clus = 70000 if a.fat == 32 else 5000          # comfortably inside the FAT type's range
    part_secs = (a.mb * 2048) if a.mb else rsv + root_secs + want_clus * spc + 2 * ((want_clus + 2) * (a.fat // 8) // SEC + 1)
    fatsz = 1
    while True:
        clus = (part_secs - rsv - root_secs - 2 * fatsz) // spc
        need = ((clus + 2) * (a.fat // 8) + SEC - 1) // SEC
        if need <= fatsz:
            break
        fatsz = need
    if a.fat == 16:
        assert 4085 <= clus < 65525, clus
    else:
        assert clus >= 65525, clus
    part_lba = 2048 if a.mbr else 0
    img = bytearray((part_lba + part_secs) * SEC)
    fat = [0] * (clus + 2)
    fat[0] = (0x0FFFFFF8 if a.fat == 32 else 0xFFF8)
    fat[1] = (0x0FFFFFFF if a.fat == 32 else 0xFFFF)
    free = list(range(2, clus + 2))
    eoc = 0x0FFFFFFF if a.fat == 32 else 0xFFFF

    def alloc(n):
        nonlocal free
        n = max(n, 1)
        take = free[0:2 * n:2]
        if len(take) < n:
            take = free[:n]
        assert len(take) == n, "image full"
        ts = set(take)
        free = [c for c in free if c not in ts]
        for x, y in zip(take, take[1:]):
            fat[x] = y
        fat[take[-1]] = eoc
        return take

    cbytes = spc * SEC
    data_lba = part_lba + rsv + 2 * fatsz + root_secs
    def clus_off(c):
        return (data_lba + (c - 2) * spc) * SEC

    def write_chain(chain, data):
        for i, c in enumerate(chain):
            part = data[i * cbytes:(i + 1) * cbytes]
            img[clus_off(c):clus_off(c) + len(part)] = part

    root = scan(a.src)

    def entries_for(node, parent_clus):
        used, out = set(), []
        if node is not root:
            out.append(dirent(".".ljust(11), 0x10, node.clus, 0))
            out.append(dirent("..".ljust(11), 0x10, parent_clus, 0))
        for ch in node.children:
            sn, need_lfn = short_name(ch.name, used)
            if need_lfn:
                out += lfn_entries(ch.name, sn)
            out.append(dirent(sn, 0x10 if ch.is_dir else 0x20, ch.clus, 0 if ch.is_dir else len(ch.data)))
        return b"".join(out)

    # pass 1: sizes -> clusters (directory size from a dry run of its entries)
    def assign(node):
        for ch in node.children:
            if ch.is_dir:
                n = len(entries_for(ch, 0)) + 32
                ch.chain = alloc((n + cbytes - 1) // cbytes)
                ch.clus = ch.chain[0]
                assign(ch)
            elif ch.data:
                ch.chain = alloc((len(ch.data) + cbytes - 1) // cbytes)
                ch.clus = ch.chain[0]
    if a.fat == 32:
        n = len(entries_for(root, 0)) + 32
        root.chain = alloc((n + cbytes - 1) // cbytes)
        root.clus = root.chain[0]
    assign(root)

    # pass 2: contents
    def emit(node, parent_clus):
        for ch in node.children:
            if ch.is_dir:
                write_chain(ch.chain, entries_for(ch, 0 if node is root else node.clus))
                emit(ch, ch.clus)
            elif ch.data:
                write_chain(ch.chain, ch.data)
    rootdata = entries_for(root, 0)
    if a.fat == 32:
        write_chain(root.chain, rootdata)
    else:
        assert len(rootdata) <= root_secs * SEC
        o = (part_lba + rsv + 2 * fatsz) * SEC
        img[o:o + len(rootdata)] = rootdata
    emit(root, 0)

    # FATs
    fmt = "<I" if a.fat == 32 else "<H"
    fatbytes = b"".join(struct.pack(fmt, v) for v in fat)
    for i in range(2):
        o = (part_lba + rsv + i * fatsz) * SEC
        img[o:o + len(fatbytes)] = fatbytes

    # boot sector
    vbr = bytearray(SEC)
    vbr[0:3] = b"\xEB\x58\x90"
    vbr[3:11] = b"MKIMG1.0"
    struct.pack_into("<HBHBHHBHHHII", vbr, 11, SEC, spc, rsv, 2, root_ents,
                     part_secs if part_secs < 65536 else 0, 0xF8,
                     0 if a.fat == 32 else fatsz, 63, 255, part_lba,
                     part_secs if part_secs >= 65536 else 0)
    if a.fat == 32:
        struct.pack_into("<IHHIHH", vbr, 36, fatsz, 0, 0, root.clus, 1, 6)
        vbr[64] = 0x80; vbr[66] = 0x29
        vbr[71:82] = b"LSPECTRUM  "; vbr[82:90] = b"FAT32   "
    else:
        vbr[36] = 0x80; vbr[38] = 0x29
        vbr[43:54] = b"LSPECTRUM  "; vbr[54:62] = b"FAT16   "
    vbr[510:512] = b"\x55\xAA"
    img[part_lba * SEC:part_lba * SEC + SEC] = vbr
    if a.mbr:
        mbr = bytearray(SEC)
        mbr[0] = 0xFA                                      # not a boot sector jump
        ptype = 0x0C if a.fat == 32 else 0x0E
        mbr[446:462] = bytes([0x00, 0, 0, 0, ptype, 0, 0, 0]) + struct.pack("<II", part_lba, part_secs)
        mbr[510:512] = b"\x55\xAA"
        img[0:SEC] = mbr
    open(a.out, "wb").write(img)
    print(f"{a.out}: FAT{a.fat}{' MBR' if a.mbr else ''}, {clus} clusters of {cbytes} B, {len(img) // 1048576} MB")


if __name__ == "__main__":
    main()
