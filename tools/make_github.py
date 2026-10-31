#!/usr/bin/env python3
"""make_github.py [ROOT] -- copy the publishable part of the project into ROOT/github (the public repo L_8_bit).

Left out: Commodore ROMs, Retroleum's DiagROM (licence unknown: the public LSpectrum ROM image and L.jic get
48K BASIC in that slot), third-party PDFs (docs/vendor/README.md lists them), the Altirra manual (LTari/ref),
game-derived files, build / simulation by-products, local notes. Run from the project root:
    python3 tools/make_github.py
then check github/ and copy it into the clone of the public repository."""
import os, re, shutil, sys, fnmatch

ROOT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else '.')
DST = os.path.join(ROOT, 'github')

TOP = ['AMenu', 'LSpectrum', 'L64', 'LTari', 'T65', 'T80', 'DDR_TEST', 'VGA_TEST', 'docs', 'tests', 'tools',
       'README.md', 'LICENSE', 'BUILDING_AND_LICENSES.md']

SKIP_DIRS = {'db', 'incremental_db', 'greybox_tmp', '.qsys_edit', '__pycache__', 'node_modules', '.git',
             'roms_local',          # C64 ROMs (copyright)
             'ref',                 # LTari/ref: Altirra manual PDF + files from atari800
             'syn_check'}           # LTari scratch synthesis check
SKIP_DIR_GLOBS = ['work*']          # Questa libraries, host-test work folders

SKIP_FILES = ['*.log', 'transcript', '*.rpt', '*.summary', '*.smsg', '*.done', '*.jdi', '*.pin', '*.sld', '*.qws',
              '*.bak', '*.ppm', '*.tmp', '~$*', '*.qdf', '*.wlf', '*.vcd', '*.img', '*.pyc', '*.chg', '*.qarlog',
              'c64roms*.mem', 'c64roms*.hex',  # C64 ROMs in the simulation folder
              '*.pdf',                         # third-party datasheets / manuals (links in docs/vendor/README.md)
              'Monitor_at_work.txt',           # local monitor data (serial number)
              'sw_img.hex',                    # generated from a game snapshot (Sidewize): copyrighted
              '*.vstf']                        # Questa crash dumps
# generated simulation pictures (sim/*.png); documentation pictures stay
SKIP_PATH_RE = [r'(^|/)sim/[^/]*\.png$', r'(^|/)sim/.*\.bmp$', r'^tests/.*/output_files/']
# build outputs: only the programming files
KEEP_OUTPUT = ['*.sof', 'L.jic']             # (LUPDATE.BIN and L_loader.jic are made below from the public image)

def skip_file(rel, name):
    if any(fnmatch.fnmatch(name, g) for g in SKIP_FILES):
        return True
    if any(re.search(r, rel) for r in SKIP_PATH_RE):
        return True
    if '/output_files/' in '/' + rel:
        return not any(fnmatch.fnmatch(name, g) for g in KEEP_OUTPUT)
    return False

if os.path.exists(DST):
    shutil.rmtree(DST)
os.makedirs(DST)
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
sig = b'RETRO' + b'LEUM'                         # DiagROM's signature, as is and bit-reversed (flash images)
sig_rev = bytes(int('{:08b}'.format(x)[::-1], 2) for x in sig)
for d, _, fs in os.walk(DST):
    for f in fs:
        data = open(os.path.join(d, f), 'rb').read()
        if sig in data or sig_rev in data:
            sys.exit('DiagROM data left in ' + os.path.join(d, f))
print('public roms48k.hex, sim/roms.mem, AMenu/output_files/L.jic, LUPDATE.BIN and L_loader.jic built (no DiagROM)')
