// build_doc.js -- docs/L_Build_and_Install.docx: building the FPGA images, the one .jic and the machine files,
// programming the board and the ESP32, the SD card, how the ROMs are used, installing and updating from the card.
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
C.push(new Paragraph({ spacing: { after: 240 }, children: [new TextRun({ text: "From the sources to a working board: the FPGA images, the one .jic file, the machine files, the ESP32 firmware, the SD card and the ROMs (state of 20 November 2026)", size: 21, font: FONT, color: "595959" })] }));

// ------------------------------------------------------------------ 1
C.push(h1("1. What goes where"));
C.push(p("The finished system has three places that hold software. Each is built and loaded separately:"));
C.push(table([2300, 3500, 3560], ["Where", "What", "How it gets there"], [
  ["**Configuration flash** on the core board (W25Q64, 8 MB)", "The machine menu and three machines, each with its ROM area", "One file, `AMenu/<board>/output_files/L.jic`, programmed over JTAG (USB-Blaster). Any of the three machines is replaced from the SD card (section 7). The C64 ROMs are added by the ESP32 (section 6)."],
  ["**ESP32** (system controller on the I/O board)", "SD card loader, on-screen menus, machine and ROM installer, Bluetooth audio", "The Arduino sketch `ESP32/v2` (I/O board revision 2) or `ESP32/v1` (revision 1), uploaded over USB (section 4)."],
  ["**microSD card** (in the I/O board's socket, read by the ESP32)", "Games, tapes, disks, cartridges, snapshots, the machine files, your own C64 ROM files, the Spectrum Next's files", "Copied on a PC (section 5)."],
]));
C.push(gap());
C.push(p("At power-up the FPGA always loads the **machine menu** from flash address 0. Choosing a machine loads that machine's image (remote update); **KEY1** or **Ctrl+Alt+Del** returns to the menu. A machine with ROMs copies them from the flash into the SDRAM every time it starts."));

C.push(h2("The machines"));
C.push(table([1500, 2700, 1560, 3600], ["Machine", "What it is", "Core boards", "ROMs"], [
  ["**LSpectrum**", "ZX Spectrum 128K", "EP4CE15, 10CL025", "In its machine file: the 128K ROM set + the F1 slot (48 KB)"],
  ["**L64**", "Commodore 64 with a 1541 drive", "EP4CE15, 10CL025", "**Not included**: written by the ESP32 from your files on the SD card"],
  ["**LTari 800**", "Atari 800XL (revision LTari800)", "EP4CE15, 10CL025", "In its machine file: AltirraOS + Altirra BASIC (free)"],
  ["**LTari 130**", "Atari 130XE (revision LTari)", "EP4CE15, 10CL025", "As LTari 800"],
  ["**LNES**", "Nintendo Entertainment System (NTSC)", "EP4CE15, 10CL025", "None: a game is loaded into the SDRAM"],
  ["**LMega**", "Sega Mega Drive / Genesis", "**10CL025 only**", "None: a game is loaded into the SDRAM"],
  ["**LNext**", "ZX Spectrum Next", "**10CL025 only**", "None in the flash: the Next starts from its own files on the SD card (folder `ZXNEXT`)"],
]));
C.push(gap());
C.push(p("LMega (about 17,600 logic elements) and LNext (about 18,300, and every block RAM of the FPGA) do not fit the EP4CE15 (15,408 logic elements): they exist for the 10CL025 board only."));

C.push(h2("Flash layout"));
C.push(table([1700, 1700, 5960], ["Address", "Size", "Contents"], [
  ["0x000000", "1 MB", "**AMenu**, the machine menu (factory image, loaded at power-up)"],
  ["0x100000", "1 MB", "Position 1: the machine's bitstream (application image)"],
  ["0x200000", "1 MB", "Position 1: its ROM area"],
  ["0x300000", "1 MB", "Position 2: bitstream"],
  ["0x400000", "1 MB", "Position 2: ROM area"],
  ["0x500000", "1 MB", "Position 3: bitstream"],
  ["0x600000", "1 MB", "Position 3: ROM area"],
  ["0x700000", "1 MB", "Not used"],
]));
C.push(gap());
C.push(p("The flash holds the menu and **three positions of 2 MB**. A position is one machine: its bitstream in the first megabyte, its ROM area in the second. Which machine sits in a position is not fixed: `L.jic` puts LSpectrum, L64 and LTari 800 there, and every machine is also a **machine file** (`.LMC`) that the menu installs from the SD card into a position you choose (section 7)."));
C.push(p("A ROM area starts with the machine's **info sector** (4 KB); the ROM image follows at + 0x1000:"));
C.push(table([1700, 7660], ["Offset", "Contents"], [
  ["0x00", "Tag `A5 5A <machine byte> <its complement>`: 18 = LSpectrum, 24 = L64, 42 = LTari (both models), 66 = LNES, 3C = LMega, 7E = LNext"],
  ["0x04", "Core ID, 4 bytes, high byte first"],
  ["0x08", "Core board (1 = EP4CE15, 2 = 10CL025); 0x09 flags (bit 0: the ROMs are the user's own, installed by the ESP32)"],
  ["0x10", "The menu line, 29 characters"],
  ["0x30", "Label (version), 32 bytes"],
]));
C.push(gap());
C.push(b("A machine cannot read which address it was started from. Its ROM loader (`LSpectrum/ep4_ce15/rtl/rom_loader.v`) looks at the start of the three ROM areas for its tag and loads the ROM image behind the first one that has it."));
C.push(b("The menu reads the tag and the menu line of each position (`AMenu/ep4_ce15/rtl/menu_names.v`); a position without the tag is shown as \"(empty)\"."));
C.push(b("The positions' addresses are fixed in four places that must agree: the menu (`AMenu/ep4_ce15/rtl/AMenu.v`, parameters MACHINE_ADDR and ROM_AREAS), the ROM loader (`rom_loader.v`, ROM_AREAS), `AMenu/ep4_ce15/tools/mk_flash.py` and the ESP32 (`g_aui32_slot` in `update.cpp`)."));

// ------------------------------------------------------------------ 2
C.push(h1("2. Tools"));
C.push(table([3000, 6360], ["Tool", "Notes"], [
  ["**Quartus Prime 25.1std Lite** (Windows)", "Free edition; includes the Programmer and `quartus_cpf`. The scripts are written for WSL and call the Windows tools in `C:\\Altera\\quartus\\bin64`. The 10CL025 board needs the Cyclone 10 LP device support (Tools > Install Devices)."],
  ["**USB-Blaster**", "JTAG cable to the core board's JTAG header."],
  ["**Arduino IDE / arduino-cli**", "Core **esp32 3.3.2** (Espressif), board **ESP32 Dev Module**. I/O board revision 1: default partition scheme. Revision 2: PSRAM enabled, flash size 16 MB, partition scheme \"16M Flash (3MB APP/9.9MB FATFS)\" (section 4). `arduino-cli` comes with the Arduino IDE."],
  ["Arduino libraries", "**ESP32-A2DP 1.8.11** (Phil Schatzmann; not in the Library Manager: copy the GitHub release into the sketchbook's `libraries` folder) and **AAudioLinkFix** (copy `ESP32/v2/libraries/AAudioLinkFix` there too)."],
  ["Python 3", "`AMenu/ep4_ce15/tools/mk_flash.py` and `mk_update.py` (the .jic, the machine files, the menu update), `tools/mk_10cl025_qsf.py` (the 10CL025 projects), and the machines' own tools (ROM images, tables, test disks)."],
  ["Questa FSE (optional)", "Intel's free simulator, for the testbenches; not needed to build."],
]));

// ------------------------------------------------------------------ 3
C.push(h1("3. Building the FPGA images and the .jic"));
C.push(h2("3.1 The Quartus projects"));
C.push(p("Every project folder (AMenu, LSpectrum, L64, LTari, LNES) has one subfolder per core board: `ep4_ce15/` for the QMTECH Cyclone IV EP4CE15 board, with all sources, simulations and tools, and `10cl025/` for the QMTECH Cyclone 10 LP 10CL025 board (section 3.4). LMega and LNext have a `10cl025/` folder only, which also holds their sources. This section builds for the EP4CE15 board."));
C.push(p("Each machine is its own Quartus project; LTari has two revisions (800 and 130). Compile all six (order does not matter); each produces a `.sof` in its `output_files` folder:"));
C.push(code([
  "cd AMenu/ep4_ce15     && quartus_sh --flow compile AMenu               # -> output_files/AMenu.sof",
  "cd LSpectrum/ep4_ce15 && quartus_sh --flow compile LSpectrum           # -> output_files/LSpectrum.sof",
  "cd L64/ep4_ce15       && quartus_sh --flow compile L64                 # -> output_files/L64.sof",
  "cd LTari/ep4_ce15     && quartus_sh --flow compile LTari               # -> output_files/LTari.sof (130XE)",
  "cd LTari/ep4_ce15     && quartus_sh --flow compile LTari -c LTari800   # -> output_files/LTari800.sof (800XL)",
  "cd LNES/ep4_ce15      && quartus_sh --flow compile LNES                # -> output_files/LNES.sof",
]));
C.push(gap());
C.push(b("In the Quartus GUI: open the `.qpf`, Processing > Start Compilation."));
C.push(b("A compile takes a few minutes per project. Check that timing is met: the Timing Analyzer summary must show no negative slack (all are fully constrained). L64 fills 97 % of the EP4CE15 and uses a fixed fitter seed in `L64.qsf`."));
C.push(b("All images are compiled for remote update (`STRATIXIII_UPDATE_MODE REMOTE` in the .qsf). Keep that setting: without it the menu cannot start the machine."));
C.push(b("The source files each project uses are listed in its `.qsf`. The machines share some files in `LSpectrum/ep4_ce15/rtl/` (SDRAM controller, ROM loader, tape loader, ESP32 link); LTari and LNES also use L64's `c64_video.v` (OSD)."));

C.push(h2("3.2 The .jic and the machine files"));
C.push(p("One tool composes the flash contents from the `.sof` files and the ROM images. Run it in the `AMenu` folder of the core board:"));
C.push(code([
  "cd AMenu/ep4_ce15",
  "python3 tools/mk_flash.py [--label \"L 2026-11-20\"]",
]));
C.push(gap());
C.push(table([3400, 5960], ["It writes", "What it is"], [
  ["`L.cof`", "The conversion set-up for `quartus_cpf`: EPCS64 (the W25Q64 behaves as one), Active Serial, AMenu at 0, the three machines of `L.jic` at 0x100000 / 0x300000 / 0x500000 and their ROM areas 1 MB above"],
  ["`output_files/L.jic` (+ `L.map`)", "**The one file for the board**: the menu, LSpectrum, L64 and LTari 800 (`INSTALLED` in the tool). `L.map` lists where each part ended up"],
  ["`output_files/machines/<machine>_<board>.LMC`", "One **machine file** per machine: a header with the board, the lengths and CRC-32 checksums, then the info sector, the ROM data and the bitstream exactly as the flash holds them"],
  ["`output_files/L_flash.bin`", "The whole flash as it reads over SPI, for the tests and for `mk_update.py`"],
]));
C.push(gap());
C.push(p("The tool also checks that the flash contents it composed are byte for byte what Quartus put into the `.jic`. In the Quartus GUI `L.cof` alone can still be converted with File > Convert Programming Files > Open Conversion Setup Data > Generate."));
C.push(p("The Spectrum ROM file `LSpectrum/ep4_ce15/roms48k.hex` is part of the project (Amstrad allows the ROMs for emulator use), and so is `LTari/ep4_ce15/roms/atarirom.hex`. The .jic file stores such data bit-reversed; the ROM loader recognises the order by the first byte, so nothing has to be done."));
C.push(p("The menu update and the loader image are made from the same folder (section 7 and 8):"));
C.push(code([
  "python3 tools/mk_update.py [--label \"L 2026-11-20\"]     # -> output_files/LUPDATE.BIN (the menu alone)",
  "python3 tools/mk_update.py --loader                       # -> output_files/L_loader.jic",
]));

C.push(h2("3.3 Programming the board"));
C.push(stepOf("prog")("Connect the USB-Blaster to the core board's JTAG header and power the board."));
C.push(stepOf("prog")("Quartus Programmer: Hardware Setup = USB-Blaster, mode **JTAG**, Add File `AMenu/ep4_ce15/output_files/L.jic`, tick **Program/Configure** and **Verify**, Start, and wait for 100 % before touching the board or the cable. From the command line:"));
C.push(code(["quartus_pgm -c USB-Blaster -m JTAG -o \"ipv;AMenu/ep4_ce15/output_files/L.jic\""]));
C.push(p("Without Verify, an interrupted write is not noticed: the menu then shows a red line **Could not start** with **reason 08** (a CRC error in that machine's image) when the machine is chosen. Program the .jic again, with Verify."));
C.push(gap());
C.push(stepOf("prog")("The Programmer first loads a small flash loader into the FPGA, then writes the flash. When it reports success, **switch the board off and on**: the menu appears with LSpectrum, L64 and LTari 800."));
C.push(p("Programming the .jic also clears the C64 ROMs in the flash; the ESP32 installs them again from the card at the next L64 start (section 6.2)."));
C.push(p("For development, a single machine's `.sof` can be loaded straight into the FPGA over JTAG (it is lost at power-off). The flash is not touched; KEY1 then goes to the menu in the flash. The machine finds its ROMs only if it is also installed in a position (its tag)."));

C.push(h2("3.4 The Cyclone 10 LP core board (10CL025)"));
C.push(p("The second core board, QMTECH's 10CL025YU256I7G, has the same size and headers, the same SDRAM and flash. Its projects are in the `10cl025/` subfolders. For AMenu, LSpectrum, L64, LTari and LNES they hold only the Quartus project and its outputs: the sources, the `.sdc` and the ROM images are those of `ep4_ce15/`. LMega and LNext exist for this board only; their `10cl025/` folders hold everything, and their `.qsf` files are written by hand with the same pins."));
C.push(code([
  "python3 tools/mk_10cl025_qsf.py                                        # makes the generated 10cl025/*.qsf from the ep4_ce15 ones",
  "cd AMenu/10cl025     && quartus_sh --flow compile AMenu",
  "cd LSpectrum/10cl025 && quartus_sh --flow compile LSpectrum",
  "cd L64/10cl025       && quartus_sh --flow compile L64",
  "cd LTari/10cl025     && quartus_sh --flow compile LTari",
  "cd LTari/10cl025     && quartus_sh --flow compile LTari -c LTari800",
  "cd LNES/10cl025      && quartus_sh --flow compile LNES",
  "cd LMega/10cl025     && quartus_sh --flow compile LMega",
  "cd LNext/10cl025     && quartus_sh --flow compile LNext",
  "cd AMenu/10cl025     && python3 ../ep4_ce15/tools/mk_flash.py          # -> L.cof, output_files/L.jic, output_files/machines/*_10cl025.LMC",
  "cd AMenu/10cl025     && python3 ../ep4_ce15/tools/mk_update.py         # -> output_files/LUPDATE.BIN for the 10CL025",
]));
C.push(gap());
C.push(b("The generated `10cl025/*.qsf` files: change the `ep4_ce15` .qsf (or the tool) and run the tool again. It replaces the device, translates every ball name (on-board parts by signal, the I/O board's signals by their pin of header U8) and points the file paths to `../ep4_ce15`."));
C.push(b("LNext: after a change in `ZXNEXT/`, run `python3 tools/mk_c10_files.py` in `LNext/10cl025` first (it makes `rtl/next_sprites.vhd` and `rtl/next_bootrom.vhd`). The project uses all 66 block RAMs of the FPGA and a fixed fitter seed in `LNext.qsf`."));
C.push(b("The board has one user key (KEY0). KEY1 is on header U7 pin 7 (ball G1) with a weak pull-up, where a button to ground can be wired; the board's nCONFIG button also returns to the machine menu."));
C.push(b("**An `L.jic` or `LUPDATE.BIN` is for one core board only.** The update file has no board mark: the file of the other board would leave the FPGA without a valid image, and the board would need the USB-Blaster and its own `L.jic`. Machine files carry their board: the menu lists only the ones made for its own board."));
C.push(b("Pins: `docs/BOARD_PINOUT.md`. Flash layout and addresses are the same on both boards."));
C.push(b("**State of 20 November 2026:** the 10CL025 board with I/O board revision 2 runs the menu, LSpectrum, L64 and LTari; LNES and LMega had their first runs on it (18 November). LNext started NextZXOS on the board with its bitstream loaded over JTAG (19 November); it was not yet installed from its machine file."));

// ------------------------------------------------------------------ 4
C.push(h1("4. The ESP32 firmware"));
C.push(p("The same firmware serves all machines and both core boards: it waits for a core ID on the SPI link and restarts whenever the machine changes."));
C.push(table([2300, 2200, 4860], ["Core ID", "Image", "What the firmware does there"], [
  ["4D4E0003", "Machine menu", "Menu update, machine install (F12), Bluetooth menu"],
  ["5A580001", "LSpectrum", "File list, tapes, snapshots"],
  ["43360003", "L64", "File list, disks, tapes, programs, snapshots, ROM install"],
  ["41540001", "LTari (both models)", "File list, disks, programs, cartridges, snapshots"],
  ["4E450001", "LNES", "File list, cartridges into the SDRAM, battery RAM files"],
  ["4D440001", "LMega", "File list, cartridges into the SDRAM, battery RAM files"],
  ["4E580001", "LNext", "The Next's SD card: sectors between the card and the FPGA"],
]));
C.push(gap());
C.push(table([2300, 3500, 3560], ["", "I/O board revision 1", "I/O board revision 2"], [
  ["Sketch", "`ESP32/v1` (`v1.ino`)", "`ESP32/v2` (`v2.ino`)"],
  ["ESP32", "DevKit board on sockets, its own USB", "ESP32-WROVER-E module (16 MB flash, 8 MB PSRAM), USB-C on the board"],
  ["Board options", "ESP32 Dev Module, default partition scheme", "ESP32 Dev Module, **PSRAM: Enabled**, **Flash Size: 16MB**, partition scheme **16M Flash (3MB APP/9.9MB FATFS)**"],
  ["Entries per folder in the file list", "320", "4,096 (the list is in the PSRAM)"],
]));
C.push(gap());
C.push(stepOf("esp")("Install the esp32 core 3.3.2 and the two libraries (section 2)."));
C.push(stepOf("esp")("Connect the board by USB; note its COM port (on the development PC: COM10 for revision 1, COM12 for revision 2)."));
C.push(stepOf("esp")("Compile and upload, in the top folder of the project:"));
C.push(code([
  "arduino-cli compile -b esp32:esp32:esp32 -u -p COM10 ESP32/v1",
  "arduino-cli compile -b esp32:esp32:esp32:PSRAM=enabled,FlashSize=16M,PartitionScheme=app3M_fat9M_16MB -u -p COM12 ESP32/v2",
]));
C.push(gap());
C.push(p("Or open `ESP32/v2/v2.ino` (revision 1: `ESP32/v1/v1.ino`) in the Arduino IDE, set the board options above, and Upload. A change in the ESP32 sources needs only this step; the FPGA flash stays as it is."));
C.push(p("The compiled sketch (`ESP32/vN/build/esp32.esp32.esp32/vN.ino.bin`) under the name `LESP32.BIN` is the firmware's update file for the SD card (section 7)."));

// ------------------------------------------------------------------ 5
C.push(h1("5. The SD card"));
C.push(stepOf("card")("Use a microSD card formatted **FAT32** (or FAT16). exFAT is not supported: most cards above 32 GB come as exFAT and must be reformatted."));
C.push(stepOf("card")("For installing machines, make the folder **/MACHINES/** and copy the machine files of your core board into it (`AMenu/<board>/output_files/machines/*.LMC`)."));
C.push(stepOf("card")("For L64, make the folder **/ROMS/C64/** and copy Commodore ROM files into it that you are entitled to use (they are copyrighted and not part of the project): read from a C64 and 1541 you own, or licensed copies:"));
C.push(table([2400, 1300, 5660], ["File name starts with", "Size", "Typical file name"], [
  ["**KERNAL**", "8 KB", "kernal-901227-03.bin"],
  ["**BASIC**", "8 KB", "basic-901226-01.bin"],
  ["**CHAR**", "4 KB", "chargen-901225-01.bin"],
  ["**DOS1541** or **1541**", "16 KB", "dos1541-325302-01+901229-05.bin (without it there is no disk drive)"],
]));
C.push(gap());
C.push(stepOf("card")("For LNext, make the folder **/ZXNEXT/** (the card must be FAT32) and copy the Spectrum Next distribution into it as it comes: `TBBLUE.FW`, the folders `machines`, `nextzxos` and the rest (https://www.specnext.com/latestdistro/). These files are not part of the project."));
C.push(stepOf("card")("Put games anywhere on the card, in folders as you like (up to 320 entries per folder; 4,096 on I/O board revision 2). Saved tapes and snapshots are written into the folder the file list is in."));
C.push(table([2400, 6960], ["Machine", "Files"], [
  ["LSpectrum", ".tap .tzx (tapes), .z80 (snapshots)"],
  ["L64", ".d64 (disks), .prg .t64 (programs), .tap (tapes), .a64 (snapshots)"],
  ["LTari 800 / 130", ".atr (disks), .xex (programs), .car (cartridges), .a8s (snapshots)"],
  ["LNES", ".nes (cartridges; battery RAM in `NAMEhhhh.SAV` beside the game)"],
  ["LMega", ".md .gen .bin .smd (cartridges up to 4 MB; battery RAM as LNES)"],
  ["LNext", "Whatever the Spectrum Next runs, inside the folder `ZXNEXT` (the Next's drive C:)"],
]));
C.push(gap());
C.push(p("The card can be inserted or changed at any time (the file list reads it again). LSpectrum and LTari need nothing on the card to start; their ROMs are in the flash."));
C.push(code([
  "SD card (FAT32)",
  "├── MACHINES/          the machine files (.LMC) of your core board",
  "├── ROMS/",
  "│   └── C64/",
  "│       ├── kernal-901227-03.bin",
  "│       ├── basic-901226-01.bin",
  "│       ├── chargen-901225-01.bin",
  "│       └── dos1541-325302-01+901229-05.bin",
  "├── ZXNEXT/            the Spectrum Next distribution (TBBLUE.FW, machines/, nextzxos/ ...)",
  "├── Spectrum/ ...      (.tap .tzx .z80, any folder names)",
  "├── C64/ ...           (.d64 .prg .t64 .tap .a64)",
  "├── Atari/ ...         (.atr .xex .car .a8s)",
  "├── NES/ ...           (.nes)",
  "└── MegaDrive/ ...     (.md .gen .bin .smd)",
]));

// ------------------------------------------------------------------ 6
C.push(h1("6. How the ROMs are used"));
C.push(h2("6.1 ZX Spectrum"));
C.push(b("The 128K ROMs and the F1 diagnostics slot (48 KB) are in the ROM area of the position LSpectrum is installed in (from the .jic or its machine file). The public image has a copy of the 48K BASIC ROM in the F1 slot (DiagROM's licence is not known); `LSpectrum/ep4_ce15/tools/mk_roms48k.py` builds the image with your own DiagROM."));
C.push(b("At every start and reset (started from the menu, KEY0) the FPGA's ROM loader finds the ROM area by its tag and copies the 48 KB from the flash into the SDRAM, then starts the Z80. F1 held at that moment selects the diagnostics slot."));
C.push(b("If the flash holds no ROM image for the machine, the board LED blinks fast: install the machine (section 7) or program the .jic."));
C.push(h2("6.2 Commodore 64"));
C.push(stepOf("check")("When L64 starts, its ROM loader copies 48 KB from the ROM area of its position into the SDRAM (CHAR, BASIC, KERNAL) and the 1541 DOS ROM into the drive's own memory. The image starts with the header \"L64 ROMS\"; byte 13 says whether a 1541 ROM is included."));
C.push(stepOf("check")("The ESP32 checks that header. **If the flash has no C64 ROMs yet** (or it has no 1541 ROM and the card has one), it shows \"No ROMs in the flash yet\", reads KERNAL*, BASIC*, CHAR* and DOS1541* / 1541* from /ROMS/C64/, builds the 48 KB image, writes it into the flash through the FPGA, reads it back to verify, and restarts the C64 with its ROMs. This takes a few seconds and happens once. The header is erased first and written last, so an install that stops anywhere is simply done again at the next start."));
C.push(stepOf("check")("From then on L64 starts **without the SD card**: the ROMs come from the flash every time L64 is started and after KEY0."));
C.push(stepOf("check")("If the files are missing, the screen says where to put them; add them and press F12 (or KEY0). Without a DOS1541 file the C64 works but has no disk drive (DEVICE NOT PRESENT); the board LED blinks fast while there is no ROM image at all."));
C.push(p("L64's machine file carries no ROMs. Installed over L64 it keeps the C64 ROMs that are there; installed into another machine's position it clears that position's ROM image, and the ESP32 installs the C64 ROMs from the card at the next L64 start. Programming `L.jic` clears them as well. Keep the ROM files on the card for that reason."));
C.push(p("For local tests only, `L64/ep4_ce15/tools/mk_c64rom.py KERNAL BASIC CHAR [DOS1541] OUT` makes the same 48 KB image as Intel HEX and as a .mem file for the simulation. Such files contain the Commodore ROMs: keep them in the git-ignored `L64/ep4_ce15/roms_local/` and never publish a .jic that contains them."));
C.push(h2("6.3 Atari"));
C.push(b("AltirraOS and Altirra BASIC (free replacement ROMs, `LTari/ep4_ce15/roms/atarirom.hex`) are in the ROM area of the position, in the .jic and in both LTari machine files. The ROM loader copies them into the SDRAM at every start, as for the Spectrum."));
C.push(b("LTari 800 and LTari 130 are two revisions of one project and two machine files with the same tag; each takes one position."));
C.push(h2("6.4 LNES and LMega"));
C.push(b("The consoles have no system ROM: their ROM areas hold only the info sector, and the machines do not read the flash. A game is a cartridge file that the ESP32 writes into the SDRAM (`ESP32/vN/src/nes.cpp`, `md.cpp`); the list of games opens when the machine starts."));
C.push(h2("6.5 LNext"));
C.push(b("A Spectrum Next has no ROMs of its own: a small boot ROM inside the core loads `TBBLUE.FW` from the SD card, which loads the ROMs and NextZXOS from the card too. They come from the Spectrum Next distribution in the card's folder `ZXNEXT` (section 5)."));
C.push(b("The card is on the ESP32. The core talks to an SD card made of logic, and the ESP32 moves the 512-byte sectors between it and the real card (`ESP32/vN/src/next.cpp`). It shows the Next the folder `ZXNEXT` as the card's root directory, so the Next's `C:/` is that folder. The machine is held in reset until the ESP32 has found the card."));

// ------------------------------------------------------------------ 7, 8
C.push(h1("7. Installing and updating from the SD card"));
C.push(p("A board that has the machine menu installs machines and updates itself from the card; no USB-Blaster is needed."));
C.push(h2("7.1 Installing a machine (F12 in the menu)"));
C.push(stepOf("upd")("Copy the machine files of your core board into the card's `MACHINES` folder and put the card in."));
C.push(stepOf("upd")("In the machine menu press **F12**. **Which machine?** lists the files made for this core board, by their menu lines. Choose one."));
C.push(stepOf("upd")("**Replace which one?** shows the three positions and what they hold now. Choose the position."));
C.push(stepOf("upd")("The ESP32 checks the whole file (CRC-32), then writes: the position's info sector is erased first, then the bitstream and the ROMs are written where they differ, and the info sector last, each sector read back. About 15 seconds; **do not switch off**. The menu then shows the new machine."));
C.push(table([3000, 6360], ["Situation", "What happens"], [
  ["The power fails during the write", "That position shows \"(empty)\", never a half machine: install it again. The menu and the other positions are not touched"],
  ["The file is damaged, or made for the other core board", "It is refused before anything is written; a file for the other board is not even listed"],
  ["No machine in the flash", "The screen says **No machines installed** and points to F12"],
  ["L64 installed over L64", "The C64 ROMs in the flash stay (section 6.2)"],
]));
C.push(h2("7.2 Updating the menu (LUPDATE.BIN)"));
C.push(p("`LUPDATE.BIN` holds the machine menu alone, **for one core board** (section 3.4)."));
C.push(stepOf("loader")("Copy `LUPDATE.BIN` to the **root folder** of the SD card and put the card in."));
C.push(stepOf("loader")("Switch the board on. While the machine menu is shown, the ESP32 finds the file and checks it (header and a CRC-32 over the whole image). The screen shows **Checking LUPDATE.BIN ...**, then **Writing the flash ...** with a progress bar; the menu takes no keys meanwhile. **Do not switch off.**"));
C.push(stepOf("loader")("The ESP32 compares the flash with the file in 4 KB sectors and rewrites only those that differ, each read back."));
C.push(stepOf("loader")("At **Update complete.** the ESP32 deletes the file. If the screen asks for it, switch the board off and on."));
C.push(table([3000, 6360], ["Situation", "What happens"], [
  ["The file is damaged or not an update file", "\"not a valid update file\": nothing is written, the file stays"],
  ["The power fails while the menu's sectors are written", "The only risky moment: the board may need the USB-Blaster and `L.jic` again. A machine install has no such risk"],
  ["The flash is already up to date", "Nothing is written; the file is deleted"],
]));
C.push(gap());
C.push(p("The file is a 256-byte header (\"LUPDATE1\", the image length, its CRC-32, the end of the menu's area and the label shown during the update) followed by the menu's flash image. The ESP32 code is `ESP32/vN/src/update.cpp`; its PC tests (`ESP32_test/vN/test/update_test.cpp` and `machine_test.cpp`, part of `run_host_test.sh`) run updates and installs against a flash model, including power cuts."));
C.push(h2("7.3 Updating the ESP32 (LESP32.BIN)"));
C.push(p("Copy `LESP32.BIN` (section 4; the file of your I/O board revision) to the root folder of the card and switch the board on: the running firmware writes it into its other program slot, deletes the file and restarts. It is handled before `LUPDATE.BIN`, so both files can be on the card together. LNES, LMega and LNext need a firmware that knows them."));
C.push(h2("7.4 The public download"));
C.push(p("`tools/make_github.py` builds the public copy of the project. Its folder `INSTALL/` holds what a user needs: `MACHINES/` (the machine files of both core boards; the names carry the board), `MENU_UPDATE/<board>/LUPDATE.BIN`, `ESP32_UPDATE/<v1|v2>/LESP32.BIN`, and the Installation Guide and User Manual as PDF in nine languages."));

C.push(h1("8. Boards shipped with the loader"));
C.push(p("`AMenu/<board>/output_files/L_loader.jic` holds only the machine menu (the rest of the flash blank): no machines and no ROMs. A board can be passed on with it, and the user installs everything from the public release."));
C.push(b("Make it in `AMenu/ep4_ce15/` (10CL025: in `AMenu/10cl025/` with `../ep4_ce15/tools/mk_update.py`): `python3 tools/mk_update.py --loader`."));
C.push(b("Program `L_loader.jic` as in 3.3. It holds the menu and blank data up to the end of the 8 MB flash: the Programmer erases only where a .jic has data (its Erase option did not clear old machines on hardware), so this file wipes a used board completely, C64 ROMs included. Then the ESP32 firmware as in section 4."));
C.push(b("At power-up the board shows **No machines installed** and points to F12."));
C.push(b("The user copies the folder `MACHINES` from the public release to the card and installs three machines with F12 (section 7.1); the Spectrum and Atari ROMs come with their machine files. For L64 the user adds the C64 ROM files, for LNext the Spectrum Next distribution, as in section 5."));

// ------------------------------------------------------------------ 9
C.push(h1("9. Checklist after installing"));
C.push(table([3800, 5560], ["Check", "Expected"], [
  ["Power on", "The machine menu with the three installed machines (after `L.jic`: LSpectrum, L64, LTari 800)"],
  ["Start LSpectrum", "The 128K menu; F12 shows the card's files (the ESP32 answers)"],
  ["KEY1, then start L64", "First time: \"No ROMs in the flash yet\", installing, then the BASIC screen; later: the BASIC screen at once, 38911 BASIC BYTES FREE"],
  ["F12 in L64, a .d64, Enter", "LOAD\"*\",8,1 is typed, the drive LED (board LED) is on, the program loads in turbo"],
  ["Ctrl+Alt+Del, then start LTari 800", "Blue screen, then \"Altirra 8K BASIC 1.59\" and Ready"],
  ["F12 in the menu, a machine file, a position", "\"Installed.\" after about 15 seconds; the menu shows the new machine"],
  ["Start LNES or LMega", "The list of games opens"],
  ["Start LNext (10CL025, folder `ZXNEXT` on the card)", "The Next's firmware starts from the card, then NextZXOS"],
  ["F8 in a computer", "The picture switches between 60 Hz and 50 Hz"],
  ["F3", "The Bluetooth menu (the ESP32's Bluetooth part answers)"],
]));
C.push(gap());
C.push(p("Licences, our own work and the same build steps in one file: `BUILDING_AND_LICENSES.md` in the repository root. Each machine's README (`<Machine>/<board>/README.md`) has its details. Keys and usage: `docs/L_User_Manual.docx`, `docs/LSpectrum_Keys.docx`, `docs/L64_Keys.docx` and `docs/LTari_Keys.docx`. Wiring of the boards: `docs/LSpectrum_Connection.docx`. Third-party parts and licences: `docs/L_Third_Party.docx` and `IP_BLOCKS.txt`."));

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
