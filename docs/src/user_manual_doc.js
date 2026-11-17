/* user_manual_doc.js -- the user manual (the whole system from the user's side) in every language: */
/* docs/manuals/doc/L_User_Manual_<code>.docx, and the English one also as docs/L_User_Manual.docx. */
/* Run in docs/src (docx package on NODE_PATH): node user_manual_doc.js [code ...] */
const fs = require("fs");
const path = require("path");
const {
  Document, Packer, Paragraph, TextRun, Table, TableRow, TableCell, WidthType,
  ShadingType, HeadingLevel, AlignmentType, LevelFormat, BorderStyle, Footer, PageNumber,
} = require("docx");

/* page: US Letter, 1 inch margins; all lengths in DXA (1/1440 inch) */
const PAGE_W = 12240;
const PAGE_H = 15840;
const MARGIN = 1440;
const TEXT_W = 9360;
const PERCENT = 100;
/* font sizes in half points */
const SZ_TITLE = 44;
const SZ_BODY = 21;
const SZ_TABLE = 20;
const SZ_CODE = 19;
const SZ_SCREEN = 18;
const SZ_FOOT = 17;
const SZ_H1 = 30;
const SZ_H2 = 24;
/* spacing and indents */
const SP_TITLE = 80;
const SP_SUB = 280;
const SP_H1_BEFORE = 320;
const SP_H1_AFTER = 120;
const SP_H2_BEFORE = 220;
const SP_H2_AFTER = 100;
const SP_PARA = 110;
const SP_ITEM = 60;
const SP_AFTER_TABLE = 140;
const IND_LEFT = 540;
const IND_HANG = 300;
const CELL_MV = 60;
const CELL_MH = 100;
const NOTE_M = 120;
const LINE_SZ = 4;
const BAR_SZ = 18;
/* slice lengths of the markers in the text: **bold** and `code` */
const MARK_BOLD = 2;
const MARK_CODE = 1;
const LEVEL_FIRST = 0;
const STEP_ONE = 1;
/* colours and fonts */
const FONT = "Calibri";
const FONT_CODE = "Consolas";
const COL_HEAD = "1F3864";
const COL_GREY = "595959";
const COL_LINE = "A6A6A6";
const COL_NOTE = "FFF4D6";
const COL_NOTE_BAR = "E0A800";
const COL_SCREEN_BG = "1F2A6B";
const COL_SCREEN_FG = "FFFFFF";
const COL_WHITE = "FFFFFF";
const BULLETS = "bullets";
const OL_PREFIX = "ol";

/* the languages: text in user_manual/lang_<code>.js (English is the reference); */
/* the font is the one used for East Asian characters */
const LANGS = [
  { code: "EN", font: "Calibri" },
  { code: "SP", font: "Calibri" },
  { code: "PT", font: "Calibri" },
  { code: "DE", font: "Calibri" },
  { code: "UA", font: "Calibri" },
  { code: "RU", font: "Calibri" },
  { code: "CN", font: "Microsoft YaHei" },
  { code: "KR", font: "Malgun Gothic" },
  { code: "JP", font: "Yu Gothic" },
];
const REFERENCE = "EN";
const OUT_REFERENCE = "../L_User_Manual.docx";
const OUT_DIR = "../manuals/doc";

/* ---------------------------------------------------------------- builders */

const g_s_line = { style: BorderStyle.SINGLE, size: LINE_SZ, color: COL_LINE };
const g_s_none = { style: BorderStyle.NONE, size: 0, color: COL_WHITE };
const g_s_borders = { top: g_s_line, bottom: g_s_line, left: g_s_line, right: g_s_line };
/* the fonts of the language being built (set by make) */
let g_s_font = { ascii: FONT, hAnsi: FONT, cs: FONT, eastAsia: FONT };
let g_s_font_screen = { ascii: FONT_CODE, hAnsi: FONT_CODE, cs: FONT_CODE, eastAsia: FONT };

/* text with **bold** and `code` segments -> TextRuns */
function runs(pc_text, ui32_size)
{
  let a_parts;
  let a_out;
  a_parts = pc_text.split(/(\*\*[^*]+\*\*|`[^`]+`)/).filter(Boolean);
  /* one run per segment */
  a_out = a_parts.map((pc_part) =>
  {
    let s_run;
    if (pc_part.startsWith("**"))
    {
      /* bold */
      s_run = new TextRun({ text: pc_part.slice(MARK_BOLD, -MARK_BOLD), bold: true, font: g_s_font, size: ui32_size });
    }
    else if (pc_part.startsWith("`") && pc_part.endsWith("`") && pc_part.length > MARK_CODE)
    {
      /* file names and what the user types */
      s_run = new TextRun({ text: pc_part.slice(MARK_CODE, -MARK_CODE), font: FONT_CODE, size: SZ_CODE });
    }
    else
    {
      /* plain text */
      s_run = new TextRun({ text: pc_part, font: g_s_font, size: ui32_size });
    }
    return s_run;
  });
  return a_out;
}

/* one table cell; the header row is white on dark blue */
function cell(pc_text, ui32_width, b_head)
{
  let a_children;
  let s_shading;
  a_children = runs(pc_text, SZ_TABLE);
  s_shading = undefined;
  if (b_head)
  {
    /* header: one bold white run */
    a_children = [new TextRun({ text: pc_text, bold: true, color: COL_WHITE, font: g_s_font, size: SZ_TABLE })];
    s_shading = { type: ShadingType.CLEAR, color: "auto", fill: COL_HEAD };
  }
  return new TableCell({
    width: { size: ui32_width, type: WidthType.DXA },
    borders: g_s_borders,
    shading: s_shading,
    margins: { top: CELL_MV, bottom: CELL_MV, left: CELL_MH, right: CELL_MH },
    children: [new Paragraph({ children: a_children })],
  });
}

/* column widths in percent -> DXA; the last column takes what is left */
function widths(a_percent)
{
  let a_dxa;
  let ui32_used;
  a_dxa = a_percent.map((ui32_p) => Math.floor(TEXT_W * ui32_p / PERCENT));
  ui32_used = a_dxa.slice(0, -STEP_ONE).reduce((ui32_a, ui32_b) => ui32_a + ui32_b, 0);
  /* no rounding gap at the right edge */
  a_dxa[a_dxa.length - STEP_ONE] = TEXT_W - ui32_used;
  return a_dxa;
}

/* a table with a repeated header row; rows are not split over pages */
function table(a_header, a_rows, a_percent)
{
  let a_w;
  let a_trows;
  a_w = widths(a_percent);
  a_trows = a_rows.map((a_row) => new TableRow({
    cantSplit: true,
    children: a_row.map((pc_text, ui32_i) => cell(pc_text, a_w[ui32_i], false)),
  }));
  /* header first */
  a_trows.unshift(new TableRow({
    tableHeader: true,
    children: a_header.map((pc_text, ui32_i) => cell(pc_text, a_w[ui32_i], true)),
  }));
  return new Table({ width: { size: TEXT_W, type: WidthType.DXA }, columnWidths: a_w, rows: a_trows });
}

/* a one-cell box: the note (yellow, bar at the left) or a screen (white on blue, fixed pitch) */
function box(a_paragraphs, pc_fill, s_left)
{
  let s_cell;
  s_cell = new TableCell({
    width: { size: TEXT_W, type: WidthType.DXA },
    borders: { top: g_s_none, bottom: g_s_none, right: g_s_none, left: s_left },
    shading: { type: ShadingType.CLEAR, color: "auto", fill: pc_fill },
    margins: { top: NOTE_M, bottom: NOTE_M, left: NOTE_M + CELL_MH, right: NOTE_M },
    children: a_paragraphs,
  });
  /* the row may not break over a page */
  return new Table({
    width: { size: TEXT_W, type: WidthType.DXA },
    columnWidths: [TEXT_W],
    rows: [new TableRow({ cantSplit: true, children: [s_cell] })],
  });
}

/* a heading; kept with the paragraph after it */
function heading(pc_text, b_first)
{
  let s_par;
  s_par = new Paragraph({
    heading: b_first ? HeadingLevel.HEADING_1 : HeadingLevel.HEADING_2,
    keepNext: true,
    spacing: b_first ? { before: SP_H1_BEFORE, after: SP_H1_AFTER } : { before: SP_H2_BEFORE, after: SP_H2_AFTER },
    children: [new TextRun({ text: pc_text, font: g_s_font })],
  });
  return s_par;
}

/* list items; pc_ref is the numbering instance (bullets, or one per numbered list) */
function list(a_items, pc_ref)
{
  let a_pars;
  a_pars = a_items.map((pc_text) => new Paragraph({
    numbering: { reference: pc_ref, level: LEVEL_FIRST },
    spacing: { after: SP_ITEM },
    children: runs(pc_text, SZ_BODY),
  }));
  return a_pars;
}

/* the gap under a table or a box */
function gap()
{
  return new Paragraph({ spacing: { after: SP_AFTER_TABLE - SP_PARA }, children: [] });
}

/* one block of BLOCKS -> the document's elements; ui32_ol numbers the numbered lists */
function build(a_block, ui32_ol)
{
  let a_out;
  let pc_kind;
  a_out = [];
  pc_kind = a_block[0];
  if (pc_kind === "h1" || pc_kind === "h2")
  {
    a_out = [heading(a_block[STEP_ONE], pc_kind === "h1")];
  }
  else if (pc_kind === "p")
  {
    a_out = [new Paragraph({ spacing: { after: SP_PARA }, children: runs(a_block[STEP_ONE], SZ_BODY) })];
  }
  else if (pc_kind === "ul")
  {
    a_out = list(a_block[STEP_ONE], BULLETS);
  }
  else if (pc_kind === "ol")
  {
    /* its own instance, so that it starts at 1 */
    a_out = list(a_block[STEP_ONE], OL_PREFIX + ui32_ol);
  }
  else if (pc_kind === "table")
  {
    a_out = [table(a_block[STEP_ONE], a_block[STEP_ONE + STEP_ONE], a_block[STEP_ONE + STEP_ONE + STEP_ONE]), gap()];
  }
  else if (pc_kind === "note")
  {
    /* yellow box with a bar at the left */
    a_out = [box([new Paragraph({ children: runs(a_block[STEP_ONE], SZ_TABLE) })], COL_NOTE,
      { style: BorderStyle.SINGLE, size: BAR_SZ, color: COL_NOTE_BAR }), gap()];
  }
  else if (pc_kind === "screen")
  {
    /* what the monitor shows: fixed pitch, white on blue */
    a_out = [box(a_block[STEP_ONE].map((pc_line) => new Paragraph({
      children: [new TextRun({ text: pc_line, font: g_s_font_screen, size: SZ_SCREEN, color: COL_SCREEN_FG })],
    })), COL_SCREEN_BG, g_s_none), gap()];
  }
  else
  {
    throw new Error("unknown block " + pc_kind);
  }
  return a_out;
}

/* one language's document -> its file(s); the promise ends when they are written */
function make(s_lang)
{
  let s_text;
  let a_children;
  let a_numbering;
  let a_files;
  let ui32_ol;
  let s_doc;
  let p_done;
  ui32_ol = 0;
  s_text = require("./user_manual/lang_" + s_lang.code.toLowerCase() + ".js");
  a_files = [path.join(OUT_DIR, "L_User_Manual_" + s_lang.code + ".docx")];
  if (s_lang.code === REFERENCE)
  {
    /* the English one is also the document in docs/ */
    a_files.push(OUT_REFERENCE);
  }
  g_s_font = { ascii: FONT, hAnsi: FONT, cs: FONT, eastAsia: s_lang.font };
  g_s_font_screen = { ascii: FONT_CODE, hAnsi: FONT_CODE, cs: FONT_CODE, eastAsia: s_lang.font };
  /* title and subtitle */
  a_children = [
    new Paragraph({ spacing: { after: SP_TITLE }, children: [new TextRun({ text: s_text.title, bold: true, size: SZ_TITLE, font: g_s_font, color: COL_HEAD })] }),
    new Paragraph({ spacing: { after: SP_SUB }, children: [new TextRun({ text: s_text.subtitle, size: SZ_BODY, font: g_s_font, color: COL_GREY })] }),
  ];
  a_numbering = [{
    reference: BULLETS,
    levels: [{ level: LEVEL_FIRST, format: LevelFormat.BULLET, text: "•", alignment: AlignmentType.LEFT,
      style: { paragraph: { indent: { left: IND_LEFT, hanging: IND_HANG } } } }],
  }];
  /* the blocks; every numbered list gets its own numbering instance */
  s_text.blocks.forEach((a_block) =>
  {
    if (a_block[0] === "ol")
    {
      a_numbering.push({
        reference: OL_PREFIX + ui32_ol,
        levels: [{ level: LEVEL_FIRST, format: LevelFormat.DECIMAL, text: "%1.", alignment: AlignmentType.LEFT,
          style: { paragraph: { indent: { left: IND_LEFT, hanging: IND_HANG } } } }],
      });
    }
    a_children.push(...build(a_block, ui32_ol));
    if (a_block[0] === "ol")
    {
      /* next list, next instance */
      ui32_ol = ui32_ol + STEP_ONE;
    }
  });
  s_doc = new Document({
    creator: "L project",
    title: s_text.title,
    numbering: { config: a_numbering },
    styles: {
      default: { document: { run: { font: g_s_font, size: SZ_BODY } } },
      paragraphStyles: [
        { id: "Heading1", name: "Heading 1", basedOn: "Normal", next: "Normal", quickFormat: true,
          run: { size: SZ_H1, bold: true, font: g_s_font, color: COL_HEAD }, paragraph: { outlineLevel: 0 } },
        { id: "Heading2", name: "Heading 2", basedOn: "Normal", next: "Normal", quickFormat: true,
          run: { size: SZ_H2, bold: true, font: g_s_font, color: COL_HEAD }, paragraph: { outlineLevel: STEP_ONE } },
      ],
    },
    sections: [{
      properties: { page: { size: { width: PAGE_W, height: PAGE_H }, margin: { top: MARGIN, right: MARGIN, bottom: MARGIN, left: MARGIN } } },
      /* footer: title and page number */
      footers: { default: new Footer({ children: [new Paragraph({
        alignment: AlignmentType.CENTER,
        children: [
          new TextRun({ text: s_text.title + "  ·  " + s_text.page + " ", font: g_s_font, size: SZ_FOOT, color: COL_GREY }),
          new TextRun({ children: [PageNumber.CURRENT], font: g_s_font, size: SZ_FOOT, color: COL_GREY }),
        ],
      })] }) },
      children: a_children,
    }],
  });
  /* write the file(s) */
  p_done = Packer.toBuffer(s_doc).then((p_buf) =>
  {
    a_files.forEach((pc_file) =>
    {
      fs.writeFileSync(pc_file, p_buf);
      console.log("written " + pc_file + " (" + p_buf.length + " bytes)");
    });
  });
  return p_done;
}

/* the languages named on the command line, or all; one after the other (the fonts are global) */
async function main()
{
  let a_codes;
  let a_todo;
  let ui32_i;
  a_codes = process.argv.slice(STEP_ONE + STEP_ONE).map((pc_code) => pc_code.toUpperCase());
  a_todo = LANGS.filter((s_lang) => a_codes.length === 0 || a_codes.includes(s_lang.code));
  fs.mkdirSync(OUT_DIR, { recursive: true });
  for (ui32_i = 0; ui32_i < a_todo.length; ui32_i = ui32_i + STEP_ONE)
  {
    /* wait: the next language changes the fonts */
    await make(a_todo[ui32_i]);
  }
}

main();
