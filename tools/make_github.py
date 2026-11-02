#!/usr/bin/env python3
"""make_github.py [ROOT] -- copy the publishable part of the project into ROOT/github (the public repo A_Computer).

Left out: Commodore ROMs, Retroleum's DiagROM (licence unknown: the public LSpectrum ROM image and L.jic get
48K BASIC in that slot), third-party PDFs (docs/vendor/README.md lists them), the Altirra manual (LTari/ref),
game-derived files, build / simulation by-products, local notes. Run from the project root:
    python3 tools/make_github.py
then check github/ and copy it into the clone of the public repository."""
import os, re, shutil, sys, fnmatch

ROOT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else '.')
DST = os.path.join(ROOT, 'github')

TOP = ['AMenu', 'LSpectrum', 'L64', 'LTari', 'T65', 'T80', 'DDR_TEST', 'VGA_TEST', 'docs', 'tests', 'tools',
       'Extra_PCB_CycloneIV', 'README.md', 'LICENSE', 'BUILDING_AND_LICENSES.md']

SKIP_DIRS = {'db', 'incremental_db', 'greybox_tmp', '.qsys_edit', '__pycache__', 'node_modules', '.git',
             'roms_local',          # C64 ROMs (copyright)
             'ref',                 # LTari/ref: Altirra manual PDF + files from atari800
             'syn_check',           # LTari scratch synthesis check
             '.history', 'Extra_PCB_CycloneIV-backups',   # KiCad local history and backups
             'old'}                 # Extra_PCB_CycloneIV/old: a superseded routing
SKIP_DIR_GLOBS = ['work*']          # Questa libraries, host-test work folders

SKIP_FILES = ['*.log', 'transcript', '*.rpt', '*.summary', '*.smsg', '*.done', '*.jdi', '*.pin', '*.sld', '*.qws',
              '*.bak', '*.ppm', '*.tmp', '~$*', '*.qdf', '*.wlf', '*.vcd', '*.img', '*.pyc', '*.chg', '*.qarlog',
              'c64roms*.mem', 'c64roms*.hex',  # C64 ROMs in the simulation folder
              '*.pdf',                         # third-party datasheets / manuals (links in docs/vendor/README.md)
              'Monitor_at_work.txt',           # local monitor data (serial number)
              'sw_img.hex',                    # generated from a game snapshot (Sidewize): copyrighted
              '*.vstf',                        # Questa crash dumps
              '*.ino.map',                     # ESP32 linker map: holds the Windows user's home path
              '*.kicad_prl', 'fp-info-cache', '*.lck', '*.dsn', '*.ses']   # KiCad local state, routing files
# generated simulation pictures (sim/*.png); documentation pictures stay
SKIP_PATH_RE = [r'(^|/)sim/[^/]*\.png$', r'(^|/)sim/.*\.bmp$', r'^tests/.*/output_files/',
                r'^docs/manuals/(build|pdf)/']   # manual previews / PDFs (the PDFs go into INSTALL/)
# build outputs: only the programming files
KEEP_OUTPUT = ['*.sof', 'L.jic']             # (LUPDATE.BIN and L_loader.jic are made below from the public image)

# own documents that are PDFs (the '*.pdf' rule above is for third-party files)
KEEP_PDF = ['Extra_PCB_CycloneIV/Extra_PCB_CycloneIV.pdf']   # the I/O board's schematic, plotted by KiCad

def skip_file(rel, name):
    if rel in KEEP_PDF:
        return False
    if any(fnmatch.fnmatch(name, g) for g in SKIP_FILES):
        return True
    if any(re.search(r, rel) for r in SKIP_PATH_RE):
        return True
    if '/output_files/' in '/' + rel:
        return not any(fnmatch.fnmatch(name, g) for g in KEEP_OUTPUT)
    return False

# github/ is also the user's git working copy (Sourcetree): everything is rebuilt except .git
os.makedirs(DST, exist_ok=True)
for e in os.listdir(DST):
    if e == '.git':
        continue
    p = os.path.join(DST, e)
    if os.path.isdir(p) and not os.path.islink(p):
        try:
            shutil.rmtree(p)
        except PermissionError:          # a folder open in Explorer / Sourcetree: it stays, but empty
            for e2 in os.listdir(p):
                q = os.path.join(p, e2)
                shutil.rmtree(q) if os.path.isdir(q) and not os.path.islink(q) else os.remove(q)
    else:
        os.remove(p)
n = size = 0
for t in TOP:
    src = os.path.join(ROOT, t)
    if os.path.isfile(src):
        shutil.copy2(src, os.path.join(DST, t)); n += 1; size += os.path.getsize(src)
        continue
    for d, dirs, files in os.walk(src):
        dirs[:] = [x for x in dirs if x not in SKIP_DIRS and not any(fnmatch.fnmatch(x, g) for g in SKIP_DIR_GLOBS)]
        for f in files:
            rel = os.path.relpath(os.path.join(d, f), ROOT).replace('\\', '/')
            if skip_file(rel, f):
                continue
            out = os.path.join(DST, rel)
            os.makedirs(os.path.dirname(out), exist_ok=True)
            shutil.copy2(os.path.join(d, f), out)
            n += 1; size += os.path.getsize(out)
print('%d files, %.1f MB' % (n, size / 1e6))

# repository files
with open(os.path.join(DST, '.gitignore'), 'w', newline='\n') as f:
    f.write('''# Commodore ROMs (copyright): never in the repository
L64/roms_local/
L64/sim/c64roms*.mem
L64/sim/c64roms*.hex
# Quartus / Questa / tools: generated
db/
incremental_db/
greybox_tmp/
**/output_files/*
!**/output_files/*.sof
!AMenu/output_files/L.jic
!AMenu/output_files/L_loader.jic
!AMenu/output_files/LUPDATE.BIN
work*/
*.log
transcript
*.vstf
__pycache__/
node_modules/
~$*
''')
print('.gitignore written')

# public ROM image (no DiagROM) and the public L.jic built from it
import subprocess
lsp = os.path.join(DST, 'LSpectrum')
subprocess.run([sys.executable, '-I', 'tools/mk_roms48k.py', os.path.join(ROOT, 'roms', 'zx128.rom'), 'roms48k.hex',
                'sim/roms.mem'], cwd=lsp, check=True)
cpf = '/mnt/c/Altera/quartus/bin64/quartus_cpf.exe'
subprocess.run([cpf, '-c', 'L.cof'], cwd=os.path.join(DST, 'AMenu'), check=True, stdout=subprocess.DEVNULL)
os.remove(os.path.join(DST, 'AMenu', 'output_files', 'L.map'))
import datetime
subprocess.run([sys.executable, '-I', 'tools/mk_update.py', '--label', 'L %s' % datetime.date.today().isoformat()],
               cwd=os.path.join(DST, 'AMenu'), check=True)
subprocess.run([sys.executable, '-I', 'tools/mk_update.py', '--loader'], cwd=os.path.join(DST, 'AMenu'), check=True)
# INSTALL/: for buyers of a ready board set (ESP32 programmed, machine menu in the FPGA): only the machines'
# image for the SD card and the manuals (docs/manuals/build_manuals.py). The developer files (L_loader.jic,
# the ESP32 binaries) stay in AMenu/output_files and LSpectrum/esp32/build.
inst = os.path.join(DST, 'INSTALL')
os.makedirs(inst, exist_ok=True)
shutil.copy2(os.path.join(DST, 'AMenu', 'output_files', 'LUPDATE.BIN'), os.path.join(inst, 'LUPDATE.BIN'))
man = os.path.join(ROOT, 'docs', 'manuals', 'pdf')
for lang in sorted(os.listdir(man)):
    os.makedirs(os.path.join(inst, lang), exist_ok=True)
    for f in sorted(os.listdir(os.path.join(man, lang))):
        if f.endswith('.pdf'):
            shutil.copy2(os.path.join(man, lang, f), os.path.join(inst, lang, f))
with open(os.path.join(inst, 'README.txt'), 'w', newline='\n') as f:
    f.write("""L - installing the machines

1. Format a microSD card as FAT32 or FAT16 (not exFAT).
2. Copy LUPDATE.BIN to the root folder of the card.
3. Put the card into the board and switch it on. Wait for "Update complete." (about one minute).

Step by step and in your language: <language>/L_Installation_Guide_<language>.pdf.
Keys, menus, joysticks: <language>/L_User_Manual_<language>.pdf.
Languages: EN English, SP Espanol, PT Portugues, DE Deutsch, UA Ukrainska, RU Russkiy, CN Zhongwen, KR Hangugeo,
JP Nihongo.

Not included: games and other programs, and the Commodore 64 ROMs (copyrighted). Get them yourself; see section 4
of the installation guide.
""")
print('INSTALL/ built: %d languages' % len(os.listdir(man)))
sig = b'RETRO' + b'LEUM'                         # DiagROM's signature, as is and bit-reversed (flash images)
sig_rev = bytes(int('{:08b}'.format(x)[::-1], 2) for x in sig)
for d, _, fs in os.walk(DST):
    for f in fs:
        data = open(os.path.join(d, f), 'rb').read()
        if sig in data or sig_rev in data:
            sys.exit('DiagROM data left in ' + os.path.join(d, f))
print('public roms48k.hex, sim/roms.mem, AMenu/output_files/L.jic, LUPDATE.BIN and L_loader.jic built (no DiagROM)')

# github/ as a git working copy: files that differ from the last commit only in line endings are put back as
# committed, so the commit shows only real changes
if os.path.isdir(os.path.join(DST, '.git')):
    git = ['git', '-C', DST, '-c', 'core.filemode=false']
    st = subprocess.run(git + ['status', '--porcelain'], capture_output=True, text=True, check=True).stdout
    eol = [l[3:] for l in st.splitlines() if l.startswith(' M ')
           and subprocess.run(git + ['diff', '--quiet', '--ignore-cr-at-eol', '--', l[3:]]).returncode == 0]
    if eol:
        subprocess.run(git + ['checkout', '--'] + eol, check=True)
    print('git: %d files with line-ending-only changes put back as committed' % len(eol))
    # changed text files get the line endings of their committed version (Quartus rewrites .qsf / .qpf with
    # CRLF): the diff then shows only the real changes
    fixed = 0
    for l in st.splitlines():
        f = l[3:]
        if not l.startswith(' M ') or f in eol:
            continue
        old = subprocess.run(git + ['show', 'HEAD:' + f], capture_output=True).stdout
        path = os.path.join(DST, f)
        new = open(path, 'rb').read()
        if b'\0' in old[:8192] or b'\0' in new[:8192]:
            continue                                  # binary
        crlf_old, crlf_new = b'\r\n' in old, b'\r\n' in new
        if crlf_old == crlf_new:
            continue
        lf = new.replace(b'\r\n', b'\n')
        open(path, 'wb').write(lf.replace(b'\n', b'\r\n') if crlf_old else lf)
        fixed += 1
    print('git: %d changed files given their committed line endings' % fixed)
