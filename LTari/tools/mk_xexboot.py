#!/usr/bin/env python3
"""mk_xexboot.py OUT.h [OUT.mem] -- LTari .xex boot loader (our own 6502 code).

The ESP32 (LSpectrum/esp32_v2/src/atari.cpp) serves an .xex as a read-only disk: sectors 1-3 = this
loader, sectors 4.. = the .xex file, 128 bytes per sector. The OS boots the loader to $0700 and
calls $0706; the loader then:
  - switches BASIC off (PORTB bit 1, BASICF) so $A000-$BFFF is RAM,
  - reads the file sector by sector through SIOV (D1:, command $52) into a buffer at $0880,
  - copies each segment (start, end, data; $FFFF headers skipped) into memory,
  - after a segment that set INITAD ($02E2) calls it,
  - at the end jumps through RUNAD ($02E0), or to the first segment's start if RUNAD was never set.
The file length (3 bytes, little endian) is patched in by the ESP32 at LEN_OFS.
Limits: the loader and its buffer use $0700-$08FF, so a program loading there does not work.

OUT.h: a C array (atari_xexboot[384], LEN_OFS); OUT.mem: hex bytes for the testbench.
"""
import sys

ORG = 0x0700
# OS addresses (Altirra Hardware Reference Manual / the OS's documented vectors)
SYM = dict(DDEVIC=0x0300, DUNIT=0x0301, DCOMND=0x0302, DSTATS=0x0303, DBUFLO=0x0304, DBUFHI=0x0305,
           DTIMLO=0x0306, DBYTLO=0x0308, DBYTHI=0x0309, DAUX1=0x030A, DAUX2=0x030B, SIOV=0xE459,
           RUNAD=0x02E0, INITAD=0x02E2, PORTB=0xD301, BASICF=0x03F8, PTR=0x00CB, BUF=0x0880)

SRC = """
        .byte $00, $03                  ; boot flags, 3 sectors
        .word $0700, done_init          ; load address, DOSINI
start:  lda #0
        sta RUNAD
        sta RUNAD+1
        sta first+1
        lda PORTB                       ; BASIC off
        ora #$02
        sta PORTB
        lda #1
        sta BASICF
        lda #4                          ; the file starts at sector 4
        sta sec
        lda #0
        sta sec+1
        lda #128
        sta bpos
seg:    jsr getb                        ; segment header: start (or $FFFF), end
        bcs fin
        sta PTR
        jsr getb
        bcs fin
        sta PTR+1
        and PTR
        cmp #$FF
        beq seg
        lda first+1                     ; the first segment's start, if RUNAD stays 0
        bne seg1
        lda PTR
        sta first
        lda PTR+1
        sta first+1
seg1:   lda #0
        sta INITAD
        sta INITAD+1
        jsr getb
        bcs fin
        sta eaddr
        jsr getb
        bcs fin
        sta eaddr+1
copy:   jsr getb
        bcs fin
        ldy #0
        sta (PTR),y
        lda PTR                         ; PTR >= end: segment done
        cmp eaddr
        lda PTR+1
        sbc eaddr+1
        bcs segend
        inc PTR
        bne copy
        inc PTR+1
        jmp copy
segend: lda INITAD
        ora INITAD+1
        beq seg
        jsr doinit
        jmp seg
doinit: jmp (INITAD)
fin:    lda RUNAD
        ora RUNAD+1
        bne run
        lda first
        sta RUNAD
        lda first+1
        sta RUNAD+1
run:    jmp (RUNAD)
done_init: rts

; next file byte in A, carry clear; carry set at the end of the file
getb:   lda len
        ora len+1
        ora len+2
        bne getb1
        sec
        rts
getb1:  lda len                         ; len - 1
        bne getb2
        lda len+1
        bne getb3
        dec len+2
getb3:  dec len+1
getb2:  dec len
        ldx bpos
        cpx #128
        bne getb4
        jsr rdsec
        ldx #0
getb4:  lda BUF,x
        inx
        stx bpos
        clc
        rts

; read sector sec into BUF (retries until it works), sec + 1
rdsec:  lda #$31
        sta DDEVIC
        lda #1
        sta DUNIT
        lda #$52
        sta DCOMND
        lda #$40
        sta DSTATS
        lda #<BUF
        sta DBUFLO
        lda #>BUF
        sta DBUFHI
        lda #7
        sta DTIMLO
        lda #128
        sta DBYTLO
        lda #0
        sta DBYTHI
        lda sec
        sta DAUX1
        lda sec+1
        sta DAUX2
        jsr SIOV
        bmi rdsec
        inc sec
        bne rdsec1
        inc sec+1
rdsec1: rts

len:    .byte 0, 0, 0                   ; file length, patched by the ESP32
sec:    .byte 0, 0
bpos:   .byte 0
eaddr:  .byte 0, 0
first:  .byte 0, 0
"""

# opcode table: (mnemonic, mode) -> code
OPS = {}
def op(code, mn, mode): OPS[(mn, mode)] = code
for c, mn, m in [
    (0x69,'adc','imm'),(0x6D,'adc','abs'),(0x29,'and','imm'),(0x25,'and','zp'),(0x2D,'and','abs'),
    (0x90,'bcc','rel'),(0xB0,'bcs','rel'),(0xF0,'beq','rel'),(0x30,'bmi','rel'),(0xD0,'bne','rel'),(0x10,'bpl','rel'),
    (0x18,'clc','imp'),(0x38,'sec','imp'),(0xC9,'cmp','imm'),(0xC5,'cmp','zp'),(0xCD,'cmp','abs'),
    (0xE0,'cpx','imm'),(0xCE,'dec','abs'),(0xEE,'inc','abs'),(0xE6,'inc','zp'),(0xE8,'inx','imp'),
    (0x4C,'jmp','abs'),(0x6C,'jmp','ind'),(0x20,'jsr','abs'),
    (0xA9,'lda','imm'),(0xA5,'lda','zp'),(0xAD,'lda','abs'),(0xBD,'lda','absx'),(0xA2,'ldx','imm'),
    (0xAE,'ldx','abs'),(0xA0,'ldy','imm'),(0x09,'ora','imm'),(0x05,'ora','zp'),(0x0D,'ora','abs'),
    (0x60,'rts','imp'),(0xE5,'sbc','zp'),(0xED,'sbc','abs'),(0x85,'sta','zp'),(0x8D,'sta','abs'),
    (0x91,'sta','izy'),(0x8E,'stx','abs')]:
    op(c, mn, m)
SIZE = dict(imp=1, imm=2, zp=2, rel=2, izy=2, abs=3, absx=3, ind=3)

def value(expr, labels, final):
    e = expr.strip()
    lo = hi = False
    if e.startswith('<'): lo, e = True, e[1:]
    elif e.startswith('>'): hi, e = True, e[1:]
    add = 0
    if '+' in e:
        e, a = e.split('+'); add = int(a, 0)
    e = e.strip()
    if e.startswith('$'): v = int(e[1:], 16)
    elif e[0].isdigit(): v = int(e)
    elif e in SYM: v = SYM[e]
    elif e in labels: v = labels[e]
    elif final: sys.exit('unknown symbol ' + e)
    else: v = 0x0700
    v += add
    return (v & 0xFF) if lo else (v >> 8) if hi else v

def assemble():
    labels = {}
    for final in (False, True):
        pc, out = ORG, bytearray()
        for raw in SRC.splitlines():
            line = raw.split(';')[0].rstrip()
            if not line.strip(): continue
            if ':' in line:
                lab, line = line.split(':', 1)
                labels[lab.strip()] = pc
            line = line.strip()
            if not line: continue
            parts = line.split(None, 1)
            mn, arg = parts[0].lower(), (parts[1].strip() if len(parts) > 1 else '')
            if mn == '.byte':
                b = [value(x, labels, final) for x in arg.split(',')]
                out += bytes(b); pc += len(b); continue
            if mn == '.word':
                for x in arg.split(','):
                    v = value(x, labels, final); out += bytes([v & 0xFF, v >> 8]); pc += 2
                continue
            if not arg: mode = 'imp'
            elif arg.startswith('#'): mode = 'imm'; arg = arg[1:]
            elif arg.startswith('(') and arg.lower().endswith('),y'): mode = 'izy'; arg = arg[1:-3]
            elif arg.startswith('('): mode = 'ind'; arg = arg[1:-1]
            elif arg.lower().endswith(',x'): mode = 'absx'; arg = arg[:-2]
            elif mn in ('bcc','bcs','beq','bmi','bne','bpl'): mode = 'rel'
            else:
                v = value(arg, labels, final)
                mode = 'zp' if v < 0x100 and (mn, 'zp') in OPS and arg in SYM else 'abs'
            if (mn, mode) not in OPS: sys.exit('no opcode %s %s' % (mn, mode))
            v = value(arg, labels, final) if arg else 0
            if mode == 'rel':
                d = v - (pc + 2)
                if final and not -128 <= d <= 127: sys.exit('branch out of range: ' + raw)
                bts = [OPS[(mn, mode)], d & 0xFF]
            elif SIZE[mode] == 2: bts = [OPS[(mn, mode)], v & 0xFF]
            elif SIZE[mode] == 3: bts = [OPS[(mn, mode)], v & 0xFF, v >> 8]
            else: bts = [OPS[(mn, mode)]]
            out += bytes(bts); pc += len(bts)
    if len(out) > 384: sys.exit('loader too long: %d bytes' % len(out))
    return bytes(out) + bytes(384 - len(out)), labels['len'] - ORG

def main():
    if len(sys.argv) not in (2, 3): sys.exit(__doc__)
    img, lofs = assemble()
    with open(sys.argv[1], 'w') as f:
        f.write('/* atari_xexboot.h -- generated by LTari/tools/mk_xexboot.py: the .xex boot loader\n'
                ' * (sectors 1-3 of the virtual disk); the file length goes at XEXBOOT_LEN_OFS (3 bytes) */\n')
        f.write('#define XEXBOOT_LEN_OFS %d\n' % lofs)
        f.write('static const uint8_t atari_xexboot[384] = {\n')
        for i in range(0, 384, 16):
            f.write('    ' + ', '.join('0x%02X' % b for b in img[i:i + 16]) + ',\n')
        f.write('};\n')
    if len(sys.argv) == 3:
        with open(sys.argv[2], 'w') as f:
            f.write(''.join('%02x\n' % b for b in img))
    print('loader %d bytes used, length at offset %d' % (len(img.rstrip(b"\0")), lofs))

main()
