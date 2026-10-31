#!/usr/bin/env python3
"""sort_games.py ROOT [--max N] [--dry-run] -- prepare a game collection for the SD tape loader

For every folder under ROOT:
  1. delete every file that is not *.tap.zip / *.tzx.zip / *.z80.zip / *.tap / *.tzx / *.z80 (any letter
     case; already unpacked files from an earlier, interrupted run are kept);
  2. unpack the .tap / .tzx / .z80 files out of each zip into the zip's folder (other files in the zip,
     e.g. .txt / .scr, are skipped; folders inside the zip are flattened), then delete the zip.
     A name that already exists with different contents gets " (2)", " (3)", ...; an identical
     file is not stored twice. A zip that cannot be read or has no tape in it is kept and reported;
  3. split folders with more than N files (default 300, the browser shows 350 entries):
     the first N (sorted by name, as the browser sorts) stay in "a", the next N go to "a1",
     then "a2", ...; folders left empty are removed.

Files named in protected.txt (in ROOT or up to two levels above) are never deleted, unpacked or moved.
Prints a summary; problem zips are listed in ROOT/sort_games.log."""
import argparse
import os
import sys
import zipfile

TAPE = (".tap", ".tzx", ".z80")                # .z80 snapshots load from the browser too
KEEP = (".tap.zip", ".tzx.zip", ".z80.zip")


def load_protected(folder):
    """names (lower case) from protected.txt in folder or up to two levels above it"""
    d = os.path.abspath(folder)
    for _ in range(3):
        p = os.path.join(d, "protected.txt")
        if os.path.isfile(p):
            with open(p, encoding="utf-8") as f:
                return {l.strip().lower() for l in f if l.strip() and not l.lstrip().startswith("#")}
        d = os.path.dirname(d)
    return set()


def unique_name(folder, name, data):
    base, ext = os.path.splitext(name)
    cand, k = name, 1
    while os.path.exists(os.path.join(folder, cand)):
        with open(os.path.join(folder, cand), "rb") as f:
            if f.read() == data:
                return None                     # the same file is already there
        k += 1
        cand = "%s (%d)%s" % (base, k, ext)
    return cand


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("root")
    ap.add_argument("--max", type=int, default=300)
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    root = os.path.abspath(a.root)
    protected = load_protected(root)
    log = []
    n_del = n_zip = n_out = n_dup = n_bad = 0

    # 1 + 2, folder by folder
    for d, _, files in os.walk(root):
        for f in sorted(files):
            p = os.path.join(d, f)
            if (f == "sort_games.log" and d == root) or f.lower() in protected:
                continue
            if not f.lower().endswith(KEEP + TAPE):           # unpacked tapes (earlier run) stay
                n_del += 1
                if not a.dry_run:
                    os.remove(p)
        for f in sorted(os.listdir(d)):
            p = os.path.join(d, f)
            if not (os.path.isfile(p) and f.lower().endswith(KEEP)) or f.lower() in protected:
                continue
            try:
                with zipfile.ZipFile(p) as z:
                    entries = [i for i in z.infolist() if not i.is_dir() and i.filename.lower().endswith(TAPE)]
                    if not entries:
                        n_bad += 1
                        log.append("no .tap/.tzx inside (kept): " + os.path.relpath(p, root))
                        continue
                    for i in entries:
                        data = z.read(i)
                        name = os.path.basename(i.filename.replace("\\", "/"))
                        if a.dry_run:
                            n_out += 1
                            continue
                        out = unique_name(d, name, data)
                        if out is None:
                            n_dup += 1
                            continue
                        with open(os.path.join(d, out), "wb") as o:
                            o.write(data)
                        n_out += 1
            except (zipfile.BadZipFile, OSError, RuntimeError, NotImplementedError) as e:
                n_bad += 1
                log.append("cannot unpack (kept): %s: %s" % (os.path.relpath(p, root), e))
                continue
            n_zip += 1
            if not a.dry_run:
                os.remove(p)

    # 3: split big folders (deepest first, only original folders)
    n_split = 0
    folders = [d for d, _, _ in os.walk(root)]
    for d in sorted(folders, key=lambda x: -x.count(os.sep)):
        files = sorted((f for f in os.listdir(d) if os.path.isfile(os.path.join(d, f)) and f != "sort_games.log"
                        and f.lower() not in protected), key=str.lower)
        if len(files) <= a.max or d == root:
            continue
        n_split += 1
        parent, name = os.path.split(d)
        for k in range(1, (len(files) + a.max - 1) // a.max):
            target = os.path.join(parent, "%s%d" % (name, k))
            chunk = files[k * a.max:(k + 1) * a.max]
            if a.dry_run:
                print("  %s: %d files -> %s" % (os.path.relpath(d, root), len(chunk), os.path.relpath(target, root)))
                continue
            os.makedirs(target, exist_ok=True)
            for f in chunk:
                os.rename(os.path.join(d, f), os.path.join(target, f))

    for d, _, _ in sorted(os.walk(root), key=lambda x: -x[0].count(os.sep)):   # folders left empty
        if d != root and not os.listdir(d) and not a.dry_run:
            os.rmdir(d)
    if log and not a.dry_run:
        with open(os.path.join(root, "sort_games.log"), "w") as f:
            f.write("\n".join(log) + "\n")
    print("deleted %d other files; unpacked %d zips -> %d tape files (%d identical duplicates dropped); "
          "%d problem zips kept; %d folders split%s" %
          (n_del, n_zip, n_out, n_dup, n_bad, n_split, " (dry run: nothing changed)" if a.dry_run else ""))
    for l in log[:30]:
        print("  " + l)


if __name__ == "__main__":
    main()
