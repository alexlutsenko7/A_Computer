/* next_video -- LNext: the Spectrum Next's 15 kHz picture on a VGA monitor, with the ESP32's OSD */
/* */
/* Line doubler with one line buffer of 1024 pixels (the machine has no block RAM to spare): */
/* the core's pixels (14 MHz) are written into the buffer as they come and read at 28 MHz, twice */
/* per line. The first reading runs ahead of the writing and so shows the line before; the */
/* second one follows the writing and shows the line being written. Every line is on screen */
/* twice. The monitor sees 31.25 kHz lines at the machine's own frame rate: 50 Hz machines give */
/* 622 to 624 lines (close to 720 x 576 at 50 Hz), 60 Hz ones 524 to 528 (close to 640 x 480). */
/* */
/* The buffer holds the colours only. Sync and blanking are made again from what the write side */
/* measures: the length of a line and of its sync pulse, the first and last picture pixel, and */
/* whether a line lies in the vertical blanking (looked at a few pixels into the line). */
/* */
/* Write side (clk14); read side (clk28 = 2 x clk14, same PLL, edges aligned): line buffer, OSD */
/* and the VGA outputs. */
/* OSD (as the other machines'): 32 x 24 characters of 16 x 16 pixels in the middle of the */
/* picture, white on blue, bit 7 of a character = inverse; osd_full = 0 shows the bottom row. */
/* */
/* Screenshots (next_grab.v, Print Screen): the picture exists nowhere but in this buffer, one */
/* line at a time, so the ESP32 takes it line by line. While g_on is set the monitor gets a */
/* black picture (the OSD stays) and the buffer's read side belongs to the grabber: g_x is the */
/* pixel's place in the line, g_q its colour one clock later. A change of g_req lets the buffer */
/* be written again; with g_arm set, the writing stops at the end of line g_line (counted from */
/* the vertical sync) and that line stays in the buffer (g_held) until the next change. */
`default_nettype none

module next_video #(
    parameter FONT_HEX = "font.hex"
)(
/* from the core (clk14): colour 3 bits each, syncs and blanking active low */
    input  wire       clk14,
    input  wire [8:0] rgb,
    input  wire       hs_n,
    input  wire       vs_n,
    input  wire       hb_n,
    input  wire       vb_n,

    input  wire       clk28,

/* OSD text write port and state (tape loader clock) */
    input  wire       osd_wclk,
    input  wire       osd_we,
    input  wire [9:0] osd_waddr,
    input  wire [7:0] osd_wdata,
    input  wire       osd_on,
    input  wire       osd_full,

/* the screenshot grabber (clk28; see above) */
    input  wire       g_on,
    input  wire       g_req,
    input  wire       g_arm,
    input  wire [9:0] g_line,
    input  wire [9:0] g_x,
    output wire [8:0] g_q,
/* a line is held; it lies in the vertical blanking */
    output reg        g_held = 1'b0,
    output reg        g_vbl = 1'b0,
/* the picture's first pixel in a line, the first one after it, the lines of a frame */
    output wire [9:0] g_first,
    output wire [9:0] g_end,
    output reg  [9:0] g_lines = 10'd0,

    output reg  [3:0] vga_r,
    output reg  [3:0] vga_g,
    output reg  [3:0] vga_b,
    output reg        vga_hs,
    output reg        vga_vs
);

/* the longest line the buffer holds, less one */
localparam [9:0] X_MAX = 10'd1023;
/* where in a line its vertical blanking is looked at */
localparam [9:0] VB_SAMPLE = 10'd16;
/* OSD: 512 x 384 pixels; its last text row */
localparam [9:0] OSD_W = 10'd512;
localparam [9:0] OSD_H = 10'd384;
localparam [4:0] OSD_LAST_ROW = 5'd23;
/* blue level of the OSD's background; bits of a colour */
localparam [3:0] BLUE_BACK = 4'hC;
localparam integer DAC_BITS = 4;

/* ---- write side (clk14) ---- */
/* (the registers start at 0 after configuration; there is no reset) */
reg        hs_d = 1'b1, ltgl = 1'b0;
reg  [9:0] wx = 10'd0;
/* measured: the line's last pixel time, the sync pulse's length, the picture's first pixel */
/* and the first one after it */
reg  [9:0] wlast = 10'd0, hs_len = 10'd0, a_first = 10'd0, a_end = 10'd0;
/* measuring this line: a picture pixel was seen, the picture ended */
reg        m_seen = 1'b0, m_done = 1'b0;
reg  [9:0] m_first = 10'd0, m_end = 10'd0;
/* vertical blanking of the line being written and of the one before */
reg        vbl_cur = 1'b1, vbl_prev = 1'b1;
/* the line buffer */
reg  [8:0] lbuf [0:1023];
/* the grabber: the request as seen, a line is waited for; the line's number in the frame, */
/* the vertical sync a clock ago, a vertical sync started in this line */
reg        g_req_q = 1'b0, g_wait = 1'b0;
reg  [9:0] wy = 10'd0;
reg        vs_d = 1'b1, vs_seen = 1'b0;

wire       w_blank = !hb_n;

always @(posedge clk14)
begin
    hs_d <= hs_n;
    vs_d <= vs_n;
/* a held line is not written over */
    if (!g_held)
    begin
        lbuf[wx] <= rgb;
    end
/* a vertical sync starts in this line: the next line is line 0 */
    if (vs_d && !vs_n)
    begin
        vs_seen <= 1'b1;
    end
/* the grabber asks: the buffer is written again, and it waits for a line or not */
    if (g_req != g_req_q)
    begin
        g_req_q <= g_req;
        g_held  <= 1'b0;
        g_wait  <= g_arm;
    end
/* the line it waits for ends: that line stays in the buffer */
    else if (hs_d && !hs_n && g_wait && wy == g_line)
    begin
        g_held <= 1'b1;
        g_wait <= 1'b0;
        g_vbl  <= vbl_cur;
    end
/* the lines of a frame are counted from the vertical sync */
    if (hs_d && !hs_n)
    begin
        if (vs_seen || (vs_d && !vs_n))
        begin
            vs_seen <= 1'b0;
            wy      <= 10'd0;
            g_lines <= wy + 10'd1;
        end
        else
        begin
            wy <= wy + 10'd1;
        end
    end
/* a line ends where the next sync pulse starts */
    if (hs_d && !hs_n)
    begin
        wlast    <= wx;
        ltgl     <= !ltgl;
        wx       <= 10'd0;
        vbl_prev <= vbl_cur;
/* a line with a picture: where it was */
        if (m_seen && m_done)
        begin
            a_first <= m_first;
            a_end   <= m_end;
        end
        m_seen <= 1'b0;
        m_done <= 1'b0;
    end
    else
    begin
        if (wx != X_MAX)
        begin
            wx <= wx + 10'd1;
        end
/* the sync pulse ends */
        if (!hs_d && hs_n)
        begin
            hs_len <= wx;
        end
/* the line's vertical blanking */
        if (wx == VB_SAMPLE)
        begin
            vbl_cur <= !vb_n;
        end
/* the picture's first pixel, and the first blanked one after it */
        if (!w_blank && !m_seen)
        begin
            m_seen  <= 1'b1;
            m_first <= wx;
        end
        if (w_blank && m_seen && !m_done)
        begin
            m_done <= 1'b1;
            m_end  <= wx;
        end
    end
end

/* ---- read side (clk28) ---- */
reg        lt_q = 1'b0, lt_seen = 1'b0, pass = 1'b0, pass_start = 1'b0;
reg  [9:0] rx = 10'd0, rlast = 10'd0;
/* the line read is in the vertical blanking; the vertical sync of the line played */
reg        r_vbl = 1'b1, vs_line = 1'b1;
/* picture lines counted, the line's number, the picture's height */
reg  [9:0] y_cnt = 10'd0, y = 10'd0, pic_h = 10'd0;

/* the picture's width */
wire [9:0]  x_w = a_end - a_first;
/* the OSD's place: the middle of the picture as measured */
wire [9:0]  osd_x0 = a_first + ((x_w - OSD_W) >> 1);
wire [9:0]  osd_y0 = (pic_h - OSD_H) >> 1;
wire [9:0]  ox   = rx - osd_x0;
wire [9:0]  oy   = y - osd_y0;
/* inside the OSD */
wire        in_o = rx >= osd_x0 && ox < OSD_W && y >= osd_y0 && oy < OSD_H && pic_h >= OSD_H && x_w >= OSD_W;
wire        row23 = oy[8:4] == OSD_LAST_ROW;
/* blanked: outside the picture's pixels, or a line of the vertical blanking */
wire        r_blank = r_vbl || rx < a_first || rx >= a_end;

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
reg [8:0]  lq = 9'd0, lq_d = 9'd0;
reg [7:0]  tq, fq;
reg        inv_d;
/* the pixel's column and the font row, delayed */
reg [3:0]  col_d1, col_d2, frow_d1;
reg [1:0]  in_d, row_d, on_s, full_s, bl_d, hs_p;

always @(posedge clk28)
begin
/* the write side started a line: the first reading (the line before) starts with it */
    lt_q       <= ltgl;
    pass_start <= 1'b0;
    if (lt_q != lt_seen)
    begin
        lt_seen    <= lt_q;
        rlast      <= wlast;
        rx         <= 10'd0;
        pass       <= 1'b0;
        r_vbl      <= vbl_prev;
        pass_start <= 1'b1;
        vs_line    <= vs_n;
    end
/* the line's end: the second reading (the line being written) */
    else if (rx == rlast)
    begin
        rx         <= 10'd0;
        pass       <= 1'b1;
        r_vbl      <= vbl_cur;
        pass_start <= !pass;
        vs_line    <= vs_n;
    end
    else
    begin
        rx <= rx + 10'd1;
    end

/* a reading starts: the picture's lines are counted, its height is the count at its end */
    if (pass_start)
    begin
        if (r_vbl)
        begin
            if (y_cnt != 10'd0)
            begin
                pic_h <= y_cnt;
            end
            y_cnt <= 10'd0;
            y     <= 10'd0;
        end
        else
        begin
            y     <= y_cnt;
            y_cnt <= y_cnt + 10'd1;
        end
    end

/* the picture, its blanking and sync; the grabber reads the buffer at its own place */
    lq   <= lbuf[g_on ? g_x : rx];
    lq_d <= lq;
    bl_d <= {bl_d[0], r_blank};
    hs_p <= {hs_p[0], rx < hs_len};

/* the OSD state, synchronised */
    on_s    <= {on_s[0], osd_on};
    full_s  <= {full_s[0], osd_full};
/* the character, its font row, the pixel's column */
    tq      <= txt[{oy[8:4], ox[8:4]}];
    frow_d1 <= oy[3:0];
    fq      <= font[{tq[6:0], frow_d1}];
/* inverse, the pixel's column */
    inv_d   <= tq[7];
    col_d1  <= ox[3:0];
    col_d2  <= col_d1;
/* inside the OSD, its last row */
    in_d    <= {in_d[0], in_o};
    row_d   <= {row_d[0], row23};
end

wire osd_here = in_d[1] && on_s[1] && (full_s[1] || row_d[1]);
/* the grabber: the buffer's colour, the picture's place in a line */
assign g_q     = lq;
assign g_first = a_first;
assign g_end   = a_end;
/* its pixel */
wire opix     = fq[~col_d2[3:1]] ^ inv_d;

/* the pins' registers */
always @(posedge clk28)
begin
    if (bl_d[1])
    begin
/* black while blanked */
        vga_r <= 4'd0;
        vga_g <= 4'd0;
        vga_b <= 4'd0;
    end
    else if (osd_here)
    begin
/* white on blue */
        vga_r <= {DAC_BITS{opix}};
        vga_g <= {DAC_BITS{opix}};
        vga_b <= opix ? 4'hF : BLUE_BACK;
    end
    else if (g_on)
    begin
/* a screenshot is taken: black */
        vga_r <= 4'd0;
        vga_g <= 4'd0;
        vga_b <= 4'd0;
    end
    else
    begin
/* the picture: 3 bits per colour, the top bit repeated */
        vga_r <= {lq_d[8:6], lq_d[8]};
        vga_g <= {lq_d[5:3], lq_d[5]};
        vga_b <= {lq_d[2:0], lq_d[2]};
    end
/* - syncs */
    vga_hs <= !hs_p[1];
    vga_vs <= vs_line;
end

endmodule

`default_nettype wire
