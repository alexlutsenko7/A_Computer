#!/usr/bin/env python3
"""diagram.py FONT_HEX OUT.png -- LSpectrum block diagram, pure Python (zlib PNG),
labels in the Spectrum ROM font (rtl/osd_font.hex)."""
import struct
import sys
import zlib

W, H = 1800, 1120
img = bytearray(b"\xff" * (W * H * 3))
font = [int(l, 16) for l in open(sys.argv[1])]

def px(x, y, c):
    if 0 <= x < W and 0 <= y < H:
        o = (y * W + x) * 3
        img[o:o + 3] = bytes(c)

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

def box(x, y, w, h, lines, fill, title_sc=2):
    rect(x, y, w, h, fill)
    frame(x, y, w, h, EDGE[fill])
    ty = y + (h - len(lines) * 22) // 2 + 3
    for i, l in enumerate(lines):
        sc = 2
        text(x + (w - text_w(l, sc)) // 2, ty + i * 22, l, DARK, sc)
    return (x, y, w, h)

def hline(x0, x1, y, c=DARK, t=3):
    if x1 < x0: x0, x1 = x1, x0
    rect(x0, y - t // 2, x1 - x0 + 1, t, c)

def vline(x, y0, y1, c=DARK, t=3):
    if y1 < y0: y0, y1 = y1, y0
    rect(x - t // 2, y0, t, y1 - y0 + 1, c)

def head(x, y, d, c=DARK):            # arrow head pointing d: 'r','l','u','d'
    for i in range(12):
        for j in range(-i // 2, i // 2 + 1):
            if d == 'r': px(x - i, y + j, c)
            if d == 'l': px(x + i, y + j, c)
            if d == 'd': px(x + j, y - i, c)
            if d == 'u': px(x + j, y + i, c)

def arrow_h(x0, x1, y, both=False, label=None, ly=None):
    hline(x0, x1, y)
    head(x1, y, 'r' if x1 > x0 else 'l')
    if both: head(x0, y, 'l' if x1 > x0 else 'r')
    if label:
        text(min(x0, x1) + 8, (ly if ly is not None else y - 22), label, (90, 90, 90), 1 if len(label) * 16 > abs(x1 - x0) - 16 else 2)

def arrow_v(x, y0, y1, both=False):
    vline(x, y0, y1)
    head(x, y1, 'd' if y1 > y0 else 'u')
    if both: head(x, y0, 'u' if y1 > y0 else 'd')

# ---- title + legend -------------------------------------------------------
text(40, 24, "LSpectrum - ZX Spectrum 128K on EP4CE15", DARK, 3)
lx = 1040
for i, (c, l) in enumerate([(BLUE, "112 MHz system"), (GREEN, "56 MHz tape loader"), (ORANGE, "25.2/27 MHz pixel"), (GREY, "outside the FPGA")]):
    rect(lx + (i % 2) * 380, 20 + (i // 2) * 30, 26, 22, c); frame(lx + (i % 2) * 380, 20 + (i // 2) * 30, 26, 22, EDGE[c], 2)
    text(lx + 36 + (i % 2) * 380, 23 + (i // 2) * 30, l, DARK, 2)

# ---- external parts (left / right) ----------------------------------------
osc   = box(30,   110, 250, 70, ["50 MHz OSC"], GREY)
flash = box(30,   250, 250, 90, ["CONFIG FLASH", "W25Q64 (ROMs)"], GREY)
kbd   = box(30,   440, 250, 90, ["USB KEYBOARD", "UART 115200"], GREY)
joy   = box(30,   590, 250, 70, ["2 JOYSTICKS"], GREY)
esp   = box(30,   860, 250, 170, ["ESP32", "SD CARD", "LOADER FW", "BLUETOOTH"], GREY)

sdram = box(1540, 250, 230, 90, ["SDRAM 32 MB", "W9825G6KH"], GREY)
vga   = box(1540, 500, 230, 90, ["VGA MONITOR", "576p / 480p"], GREY)
amp   = box(1540, 760, 230, 90, ["AUDIO JACK", "AY + BEEPER"], GREY)

# ---- FPGA ------------------------------------------------------------------
frame(320, 95, 1190, 1000, (150, 150, 150), 2)
text(1100, 1068, "FPGA EP4CE15F23C8", (120, 120, 120), 2)

pll   = box(350,  110, 330, 70, ["PLLs 112/56 + 25/27"], BLUE)
ldr   = box(350,  250, 330, 90, ["rom_loader", "flash -> SDRAM"], BLUE)
kb    = box(350,  440, 330, 90, ["zx_keyboard", "matrix, F1 F8 F12.."], BLUE)
tl    = box(350,  860, 330, 170, ["tape_loader", "esp_link (SPI)", "FIFO, player,", "recorder, UART"], GREEN)

cpu   = box(760,  110, 330, 90, ["T80 CPU", "clock enable 3.5/28"], BLUE)
bus   = box(760,  250, 330, 410, ["zx_bus", "", "CEN generator", "bus bridge", "paging 7FFD", "ports FE 1F FFFD", "interrupt", "EAR / tape"], BLUE)
ay    = box(760,  740, 330, 90, ["AY-3-8912 (JT49)", "DAC + bt_i2s"], BLUE)

ram   = box(1170, 250, 310, 90, ["sdram_ram", "controller 112 MHz"], BLUE)
vid   = box(1170, 470, 310, 150, ["zx_video", "screen shadows", "VGA timing", "OSD overlay"], ORANGE)

# ---- connections -----------------------------------------------------------
arrow_h(280, 350, 145)                                   # osc -> plls
arrow_h(280, 350, 295, both=True)                        # flash <-> rom_loader
arrow_h(280, 350, 485)                                   # keyboard -> zx_keyboard
arrow_h(280, 760, 625)                                   # joystick -> bus
arrow_h(280, 350, 945, both=True)                        # ESP32 <-> tape loader (SPI link)
arrow_v(925, 200, 250, both=True)                        # cpu <-> bus
hline(680, 720, 295); vline(720, 295, 210); hline(720, 1130, 210); vline(1130, 210, 285)  # rom_loader -> ram (over the bus)
head(1130, 285, 'd')
arrow_h(1130, 1170, 285)
arrow_h(1090, 1170, 310, both=True)                      # bus <-> sdram_ram
arrow_h(1480, 1540, 295, both=True)                      # sdram_ram <-> chip
arrow_h(680, 760, 470)                                   # keyboard rows -> bus
arrow_h(1090, 1170, 530)                                 # bus -> video (shadow writes)
arrow_h(1480, 1540, 545)                                 # video -> vga
arrow_v(925, 660, 740, both=True)                        # bus <-> ay
hline(1090, 1520, 805); head(1540, 805, 'r'); hline(1520, 1540, 805)   # ay -> amp
hline(680, 720, 900); vline(720, 900, 600); arrow_h(720, 760, 600); head(680, 900, 'l')   # tape loader <-> bus (EAR, turbo / MIC, hold)
hline(680, 1325, 1000); arrow_v(1325, 1000, 620)                       # tape loader -> OSD
vline(560, 530, 860); head(560, 860, 'd')                               # keyboard -> tape loader keys
vline(1525, 805, 1105); hline(100, 1525, 1105); vline(100, 1030, 1105); head(100, 1030, 'u')  # sound as I2S -> ESP32
vline(640, 1030, 1052); hline(200, 640, 1052); vline(200, 1030, 1052); head(200, 1030, 'u'); head(640, 1030, 'u')  # tape loader <-> ESP32 UART (F3 menu)

# small labels
LBL = (70, 70, 70)
text(732, 868, "EAR, turbo,", LBL, 2)
text(732, 888, "MIC, hold", LBL, 2)
text(1340, 945, "OSD text", LBL, 2)
text(572, 640, "keys", LBL, 2)
text(1000, 220, "ROMs", LBL, 2)
text(1452, 1112 - 30, "I2S", LBL, 2)
text(286, 912, "SPI", LBL, 2)
text(420, 1036, "UART", LBL, 2)

# ---- PNG -------------------------------------------------------------------
raw = b"".join(b"\x00" + bytes(img[y * W * 3:(y + 1) * W * 3]) for y in range(H))
def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
open(sys.argv[2], "wb").write(png)
print("written", sys.argv[2], len(png))
