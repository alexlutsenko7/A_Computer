// ltari_keys_doc.js -- docs/LTari_Keys.docx: LTari (Atari 800XL / 130XE): keys and usage.
//   node ltari_keys_doc.js ../LTari_Keys.docx
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
const procs = ["boot", "disk", "swap", "dos", "xex", "car", "nobasic", "snap", "video", "bt", "shot"];
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
  new Paragraph({ spacing: { after: 60 }, children: [new TextRun({ text: "LTari — keys", bold: true, size: 40, font: FONT, color: "1F3864" })] }),
  new Paragraph({ spacing: { after: 240 }, children: [new TextRun({ text: "Atari 800XL / 130XE (PAL) on the QMTECH Cyclone IV board: AltirraOS and Altirra BASIC, SD card disk drive (.atr), .xex and cartridges (.car), snapshots, 60 / 50 Hz video, Bluetooth audio (build of 2 November 2026)", size: 21, font: FONT, color: "595959" })] }),

  p("All keys below are on the USB keyboard unless a board button is named. The machine menu is described in L64_Keys.docx; LTari has two entries there: **3 LTari 800** (800XL, 64 KB) and **4 LTari 130** (130XE, 128 KB)."),

  h1("Machine keys"),
  table([2234, 2816, 4310], ["Key", "What it does", "Notes"], [
    ["**F12**, keypad **/** or **NumLock**", "Opens / closes the SD card browser", ["Lists folders and the .atr, .xex and .car files. See \"Usage cases\" below."]],
    ["**Alt + F2 / F3 / F4**", "The Atari's **START / SELECT / OPTION**", ["Held as long as the keys are held. OPTION held while the Atari starts switches BASIC off: Alt + F4 held while pressing KEY0 without a disk (for an .atr the browser asks)."]],
    ["**Alt + F5**", "The Atari's **Reset** key", ["A warm start: BASIC keeps its program."]],
    ["**Alt + F6**", "The Atari's **Help** key", []],
    ["**Pause**, **Alt + F7**", "The Atari's **Break** key", []],
    ["**F3**", "Opens the Bluetooth audio menu", ["As on the other machines: scan, connect, PIN, volume. F3 or Esc closes it."]],
    ["**F4**", "Opens the joystick menu", ["**DB9-1 = stick 0** (default; player 1 in most games) or swapped. Up / Down, Enter selects, F4 or Esc closes."]],
    ["**F8**", "Swaps the video between 60 Hz and 50 Hz",
      ["After power-up the picture is 640x480 at 60 Hz; F8 gives 720x576 at 50 Hz. The Atari itself always runs at its real 50 Hz (PAL); at 60 Hz every fifth picture is shown twice. The 50 Hz mode shows every picture once."]],
    ["**F2**", "Saves a snapshot", ["The Atari stops; type a name, Enter saves NAME.A8S in the browser's current folder (Esc: no file), then it runs on. Choosing the .a8s in the browser loads it."]],
    ["**Print Screen**", "Saves the picture", ["As SCRNnnnn.BMP (376 x 240, 256 colours) in the browser's current folder."]],
    ["**KEY0** (board button W13)", "Resets everything", ["A cold start: memory cleared, disk and cartridge taken out; the ESP32 restarts."]],
    ["**Ctrl + Alt + Del**, or **KEY1** (board button Y13)", "Back to the machine menu", ["Ctrl + Alt + Del acts when the keys are released."]],
  ]),
  gap(),
  p("F5, F6 and saving to tape are not used on LTari: they show a note or do nothing."),

  h2("Browser keys"),
  table([3420, 5940], ["Key (browser open)", "Action"], [
    ["Up / Down, keypad 8 / 2, F9 / F10", "Moves the selection (held: repeats)"],
    ["Left / Right, keypad 4 / 6, Page Up / Page Down", "One page up / down"],
    ["**Enter**, keypad Enter, F11", "Opens the folder, or uses the file (see the usage cases); an .atr boots"],
    ["**Shift + Enter** on an .atr", "Changes the disk in D1: only; the Atari runs on (\"insert disk 2\")"],
    ["**Enter** on an .atr, then **F1** / **F2**", "Boots it with BASIC off (F1) or on (F2); Esc goes back to the list"],
    ["**Esc**, **Backspace**", "Up one folder; in the top folder closes the browser"],
    ["**F12**", "Closes the browser"],
  ]),
  gap(),
  p("While the browser is open the Atari sees no keys."),

  h1("Usage cases"),

  h2("Starting"),
  stepOf("boot")("In the machine menu choose **3 LTari 800** or **4 LTari 130**. No ROM files are needed: AltirraOS and Altirra BASIC (free replacements by Avery Lee) are in the flash."),
  stepOf("boot")("The monitor gets no signal for about 2 seconds, then the screen turns blue. With no disk the OS asks the disk drive for about a second, then **Altirra 8K BASIC** shows **Ready**."),

  h2("Booting a disk (.atr)"),
  stepOf("disk")("Press **F12**, choose the **.atr** file and press **Enter**. Three lines ask **How do you want to load it: <F1> No BASIC <F2> with BASIC**; press F1 or F2 (Esc goes back to the list)."),
  stepOf("disk")("The note says **D1: name**; the disk is in drive 1 and the Atari restarts and boots from it."),
  stepOf("disk")("The disk stays in until another one is chosen or KEY0 is pressed. Programs write to it as to a real disk: the .atr on the card changes."),
  stepOf("disk")("Disks made for the old Atari 400 / 800 often need **BASIC off** (e.g. M.U.L.E.: with BASIC on it hangs on a half-drawn screen): choose **F1**. The OPTION key is held for you while the Atari starts."),
  stepOf("disk")("To protect an .atr, make the file read-only on the PC (Properties > Read-only): writing then fails with an error, as on a write-protected disk."),

  h2("Changing disks (multi-disk programs)"),
  stepOf("swap")("Boot the first disk as above (Enter, then F1 or F2)."),
  stepOf("swap")("When the program asks for the next disk or side: **F12**, choose that .atr and press **Shift + Enter**. The note says **Disk changed, D1: name**; the Atari was not restarted."),
  stepOf("swap")("Press the key the program asks for (often Return or START) to go on."),

  h2("BASIC with a DOS disk"),
  stepOf("dos")("Boot a DOS disk (e.g. DOS 2.5 .atr) as above with **F2** (with BASIC). BASIC starts with Ready."),
  stepOf("dos")("**SAVE \"D:NAME\"** and **LOAD \"D:NAME\"** save and load BASIC programs on that disk; **DOS** opens the DOS menu."),

  h2("Running a program file (.xex)"),
  stepOf("xex")("Press **F12**, choose the **.xex** file and press **Enter**. The note says **Run: name**."),
  stepOf("xex")("The Atari restarts, a small loader switches BASIC off and loads the file from a virtual disk (a few seconds), then the program starts."),
  stepOf("xex")("The loader uses memory $0700-$08FF: a program that loads there does not work this way (use an .atr version)."),

  h2("Plugging in a cartridge (.car)"),
  stepOf("car")("Press **F12**, choose the **.car** file and press **Enter**. The note says **Cartridge: name**, and the Atari restarts into the cartridge."),
  stepOf("car")("Supported: standard 8 KB and 16 KB cartridges, Atarimax 128 KB and 1 MB (many newer games). Other types say **Cart type not yet**."),
  stepOf("car")("Choosing an .atr or .xex, or KEY0, takes the cartridge out again."),

  h2("Without BASIC"),
  stepOf("nobasic")("With a disk: in the browser press **Enter** on the .atr, then **F1** (No BASIC)."),
  stepOf("nobasic")("Without a disk: hold **Alt + F4** and press **KEY0**; keep holding until the screen comes up. (KEY0 also takes a disk out, so use the browser way for disks.)"),
  stepOf("nobasic")("Signs that a disk needs BASIC off: it hangs while starting or shows a half-drawn screen. Most disks for the old 400 / 800 need it; .xex files switch BASIC off by themselves."),

  h2("Snapshots"),
  stepOf("snap")("Press **F2**: the Atari stops. Type a name (letters / digits, up to 8) and press **Enter**: NAME.A8S is saved in the browser's current folder (64 KB file on the 800, 128 KB on the 130). Esc saves nothing. The Atari then runs on."),
  stepOf("snap")("To go back to that moment: **F12**, choose the .a8s, **Enter**. Memory, CPU and chip registers are restored and the program runs on from there."),
  stepOf("snap")("Load it on the same model (800 or 130) it was saved on. A cartridge game: load the same .car first, then the snapshot. A disk game that loads more later: if the note says **Loaded; disk was NAME**, put that disk in with Shift + Enter."),
  stepOf("snap")("Not kept: the exact position in the picture and the chips' internal counters; the program is back in step within a frame."),

  h2("60 Hz or 50 Hz"),
  stepOf("video")("LTari starts at 640x480, 60 Hz. If your monitor also accepts 50 Hz, **F8** shows the Atari's own 50 Hz with perfectly smooth scrolling; F8 again goes back to 60 Hz."),

  h2("Sound on Bluetooth headphones or a speaker"),
  stepOf("bt")("POKEY's sound goes to the 3.5 mm jack and, through the ESP32, to Bluetooth. Press **F3**, choose **Scan**, then the device, and Enter."),

  h2("Screenshots"),
  stepOf("shot")("Press **Print Screen**: the picture is saved as SCRNnnnn.BMP in the folder the browser shows (the card's top folder after a start)."),

  h1("The Atari keyboard on a USB keyboard"),
  p("Keys that the Atari has are on the same PC keys; the others are on keys at the same places as on the Atari:"),
  table([3420, 5940], ["USB key", "Atari key"], [
    ["Letters, digits, Return, Space, Tab, Esc, Caps Lock, Backspace", "The same keys (Backspace = Delete / Back S)"],
    ["- = ; , . /", "The same keys"],
    ["' (apostrophe)", "+  (Shift: \\)"],
    ["\\ (backslash)", "*  (Shift: ^)"],
    ["[ and ]", "< and >  (Shift: Clear / Insert line)"],
    ["` (back quote)", "Inverse video (the Atari logo key)"],
    ["Up / Down / Left / Right", "The cursor keys (Control + - = + *)"],
    ["Home", "Clear screen (Shift + <)"],
    ["Delete / Insert", "Delete / insert a character (Control + Back S / >)"],
    ["Shift, Ctrl", "Shift, Control"],
    ["Shift + 2 / Shift + 7 / Shift + 8", "\"  /  '  /  @   (as printed on the Atari)"],
  ]),

  h1("Good to know"),
  bullet("SD card: FAT32 or FAT16, not exFAT. The browser shows folders first, then files, up to 320 per folder."),
  bullet("The LTari 130 has 128 KB (the 130XE's extra 64 KB in banks of 16 KB); the LTari 800 has 64 KB."),
  bullet("The chips are new designs from the Atari documentation; some rare hardware tricks may still be missing (see LTari/README.md)."),
];

const doc = new Document({
  creator: "L",
  title: "LTari — keys",
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
