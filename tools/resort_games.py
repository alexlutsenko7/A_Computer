#!/usr/bin/env python3
"""resort_games.py ROOT [--max N] [--dry-run] -- re-sort a game collection by first letter (moves only)

Never deletes a file. For the letter folders under ROOT (a, a1, a2, ..., 123, ...; folders whose name
starts with '#' are left alone):
  1. pools all files by the first character of their name: a-z (any case) -> that letter, anything
     else (digit, punctuation, non-ASCII) -> "123";
  2. sorts each group as the SD loader's browser does (ASCII, case-insensitive);
  3. spreads it evenly over ceil(n / N) folders (default N = 300): letter, letter1, letter2, ...
Two different files with the same name (case-insensitive) in one group: the later one gets " (2)",
" (3)", ... Files named in protected.txt (ROOT or up to two levels above) are not moved or renamed.
Folders left empty are removed. Every move is written to ROOT/../resort_moves.log ("old -> new",
relative to ROOT), which is enough to undo the run."""
import argparse
import math
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sort_games import load_protected          # same protected.txt rules as the other tools


def group(name):
    c = name[0]
    return c.lower() if c.isascii() and c.isalpha() else "123"


def browser_key(name):
    return name.encode("utf-8", "surrogateescape").lower()       # bytes.lower: ASCII only, as u_stricmp


def is_letter_folder(d):
    return not d.startswith("#") and re.fullmatch(r"(123|[a-z])\d*", d) is not None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("root")
    ap.add_argument("--max", type=int, default=300)
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    root = os.path.abspath(a.root)
    protected = load_protected(root)

    folders = sorted(d for d in os.listdir(root) if os.path.isdir(os.path.join(root, d)) and is_letter_folder(d))
    pool, fixed = {}, {}                     # group -> [(name, folder)]; folder -> protected count
    for d in folders:
        for f in os.listdir(os.path.join(root, d)):
            if not os.path.isfile(os.path.join(root, d, f)):
                continue
            if f.lower() in protected:
                fixed[d] = fixed.get(d, 0) + 1
                continue
            pool.setdefault(group(f), []).append((f, d))

    plan = []                                # (old rel, new folder, new name)
    for g, items in pool.items():
        items.sort(key=lambda x: (browser_key(x[0]), x[1]))
        taken = {f.lower() for f, _ in items}
        seen, named = set(), []
        for f, d in items:                   # unique names within the group
            new = f
            if f.lower() in seen:
                base, ext = os.path.splitext(f)
                k = 2
                while ("%s (%d)%s" % (base, k, ext)).lower() in taken:
                    k += 1
                new = "%s (%d)%s" % (base, k, ext)
                taken.add(new.lower())
            seen.add(new.lower())
            named.append((new, f, d))
        named.sort(key=lambda x: browser_key(x[0]))
        k = max(1, math.ceil(len(named) / a.max))
        size = math.ceil(len(named) / k)
        for i, (new, f, d) in enumerate(named):
            j = i // size
            plan.append((d + "/" + f, g if j == 0 else "%s%d" % (g, j), new))

    moves = [p for p in plan if p[0] != p[1] + "/" + p[2]]
    renamed = [p for p in plan if os.path.basename(p[0]) != p[2]]
    counts = {}
    for _, nd, _ in plan:
        counts[nd] = counts.get(nd, 0) + 1
    for d, n in fixed.items():
        counts[d] = counts.get(d, 0) + n
    over = {d: n for d, n in counts.items() if n > a.max}
    print("%d files in %d groups: %d to move (%d renamed for a name clash), %d protected left in place"
          % (len(plan), len(pool), len(moves), len(renamed), sum(fixed.values())))
    for p in renamed:
        print("  rename: %s -> %s/%s" % p)
    if over:
        print("  over %d after the run: %s" % (a.max, over))
    if a.dry_run:
        print("dry run: nothing changed")
        return

    # two phases (a target name may still be occupied by a file that moves away later):
    # every moving file to a staging folder first, then to its place
    stage = os.path.join(root, "_resort_tmp")
    os.makedirs(stage, exist_ok=False)
    logp = os.path.join(os.path.dirname(root), "resort_moves.log")
    with open(logp, "w", encoding="utf-8") as log:
        log.write("# resort_games.py: old -> new (relative to %s)\n" % root)
        staged = []
        for i, (old, nd, new) in enumerate(moves):
            tmp = os.path.join(stage, "%05d" % i)
            os.rename(os.path.join(root, old), tmp)
            staged.append((tmp, old, nd, new))
        for tmp, old, nd, new in staged:
            os.makedirs(os.path.join(root, nd), exist_ok=True)
            dst = os.path.join(root, nd, new)
            if os.path.exists(dst):
                raise SystemExit("target exists, stopped (staged files are in %s): %s" % (stage, dst))
            os.rename(tmp, dst)
            log.write("%s -> %s/%s\n" % (old, nd, new))
    os.rmdir(stage)
    removed = []
    for d in folders:
        p = os.path.join(root, d)
        if os.path.isdir(p) and not os.listdir(p):
            os.rmdir(p)
            removed.append(d)
    print("moved %d files; empty folders removed: %s; log: %s" % (len(moves), " ".join(removed) or "none", logp))


if __name__ == "__main__":
    main()
