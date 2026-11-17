#!/usr/bin/env python3
"""mk_update.py -- LUPDATE.BIN, the update of the machine menu that the ESP32 installs from the SD card
(ESP32/v1/src/update.cpp), and the loader .jic for boards shipped without machines.

  python3 tools/mk_update.py [--out output_files/LUPDATE.BIN] [--label TEXT]
      LUPDATE.BIN from output_files/L_flash.bin (tools/mk_flash.py: the flash as SPI reads it): the menu
      alone. The machines are not in it: each is a machine file that the user installs from the card's
      MACHINES folder (output_files/machines/, mk_flash.py)
  python3 tools/mk_update.py --whole --out FILE [--flash L_flash.bin]
      the whole flash image with a skipped range, as the update file was before the machine files: the
      firmware still takes it, and ESP32_test/v1/test/update_test.cpp runs its scenarios with it
  python3 tools/mk_update.py --loader [--out output_files/L_loader.jic]
      the loader .jic: the machine menu at flash 0, the rest of the flash 00 to 8 MB. On hardware the
      Programmer left old machines in place both with FF data there and with its Erase option (it
      appears to skip sectors that are all FF); programming 00 clears every bit whether the sector is
      erased first or not. The board shows "No machines installed" until machines are installed from the card

File: 256-byte header ("LUPDATE1", image length, CRC-32 of the image, skip range (none; --whole: 0x580000-
0x5FFFFF), menu end = where the factory image's part ends (the image length; --whole: 0x100000), a 64-byte
label, CRC-32 of the header), then the flash image from address 0 as the flash returns it over SPI, cut after
its last used 4 KB sector.
Run from AMenu/ep4_ce15/ or AMenu/10cl025/ (python3 ../ep4_ce15/tools/mk_update.py).
"""
import argparse, datetime, os, re, struct, subprocess, sys, zlib

CPF = os.environ.get('QUARTUS_CPF', '/mnt/c/Altera/quartus/bin64/quartus_cpf.exe')
SECTOR = 4096
WHOLE_SKIP = (0x580000, 0x600000)
MENU_END = 0x100000            # the factory image's megabyte (docs/PLAN.md)


def cpf(*args):
    r = subprocess.run([CPF] + list(args), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if r.returncode != 0 or 'was successful' not in r.stdout:
        sys.exit('quartus_cpf failed:\n' + r.stdout[-2000:])


def make_update(flash, out, label, whole):
    img = open(flash, 'rb').read()                     # the bytes as the flash returns them
    if img[0x20] != 0x56:                              # the menu image's sync byte 6A, as read over SPI
        sys.exit('%s: no configuration image at 0x20 (0x%02X, expected 0x56)' % (flash, img[0x20]))
    if not whole:
        img = img[:MENU_END]
    end = len(img)
    while end > 0 and img[end - 1] == 0xFF:
        end -= 1
    end = (end + SECTOR - 1) // SECTOR * SECTOR
    img = img[:end]
    skip, menu_end = (WHOLE_SKIP, MENU_END) if whole else ((0, 0), len(img))
    lab = label.encode('ascii', 'replace')[:64].ljust(64, b'\0')
    hdr = b'LUPDATE1' + struct.pack('<IIIII', len(img), zlib.crc32(img), skip[0], skip[1], menu_end) + lab
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
    ap.add_argument('--flash', default='output_files/L_flash.bin')
    ap.add_argument('--out')
    ap.add_argument('--label', default='L ' + datetime.date.today().isoformat())
    ap.add_argument('--whole', action='store_true')
    ap.add_argument('--loader', action='store_true')
    a = ap.parse_args()
    if a.loader:
        make_loader(a.out or 'output_files/L_loader.jic')
        return
    make_update(a.flash, a.out or 'output_files/LUPDATE.BIN', a.label, a.whole)


main()
