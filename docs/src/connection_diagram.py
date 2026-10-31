#!/usr/bin/env python3
"""connection_diagram.py FONT_HEX OUT.png -- LSpectrum wiring overview, pure Python (zlib PNG),
labels in the Spectrum ROM font (rtl/osd_font.hex). Same drawing style as architecture_diagram.py."""
import struct
import sys
import zlib

W, H = 1800, 980
img = bytearray(b"\xff" * (W * H * 3))
font = [int(l, 16) for l in open(sys.argv[1])]


def rect(x, y, w, h, c):
    for yy in range(y, y + h):
        o = (yy * W + x) * 3
        img[o:o + 3 * w] = bytes(c) * w


def frame(x, y, w, h, c, t=3):
    rect(x, y, w, t, c); rect(x, y + h - t, w, t, c)
    rect(x, y, t, h, c); rect(x + w - t, y, t, h, c)


def text(x, y, s, c=(0, 0, 0), sc=2):
    for i, ch in enumerate(s):
        code = ord(ch) if 32 <= ord(ch) < 128 else 63
        for r in range(8):
            row = font[code * 8 + r]
            for b in range(8):
                if row & (0x80 >> b):
                    rect(x + (i * 8 + b) * sc, y + r * sc, sc, sc, c)


def text_w(s, sc=2):
    return len(s) * 8 * sc


BLUE, GREEN, ORANGE, GREY, DARK = (214, 228, 248), (214, 240, 214), (252, 228, 200), (232, 232, 232), (40, 40, 40)
EDGE = {BLUE: (46, 84, 150), GREEN: (56, 128, 56), ORANGE: (190, 110, 30), GREY: (110, 110, 110)}
LBL = (70, 70, 70)


def box(x, y, w, h, lines, fill):
    rect(x, y, w, h, fill)
    frame(x, y, w, h, EDGE[fill])
    ty = y + (h - len(lines) * 22) // 2 + 3
    for i, l in enumerate(lines):
        text(x + (w - text_w(l)) // 2, ty + i * 22, l, DARK, 2)


def hline(x0, x1, y, t=5):
    if x1 < x0: x0, x1 = x1, x0
    rect(x0, y - t // 2, x1 - x0 + 1, t, DARK)


def vline(x, y0, y1, t=5):
    if y1 < y0: y0, y1 = y1, y0
    rect(x - t // 2, y0, t, y1 - y0 + 1, DARK)


WHITE = (250, 250, 250)
EDGE[WHITE] = (56, 128, 56)

text(40, 24, "LSpectrum - connections", DARK, 3)
for i, (c, l) in enumerate([(BLUE, "FPGA core board"), (GREEN, "I/O board"), (ORANGE, "ESP32 controller"), (GREY, "devices")]):
    rect(1000 + (i % 2) * 380, 20 + (i // 2) * 30, 26, 22, c); frame(1000 + (i % 2) * 380, 20 + (i // 2) * 30, 26, 22, EDGE[c], 2)
    text(1036 + (i % 2) * 380, 23 + (i // 2) * 30, l, DARK, 2)

# core board with U8 on its right edge (U7 not used)
box(60, 120, 560, 740, [], BLUE)
for i, l in enumerate(["QMTECH CYCLONE IV", "EP4CE15 + SDRAM", "", "KEY0 = RESET", "LED = TURBO"]):
    text(60 + (480 - text_w(l)) // 2, 420 + i * 26, l, DARK, 2)
box(520, 140, 80, 700, [], GREY)
for i, ch in enumerate("U8"): text(552, 466 + i * 24, ch, DARK, 2)

# the wire link, each pin pair swapped
for y in range(180, 820, 40): hline(600, 800, y, 3)
rect(612, 430, 176, 110, BLUE)
for i, l in enumerate(["64 WIRES", "J1.1-U8.2", "J1.2-U8.1"]):
    text(700 - text_w(l) // 2, 440 + i * 34, l, DARK, 2)

# I/O board with J1 on its left edge
box(800, 120, 960, 740, [], GREEN)
box(820, 140, 80, 700, [], WHITE)
for i, ch in enumerate("J1"): text(852, 466 + i * 24, ch, DARK, 2)
text(1310, 820, "EXTRA_PCB_CYCLONEIV", DARK, 2)
box(940, 160, 320, 420, ["ESP32-WROOM-32", "SYSTEM CONTROLLER", "(SOCKETS U2)", "", "LINK, I2S, UART", "TO J1", "", "SD CARD ON VSPI"], ORANGE)
right = [["MICROSD J7"], ["VGA J2, 4-BIT DAC"], ["2 X DB9 JOY J4 J6"], ["AUDIO JACK J3"], ["KEYBOARD MODULE J5"], ["K7803 3.3V U1"]]
for i, l in enumerate(right):
    box(1310, 160 + i * 105, 420, 80, l, WHITE)
hline(1260, 1310, 200)                                   # ESP32 -> microSD

# devices
box(960, 880, 280, 80, ["BT HEADPHONES"], GREY)
for y in range(580, 880, 16): rect(1098, y, 5, 8, DARK)  # radio link, dashed
box(60, 880, 560, 80, ["5 V POWER: USB OR VIN"], GREY)

raw = b"".join(b"\x00" + bytes(img[y * W * 3:(y + 1) * W * 3]) for y in range(H))
def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
open(sys.argv[2], "wb").write(png)
print("written", sys.argv[2], len(png))
