#!/usr/bin/env python3
"""menu_text.py -- writes rtl/menu_text.hex (EP4CE15 board) and rtl/menu_text_10cl025.hex (10CL025 board, with the
F4 line), the 32 x 24 text screen of the machine menu.

Position i is on row ENTRY_ROW + 2 * i (menu_video highlights it); only its number is in this text:
the machine's name comes from the flash (menu_names). ERR_ROW is shown only after a machine could not
start.
Run from AMenu/ep4_ce15/: python3 tools/menu_text.py
"""
import os

COLS, ROWS = 32, 24
ENTRY_ROW, ERR_ROW = 6, 14
POSITIONS = 3
RTL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "rtl")


def make(name, keys):
    """One text screen into rtl/<name>; keys = the lines about the function keys, from row 21 on."""
    screen = [[" "] * COLS for _ in range(ROWS)]

    def put(row, text, col=0):
        assert col + len(text) <= COLS, text
        for i, c in enumerate(text):
            screen[row][col + i] = c

    def centre(row, text):
        put(row, text, (COLS - len(text)) // 2)

    centre(2, "Choose a machine")
    for i in range(POSITIONS):
        put(ENTRY_ROW + 2 * i, f" {i + 1}")
    put(ERR_ROW, " Could not start, reason:    ")   # menu_video puts the code at columns 25-26
    put(ERR_ROW + 1, " Chip tried address:       ")   # and the address at columns 21-26
    put(ERR_ROW + 2, " Mode:    reason before:      ")  # mode at column 7, earlier reason at 25-26
    centre(19, f"Up/Down + Enter, 1-{POSITIONS}, joystick")
    centre(20, "KEY1 in a machine: back here")
    for i, text in enumerate(keys):
        centre(21 + i, text)

    out = os.path.join(RTL, name)
    with open(out, "w", newline="\n") as f:
        for row in screen:
            for c in row:
                f.write(f"{ord(c):02X}\n")
    print("wrote", out)
    for r in screen:
        print("|" + "".join(r) + "|")


# EP4CE15 board (I/O board revision 1, firmware ESP32/v1: no Wi-Fi)
make("menu_text.hex", ["F3: Bluetooth audio", "F12: install from the SD card"])
# 10CL025 board (I/O board revision 2, firmware ESP32/v2): F4 = the SD card over Wi-Fi (FTP server)
make("menu_text_10cl025.hex", ["F3: Bluetooth audio", "F4: SD card over Wi-Fi (FTP)", "F12: install from the SD card"])
