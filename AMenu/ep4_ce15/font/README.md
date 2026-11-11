# Menu font

`spleen-8x16.bdf`: **Spleen 8x16** 2.1.0 by Frederic Cambus (https://github.com/fcambus/spleen, tag 2.1.0),
BSD 2-Clause licence (`LICENSE`, kept with the font as the licence requires). Used for every on-screen text: the machine
menu's screens (menu, flash update, "No machines installed") and the machines' OSD (LSpectrum `zx_video.v`, L64 / LTari
`c64_video.v`): `../tools/mk_menufont.py` turns the ASCII range into `../rtl/menu_font.hex` (128 characters x 16 rows,
one byte per row, leftmost pixel = bit 7). The Spectrum ROM font `LSpectrum/ep4_ce15/rtl/osd_font.hex` is now only used for the
labels of the documentation diagrams.
