/* zx_video -- ZX Spectrum screen on VGA, with the screen shadows */
/* */
/* Pixel clock domain (25.208 MHz for 640x480@60, 27.009 MHz for 720x576@50; mode50 is */
/* static while running, see vga_timing / LSpectrum.v). Each Spectrum pixel is */
/* 2 x 2 VGA pixels; the 512 x 384 picture sits in the middle of the active area: */
/* 640x480: border 64 px left/right, 48 lines top/bottom */
/* 720x576: border 104 px left/right, 96 lines top/bottom */
/* */
/* Screen shadows: block-RAM copies of the first 6912 bytes of RAM pages 5 and */
/* 7, written by the CPU side (wclk) in parallel with the SDRAM, read here. */
/* */
/* Fetch per 8-pixel cell (16 VGA pixels), la = x - border + 4 (4 px ahead): */
/* la[3:0] = 0: bitmap address -> 1: bitmap byte, attribute address */
/* -> 2: attribute byte -> 3: both loaded for the cell that starts next clock. */
/* */
/* Frame interrupt (50 Hz mode): frame_n falls at int_pos (VGA line, pixel after the */
/* start of vsync), set by the tape loader (Page Up / Page Down in 1/8 lines; default */
/* line 24, pixel 166 = "24.1", measured: see History). Calculated so the Spectrum frame lines up with the */
/* picture as on a real 128K: the interrupt comes 14364 T-states (63 lines of 228 T) */
/* before the first picture line. Our first picture line is 140 VGA lines (4480 us) */
/* after vsync, plus 236 / 27 MHz to the first picture pixel; a 128K line is 64.28 us */
/* against 2 VGA lines = 64 us, so the match is made in the middle (row 96): */
/* 4480 + 8.7 + 96 * 64 - (14364 + 96 * 228) / 3.5469 MHz = 412 us = 12 lines + 756 px. */
/* History (2026-10-09, Aquaplane's horizon = a border colour change timed from the */
/* interrupt): at vsync the stripe was ~45 lines too high; without memory contention */
/* it lined up at 44.7..45.7 (line 45, pixel 328), about 1 ms later than calculated, */
/* because the game's timing loop is slowed by contention on a real machine. With */
/* Level-1 contention (zx_bus) it lines up at 24.1..24.2 (user, hardware): the default, */
/* line 24, pixel 166. The remaining ~11.5 lines against the calculated 12.7 are most */
/* likely the internal contended T-states Level 1 does not emulate (DJNZ, PUSH, ...) */
/* and/or Aquaplane being timed for the 48K (224 T lines). */
/* */
/* OSD (SD tape loader): 32 x 24 characters over the 256 x 192 picture, the menu's */
/* Spleen 8x16 font (FONT_HEX = ../../AMenu/ep4_ce15/rtl/menu_font.hex: 16 rows per character, one */
/* per VGA line), white on blue, bit 7 of a character = */
/* inverse. osd_full = 0 shows only the bottom row (status bar). Same fetch */
/* timing: la 0: text address -> 1: character, font address -> 2: font row. */
`default_nettype none

module zx_video #(
    parameter FONT_HEX = "../../AMenu/ep4_ce15/rtl/menu_font.hex"
)(
    input  wire        pclk,
    input  wire        prst_n,
    input  wire        mode50,

/* CPU clock domain */
    input  wire [2:0]  border,
/* CPU clock domain (7FFD bit 3) */
    input  wire        screen7,

/* shadow write port (CPU clock domain) */
    input  wire        wclk,
    input  wire        sh_we,
    input  wire        sh_page7,
    input  wire [12:0] sh_addr,
    input  wire [7:0]  sh_data,

/* OSD text write port (tape loader clock) */
    input  wire        osd_wclk,
    input  wire        osd_we,
    input  wire [9:0]  osd_waddr,
    input  wire [7:0]  osd_wdata,
/* tape loader clock domain */
    input  wire        osd_on,
    input  wire        osd_full,
/* frame interrupt position {pixel, line} (tape loader clock, quasi-static) */
    input  wire [19:0] int_pos,

    output reg         vga_r,
    output reg         vga_r_low,
    output reg         vga_g,
    output reg         vga_g_low,
    output reg         vga_b,
    output reg         vga_b_low,
    output reg         vga_hs,
    output reg         vga_vs,
/* falls at the Spectrum frame interrupt (50 Hz mode) */
    output reg         frame_n
);

/* the interrupt line stays marked for 4 lines */
localparam [9:0] INT_LINES = 10'd4;
/* lines of the 50 Hz frame */
localparam [9:0] LINES_50 = 10'd625;
/* first column of the picture, 50 Hz: (720 - 512) / 2 */
localparam [9:0] PIC_X0_50 = 10'd104;
/* first column of the picture, 60 Hz: (640 - 512) / 2 */
localparam [9:0] PIC_X0_60 = 10'd64;
/* first line of the picture, 50 Hz: (576 - 384) / 2 */
localparam [9:0] PIC_Y0_50 = 10'd96;
/* first line of the picture, 60 Hz: (480 - 384) / 2 */
localparam [9:0] PIC_Y0_60 = 10'd48;
/* the pixel pipeline starts 4 pixels before the picture */
localparam [9:0] LOOK_AHEAD = 10'd4;
/* picture height: 192 lines, doubled */
localparam [9:0] PIC_H = 10'd384;
/* picture width: 256 pixels, doubled */
localparam [9:0] PIC_W = 10'd512;
/* pixel phase at which the font byte is ready */
localparam [3:0] PIPE_FONT = 4'd2;
/* bits of a font row */
localparam integer FONT_BITS = 8;
/* pixel phase at which the next character's bits are loaded */
localparam [3:0] PIPE_LOAD = 4'd3;
/* the text row of the status line */
localparam [4:0] OSD_LAST_ROW = 5'd23;

/* Shadows (simple dual port, separate clocks) */
/* 7 blocks of 1K x 8 per shadow. For Quartus they are explicit altsyncrams: inferred from the */
/* arrays, synthesis counts 8 M9K each (8K x 1 slices). Simulation uses the arrays (testbenches */
/* read them). */
reg  [7:0]  q5, q7;
reg  [12:0] raddr;
`ifdef ALTERA_RESERVED_QIS
/* the RAM blocks' outputs, as the registers the rest of the module reads */
wire [7:0]  q5w, q7w;
always @*
begin
    q5 = q5w;
/* page 7 */
    q7 = q7w;
end

/* page 5's shadow */
altsyncram #(
    .operation_mode ("DUAL_PORT"), .intended_device_family ("Cyclone IV E"), .ram_block_type ("M9K"),
    .width_a (8), .widthad_a (13), .numwords_a (6912), .width_b (8), .widthad_b (13), .numwords_b (6912),
    .maximum_depth (1024), .address_reg_b ("CLOCK1"), .outdata_reg_b ("UNREGISTERED"),
    .address_aclr_b ("NONE"), .outdata_aclr_b ("NONE"), .power_up_uninitialized ("FALSE"),
    .lpm_type ("altsyncram")
) u_sh5 (
    .clock0 (wclk), .address_a (sh_addr), .data_a (sh_data), .wren_a (sh_we && !sh_page7),
    .clock1 (pclk), .address_b (raddr), .q_b (q5w)
);

/* page 7's */
altsyncram #(
    .operation_mode ("DUAL_PORT"), .intended_device_family ("Cyclone IV E"), .ram_block_type ("M9K"),
    .width_a (8), .widthad_a (13), .numwords_a (6912), .width_b (8), .widthad_b (13), .numwords_b (6912),
    .maximum_depth (1024), .address_reg_b ("CLOCK1"), .outdata_reg_b ("UNREGISTERED"),
    .address_aclr_b ("NONE"), .outdata_aclr_b ("NONE"), .power_up_uninitialized ("FALSE"),
    .lpm_type ("altsyncram")
) u_sh7 (
    .clock0 (wclk), .address_a (sh_addr), .data_a (sh_data), .wren_a (sh_we && sh_page7),
    .clock1 (pclk), .address_b (raddr), .q_b (q7w)
);
`else
reg [7:0] sh5 [0:6911];
/* for simulation: plain arrays */
reg [7:0] sh7 [0:6911];

always @(posedge wclk)
    if (sh_we)
    begin
/* the page written */
        if (sh_page7)
        begin
            sh7[sh_addr] <= sh_data;
        end
        else
        begin
            sh5[sh_addr] <= sh_data;
        end
    end

/* registered read */
always @(posedge pclk)
begin
    q5 <= sh5[raddr];
/* page 7 */
    q7 <= sh7[raddr];
end
`endif

/* OSD text (simple dual port, separate clocks) and font ROM */
reg [7:0] txt  [0:1023];
/* 128 characters x 16 rows */
reg [7:0] font [0:2047];
reg [7:0] tq, fq;
reg [9:0] taddr;
/* the font */
initial $readmemh(FONT_HEX, font);

always @(posedge osd_wclk)
    if (osd_we)
    begin
/* the tape loader writes the text */
        txt[osd_waddr] <= osd_wdata;
    end

/* the OSD switches, synchronised */
reg [1:0] oon_s, ofull_s;
always @(posedge pclk)
begin
    oon_s   <= {oon_s[0],   osd_on};
/* full screen or status bar */
    ofull_s <= {ofull_s[0], osd_full};
end

/* Inputs from the CPU domain */
reg [2:0] border_s1, border_s2;
reg [1:0] scr_s;
always @(posedge pclk)
begin
/* two stages */
    border_s1 <= border;
    border_s2 <= border_s1;
    scr_s     <= {scr_s[0], screen7};
end
/* the screen shown: page 5 or page 7 */
wire [7:0] q = scr_s[1] ? q7 : q5;

/* Timing */
wire [9:0] hcnt, vcnt, x, y, h_act, v_act;
wire       active, hsync_n, vsync_n;

vga_timing u_timing (
    .clk     (pclk),
    .rst_n   (prst_n),
    .mode_50 (mode50),
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

/* frame interrupt mark: low for 4 lines from int_pos (line [9:0], pixel [19:10]), */
/* set by the tape loader (Page Up / Page Down move it, for lining up border effects */
/* on the TV); a change can cost or add one interrupt, nothing else. */
reg [19:0] ip_s1, ip_s2;
always @(posedge pclk)
begin
    ip_s1 <= int_pos;
/* the interrupt's line and pixel */
    ip_s2 <= ip_s1;
end
wire [9:0] il     = ip_s2[9:0];
wire [9:0] ipx    = ip_s2[19:10];
/* the line where the mark ends: 4 lines later, wrapping at the frame's end */
wire [9:0] il_end = (il + INT_LINES >= LINES_50) ? il + INT_LINES - LINES_50 : il + INT_LINES;

always @(posedge pclk or negedge prst_n)
    if (!prst_n)
    begin
/* idle; the mark starts */
        frame_n <= 1'b1;
    end
    else if (vcnt == il && hcnt == ipx)
    begin
        frame_n <= 1'b0;
    end
/* and ends */
    else if (vcnt == il_end && hcnt == ipx)
    begin
        frame_n <= 1'b1;
    end

/* the border's width and height */
wire [9:0]  bx  = mode50 ? PIC_X0_50 : PIC_X0_60;
wire [9:0]  by  = mode50 ? PIC_Y0_50  : PIC_Y0_60;
/* x inside the picture */
wire [9:0]  rel = x - bx;
/* 4 pixels ahead */
wire [9:0]  la  = x - bx + LOOK_AHEAD;
wire [9:0]  ry  = y - by;
wire        in_y   = active && y >= by && ry < PIC_H;
/* inside the picture */
wire        in_x   = x >= bx && rel < PIC_W;
wire        la_in  = (x + LOOK_AHEAD >= bx) && la < PIC_W;
wire [7:0]  zy     = ry[8:1];
/* the character column; what to fetch in this pixel */
wire [4:0]  la_cx  = la[8:4];

always @*
begin
    if (la[3:0] == 4'd0)
    begin
/* bitmap */
        raddr = {zy[7:6], zy[2:0], zy[5:3], la_cx};
    end
    else
    begin
/* attributes (0x1800 + ...) */
        raddr = {3'b110, zy[7:3], la_cx};
    end
/* OSD text: row * 32 + column */
    taddr = {zy[7:3], la_cx};
end

/* the character, then its font row */
always @(posedge pclk)
begin
    tq <= txt[taddr];
    fq <= font[{tq[6:0], ry[3:0]}];
end

/* Pixel pipeline */
reg [7:0] bm_next, at_next, bm, at;
reg [7:0] obm_next, obm;
reg       oinv;
/* the FLASH counter */
reg [4:0] fcnt;
reg       flash, vs_prev;

always @(posedge pclk or negedge prst_n)
/* reset */
    if (!prst_n)
    begin
        bm_next <= 8'd0;
        at_next <= 8'd0;
/* the cell on the screen */
        bm      <= 8'd0;
        at      <= 8'd0;
        obm_next <= 8'd0;
/* the OSD's */
        obm     <= 8'd0;
        oinv    <= 1'b0;
        fcnt    <= 5'd0;
/* FLASH off */
        flash   <= 1'b0;
        vs_prev <= 1'b1;
    end
    else
    begin
        if (in_y && la_in)
        begin
/* bitmap byte; the OSD character's inverse bit */
            if (la[3:0] == 4'd1)
            begin
                bm_next <= q;
                oinv <= tq[7];
            end
/* attribute byte; the OSD's font row */
            if (la[3:0] == PIPE_FONT)
            begin
                at_next <= q;
                obm_next <= fq ^ {FONT_BITS{oinv}};
            end
/* all loaded for the cell that starts next */
            if (la[3:0] == PIPE_LOAD)
            begin
                bm <= bm_next;
/* attribute and OSD */
                at <= at_next;
                obm <= obm_next;
            end
        end
/* FLASH: swap ink and paper every 16 frames */
        vs_prev <= vsync_n;
        if (vs_prev && !vsync_n)
        begin
            fcnt <= fcnt + 5'd1;
/* every 16 frames */
            if (fcnt[3:0] == 4'd15)
            begin
                flash <= !flash;
            end
        end
    end

wire       pix    = bm[~rel[3:1]];
/* OSD covers this line */
wire       osd    = oon_s[1] && (ofull_s[1] || zy[7:3] == OSD_LAST_ROW);
wire       opix   = obm[~rel[3:1]];
wire       ink_on = pix ^ (at[7] & flash);
/* G R B */
wire [2:0] col    = ink_on ? at[2:0] : at[5:3];

always @(posedge pclk or negedge prst_n)
    if (!prst_n)
    begin
/* black, syncs inactive */
        {vga_r, vga_r_low, vga_g, vga_g_low, vga_b, vga_b_low} <= 6'd0;
        vga_hs <= 1'b1;
        vga_vs <= 1'b1;
    end
    else
    begin
/* black outside the picture */
        if (!active)
        begin
            {vga_r, vga_r_low, vga_g, vga_g_low, vga_b, vga_b_low} <= 6'd0;
        end
/* OSD: white on blue */
        else if (in_y && in_x && osd)
        begin
            vga_r <= opix;
            vga_r_low <= opix;
/* green */
            vga_g <= opix;
            vga_g_low <= opix;
            vga_b <= 1'b1;
/* blue is always on; then the Spectrum's picture */
            vga_b_low <= opix;
        end
        else if (in_y && in_x)
        begin
            vga_r <= col[1];
/* bright adds the low bit */
            vga_r_low <= col[1] & at[6];
            vga_g <= col[2];
            vga_g_low <= col[2] & at[6];
/* blue */
            vga_b <= col[0];
            vga_b_low <= col[0] & at[6];
        end
        else
        begin
/* the border */
            vga_r <= border_s2[1];
            vga_r_low <= 1'b0;
            vga_g <= border_s2[2];
/* green and blue */
            vga_g_low <= 1'b0;
            vga_b <= border_s2[0];
            vga_b_low <= 1'b0;
        end
/* the syncs */
        vga_hs <= hsync_n;
        vga_vs <= vsync_n;
    end

endmodule

`default_nettype wire
