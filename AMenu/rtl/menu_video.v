//=============================================================================
// menu_video -- the machine menu: 32 x 24 text screen on 640x480@60
//
// Same geometry as the LSpectrum OSD (zx_video): 32 x 24 characters of 16 x 16
// VGA pixels, the 512 x 384 text area in the middle (border 64 px left/right, 48
// lines top/bottom), white on blue. Font: Spleen 8x16 (FONT_HEX = menu_font.hex,
// tools/mk_menufont.py; ../font/): 8 x 16 font pixels per character, each shown
// 2 VGA pixels wide and 1 line tall.
//
// The text is a ROM (TEXT_HEX, tools/menu_text.py): rows ENTRY_ROW,
// ENTRY_ROW + 2, ... are the machines; the row of the selected one is shown
// inverse. Row ERR_ROW is only shown while err = 1.
// While osd_on = 1 the screen shows the ESP32's OSD text instead (written over the
// link: flash update, "no machines installed"), white on blue, bit 7 = inverse.
//
// Fetch per character (16 VGA pixels), la = x - 64 + 4 (4 px ahead):
//   la[3:0] = 0: text address -> 1: character, font address -> 2: font row
//   -> 3: loaded for the character that starts next clock.
//=============================================================================
`default_nettype none

module menu_video #(
    parameter         FONT_HEX  = "font.hex",
    parameter         TEXT_HEX  = "menu_text.hex",
    parameter integer ENTRY_ROW = 6,
    parameter integer ERR_ROW   = 18
)(
    input  wire       pclk,             // 25.208 MHz
    input  wire       prst_n,
    input  wire [2:0] sel,              // selected machine (other clock domain, quasi-static)
    input  wire       err,              // show the error row (other clock domain, quasi-static)
    input  wire [4:0] cause,            // shown in hex at columns 25-26 of the error row (static while err)
    input  wire [23:0] addr,            // shown in hex at columns 21-26 of the row below (static while err)
    input  wire [4:0] cause2,           // two rows below: columns 25-26
    input  wire [1:0] mode,             // two rows below: column 7
    input  wire       osd_on,           // show the OSD text (other clock domain, level)
    input  wire       osd_wclk,         // OSD text write port (tape_loader)
    input  wire       osd_we,
    input  wire [9:0] osd_waddr,
    input  wire [7:0] osd_wdata,
    output reg  [3:0] vga_r,
    output reg  [3:0] vga_g,
    output reg  [3:0] vga_b,
    output reg        vga_hs,
    output reg        vga_vs
);

reg [7:0] txt  [0:767];
reg [7:0] otxt [0:1023];                // OSD text (32 x 24 used)
reg [7:0] font [0:2047];                // 128 characters x 16 rows
initial begin
    $readmemh(TEXT_HEX, txt);
    $readmemh(FONT_HEX, font);
end

always @(posedge osd_wclk)
    if (osd_we) otxt[osd_waddr] <= osd_wdata;

reg [2:0] sel_s1, sel_s;
reg [1:0] err_s, osd_s;
always @(posedge pclk) begin
    sel_s1 <= sel;
    sel_s  <= sel_s1;
    err_s  <= {err_s[0], err};
    osd_s  <= {osd_s[0], osd_on};
end

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

wire [9:0] rel   = x - 10'd64;          // x inside the text area
wire [9:0] la    = x - 10'd60;          // 4 pixels ahead
wire [9:0] ry    = y - 10'd48;
wire       in_y  = active && y >= 10'd48 && ry < 10'd384;
wire       in_x  = x >= 10'd64 && rel < 10'd512;
wire       la_in = x >= 10'd60 && la < 10'd512;
wire [4:0] row   = ry[8:4];

reg  [7:0] tq, fq, obm_next, obm;
wire [4:0] col  = la[8:4];
wire [3:0] anib = col == 5'd21 ? addr[23:20] : col == 5'd22 ? addr[19:16] : col == 5'd23 ? addr[15:12] :
                  col == 5'd24 ? addr[11:8]  : col == 5'd25 ? addr[7:4]   : addr[3:0];
wire       arow = row == ERR_ROW + 1 && col >= 5'd21 && col <= 5'd26;
wire       mrow = row == ERR_ROW + 2 && (col == 5'd7 || col == 5'd25 || col == 5'd26);
wire [3:0] nib  = arow ? anib :
                  mrow ? (col == 5'd7 ? {2'd0, mode} : col == 5'd25 ? {3'd0, cause2[4]} : cause2[3:0]) :
                  col == 5'd25 ? {3'd0, cause[4]} : cause[3:0];
wire [7:0] hexc = nib < 4'd10 ? 8'h30 + {4'd0, nib} : 8'h37 + {4'd0, nib};
always @(posedge pclk) begin
    tq <= osd_s[1] ? otxt[{row, col}] :
          (row == ERR_ROW && (col == 5'd25 || col == 5'd26)) || arow || mrow ? hexc : txt[{row, col}];
    fq <= font[{tq[6:0], ry[3:0]}];
end

always @(posedge pclk or negedge prst_n)
    if (!prst_n) begin
        obm_next <= 8'd0;
        obm      <= 8'd0;
    end else if (in_y && la_in) begin
        if (la[3:0] == 4'd2) obm_next <= fq ^ {8{tq[7]}};
        if (la[3:0] == 4'd3) obm      <= obm_next;
    end

wire inv  = row == ENTRY_ROW + 2 * sel_s && !osd_s[1];
wire hide = (row >= ERR_ROW && row <= ERR_ROW + 2) && !err_s[1] && !osd_s[1];
wire pix  = (obm[~rel[3:1]] ^ inv) && !hide;
wire red  = row >= ERR_ROW && row <= ERR_ROW + 2 && !osd_s[1];  // the error rows: white on red

always @(posedge pclk or negedge prst_n)
    if (!prst_n) begin
        {vga_r, vga_g, vga_b} <= 12'd0;
        vga_hs <= 1'b1;
        vga_vs <= 1'b1;
    end else begin
        if (!active)
            {vga_r, vga_g, vga_b} <= 12'd0;
        else if (in_y && in_x) begin
            if (pix)                    {vga_r, vga_g, vga_b} <= 12'hFFF;
            else if (red && err_s[1])   {vga_r, vga_g, vga_b} <= 12'hA00;
            else                        {vga_r, vga_g, vga_b} <= 12'h00C;
        end else
            {vga_r, vga_g, vga_b} <= 12'h004;
        vga_hs <= hsync_n;
        vga_vs <= vsync_n;
    end

endmodule

`default_nettype wire
