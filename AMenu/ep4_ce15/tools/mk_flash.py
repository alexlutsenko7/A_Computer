#!/usr/bin/env python3
"""mk_flash.py -- the flash contents for one core board: L.cof / L.jic and the machine files for the SD card.

Flash layout (8 MB, docs/PLAN.md): the machine menu at 0, then three positions of 2 MB:

    position    bitstream    ROM area
       1        0x100000     0x200000
       2        0x300000     0x400000
       3        0x500000     0x600000        (0x700000-0x7FFFFF is not used)

A ROM area starts with the machine's info sector (4 KB), the ROM image follows at + 0x1000:

    0x00  tag A5 5A <machine byte> <its complement>: the machine's ROM loader finds its ROM area by it
    0x04  core ID, 4 bytes, high byte first
    0x08  board (1 = EP4CE15, 2 = 10CL025), 0x09 flags (bit 0: the ROMs are the user's, installed by the ESP32)
    0x10  the menu line, 29 characters, space padded
    0x30  label (version), 32 bytes, NUL padded

Which machine sits in a position is not fixed: L.jic holds the three of INSTALLED, and every machine is also
written as a machine file that the ESP32 installs from the SD card's /MACHINES folder into a position the
user chooses (ESP32/vN/src/update.cpp, mch_install):

    0    "LMACHIN1"
    8    board, 12 image length, 16 CRC-32 of the image, 20 ROM length, 24 CRC-32 of the ROM data,
         28 CRC-32 of the info sector, 32 flags (as in the info sector)       (all 32 bits, low byte first)
    252  CRC-32 of bytes 0-251
    256  the info sector (4096 bytes), then the ROM data, then the image (both whole 4 KB sectors),
         all as the flash returns the bytes over SPI

Run in AMenu/ep4_ce15 or AMenu/10cl025 after the Quartus builds:
    python3 ../ep4_ce15/tools/mk_flash.py [--label TEXT]
writes L.cof, output_files/L.jic (+ L.map), output_files/L_flash.bin (the whole flash as SPI reads it, for the
tests) and output_files/machines/*.LMC. The bitstreams are taken from a scratch .pof, and the tool checks that
the flash image it composed is byte for byte what Quartus puts into the .jic's data (bitstreams independent
of their address; .hex blocks: the .jic file holds their bytes bit-reversed and the bitstreams' as they are,
the flash returns the bitstreams' bytes bit-reversed over SPI, so the .hex bytes come back as written).
"""
import argparse, datetime, os, re, struct, subprocess, sys, zlib

CPF = os.environ.get('QUARTUS_CPF', '/mnt/c/Altera/quartus/bin64/quartus_cpf.exe')
SECTOR = 4096
MB = 0x100000
FLASH = 0x800000
POS_IMAGE = (0x100000, 0x300000, 0x500000)
POS_ROM = (0x200000, 0x400000, 0x600000)
ROM_OFFSET = 0x1000
ROM_MAX = MB - ROM_OFFSET
NAME_LEN = 29
FLAG_USER_ROMS = 1
BOARDS = {'ep4_ce15': (1, 'EP4CE15', 'ep4ce15'), '10cl025': (2, '10CL025Y', '10cl025')}

# key, folder, revision, machine byte of the tag, core ID, menu line (name, what), ROM .hex (None: the user's), flags
MACHINES = [
    ('LSpectrum', 'LSpectrum', 'LSpectrum', 0x18, 0x5A580001, ('LSpectrum', 'ZX Spectrum 128K'),
     'LSpectrum/ep4_ce15/roms48k.hex', 0),
    ('L64', 'L64', 'L64', 0x24, 0x43360003, ('L64', 'Commodore 64'), None, FLAG_USER_ROMS),
    ('LTari800', 'LTari', 'LTari800', 0x42, 0x41540001, ('LTari 800', 'Atari 800XL'),
     'LTari/ep4_ce15/roms/atarirom.hex', 0),
    ('LTari130', 'LTari', 'LTari', 0x42, 0x41540001, ('LTari 130', 'Atari 130XE'),
     'LTari/ep4_ce15/roms/atarirom.hex', 0),
    # no ROMs: the NES has none, a game is loaded into the SDRAM
    ('LNES', 'LNES', 'LNES', 0x66, 0x4E450001, ('LNES', 'Nintendo NES'), None, 0),
    # the Mega Drive needs the larger FPGA: a ninth field names the boards a machine exists for
    ('LMega', 'LMega', 'LMega', 0x3C, 0x4D440001, ('LMega', 'Sega Mega Drive'), None, 0, ('10cl025',)),
]
# the machines of L.jic, position 1 to 3
INSTALLED = ('LSpectrum', 'L64', 'LTari800')

REV = bytes(int('{:08b}'.format(x)[::-1], 2) for x in range(256))


def cpf(*args):
    r = subprocess.run([CPF] + list(args), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if r.returncode != 0 or 'was successful' not in r.stdout:
        sys.exit('quartus_cpf failed:\n' + r.stdout[-2000:])


def read_hex(path):
    """Intel hex -> bytes from address 0"""
    data, base = bytearray(), 0
    for line in open(path):
        line = line.strip()
        if not line.startswith(':'):
            continue
        rec = bytes.fromhex(line[1:])
        n, addr, typ = rec[0], (rec[1] << 8) | rec[2], rec[3]
        if typ == 4:
            base = ((rec[4] << 8) | rec[5]) << 16
        elif typ == 0:
            a = base + addr
            if len(data) < a + n:
                data.extend(b'\xFF' * (a + n - len(data)))
            data[a:a + n] = rec[4:4 + n]
    return bytes(data)


def write_hex(path, data):
    """bytes -> Intel hex from address 0 (the .cof places it), records that are all FF left out"""
    with open(path, 'w', newline='\n') as f:
        seg = -1
        for a in range(0, len(data), 32):
            chunk = data[a:a + 32]
            if chunk == b'\xFF' * len(chunk):
                continue
            if a >> 16 != seg:
                seg = a >> 16
                rec = bytes([2, 0, 0, 4, seg >> 8, seg & 0xFF])
                f.write(':%s%02X\n' % (rec.hex().upper(), (-sum(rec)) & 0xFF))
            rec = bytes([len(chunk), (a >> 8) & 0xFF, a & 0xFF, 0]) + chunk
            f.write(':%s%02X\n' % (rec.hex().upper(), (-sum(rec)) & 0xFF))
        f.write(':00000001FF\n')


def pad_sector(data):
    return data + b'\xFF' * (-len(data) % SECTOR)


def info_sector(m, board, label):
    key, folder, rev, mbyte, core, (name, what), romhex, flags = m[:8]
    line = ('%-12s %s' % (name, what)).encode('ascii')
    assert len(line) <= NAME_LEN, line
    s = bytes([0xA5, 0x5A, mbyte, mbyte ^ 0xFF]) + struct.pack('>I', core) + bytes([board, flags, 0, 0])
    s = s.ljust(0x10, b'\0') + line.ljust(NAME_LEN, b' ') + b'\0\0\0'
    s += label.encode('ascii', 'replace')[:31].ljust(32, b'\0')
    return s.ljust(SECTOR, b'\xFF')


def cof_text(loader, out, pages, hexes):
    """pages: (address, sof); hexes: (address, file)"""
    t = ['<?xml version="1.0" encoding="US-ASCII" standalone="yes"?>', '<cof>', '\t<eprom_name>EPCS64</eprom_name>']
    if loader:
        t.append('\t<flash_loader_device>%s</flash_loader_device>' % loader)
    t += ['\t<output_filename>%s</output_filename>' % out, '\t<n_pages>%d</n_pages>' % len(pages), '\t<width>1</width>',
          '\t<mode>7</mode>']
    for addr, name in hexes:
        t += ['\t<hex_block>', '\t\t<hex_filename>%s</hex_filename>' % name,
              '\t\t<hex_addressing>relative</hex_addressing>', '\t\t<hex_offset>%d</hex_offset>' % addr, '\t</hex_block>']
    for i, (addr, sof) in enumerate(pages):
        t.append('\t<sof_data>')
        if i:
            t.append('\t\t<start_address>%08X</start_address>' % addr)
        t += ['\t\t<user_name>Page_%d</user_name>' % i, '\t\t<page_flags>%d</page_flags>' % (1 if i == 0 else 0),
              '\t\t<bit0>', '\t\t\t<sof_filename>%s</sof_filename>' % sof, '\t\t</bit0>', '\t</sof_data>']
    t += ['\t<version>10</version>', '\t<create_cvp_file>0</create_cvp_file>', '\t<create_hps_iocsr>0</create_hps_iocsr>',
          '\t<auto_create_rpd>0</auto_create_rpd>', '\t<rpd_little_endian>1</rpd_little_endian>', '\t<options>',
          '\t\t<map_file>1</map_file>', '\t</options>', '</cof>', '']
    return '\n'.join(t)


def rpd_of(cof_body, name):
    """a .cof without flash loader -> .pof -> .rpd -> the flash contents as SPI reads them (8 MB, FF padded)"""
    tmp = name + '.cof'
    open(tmp, 'w', newline='\n').write(cof_body)
    try:
        cpf('-c', tmp)
        cpf('-c', 'output_files/%s.pof' % name, 'output_files/%s.rpd' % name)
        img = open('output_files/%s.rpd' % name, 'rb').read().translate(REV)
    finally:
        os.remove(tmp)
        for ext in ('pof', 'rpd', 'map'):
            f = 'output_files/%s.%s' % (name, ext)
            if os.path.exists(f):
                os.remove(f)
    return img.ljust(FLASH, b'\xFF')[:FLASH]


def trimmed(img):
    """a bitstream slice without its trailing FF, in whole sectors"""
    end = len(img)
    while end > 0 and img[end - 1] == 0xFF:
        end -= 1
    return pad_sector(img[:end])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--label', default=datetime.date.today().isoformat())
    a = ap.parse_args()
    bdir = os.path.basename(os.getcwd())
    if bdir not in BOARDS or not os.path.exists('AMenu.qpf'):
        sys.exit('run in AMenu/ep4_ce15 or AMenu/10cl025')
    board, loader, bname = BOARDS[bdir]
    root = '../..'
    machines = [m for m in MACHINES if len(m) < 9 or bdir in m[8]]
    sof = {m[0]: '%s/%s/%s/output_files/%s.sof' % (root, m[1], bdir, m[2]) for m in machines}
    menu_sof = 'output_files/AMenu.sof'
    for f in list(sof.values()) + [menu_sof]:
        if not os.path.exists(f):
            sys.exit('missing ' + f)
    os.makedirs('output_files/machines', exist_ok=True)

    # every bitstream once: the menu at 0, the machines 1 MB apart (a scratch layout, only to cut them out)
    scratch = rpd_of(cof_text(None, 'output_files/L_scratch.pof',
                              [(0, menu_sof)] + [((i + 1) * MB, sof[m[0]]) for i, m in enumerate(machines)], []),
                     'L_scratch')
    menu = trimmed(scratch[:MB])
    image = {m[0]: trimmed(scratch[(i + 1) * MB:(i + 2) * MB]) for i, m in enumerate(machines)}
    for k, img in [('menu', menu)] + list(image.items()):
        if img[0x20] != 0x56:                    # the sync byte 6A as SPI reads it
            sys.exit('%s: no configuration image' % k)

    # info sectors, ROM data, machine files
    info, rom = {}, {}
    for m in machines:
        key = m[0]
        info[key] = info_sector(m, board, a.label)
        rom[key] = pad_sector(read_hex(os.path.join(root, m[6]))) if m[6] else b''
        assert len(rom[key]) <= ROM_MAX and len(image[key]) <= MB
        hdr = b'LMACHIN1' + struct.pack('<IIIIIII', board, len(image[key]), zlib.crc32(image[key]), len(rom[key]),
                                         zlib.crc32(rom[key]), zlib.crc32(info[key]), m[7])
        hdr = hdr.ljust(252, b'\0')
        hdr += struct.pack('<I', zlib.crc32(hdr))
        out = 'output_files/machines/%s_%s.LMC' % (key, bname)
        with open(out, 'wb') as f:
            f.write(hdr + info[key] + rom[key] + image[key])
        print('%s: image %d KB, ROMs %d KB' % (out, len(image[key]) // 1024, len(rom[key]) // 1024))

    # the whole flash as SPI reads it
    flash = bytearray(b'\xFF' * FLASH)
    flash[0:len(menu)] = menu
    pages, hexes = [(0, menu_sof)], []
    for p, key in enumerate(INSTALLED):
        flash[POS_IMAGE[p]:POS_IMAGE[p] + len(image[key])] = image[key]
        area = info[key] + rom[key]
        flash[POS_ROM[p]:POS_ROM[p] + len(area)] = area
        pages.append((POS_IMAGE[p], sof[key]))
        hx = 'output_files/L_pos%d_rom.hex' % (p + 1)
        write_hex(hx, area)                      # a .hex block's bytes come back over SPI as they are in the file
        hexes.append((POS_ROM[p], hx))
    open('output_files/L_flash.bin', 'wb').write(flash)

    # L.cof -> L.jic; the same without the flash loader must give the composed image
    open('L.cof', 'w', newline='\n').write(cof_text(loader, 'output_files/L.jic', pages, hexes))
    cpf('-c', 'L.cof')
    check = rpd_of(cof_text(None, 'output_files/L_check.pof', pages, hexes), 'L_check')
    if check != bytes(flash):
        bad = next(i for i in range(FLASH) if check[i] != flash[i])
        sys.exit('L.jic data differs from the composed flash image at 0x%06X' % bad)
    print(open('output_files/L.map').read().split('Configuration device')[0].strip())
    print('output_files/L.jic: menu + %s; checked against output_files/L_flash.bin' % ', '.join(INSTALLED))


main()
