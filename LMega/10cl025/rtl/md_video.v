/* md_video -- LMega: the VDP's 15 kHz picture on a VGA monitor, with the ESP32's OSD */
/* */
/* Line doubler: every line of the VDP (3,420 master clocks) is stored in one of two line */
/* buffers and shown twice in the following line's time, each time in 1,710 master clocks = */
/* 3,420 clk_sd. The monitor sees a 640 x 480 mode at the console's own frame rate (262 */
/* lines -> 524, about 59.9 Hz; a 50 Hz console: 313 -> 626), so scrolling stays smooth. */
/* */
/* Sharp pixels: a VGA line has 800 pixel times, of which 640 are the picture. The output */
/* counts 800 pixels in the 3,420 clocks of a line with a fraction counter (a pixel is 4 or 5 */
/* clocks long), and the picture's 320 pixels fill exactly 640 of them (two each). With 256 */
/* pixels per line (the VDP's other mode) a pixel is 2 or 3 output pixels wide. */
/* */
/* Third mode (fb_mode, for a 50 Hz console on a 60 Hz screen): the lines do not follow the VDP. */
/* The output makes a standard 640 x 480 @ 60 Hz frame of its own (800 pixel times in 3,412 clocks, */
/* 525 lines) and takes the pixels from md_fb's line buffer (fb_addr -> fb_q), telling it when a frame */
/* starts (fb_frame) and when the next picture line is on screen (fb_line). */
/* */
/* Vertical sync: in its interlace modes the VDP delays the sync of every second field by half a */
/* line (one output line). The monitor must not see that (frames of 523 and 525 lines in turn: a */
/* monitor that takes 60 Hz only shows nothing), so the VDP's sync is looked at in the middle of */
/* every output line and the monitor's sync changes only where a VDP line starts: 524 lines always. */
/* */
/* Write side (mclk): the VDP's colours with ce_pix while neither blanking is active. */
/* Read side (clk_sd = 2 x mclk, edges aligned): the line buffer, the OSD and the VGA outputs. */
/* OSD (as the other machines'): 32 x 24 characters of 16 x 16 pixels in the middle of the */
/* picture, white on blue, bit 7 of a character = inverse; osd_full = 0 shows the bottom row. */
`default_nettype none

module md_video #(
    parameter FONT_HEX = "font.hex"
)(
/* from the VDP (mclk); hs / vs are 1 during the sync pulses */
    input  wire       mclk,
    input  wire       ce_pix,
    input  wire       hs,
    input  wire       vs,
    input  wire       hbl,
    input  wire       vbl,
    input  wire [3:0] r,
    input  wire [3:0] g,
    input  wire [3:0] b,
/* 320 pixels per line (else 256) */
    input  wire       h40,

    input  wire       clk_sd,

/* the frame buffer mode (md_fb, clk_sd) */
    input  wire       fb_mode,
    input  wire [11:0] fb_q,
    input  wire [8:0] fb_lines,
    input  wire       fb_h40,
    output wire [10:0] fb_addr,
    output reg        fb_frame,
    output reg        fb_line,

/* OSD text write port and state (tape loader clock) */
    input  wire       osd_wclk,
    input  wire       osd_we,
    input  wire [9:0] osd_waddr,
    input  wire [7:0] osd_wdata,
    input  wire       osd_on,
    input  wire       osd_full,

    output reg  [3:0] vga_r,
    output reg  [3:0] vga_g,
    output reg  [3:0] vga_b,
    output reg        vga_hs,
    output reg        vga_vs
);

/* clocks of an output line, less one; pixel times of an output line */
localparam [11:0] LINE_LAST = 12'd3419;
localparam [11:0] PIX_STEP = 12'd800;
localparam [11:0] PIX_WRAP = 12'd2620;
/* frame buffer mode: a line of 3,412 clocks (31.47 kHz), 525 lines, the vertical sync's lines */
localparam [11:0] LINE_LAST_FB = 12'd3411;
localparam [11:0] PIX_WRAP_FB = 12'd2612;
localparam [9:0] V_LAST = 10'd524;
/* where in an output line the VDP's vertical sync is looked at: the middle */
localparam [11:0] VS_SAMPLE = 12'd1710;
/* the picture's lines, the vertical sync */
localparam [9:0] V_ACT = 10'd480;
localparam [9:0] VS_BEG = 10'd490;
localparam [9:0] VS_END = 10'd492;
/* the first line toggle comes two screen lines into the picture */
localparam [9:0] FIRST_REPEAT = 10'd2;
/* the picture's pixels, the sync pulse */
localparam [9:0] H_ACT = 10'd640;
localparam [9:0] HS_BEG = 10'd656;
localparam [9:0] HS_END = 10'd752;
/* 256-pixel mode: source pixel = output pixel * 205 / 512 (two fifths) */
localparam [7:0] H32_MUL = 8'd205;
localparam integer H32_SHIFT = 9;
/* OSD: 512 x 384 in the 640-pixel line; its last text row */
localparam [9:0] OSD_X0 = 10'd64;
localparam [9:0] OSD_W = 10'd512;
localparam [9:0] OSD_H = 10'd384;
/* the status line's row */
localparam [4:0] OSD_LAST_ROW = 5'd23;
/* blue level of the OSD's background; bits of a colour */
localparam [3:0] BLUE_BACK = 4'hC;
localparam integer DAC_BITS = 4;

/* ---- write side (mclk) ---- */
/* (the registers start at 0 after configuration; there is no reset) */
reg        hs_d = 1'b0, wsel = 1'b0, ltgl = 1'b0;
reg  [8:0] wx = 9'd0;
reg  [1:0] lvalid = 2'b00, lh40 = 2'b00;
/* the two line buffers of 512 pixels */
reg [11:0] lbuf [0:1023];
always @(posedge mclk)
begin
    hs_d <= hs;
/* a line starts with its sync pulse: the other buffer, empty so far */
    if (hs && !hs_d)
    begin
        wsel          <= !wsel;
        ltgl          <= !ltgl;
/* its first pixel; it has no picture yet */
        wx            <= 9'd0;
        lvalid[!wsel] <= 1'b0;
        lh40[!wsel]   <= h40;
    end
/* a pixel of the picture */
    else if (ce_pix && !hbl && !vbl)
    begin
        lbuf[{wsel, wx}] <= {r, g, b};
        wx               <= wx + 9'd1;
/* the buffer holds a picture line now */
        lvalid[wsel]     <= 1'b1;
    end
end

/* ---- read side (clk_sd) ---- */
reg        lt_d = 1'b0, rsel = 1'b0, half = 1'b0;
reg [11:0] oc = 12'd0, acc = 12'd0;
reg  [9:0] px = 10'd0, y = 10'd0, ytop = 10'd0, pic_h = 10'd0, pic_cnt = 10'd0;
/* what the buffer on screen holds; the vertical sync: synchronised, as seen in the middle of a */
/* line, and the monitor's (it changes with a VDP line only) */
reg        r_valid = 1'b0, r_h40 = 1'b0, was_valid = 1'b0, vs_s = 1'b0, vs_mid = 1'b0, vs_line = 1'b0;
wire       line_ev = ltgl != lt_d;
/* the sync of the output line that starts: a VDP line takes the newest look, its repeat keeps it */
wire       vs_now  = line_ev ? vs_mid : vs_line;
/* the line's length and who starts it: the VDP, or (frame buffer mode) the counter alone */
wire [11:0] line_last = fb_mode ? LINE_LAST_FB : LINE_LAST;
wire [11:0] pix_wrap  = fb_mode ? PIX_WRAP_FB : PIX_WRAP;
wire       line_start = (line_ev && !fb_mode) || oc == line_last;
/* frame buffer mode: the screen line, the picture's place on the screen */
reg  [9:0] vl = 10'd0;
reg        ls_d = 1'b0;
wire [9:0] fb_h2    = {fb_lines, 1'b0};
/* its first screen line; the line inside the picture */
wire [9:0] fb_voff  = (V_ACT - fb_h2) >> 1;
wire [9:0] fb_pv    = vl - fb_voff;
wire       fb_valid = vl >= fb_voff && fb_pv < fb_h2;

/* the output side */
always @(posedge clk_sd)
begin
    lt_d <= ltgl;
    vs_s <= vs;
/* the VDP's vertical sync in the middle of an output line: far from both places where it changes */
    if (oc == VS_SAMPLE)
    begin
        vs_mid <= vs_s;
    end
/* an output line: 3,420 clocks, 800 pixel times */
    if (line_start)
    begin
        oc  <= 12'd0;
        acc <= 12'd0;
/* the first pixel */
        px  <= 10'd0;
    end
    else
    begin
        oc <= oc + 12'd1;
        if (acc >= pix_wrap)
        begin
/* the next pixel time */
            acc <= acc - pix_wrap;
            px  <= px + 10'd1;
        end
        else
        begin
            acc <= acc + PIX_STEP;
        end
    end
/* the VDP starts a line: the buffer it just filled is shown twice */
    if (line_ev)
    begin
        half    <= 1'b0;
        rsel    <= !wsel;
/* its contents: a picture line, 320 pixels */
        r_valid <= lvalid[!wsel];
        r_h40   <= lh40[!wsel];
    end
    else if (oc == line_last)
    begin
/* the second showing of the line */
        half <= 1'b1;
    end
/* frame buffer mode: the screen's own line counter, and the news for md_fb one clock into a line */
    ls_d     <= line_start && fb_mode;
    fb_frame <= 1'b0;
    fb_line  <= 1'b0;
/* the next screen line */
    if (line_start && fb_mode)
    begin
        vl <= vl == V_LAST ? 10'd0 : vl + 10'd1;
    end
/* a frame starts after the picture; a picture line is shown on two screen lines */
    if (ls_d)
    begin
        fb_frame <= vl == V_ACT;
        fb_line  <= fb_valid && fb_pv >= FIRST_REPEAT && !fb_pv[0];
    end
/* line counting from the vertical sync; where the picture starts and how high it is */
    if (line_start)
    begin
        vs_line   <= vs_now;
        was_valid <= r_valid;
/* the sync pulse: the frame's lines are counted from here */
        if (vs_now)
        begin
            y <= 10'd0;
            if (!vs_line)
            begin
/* the height of the picture that ended */
                pic_h   <= pic_cnt;
                pic_cnt <= 10'd0;
            end
        end
        else
        begin
            y <= y + 10'd1;
/* a line of the picture */
            if (r_valid)
            begin
                pic_cnt <= pic_cnt + 10'd1;
                if (!was_valid)
                begin
/* the first line of the picture */
                    ytop <= y + 10'd1;
                end
            end
        end
    end
end

/* the source pixel of an output pixel */
wire [17:0] x32  = px * H32_MUL;
/* what is shown: the VDP's line, or the frame buffer's */
wire        e_valid = fb_mode ? fb_valid : r_valid;
wire        e_h40   = fb_mode ? fb_h40 : r_h40;
wire [9:0]  e_y     = fb_mode ? vl : y;
/* where the picture starts and how high it is, for the OSD; the vertical sync */
wire [9:0]  e_ytop  = fb_mode ? fb_voff : ytop;
wire [9:0]  e_pic_h = fb_mode ? fb_h2 : pic_h;
wire        e_vs    = fb_mode ? (vl >= VS_BEG && vl < VS_END) : vs_line;
/* the source pixel of this pixel time */
wire [8:0]  sidx = e_h40 ? px[9:1] : {1'b0, x32[H32_SHIFT +: 8]};
assign      fb_addr = {fb_pv[2:1], sidx};
/* the OSD's place: the middle of the picture as measured */
wire [9:0]  osd_y0 = e_ytop + ((e_pic_h - OSD_H) >> 1);
wire [9:0]  rx   = px - OSD_X0;
wire [9:0]  ry   = e_y - osd_y0;
/* inside the 640 pixels; inside the OSD */
wire        act  = px < H_ACT;
wire        in_o = px >= OSD_X0 && rx < OSD_W && e_y >= osd_y0 && ry < OSD_H && e_pic_h >= OSD_H;
wire        row23 = ry[8:4] == OSD_LAST_ROW;

/* the OSD's text and font */
reg [7:0] txt  [0:1023];
reg [7:0] font [0:2047];
initial $readmemh(FONT_HEX, font);
/* the text is written by the tape loader */
always @(posedge osd_wclk)
    if (osd_we)
    begin
        txt[osd_waddr] <= osd_wdata;
    end

/* line buffer and text -> font -> pixel: 2 clocks, everything else delayed to match */
reg [11:0] lq, lq_d;
reg [7:0]  tq, fq;
reg        inv_d, fb_sel;
/* the pixel's column and the font row, delayed */
reg [3:0]  col_d1, col_d2, frow_d1;
reg [1:0]  in_d, row_d, act_d, hs_p, val_d, on_s, full_s;
always @(posedge clk_sd)
begin
/* the OSD state, synchronised */
    on_s    <= {on_s[0], osd_on};
    full_s  <= {full_s[0], osd_full};
/* the picture */
    lq      <= lbuf[{rsel, sidx}];
    fb_sel  <= fb_mode;
    lq_d    <= fb_sel ? fb_q : lq;
/* inside the 640 pixels */
    act_d   <= {act_d[0], act};
/* the buffer holds a picture line */
    val_d   <= {val_d[0], e_valid};
    hs_p    <= {hs_p[0], px >= HS_BEG && px < HS_END};
/* the character, its font row, the pixel's column */
    tq      <= txt[{ry[8:4], rx[8:4]}];
    frow_d1 <= ry[3:0];
    fq      <= font[{tq[6:0], frow_d1}];
/* inverse, the pixel's column */
    inv_d   <= tq[7];
    col_d1  <= rx[3:0];
    col_d2  <= col_d1;
/* inside the OSD, its last row */
    in_d    <= {in_d[0], in_o};
    row_d   <= {row_d[0], row23};
end

wire osd_here = in_d[1] && on_s[1] && (full_s[1] || row_d[1]);
/* its pixel */
wire opix     = fq[~col_d2[3:1]] ^ inv_d;

/* the pins' registers */
always @(posedge clk_sd)
begin
    if (osd_here)
    begin
/* white on blue */
        vga_r <= {DAC_BITS{opix}};
        vga_g <= {DAC_BITS{opix}};
        vga_b <= opix ? 4'hF : BLUE_BACK;
    end
/* the picture */
    else if (act_d[1] && val_d[1])
    begin
        vga_r <= lq_d[11:8];
        vga_g <= lq_d[7:4];
/* blue */
        vga_b <= lq_d[3:0];
    end
    else
    begin
        vga_r <= 4'd0;
        vga_g <= 4'd0;
/* black outside the picture */
        vga_b <= 4'd0;
    end
/* - syncs */
    vga_hs <= !hs_p[1];
    vga_vs <= !e_vs;
end

endmodule

`default_nettype wire
