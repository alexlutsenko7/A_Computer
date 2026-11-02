#!/usr/bin/env python3
"""mk_update.py -- LUPDATE.BIN, the flash update the ESP32 installs from the SD card
(LSpectrum/esp32/src/update.cpp), and the loader .jic for boards shipped without machines.

  python3 tools/mk_update.py [--cof L.cof] [--out output_files/LUPDATE.BIN] [--label TEXT]
      builds output_files/L_raw.pof and .rpd from the .cof (the same images and ROMs as L.jic)
      with quartus_cpf, then LUPDATE.BIN from the .rpd
  python3 tools/mk_update.py --rpd FILE.rpd --out LUPDATE.BIN [--label TEXT]
      only the last step (tests)
  python3 tools/mk_update.py --loader [--out output_files/L_loader.jic]
      the loader .jic: the machine menu at flash 0, the rest of the flash 00 to 8 MB. On hardware the
      Programmer left old machines in place both with FF data there and with its Erase option (it
      appears to skip sectors that are all FF); programming 00 clears every bit whether the sector is
      erased first or not. The board shows "No machines installed" until LUPDATE.BIN is on the card

File: 256-byte header ("LUPDATE1", image length, CRC-32 of the image, skip range = the C64 ROM area
0x580000-0x5FFFFF that the ESP32 installs itself, menu end 0x100000, a 64-byte label, CRC-32 of the
header), then the flash image from address 0 as the flash returns it over SPI, cut after its last used
4 KB sector. The .rpd holds every byte bit-reversed (LSB first): seen on hardware 2026-10-30, the ESP32 reads
56 EF EF EF at an image's start where the .rpd has 6A F7 F7 F7 (sync byte 6A), so the bits are reversed here.
Run from AMenu/.
"""
import argparse, datetime, os, re, struct, subprocess, sys, zlib

CPF = os.environ.get('QUARTUS_CPF', '/mnt/c/Altera/quartus/bin64/quartus_cpf.exe')
SECTOR = 4096
SKIP = (0x580000, 0x600000)
MENU_END = 0x100000            # the factory slot (1 MB slots: docs/PLAN.md)


def cpf(*args):
    r = subprocess.run([CPF] + list(args), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if r.returncode != 0 or 'was successful' not in r.stdout:
        sys.exit('quartus_cpf failed:\n' + r.stdout[-2000:])


def build_rpd(cof):
    """L.cof -> a .pof (no flash loader) -> .rpd; returns the .rpd path"""
    s = open(cof).read()
    s = re.sub(r'<output_filename>[^<]*</output_filename>', '<output_filename>output_files/L_raw.pof</output_filename>', s)
    s = re.sub(r'\s*<flash_loader_device>[^<]*</flash_loader_device>', '', s)
    tmp = 'L_raw.cof'
    open(tmp, 'w').write(s)
    try:
        cpf('-c', tmp)
        cpf('-c', 'output_files/L_raw.pof', 'output_files/L_raw.rpd')
    finally:
        os.remove(tmp)
        for f in ('output_files/L_raw.map',):
            if os.path.exists(f):
                os.remove(f)
    return 'output_files/L_raw.rpd'


REV = bytes(int('{:08b}'.format(x)[::-1], 2) for x in range(256))


def make_update(rpd, out, label):
    img = open(rpd, 'rb').read().translate(REV)       # .rpd (LSB first) -> the bytes as the flash returns them
    if img[0x20] != 0x56:                              # the menu image's sync byte 6A, as read over SPI
        sys.exit('%s: no configuration image at 0x20 (0x%02X, expected 0x56)' % (rpd, img[0x20]))
    end = len(img)
    while end > 0 and img[end - 1] == 0xFF:
        end -= 1
    end = (end + SECTOR - 1) // SECTOR * SECTOR
    img = img[:end]
    lab = label.encode('ascii', 'replace')[:64].ljust(64, b'\0')
    hdr = b'LUPDATE1' + struct.pack('<IIIII', len(img), zlib.crc32(img), SKIP[0], SKIP[1], MENU_END) + lab
    hdr = hdr.ljust(252, b'\0')
    hdr += struct.pack('<I', zlib.crc32(hdr))
    with open(out, 'wb') as f:
        f.write(hdr + img)
    print('%s: %d KB image (to 0x%06X), label "%s"' % (out, len(img) // 1024, len(img), label))


def blank_hex(path, start, end):
    """Intel hex of 00 from start to end (relative addresses, as the .cof's hex blocks)"""
    with open(path, 'w', newline='\n') as f:
        seg = -1
        for a in range(0, end - start, 32):
            if a >> 16 != seg:
                seg = a >> 16
                rec = bytes([2, 0, 0, 4, seg >> 8, seg & 0xFF])
                f.write(':%s%02X\n' % (rec.hex().upper(), (-sum(rec)) & 0xFF))
            rec = bytes([32, (a >> 8) & 0xFF, a & 0xFF, 0]) + b'\x00' * 32
            f.write(':%s%02X\n' % (rec.hex().upper(), (-sum(rec)) & 0xFF))
        f.write(':00000001FF\n')


def make_loader(out):
    s = open('L.cof').read()
    s = re.sub(r'<output_filename>[^<]*</output_filename>', '<output_filename>%s</output_filename>' % out, s)
    s = re.sub(r'\s*<hex_block>.*?</hex_block>', '', s, flags=re.S)
    blank_hex('L_blank.hex', MENU_END, 0x800000)
    s = s.replace('<mode>7</mode>', '<mode>7</mode>\n\t<hex_block>\n\t\t<hex_filename>L_blank.hex</hex_filename>\n'
                  '\t\t<hex_addressing>relative</hex_addressing>\n\t\t<hex_offset>%d</hex_offset>\n\t</hex_block>' % MENU_END)
    s = re.sub(r'\s*<sof_data>\s*<start_address>.*?</sof_data>', '', s, flags=re.S)   # every page but Page_0
    s = re.sub(r'<n_pages>\d+</n_pages>', '<n_pages>1</n_pages>', s)
    tmp = 'L_loader_tmp.cof'
    open(tmp, 'w').write(s)
    try:
        cpf('-c', tmp)
    finally:
        os.remove(tmp)
        os.remove('L_blank.hex')
    m = os.path.splitext(out)[0] + '.map'
    if os.path.exists(m):
        print(open(m).read().split('Configuration device')[0].strip())
        os.remove(m)
    print('%s: the machine menu, the rest of the flash 00' % out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--cof', default='L.cof')
    ap.add_argument('--rpd')
    ap.add_argument('--out')
    ap.add_argument('--label', default='L ' + datetime.date.today().isoformat())
    ap.add_argument('--loader', action='store_true')
    a = ap.parse_args()
    if a.loader:
        make_loader(a.out or 'output_files/L_loader.jic')
        return
    rpd = a.rpd or build_rpd(a.cof)
    make_update(rpd, a.out or 'output_files/LUPDATE.BIN', a.label)
    if not a.rpd:
        for f in ('output_files/L_raw.pof', 'output_files/L_raw.rpd'):
            os.remove(f)


main()
