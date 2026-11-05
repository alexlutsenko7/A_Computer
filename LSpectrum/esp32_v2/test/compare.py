#!/usr/bin/env python3
"""compare.py TREE LOG OUTDIR [START_BLOCK] -- check a host_test run:
  - the listing in LOG matches TREE (each path component cut to NAME_MAX = 29 chars, as fat.c does);
  - every .tap/.tzx signal in OUTDIR matches tools/tzxref.py for the source file."""
import os
import subprocess
import sys

NAME_MAX = 29
HERE = os.path.dirname(os.path.abspath(__file__))


def cut(rel):
    return "/".join(c[:NAME_MAX] for c in rel.split("/"))


def main():
    tree, log, outdir = sys.argv[1:4]
    start = sys.argv[4] if len(sys.argv) > 4 else "0"
    fail = 0
    expect, tapes = [], []
    for root, dirs, files in os.walk(tree):
        for d in dirs:
            rel = os.path.relpath(os.path.join(root, d), tree).replace(os.sep, "/")
            expect.append(f"D /{cut(rel)}")
        for f in files:
            p = os.path.join(root, f)
            rel = os.path.relpath(p, tree).replace(os.sep, "/")
            expect.append(f"F /{cut(rel)} {os.path.getsize(p)}")
            if f.lower().endswith((".tap", ".tzx")):
                tapes.append((p, cut(rel)))
    got = [l.rstrip("\r\n") for l in open(log) if l[:2] in ("D ", "F ")]
    if sorted(expect) != sorted(got):
        fail = 1
        print("  listing MISMATCH")
        for l in sorted(set(expect) ^ set(got)):
            print("   ", "missing" if l in expect else "extra  ", l)
    else:
        print(f"  listing OK ({len(got)} entries)")
    bad = 0
    for src, rel in tapes:
        ref = subprocess.run([sys.executable, "-I", os.path.join(HERE, "..", "tools", "tzxref.py"), src, start],
                             capture_output=True, text=True, check=True).stdout.splitlines()
        out = os.path.join(outdir, rel.replace("/", "_") + ".txt")
        have = open(out).read().splitlines() if os.path.exists(out) else ["(missing)"]
        if ref != have:
            bad += 1
            k = next((i for i, (a, b) in enumerate(zip(ref, have)) if a != b), min(len(ref), len(have)))
            print(f"  SIGNAL MISMATCH {rel}: segment {k}: ref {ref[k:k + 2]} got {have[k:k + 2]} "
                  f"(ref {len(ref)} segments, got {len(have)})")
    print(f"  {len(tapes)} files played, {len(tapes) - bad} signals identical to the reference")
    sys.exit(1 if fail or bad else 0)


if __name__ == "__main__":
    main()
