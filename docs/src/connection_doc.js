// connection_doc.js OUT.docx DIAGRAM.png -- LSpectrum wiring document (US Letter, 1" margins)
const fs = require("fs");
const {
  Document, Packer, Paragraph, TextRun, Table, TableRow, TableCell, WidthType, ShadingType,
  HeadingLevel, AlignmentType, LevelFormat, BorderStyle, ImageRun, Footer, PageNumber,
} = require("docx");

const W = 9360;
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
function cell(text, width, head = false, fill) {
  const lines = Array.isArray(text) ? text : [text];
  return new TableCell({
    width: { size: width, type: WidthType.DXA }, borders,
    shading: head ? { type: ShadingType.CLEAR, color: "auto", fill: "1F3864" }
           : fill ? { type: ShadingType.CLEAR, color: "auto", fill } : undefined,
    margins: { top: 40, bottom: 40, left: 80, right: 80 },
    children: lines.map(l => new Paragraph({
      children: head ? [new TextRun({ text: l, bold: true, color: "FFFFFF", font: FONT, size: 18 })] : runs(l, 18),
    })),
  });
}
function table(widths, header, rows, fill) {
  const sum = widths.reduce((a, b) => a + b, 0);
  if (sum !== W) throw new Error("table widths " + sum);
  return new Table({
    width: { size: W, type: WidthType.DXA }, columnWidths: widths,
    rows: [new TableRow({ tableHeader: true, children: header.map((h, i) => cell(h, widths[i], true)) }),
           ...rows.map(r => new TableRow({ cantSplit: true, children: r.map((c, i) => cell(c, widths[i], false, fill)) }))],
  });
}
const h1 = t => new Paragraph({ heading: HeadingLevel.HEADING_1, spacing: { before: 300, after: 120 }, children: [new TextRun({ text: t, font: FONT })] });
const p  = t => new Paragraph({ spacing: { after: 110 }, children: runs(t, 21) });
const b  = t => new Paragraph({ numbering: { reference: "bullets", level: 0 }, spacing: { after: 50 }, children: runs(t, 21) });
const n  = t => new Paragraph({ numbering: { reference: "check", level: 0 }, spacing: { after: 50 }, children: runs(t, 21) });
const gap = () => new Paragraph({ spacing: { after: 80 }, children: [] });
const caption = t => new Paragraph({ alignment: AlignmentType.CENTER, spacing: { after: 160 }, children: [new TextRun({ text: t, italics: true, size: 18, font: FONT, color: "595959" })] });

const img = fs.readFileSync(process.argv[3]);
const PINW = [1300, 1300, 1500, 1500, 660, 3100];     // J1 pin, U8 pin, FPGA pin, signal, dir, notes
const PINH = ["I/O board J1", "Core board U8", "FPGA pin", "Signal", "Dir", "Notes"];

const C = [];
C.push(new Paragraph({ spacing: { after: 60 }, children: [new TextRun({ text: "LSpectrum — connections", bold: true, size: 44, font: FONT, color: "1F3864" })] }));
C.push(new Paragraph({ spacing: { after: 240 }, children: [new TextRun({ text: "How the QMTECH Cyclone IV core board, the Extra_PCB_CycloneIV I/O board, the ESP32 system controller and the microSD card are wired (state of 23 October 2026)", size: 21, font: FONT, color: "595959" })] }));

C.push(h1("1. Overview"));
C.push(new Paragraph({ alignment: AlignmentType.CENTER, children: [new ImageRun({ type: "png", data: img, transformation: { width: 624, height: 340 } })] }));
C.push(caption("Figure 1. The core board, the I/O board and what plugs into the I/O board."));
C.push(table([2400, 2600, 4360], ["Part", "Connected to", "Carries"], [
  ["Extra_PCB_CycloneIV I/O board", "core board U8, by 64 short wires from its J1, each pin pair swapped", "VGA, keyboard, audio, two joysticks, the ESP32's link, I2S and UART, 5 V for the I/O board"],
  ["ESP32-WROOM-32 DevKit", "sockets U2 on the I/O board", "SPI link for the tape loader, sound as I2S, UART for the F3 Bluetooth menu, the microSD card"],
  ["microSD card", "socket J7 on the I/O board, wired to the ESP32", "SD card (SPI) for the tape loader"],
  ["Bluetooth headphones / speaker", "the ESP32, by radio (A2DP)", "the Spectrum's sound"],
]));
C.push(gap());
C.push(p("All FPGA pins are 3.3 V (LVTTL) and **not 5 V tolerant**. Every signal between the boards is 3.3 V: the I/O board makes its own 3.3 V for its pull-ups and the SD card, the keyboard module's UART is 3.3 V, and the ESP32 is a 3.3 V part."));

C.push(h1("2. The core board headers"));
C.push(p("U7 is the left header (not used) and U8 the right one (32 x 2 pins each). On both: pins 1/2 ground, 3/4 3.3 V, 61/62 ground, 63/64 VIN (5 V). The numbering was read from the QMTECH schematic: **check 1/2, 3/4, 61/62 and 63/64 with a meter** before connecting anything new. Full header map: docs/BOARD_PINOUT.md."));
C.push(table([2400, 6960], ["On-board", "Pin / use"], [
  ["50 MHz oscillator", "T2"],
  ["KEY0 (button farther from the long edge)", "W13: reset of everything"],
  ["KEY1", "Y13: back to the machine menu"],
  ["LED", "E4: on = turbo; fast blink = no ROMs in the flash (program the .jic)"],
  ["SDRAM, configuration flash", "on the board, nothing to wire"],
]));

C.push(h1("3. I/O board J1 to core board U8"));
C.push(p("The I/O board sits beside the core board, its J1 holes directly opposite U8. The two are joined by 64 short wires with **each pin pair swapped**: J1 pin 2k-1 goes to U8 pin 2k, and J1 pin 2k to U8 pin 2k-1 (J1.1 to U8.2, J1.2 to U8.1, and so on). Each power pair carries the same net on both pins (ground, 3.3 V, ground, 5 V), so power stays correct; the signals land on the FPGA pins below, which is what the LSpectrum pin assignment expects."));
C.push(table(PINW, PINH, [
  ["1", "2", "-", "GND", "", "ground"],
  ["2", "1", "-", "GND", "", ""],
  ["3, 4", "4, 3", "-", "(3.3 V)", "", "not connected on the I/O board"],
  ["5, 6", "6, 5", "AB11, AA11", "-", "", "not connected (clock-only FPGA inputs)"],
  ["7", "8", "AB13", "ESP_SCK", "in", "ESP32 D14, link clock 8 MHz"],
  ["8", "7", "AA13", "ESP_MOSI", "in", "ESP32 D13"],
  ["9", "10", "AB14", "ESP_CS_N", "in", "ESP32 D33"],
  ["10", "9", "AA14", "ESP_MISO", "out", "ESP32 D35"],
  ["11", "12", "AB15", "ESP_IRQ", "out", "ESP32 D34"],
  ["12", "11", "AA15", "BT_BCLK", "in", "ESP32 D26, I2S"],
  ["13", "14", "AB16", "BT_LRCK", "in", "ESP32 D25, I2S"],
  ["14", "13", "AA16", "BT_DATA", "out", "ESP32 D22, I2S"],
  ["15", "16", "AB17", "BT_TX", "out", "ESP32 RX2 (GPIO16), F3 menu"],
  ["16", "15", "AA17", "BT_RX", "in", "ESP32 TX2 (GPIO17)"],
  ["17", "18", "AB18", "KB_IN", "in", "keyboard module J5.3"],
  ["18", "17", "AA18", "AUDIO_AY", "out", "AY, sigma-delta; RC filter on the board"],
  ["19", "20", "AB19", "KB_OUT", "in", "keyboard module J5.2"],
  ["20", "19", "AA19", "AUDIO_BEEP", "out", "beeper, port FE bit 4"],
  ["21", "22", "AB20", "JOY1_UP_N", "in", "J4 pin 1; 3.3 kΩ pull-ups on the board"],
  ["22", "21", "AA20", "JOY1_DOWN_N", "in", "J4 pin 2"],
  ["23", "24", "Y21", "JOY1_LEFT_N", "in", "J4 pin 3"],
  ["24", "23", "Y22", "JOY1_RIGHT_N", "in", "J4 pin 4"],
  ["25", "26", "W21", "JOY1_FIRE_N", "in", "J4 pin 6"],
  ["26", "25", "W22", "JOY2_UP_N", "in", "J6 pin 1"],
  ["27", "28", "V21", "JOY2_DOWN_N", "in", "J6 pin 2"],
  ["28", "27", "V22", "JOY2_LEFT_N", "in", "J6 pin 3"],
  ["29", "30", "U21", "JOY2_RIGHT_N", "in", "J6 pin 4"],
  ["30", "29", "U22", "JOY2_FIRE_N", "in", "J6 pin 6"],
  ["31-44, 46, 48", "31-44, 45, 47", "-", "-", "", "not connected"],
  ["45", "46", "H21", "VGA_VS", "out", "22 Ω + 6.8 pF on the board"],
  ["47", "48", "F21", "VGA_HS", "out", "22 Ω + 6.8 pF on the board"],
  ["49, 51, 50, 52", "50, 52, 49, 51", "E21, D21, E22, D22", "VGA_R[3:0]", "out", "523 Ω, 1.05 kΩ, 2.1 kΩ, 4.22 kΩ (bit 3 to 0)"],
  ["53, 55, 54, 56", "54, 56, 53, 55", "C21, B21, C22, B22", "VGA_G[3:0]", "out", "same DAC"],
  ["57, 59, 58, 60", "58, 60, 57, 59", "N19, M19, N20, M20", "VGA_B[3:0]", "out", "same DAC"],
  ["61", "62", "-", "GND", "", ""],
  ["62", "61", "-", "GND", "", ""],
  ["63", "64", "-", "VIN 5 V", "power", "feeds the whole I/O board"],
  ["64", "63", "-", "VIN 5 V", "power", ""]
]));
C.push(gap());
C.push(p("The 3.3 V pins (J1.3/4) are not used by the I/O board: it makes its own 3.3 V from the 5 V. U8.5 and U8.6 are clock-only inputs of the FPGA: never use them for anything else."));

C.push(h1("4. Connectors on the I/O board"));
C.push(table([2200, 7160], ["Connector", "Use"], [
  ["J2 VGA (DB15 HD)", "4 bits per colour (binary-weighted resistor DAC into the monitor's 75 Ω, 0.7 V full scale). LSpectrum outputs ZX normal colours as level 14 of 15 and bright as 15."],
  ["J4, J6 joysticks (DB9 male)", "Atari/Kempston pinout: 1 up, 2 down, 3 left, 4 right, 6 fire, 8 ground. Mode chosen with F4: both Kempston (port 1F, default), J4 Kempston + J6 Cursor, or Interface 2 (J4 Sinclair 1, J6 Sinclair 2)."],
  ["J3 audio (3.5 mm jack)", "AY + beeper mixed, mono on tip and ring, line level (about 0.75 V peak to peak, ~600 Ω): for an amplifier with its own volume control, not for headphones directly."],
  ["J5 keyboard module", "USB-HID to UART module on 4 pins: 1 GND, 2 KB_OUT, 3 KB_IN, 4 +5 V. UART 115,200 baud at 3.3 V; the FPGA reads both lines (data = KB_OUT AND KB_IN)."],
  ["J7 microSD", "on the ESP32 (section 5), 10 kΩ pull-ups on CS, CMD and DAT0-2, 100 nF + 10 µF at the socket."],
  ["U2 ESP32 sockets", "two 1x15 female sockets for the 30-pin ESP32 DevKit."],
  ["U1 K7803", "5 V to 3.3 V switching module for the pull-ups and the SD card."],
]));

C.push(h1("5. ESP32 system controller and microSD card"));
C.push(p("A 30-pin ESP32-WROOM-32 DevKit (CP2102, USB-C) with the sketch LSpectrum/esp32_v2/esp32_v2.ino, plugged into the I/O board. It owns the microSD card, runs the tape loader and the Bluetooth audio, and talks to the FPGA over an SPI link with an interrupt line, an I2S sound input and a UART. The ESP32 drives the link and I2S clocks. ESP32 pins are given by their DOIT 30-pin board labels."));
const ESPW = [1500, 1500, 1300, 1000, 1000, 3060];
C.push(table(ESPW, ["ESP32 board pin", "Signal", "Dir", "J1 / U8", "FPGA pin", "Notes"], [
  ["D35", "ESP_MISO", "FPGA → ESP32", "10 / 9", "AA14", "link data to the ESP32; D35 is input-only"],
  ["D34", "ESP_IRQ", "FPGA → ESP32", "11 / 12", "AB15", "interrupt, active high; D34 is input-only"],
  ["D14", "ESP_SCK", "ESP32 → FPGA", "7 / 8", "AB13", "link clock, 8 MHz; FPGA pull-up"],
  ["D13", "ESP_MOSI", "ESP32 → FPGA", "8 / 7", "AA13", "link data to the FPGA; FPGA pull-up"],
  ["D33", "ESP_CS_N", "ESP32 → FPGA", "9 / 10", "AB14", "link select; FPGA pull-up (idle while the ESP32 boots)"],
  ["D26", "BT_BCLK", "ESP32 → FPGA", "12 / 11", "AA15", "I2S bit clock, 1.4112 MHz; FPGA pull-up"],
  ["D25", "BT_LRCK", "ESP32 → FPGA", "13 / 14", "AB16", "I2S word select, 44.1 kHz; FPGA pull-up"],
  ["D22", "BT_DATA", "FPGA → ESP32", "14 / 13", "AA16", "sound, 16-bit; ESP32 pull-down"],
  ["RX2 (GPIO16)", "BT_TX", "FPGA → ESP32", "15 / 16", "AB17", "F3 menu commands, 115,200 baud"],
  ["TX2 (GPIO17)", "BT_RX", "ESP32 → FPGA", "16 / 15", "AA17", "answers and events; FPGA pull-up"],
  ["VIN, GND", "5 V, GND", "", "63, 64 / 1, 2", "-", "power from the core board through J1"],
], "FDF0E2"));
C.push(gap());
C.push(table([2000, 2400, 1700, 3260], ["ESP32 board pin", "microSD (J7)", "Signal", "Notes"], [
  ["D18", "CLK", "SD SCK", "ESP32 VSPI, 20 MHz"],
  ["D19", "DAT0", "SD MISO", "10 kΩ pull-up on the board"],
  ["D23", "CMD", "SD MOSI", "10 kΩ pull-up"],
  ["D5", "DAT3", "SD CS", "10 kΩ pull-up"],
], "E2EFDA"));
C.push(gap());
C.push(b("**Direction check:** the FPGA's TX goes to the ESP32's RX2, and the ESP32's TX2 to the FPGA's RX; I2S data and link MISO go from the FPGA to the ESP32."));
C.push(b("**ESP32 unplugged** is safe: the FPGA's pull-ups keep the lines quiet; the Spectrum boots and runs without the ESP32 (no SD card, no Bluetooth)."));
C.push(b("**USB on the ESP32** is for programming and debugging (a terminal at 115,200 baud shows the loader's messages and takes the Bluetooth commands). Pairing is done from LSpectrum: **F3** opens the Bluetooth menu."));
C.push(b("Pins avoided on the ESP32 on purpose: GPIO12 (the FPGA's pull-ups would select 1.8 V flash at boot), GPIO2 and GPIO15 (boot strapping), GPIO6-11 (flash)."));

C.push(h1("6. Power"));
C.push(table([2600, 6760], ["What", "From"], [
  ["Core board", "its own power input (USB or 5 V); everything else is fed from it"],
  ["I/O board", "5 V (VIN) from U8.63/64 through J1.64/63; U1 (K7803) makes its 3.3 V"],
  ["USB keyboard module", "5 V on J5.4 (USB power only; its UART is 3.3 V)"],
  ["ESP32 DevKit", "5 V into VIN from the I/O board"],
  ["microSD card", "3.3 V from U1 on the I/O board"],
]));

C.push(h1("7. Before switching on"));
C.push(n("Meter check of the header power pins (section 2) after any change in the wiring."));
C.push(n("Continuity check of the swapped wiring: J1.1 to U8.2 and J1.2 to U8.1 (ground), J1.63 to U8.64 and J1.64 to U8.63 (5 V), and no short between 5 V and ground."));
C.push(n("The configuration flash holds the LSpectrum image built for this I/O board."));
C.push(n("ESP32 and keyboard module plugged in the right way round (pin 1 / silkscreen)."));
C.push(n("The wires are short and the two boards fixed to each other, so the wires do not lever on U8."));

const doc = new Document({
  creator: "L", title: "LSpectrum connections",
  styles: {
    default: { document: { run: { font: FONT, size: 21 } } },
    paragraphStyles: [
      { id: "Heading1", name: "Heading 1", basedOn: "Normal", next: "Normal", quickFormat: true,
        run: { size: 28, bold: true, color: "1F3864", font: FONT }, paragraph: { outlineLevel: 0 } },
    ],
  },
  numbering: { config: [
    { reference: "bullets", levels: [{ level: 0, format: LevelFormat.BULLET, text: "•", alignment: AlignmentType.LEFT,
      style: { paragraph: { indent: { left: 540, hanging: 270 } } } }] },
    { reference: "check", levels: [{ level: 0, format: LevelFormat.DECIMAL, text: "%1.", alignment: AlignmentType.LEFT,
      style: { paragraph: { indent: { left: 540, hanging: 300 } } } }] },
  ] },
  sections: [{
    properties: { page: { size: { width: 12240, height: 15840 }, margin: { top: 1440, bottom: 1440, left: 1440, right: 1440 } } },
    footers: { default: new Footer({ children: [new Paragraph({ alignment: AlignmentType.CENTER, children: [
      new TextRun({ text: "LSpectrum connections  -  page ", size: 16, color: "808080", font: FONT }),
      new TextRun({ children: [PageNumber.CURRENT], size: 16, color: "808080", font: FONT })] })] }) },
    children: C,
  }],
});
Packer.toBuffer(doc).then(buf => { fs.writeFileSync(process.argv[2], buf); console.log("written", process.argv[2], buf.length); });
