#!/usr/bin/env python3
"""sort_atari.py ZIPDIR DEST [--apply] -- an Atari 8-bit collection of zips -> the LTari SD card layout

DEST is Games/Atari. Without --apply only a summary and a sample are printed.
  1. everything already in DEST (except #tested) moves into DEST/#tested (the files tried on the board);
  2. from every zip in ZIPDIR the files LTari can use are taken: .atr (header 96 02), .xex / .com (binary
     load, FF FF), .car of the types the ESP32 supports (1, 2, 41, 42, 75); folders inside the zip are
     flattened, nothing is run. Other files (.txt, .cas, .atx, other cartridge types, ...) are skipped and
     counted. A file whose contents are already there (also in #tested) is not stored twice;
  3. names are shortened to 27 characters as the ZX collection (tools/shorten_names.py rules), ASCII only;
  4. files are put into folders by their first character (a-z, else "123"), sorted by name as the browser
     does, at most 300 per folder: "a", then "a1", "a2", ... (the browser lists 320 entries).
With --apply the zip -> file list goes to DEST/../atari_import.log."""
import hashlib, os, re, shutil, sys, unicodedata, zipfile

MAX, PER = 27, 300
CART_TYPES = {1, 2, 41, 42, 75}


def ascii_only(s):
    s = unicodedata.normalize('NFKD', s)
    s = ''.join(c for c in s if not unicodedata.combining(c))
    return ''.join(c if 32 <= ord(c) < 127 and c not in '\\/:*?"<>|' else '_' for c in s)


# side / disk / part first, so that they survive the cutting (multi-disk programs): "x _ side A" -> "x-SA",
# "x - Disk 2" / "x (Disk 2 of 3)" -> "x-D2"
ABBR = [(r'[\s_-]*\(?\b[Ss]ide\s+([0-9A-Za-z])\b\)?', r'-S\1'),
        (r'[\s_-]*\(?\b[Dd]is[kc]\s+([0-9]+)(\s+of\s+[0-9]+)?\b\)?', r'-D\1'),
        (r'[\s_-]*\(?\b[Pp]art\s+([0-9IVX]+)\b\)?', r'-P\1'),
        (r'\bAlternate\b', 'Alt'), (r'\bRelease\s+([0-9.]+)', r'R\1'), (r'\bVersion\b', 'V'),
        (r'\s+-\s+', '-'), (r'^The\s+', '')]


def shorten(name):
    """(base, ext, dropped brackets), as tools/shorten_names.py"""
    base, ext = os.path.splitext(name)
    base = ascii_only(base).strip(); ext = ascii_only(ext).lower()
    room = MAX - len(ext)
    for pat, rep in ABBR:
        if len(base) <= room:
            break
        base = re.sub(pat, rep, base)
    dropped = []
    while len(base) > room and re.search(r'\s*[\(\[][^()\[\]]*[\)\]]\s*$', base):
        dropped.insert(0, re.search(r'[\(\[]([^()\[\]]*)[\)\]]\s*$', base).group(1))
        base = re.sub(r'\s*[\(\[][^()\[\]]*[\)\]]\s*$', '', base)
    if len(base) > room:
        m = re.search(r'(-[^-]{1,8})$', base)
        tail = m.group(1) if m and len(m.group(1)) < room - 6 else ''
        head = base[:len(base) - len(tail)] if tail else base
        base = head[:room - len(tail)].rstrip(' -,._') + tail
    return base or 'noname', ext, dropped


def usable(name, data):
    """'' if LTari can use the file, else the reason"""
    e = os.path.splitext(name)[1].lower()
    if e == '.atr':
        return '' if data[:2] == b'\x96\x02' else 'atr header'
    if e in ('.xex', '.com'):
        return '' if data[:2] == b'\xff\xff' else 'no FF FF'
    if e == '.car':
        if data[:4] != b'CART':
            return 'car header'
        t = int.from_bytes(data[4:8], 'big')
        return '' if t in CART_TYPES else 'car type %d' % t
    return e or 'no extension'


def folder_of(name):
    c = name[0].lower()
    return c if 'a' <= c <= 'z' else '123'


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    zipdir, dest, apply = sys.argv[1], sys.argv[2], '--apply' in sys.argv
    tested = os.path.join(dest, '#tested')
    seen = set()                                    # sha1 of every file kept
    for d, _, fs in os.walk(dest):
        for f in fs:
            seen.add(hashlib.sha1(open(os.path.join(d, f), 'rb').read()).hexdigest())

    skipped, bad_zips, dups = {}, [], 0
    found = []                                      # (zip, original name, data)
    zips = sorted(f for f in os.listdir(zipdir) if f.lower().endswith('.zip'))
    for zn in zips:
        try:
            z = zipfile.ZipFile(os.path.join(zipdir, zn))
            infos = [i for i in z.infolist() if not i.is_dir()]
        except Exception:
            bad_zips.append(zn); continue
        for i in infos:
            base = os.path.basename(i.filename.replace('\\', '/'))
            if not base:
                continue
            if i.file_size > 2 * 1024 * 1024:       # nothing LTari loads is that big
                skipped['too big'] = skipped.get('too big', 0) + 1; continue
            try:
                data = z.read(i)
            except Exception:
                bad_zips.append(zn); break
            why = usable(base, data)
            if why:
                skipped[why] = skipped.get(why, 0) + 1; continue
            h = hashlib.sha1(data).hexdigest()
            if h in seen:
                dups += 1; continue
            seen.add(h)
            found.append((zn, base, data))

    # names and folders
    groups = {}
    for zn, base, data in found:
        b, e, dropped = shorten(base)
        groups.setdefault(folder_of(b), []).append([b, e, dropped, zn, base, data])
    plan = []                                       # (folder, file name, zip, original, data)
    for g in sorted(groups):
        items = groups[g]
        taken = set()
        for it in sorted(items, key=lambda x: (x[0] + x[1]).lower()):
            b, e, dropped = it[0], it[1], it[2]
            new = b + e
            if new.lower() in taken and dropped:
                tag = re.sub(r'[^A-Za-z0-9]', '', ''.join(dropped))
                for n in range(min(len(tag), 8), 1, -1):
                    t = ' (' + tag[:n] + ')'
                    cand = b[:MAX - len(e) - len(t)].rstrip(' -,._') + t + e
                    if cand.lower() not in taken:
                        new = cand; break
            k = 2
            while new.lower() in taken:
                suf = ' %d' % k
                new = b[:MAX - len(e) - len(suf)].rstrip(' -,._') + suf + e
                k += 1
            taken.add(new.lower())
            it.append(new)
        items.sort(key=lambda x: x[6].lower())
        for n in range(0, len(items), PER):
            fold = g if n == 0 else '%s%d' % (g, n // PER)
            for it in items[n:n + PER]:
                plan.append((fold, it[6], it[3], it[4], it[5]))

    print('%d zips (%d unreadable), %d usable files, %d duplicates left out' % (len(zips), len(bad_zips), len(found), dups))
    print('skipped:', ', '.join('%s %d' % kv for kv in sorted(skipped.items(), key=lambda kv: -kv[1])))
    folds = {}
    for f, *_ in plan:
        folds[f] = folds.get(f, 0) + 1
    print('folders:', ' '.join('%s:%d' % kv for kv in sorted(folds.items())))
    exts = {}
    for _, n, *_ in plan:
        e = os.path.splitext(n)[1]; exts[e] = exts.get(e, 0) + 1
    print('types:', exts)
    if not apply:
        import random
        random.seed(1)
        for f, n, zn, base, _ in random.sample(plan, min(12, len(plan))):
            print('  %-58s -> %s/%s' % (base[:58], f, n))
        print('(dry run: add --apply)')
        return

    os.makedirs(tested, exist_ok=True)
    for f in os.listdir(dest):
        if f != '#tested':
            shutil.move(os.path.join(dest, f), os.path.join(tested, f))
    with open(os.path.join(dest, '..', 'atari_import.log'), 'w', encoding='utf-8') as log:
        for fold, n, zn, base, data in plan:
            os.makedirs(os.path.join(dest, fold), exist_ok=True)
            with open(os.path.join(dest, fold, n), 'wb') as o:
                o.write(data)
            log.write('%s | %s -> %s/%s\n' % (zn, base, fold, n))
        for zn in bad_zips:
            log.write('UNREADABLE %s\n' % zn)
    print('written; list in %s' % os.path.normpath(os.path.join(dest, '..', 'atari_import.log')))


main()
