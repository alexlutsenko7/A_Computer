/* c64_video -- VIC-II picture (from the frame buffer, c64_fb) + the ESP32's OSD -> VGA */
/* */
/* Pixel clock = the frame buffer's pclk: L64 (c64_fb) 800 x 600 active at 60 Hz */
/* (39.80 MHz) or 50 Hz (31.51 MHz); LTari (atari_fb) 640 x 480 / 720 x 576. */
/* */
/* OSD (SD tape loader, as zx_video): 32 x 24 characters, 16 x 16 pixels each (Spleen 8x16: */
/* 16 font rows, one per VGA line; FONT_HEX = ../../AMenu/ep4_ce15/rtl/menu_font.hex), */
/* 512 x 384 in the middle of the active area (its size measured in the previous */
/* frame, so any mode is centred), Spectrum font (FONT_HEX), white on */
/* blue, bit 7 of a character = inverse; osd_full = 0 shows only the bottom row. */
/* The VIC-II picture and syncs are delayed by 2 clocks to line up with the text */
/* and font reads. */
/* */
/* Output: the top 4 bits of Kawari's 6-bit colours (the I/O board's 4-bit DAC). */
`default_nettype none

module c64_video #(
    parameter         FONT_HEX = "font.hex"
)(
/* pixel clock */
    input  wire       clk,
    input  wire [5:0] red,
    input  wire [5:0] green,
    input  wire [5:0] blue,
    input  wire       hsync,
    input  wire       vsync,
    input  wire       active,

/* OSD text write port (tape loader clock) */
    input  wire       osd_wclk,
    input  wire       osd_we,
    input  wire [9:0] osd_waddr,
    input  wire [7:0] osd_wdata,
/* tape loader clock domain */
    input  wire       osd_on,
    input  wire       osd_full,

    output reg  [3:0] vga_r,
    output reg  [3:0] vga_g,
    output reg  [3:0] vga_b,
    output reg        vga_hs,
    output reg        vga_vs
);

/* OSD's left edge until the picture is measured: (800 - 512) / 2 */
localparam [9:0] OSD_X_DEF = 10'd144;
/* OSD's top edge until the picture is measured: (600 - 384) / 2 */
localparam [9:0] OSD_Y_DEF = 10'd108;
/* OSD width: 32 columns of 16 pixels */
localparam [9:0] OSD_W = 10'd512;
/* OSD height: 24 rows of 16 lines */
localparam [9:0] OSD_H = 10'd384;
/* the text row of the status line */
localparam [4:0] OSD_LAST_ROW = 5'd23;
/* bits per colour of the VGA DAC */
localparam integer DAC_BITS = 4;
/* blue level of the OSD's background */
localparam [3:0] BLUE_BACK = 4'hC;

reg [7:0] txt  [0:1023];
/* 128 characters x 16 rows (2 M9K: read straight into fq) */
reg [7:0] font [0:2047];
initial $readmemh(FONT_HEX, font);

always @(posedge osd_wclk)
/* the OSD text memory is written */
    if (osd_we)
    begin
        txt[osd_waddr] <= osd_wdata;
    end

reg [1:0] on_s, full_s;
/* the OSD state in the pixel domain */
always @(posedge clk)
begin
    on_s   <= {on_s[0], osd_on};
    full_s <= {full_s[0], osd_full};
end

/* position inside the active area: x from the start of active, y counts active lines after vsync */
reg [9:0] x, y;
reg       act_p, vs_p;
always @(posedge clk)
begin
/* the previous levels */
    act_p <= active;
    vs_p  <= vsync;
    if (active)
    begin
/* the column counts inside a line */
        x <= act_p ? x + 10'd1 : 10'd0;
    end
/* both sync edges: counting starts after the pulse */
    if (vsync != vs_p)
    begin
        y <= 10'd0;
    end
    else if (act_p && !active)
    begin
/* the next line */
        y <= y + 10'd1;
    end
end

/* OSD position: the middle of the active area as measured (width at the end of each */
/* active line, height at the vsync edge after the active lines) */
/* (800 - 512) / 2, (600 - 384) / 2 until measured */
reg [9:0] osd_x = OSD_X_DEF, osd_y = OSD_Y_DEF;
always @(posedge clk)
begin
    if (act_p && !active)
    begin
/* the OSD's left edge; its top edge at the end of the frame */
        osd_x <= (x + 10'd1 - OSD_W) >> 1;
    end
    if (vsync != vs_p && y != 10'd0)
    begin
        osd_y <= (y - OSD_H) >> 1;
    end
end

/* the position inside the OSD */
wire [9:0] rx    = x - osd_x;
wire [9:0] ry    = y - osd_y;
wire       in_o  = active && act_p && x >= osd_x && rx < OSD_W && y >= osd_y && ry < OSD_H;
/* its last text row */
wire       row23 = ry[8:4] == OSD_LAST_ROW;

/* text -> font -> pixel, 2 clocks; picture and syncs delayed to match */
/* fq: the font byte as read (a ROM in block RAM needs that) */
reg  [7:0] tq, fq;
/* bit 7 of the character: inverse */
reg        inv_d;
/* rx[3:0] delayed */
reg  [3:0] col_d1, col_d2;
reg  [1:0] in_d, row_d;
reg  [3:0] frow_d1;
/* the picture, delayed twice; the syncs */
reg [17:0] rgb_d1, rgb_d2;
reg  [1:0] hs_d, vs_d;
always @(posedge clk)
begin
/* the character; its font row */
    tq      <= txt[{ry[8:4], rx[8:4]}];
    frow_d1 <= ry[3:0];
    fq      <= font[{tq[6:0], frow_d1}];
/* inverse, the pixel column */
    inv_d   <= tq[7];
    col_d1  <= rx[3:0];
    col_d2  <= col_d1;
/* inside the OSD, the last row; the picture */
    in_d    <= {in_d[0], in_o};
    row_d   <= {row_d[0], row23};
    rgb_d1  <= active ? {red, green, blue} : 18'd0;
/* its second delay; the syncs */
    rgb_d2  <= rgb_d1;
    hs_d    <= {hs_d[0], hsync};
    vs_d    <= {vs_d[0], vsync};
end

/* the OSD shows here; its pixel */
wire osd_here = in_d[1] && on_s[1] && (full_s[1] || row_d[1]);
wire opix     = fq[~col_d2[3:1]] ^ inv_d;

always @(posedge clk)
begin
/* white on blue */
    if (osd_here)
    begin
        vga_r <= {DAC_BITS{opix}};
        vga_g <= {DAC_BITS{opix}};
/* blue: text bright, background darker */
        vga_b <= opix ? 4'hF : BLUE_BACK;
    end
    else
    begin
        vga_r <= rgb_d2[17:14];
        vga_g <= rgb_d2[11:8];
/* the picture's blue; the syncs */
        vga_b <= rgb_d2[5:2];
    end
    vga_hs <= hs_d[1];
    vga_vs <= vs_d[1];
end

endmodule

/* other files keep the default net type */
`default_nettype wire
