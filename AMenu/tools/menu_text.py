#!/usr/bin/env python3
"""menu_text.py -- writes rtl/menu_text.hex, the 32 x 24 text screen of the machine menu.

Machine i is on row ENTRY_ROW + 2 * i (menu_video highlights it); ERR_ROW is shown only
after a machine could not start. Keep MACHINES in the order of AMenu's MACHINE_ADDR.
Run from AMenu/: python3 tools/menu_text.py
"""
import os

COLS, ROWS = 32, 24
ENTRY_ROW, ERR_ROW = 6, 18
MACHINES = [("LSpectrum", "ZX Spectrum 128K"),
            ("L64", "Commodore 64"),
            ("LTari 800", "Atari 800XL"),
            ("LTari 130", "Atari 130XE")]

screen = [[" "] * COLS for _ in range(ROWS)]

def put(row, text, col=0):
    assert col + len(text) <= COLS, text
    for i, c in enumerate(text):
        screen[row][col + i] = c

def centre(row, text):
    put(row, text, (COLS - len(text)) // 2)

centre(2, "Choose a machine")
for i, (name, what) in enumerate(MACHINES):
    put(ENTRY_ROW + 2 * i, f" {i + 1} {name:<12} {what}")
put(ERR_ROW, " Could not start, reason:    ")   # menu_video puts the code at columns 25-26
put(ERR_ROW + 1, " Chip tried address:       ")   # and the address at columns 21-26
put(ERR_ROW + 2, " Mode:    reason before:      ")  # mode at column 7, earlier reason at 25-26
centre(21, f"Up/Down + Enter, 1-{len(MACHINES)}, joystick")
centre(22, "KEY1 in a machine: back here")

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "rtl", "menu_text.hex")
with open(out, "w", newline="\n") as f:
    for row in screen:
        for c in row:
            f.write(f"{ord(c):02X}\n")
print("wrote", out)
for r in screen:
    print("|" + "".join(r) + "|")
