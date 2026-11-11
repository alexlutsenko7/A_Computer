const fs = require("fs");
const {
  Document, Packer, Paragraph, TextRun, Table, TableRow, TableCell, WidthType, ShadingType,
  HeadingLevel, AlignmentType, LevelFormat, BorderStyle, ImageRun, PageBreak, Footer, PageNumber,
  TableOfContents,
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
      children: head ? [new TextRun({ text: l, bold: true, color: "FFFFFF", font: FONT, size: 19 })] : runs(l, 19),
    })),
  });
}
function table(widths, header, rows) {
  const sum = widths.reduce((a, b) => a + b, 0);
  if (sum !== W) throw new Error("table widths " + sum);
  return new Table({
    width: { size: W, type: WidthType.DXA }, columnWidths: widths,
    rows: [new TableRow({ tableHeader: true, children: header.map((h, i) => cell(h, widths[i], true)) }),
           ...rows.map(r => new TableRow({ children: r.map((c, i) => cell(c, widths[i])) }))],
  });
}
const h1 = t => new Paragraph({ heading: HeadingLevel.HEADING_1, spacing: { before: 320, after: 120 }, children: [new TextRun({ text: t, font: FONT })] });
const h2 = t => new Paragraph({ heading: HeadingLevel.HEADING_2, spacing: { before: 220, after: 100 }, children: [new TextRun({ text: t, font: FONT })] });
const p  = t => new Paragraph({ spacing: { after: 110 }, children: runs(t, 21) });
const b  = t => new Paragraph({ numbering: { reference: "bullets", level: 0 }, spacing: { after: 50 }, children: runs(t, 21) });
const gap = () => new Paragraph({ spacing: { after: 80 }, children: [] });
const caption = t => new Paragraph({ alignment: AlignmentType.CENTER, spacing: { after: 160 }, children: [new TextRun({ text: t, italics: true, size: 18, font: FONT, color: "595959" })] });

const img = fs.readFileSync(process.argv[3]);

const C = [];
// ---------------------------------------------------------------- title
C.push(new Paragraph({ spacing: { after: 60 }, children: [new TextRun({ text: "LSpectrum", bold: true, size: 52, font: FONT, color: "1F3864" })] }));
C.push(new Paragraph({ spacing: { after: 60 }, children: [new TextRun({ text: "Architecture of the ZX Spectrum 128K on the QMTECH Cyclone IV board", size: 28, font: FONT, color: "2F5496" })] }));
C.push(new Paragraph({ spacing: { after: 300 }, children: [new TextRun({ text: "Design state of 23 October 2026: the 128K machine (on hardware since 6 October), the SD card tape loader with saving, .z80 snapshots, memory contention and Bluetooth audio", size: 20, font: FONT, color: "595959" })] }));
C.push(new TableOfContents("Contents", { hyperlink: true, headingStyleRange: "1-2" }));
C.push(new Paragraph({ children: [new PageBreak()] }));

// ---------------------------------------------------------------- 1
C.push(h1("1. Overview"));
C.push(p("LSpectrum is a ZX Spectrum 128K built in an Intel/Altera Cyclone IV E FPGA (EP4CE15F23C8) on a QMTECH core board. It is a port of the user's earlier Spectrum 128 on a DE10-Lite (MAX10), redesigned around three ideas:"));
C.push(b("**All memory in SDRAM.** The 128 KB of RAM and the ROMs live in the board's 32 MB SDR SDRAM; only the screen is mirrored in block RAM for the video. This keeps the design small enough for smaller FPGAs."));
C.push(b("**One system clock, no clock multiplexers.** Everything that belongs to the Spectrum runs at 112 MHz; the Z80 is stepped by a clock enable, at the real 3.5469 MHz or at 28 MHz (turbo, 8x)."));
C.push(b("**Fully constrained timing.** Every clock and every I/O has constraints, and the build closes timing at all corners (the DE10 reference had none)."));
C.push(p("Added on top: an **SD card tape loader** that plays unmodified .tap and .tzx files in turbo and **saves** the Spectrum's SAVE output as .tap files, **.z80 snapshots** (F2 saves the whole machine at any moment, the browser loads them), controlled from on-screen dialogs, USB-keyboard machine keys (DiagROM, 50/60 Hz, reset), and **Bluetooth audio** to headphones or speakers, chosen in an on-screen menu (F3). An ESP32 board is the **system controller**: it owns the SD card, runs the loader firmware and the Bluetooth stack, and drives the FPGA's loader hardware over an SPI link."));
C.push(table([3000, 6360], ["Item", "Value"], [
  ["FPGA", "EP4CE15F23C8 (15,408 logic elements, 56 M9K block RAMs, 4 PLLs)"],
  ["Board", "QMTECH Cyclone IV core board: 50 MHz oscillator, W9825G6KH-6 SDRAM (32 MB, 16 bit), W25Q64 configuration flash, 2 buttons, 1 LED"],
  ["I/O board", "Extra_PCB_CycloneIV, wired to the core board's U8: VGA (4 bits per colour), AY + beeper audio on a 3.5 mm jack, two Kempston DB9, USB keyboard module (UART), microSD socket and the ESP32"],
  ["CPU", "T80 (Z80, VHDL, from the MiSTer ZX Spectrum core), 3.5469 MHz or 28 MHz"],
  ["System controller", "ESP32-WROOM-32 DevKit with the Arduino sketch ESP32/v2/: the microSD card on its SPI port, SD tape loader firmware (C), A2DP Bluetooth source fed with the sound over I2S; SPI link (8 MHz) to the FPGA"],
  ["Resources used", "7,469 logic elements (48 %), 19 of 56 M9K block RAMs (34 %), 2 PLLs, 84 pins"],
  ["Timing", "worst setup slack +0.42 ns (112 MHz, slow 85 °C corner), worst hold +0.16 ns, no negative slack at any corner, no unconstrained paths"],
  ["Tools", "Quartus Prime 25.1std Lite, Questa FSE, Arduino core esp32 3.3.2"],
]));

// ---------------------------------------------------------------- 2
C.push(h1("2. Block diagram"));
C.push(new Paragraph({ alignment: AlignmentType.CENTER, children: [new ImageRun({ type: "png", data: img, transformation: { width: 624, height: 388 } })] }));
C.push(caption("Figure 1. Blocks and clock domains (blue 112 MHz, green 56 MHz, orange pixel clock, grey outside the FPGA)."));
C.push(table([2300, 2060, 5000], ["Module (rtl/)", "Clock", "Role"], [
  ["`LSpectrum.v`", "all", "Top level: PLLs, resets, SDRAM clock output, video clock switch, pins"],
  ["`zx_system.v`", "all", "The machine without PLLs (what the simulations instantiate): connects all blocks"],
  ["`zx_bus.v`", "112 MHz", "CPU clock enable, bus bridge to SDRAM, paging, I/O ports, interrupt, EAR"],
  ["`cpu_t80.v` + `T80/`", "112 MHz + CEN", "Z80 core with a single clock enable"],
  ["`sdram_ram.v`", "112 MHz", "Byte-wide RAM on the SDR SDRAM (open-row, CAS latency 2)"],
  ["`rom_loader.v`, `flash_if.v`", "112 MHz", "Copies the ROMs from the configuration flash into SDRAM at reset"],
  ["`zx_video.v`, `vga_timing.v`", "25.2 / 27 MHz", "Spectrum picture from the screen shadows, borders, FLASH, OSD overlay"],
  ["`zx_keyboard.v`", "112 MHz", "USB keyboard packets to the Spectrum key matrix, loader keys, machine keys"],
  ["`jt49/`, `sd_dac.v`", "112 MHz", "AY-3-8912 sound chip and its 1-bit audio DAC"],
  ["`bt_i2s.v`", "112 MHz", "The sound as I2S for the ESP32's Bluetooth part"],
  ["`tape_loader.v` + `esp_link.v`", "56 MHz", "Tape loader hardware driven by the ESP32 over the SPI link: registers, command FIFO, pulse player, recorder (saving), snapshot port, OSD port, UART to the ESP32"],
  ["`sys_pll.v`, `vga_pll.v`, `vga_clkmux.v`", "-", "PLLs and the glitch-free pixel clock switch"],
]));

// ---------------------------------------------------------------- 3
C.push(h1("3. Clocks and resets"));
C.push(table([2100, 2700, 4560], ["Clock", "Source", "Used by"], [
  ["50 MHz", "board oscillator", "PLL inputs; video mode switch sequencer"],
  ["112 MHz (c0)", "sys_pll: 50 x 56 / 25", "System: SDRAM controller, CPU + bridge, AY, keyboard, ROM loader"],
  ["112 MHz delayed (c1)", "sys_pll, +1.34 ns", "SDRAM clock, forwarded inverted through a DDIO output"],
  ["56 MHz (c2)", "sys_pll: 50 x 28 / 25", "Tape loader hardware and the ESP32 link; rising edges aligned with c0, so crossings are ordinary timed paths"],
  ["25.208 / 27.009 MHz", "vga_pll", "Pixel clock for 640x480@60 or 720x576@50 (one VCO of 756.25 MHz; +0.033 % against the CEA-861 25.200 / 27.000 MHz), one at a time through the global clock control block"],
]));
C.push(gap());
C.push(p("**Video clock switch.** Changing between 50 and 60 Hz is a sequence run from the 50 MHz clock: video reset on, clock disabled, select changed, clock enabled, video reset off. The clock control block makes the switch glitch-free."));
C.push(p("**Resets.** Three reset domains, each released synchronously:"));
C.push(b("**Power-up** (PLL locked): the keyboard decoder. Held keys and the 50/60 choice therefore survive a machine reset, which is what makes \"hold F1 and reset\" work."));
C.push(b("**Machine** (power-up, KEY0): SDRAM controller, ROM loader, CPU, ports, AY."));
C.push(b("**Tape loader** (power-up, KEY0): the loader hardware; the ESP32 notices the reset and restarts itself."));

// ---------------------------------------------------------------- 4
C.push(h1("4. CPU and clock enable"));
C.push(p("The Z80 is the T80 core, copied unchanged from the MiSTer ZX Spectrum core, wrapped in `cpu_t80.v` with a single clock enable (CEN). All T80 state changes only on CEN, so the CPU can be slowed, sped up or stopped at any clock without corrupting anything."));
C.push(b("**CEN generator:** a 32-bit phase accumulator at 112 MHz. Normal speed adds 136,016,246 per clock, giving exactly 3.5469 MHz on average (31-32 clocks per T-state, the 128K's frequency). Turbo adds 2^30, giving exactly 28 MHz (one T-state every 4 clocks). Switching is glitch-free at any time."));
C.push(b("**Turbo source:** the SD tape loader while it plays or saves a block; F6 switches it to normal speed."));
C.push(b("**Hold:** the tape loader can stop the CEN (like a memory wait) while it needs time during a save; the Spectrum does not notice, because its T-states stop too."));
C.push(b("**Snapshot freeze:** the tape loader can stop the CEN at an instruction boundary (section 9.5)."));
C.push(b("**Memory contention (Level 1, 128K timing):** a frame T-state counter restarts at each interrupt and counts real T-states. At the start of each memory cycle to 4000-7FFF (or to C000-FFFF while an odd RAM page is paged in), and in the I/O patterns of the 128K, the CEN is withheld by 6, 5, 4, 3, 2, 1, 0, 0 T-states during the 128 contended T-states of each of the 192 picture lines (from T-state 14,361). Those T-states are lost, as on the real machine, and the tape player counts them too. Off in turbo; F5 switches it off. Not emulated: the internal contended T-states of some instructions."));
C.push(b("**Floating bus:** an I/O read of a port nothing answers (e.g. port FF) returns the byte the ULA is fetching when the CPU reads the port, as on a real 128K. The read point follows Fuse 1.6: the start of the I/O cycle's 4th T-state, after all of its contention. Counting x = T-state - 14,362 - 228 x row, the bitmap and attribute bytes of the displayed screen appear at x = 2-5 of each 8 within the 128 picture T-states of a line, FF elsewhere. A contended poll (port high byte 40-7F) therefore only ever sees an attribute or FF, which games that sync on an attribute rely on (Sidewize). The bridge decides at the start of T2: it takes hpos and adds the contention the cycle is still going to get (two pipeline stages), then reads the byte from SDRAM before the CPU takes it at the end of the wait state. (Until 11 October the byte was taken at T2; half of Sidewize's polls then saw pixel bytes, the game synced too early and its player flickered.) On together with contention (F5), off in turbo. Not emulated: ULA snow (DiagROM's snow test fails)."));
C.push(b("**Stall:** if a memory read is not finished when the CPU needs its data, the CEN pulse is held back (\"owed\") and given as soon as the data is there. At normal speed this never happens (the SDRAM is always fast enough); in turbo it costs a clock now and then."));
C.push(b("**Timing constraints:** CEN pulses are never closer than 4 clocks, so paths inside the T80 get a 4-clock multicycle (the T80 alone reaches 63.5 MHz on this chip, so 4 x 8.9 ns is ample)."));

// ---------------------------------------------------------------- 5
C.push(h1("5. Memory"));
C.push(h2("5.1 SDRAM controller"));
C.push(p("`sdram_ram.v` turns the 16-bit W9825G6KH-6 (4 banks x 8192 rows x 512 columns) into a simple byte-wide RAM with a request/acknowledge handshake. It runs at 112 MHz with CAS latency 2 and was proven on its own in the DDR_TEST project before being used here."));
C.push(b("**Address mapping:** bit 0 selects the byte lane (DQM), bits 9-1 the column, bits 11-10 the bank, higher bits the row. Consecutive 1 KB blocks rotate through the 4 banks."));
C.push(b("**Open-row policy:** each bank keeps its last row open, so code and data that stay within a few kilobytes are read without an ACTIVATE."));
C.push(b("**Refresh:** done early whenever the controller is idle, forced only when the 7.5 µs interval runs out."));
C.push(b("**Pins:** all SDRAM address, command and data pins use I/O-cell registers; the SDRAM clock is the inverted, slightly delayed system clock, forwarded through a DDIO output so it has the same output delay as the data."));
C.push(table([4680, 4680], ["Access", "Clocks from request to acknowledge"], [
  ["Write", "1 (posted: the controller completes it on its own)"],
  ["Read, row already open", "4"],
  ["Read, bank idle", "6"],
  ["Read, other row open in that bank", "8"],
  ["Read colliding with a refresh (worst case)", "about 20"],
]));
C.push(h2("5.2 Memory map"));
C.push(p("The Spectrum uses an 18-bit (256 KB) window of the SDRAM:"));
C.push(table([2600, 6760], ["SDRAM address", "Contents"], [
  ["0x00000 - 0x1FFFF", "RAM pages 0-7, 16 KB each (page n at n x 0x4000)"],
  ["0x20000 - 0x23FFF", "ROM 0: 128K editor"],
  ["0x24000 - 0x27FFF", "ROM 1: 48K BASIC"],
  ["0x28000 - 0x2BFFF", "DiagROM v1.59 (used for both ROM slots when selected at start)"],
  ["0x2C000 - 0x3FFFF", "spare"],
]));
C.push(gap());
C.push(table([2600, 6760], ["CPU address", "Mapped to"], [
  ["0x0000 - 0x3FFF", "ROM 0 or ROM 1 (port 7FFD bit 4), or DiagROM; writes are ignored"],
  ["0x4000 - 0x7FFF", "RAM page 5 (screen 0)"],
  ["0x8000 - 0xBFFF", "RAM page 2"],
  ["0xC000 - 0xFFFF", "RAM page 0-7 (port 7FFD bits 2-0); page 7 holds screen 1"],
]));
C.push(h2("5.3 Bus bridge"));
C.push(p("`zx_bus.v` connects the T80 to the SDRAM. It watches the CPU's machine cycles and their T-states:"));
C.push(b("**T1, first clock:** the address is latched and a read is started at once (speculatively), mapped through the paging logic. The SDRAM therefore has almost two T-states before the CPU takes the data."));
C.push(b("**T1, second clock:** the cycle type (memory or I/O, read or write) is sampled."));
C.push(b("**T2:** for writes, the data is sampled and the write is posted: the CPU does not wait for it. The next read waits until earlier writes are done, so a read always sees them. Writes to the screen areas of pages 5 and 7 also go to the screen shadows."));
C.push(b("**End of T2:** the CEN that lets the CPU take the data is held until the read has completed (only possible in turbo)."));
C.push(h2("5.4 ROM loading"));
C.push(p("The ROMs are stored in the configuration flash at 0x500000 (128K set, 32 KB) and 0x508000 (DiagROM, 16 KB), written together with the bitstream as one .jic file. After every machine reset `rom_loader.v` reads the 48 KB with SPI READ commands through the Cyclone IV ASMI block and writes them into SDRAM (about 14 ms), then the CPU starts. The .jic tool stores user data bit-reversed; the loader recognises this from the first byte (F3 = DI, or CF = F3 reversed) and corrects it. A missing ROM image makes the LED blink fast."));
C.push(p("At power-up the CPU additionally waits for the first USB keyboard packet (at most 1.5 s), so that a held F1 key is already known when the ROM is chosen."));

// ---------------------------------------------------------------- 6
C.push(h1("6. Video"));
C.push(p("The picture is generated in its own pixel clock domain from **screen shadows**: block-RAM copies of the first 6912 bytes (bitmap + attributes) of RAM pages 5 and 7, written in parallel with the CPU's SDRAM writes. The video never reads the SDRAM, so it never disturbs the CPU."));
C.push(table([2000, 2400, 2200, 2760], ["Mode", "Timing", "Pixel clock", "Picture placement"], [
  ["50 Hz", "720x576 (CEA 576p), 864 x 625", "27.009 MHz (50.017 Hz)", "512x384 picture, 104 px / 96 lines border"],
  ["60 Hz", "640x480, 800 x 525", "25.208 MHz (60.02 Hz)", "512x384 picture, 64 px / 48 lines border"],
]));
C.push(gap());
C.push(b("Each Spectrum pixel is 2 x 2 VGA pixels. Bitmap and attribute bytes are fetched 4 pixels ahead; FLASH swaps ink and paper every 16 frames; BRIGHT selects the level: each colour is 14 of 15 normal and 15 of 15 bright on the 4-bit DAC."));
C.push(b("Power-up mode is 60 Hz (640x480, accepted by every monitor; 576p50 is not); F8 swaps it, and the choice is kept across resets."));
C.push(b("**OSD:** 32 x 24 characters exactly over the Spectrum picture, using the Spectrum's own character set (taken from the 48K ROM), white on blue; bit 7 of a character means inverse video. It can cover the whole picture (browser) or only the bottom row (status). It uses the same 4-pixel-ahead fetch: text RAM, then font ROM."));

// ---------------------------------------------------------------- 7
C.push(h1("7. Sound, ports and interrupt"));
C.push(h2("7.1 Sound"));
C.push(b("**AY-3-8912:** JT49 core (GPL-3) clocked at 1.7734 MHz as on the 128K, independent of turbo. The three channels are mixed into one 10-bit value and output by a sigma-delta DAC at 112 MHz on AUDIO_AY; the I/O board's 68 Ω + 100 nF filter makes it analog again."));
C.push(b("**Beeper:** port FE bit 4, output directly on AUDIO_BEEP; both go to the 3.5 mm jack."));
C.push(b("**Bluetooth:** the same two sources, mixed and filtered, as 16-bit I2S for the ESP32 bridge (section 10)."));
C.push(h2("7.2 I/O ports (partial decoding, as the real 128K)"));
C.push(table([2600, 6760], ["Port", "Function"], [
  ["Write, A0 = 0 (FE)", "border colour (bits 2-0), MIC (bit 3, to the tape loader's recorder; no pin), beeper (bit 4)"],
  ["Write, A15 = 0, A1 = 0 (7FFD)", "RAM page (2-0), screen page 5/7 (3), ROM (4), lock until reset (5)"],
  ["Write FFFD / BFFD", "AY register select / data"],
  ["Read, A0 = 0 (FE)", "keyboard half-rows selected by A8-A15 (bits 4-0), EAR (bit 6), bits 5 and 7 = 1"],
  ["Read FFFD", "AY register"],
  ["Read, A0 = 1, A5 = 0 (1F)", "Kempston joystick: 000FUDLR, 1 = pressed (the DB9 ports in Kempston mode, F4 menu)"],
  ["Other reads", "floating bus: the screen byte the ULA is fetching (section 4), FF in the border, in turbo or with F5 off"],
]));
C.push(gap());
C.push(p("**EAR (bit 6)** comes from the SD tape loader while it plays, otherwise from the beeper bit (as on the real machine)."));
C.push(h2("7.3 Interrupt"));
C.push(p("The 32-T-state interrupt comes from the video in 50 Hz mode (a 50.017 Hz frame; a real 128K runs at 50.021 Hz) and from a 70,908-T-state counter (the 128K frame) in 60 Hz mode; the counter follows turbo."));
C.push(b("In 50 Hz mode the interrupt fires at a set point of the VGA frame, so that border effects line up with the picture: VGA line 24, pixel 166 after the start of vsync, measured with Aquaplane's horizon stripe. Page Up / Page Down (browser closed) move it in 1/8-line steps. Calculated for a real 128K it would be line 12.7; the difference is most likely the contention that is not emulated (Level 2)."));
C.push(b("In 60 Hz mode the picture is not locked to the Spectrum frame (59.5 Hz video, 50 Hz interrupts), so border effects cannot line up."));

// ---------------------------------------------------------------- 8
C.push(h1("8. Keyboard and controls"));
C.push(p("A USB keyboard is attached through a CH9350-style module that sends HID reports over a 115,200-baud UART. `zx_keyboard.v` decodes the modifier byte and the first three key codes of each report into the 8 x 5 Spectrum key matrix, plus extras:"));
C.push(b("PC keys mapped to Spectrum combinations: Backspace = DELETE, arrows = cursor keys, Esc = BREAK, Left Shift = CAPS SHIFT, Right Shift / Ctrl = SYMBOL SHIFT."));
C.push(b("**Machine keys** handled in hardware: F1 held at start (DiagROM), F8 (50/60 Hz), Ctrl+Alt+Del (back to the machine menu, as KEY1)."));
C.push(b("**Loader keys** passed to the loader (read by the ESP32 over the link) as a bit vector: F12 / numpad keys / arrows / Enter / Esc / F2 (snapshot) / F3 (Bluetooth menu) / F4 (joystick menu) / F5 (contention) / F6 (speed) / F7 (stop) / F9-F11 / Page Up / Page Down (browser paging, or the 50 Hz interrupt position); plus the raw keyboard report for typing file names."));
C.push(b("While the browser is open the Spectrum's key matrix is released, so it sees no keys."));
C.push(p("The complete key list with usage cases is in the separate document LSpectrum_Keys.docx. Board buttons: KEY0 resets everything; KEY1 (or Ctrl+Alt+Del on the keyboard) returns to the machine menu (the factory image AMenu, loaded at power-up; LSpectrum is the application image at flash 0x100000)."));

// ---------------------------------------------------------------- 9
C.push(h1("9. SD card tape loader"));
C.push(p("The loader reads unmodified .tap and .tzx files from a FAT16/FAT32 microSD card and feeds them to the Spectrum's EAR input in turbo, and it records the Spectrum's SAVE output into new .tap files on the card. The work is split: the ESP32 does the files and dialogs, the FPGA everything that needs exact timing or direct access to the machine."));
C.push(h2("9.1 Hardware (tape_loader.v + esp_link.v, 56 MHz)"));
C.push(b("**SPI link** (esp_link.v): the ESP32 is the SPI master (mode 0, up to 8 MHz; SCK oversampled at 56 MHz). Each frame (CS low) is a command byte and its data: register write / read, OSD text, pulse commands, Spectrum memory writes / reads through the snapshot port (bursts, about 900 KB/s), and a status read. The link is the master of the loader's register bus; a core ID register (\"ZX\", version 1) and an interrupt line (FIFO half empty, key change, recorder event, snapshot port idle) complete it."));
C.push(b("**UART** (115,200 baud, 512-byte receive FIFO) to the ESP32's Bluetooth part (section 10)."));
C.push(b("**Recorder:** MIC edges timed in T-states; while a save runs, an unread edge holds the Z80, so nothing is lost however slowly the ESP32 answers."));
C.push(b("**Command FIFO** (512 x 32 bit) and the **pulse player**."));
C.push(b("**OSD write port** into the text RAM of the video block; **timer**; control register for turbo, EAR source and OSD."));
C.push(h2("9.2 Pulse player"));
C.push(p("Every tape block is a sequence of signal edges. The ESP32 turns the file into commands; the player executes them, counting time in **Z80 T-states** (it counts the CPU's clock-enable pulses), not in nanoseconds. Consequences: the same file is exact at 3.5 MHz and at 28 MHz, SDRAM stalls stretch tape and CPU equally, and custom turbo loaders stay in step with the Z80."));
C.push(table([2400, 6960], ["Command", "Meaning"], [
  ["PULSE n", "hold the level for n T-states, then toggle"],
  ["LEVEL l, n", "set the level, hold it n T-states (n = 0: no time)"],
  ["DATA b, k", "k bits of byte b, most significant first; each bit = 2 pulses of length LEN0 or LEN1"],
  ["SAMPLES b, k", "k bits of b; each sets the level for LEN0 T-states (TZX direct recording)"],
  ["LEN0, LEN1, MARK", "settings: bit lengths, block number (no time)"],
]));
C.push(gap());
C.push(p("The next command starts in the same clock as the previous one ends, so there are no gaps; settings are taken in while a pulse runs and take effect exactly at its end, so they never show on the line. If the ESP32 is late, the delay is credited to the next pulse (up to 255 T-states), so edges stay on time."));
C.push(h2("9.3 Firmware (ESP32/v2/src/, C)"));
C.push(b("**Platform:** the FPGA's registers appear as proxy objects whose reads and writes go over the link (hw.h, esp_hw.cpp); pulse commands, OSD text and memory writes are collected into one frame each; SD sectors come from the ESP32's SD card driver. The loader runs as a task next to the Bluetooth stack."));
C.push(b("**FAT16/FAT32:** with or without a partition table, long file names, fragmented files, seeking, creating files."));
C.push(b("**TAP and TZX:** TZX blocks 10, 11, 12, 13, 14, 15, 20 and 2B are played; 21-27 (groups, jumps, loops, calls) are followed; 18, 19, 28, 2A and information blocks are skipped."));
C.push(b("**Browser and control:** sorted folder lists (up to 320 entries) on the OSD, keys with auto-repeat, pause, back one block, stop, turbo/normal speed (F6), and \"stop the tape\" blocks for multi-load games."));
C.push(b("**Saving:** recording mode, ROM-format decoder (pilot, sync, bits), 8.3 name typed on the USB keyboard, FAT writing (free clusters, both FAT copies, directory entries, growing folders, deleting an empty file)."));
C.push(b("**Snapshots:** .z80 version 3 writer (pages compressed in two passes: length, then data) and a loader for versions 1-3, 48K and 128K, that checks the whole file before changing anything."));
C.push(b("**Bluetooth menu** (F3): commands to the Bluetooth part and its answers and events over the FPGA's UART (section 10.3)."));
C.push(p("The same C files are built for the PC tests (section 13)."));
C.push(h2("9.4 Saving"));
C.push(p("Saving is a recording mode, started from the browser (first line [Save to this folder], then an 8.3 name) and stopped with F12. Meanwhile every ROM-format block the Spectrum saves is decoded from MIC and appended to that one .tap file; a block needs 64 pilot pulses, so MIC clicks for sound are ignored, and turbo is switched on only while a block is being saved. TAP block lengths are written as 0 first and patched when a block ends. Each bit is decided by its first pulse, because the ROM does not always end a block with an edge. An empty recording removes its file."));

C.push(h2("9.5 Snapshots"));
C.push(p("F2 saves the whole machine as a .z80 file (version 3, 128K): the 8 RAM pages, every CPU register, port 7FFD, border, the AY registers and its register select. Choosing a .z80 file in the browser loads it (versions 1-3; 48K snapshots run in 48K mode with 7FFD = 30h)."));
C.push(b("**Freeze at an instruction boundary** (zx_bus): the CEN stops in T2 of an opcode fetch that is not an interrupt acknowledge and does not follow a CB/ED/DD/FD prefix (tracked from the fetched opcodes). There the T80 has written back the previous instruction (at T1) and not yet taken the opcode or incremented PC and R, so its registers are the state between two instructions. In HALT the PC is already past the HALT: the firmware saves PC - 1."));
C.push(b("**Registers** are read from the T80's REG output; loading resets the T80 alone and loads every register at once through its DIRSet/DIR port (the MiSTer way), then the CPU starts a fresh opcode fetch at the saved PC."));
C.push(b("**Command port** (loader to zx_bus, request toggle + acknowledge): SDRAM byte read / write (writes also update the screen shadows), register word read, register word write + LOAD, AY register read / write / select, ports (7FFD, border), state (HALT, AY select, ports)."));
C.push(b("**Unfreeze:** the opcode read of the stopped M1 is repeated (the loader's SDRAM reads changed the data bus), so the program continues as if nothing happened; T-states stopped too, so a playing tape stays in step."));
C.push(b("Not saved: the position inside the video frame; after a load the next interrupt comes at a different point of the frame (the T80's reset state also costs one T-state)."));

// ---------------------------------------------------------------- 10
C.push(h1("10. Bluetooth audio"));
C.push(p("Classic Bluetooth audio (A2DP) needs a radio and a protocol stack that the FPGA does not have, so a small ESP32 board does it: the original ESP32 (ESP32-WROOM-32), because the newer S2 / S3 / C3 chips only have Bluetooth Low Energy. The ESP32 is wired to U7 (pins in section 11; full wiring in LSpectrum_Connection.docx). It acts like a phone: it finds, pairs with and streams to headphones or a speaker."));
C.push(h2("10.1 Sound path (bt_i2s.v)"));
C.push(b("**Mix:** the AY value (10 bit) x 16 plus 8192 for the beeper, the same sources as the analog outputs."));
C.push(b("**Filters:** two one-pole low-passes at the AY rate (3.5469 MHz, about 35 kHz each) against aliasing at 44.1 kHz, then a DC blocker once per sample (about 27 Hz), so silence is 0 whatever the AY volumes or the beeper level."));
C.push(b("**I2S:** the ESP32 is the master and drives BCLK (1.4112 MHz) and LRCK (44.1 kHz), so the Bluetooth stream and the sound share one clock. The FPGA synchronises both and sends 16-bit words, MSB first, one BCLK after each LRCK edge (Philips format), the same sample in both channels; DATA changes about 27 ns after the falling BCLK edge, far ahead of the next rising edge (354 ns)."));
C.push(h2("10.2 The ESP32 (ESP32/v2/v2.ino)"));
C.push(b("Arduino sketch on the ESP32 core 3.3 with the ESP32-A2DP library (v1.8.11): an A2DP source that takes its samples from the I2S input (or a test tone), reconnects to the last device by itself, and stores its settings (device, PIN, volume, source) in flash."));
C.push(b("**PIN devices** (Bluetooth 2.0 and older) ask for a fixed code: the ESP32 answers with 0000, 1234, 8888 and 1111 in turn, one per connection attempt, or with a code set in the menu. Newer devices pair without a code. Old devices that only give their name on request are listed too."));
C.push(b("**ESP-IDF fix:** when the headphones open the stream themselves (Bose headphones do), ESP-IDF 5.5 never asks for their codec capabilities, leaves its SBC encoder unset and crashed with a division by zero. The sketch wraps the failing function at link time (-Wl,--wrap) and reports success while a link is open; the encoder then uses the standard SBC setup that the headphones chose."));
C.push(h2("10.3 Control from LSpectrum (F3)"));
C.push(p("The loader's menu (bt.cpp) and the Bluetooth part talk through the FPGA's UART (115,200 baud, BT_TX / BT_RX) with text lines: commands (`info`, `scan`, `connect n`, `disconnect`, `forget`, `pin`, `vol`, `src`), answers starting with OK or ERR, and events starting with EV (device found, connecting, connected, pairing with PIN ..., paired, disconnected). F3 opens a full-screen menu: state, Scan for devices, Disconnect, Forget the device, PIN, Volume, Sound (Spectrum or test tone), and the devices found; Enter on a device connects to it. The menu asks for the state every second and shows events at once; a tape that is playing goes on meanwhile. The ESP32's USB port takes the same commands, for debugging."));
C.push(b("Bluetooth (SBC) adds roughly 0.15-0.25 s of delay: fine for music, noticeable in fast games."));

// ---------------------------------------------------------------- 11
C.push(h1("11. Pins"));
C.push(table([2500, 1500, 5360], ["Signal", "FPGA pin", "Where"], [
  ["CLOCK_50", "T2", "board oscillator"],
  ["RESET_N (KEY0)", "W13", "board button"],
  ["LEDR", "E4", "board LED: on = turbo, fast blink = no ROMs in flash"],
  ["DRAM_* (40 pins)", "various", "on-board SDRAM (as the QMTECH demo)"],
  ["VGA_R[3:0]", "E21 D21 E22 D22", "I/O board VGA DAC (bit 3 to 0)"],
  ["VGA_G[3:0]", "C21 B21 C22 B22", "I/O board VGA DAC"],
  ["VGA_B[3:0]", "N19 M19 N20 M20", "I/O board VGA DAC"],
  ["VGA_HS / VGA_VS", "F21 / H21", "I/O board VGA"],
  ["KB_OUT / KB_IN", "AB19 / AB18", "keyboard module UART (both inputs, data = KB_OUT AND KB_IN)"],
  ["AUDIO_AY / AUDIO_BEEP", "AA18 / AA19", "I/O board audio jack (RC filter on AY)"],
  ["JOY1_UP/DOWN/LEFT/RIGHT/FIRE_N", "AB20 AA20 Y21 Y22 W21", "I/O board DB9 J4 (pull-ups on the board)"],
  ["JOY2_UP/DOWN/LEFT/RIGHT/FIRE_N", "W22 V21 V22 U21 U22", "I/O board DB9 J6; mode (Kempston / Cursor / Sinclair) from the F4 menu"],
  ["ESP_SCK / MOSI / CS_N (in)", "AB13 / AA13 / AB14", "ESP32 GPIO14 / 13 / 33: SPI link"],
  ["ESP_MISO / ESP_IRQ (out)", "AA14 / AB15", "ESP32 GPIO35 / 34: SPI link data, interrupt"],
  ["BT_BCLK / BT_LRCK (in), BT_DATA (out)", "AA15 / AB16 / AA16", "ESP32 GPIO26 / 25 / 22: I2S"],
  ["BT_TX (out) / BT_RX (in)", "AB17 / AA17", "ESP32 GPIO16 (RX2) / GPIO17 (TX2): UART"],
]));
C.push(gap());
C.push(p("All pins are 3.3-V LVTTL; unused pins are inputs. All of them reach the I/O board through U8 and its J1 (each pin pair swapped). The full header map is in docs/BOARD_PINOUT.md; the wiring of everything is in LSpectrum_Connection.docx."));

// ---------------------------------------------------------------- 12
C.push(h1("12. Timing constraints"));
C.push(b("All PLL clocks derived; the 50 MHz, system (112 / 56 MHz and the SDRAM clock) and pixel clock groups are asynchronous to each other, and every crossing between them is synchronised or goes through a dual-clock block RAM. 112 and 56 MHz come from one PLL with aligned edges and are timed against each other normally."));
C.push(b("SDRAM pins: input and output delays from the W9825G6KH-6 data sheet plus board skew; read data has a 2-clock setup multicycle from the SDRAM clock."));
C.push(b("T80 internal paths: 4-clock multicycle; cycle decode sampled by the bridge: 2-clock multicycle."));
C.push(b("SDRAM owner switch (ROM loader to CPU): 2-clock multicycle, valid because both sides are idle when it happens once after reset."));
C.push(b("Board inputs and slow outputs (buttons, switches, keyboard, joystick, audio, VGA DAC, ESP32 link, Bluetooth I2S and UART) are false paths; the link oversamples SCK and leaves several clocks of margin, I2S and UART inputs are synchronised."));

// ---------------------------------------------------------------- 13
C.push(h1("13. Verification"));
C.push(table([3100, 6260], ["Test", "What it shows"], [
  ["sim/run_sim.sh", "Whole machine with the real ROMs: flash model, ROM loader, SDRAM model with timing checks, T80 boots the 128K ROM to its menu (and DiagROM with F1)"],
  ["sim/run_esp_link_sim.sh", "Loader hardware driven over the SPI link by an ESP32 model: core ID, register writes and reads, OSD text, FIFO bursts, 256-byte memory writes and reads across a page, the error flag with slow commands, the interrupt on a key change"],
  ["ESP32_test/v2/test/run_host_test.sh", "Firmware on the PC against generated FAT16/FAT32 card images (fragmented files, long names): every listing and every TAP/TZX signal compared with an independent Python reference; recordings of real TAP files (noise, headerless, several saves, 1 s pauses in turbo, empty) written and checked by an independent FAT checker; snapshots: reference .z80 files (versions 1-3, 48K/128K, stored pages, bad files) loaded into a model of the hardware, and save + reload round trips checked by an independent .z80 decoder"],
  ["sim/run_snap_sim.sh", "zx_bus + T80 + SDRAM: a Z80 test program (prefixes, DD CB, block instructions, EXX, IM 2, HALT, paging, AY) run undisturbed, with random freezes and reads, and with random freezes and full restores (LOAD): identical results"],
  ["sim/run_cont_sim.sh", "zx_bus + T80 + SDRAM: 8,000 NOPs in contended RAM run 57 per line in the border and 41 per picture line (the known Spectrum result), 57 everywhere with contention off"],
  ["sim/run_float_sim.sh", "zx_bus + T80 + SDRAM: 6,000 IN A,(FF) against Fuse 1.6's rule for the 128K floating bus (read point after all I/O contention; incl. contended port addresses); all FF with it switched off"],
  ["sim/run_floatgame_sim.sh", "zx_bus + T80 + SDRAM running a real game from a .z80 (default Sidewize): every floating-bus read and every exit of the game's sync loop compared with Fuse's rule (~1 minute per frame)"],
  ["sim/run_bt_i2s_sim.sh", "bt_i2s against an ESP32-like I2S master with 16- and 32-bit slots: every word bit-exact, beeper swing centred on 0, DC removed"],
  ["tests/Test_wires, ESP32_test/v1/ESPLinkTest", "Hardware tests: every ESP32-FPGA wire (levels, pulses, 8 MHz SPI, crosstalk) and the SD card; link throughput, memory round trips, keys and OSD test pages"],
  ["DDR_TEST, VGA_TEST", "Earlier stand-alone projects that proved the SDRAM controller and the video modes on the hardware"],
  ["Hardware", "128K boots and runs (6 October); games load from the SD card in turbo and at normal speed, saving to the card works (8 October); 60 Hz start, contention and the 50 Hz border alignment confirmed with Aquaplane, floating bus confirmed with Sidewize, snapshots save and load (9 October); floating bus read point corrected, Sidewize's player no longer flickers, Arkanoid and Cobra work (11 October); ESP32 with Bose headphones: connects, test tone plays (13 October); ESP32 as system controller: wiring, link, loading, saving, snapshots and the Bluetooth menu work (14 October)"],
]));

// ---------------------------------------------------------------- 14
C.push(h1("14. The second core board"));
C.push(p("The same sources build for QMTECH's Cyclone 10 LP board (10CL025YU256I7G): the project is in `LSpectrum/10cl025/`, its .qsf generated from the EP4CE15 one by `tools/mk_10cl025_qsf.py` (device, ball names, file paths). One source line depends on the family: the block that gives the design access to the configuration flash (`flash_if.v`). The build of 11 November 2026 uses 7,717 of 24,624 logic elements and meets timing with the same constraints (worst setup slack +0.86 ns at 112 MHz); it has not run on hardware yet. The board has one user key: KEY1 is on a header pin, and the nCONFIG button returns to the machine menu."));

C.push(h1("15. Known limitations"));
C.push(b("Memory contention only at Level 1 (memory and I/O cycles; not the internal T-states some instructions contend); no ULA snow: timing-critical demos are not exact. The 50 Hz interrupt position is tuned (Aquaplane) rather than calculated; other border-effect games may need Page Up / Page Down."));
C.push(b("The AY output is mono; MIC is not on a pin (saving goes to the SD card only)."));
C.push(b("Tape loader: TZX generalized data (0x19), CSW (0x18) and the select-block menu (0x28) are not played; text and message blocks are not shown; LOAD \"\" is not typed automatically; at most 320 entries per folder; exFAT cards are not supported."));
C.push(b("Saving: ROM format only, 8.3 names, no overwrite, no file dates. Snapshots: .z80 only (no .sna), no overwrite, the video frame position is not kept."));
C.push(b("The ESP32 is needed for the SD card, the browser, saving, snapshots and Bluetooth; without it the Spectrum boots and runs, but F12 does nothing."));
C.push(b("Bluetooth: mono, about 0.2 s of delay; the ESP32 needs its own power (USB or 5 V on VIN)."));

const doc = new Document({
  creator: "L", title: "LSpectrum architecture",
  features: { updateFields: true },
  styles: {
    default: { document: { run: { font: FONT, size: 21 } } },
    paragraphStyles: [
      { id: "Heading1", name: "Heading 1", basedOn: "Normal", next: "Normal", quickFormat: true,
        run: { size: 30, bold: true, color: "1F3864", font: FONT }, paragraph: { outlineLevel: 0 } },
      { id: "Heading2", name: "Heading 2", basedOn: "Normal", next: "Normal", quickFormat: true,
        run: { size: 24, bold: true, color: "2F5496", font: FONT }, paragraph: { outlineLevel: 1 } },
    ],
  },
  numbering: { config: [{ reference: "bullets", levels: [{ level: 0, format: LevelFormat.BULLET, text: "•", alignment: AlignmentType.LEFT,
    style: { paragraph: { indent: { left: 540, hanging: 270 } } } }] }] },
  sections: [{
    properties: { page: { size: { width: 12240, height: 15840 }, margin: { top: 1440, bottom: 1440, left: 1440, right: 1440 } } },
    footers: { default: new Footer({ children: [new Paragraph({ alignment: AlignmentType.CENTER, children: [
      new TextRun({ text: "LSpectrum architecture  -  page ", size: 16, color: "808080", font: FONT }),
      new TextRun({ children: [PageNumber.CURRENT], size: 16, color: "808080", font: FONT })] })] }) },
    children: C,
  }],
});
Packer.toBuffer(doc).then(buf => { fs.writeFileSync(process.argv[2], buf); console.log("written", process.argv[2], buf.length); });
