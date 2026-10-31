const fs = require("fs");
const {
  Document, Packer, Paragraph, TextRun, Table, TableRow, TableCell, WidthType,
  ShadingType, HeadingLevel, AlignmentType, LevelFormat, BorderStyle,
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
  return new Table({
    width: { size: W, type: WidthType.DXA },
    columnWidths: widths,
    rows: [
      new TableRow({ tableHeader: true, children: header.map((h, i) => cell(h, widths[i], true)) }),
      ...rows.map(r => new TableRow({ children: r.map((c, i) => cell(c, widths[i])) })),
    ],
  });
}

const h1 = t => new Paragraph({ heading: HeadingLevel.HEADING_1, spacing: { before: 300, after: 120 }, children: [new TextRun({ text: t, font: FONT })] });
const h2 = t => new Paragraph({ heading: HeadingLevel.HEADING_2, spacing: { before: 240, after: 100 }, children: [new TextRun({ text: t, font: FONT })] });
const p = t => new Paragraph({ spacing: { after: 100 }, children: runs(t, { size: 21 }) });
const step = t => new Paragraph({ numbering: { reference: "steps", level: 0 }, spacing: { after: 60 }, children: runs(t, { size: 21 }) });
const bullet = t => new Paragraph({ numbering: { reference: "bullets", level: 0 }, spacing: { after: 60 }, children: runs(t, { size: 21 }) });
const gap = () => new Paragraph({ spacing: { after: 60 }, children: [] });

// numbering instances: each procedure restarts at 1
const procs = ["load", "multi", "rewind", "save", "snapsave", "snapload", "border", "diag", "reset", "bt"];
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
  new Paragraph({ spacing: { after: 60 }, children: [new TextRun({ text: "LSpectrum — extra keys", bold: true, size: 40, font: FONT, color: "1F3864" })] }),
  new Paragraph({ spacing: { after: 240 }, children: [new TextRun({ text: "ZX Spectrum 128K on the QMTECH Cyclone IV board, with the SD card tape loader, snapshots, memory contention and Bluetooth audio (build of 13 October 2026)", size: 21, font: FONT, color: "595959" })] }),

  p("All keys below are on the USB keyboard unless a board button is named. Keys that the Spectrum itself uses (letters, digits, Enter, Space, Shift) work as on a real 128K and are listed at the end."),

  h1("Machine keys"),
  table([2234, 2816, 4310], ["Key", "What it does", "Notes"], [
    ["**F1** (held while the Spectrum starts)", "Starts DiagROM (test ROM) instead of the 128K ROM",
      ["Only read at the moment the Spectrum starts: at power-up, after KEY0, or when it is chosen in the machine menu. Holding F1 later does nothing.",
       "Keep holding F1 until the DiagROM screen appears. See \"Starting the test ROM\" below."]],
    ["**F2**", "Saves a snapshot of the whole machine as a .z80 file",
      ["The Spectrum stops at once and asks for a name. See \"Saving and loading snapshots\" below."]],
    ["**F3**", "Opens the Bluetooth audio menu",
      ["For Bluetooth headphones or a speaker (through the ESP32 board). Scan, connect, PIN, volume. F3 or Esc closes it; a tape that is playing goes on. See \"Sound on Bluetooth headphones or a speaker\" below."]],
    ["**F4**", "Opens the joystick menu",
      ["Chooses what the two joystick sockets are: **Kempston** on both (default; most games), **Kempston + Cursor** (second socket = keys 5 6 7 8 and 0 for fire, for Cursor / Protek / AGF games), or **Interface 2** (first socket = Sinclair 1, keys 6-0; second = Sinclair 2, keys 1-5; for two-player games and the 128K +2 menus). Up/Down, Enter selects, F4 or Esc closes; shows \"Joystick: ...\" for 4 seconds. Back to Kempston after KEY0 or power-up."]],
    ["**F5**", "Switches memory contention on (default) / off",
      ["Contention is the slowing of the processor while the screen is drawn, as on a real Spectrum; timing-critical games and border effects need it. F5 also switches the floating bus (port FF reads the screen, as on the real machine; a few games use it, e.g. Sidewize, Arkanoid and Cobra, and stop with F5 off). Shows \"Contention: on\" or \"off\" for 4 seconds. Back to on after KEY0 or power-up. Never active in turbo."]],
    ["**F6**", "Switches tape loading and saving between turbo (default) and normal speed",
      ["Shows \"Speed: normal\" or \"Speed: turbo\" on the bottom row for 2 seconds. Works at any time; a tape that is playing or a block being saved changes speed at once. Back to turbo after KEY0 or power-up."]],
    ["**F8**", "Swaps the video between 50 Hz (720x576) and 60 Hz (640x480)",
      ["Each press swaps. The choice survives KEY0. At power-up and after the machine menu the video is always 60 Hz (640x480), which every monitor accepts; not all monitors accept the 50 Hz mode.",
       "Border effects (stripes in the border that line up with the picture) only work in the 50 Hz mode."]],
    ["**Page Up** / **Page Down** (browser closed)", "Moves the frame interrupt 1/8 line earlier / later (50 Hz mode)",
      ["Lines up border effects with the picture: Page Down moves them down. Shows \"Frame INT: 24.1\" (line.eighth) for 4 seconds; 24.1 is the default, measured with Aquaplane. Back to 24.1 after KEY0 or power-up. With the browser open these keys page through the list."]],
    ["**KEY0** (board button W13)", "Resets everything, including the SD tape loader", ["The video mode is kept. The ESP32 restarts with it; Bluetooth headphones reconnect after a few seconds."]],
    ["**Ctrl + Alt + Del**, or KEY1 (board button Y13)", "Back to the machine menu", ["Ctrl + Alt + Del acts when the keys are released. The FPGA loads the menu that appears at power-up (choose a machine with Up/Down + Enter, its digit, or a joystick); no board button is needed. The Spectrum's state is lost; the ESP32 restarts by itself when a machine is started again."]],
  ]),

  h1("SD tape loader keys"),
  p("The loader shows a file browser over the Spectrum picture (white on blue). Every action has a numpad key and an F-key, so keyboards without a numpad work too. While the browser is open the Spectrum sees no keys at all."),
  table([2816, 3272, 3272], ["Key", "Browser closed", "Browser open"], [
    ["**F12**, keypad **/** or **NumLock**", "Opens the browser; while recording: stops recording", "Closes the browser"],
    ["Keypad **8** / **2**, **F9** / **F10**, **Up** / **Down**", "(Up / Down go to the Spectrum as cursor keys)", "Moves the selection up / down (held: repeats)"],
    ["Keypad **4** / **6**, **Left** / **Right**, **Page Up** / **Page Down**", "(Left / Right go to the Spectrum)", "One page (20 lines) up / down; held: repeats"],
    ["**Enter**, keypad **Enter**", "(goes to the Spectrum)", "Plays the selected tape, loads the selected .z80 snapshot, or opens the folder"],
    ["**F11**", "Pauses / continues the tape", "Same as Enter"],
    ["Keypad **5**", "Pauses / continues the tape", "Pauses / continues the tape"],
    ["Keypad **-**", "Goes back one block on the tape", "Goes back one block on the tape"],
    ["**F7**, keypad *", "Stops the tape: normal speed and normal EAR again, nothing shown on screen", "Stops the tape"],
    ["**Esc**, **Backspace**", "(Esc = BREAK, Backspace = DELETE on the Spectrum)", "Goes up one folder; in the top folder closes the browser"],
    ["**F2**", "Saves a snapshot into the folder the browser was last in", "Saves a snapshot into this folder, then closes the browser"],
  ]),
  gap(),
  p("The browser stays on screen until you let go of the key that closed it, so the Spectrum never sees that Enter or Esc (Esc would be BREAK)."),

  h2("Name keys"),
  p("After choosing [Save to this folder] in the browser, or after F2:"),
  table([2816, 6544], ["Key", "Action"], [
    ["Letters, digits, **-**, **_**", "Type the name (up to 8 characters; .TAP or .Z80 is added)"],
    ["**Backspace**", "Deletes the last character"],
    ["**Enter**", "Starts recording / saves the snapshot"],
    ["**Esc**", "Back to the browser / no snapshot, the Spectrum runs on"],
  ]),
  gap(),
  p("While recording, **F12** (or **F7**) stops recording and closes the file; the browser cannot be opened then."),

  h1("Usage cases"),

  h2("Loading a game"),
  stepOf("load")("Make the Spectrum wait for a tape: choose **Tape Loader** in the 128K menu, or type **LOAD \"\"** and press Enter."),
  stepOf("load")("Press **F12**. The browser shows the folders and the .tap / .tzx files of the SD card."),
  stepOf("load")("Pick the file (arrows, keypad 8/2) and press **Enter**. The browser closes and the tape starts."),
  stepOf("load")("While the tape plays, the Spectrum runs at 28 MHz (8 times faster) and the board LED is on. At the end of the tape it goes back to normal speed by itself. Press **F6** before (or during) loading to load at the normal speed instead."),

  h2("Multi-load games and \"stop the tape\" blocks"),
  stepOf("multi")("Some TZX files stop the tape between parts. The bottom row then shows **Tape stopped (5=go on)** and the speed returns to normal."),
  stepOf("multi")("When the game asks for the next part, press keypad **5** (or **F11**). Loading continues where it stopped."),

  h2("A loading error, or starting a block again"),
  stepOf("rewind")("Press keypad **5** to pause the tape. The bottom row shows **Paused, block N**."),
  stepOf("rewind")("Press keypad **-** once for every block you want to go back."),
  stepOf("rewind")("Make the Spectrum wait for the tape again (for example LOAD \"\"), then press keypad **5** to play from that block."),

  h2("Saving programs"),
  stepOf("save")("Press **F12**, go into the folder you want, and choose the first line **[Save to this folder]**."),
  stepOf("save")("Type a name, or keep the suggested **SAVEnnnn**, and press **Enter**. The browser closes and recording starts; the bottom row shows **Rec NAME.TAP: 0 F12=stop**."),
  stepOf("save")("Save on the Spectrum as often as you like, for example **SAVE \"game\"**, **SAVE \"pic\" SCREEN$** or **SAVE \"code\" CODE 32768,1000**. Every block goes into this one file. Blocks are saved at 8 times the speed; in between the Spectrum runs normally."),
  stepOf("save")("Press **F12** to stop. The bottom row shows **Saved NAME.TAP (n blocks)**. If nothing was saved, the empty file is removed."),
  p("To load it back: F12, choose the file, Enter (after LOAD \"\" as usual). Only the ROM's standard save format is recognised."),

  h2("Saving and loading snapshots"),
  p("A snapshot is the whole machine at one moment: memory, processor, sound chip, border. Load it later and the program goes on from exactly there, for example a game at level 5."),
  stepOf("snapsave")("At the moment you want to keep, press **F2**. The Spectrum stops at once (the sound goes quiet) and asks for a name."),
  stepOf("snapsave")("Type a name (up to 8 letters or digits) and press **Enter**. The file NAME.Z80 is written into the folder the browser was last in (the top folder after power-up; to save elsewhere, open the browser with F12, go into the folder, then press F2 there)."),
  stepOf("snapsave")("After about a second the Spectrum runs on exactly where it stopped, and the bottom row shows **Saved NAME.Z80**. Esc instead of Enter saves nothing."),
  stepOf("snapload")("Press **F12**, choose the .z80 file and press **Enter**. No LOAD \"\" is needed: the program starts at once from the saved moment."),
  stepOf("snapload")("Snapshots from emulators work too: .z80 files of 48K and 128K programs. 48K programs run in 48K mode, as on a real 128."),
  p("A name that already exists is refused: choose another. F2 does nothing while the tape recorder is recording (press F12 first). Loading a snapshot stops a tape that is playing."),

  h2("Border effects in the wrong place"),
  p("Some games draw stripes in the border at a fixed moment, for example the horizon in Aquaplane. They only line up with the picture in the 50 Hz mode."),
  stepOf("border")("Press **F8** once for the 50 Hz mode (720x576), then load the game."),
  stepOf("border")("If the border stripe sits above or below where the game draws it, press **Page Down** (stripe moves down) or **Page Up** (up), with the browser closed, until it lines up. Each press moves it 1/8 line; the bottom row shows the position."),
  stepOf("border")("Note the number shown. The setting goes back to 24.1 after KEY0 or power-up."),

  h2("Starting the test ROM (DiagROM)"),
  stepOf("diag")("Press and hold **F1**."),
  stepOf("diag")("While holding F1: switch the board on, or press **KEY0**, or choose LSpectrum in the machine menu."),
  stepOf("diag")("Keep holding F1 until the DiagROM screen appears, then let go."),
  stepOf("diag")("To get back to the normal 128K ROM, restart without holding F1 (KEY0, or Ctrl + Alt + Del and the menu)."),
  p("At power-up the Spectrum waits up to 1.5 seconds for the keyboard so that a held F1 is seen. If DiagROM still does not start, keep holding F1 and press KEY0: that always works."),

  h2("Stopping a tape completely"),
  p("Press **F7** (or keypad *) at any time. The tape stops, the Spectrum goes back to normal speed, the status row disappears and the tape position is forgotten. To play the file again, choose it in the browser (F12): it starts from the beginning. Pause (keypad 5) is different: it keeps the position and shows a status row."),

  h2("Resetting"),
  stepOf("reset")("**KEY0**: everything restarts, including the tape loader (the SD card is read again)."),
  stepOf("reset")("**Ctrl + Alt + Del**: back to the machine menu; choosing LSpectrum there starts it as at power-up."),

  h2("Sound on Bluetooth headphones or a speaker"),
  p("The Spectrum's sound (AY and beeper) also goes to an ESP32 board wired to the FPGA board (see LSpectrum_Connection.docx), which sends it to Bluetooth headphones or a speaker. Everything is done from the **F3** menu; the ESP32 remembers the device and reconnects by itself when both are switched on."),
  stepOf("bt")("Put the headphones or speaker into pairing mode."),
  stepOf("bt")("Press **F3**. The second line shows the state (Not connected / Connected: name)."),
  stepOf("bt")("Choose **Scan for devices** and press **Enter**. After a few seconds the devices found are listed at the bottom (an old device may show (no name))."),
  stepOf("bt")("Move down to the device and press **Enter**. The second line changes to **Connected: name**."),
  stepOf("bt")("Press **F3** (or Esc) to close the menu."),
  p("Other lines of the menu: **Disconnect**; **Forget the device** (it will not reconnect by itself); **PIN** (Enter, type the code, Enter; empty = auto); **Volume** (Left / Right); **Sound: Spectrum / test tone** (Enter swaps; the test tone checks the Bluetooth side alone)."),
  p("Old devices that need a PIN code are paired automatically with 0000, 1234, 8888 and 1111 in turn (one try per connection attempt, about 20 seconds each; the bottom line shows the PIN being tried). If the device uses another code, set it under PIN before connecting. Bluetooth adds about 0.2 s of delay: fine for music, noticeable in fast games. If the menu says **No answer from the ESP32**, check its power and the wires."),

  h1("Good to know"),
  bullet("SD card: FAT32 or FAT16. exFAT does not work (most cards larger than 32 GB come as exFAT: format them as FAT32)."),
  bullet("Folders work. The browser shows folders first, then files, sorted by name, up to 320 per folder; long names are shown up to 27 characters."),
  bullet("Unmodified .tap and .tzx files are played and .z80 snapshots are loaded; no conversion on the PC is needed."),
  bullet("If the browser says **No SD card, or not FAT16/FAT32**, insert the card and press Enter to try again."),

  h1("Spectrum keys on the USB keyboard"),
  table([3108, 6252], ["USB key", "Spectrum key"], [
    ["Letters, digits, Enter, Space", "The same keys"],
    ["Left Shift", "CAPS SHIFT"],
    ["Right Shift or Ctrl", "SYMBOL SHIFT"],
    ["Backspace", "DELETE (CAPS SHIFT + 0)"],
    ["Arrow keys", "Cursor keys (CAPS SHIFT + 5 / 6 / 7 / 8)"],
    ["Esc", "BREAK (CAPS SHIFT + SPACE)"],
  ]),
];

const doc = new Document({
  creator: "L",
  title: "LSpectrum — extra keys",
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
    children,
  }],
});

Packer.toBuffer(doc).then(b => { fs.writeFileSync(process.argv[2], b); console.log("written", process.argv[2], b.length); });
