// thirdparty_doc.js -- docs/L_Third_Party.docx: every external core, library and data file in the
// project, with origin, licence and how much of it is used.  node thirdparty_doc.js ../L_Third_Party.docx
const fs = require("fs");
const {
  Document, Packer, Paragraph, TextRun, Table, TableRow, TableCell, WidthType, ShadingType,
  HeadingLevel, AlignmentType, LevelFormat, BorderStyle, Footer, PageNumber,
} = require("docx");

const W = 9360;                 // US Letter, 1" margins
const FONT = "Calibri";
const border = { style: BorderStyle.SINGLE, size: 4, color: "A6A6A6" };
const borders = { top: border, bottom: border, left: border, right: border };

function runs(text, size = 20) {
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
    margins: { top: 50, bottom: 50, left: 90, right: 90 },
    children: lines.map(l => new Paragraph({
      children: head ? [new TextRun({ text: l, bold: true, color: "FFFFFF", font: FONT, size: 18 })] : runs(l, 18),
    })),
  });
}
function table(widths, header, rows) {
  const sum = widths.reduce((a, b) => a + b, 0);
  if (sum !== W) throw new Error("table widths " + sum);
  return new Table({
    width: { size: W, type: WidthType.DXA }, columnWidths: widths,
    rows: [new TableRow({ tableHeader: true, children: header.map((h, i) => cell(h, widths[i], true)) }),
           ...rows.map(r => new TableRow({ cantSplit: true, children: r.map((c, i) => cell(c, widths[i])) }))],
  });
}
const h1 = t => new Paragraph({ heading: HeadingLevel.HEADING_1, spacing: { before: 320, after: 120 }, children: [new TextRun({ text: t, font: FONT })] });
const h2 = t => new Paragraph({ heading: HeadingLevel.HEADING_2, spacing: { before: 220, after: 100 }, children: [new TextRun({ text: t, font: FONT })] });
const p  = t => new Paragraph({ spacing: { after: 110 }, children: runs(t, 21) });
const b  = t => new Paragraph({ numbering: { reference: "bullets", level: 0 }, spacing: { after: 50 }, children: runs(t, 21) });
const gap = () => new Paragraph({ spacing: { after: 80 }, children: [] });

// ---------------------------------------------------------------- numbers (2026-10-28 builds; LTari 2026-10-29)
// Lines: the files each Quartus project compiles (comments included). LEs: Fitter, per entity.
const LE = {
  adore: 15012, aspec: 7675,
  t65: 1137, t65d: 1070, kawari: 2831, sid: 2965, cia: 1040, via: 748,
  t80: 2675, jt49: 502,
  alex: 7179, t65a: 1065,
};
const pct = (a, t) => Math.round(100 * a / t) + " %";
const n = v => v.toLocaleString("en-US");

const C = [];
// ---------------------------------------------------------------- title
C.push(new Paragraph({ spacing: { after: 60 }, children: [new TextRun({ text: "L", bold: true, size: 52, font: FONT, color: "1F3864" })] }));
C.push(new Paragraph({ spacing: { after: 60 }, children: [new TextRun({ text: "Third-party cores, libraries and data: origin, licence, how much is used", size: 28, font: FONT, color: "2F5496" })] }));
C.push(new Paragraph({ spacing: { after: 240 }, children: [new TextRun({ text: "State of 29 October 2026: machine menu (AMenu), LSpectrum (ZX Spectrum 128K), L64 (Commodore 64), LTari (Atari 800XL / 130XE), ESP32 system controller", size: 20, font: FONT, color: "595959" })] }));

C.push(p("The project's own files are under the MIT licence. This document lists everything in it that comes from elsewhere. **Lines** are the source lines of the files a build compiles (comments included). **LEs** are the logic elements the Quartus fitter reports for that part in the build of 28 October 2026, against the whole design. The project's own HDL is about **10,600 lines** in 39 files (FPGA; LTari's 3,300 lines in 11 files among them), and its own ESP32 firmware about **4,800 lines** in 24 files."));

// ---------------------------------------------------------------- 1 summary
C.push(h1("1. Summary"));
C.push(table([1700, 1500, 2000, 1560, 1300, 1300], ["Part", "Used in", "Licence", "Lines used", "Changed?", "LEs (share)"], [
  ["**T80** Z80 CPU", "LSpectrum", "BSD-style", "4,498 (5 of 11 files)", "no", `${n(LE.t80)} (${pct(LE.t80, LE.aspec)})`],
  ["**JT49** AY-3-8910", "LSpectrum", "**GPL-3**", "780 (7 files)", "no", `${n(LE.jt49)} (${pct(LE.jt49, LE.aspec)})`],
  ["**T65** 6502 CPU", "L64: 6510 + 1541 CPU", "BSD-style", "2,470 (4 files)", "no", `${n(LE.t65 + LE.t65d)} (${pct(LE.t65 + LE.t65d, LE.adore)}), 2 copies`],
  ["**T65** 6502 CPU", "LTari: the 6502C", "BSD-style", "2,470 (4 files)", "no", `${n(LE.t65a)} (${pct(LE.t65a, LE.alex)})`],
  ["**VIC-II Kawari**", "L64: video chip", "**GPL-3**", "6,876 (18 files)", "small, marked", `${n(LE.kawari)} (${pct(LE.kawari, LE.adore)})`],
  ["**SID** 6581/8580", "L64: sound", "CERN-OHL-S v2 + GPL-2+", "2,416 (6 files)", "no", `${n(LE.sid)} (${pct(LE.sid, LE.adore)})`],
  ["**CIA** 6526 (`mos6526.v`)", "L64: 2 CIAs", "GPL-2+ (MiSTer core)", "534 (1 file)", "2 small, marked", `${n(LE.cia)} (${pct(LE.cia, LE.adore)}), 2 copies`],
  ["**VIA** 6522", "L64: 1541, 2 VIAs", "**GPL-3**", "714 (1 file)", "no", `${n(LE.via)} (${pct(LE.via, LE.adore)}), 2 copies`],
  ["Intel FPGA IP (megafunctions)", "all FPGA images", "Intel FPGA software licence", "parameters only", "-", "PLLs, clock switch, DDIO, remote update, flash, block RAM"],
  ["**Arduino-ESP32** core 3.3.2 + ESP-IDF", "ESP32 firmware", "LGPL-2.1+ / Apache-2.0", "linked library", "no", "-"],
  ["**ESP32-A2DP** 1.8.11", "ESP32: Bluetooth audio", "Apache-2.0", "~2,700 of 5,900 (source part)", "no", "-"],
  ["Spleen 8x16 font", "all images (on-screen text)", "BSD-2-Clause", "ASCII glyphs", "no", "-"],
  ["ZX Spectrum 128K ROMs", "LSpectrum", "Amstrad: emulator use", "32 KB + font", "no", "-"],
  ["DiagROM 1.59", "LSpectrum (F1)", "see 4.2", "16 KB", "no", "-"],
  ["Commodore 64 + 1541 ROMs", "L64", "Commodore copyright", "**not included**", "-", "-"],
  ["AltirraOS 3.11 + Altirra BASIC 1.59", "LTari", "free (all-permissive notice)", "16 KB + 8 KB", "no", "-"],
]));
C.push(gap());
C.push(p(`Roughly: in L64, the external cores make up about ${pct(LE.t65 + LE.t65d + LE.kawari + LE.sid + LE.cia + LE.via, LE.adore)} of the logic (the chips of the C64 itself); the bus, PLA, 1541 drive logic, frame buffer, keyboard, video, SDRAM controller and loader are our own. In LSpectrum, the external cores are about ${pct(LE.t80 + LE.jt49, LE.aspec)} of the logic. In LTari only T65 is external (about ${pct(LE.t65a, LE.alex)}): ANTIC, GTIA, POKEY, the PIA and everything around them are our own, written from the Altirra Hardware Reference Manual. The menu (AMenu) has no external core. By lines, the external HDL the builds use is about 18,300 lines against our 7,300.`));

// ---------------------------------------------------------------- 2 FPGA
C.push(h1("2. FPGA cores"));

C.push(h2("2.1 T80 (Z80 CPU), LSpectrum"));
C.push(b("**Origin:** MiSTer ZX Spectrum core, `rtl/T80`, commit `af0e6723` (24 July 2026), copied unchanged into `T80/` (`T80/SOURCE.md`, with SHA-256 of every file)."));
C.push(b("**Authors:** Daniel Wallner (T80 0250), MikeJ (T80(b) 303), Sorgelig (T80(c) 351, MiSTer)."));
C.push(b("**Licence:** BSD-style (header of `T80.vhd`): redistribution in source and synthesised form allowed; keep the copyright notice in the source and reproduce it in the documentation of a synthesised (bitstream) distribution."));
C.push(b("**Used:** `T80_Pack`, `T80_ALU`, `T80_MCode`, `T80_Reg`, `T80.vhd` = 4,498 lines of the folder's 6,306; the other variants (T80a, T80s, T80se, GBse, T8080se...) are not compiled. Our wrapper is `LSpectrum/rtl/cpu_t80.v`."));

C.push(h2("2.2 JT49 (AY-3-8910 / 8912 sound), LSpectrum"));
C.push(b("**Origin:** JT49 by Jose Tejada Gomez (jotego), version 1.0 (10 November 2018), as in the user's earlier DE10-Lite Spectrum; `LSpectrum/rtl/jt49/`."));
C.push(b("**Licence:** **GPL-3 or later**. A bitstream that contains it is a GPL-3 work: whoever receives the bitstream must be able to get the complete source (the GitHub repository)."));
C.push(b("**Used:** all 7 files, 780 lines; unchanged. One synthesis setting: ROM recognition off for `jt49_exp` (the volume table stays in logic)."));

C.push(h2("2.3 T65 (6502 CPU), L64"));
C.push(b("**Origin:** MiSTer Commodore 64 core, `rtl/t65`, commit `fe6dfe5` (6 September 2026), T65(b) version 315; copied unchanged into `T65/` (`T65/SOURCE.md`)."));
C.push(b("**Authors:** Daniel Wallner, Mike Johnson, Wolfgang Scherr, Morten Leikvoll, SzGy."));
C.push(b("**Licence:** BSD-style (header of `T65.vhd`): source and synthesised redistribution allowed if the copyright notice is kept."));
C.push(b("**Used:** all 4 files, 2,470 lines, twice: as the C64's 6510 (the I/O port at $00/$01 is ours, in `c64_system.v`) and as the 1541's 6502 (`c1541.v`)."));
C.push(b("**LTari:** the same 4 files as the Atari's 6502C (`LTari/rtl/atari_system.v`)."));

C.push(h2("2.4 VIC-II Kawari (video chip), L64"));
C.push(b("**Origin:** VIC-II Kawari by Randy Rossi, https://github.com/randyrossi/vicii-kawari, commit `95ed201` (8 October 2026), path `hdl/`; `L64/rtl/vicii/` with `LICENSE` and `SOURCE.md`."));
C.push(b("**Licence:** **GPL-3** (every file has the GPL-3 header). The L64 bitstream is a GPL-3 work."));
C.push(b("**Used:** only what a plain VIC-II needs: 18 files, 6,876 lines. Kawari's extensions (extra video modes, 80 columns, flash/EEPROM, SPI), its RGB / DVI / luma-chroma outputs and its scan doubler are not built; our `config.vh` sets this."));
C.push(b("**Changes** (each marked `// L64:`): the 14-bit VIC address, the half-cycle tick and the colour index per dot are exported; an `ext_rst` input restarts its reset sequence; the character line buffer is read through a register so that it fits a block RAM; power-up values for simulation."));
C.push(b("**Chosen** instead of FPGA-64 (syntiac), whose licence allows personal educational use only and forbids copying and redistribution."));

C.push(h2("2.5 SID 6581 / 8580 (sound), L64"));
C.push(b("**Origin:** MiSTer Commodore 64 core, `rtl/sid/`, commit `fe6dfe5`; `L64/rtl/sid/` (`SOURCE.md`)."));
C.push(b("**Licence:** `sid_dac.sv` and `sid_filter.sv` (Dag Lem's reDIP-SID, Alexey Melnikov): **CERN-OHL-S v2** (strongly reciprocal: modified versions and products made with them must make the source available). `sid_top.sv`, `sid_voice.sv`, `sid_envelope.sv`, `sid_tables.sv` have no header; they are part of the MiSTer C64 core, which is distributed under the GPL (2 or later)."));
C.push(b("**Used:** all 6 files, 2,416 lines, unchanged; built with one filter curve set and one SID (`MULTI_FILTERS = 0`, `DUAL = 0`)."));

C.push(h2("2.6 CIA 6526 (`mos6526.v`), L64"));
C.push(b("**Origin:** MiSTer Commodore 64 core, `rtl/mos6526.v`, commit `fe6dfe5` (\"by Rayne, timers and interrupts rewritten by slingshot\"); `L64/rtl/cia/`."));
C.push(b("**Licence:** no header; part of the MiSTer C64 core, distributed under the GPL (2 or later)."));
C.push(b("**Used:** 1 file, 534 lines, twice (CIA1, CIA2). Two changes, marked: four signals are declared before their first use, so that Questa accepts the file; an output `state` gives CRA, CRB and the interrupt mask for snapshots."));

C.push(h2("2.7 VIA 6522, L64 (1541 drive)"));
C.push(b("**Origin:** `iecdrv_via6522.vhd` by Gideon Zweijtzer, from the MiSTer C64 core (`rtl/iec_drive/`, commit `fe6dfe5`); `L64/rtl/via/`."));
C.push(b("**Licence:** **GPL-3** (\"Free to use, distribute and change to your own needs. Leaving a reference to the author will be highly appreciated.\")."));
C.push(b("**Used:** 1 file, 714 lines, twice (VIA1 serial bus, VIA2 drive mechanics), unchanged. The rest of the 1541 (address decode, serial bus, stepper, GCR encoder / decoder, track buffer) is our code (`c1541.v`, `c1541_gcr.v`); MiSTer's own drive model is not used."));

C.push(h2("2.8 Intel FPGA IP"));
C.push(p("Megafunctions that Quartus generates from parameters: `altpll` (all clocks), `altclkctrl` (the 50 / 60 Hz pixel clock switch), `altddio_out` (the SDRAM clock pin), `altremote_update` (machine menu and KEY1), `cycloneive_asmiblock` (configuration flash access for the ROM loader and the ROM install), and block RAMs inferred as `altsyncram`. They are covered by the Intel FPGA software licence that comes with Quartus Prime Lite; no Intel source is copied into the project."));

// ---------------------------------------------------------------- 3 ESP32
C.push(h1("3. ESP32 firmware libraries"));
C.push(table([2600, 2300, 4460], ["Library", "Licence", "What is used"], [
  ["**Arduino-ESP32** core 3.3.2 (Espressif)", "core: LGPL-2.1 or later; SD, Preferences and ESP-IDF: Apache-2.0", "`SPI` (link to the FPGA, SD card), `SD` (raw sector access only; the FAT code is ours), `Preferences` (Bluetooth settings), the I2S driver, GPIO and FreeRTOS from ESP-IDF, the Bluedroid Bluetooth stack. Linked, not copied."],
  ["**ESP32-A2DP** 1.8.11 (Phil Schatzmann)", "Apache-2.0", "The A2DP source (`BluetoothA2DPSource`, `BluetoothA2DPCommon`, volume control): about 2,700 of its 5,900 lines; the sink part is not used. Installed separately, not in the repository."],
  ["AAudioLinkFix (in `LSpectrum/esp32/libraries/`)", "ours (MIT)", "A small library that wraps one function of the Bluetooth stack (codec set-up fix); ours, listed here because it sits in a libraries folder."],
]));
C.push(gap());
C.push(p("The firmware itself (browser, FAT16 / FAT32, TAP / TZX player, recorder, .z80 snapshots, C64 loaders, 1541 track service, ROM install, Bluetooth menu) is our own C / C++."));

// ---------------------------------------------------------------- 4 data
C.push(h1("4. ROMs and other data"));
C.push(h2("4.1 ZX Spectrum 128K ROMs"));
C.push(b("`roms/zx128.rom` (32 KB), in `LSpectrum/roms48k.hex` and the simulation image. (c) Amstrad, who allow redistribution for emulator use with the copyright messages unchanged and not for sale."));
C.push(b("The Spectrum ROM's character set (`LSpectrum/rtl/osd_font.hex`, made by `esp32/tools/mkfont.py`) only labels the documentation diagrams; the on-screen text uses the Spleen font (below)."));
C.push(b("The machine menu's font is **Spleen 8x16** 2.1.0 by Frederic Cambus (github.com/fcambus/spleen), BSD 2-Clause: `AMenu/font/` with its `LICENSE`, converted by `AMenu/tools/mk_menufont.py` into `AMenu/rtl/menu_font.hex`, used by the menu and the machines' on-screen displays."));
C.push(h2("4.2 DiagROM"));
C.push(b("Retroleum ZX Spectrum diagnostics (16 KB, F1 at start). Its licence is not known, so it is **not in the public repository**: the published `LSpectrum/roms48k.hex` and `L.jic` have a copy of the 48K BASIC ROM in that slot. `LSpectrum/tools/mk_roms48k.py` builds the image with your own copy."));
C.push(h2("4.3 Commodore 64 and 1541 ROMs"));
C.push(b("KERNAL, BASIC, character ROM and 1541 DOS: copyrighted (Commodore; today the rights holder licenses them, e.g. to emulator distributions). **Not part of the project, the repository or the .jic.** Users put their own ROM files on the SD card (`/ROMS/C64/`); the ESP32 writes them into the configuration flash. Local test copies live in the git-ignored `L64/roms_local/`."));
C.push(h2("4.4 AltirraOS and Altirra BASIC"));
C.push(b("`LTari/roms/altirraos_xl.rom` (16 KB, AltirraOS 3.11) and `altirra_basic.rom` (8 KB, Altirra BASIC 1.59), free replacement ROMs by Avery Lee, taken from the atari800 emulator's source (`src/roms/`), in `LTari/roms/atarirom.hex` and the .jic at 0x380000."));
C.push(b("**Licence:** \"Copying and distribution of this file, with or without modification, are permitted in any medium without royalty provided the copyright notice and this notice are preserved. This file is offered as-is, without any warranty.\" (copyright Avery Lee 2008-2018 / 2008-2022; `LTari/roms/README.md`)."));
C.push(b("The Altirra Hardware Reference Manual (Avery Lee; a free download, not in the repository) is the documentation the LTari chips are written from; no other Atari FPGA core's HDL was used."));
C.push(h2("4.5 Other material"));
C.push(b("Data sheets and schematics (QMTECH, Winbond, CONNFLY, Analog Devices, MacroSilicon, WCH): the vendors' copyright; not in the repository, `docs/vendor/README.md` lists where to get them."));
C.push(b("Development tools (Quartus, Questa, Arduino IDE, gcc, Python, Node.js) are not part of what is distributed."));

// ---------------------------------------------------------------- 5 obligations
C.push(h1("5. What the licences ask for"));
C.push(b("**GPL-3 parts (JT49, Kawari, VIA):** the LSpectrum and L64 bitstreams, and the combined `L.jic`, are GPL-3 works. Anyone who gets a bitstream must be able to get its complete source under the GPL-3: publishing the repository does this. Our own MIT files are compatible (MIT may be combined into a GPL-3 work). The menu image (AMenu) and the LTari image contain no GPL part: LTari is our MIT code, T65 (BSD-style) and the Altirra ROMs (all-permissive)."));
C.push(b("**CERN-OHL-S v2 (SID DAC / filter):** strongly reciprocal like the GPL: keep the notices, and make the source of the design that contains it available, which the public repository does."));
C.push(b("**Altirra ROMs:** keep the copyright notice and the permission notice with the files (`LTari/roms/README.md`, this document)."));
C.push(b("**BSD-style (T80, T65):** keep the copyright notices in the source (they are in the file headers) and reproduce them in the documentation of a bitstream distribution: this document and the README name them."));
C.push(b("**Apache-2.0 / LGPL-2.1 (ESP32 libraries):** the libraries are not modified; LGPL-2.1 for a statically linked firmware means the user must be able to relink it with a changed core, which the published source and Arduino build provide."));
C.push(b("**Licence texts:** Kawari has its `LICENSE` file; the other parts carry their licence in the file headers. Recommended before publishing: add the GPL-3 text (`COPYING`) at the top of the repository, since the bitstreams are GPL-3 works."));

const numbering = { config: [{ reference: "bullets", levels: [{ level: 0, format: LevelFormat.BULLET, text: "•", alignment: AlignmentType.LEFT, style: { paragraph: { indent: { left: 360, hanging: 260 } } } }] }] };

const doc = new Document({
  creator: "L",
  title: "L — third-party cores, libraries and data",
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
