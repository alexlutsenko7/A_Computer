// l64_keys_doc.js -- docs/L64_Keys.docx: the machine menu and L64 (Commodore 64): keys and usage.
//   node l64_keys_doc.js ../L64_Keys.docx
const fs = require("fs");
const {
  Document, Packer, Paragraph, TextRun, Table, TableRow, TableCell, WidthType,
  ShadingType, HeadingLevel, AlignmentType, LevelFormat, BorderStyle, Footer, PageNumber,
} = require("docx");

const W = 9360; // US Letter text width with 1" margins (DXA)
const FONT = "Calibri";
const border = { style: BorderStyle.SINGLE, size: 4, color: "A6A6A6" };
const borders = { top: border, bottom: border, left: border, right: border };

function runs(text, opts = {}) {
  // **bold** segments
  return text.split(/(\*\*[^*]+\*\*)/).filter(Boolean).map(t =>
    t.startsWith("**") ? new TextRun({ text: t.slice(2, -2), bold: true, font: FONT, size: opts.size || 20 })
                       : new TextRun({ text: t, font: FONT, size: opts.size || 20 }));
}

function cell(text, width, head = false) {
  const lines = Array.isArray(text) ? text : [text];
  return new TableCell({
    width: { size: width, type: WidthType.DXA },
    borders,
    shading: head ? { type: ShadingType.CLEAR, color: "auto", fill: "1F3864" } : undefined,
    margins: { top: 60, bottom: 60, left: 100, right: 100 },
    children: lines.map(l => new Paragraph({
      children: head ? [new TextRun({ text: l, bold: true, color: "FFFFFF", font: FONT, size: 20 })] : runs(l),
    })),
  });
}

function table(widths, header, rows) {
  if (widths.reduce((a, b) => a + b, 0) !== W) throw new Error("table widths");
  return new Table({
    width: { size: W, type: WidthType.DXA },
    columnWidths: widths,
    rows: [
      new TableRow({ tableHeader: true, children: header.map((h, i) => cell(h, widths[i], true)) }),
      ...rows.map(r => new TableRow({ cantSplit: true, children: r.map((c, i) => cell(c, widths[i])) })),
    ],
  });
}

const h1 = t => new Paragraph({ heading: HeadingLevel.HEADING_1, spacing: { before: 300, after: 120 }, children: [new TextRun({ text: t, font: FONT })] });
const h2 = t => new Paragraph({ heading: HeadingLevel.HEADING_2, spacing: { before: 240, after: 100 }, children: [new TextRun({ text: t, font: FONT })] });
const p = t => new Paragraph({ spacing: { after: 100 }, children: runs(t, { size: 21 }) });
const bullet = t => new Paragraph({ numbering: { reference: "bullets", level: 0 }, spacing: { after: 60 }, children: runs(t, { size: 21 }) });
const gap = () => new Paragraph({ spacing: { after: 60 }, children: [] });

// numbering instances: each procedure restarts at 1
const procs = ["roms", "disk", "dir", "prg", "tape", "save", "snapsave", "snapload", "video", "bt"];
const numbering = {
  config: [
    { reference: "bullets", levels: [{ level: 0, format: LevelFormat.BULLET, text: "•", alignment: AlignmentType.LEFT,
      style: { paragraph: { indent: { left: 540, hanging: 270 } } } }] },
    ...procs.map(r => ({ reference: r, levels: [{ level: 0, format: LevelFormat.DECIMAL, text: "%1.", alignment: AlignmentType.LEFT,
      style: { paragraph: { indent: { left: 540, hanging: 300 } } } }] })),
  ],
};
const stepOf = ref => t => new Paragraph({ numbering: { reference: ref, level: 0 }, spacing: { after: 60 }, children: runs(t, { size: 21 }) });

const children = [
  new Paragraph({ spacing: { after: 60 }, children: [new TextRun({ text: "L64 and the machine menu — keys", bold: true, size: 40, font: FONT, color: "1F3864" })] }),
  new Paragraph({ spacing: { after: 240 }, children: [new TextRun({ text: "Commodore 64 (PAL) with 1541 disk drive on the QMTECH Cyclone IV board: SD card loader, turbo, snapshots, 60 / 50 Hz video, Bluetooth audio (build of 28 October 2026)", size: 21, font: FONT, color: "595959" })] }),

  p("All keys below are on the USB keyboard unless a board button is named. The C64's own keys are listed at the end. The keys for the ZX Spectrum are in LSpectrum_Keys.docx."),

  // ------------------------------------------------------------------ menu
  h1("The machine menu"),
  p("At every power-up the FPGA first shows the machine menu: **1 LSpectrum** (ZX Spectrum 128K), **2 L64** (Commodore 64), **3 LTari 800** and **4 LTari 130** (Atari 800XL / 130XE, see LTari_Keys.docx). It needs nothing but the board, the monitor and the keyboard or a joystick."),
  table([3108, 6252], ["Key", "What it does"], [
    ["**Up** / **Down** (or keypad 8 / 2)", "Moves the highlight"],
    ["**Enter** (or keypad Enter)", "Starts the highlighted machine"],
    ["**1** ... **4** (also on the keypad)", "Starts that machine at once"],
    ["Joystick (either socket)", "Up / down moves, fire starts"],
    ["**Ctrl + Alt + Del** or **KEY1** (board button Y13) in a machine", "Back to this menu; the highlight is on the machine you left. The machine's state is lost."],
  ]),
  gap(),
  p("Keys already held at power-up are ignored. If a machine cannot start (its image is missing or damaged), the menu comes back with red lines saying **Could not start**, the reason and the address that was tried, and the board LED blinks: program the .jic again."),

  // ------------------------------------------------------------------ machine keys
  h1("L64: machine keys"),
  table([2234, 2816, 4310], ["Key", "What it does", "Notes"], [
    ["**F12**, keypad **/** or **NumLock**", "Opens / closes the SD card browser", ["Lists folders and the .d64, .prg, .t64, .tap and .a64 files. See \"Usage cases\" below."]],
    ["**F2**", "Saves a snapshot of the whole C64 as a .a64 file",
      ["The C64 stops at once and asks for a name. Choosing the .a64 in the browser later loads it. See \"Saving and loading snapshots\"."]],
    ["**F3**", "Opens the Bluetooth audio menu",
      ["For Bluetooth headphones or a speaker, as on LSpectrum: scan, connect, PIN, volume. F3 or Esc closes it."]],
    ["**F4**", "Opens the joystick menu",
      ["Chooses which C64 control port each DB9 socket is: **DB9-1 = port 2, DB9-2 = port 1** (default; most one-player games use port 2), **swapped**, or **both on port 2**. Up / Down, Enter selects, F4 or Esc closes."]],
    ["**F5**", "Switches the SID sound chip between **6581** (default) and **8580**",
      ["The 6581 is the original C64's chip, the 8580 the later one (different filter and sound of the digi samples). Shown on the bottom row for 4 seconds."]],
    ["**F6**", "Switches loading between **turbo** (default) and normal speed",
      ["In turbo, while the cassette or the disk drive motor runs, the C64 and the 1541 run up to 4 times faster. The picture and the sound chip keep the normal speed; music that a game plays while it loads runs fast. Shows \"Speed: turbo\" or \"Speed: normal\" for 2 seconds. Back to turbo after KEY0 or power-up."]],
    ["**F7**, keypad *", "Stops the tape", []],
    ["**F11**, keypad **5**", "Pauses / continues the tape", []],
    ["**F8**", "Swaps the video between 60 Hz and 50 Hz",
      ["After power-up the picture is 800x600 at 60 Hz, which monitors accept best. The C64 itself always runs at its real 50 Hz (PAL); at 60 Hz every fifth picture is shown twice, so scrolling is very slightly uneven. The 50 Hz mode shows every picture once. The monitor takes a moment to switch; the C64 runs on meanwhile."]],
    ["**Alt + F1 ... F8**", "The C64's own F1 ... F8 keys", ["Without Alt, the PC's F-keys are the functions in this table. Alt+F2 / F4 / F6 / F8 give SHIFT + F1 / F3 / F5 / F7, as on the C64."]],
    ["**KEY0** (board button W13)", "Resets everything", ["The C64 starts as after switching it on (its memory is cleared, so a game's reset protection cannot catch it); the loader and the ESP32 restart; Bluetooth reconnects after a few seconds."]],
    ["**Ctrl + Alt + Del**, or **KEY1** (board button Y13)", "Back to the machine menu", ["Ctrl + Alt + Del acts when the keys are released; no board button is needed. See above."]],
  ]),
  gap(),
  p("The board LED is on for 2.7 seconds after the machine starts, then shows the 1541's drive LED (on while the drive works). A fast blink means that there are no C64 ROMs in the flash yet (see \"First start: the ROMs\")."),

  h2("Browser and name keys"),
  table([3420, 5940], ["Key (browser open)", "Action"], [
    ["Up / Down, keypad 8 / 2, F9 / F10", "Moves the selection (held: repeats)"],
    ["Left / Right, keypad 4 / 6, Page Up / Page Down", "One page up / down"],
    ["**Enter**, keypad Enter, F11", "Opens the folder, or uses the file (see the usage cases)"],
    ["**Esc**, **Backspace**", "Up one folder; in the top folder closes the browser"],
    ["**F12**", "Closes the browser"],
    ["**F2**", "Saves a snapshot into this folder"],
  ]),
  gap(),
  p("While the browser is open the C64 sees no keys. When asked for a name (saving to tape, or F2), type up to 8 letters or digits, Backspace deletes, **Enter** saves, **Esc** cancels."),

  // ------------------------------------------------------------------ usage
  h1("Usage cases"),

  h2("First start: the ROMs"),
  p("The Commodore ROMs are copyrighted and are not part of this project, so you supply your own files (for example those that come with the VICE emulator)."),
  stepOf("roms")("On the SD card, make the folder **/ROMS/C64/** and put in it the KERNAL (8 KB), BASIC (8 KB) and character ROM (4 KB): file names starting with **KERNAL**, **BASIC** and **CHAR**, e.g. kernal-901227-03.bin, basic-901226-01.bin, chargen-901225-01.bin."),
  stepOf("roms")("For the disk drive add the 1541 DOS ROM (16 KB), a name starting with **DOS1541** or **1541**. Without it there is no drive (DEVICE NOT PRESENT)."),
  stepOf("roms")("Start L64 from the machine menu. The ESP32 finds no ROMs in the flash, writes them there (a few seconds, shown on screen) and restarts the C64. From then on the C64 starts without the card. If the files are missing, the screen says where to put them: add them and press KEY0."),

  h2("Loading a game from disk (.d64)"),
  stepOf("disk")("Press **F12**, choose the **.d64** file and press **Enter**. The disk goes into the drive (device 8) and **LOAD\"*\",8,1** is typed for you."),
  stepOf("disk")("Loading runs in turbo (F6): the drive LED and the board LED are on. Many games start by themselves; when **READY.** appears, type **RUN** and press Return."),
  stepOf("disk")("For a disk with several programs, see the directory first (below) and load by name: **LOAD\"NAME\",8,1**."),
  stepOf("disk")("When a game asks for another disk (or side B), press **F12** and choose that .d64: the disk is changed and the game notices it. Nothing is typed while a program runs."),
  stepOf("disk")("To protect a .d64 from being written to, make the file read-only on the PC (Properties > Read-only): the C64 then sees a write-protected disk."),

  h2("Showing a disk's directory"),
  stepOf("dir")("Insert the .d64 with F12 as above, then press **Esc** (RUN/STOP) if the automatic LOAD has started."),
  stepOf("dir")("Type **LOAD\"$\",8** and Return, then **LIST** and Return."),

  h2("Loading a program file (.prg, .t64)"),
  stepOf("prg")("Press **F12**, choose the **.prg** or **.t64** file and press **Enter**."),
  stepOf("prg")("The program is put straight into memory. A BASIC program starts by itself (RUN is typed for you); for other programs the bottom line shows where it was loaded (for example $C000-$C3FF), and the program's own instructions say how to start it (often **SYS** with a number, e.g. SYS 49152 for $C000)."),

  h2("Loading from tape (.tap)"),
  stepOf("tape")("Type **LOAD** and press Return (or Shift+Esc = SHIFT+RUN/STOP). The C64 says PRESS PLAY ON TAPE."),
  stepOf("tape")("Press **F12**, choose the **.tap** file and press **Enter**. The tape plays; the C64 switches the tape motor as a real datasette, and in turbo it loads up to 4 times faster."),
  stepOf("tape")("**F11** or keypad 5 pauses, **F7** stops. If a game's own (turbo) loader fails, press F6 for normal speed and load again."),

  h2("Saving to tape"),
  stepOf("save")("Press **F12**, choose the first line **[Save to this folder]**, type a name and press Enter. A .TAP file of that name is opened."),
  stepOf("save")("On the C64 type **SAVE \"NAME\"** and Return (the C64 waits for RECORD & PLAY: that is already pressed). Save as often as you like; everything goes into this file."),
  stepOf("save")("Press **F12** to stop recording and close the file. Load it later as any .tap."),

  h2("Saving and loading snapshots (.a64)"),
  stepOf("snapsave")("At any moment (also in a game) press **F2**. The C64 stops; type a name and press Enter: NAME.A64 is saved in the browser's current folder, and the C64 runs on. Esc saves nothing."),
  stepOf("snapsave")("Save while the disk drive is idle: the drive's own state is not part of the snapshot."),
  stepOf("snapload")("To continue later: press **F12**, choose the **.a64** file and press **Enter**. The C64 continues exactly where it was saved, with picture, sound and registers."),
  stepOf("snapload")("A note or two of the music may restart, and a raster effect may jump for one picture; the game then runs normally."),

  h2("60 Hz or 50 Hz"),
  stepOf("video")("At each start (from the machine menu, KEY0) the monitor gets no signal for about 2 seconds, until BASIC is on the screen: then it adjusts itself to a real picture."),
  stepOf("video")("L64 starts at 800x600, 60 Hz. If your monitor also accepts 50 Hz, **F8** shows the C64's own 50 Hz with perfectly smooth scrolling; F8 again goes back to 60 Hz."),
  stepOf("video")("If the monitor shows nothing after F8, press F8 again. The choice survives KEY0; after power-up and after the machine menu it is always 60 Hz."),

  h2("Sound on Bluetooth headphones or a speaker"),
  stepOf("bt")("The SID sound goes to the 3.5 mm jack and, through the ESP32, to Bluetooth. Press **F3**, choose **Scan**, then the device, and Enter."),
  stepOf("bt")("The ESP32 remembers the device and reconnects by itself at the next start. The menu works as on LSpectrum (LSpectrum_Keys.docx)."),

  // ------------------------------------------------------------------ keyboard
  h1("The C64 keyboard on a USB keyboard"),
  p("The keys are mapped by their position on a US keyboard, so the C64's layout is where a C64 owner expects it:"),
  table([3420, 5940], ["USB key", "C64 key"], [
    ["Letters, digits, Return, Space, , . /", "The same keys"],
    ["- = [ ] ; ' `", "+ - @ * : ; ← (the keys at the same places on the C64)"],
    ["\\", "="],
    ["Insert / End / Home", "£ / ↑ / CLR HOME"],
    ["Backspace, Delete", "INST DEL"],
    ["Esc", "RUN/STOP"],
    ["Tab, Ctrl", "CTRL"],
    ["Windows key", "C= (Commodore key)"],
    ["Page Up (browser closed)", "RESTORE"],
    ["Left / Right / Up / Down", "Cursor keys (Left and Up add SHIFT, as on the C64)"],
    ["Shift", "SHIFT"],
    ["Alt + F1 ... F8", "F1 ... F8"],
  ]),

  h1("Good to know"),
  bullet("SD card: FAT32 or FAT16, not exFAT. The browser shows folders first, then files, up to 320 per folder."),
  bullet("Most games want a joystick in **control port 2**: that is the DB9-1 socket by default (F4 changes it)."),
  bullet("Games on several disks: insert the next .d64 with F12 when the game asks for it, then go on as the game says. Disk changes are not signalled to the drive yet, so a game that checks for the change may not notice the new disk."),
  bullet("A game that keeps the disk motor running stays in turbo: if it runs too fast, press F6."),
  bullet("Cartridges are not supported."),
];

const doc = new Document({
  creator: "L",
  title: "L64 and the machine menu — keys",
  styles: {
    default: { document: { run: { font: FONT, size: 21 } } },
    paragraphStyles: [
      { id: "Heading1", name: "Heading 1", basedOn: "Normal", next: "Normal", quickFormat: true,
        run: { size: 30, bold: true, color: "1F3864", font: FONT }, paragraph: { outlineLevel: 0 } },
      { id: "Heading2", name: "Heading 2", basedOn: "Normal", next: "Normal", quickFormat: true,
        run: { size: 24, bold: true, color: "2F5496", font: FONT }, paragraph: { outlineLevel: 1 } },
    ],
  },
  numbering,
  sections: [{
    properties: { page: { size: { width: 12240, height: 15840 }, margin: { top: 1440, bottom: 1440, left: 1440, right: 1440 } } },
    footers: { default: new Footer({ children: [new Paragraph({ alignment: AlignmentType.CENTER, children: [new TextRun({ children: [PageNumber.CURRENT], size: 18, font: FONT, color: "808080" })] })] }) },
    children,
  }],
});

Packer.toBuffer(doc).then(b => { fs.writeFileSync(process.argv[2], b); console.log("written", process.argv[2], b.length); });
