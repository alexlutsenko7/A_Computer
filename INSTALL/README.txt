L - installing the machines

The board's flash holds the machine menu and three machines at a time. You choose which three.

1. Format a microSD card as FAT32 or FAT16 (not exFAT).
2. Copy the folder MACHINES to the root folder of the card. It holds one file per machine and core board:
   ..._ep4ce15.LMC for the Cyclone IV EP4CE15 board, ..._10cl025.LMC for the Cyclone 10 LP 10CL025 board.
   The menu lists only the files made for its own board.
3. Put the card into the board and switch it on. In the machine menu press F12, choose a machine and then
   the position (1 to 3) it goes into. Wait for "Installed." (about 15 seconds). Repeat for the other positions.

Machines: LSpectrum (ZX Spectrum 128K), L64 (Commodore 64), LTari 800 / LTari 130 (Atari 800XL / 130XE),
LNES (Nintendo Entertainment System), LMega (Sega Mega Drive / Genesis; 10CL025 board only).
LNES and LMega are new and were tested in simulation only when this file was written.

ESP32_UPDATE/<v1 or v2>/LESP32.BIN updates the ESP32's firmware (v1 = I/O board revision 1, v2 = revision 2):
copy the file of your I/O board to the root folder of the card and switch the board on. LNES and LMega need this
firmware; do this before installing them.

MENU_UPDATE/<board>/LUPDATE.BIN updates the machine menu itself: copy the file of YOUR board to the root
folder of the card and switch the board on. A menu file for the other board leaves the board unable to start
(a USB-Blaster is then needed), so take care. It is only needed when a new version of the menu is published.

Step by step and in your language: <language>/L_Installation_Guide_<language>.pdf.
Keys, menus, joysticks: <language>/L_User_Manual_<language>.pdf.
(The guides were written before the machine files and the two consoles; where they differ, this file is right.)
Languages: EN English, SP Espanol, PT Portugues, DE Deutsch, UA Ukrainska, RU Russkiy, CN Zhongwen, KR Hangugeo,
JP Nihongo.

Not included: games and other programs, and the Commodore 64 ROMs (copyrighted). Get them yourself; see section 4
of the installation guide.
