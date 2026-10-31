#!/usr/bin/env python3
"""shorten_names.py FOLDER [--apply] -- make .tap/.tzx/.z80 names fit the SD browser (27 characters incl. extension)

Dry run without --apply (prints a sample). Rules, in order, until the name fits:
  1. accents removed, other non-ASCII characters -> _ (the OSD shows them as ?)
  2. abbreviations: Side 1 -> S1, Part 2 -> P2, Alternate -> Alt, Release 1 -> R1, Version -> V,
     " - " -> "-", a leading "The " dropped
  3. bracketed parts (publisher, year, ...) dropped from the end
  4. the middle is cut, a short last "-..." part (side, part) is kept
A name clash in the folder gets a short tag of the dropped brackets, e.g. "(DroSoft)", else " 2", " 3", ...
With --apply, every rename is listed in FOLDER/../renamed_files.txt. Files named in protected.txt (in FOLDER or up
to two levels above) are never renamed."""
MAX = 27
import os, re, sys, unicodedata
root = sys.argv[1]; apply = len(sys.argv) > 2 and sys.argv[2] == '--apply'


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
protected = load_protected(root)
def ascii_only(s):
    s = unicodedata.normalize('NFKD', s)
    s = ''.join(c for c in s if not unicodedata.combining(c))
    return ''.join(c if 32 <= ord(c) < 127 else '_' for c in s)
ABBR = [(r'\bSide\s+([0-9A-Za-z])\b', r'S\1'), (r'\bPart\s+([0-9IVX]+)\b', r'P\1'), (r'\bAlternate\b', 'Alt'),
        (r'\bRelease\s+([0-9.]+)', r'R\1'), (r'\bVersion\b', 'V'), (r'\s+-\s+', '-'), (r'^The\s+', '')]
def shorten(name):
    base, ext = os.path.splitext(name)
    base = ascii_only(base).strip(); ext = ascii_only(ext)
    room = MAX - len(ext)
    for pat, rep in ABBR:
        if len(base) <= room: break
        base = re.sub(pat, rep, base)
    dropped = []
    while len(base) > room and re.search(r'\s*\([^()]*\)\s*$', base):
        dropped.insert(0, re.search(r'\(([^()]*)\)\s*$', base).group(1))
        base = re.sub(r'\s*\([^()]*\)\s*$', '', base)
    shorten.dropped = dropped
    if len(base) > room:                       # keep the last "-..." part (side, part), cut the middle
        m = re.search(r'(-[^-]{1,8})$', base)
        tail = m.group(1) if m and len(m.group(1)) < room - 6 else ''
        head = base[:len(base) - len(tail)] if tail else base
        base = head[:room - len(tail)].rstrip(' -,._') + tail
    return base, ext
changes = []; stats = {'long': 0, 'nonascii': 0}
for d, _, fs in os.walk(root):
    taken = {f.lower() for f in fs}
    for f in sorted(fs):
        if not f.lower().endswith(('.tap', '.tzx', '.z80')) or f.lower() in protected: continue
        if len(f) <= MAX and ascii_only(f) == f: continue
        if len(f) > MAX: stats['long'] += 1
        if ascii_only(f) != f: stats['nonascii'] += 1
        base, ext = shorten(f); new = base + ext; k = 2
        if new.lower() in taken and shorten.dropped:          # clash: keep a short tag of the dropped brackets
            tag = re.sub(r'[^A-Za-z0-9]', '', ''.join(shorten.dropped))
            for n in range(min(len(tag), 8), 1, -1):
                t = ' (' + tag[:n] + ')'
                cand = base[:MAX - len(ext) - len(t)].rstrip(' -,._') + t + ext
                if cand.lower() not in taken: new = cand; break
        while new.lower() in taken and new.lower() != f.lower():
            suf = ' %d' % k; new = base[:MAX - len(ext) - len(suf)].rstrip(' -,._') + suf + ext; k += 1
        taken.discard(f.lower()); taken.add(new.lower())
        changes.append((d, f, new))
print('%d files to rename (%d longer than %d characters, %d with non-ASCII characters)' % (len(changes), stats['long'], MAX, stats['nonascii']))
if not apply:
    import random; random.seed(1)
    for d, f, n in random.sample(changes, min(15, len(changes))): print('  %-60s -> %s' % (f, n))
    print('suffix needed:', sum(1 for _,_,n in changes if re.search(r' \d+\.\w+$', n) and not re.search(r' \d+\.\w+$', _)))
else:
    with open(os.path.join(root, '..', 'renamed_files.txt'), 'w') as log:
        for d, f, n in changes:
            os.rename(os.path.join(d, f), os.path.join(d, n)); log.write('%s/%s -> %s\n' % (os.path.relpath(d, root), f, n))
    print('renamed; list in Games/renamed_files.txt')
