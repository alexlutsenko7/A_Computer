/* lang_en.js -- the user manual's text, English (the reference). */
/* Keep the block structure the same in every lang_*.js; on-screen messages stay as the board shows them. */
/* Blocks: ['h1' | 'h2' | 'p' | 'note', text], ['ul' | 'ol', items], ['screen', lines], */
/* ['table', header, rows, column widths in percent] */
module.exports = {
  title: "L — User Manual",
  subtitle: "One board, your choice of classic machines: ZX Spectrum 128K, Commodore 64, Atari 800XL / 130XE, Nintendo Entertainment System and Sega Mega Drive. How to connect it, choose the machines and play. Edition of 17 November 2026.",
  page: "page",
  blocks: [
    /* ------------------------------------------------------------ 1 */
    ["h1", "1. What L is"],
    ["p", "L is a small board set that becomes one of several classic home computers and game consoles. When you switch it on it shows the **machine menu**. You choose a machine, and a moment later the board is that machine: a ZX Spectrum, a Commodore 64, an Atari, a Nintendo console or a Sega console. It is not an emulator program on a PC; the chips of the old machine are rebuilt inside the board."],
    ["p", "Games and programs come from a microSD card. A file list on the screen replaces the tape recorder, the disk drive and the cartridge slot. The picture goes to a VGA monitor, the sound to the audio socket or to Bluetooth headphones."],
    ["table", ["Machine", "What it is", "Files it uses"], [
      ["**LSpectrum**", "ZX Spectrum 128K (also runs 48K programs)", ".tap .tzx (tapes), .z80 (snapshots)"],
      ["**L64**", "Commodore 64 with a 1541 disk drive", ".d64 (disks), .prg .t64 (programs), .tap (tapes), .a64 (snapshots)"],
      ["**LTari 800**", "Atari 800XL, 64 KB", ".atr (disks), .xex (programs), .car (cartridges), .a8s (snapshots)"],
      ["**LTari 130**", "Atari 130XE, 128 KB", "as LTari 800"],
      ["**LNES**", "Nintendo Entertainment System", ".nes (cartridges)"],
      ["**LMega**", "Sega Mega Drive / Genesis", ".md .gen .bin .smd (cartridges)"],
    ], [18, 36, 46]],
    ["p", "The board keeps **three machines** at a time. Which three is your choice: every machine is a file on the SD card, and you can put any of them in place of another in about 15 seconds (section 4)."],
    ["note", "The board set comes without games and other programs, and without the Commodore 64 ROMs. Section 5 says what each machine needs."],

    /* ------------------------------------------------------------ 2 */
    ["h1", "2. Connecting"],
    ["table", ["Socket", "Connect", "Notes"], [
      ["VGA", "Monitor", "The picture starts at 640 x 480, 60 Hz (L64: 800 x 600, 60 Hz), which every monitor accepts."],
      ["USB keyboard socket", "A PC keyboard", "A normal USB keyboard. On the first I/O board it plugs into the small keyboard module."],
      ["DB9-1, DB9-2", "Joysticks", "Atari / Commodore type with one fire button. Which socket is which player: section 8."],
      ["3.5 mm audio socket", "Amplifier or active speakers", "Line level, the same sound on both channels. Not for headphones directly."],
      ["microSD socket", "SD card", "FAT32 or FAT16, **not exFAT** (section 5). The card can be changed at any time."],
      ["Bluetooth", "Headphones or a speaker", "No cable: paired once with F3 (section 7)."],
      ["5 V input", "Power supply", "Powers everything. Connect it last."],
    ], [24, 26, 50]],
    ["p", "Only the monitor, the keyboard and the power are needed to see the machine menu. Plug the keyboard in before you switch on."],

    /* ------------------------------------------------------------ 3 */
    ["h1", "3. Switching on: the machine menu"],
    ["p", "The menu appears every time the board is switched on:"],
    ["screen", [
      "        Choose a machine        ",
      "                                ",
      " 1 LSpectrum    ZX Spectrum 128K",
      "                                ",
      " 2 L64          Commodore 64    ",
      "                                ",
      " 3 LTari 800    Atari 800XL     ",
      "                                ",
      " Up/Down + Enter, 1-3, joystick ",
      "      F3: Bluetooth audio       ",
      " F12: install from the SD card  ",
    ]],
    ["table", ["Key", "What it does"], [
      ["**Up / Down** (keypad 8 / 2)", "Moves the highlight"],
      ["**Enter** (keypad Enter)", "Starts the highlighted machine"],
      ["**1**, **2**, **3**", "Starts that machine at once"],
      ["Joystick (either socket)", "Up / down moves, fire starts"],
      ["**F3**", "Bluetooth audio menu (section 7)"],
      ["**F12**", "Installs a machine from the SD card (section 4)"],
    ], [36, 64]],
    ["p", "To leave a machine and come back to the menu, press **Ctrl + Alt + Del** (it acts when you let the keys go). The highlight is then on the machine you left. Whatever that machine was doing is lost, so save first if you need to. Bluetooth stays connected."],
    ["ul", [
      "A position that holds no machine shows **(empty)** and cannot be started.",
      "**No machines installed** means all three positions are empty: install machines with F12 (section 4).",
      "A red line **Could not start** means that machine's data is damaged: install it again with F12.",
    ]],

    /* ------------------------------------------------------------ 4 */
    ["h1", "4. Choosing your three machines (F12 in the menu)"],
    ["p", "Each machine is one file with the ending `.LMC`. The files are in the folder `INSTALL/MACHINES` of the project's download. You may copy all of them; the menu lists only the ones made for your board."],
    ["ol", [
      "On the PC, copy the folder `MACHINES` to the top folder of the SD card.",
      "Put the card into the board and switch on.",
      "In the machine menu press **F12**. **Which machine?** lists the machine files on the card. Choose one with Up / Down and Enter.",
      "**Replace which one?** shows the three positions and what they hold now. Choose the position the new machine goes into.",
      "Wait for **Installed.** (about 15 seconds). Do not switch off meanwhile. The menu then shows the new machine.",
    ]],
    ["table", ["If ...", "Then ..."], [
      ["the list of machines is empty", "The folder must be named `MACHINES`, in the top folder of the card, and the card must be FAT32 or FAT16."],
      ["the power fails while installing", "That position shows **(empty)**. Install the machine again. The menu and the other two positions are not touched."],
      ["LNES or LMega starts but shows no list of games", "The ESP32 needs its newer firmware: section 14."],
    ], [40, 60]],
    ["note", "Installing a machine never changes the files on the SD card. Installing L64 again keeps the C64 ROMs you put in (section 5)."],

    /* ------------------------------------------------------------ 5 */
    ["h1", "5. The SD card and your software"],
    ["p", "Use a microSD card formatted **FAT32** or **FAT16**. **exFAT does not work**: most cards above 32 GB come as exFAT and must be formatted as FAT32 first (on Windows with a FAT32 format tool; on a Mac with Disk Utility, \"MS-DOS (FAT)\")."],
    ["p", "Folders may have any names and may be nested. A folder shows up to 320 entries in the file list (4,096 on the second I/O board), so sort a large collection into sub-folders."],
    ["screen", [
      "SD card (example)                               ",
      "  MACHINES/    the machine files (.LMC)         ",
      "  ROMS/C64/    the four C64 ROM files           ",
      "  Spectrum/    .tap .tzx .z80                   ",
      "  C64/         .d64 .prg .t64 .tap .a64         ",
      "  Atari/       .atr .xex .car .a8s              ",
      "  NES/         .nes                             ",
      "  MegaDrive/   .md .gen .bin .smd               ",
    ]],
    ["p", "Please respect the copyright: use only software and ROMs you are allowed to use. A game is not free just because it is old. Many old programs may be shared with their authors' permission, others may not."],
    ["table", ["Machine", "Needs before it starts", "Programs"], [
      ["LSpectrum", "Nothing", ".tap, .tzx, .z80"],
      ["L64", "**The C64 ROMs, once** (below)", ".d64, .prg, .t64, .tap"],
      ["LTari 800 / 130", "Nothing", ".atr, .xex, .car"],
      ["LNES", "Nothing", ".nes"],
      ["LMega", "Nothing", ".md, .gen, .bin, .smd"],
    ], [22, 38, 40]],
    ["h2", "The Commodore 64 ROMs (once)"],
    ["p", "The C64's built-in programs are copyrighted and are not part of L. Use copies you are entitled to: read from a C64 and a 1541 you own, or licensed ones."],
    ["ol", [
      "On the SD card make the folder `/ROMS/C64/` and copy four files into it: the KERNAL (8 KB), BASIC (8 KB) and character ROM (4 KB), with names starting with **KERNAL**, **BASIC** and **CHAR**, and the 1541 disk drive's ROM (16 KB), name starting with **DOS1541** or **1541**.",
      "Start **L64** in the machine menu. The ROMs are copied into the board (a few seconds, shown on the screen) and the C64 starts.",
      "From then on the C64 starts without the card. If a file is missing, the screen says where to put it. Without the 1541 file the C64 runs, but has no disk drive.",
    ]],

    /* ------------------------------------------------------------ 6 */
    ["h1", "6. Keys that work in every machine"],
    ["table", ["Key", "What it does"], [
      ["**F12** (also keypad **/** or **NumLock**)", "Opens / closes the list of files on the SD card"],
      ["**F3**", "Bluetooth audio menu (section 7)"],
      ["**F4**", "Joystick menu (section 8)"],
      ["**Ctrl + Alt + Del**", "Back to the machine menu"],
      ["**F2**", "Computers only: saves a snapshot of the whole machine, to continue later exactly there. Asks for a name."],
      ["**F8**", "Computers: swaps the picture between 60 Hz and the machine's own 50 Hz. It is 60 Hz after every start. If the monitor shows nothing, press F8 again. LMega: section 13. LNES: no function."],
      ["**Print Screen**", "Saves the picture as `SCRNnnnn.BMP` in the folder the file list is in (not in LMega)"],
    ], [34, 66]],
    ["p", "Short messages (for example **Speed: turbo**) appear for a few seconds on the bottom line of the picture. While a menu or the file list is open, the machine itself sees no keys."],
    ["h2", "The file list"],
    ["p", "The list shows folders first, then the files the running machine can use, white on blue over the picture."],
    ["table", ["Key (list open)", "What it does"], [
      ["**Up / Down** (keypad 8 / 2)", "Moves the selection; held down it repeats"],
      ["**Left / Right**, **Page Up / Page Down** (keypad 4 / 6)", "One page up / down"],
      ["**Enter** (keypad Enter)", "Opens the folder, or loads the file"],
      ["**Esc**, **Backspace**", "Up one folder; in the top folder closes the list"],
      ["**F12**", "Closes the list"],
      ["**F2**", "Saves a snapshot into this folder (computers)"],
    ], [44, 56]],
    ["p", "When a name is asked for, type up to 8 letters or digits. **Backspace** deletes, **Enter** saves, **Esc** cancels. A name that already exists is refused."],

    /* ------------------------------------------------------------ 7 */
    ["h1", "7. Bluetooth sound (F3)"],
    ["p", "The sound of every machine can also go to Bluetooth headphones or a Bluetooth speaker. F3 works in the machine menu and in every machine."],
    ["ol", [
      "Put the headphones or the speaker into pairing mode.",
      "Press **F3**. The second line shows **Not connected** or **Connected: name**.",
      "Choose **Scan for devices** and press **Enter**. After a few seconds the devices found are listed.",
      "Move to your device and press **Enter**. The line changes to **Connected: name**.",
      "Press **F3** or **Esc** to close the menu.",
    ]],
    ["table", ["Menu line", "What it does"], [
      ["Scan for devices", "Searches for Bluetooth audio devices (ends the current connection)"],
      ["Disconnect", "Ends the connection"],
      ["Forget the device", "Ends it and does not reconnect by itself any more"],
      ["PIN", "Enter, type the code, Enter. Empty = automatic: 0000, 1234, 8888, 1111 are tried in turn."],
      ["Volume", "Left / Right"],
      ["Sound", "Enter swaps between the machine's sound and a test tone"],
    ], [30, 70]],
    ["p", "The board remembers the device and reconnects by itself when both are switched on. The connection stays when you change machines. Bluetooth delays the sound by about 0.2 seconds: fine for music, noticeable in fast games."],

    /* ------------------------------------------------------------ 8 */
    ["h1", "8. Joysticks (F4)"],
    ["p", "Any Atari / Commodore type joystick with a 9-pin plug works. F4 opens the joystick menu: Up / Down, **Enter** selects, F4 or Esc closes."],
    ["table", ["Machine", "Choices (the first is the one after a start)"], [
      ["LSpectrum", "**Kempston** on both sockets (most games) — **Kempston + Cursor** (DB9-2 acts as the keys 5 6 7 8 and 0) — **Interface 2** (DB9-1 = Sinclair 1, keys 6-0; DB9-2 = Sinclair 2, keys 1-5)"],
      ["L64", "**DB9-1 = control port 2, DB9-2 = port 1** (most one-player games use port 2) — swapped — both sockets on port 2"],
      ["LTari", "**DB9-1 = stick 0** (player 1 in most games), DB9-2 = stick 1 — swapped"],
      ["LNES", "Which socket is controller 1; whether the fire button is **A** (default) or B"],
      ["LMega", "Which socket is pad 1"],
    ], [18, 82]],
    ["p", "The consoles' pads have more buttons than a joystick. The joystick gives the directions and one button; the other buttons are on the keyboard (sections 12 and 13). A console game can be played with the keyboard and one joystick, or with the joystick's button and the keys next to your other hand."],

    /* ------------------------------------------------------------ 9 */
    ["h1", "9. LSpectrum (ZX Spectrum 128K)"],
    ["table", ["Key", "What it does"], [
      ["**F6**", "Tape loading and saving in turbo (default, 8 times faster) / normal speed"],
      ["**F7** (keypad *)", "Stops the tape"],
      ["**F11** (keypad 5)", "Pauses / continues the tape"],
      ["Keypad **-**", "Goes back one tape block (while paused)"],
      ["**F5**", "Exact memory timing on (default) / off. Some games and border effects need it on."],
      ["**Page Up / Page Down**", "Moves border effects up / down in small steps (50 Hz picture, file list closed)"],
      ["**F1** held while the Spectrum starts", "Starts the second ROM (48K BASIC) instead of the 128K one"],
      ["Esc / Backspace", "BREAK / DELETE on the Spectrum"],
    ], [34, 66]],
    ["h2", "Loading a game"],
    ["ol", [
      "Make the Spectrum wait for a tape: **Tape Loader** in the 128K menu, or `LOAD \"\"` and Enter.",
      "Press **F12**, choose the .tap or .tzx file and press **Enter**. The tape plays; in turbo the Spectrum runs 8 times faster until the tape ends.",
      "Games that load more later: when the bottom line says **Tape stopped (5=go on)** and the game asks for the next part, press keypad **5** (or F11).",
      "After a loading error: keypad **5** pauses, keypad **-** goes back one block per press; type `LOAD \"\"` again and press keypad 5. If a game does not load in turbo, press **F6** and load it at normal speed.",
    ]],
    ["h2", "Saving to tape"],
    ["ol", [
      "Press **F12**, go into a folder and choose the first line **[Save to this folder]**.",
      "Type a name (or keep **SAVEnnnn**) and press **Enter**: recording starts.",
      "Save on the Spectrum as often as you like (`SAVE \"name\"`): everything goes into this one .TAP file.",
      "Press **F12** to stop. Load the file later like any tape.",
    ]],
    ["h2", "Snapshots (.z80)"],
    ["p", "**F2** asks for a name and saves the whole machine as NAME.Z80; the Spectrum then runs on. To continue another day: F12, choose the .z80, Enter. No LOAD is needed. Snapshots made by PC emulators (48K and 128K) work too."],

    /* ------------------------------------------------------------ 10 */
    ["h1", "10. L64 (Commodore 64)"],
    ["p", "The first start copies the C64 ROMs from the SD card (section 5). The picture appears about 2 seconds after starting, when BASIC is ready."],
    ["table", ["Key", "What it does"], [
      ["**F6**", "Loading in turbo (default: up to 4 times faster while the tape or the disk runs) / normal"],
      ["**F7** (keypad *)", "Stops the tape"],
      ["**F11** (keypad 5)", "Pauses / continues the tape"],
      ["**F5**", "Sound chip of the early C64 (6581, default) / of the late C64 (8580)"],
      ["**Alt + F1 ... F8**", "The C64's own F1 ... F8 keys"],
    ], [34, 66]],
    ["h2", "Loading"],
    ["ul", [
      "**Disk (.d64)**: F12, choose the .d64, **Enter**. The disk goes into drive 8 and `LOAD\"*\",8,1` is typed for you. When **READY.** appears, type `RUN` and Return. When a game asks for another disk, choose it with F12.",
      "**The disk's contents**: `LOAD\"$\",8` then `LIST`.",
      "**Program (.prg, .t64)**: F12, choose it, **Enter**. A BASIC program starts by itself; for others the bottom line shows what to type (for example `SYS 49152`).",
      "**Tape (.tap)**: type `LOAD` and Return (PRESS PLAY ON TAPE), then F12, choose the .tap, **Enter**.",
      "**Saving to tape**: F12, **[Save to this folder]**, a name, Enter; then `SAVE \"name\"` on the C64; F12 stops.",
      "**Snapshots (.a64)**: F2 saves (best while the disk drive is idle); F12, the .a64, Enter continues.",
    ]],
    ["h2", "The C64 keyboard"],
    ["table", ["PC key", "C64 key"], [
      ["Letters, digits, Return, Space, , . /", "The same keys"],
      ["- = [ ] ; ' `", "+ - @ * : ; ← (the keys at the same places on the C64)"],
      ["\\", "="],
      ["Insert / End / Home", "£ / ↑ / CLR HOME"],
      ["Backspace, Delete", "INST DEL"],
      ["Esc", "RUN/STOP"],
      ["Tab, Ctrl", "CTRL"],
      ["Windows key", "C= (Commodore key)"],
      ["Page Up (file list closed)", "RESTORE"],
      ["Cursor keys", "Cursor keys"],
    ], [40, 60]],
    ["p", "The key positions follow a US keyboard. Most games want the joystick in control port 2: that is DB9-1 unless you change it with F4. Cartridges are not supported."],

    /* ------------------------------------------------------------ 11 */
    ["h1", "11. LTari (Atari 800XL / 130XE)"],
    ["p", "LTari 800 and LTari 130 are two machine files; each takes one of the three positions. They work the same; the 130 has twice the memory, which a few later programs need."],
    ["table", ["Key", "What it does"], [
      ["**Alt + F2 / F3 / F4**", "The Atari's START / SELECT / OPTION keys"],
      ["**Alt + F5**", "The Atari's RESET key"],
      ["**Alt + F6**", "HELP"],
      ["**Pause** (also Alt + F7)", "BREAK"],
      ["**Shift + Enter** on an .atr in the file list", "Changes the disk without restarting (\"insert disk 2\")"],
    ], [40, 60]],
    ["h2", "Loading"],
    ["ul", [
      "**Disk (.atr)**: F12, choose it, **Enter**. The screen asks **<F1> No BASIC  <F2> with BASIC**. Most games want **F1**; disks with BASIC programs want **F2**. The Atari restarts and starts from the disk. Programs write to the .atr file as to a real disk.",
      "**Program (.xex)**: F12, choose it, **Enter**.",
      "**Cartridge (.car)**: F12, choose it, **Enter**. Choosing an .atr or .xex afterwards takes the cartridge out.",
      "**Snapshots (.a8s)**: F2 saves; F12, the .a8s, Enter continues. Load it on the same model (800 or 130); for a cartridge game load the .car first.",
    ]],
    ["h2", "The Atari keyboard"],
    ["table", ["PC key", "Atari key"], [
      ["Letters, digits, Return, Space, Tab, Esc, Caps Lock, Backspace", "The same keys"],
      ["- = ; , . /", "The same keys"],
      ["' (apostrophe)", "+"],
      ["\\ (backslash)", "*"],
      ["[ and ]", "< and >"],
      ["` (back quote)", "Inverse video (the Atari logo key)"],
      ["Cursor keys", "The cursor keys"],
      ["Home", "CLEAR screen"],
      ["Delete / Insert", "Delete / insert a character"],
    ], [48, 52]],
    ["p", "The key positions follow a US keyboard. If a disk game hangs at its start or shows a half-drawn screen, load it again and answer **F1** (No BASIC)."],

    /* ------------------------------------------------------------ 12 */
    ["h1", "12. LNES (Nintendo Entertainment System)"],
    ["note", "LNES and LMega are the newest machines. When this edition was written they had passed their tests in simulation and had not yet been run on a board."],
    ["p", "The list of games opens by itself when LNES starts. Choose a .nes file and press **Enter**: the game starts. **F12** opens the list again for another game."],
    ["table", ["Button", "Controller 1", "Controller 2"], [
      ["Up, Down, Left, Right", "Joystick in DB9-1", "Joystick in DB9-2"],
      ["A", "The joystick's button; also **X** or **Space**", "The joystick's button; also **G**"],
      ["B", "**Z** or left **Ctrl**", "**F**"],
      ["Select", "**Tab**", "**R**"],
      ["Start", "**Enter**", "**T**"],
    ], [28, 40, 32]],
    ["table", ["Key", "What it does"], [
      ["**Alt + F5**", "The console's Reset button"],
      ["**F4**", "Which socket is controller 1; joystick button = A or B"],
      ["**Print Screen**", "Saves the picture"],
    ], [34, 66]],
    ["ul", [
      "The console is the American / Japanese 60 Hz model; F8 has no function.",
      "A game with a battery in its cartridge keeps its saved games in a small file `NAMEhhhh.SAV` beside the game. It is written by itself a moment after the game saves. Keep it together with the game.",
      "Most cartridges work. A game whose cartridge type is not built in is refused with a line such as **No mapper 9**.",
      "There are no snapshots (F2) in the consoles.",
    ]],

    /* ------------------------------------------------------------ 13 */
    ["h1", "13. LMega (Sega Mega Drive / Genesis)"],
    ["p", "The list of games opens by itself when LMega starts. Choose a game and press **Enter**. **F12** opens the list again."],
    ["table", ["Button", "Pad 1", "Pad 2"], [
      ["Up, Down, Left, Right", "Joystick in DB9-1", "Joystick in DB9-2"],
      ["B", "The joystick's button; also **Tab**", "The joystick's button; also **R**"],
      ["A", "**Z** or left **Ctrl**", "**F**"],
      ["C", "**X** or **Space**", "**G**"],
      ["Start", "**Enter**", "**T**"],
    ], [28, 40, 32]],
    ["table", ["Key", "What it does"], [
      ["**Alt + F5**", "The console's Reset button"],
      ["**F4**", "Which socket is pad 1"],
      ["**F8**", "For a game made for Europe only: steps through three pictures (below)"],
    ], [34, 66]],
    ["p", "Games for America or Japan always run at 60 Hz. A game made for Europe only is a 50 Hz game, and F8 steps through:"],
    ["ol", [
      "**60 Hz console** (after every start): the game runs about 17 % too fast; a few games refuse to run.",
      "**50 Hz console, 50 Hz picture**: the right speed and smooth, if the monitor accepts 50 Hz.",
      "**50 Hz console, 60 Hz picture**: the right speed on any monitor; movement is slightly less smooth.",
    ]],
    ["ul", [
      "Saved games of cartridges with a battery go into `NAMEhhhh.SAV` beside the game, as in LNES.",
      "Games up to 4 MB work. The pad is the 3-button one. Print Screen and snapshots are not available.",
    ]],

    /* ------------------------------------------------------------ 14 */
    ["h1", "14. Updating the board"],
    ["p", "Updates are files in the folder `INSTALL` of the project's download. They are needed only when a new version is published."],
    ["h2", "The ESP32 (file list, Bluetooth)"],
    ["ol", [
      "Take `LESP32.BIN` from `ESP32_UPDATE/v1` (first I/O board: the ESP32 is a small plug-in board) or `ESP32_UPDATE/v2` (second I/O board: USB-C socket on the board).",
      "Copy it to the top folder of the SD card, put the card in and switch on. The update runs by itself.",
    ]],
    ["p", "LNES and LMega need this firmware: do it before you install them."],
    ["h2", "The machine menu"],
    ["ol", [
      "Take `LUPDATE.BIN` from `MENU_UPDATE/10cl025`.",
      "Copy it to the top folder of the SD card, put the card in and switch on.",
      "The screen shows **Checking LUPDATE.BIN ...**, then **Writing the flash ...** with a progress bar. **Do not switch off.**",
      "At **Update complete.** the file is deleted from the card. If the screen asks for it, switch the board off and on.",
    ]],
    ["note", "Use only the file from `MENU_UPDATE/10cl025`. A menu file made for a different board leaves the board unable to start; it then has to be written again with a programming cable."],
    ["p", "The machines themselves are updated by installing their newer `.LMC` files (section 4)."],

    /* ------------------------------------------------------------ 15 */
    ["h1", "15. If something does not work"],
    ["table", ["Problem", "What to do"], [
      ["No picture after F8", "The monitor does not accept 50 Hz: press F8 again."],
      ["The file list is empty", "The card must be FAT32 or FAT16, not exFAT. Press F12 again after changing the card. The list shows only the files the running machine can use."],
      ["The menu shows **(empty)** or **No machines installed**", "Install machines with F12 (section 4)."],
      ["**Could not start** in the menu", "Install that machine again with F12."],
      ["L64 asks for ROM files", "Copy the four files into `/ROMS/C64/` (section 5) and start L64 again."],
      ["Keys do nothing in a machine", "A menu or the file list may be open: close it with Esc, F12, F3 or F4. If needed, Ctrl + Alt + Del and start the machine again."],
      ["The keyboard does nothing at all", "Switch off, check the keyboard's plug, switch on with the keyboard connected."],
      ["**No answer from the ESP32** (F3)", "Switch the board off and on. On the first I/O board check that the ESP32 board sits in its sockets."],
      ["No sound", "The audio socket needs an amplifier or active speakers. For Bluetooth check **Connected** in the F3 menu and its Volume line."],
      ["A Spectrum game does not load", "Press F6 (normal speed) and load it again."],
      ["An Atari game hangs at its start", "Load the .atr again and answer **F1** (No BASIC)."],
      ["A console game is refused", "LNES: its cartridge type is not built in. LMega: games above 4 MB and games with extra chips in the cartridge do not run."],
    ], [38, 62]],
  ],
};
