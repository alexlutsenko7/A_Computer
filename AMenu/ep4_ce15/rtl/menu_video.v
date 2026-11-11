/* menu_video -- the machine menu: 32 x 24 text screen on 640x480@60 */
/* */
/* Same geometry as the LSpectrum OSD (zx_video): 32 x 24 characters of 16 x 16 */
/* VGA pixels, the 512 x 384 text area in the middle (border 64 px left/right, 48 */
/* lines top/bottom), white on blue. Font: Spleen 8x16 (FONT_HEX = menu_font.hex, */
/* tools/mk_menufont.py; ../font/): 8 x 16 font pixels per character, each shown */
/* 2 VGA pixels wide and 1 line tall. */
/* */
/* The text is a ROM (TEXT_HEX, tools/menu_text.py): rows ENTRY_ROW, */
/* ENTRY_ROW + 2, ... are the machines; the row of the selected one is shown */
/* inverse. Row ERR_ROW is only shown while err = 1. */
/* While osd_on = 1 the screen shows the ESP32's OSD text instead (written over the */
/* link: flash update, "no machines installed"), white on blue, bit 7 = inverse. */
/* */
/* Fetch per character (16 VGA pixels), la = x - 64 + 4 (4 px ahead): */
/* la[3:0] = 0: text address -> 1: character, font address -> 2: font row */
/* -> 3: loaded for the character that starts next clock. */
`default_nettype none

module menu_video #(
    parameter         FONT_HEX  = "font.hex",
    parameter         TEXT_HEX  = "menu_text.hex",
    parameter integer ENTRY_ROW = 6,
    parameter integer ERR_ROW   = 18
)(
/* 25.208 MHz */
    input  wire       pclk,
    input  wire       prst_n,
/* selected machine (other clock domain, quasi-static) */
    input  wire [2:0] sel,
/* show the error row (other clock domain, quasi-static) */
    input  wire       err,
/* shown in hex at columns 25-26 of the error row (static while err) */
    input  wire [4:0] cause,
/* shown in hex at columns 21-26 of the row below (static while err) */
    input  wire [23:0] addr,
/* two rows below: columns 25-26 */
    input  wire [4:0] cause2,
/* two rows below: column 7 */
    input  wire [1:0] mode,
/* show the OSD text (other clock domain, level) */
    input  wire       osd_on,
/* OSD text write port (tape_loader) */
    input  wire       osd_wclk,
    input  wire       osd_we,
    input  wire [9:0] osd_waddr,
    input  wire [7:0] osd_wdata,
    output reg  [3:0] vga_r,
    output reg  [3:0] vga_g,
    output reg  [3:0] vga_b,
    output reg        vga_hs,
    output reg        vga_vs
);

/* first pixel column of the text area (640 - 512) / 2 */
localparam [9:0] TEXT_X0 = 10'd64;
/* the text pipeline starts 4 pixels before the text area */
localparam [9:0] LOOK_X0 = 10'd60;
/* first line of the text area (480 - 384) / 2 */
localparam [9:0] TEXT_Y0 = 10'd48;
/* height of the text area: 24 rows of 16 lines */
localparam [9:0] TEXT_H = 10'd384;
/* width of the text area: 32 columns of 16 pixels */
localparam [9:0] TEXT_W = 10'd512;
/* text column of the address digit 5 (the first of six) */
localparam [4:0] COL_ADDR5 = 5'd21;
/* text column of the address digit 4 */
localparam [4:0] COL_ADDR4 = 5'd22;
/* text column of the address digit 3 */
localparam [4:0] COL_ADDR3 = 5'd23;
/* text column of the address digit 2 */
localparam [4:0] COL_ADDR2 = 5'd24;
/* text column of the address digit 1 and of the high digit of the two-digit values */
localparam [4:0] COL_HEX_HI = 5'd25;
/* text column of the last address digit and of the low digit of the two-digit values */
localparam [4:0] COL_HEX_LO = 5'd26;
/* rows per menu entry; also the last of the error rows (ERR_ROW .. ERR_ROW + 2) */
localparam integer ROW_STEP = 2;
/* text column of the mode digit */
localparam [4:0] COL_MODE = 5'd7;
/* nibbles from 10 on are shown as letters */
localparam [3:0] HEX_LETTERS = 4'd10;
/* character code of 0 */
localparam [7:0] ASCII_0 = 8'h30;
/* character code of A, minus 10 */
localparam [7:0] ASCII_A_10 = 8'h37;
/* pixel phase at which the font byte is ready */
localparam [3:0] PIPE_FONT = 4'd2;
/* bits of a font row */
localparam integer FONT_BITS = 8;
/* pixel phase at which the next character's bits are loaded */
localparam [3:0] PIPE_LOAD = 4'd3;
/* background of the error rows */
localparam [11:0] RGB_RED = 12'hA00;
/* background of the text area */
localparam [11:0] RGB_BLUE = 12'h00C;
/* colour around the text area */
localparam [11:0] RGB_DARK_BLUE = 12'h004;

reg [7:0] txt  [0:767];
/* OSD text (32 x 24 used) */
reg [7:0] otxt [0:1023];
/* 128 characters x 16 rows */
reg [7:0] font [0:2047];
initial
begin
    $readmemh(TEXT_HEX, txt);
/* the font */
    $readmemh(FONT_HEX, font);
end

/* the ESP32's text */
always @(posedge osd_wclk)
    if (osd_we)
    begin
        otxt[osd_waddr] <= osd_wdata;
    end

/* the cursor, the error flag and the OSD switch, synchronised */
reg [2:0] sel_s1, sel_s;
reg [1:0] err_s, osd_s;
always @(posedge pclk)
begin
/* two stages */
    sel_s1 <= sel;
    sel_s  <= sel_s1;
    err_s  <= {err_s[0], err};
/* the OSD switch */
    osd_s  <= {osd_s[0], osd_on};
end

/* 640x480 timing */
wire [9:0] hcnt, vcnt, x, y, h_act, v_act;
wire       active, hsync_n, vsync_n;

vga_timing u_timing (
    .clk     (pclk),
    .rst_n   (prst_n),
    .mode_50 (1'b0),
    .hcnt    (hcnt),
    .vcnt    (vcnt),
    .active  (active),
    .x       (x),
    .y       (y),
    .h_act   (h_act),
    .v_act   (v_act),
    .hsync_n (hsync_n),
    .vsync_n (vsync_n)
);

/* x inside the text area */
wire [9:0] rel   = x - TEXT_X0;
/* 4 pixels ahead */
wire [9:0] la    = x - LOOK_X0;
wire [9:0] ry    = y - TEXT_Y0;
wire       in_y  = active && y >= TEXT_Y0 && ry < TEXT_H;
/* inside the text area */
wire       in_x  = x >= TEXT_X0 && rel < TEXT_W;
wire       la_in = x >= LOOK_X0 && la < TEXT_W;
wire [4:0] row   = ry[8:4];

/* text and font fetch */
reg  [7:0] tq, fq, obm_next, obm;
wire [4:0] col  = la[8:4];
wire [3:0] anib = col == COL_ADDR5 ? addr[23:20] : col == COL_ADDR4 ? addr[19:16] : col == COL_ADDR3 ? addr[15:12] :
                  col == COL_ADDR2 ? addr[11:8]  : col == COL_HEX_HI ? addr[7:4]   : addr[3:0];
/* the address row and the mode row show hexadecimal digits */
wire       arow = row == ERR_ROW + 1 && col >= COL_ADDR5 && col <= COL_HEX_LO;
wire       mrow = row == ERR_ROW + ROW_STEP && (col == COL_MODE || col == COL_HEX_HI || col == COL_HEX_LO);
wire [3:0] nib  = arow ? anib :
                  mrow ? (col == COL_MODE ? {2'd0, mode} : col == COL_HEX_HI ? {3'd0, cause2[4]} : cause2[3:0]) :
                  col == COL_HEX_HI ? {3'd0, cause[4]} : cause[3:0];
/* the digit as a character */
wire [7:0] hexc = nib < HEX_LETTERS ? ASCII_0 + {4'd0, nib} : ASCII_A_10 + {4'd0, nib};
always @(posedge pclk)
begin
    tq <= osd_s[1] ? otxt[{row, col}] :
          (row == ERR_ROW && (col == COL_HEX_HI || col == COL_HEX_LO)) || arow || mrow ? hexc : txt[{row, col}];
/* the font row */
    fq <= font[{tq[6:0], ry[3:0]}];
end

/* the character's bitmap, loaded 1 pixel before its cell */
always @(posedge pclk or negedge prst_n)
    if (!prst_n)
    begin
        obm_next <= 8'd0;
/* reset */
        obm      <= 8'd0;
    end
    else if (in_y && la_in)
    begin
        if (la[3:0] == PIPE_FONT)
        begin
/* inverse characters */
            obm_next <= fq ^ {FONT_BITS{tq[7]}};
        end
        if (la[3:0] == PIPE_LOAD)
        begin
            obm      <= obm_next;
        end
    end

/* the cursor's row is inverse; the error rows only show after an error */
wire inv  = row == ENTRY_ROW + ROW_STEP * sel_s && !osd_s[1];
wire hide = (row >= ERR_ROW && row <= ERR_ROW + ROW_STEP) && !err_s[1] && !osd_s[1];
wire pix  = (obm[~rel[3:1]] ^ inv) && !hide;
/* the error rows: white on red */
wire red  = row >= ERR_ROW && row <= ERR_ROW + ROW_STEP && !osd_s[1];

always @(posedge pclk or negedge prst_n)
    if (!prst_n)
    begin
/* black, syncs inactive */
        {vga_r, vga_g, vga_b} <= 12'd0;
        vga_hs <= 1'b1;
        vga_vs <= 1'b1;
    end
    else
    begin
/* black outside the picture */
        if (!active)
        begin
            {vga_r, vga_g, vga_b} <= 12'd0;
        end
        else if (in_y && in_x)
        begin
/* text white */
            if (pix)
            begin
                {vga_r, vga_g, vga_b} <= 12'hFFF;
            end
            else if (red && err_s[1])
            begin
/* red or blue behind it */
                {vga_r, vga_g, vga_b} <= RGB_RED;
            end
            else
            begin
                {vga_r, vga_g, vga_b} <= RGB_BLUE;
            end
        end
        else
        begin
/* dark blue around the text area */
            {vga_r, vga_g, vga_b} <= RGB_DARK_BLUE;
        end
/* the syncs */
        vga_hs <= hsync_n;
        vga_vs <= vsync_n;
    end

endmodule

`default_nettype wire
