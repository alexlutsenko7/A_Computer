// build_doc.js -- docs/L_Build_and_Install.docx: building the FPGA images, assembling the one .jic,
// programming the board and the ESP32, the SD card (ROM files) and how the ROMs are used.
//   node build_doc.js ../L_Build_and_Install.docx
const fs = require("fs");
const {
  Document, Packer, Paragraph, TextRun, Table, TableRow, TableCell, WidthType,
  ShadingType, HeadingLevel, AlignmentType, LevelFormat, BorderStyle, Footer, PageNumber,
} = require("docx");

const W = 9360; // US Letter text width with 1" margins (DXA)
const FONT = "Calibri";
const border = { style: BorderStyle.SINGLE, size: 4, color: "A6A6A6" };
const borders = { top: border, bottom: border, left: border, right: border };

function runs(text, size = 21) {
  return text.split(/(\*\*[^*]+\*\*|`[^`]+`)/).filter(Boolean).map(t => {
    if (t.startsWith("**")) return new TextRun({ text: t.slice(2, -2), bold: true, font: FONT, size });
    if (t.startsWith("`"))  return new TextRun({ text: t.slice(1, -1), font: "Consolas", size: size - 2 });
    return new TextRun({ text: t, font: FONT, size });
  });
}
function cell(text, width, head = false) {
  const lines = Array.isArray(text) ? text : [text];
  return new TableCell({
    width: { size: width, type: WidthType.DXA }, borders,
    shading: head ? { type: ShadingType.CLEAR, color: "auto", fill: "1F3864" } : undefined,
    margins: { top: 60, bottom: 60, left: 100, right: 100 },
    children: lines.map(l => new Paragraph({
      children: head ? [new TextRun({ text: l, bold: true, color: "FFFFFF", font: FONT, size: 19 })] : runs(l, 19),
    })),
  });
}
function table(widths, header, rows) {
  if (widths.reduce((a, b) => a + b, 0) !== W) throw new Error("table widths");
  return new Table({
    width: { size: W, type: WidthType.DXA }, columnWidths: widths,
    rows: [new TableRow({ tableHeader: true, children: header.map((h, i) => cell(h, widths[i], true)) }),
           ...rows.map(r => new TableRow({ cantSplit: true, children: r.map((c, i) => cell(c, widths[i])) }))],
  });
}
const h1 = t => new Paragraph({ heading: HeadingLevel.HEADING_1, spacing: { before: 320, after: 120 }, children: [new TextRun({ text: t, font: FONT })] });
const h2 = t => new Paragraph({ heading: HeadingLevel.HEADING_2, spacing: { before: 220, after: 100 }, children: [new TextRun({ text: t, font: FONT })] });
const p  = t => new Paragraph({ spacing: { after: 110 }, children: runs(t) });
const b  = t => new Paragraph({ numbering: { reference: "bullets", level: 0 }, spacing: { after: 50 }, children: runs(t) });
const gap = () => new Paragraph({ spacing: { after: 60 }, children: [] });
// a block of commands: grey box, Consolas
function code(lines) {
  return new Table({
    width: { size: W, type: WidthType.DXA }, columnWidths: [W],
    rows: [new TableRow({ children: [new TableCell({
      width: { size: W, type: WidthType.DXA }, borders,
      shading: { type: ShadingType.CLEAR, color: "auto", fill: "F2F2F2" },
      margins: { top: 80, bottom: 80, left: 120, right: 120 },
      children: lines.map(l => new Paragraph({ children: [new TextRun({ text: l, font: "Consolas", size: 17 })] })),
    })] })],
  });
}
const procs = ["fpga", "jic", "prog", "esp", "card", "check", "upd", "loader"];
const numbering = {
  config: [
    { reference: "bullets", levels: [{ level: 0, format: LevelFormat.BULLET, text: "•", alignment: AlignmentType.LEFT,
      style: { paragraph: { indent: { left: 540, hanging: 270 } } } }] },
    ...procs.map(r => ({ reference: r, levels: [{ level: 0, format: LevelFormat.DECIMAL, text: "%1.", alignment: AlignmentType.LEFT,
      style: { paragraph: { indent: { left: 540, hanging: 300 } } } }] })),
  ],
};
const stepOf = ref => t => new Paragraph({ numbering: { reference: ref, level: 0 }, spacing: { after: 60 }, children: runs(t) });

const C = [];
C.push(new Paragraph({ spacing: { after: 60 }, children: [new TextRun({ text: "L — build and install", bold: true, size: 44, font: FONT, color: "1F3864" })] }));
C.push(new Paragraph({ spacing: { after: 240 }, children: [new TextRun({ text: "From the sources to a working board: the FPGA images, the one .jic file, the ESP32 firmware, the SD card and the ROMs (state of 30 October 2026)", size: 21, font: FONT, color: "595959" })] }));

// ------------------------------------------------------------------ 1
C.push(h1("1. What goes where"));
C.push(p("The finished system has three places that hold software. Each is built and loaded separately:"));
C.push(table([2300, 3500, 3560], ["Where", "What", "How it gets there"], [
  ["**Configuration flash** on the core board (W25Q64, 8 MB)", "The machine menu, both machines, the Spectrum ROMs; later the C64 ROMs", "One file, `AMenu/output_files/L.jic`, programmed over JTAG (USB-Blaster). The C64 ROMs are added by the ESP32 (section 6)."],
  ["**ESP32** (system controller on the I/O board)", "SD card loader, on-screen menus, ROM installer, Bluetooth audio", "The Arduino sketch `LSpectrum/esp32_v2`, uploaded over USB (section 4)."],
  ["**microSD card** (in the I/O board's socket, read by the ESP32)", "Games, tapes, disks, snapshots, and your own C64 ROM files", "Copied on a PC (section 5)."],
]));
C.push(gap());
C.push(p("At power-up the FPGA always loads the **machine menu** from flash address 0. Choosing a machine loads that machine's image (Cyclone IV remote update); **KEY1** or **Ctrl+Alt+Del** returns to the menu. Each machine copies its ROMs from the flash into the SDRAM every time it starts."));

C.push(h2("Flash layout"));
C.push(table([1700, 1700, 5960], ["Address", "Size", "Contents"], [
  ["0x000000", "~500 KB", "**AMenu**, the machine menu (factory image)"],
  ["0x100000", "~500 KB", "**LSpectrum**, ZX Spectrum 128K (application image)"],
  ["0x200000", "~500 KB", "**L64**, Commodore 64 (application image)"],
  ["0x300000", "~500 KB", "**LTari 800**, Atari 800XL (revision LTari800)"],
  ["0x400000", "~500 KB", "**LTari 130**, Atari 130XE (revision LTari)"],
  ["0x500000", "48 KB", "Spectrum ROMs: 128K ROM set + the F1 diagnostics slot (`LSpectrum/roms48k.hex`; the public copy has 48K BASIC there)"],
  ["0x540000", "28 KB", "LTari ROMs: AltirraOS + Altirra BASIC (free; `LTari/roms/atarirom.hex`)"],
  ["0x580000", "48 KB", "C64 ROMs: CHAR, BASIC, KERNAL and 1541 DOS. **Not in the .jic**: written by the ESP32 from your files on the SD card"],
  ["0x600000 ...", "free", "room for further machines"],
]));
C.push(gap());
C.push(p("Every image has a 1 MB slot, so boards with a larger FPGA use the same layout. The addresses are fixed in three places that must agree: the menu (`AMenu/rtl/AMenu.v`, parameter MACHINE_ADDR), the .cof file (`AMenu/L.cof`) and the machines' ROM loaders (`rom_loader.v` FLASH_ADDR: its default 0x500000 for the Spectrum, 0x580000 set in `c64_system.v`, 0x540000 in `atari_system.v`), plus the ESP32 (`update.cpp` slots, `c64.cpp` ROM_BASE) and `AMenu/tools/mk_update.py` (skipped C64 area, menu end). The two LTari images are two revisions of one project: LTari800 (0x300000, 800XL) and LTari (0x400000, 130XE)."));

// ------------------------------------------------------------------ 2
C.push(h1("2. Tools"));
C.push(table([3000, 6360], ["Tool", "Notes"], [
  ["**Quartus Prime 25.1std Lite** (Windows)", "Free edition; includes the Programmer and `quartus_cpf`. The scripts are written for WSL and call the Windows tools in `C:\\Altera\\quartus\\bin64`."],
  ["**USB-Blaster**", "JTAG cable to the core board's JTAG header."],
  ["**Arduino IDE / arduino-cli**", "Core **esp32 3.3.2** (Espressif), board **ESP32 Dev Module**, default partition scheme. `arduino-cli` comes with the Arduino IDE."],
  ["Arduino libraries", "**ESP32-A2DP 1.8.11** (Phil Schatzmann; not in the Library Manager: copy the GitHub release into the sketchbook's `libraries` folder) and **AAudioLinkFix** (copy `LSpectrum/esp32_v2/libraries/AAudioLinkFix` there too)."],
  ["Python 3 (optional)", "For the tools: `L64/tools/mk_c64rom.py` (a local C64 ROM image for tests), `mk_d64.py` (a test disk)."],
  ["Questa FSE (optional)", "Intel's free simulator, for the testbenches; not needed to build."],
]));

// ------------------------------------------------------------------ 3
C.push(h1("3. Building the FPGA images and the .jic"));
C.push(h2("3.1 The four Quartus projects"));
C.push(p("Each machine is its own Quartus project; LTari has two revisions (800 and 130). Compile all five (order does not matter); each produces a `.sof` in its `output_files` folder:"));
C.push(code([
  "cd AMenu      && quartus_sh --flow compile AMenu        # -> AMenu/output_files/AMenu.sof",
  "cd LSpectrum  && quartus_sh --flow compile LSpectrum    # -> LSpectrum/output_files/LSpectrum.sof",
  "cd L64    && quartus_sh --flow compile L64      # -> L64/output_files/L64.sof",
  "cd LTari   && quartus_sh --flow compile LTari     # -> LTari/output_files/LTari.sof (130XE)",
  "cd LTari   && quartus_sh --flow compile LTari -c LTari800   # -> LTari800.sof (800XL)",
]));
C.push(gap());
C.push(b("In the Quartus GUI: open the `.qpf`, Processing > Start Compilation."));
C.push(b("A compile takes a few minutes per project. Check that timing is met: the Timing Analyzer summary must show no negative slack (all are fully constrained)."));
C.push(b("All images are compiled for remote update (`STRATIXIII_UPDATE_MODE REMOTE` in the .qsf). Keep that setting: without it the menu cannot start the machine."));
C.push(b("The source files each project uses are listed in its `.qsf`. The machines share some files in `LSpectrum/rtl/` (SDRAM controller, ROM loader, tape loader, ESP32 link); LTari also uses L64's `c64_video.v` (OSD)."));

C.push(h2("3.2 Assembling the one .jic"));
C.push(p("The four `.sof` files (LTari's twice) and the Spectrum and Atari ROMs are combined into one JTAG Indirect Configuration file, as described by `AMenu/L.cof`:"));
C.push(code([
  "cd AMenu",
  "quartus_cpf -c L.cof        # -> output_files/L.jic  (+ output_files/L.map)",
]));
C.push(gap());
C.push(table([2900, 6460], ["Part of L.cof", "Setting"], [
  ["Device", "EPCS64 (the W25Q64 behaves as one), FPGA EP4CE15, Active Serial"],
  ["Page_0", "`output_files/AMenu.sof` at 0x000000"],
  ["Page_1", "`../LSpectrum/output_files/LSpectrum.sof`, start address 0x100000"],
  ["Page_2", "`../L64/output_files/L64.sof`, start address 0x200000"],
  ["Page_3", "`../LTari/output_files/LTari800.sof`, start address 0x300000"],
  ["Page_4", "`../LTari/output_files/LTari.sof`, start address 0x400000"],
  ["Hex data", "`../LSpectrum/roms48k.hex` at 0x500000 and `../LTari/roms/atarirom.hex` at 0x540000 (relative)"],
  ["Options", "EPCS ID check off; a .map file with the addresses"],
]));
C.push(gap());
C.push(p("`L.map` lists where each part ended up; compare it with the flash layout in section 1. In the Quartus GUI the same file is made with File > Convert Programming Files > Open Conversion Setup Data (`L.cof`) > Generate."));
C.push(p("The Spectrum ROM file `roms48k.hex` is part of the project (Amstrad allows the ROMs for emulator use). The .jic stores its bytes bit-reversed; the ROM loader recognises that by the first byte, so nothing has to be done."));

C.push(h2("3.3 Programming the board"));
C.push(stepOf("prog")("Connect the USB-Blaster to the core board's JTAG header and power the board."));
C.push(stepOf("prog")("Quartus Programmer: Hardware Setup = USB-Blaster, mode **JTAG**, Add File `AMenu/output_files/L.jic`, tick **Program/Configure** and **Verify**, Start, and wait for 100 % before touching the board or the cable. From the command line:"));
C.push(code(["quartus_pgm -c USB-Blaster -m JTAG -o \"ipv;AMenu/output_files/L.jic\""]));
C.push(p("Without Verify, an interrupted write is not noticed: the menu then reports **reason 08** (a CRC error in that machine's image) when the machine is chosen. Program the .jic again, with Verify."));
C.push(gap());
C.push(stepOf("prog")("The Programmer first loads a small flash loader into the FPGA, then writes the flash. When it reports success, **switch the board off and on**: the menu appears."));
C.push(p("For development, a single machine's `.sof` can be loaded straight into the FPGA over JTAG (it is lost at power-off). The flash is not touched; KEY1 then goes to the menu in the flash."));

// ------------------------------------------------------------------ 4
C.push(h1("4. The ESP32 firmware"));
C.push(p("The same firmware serves all machines: it waits for a machine's core ID on the SPI link (LSpectrum 5A580001, L64 43360001, LTari 41540001) and restarts whenever the machine changes."));
C.push(stepOf("esp")("Install the esp32 core 3.3.2 and the two libraries (section 2)."));
C.push(stepOf("esp")("Connect the ESP32 board by USB; note its COM port (COM10 on the development PC)."));
C.push(stepOf("esp")("Compile and upload, in the folder `LSpectrum/`:"));
C.push(code(["arduino-cli compile -b esp32:esp32:esp32 -u -p COM10 esp32"]));
C.push(gap());
C.push(p("Or open `LSpectrum/esp32_v2/esp32_v2.ino` in the Arduino IDE, board \"ESP32 Dev Module\", and Upload. (I/O board revision 1: `LSpectrum/esp32_v1/esp32_v1.ino`.) The sketch uses about 1.17 MB of the 1.25 MB app partition. A change in the ESP32 sources needs only this step; the FPGA flash stays as it is."));

// ------------------------------------------------------------------ 5
C.push(h1("5. The SD card"));
C.push(stepOf("card")("Use a microSD card formatted **FAT32** (or FAT16). exFAT is not supported: most cards above 32 GB come as exFAT and must be reformatted."));
C.push(stepOf("card")("For L64, make the folder **/ROMS/C64/** and copy your own Commodore ROM files into it (they are copyrighted and not part of the project; VICE, for example, comes with them):"));
C.push(table([2400, 1300, 5660], ["File name starts with", "Size", "Example (VICE)"], [
  ["**KERNAL**", "8 KB", "kernal-901227-03.bin"],
  ["**BASIC**", "8 KB", "basic-901226-01.bin"],
  ["**CHAR**", "4 KB", "chargen-901225-01.bin"],
  ["**DOS1541** or **1541**", "16 KB", "dos1541-325302-01+901229-05.bin (without it there is no disk drive)"],
]));
C.push(gap());
C.push(stepOf("card")("Put games anywhere on the card, in folders as you like (up to 320 entries per folder): Spectrum .tap / .tzx / .z80, C64 .d64 / .prg / .t64 / .tap / .a64. Saved tapes and snapshots are written into the folder the browser is in."));
C.push(p("The Spectrum needs nothing on the card to start; its ROMs are in the .jic. The card can be inserted or changed at any time (the browser reads it again)."));
C.push(code([
  "SD card (FAT32)",
  "├── ROMS/",
  "│   └── C64/",
  "│       ├── kernal-901227-03.bin",
  "│       ├── basic-901226-01.bin",
  "│       ├── chargen-901225-01.bin",
  "│       └── dos1541-325302-01+901229-05.bin",
  "├── Spectrum/ ...      (.tap .tzx .z80, any folder names)",
  "└── C64/ ...           (.d64 .prg .t64 .tap .a64)",
]));

// ------------------------------------------------------------------ 6
C.push(h1("6. How the ROMs are used"));
C.push(h2("6.1 ZX Spectrum"));
C.push(b("The 128K ROMs and the F1 diagnostics slot are in the flash at 0x500000 (from the .jic). The public image has a copy of the 48K BASIC ROM in that slot (DiagROM's licence is not known); `LSpectrum/tools/mk_roms48k.py` builds it with your own DiagROM."));
C.push(b("At every start and reset (power-up via the menu, KEY0) the FPGA's ROM loader copies the 48 KB from the flash into the SDRAM, then starts the Z80. F1 held at that moment selects the diagnostics slot."));
C.push(b("If the flash holds no ROM image (first byte wrong), the board LED blinks fast: program the .jic."));
C.push(h2("6.2 Commodore 64"));
C.push(stepOf("check")("When L64 starts, its ROM loader copies 48 KB from flash 0x580000 into the SDRAM (CHAR, BASIC, KERNAL) and the 1541 DOS ROM into the drive's own memory. The image starts with the header \"L64 ROMS\"; byte 13 says whether a 1541 ROM is included."));
C.push(stepOf("check")("The ESP32 checks that header. **If the flash has no C64 ROMs yet**, it shows \"No ROMs in the flash yet\", reads KERNAL*, BASIC*, CHAR* and DOS1541* / 1541* from /ROMS/C64/, builds the 48 KB image, writes it into the flash through the FPGA (flash pass-through, sector erase + page program), reads it back to verify, and tells the FPGA to reload: the C64 starts with its ROMs. This takes a few seconds and happens once."));
C.push(stepOf("check")("From then on L64 starts **without the SD card**: the ROMs come from the flash every time L64 is started and after KEY0."));
C.push(stepOf("check")("If the files are missing, the screen says where to put them; add them and press KEY0. Without a DOS1541 file the C64 works but has no disk drive (DEVICE NOT PRESENT); the board LED blinks fast while there is no ROM image at all."));
C.push(p("**Changing the C64 ROMs later** (for example adding the 1541 ROM afterwards) is not automatic yet: the ESP32 installs only when the flash has no C64 ROMs. To make it install again, erase the flash before programming the .jic (Programmer: tick **Erase** as well as Program/Configure), or erase only the sectors at 0x200000; at the next L64 start the files are installed from the card. Keep the ROM files on the card for that reason."));
C.push(p("For local tests only, `L64/tools/mk_c64rom.py KERNAL BASIC CHAR [DOS1541] OUT` makes the same 48 KB image as Intel HEX (to add to a private copy of the .cof at 0x580000) and as a .mem file for the simulation. Such files contain the Commodore ROMs: keep them in the git-ignored `L64/roms_local/` and never publish a .jic that contains them."));

// ------------------------------------------------------------------ 7, 8
C.push(h1("7. Updating from the SD card (LUPDATE.BIN)"));
C.push(p("A board with the machine menu of 30 October 2026 or later updates itself from the card; no USB-Blaster is needed. The update file `LUPDATE.BIN` has the same contents as `L.jic`."));
C.push(stepOf("upd")("Copy `LUPDATE.BIN` to the **root folder** of the SD card and put the card in."));
C.push(stepOf("upd")("Switch the board on. While the machine menu is shown, the ESP32 finds the file and checks it (header and a CRC-32 over the whole image). The screen shows **L update** with a progress bar; the menu takes no keys meanwhile. **Do not switch off.**"));
C.push(stepOf("upd")("The ESP32 compares the flash with the file in 4 KB sectors and rewrites only those that differ, each read back: the machines first, the menu last. A small change takes a few minutes of checking and seconds of writing; a full install about 3-4 minutes."));
C.push(stepOf("upd")("When everything checked out, the ESP32 **deletes LUPDATE.BIN**. If the menu itself changed, the screen says **Switch the board off and on**; otherwise the menu comes back and the new machines start at once."));
C.push(table([3000, 6360], ["Situation", "What happens"], [
  ["The file is damaged or not an update file", "\"not a valid update file\": nothing is written, the file stays"],
  ["The power fails during the update", "The file is still on the card; the update runs again at the next start and finishes the job"],
  ["The power fails while the menu's own sectors are written", "The only risky moment (only when the menu changed, written last): the board may need the USB-Blaster and `L.jic` again"],
  ["The flash is already up to date", "Nothing is written; \"(the flash was up to date)\"; the file is deleted"],
  ["C64 ROMs installed by the ESP32", "Never touched (flash 0x580000-0x5FFFFF is skipped)"],
]));
C.push(gap());
C.push(p("Making the file, after building the images (section 3), in `AMenu/`:"));
C.push(code(["python3 tools/mk_update.py --label \"L 2026-10-30\"     # -> output_files/LUPDATE.BIN"]));
C.push(p("The tool converts `L.cof` into a raw flash image (.pof -> .rpd, the flash contents byte for byte) and writes it after a 256-byte header: \"LUPDATE1\", the image length, its CRC-32, the skipped range (the C64 ROM area), the end of the menu's area and the label shown during the update. The ESP32 code is `LSpectrum/esp32_v2/src/update.cpp`; its PC test (`esp32_v2/test/update_test.cpp`, part of `run_host_test.sh`) runs updates against a flash model, including power cuts at random moments."));

C.push(h1("8. Boards shipped with the loader"));
C.push(p("`AMenu/output_files/L_loader.jic` holds only the machine menu (the rest of the flash blank): no machines and no ROMs. A board can be passed on with it, and the user installs everything from the public release."));
C.push(stepOf("loader")("Make it in `AMenu/`: `python3 tools/mk_update.py --loader`."));
C.push(stepOf("loader")("Program `L_loader.jic` as in 3.3. It holds the menu and blank data up to the end of the 8 MB flash: the Programmer erases only where a .jic has data (its Erase option did not clear old machines on hardware), so this file wipes a used board completely, C64 ROMs included. Then the ESP32 firmware as in section 4."));
C.push(stepOf("loader")("At power-up the board shows **No machines installed. Copy LUPDATE.BIN to the SD card's root folder.** It looks at the card every 2 seconds."));
C.push(stepOf("loader")("The user copies `LUPDATE.BIN` from the repository (`AMenu/output_files/`) to the card: the update installs all machines and the Spectrum / Atari ROMs (section 7). For L64 the user adds the C64 ROM files as in section 5."));

// ------------------------------------------------------------------ 9
C.push(h1("9. Checklist after installing"));
C.push(table([3800, 5560], ["Check", "Expected"], [
  ["Power on", "The machine menu: LSpectrum, L64, LTari 800, LTari 130"],
  ["Start LSpectrum (1)", "The 128K menu; F12 shows the card's files (the ESP32 answers)"],
  ["KEY1, then start L64 (2)", "First time: \"No ROMs in the flash yet\", installing, then the BASIC screen; later: the BASIC screen at once, 38911 BASIC BYTES FREE"],
  ["F12 in L64, a .d64, Enter", "LOAD\"*\",8,1 is typed, the drive LED (board LED) is on, the program loads in turbo"],
  ["Ctrl+Alt+Del, then start LTari 130 (4)", "Blue screen, then \"Altirra 8K BASIC 1.59\" and Ready"],
  ["F8", "The picture switches between 60 Hz (640x480) and 50 Hz (720x576)"],
  ["F3", "The Bluetooth menu (the ESP32's Bluetooth part answers)"],
]));
C.push(gap());
C.push(p("Licences, our own work and the same build steps in one file: `BUILDING_AND_LICENSES.md` in the repository root. Keys and usage of each machine: `docs/LSpectrum_Keys.docx`, `docs/L64_Keys.docx` and `docs/LTari_Keys.docx`. Wiring of the boards: `docs/LSpectrum_Connection.docx`. Third-party parts and licences: `docs/L_Third_Party.docx`."));

const doc = new Document({
  creator: "L",
  title: "L — build and install",
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
    children: C,
  }],
});

Packer.toBuffer(doc).then(buf => { fs.writeFileSync(process.argv[2], buf); console.log("written", process.argv[2], buf.length); });
