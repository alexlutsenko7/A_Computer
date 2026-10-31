//=============================================================================
// c64_video -- VIC-II picture (from the frame buffer, c64_fb) + the ESP32's OSD -> VGA
//
// Pixel clock = the frame buffer's pclk: L64 (c64_fb) 800 x 600 active at 60 Hz
// (39.80 MHz) or 50 Hz (31.51 MHz); LTari (atari_fb) 640 x 480 / 720 x 576.
//
// OSD (SD tape loader, as zx_video): 32 x 24 characters, 16 x 16 pixels each (Spleen 8x16:
// 16 font rows, one per VGA line; FONT_HEX = ../AMenu/rtl/menu_font.hex),
// 512 x 384 in the middle of the active area (its size measured in the previous
// frame, so any mode is centred), Spectrum font (FONT_HEX), white on
// blue, bit 7 of a character = inverse; osd_full = 0 shows only the bottom row.
// The VIC-II picture and syncs are delayed by 2 clocks to line up with the text
// and font reads.
//
// Output: the top 4 bits of Kawari's 6-bit colours (the I/O board's 4-bit DAC).
//=============================================================================
`default_nettype none

module c64_video #(
    parameter         FONT_HEX = "font.hex"
)(
    input  wire       clk,              // pixel clock
    input  wire [5:0] red,
    input  wire [5:0] green,
    input  wire [5:0] blue,
    input  wire       hsync,
    input  wire       vsync,
    input  wire       active,

    input  wire       osd_wclk,         // OSD text write port (tape loader clock)
    input  wire       osd_we,
    input  wire [9:0] osd_waddr,
    input  wire [7:0] osd_wdata,
    input  wire       osd_on,           // tape loader clock domain
    input  wire       osd_full,

    output reg  [3:0] vga_r,
    output reg  [3:0] vga_g,
    output reg  [3:0] vga_b,
    output reg        vga_hs,
    output reg        vga_vs
);

reg [7:0] txt  [0:1023];
reg [7:0] font [0:2047];                // 128 characters x 16 rows (2 M9K: read straight into fq)
initial $readmemh(FONT_HEX, font);

always @(posedge osd_wclk)
    if (osd_we) txt[osd_waddr] <= osd_wdata;

reg [1:0] on_s, full_s;
always @(posedge clk) begin
    on_s   <= {on_s[0], osd_on};
    full_s <= {full_s[0], osd_full};
end

// position inside the active area: x from the start of active, y counts active lines after vsync
reg [9:0] x, y;
reg       act_p, vs_p;
always @(posedge clk) begin
    act_p <= active;
    vs_p  <= vsync;
    if (active) x <= act_p ? x + 10'd1 : 10'd0;
    if (vsync != vs_p)          y <= 10'd0;      // both sync edges: counting starts after the pulse
    else if (act_p && !active)  y <= y + 10'd1;
end

// OSD position: the middle of the active area as measured (width at the end of each
// active line, height at the vsync edge after the active lines)
reg [9:0] osd_x = 10'd144, osd_y = 10'd108;     // (800 - 512) / 2, (600 - 384) / 2 until measured
always @(posedge clk) begin
    if (act_p && !active)          osd_x <= (x + 10'd1 - 10'd512) >> 1;
    if (vsync != vs_p && y != 10'd0) osd_y <= (y - 10'd384) >> 1;
end

wire [9:0] rx    = x - osd_x;
wire [9:0] ry    = y - osd_y;
wire       in_o  = active && act_p && x >= osd_x && rx < 10'd512 && y >= osd_y && ry < 10'd384;
wire       row23 = ry[8:4] == 5'd23;

// text -> font -> pixel, 2 clocks; picture and syncs delayed to match
reg  [7:0] tq, fq;                      // fq: the font byte as read (a ROM in block RAM needs that)
reg        inv_d;                       // bit 7 of the character: inverse
reg  [3:0] col_d1, col_d2;              // rx[3:0] delayed
reg  [1:0] in_d, row_d;
reg  [3:0] frow_d1;
reg [17:0] rgb_d1, rgb_d2;
reg  [1:0] hs_d, vs_d;
always @(posedge clk) begin
    tq      <= txt[{ry[8:4], rx[8:4]}];
    frow_d1 <= ry[3:0];
    fq      <= font[{tq[6:0], frow_d1}];
    inv_d   <= tq[7];
    col_d1  <= rx[3:0];
    col_d2  <= col_d1;
    in_d    <= {in_d[0], in_o};
    row_d   <= {row_d[0], row23};
    rgb_d1  <= active ? {red, green, blue} : 18'd0;
    rgb_d2  <= rgb_d1;
    hs_d    <= {hs_d[0], hsync};
    vs_d    <= {vs_d[0], vsync};
end

wire osd_here = in_d[1] && on_s[1] && (full_s[1] || row_d[1]);
wire opix     = fq[~col_d2[3:1]] ^ inv_d;

always @(posedge clk) begin
    if (osd_here) begin                 // white on blue
        vga_r <= {4{opix}};
        vga_g <= {4{opix}};
        vga_b <= opix ? 4'hF : 4'hC;
    end else begin
        vga_r <= rgb_d2[17:14];
        vga_g <= rgb_d2[11:8];
        vga_b <= rgb_d2[5:2];
    end
    vga_hs <= hs_d[1];
    vga_vs <= vs_d[1];
end

endmodule

`default_nettype wire
