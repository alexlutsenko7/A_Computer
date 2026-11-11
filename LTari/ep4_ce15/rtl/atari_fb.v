/* atari_fb -- frame buffer video: GTIA's picture goes into SDRAM and is shown at */
/* 640 x 480 @ 60 Hz or 720 x 576 @ 50 Hz (as L64's c64_fb, here for GTIA's pixels) */
/* */
/* Writer (clk): GTIA's two hi-res pixels per colour clock (px_stb, 8-bit colours */
/* {hue, luminance}), colour clocks X0..X0+W-1 of lines Y0..Y0+H-1 = 376 x 240, the whole */
/* visible PAL picture (NOTES.md). One 16-bit word per colour clock (left pixel in bits */
/* 7:0), 188 words per line. Each word goes through a 256-entry FIFO (clk_sd) into SDRAM. */
/* */
/* Three buffers (triple buffering, as c64_fb): the writer fills one; when a frame is */
/* complete it becomes the newest, and the writer goes on in the buffer that is neither */
/* the newest nor the one on screen. The reader takes the newest buffer at the start of */
/* each output frame, so every frame it shows is complete. */
/* */
/* SDRAM byte address of a word: {3'd2 + buffer, line[7:0], word[7:0], 1'b0}: */
/* buffers at 0x40000 / 0x60000 / 0x80000, 512 bytes per line. */
/* */
/* Reader (pclk): fetches each picture line once into a 4-line buffer (block RAM, */
/* written at clk_sd), up to 3 lines ahead of the line on screen, and shows every */
/* line twice at 2 pixels per hi-res pixel. The 240 lines fill 480 output lines; the */
/* width is cropped to the middle of the 376 hi-res pixels (as a TV's overscan): */
/* m60 = 1: 640 x 480 @ 60 Hz (800 x 525, VESA / CEA VIC 1), pclk 25.208 MHz: */
/* hi-res pixels 28..347 (320 = the normal playfield), all 240 lines */
/* m60 = 0: 720 x 576 @ 50 Hz (864 x 625, CEA VIC 17), pclk 27.009 MHz: */
/* hi-res pixels 8..367 (360), the 480 lines 48 lines below the top */
/* Both modes: - syncs; the same timing as LSpectrum's vga_timing. */
/* Output: the PAL palette (PAL_HEX, tools/mk_palette.py, 6 bits per colour; entry 0 is */
/* black), syncs and active, 4 pclk after h / v. */
/* */
/* SDRAM port (clk_sd): m_req is held until m_ack (one access at a time); the */
/* system's arbiter serves it between the machine's own accesses. */
/* */
/* Screenshots (ESP32): hold = 1 keeps the newest buffer as it is (the writer goes on */
/* overwriting its own buffer), so the ESP32 can read a complete picture from SDRAM. */
`default_nettype none

module atari_fb #(
/* first stored colour clock */
    parameter [7:0]   X0 = 8'h22,
/* first stored scan line */
    parameter [8:0]   Y0 = 9'd8,
/* words (colour clocks) per line */
    parameter integer W  = 188,
/* lines */
    parameter integer H  = 240,
    parameter         PAL_HEX = "atari_palette.hex"
)(
/* GTIA side (clk) */
    input  wire        clk,
/* power-up */
    input  wire        rst_n,
    input  wire        px_stb,
    input  wire [7:0]  px_cc,
    input  wire [8:0]  px_vc,
    input  wire [7:0]  px0,
    input  wire [7:0]  px1,
/* no buffer change (screenshot); quasi-static */
    input  wire        hold,
/* the last complete buffer */
    output reg  [1:0]  newest,

/* SDRAM side (clk_sd = 3 x clk, rising edges aligned) */
    input  wire        clk_sd,
    input  wire        rst_sd_n,
    output reg         m_req,
    output reg         m_we,
    output reg  [20:0] m_addr,
    output reg  [15:0] m_wdata,
/* the access is done (m_rdata valid for a read) */
    input  wire        m_ack,
    input  wire [15:0] m_rdata,

/* video side */
    input  wire        pclk,
    input  wire        prst_n,
/* static while prst_n = 1 */
    input  wire        m60,
/* {red, green, blue}, 6 bits each */
    output reg  [17:0] rgb,
    output reg         hsync,
    output reg         vsync,
    output reg         active
);

/* the last of the three buffers */
localparam [1:0] BUF_LAST = 2'd2;
/* buffer read after reset */
localparam [1:0] BUF_START_RD = 2'd2;
/* lines fetched ahead of the line shown */
localparam [9:0] FETCH_AHEAD = 10'd3;
/* SDRAM bank (128 KB units) of the first frame buffer */
localparam [2:0] FB_BANK0 = 3'd2;
/* 60 Hz: picture columns skipped on the left (752 - 640) / 2 */
localparam [10:0] H_SKIP_60 = 11'd56;
/* 50 Hz: picture columns skipped on the left (752 - 720) / 2 */
localparam [10:0] H_SKIP_50 = 11'd16;
/* 50 Hz: first screen line of the picture (576 - 480) / 2 */
localparam [9:0] V_OFF_50 = 10'd48;
/* visible pixels per line, 60 Hz */
localparam [10:0] H_ACT_60 = 11'd640;
/* visible pixels per line, 50 Hz */
localparam [10:0] H_ACT_50 = 11'd720;
/* visible lines, 60 Hz */
localparam [9:0] V_ACT_60 = 10'd480;
/* visible lines, 50 Hz */
localparam [9:0] V_ACT_50 = 10'd576;
/* last pixel count of a line, 60 Hz */
localparam [10:0] H_MAX_60 = 11'd799;
/* last pixel count of a line, 50 Hz */
localparam [10:0] H_MAX_50 = 11'd863;
/* last line count of a frame, 60 Hz */
localparam [9:0] V_MAX_60 = 10'd524;
/* last line count of a frame, 50 Hz */
localparam [9:0] V_MAX_50 = 10'd624;
/* horizontal sync start, 60 Hz */
localparam [10:0] HS_BEG_60 = 11'd656;
/* horizontal sync start, 50 Hz */
localparam [10:0] HS_BEG_50 = 11'd732;
/* horizontal sync end, 60 Hz */
localparam [10:0] HS_END_60 = 11'd752;
/* horizontal sync end, 50 Hz */
localparam [10:0] HS_END_50 = 11'd796;
/* vertical sync start, 60 Hz */
localparam [9:0] VS_BEG_60 = 10'd490;
/* vertical sync start, 50 Hz */
localparam [9:0] VS_BEG_50 = 10'd581;
/* vertical sync end, 60 Hz */
localparam [9:0] VS_END_60 = 10'd492;
/* vertical sync end, 50 Hz */
localparam [9:0] VS_END_50 = 10'd586;
/* every picture line is shown on two screen lines */
localparam integer LINE_DOUBLE = 2;
/* the first line toggle comes two screen lines into the picture */
localparam [9:0] FIRST_REPEAT = 10'd2;

/* the buffer that is neither a nor b (a == b only by a glitch: any other one) */
function [1:0] third(input [1:0] a, input [1:0] b);
    third = (a != b && a != 2'd3 && b != 2'd3) ? 2'd3 - a - b : (a == BUF_LAST ? 2'd0 : a + 2'd1);
endfunction

/* Writer (clk) */
/* buffer on screen (pclk) */
reg  [1:0]  rb;
reg  [1:0]  wb;
reg  [1:0]  hold_s;
/* the buffer being read, synchronised; the word to write */
reg  [1:0]  rb_s1, rb_s2, rb_s3;
reg  [15:0] w_data;
/* {buffer, line, word} */
reg  [17:0] w_loc;
reg         w_tgl;

wire [7:0] xo   = px_cc - X0;
/* the pixel's place in the picture */
wire [8:0] yl   = px_vc - Y0;
wire       in_x = px_cc >= X0 && xo < W;
wire       in_y = px_vc >= Y0 && px_vc < Y0 + H;

/* the write side */
always @(posedge clk or negedge rst_n)
    if (!rst_n)
    begin
        wb     <= 2'd0;
/* at reset: buffer 0 written, 1 newest, 2 read */
        newest <= 2'd1;
        rb_s1  <= BUF_START_RD;
        rb_s2  <= BUF_START_RD;
/* the synchronisers */
        rb_s3  <= BUF_START_RD;
        hold_s <= 2'b00;
        w_data <= 16'd0;
/* no word yet */
        w_loc  <= 18'd0;
        w_tgl  <= 1'b0;
    end
    else
    begin
        rb_s1 <= rb;
/* the buffer the reader shows */
        rb_s2 <= rb_s1;
        rb_s3 <= rb_s2;
        hold_s <= {hold_s[0], hold};
/* frame complete */
        if (px_stb && px_cc == X0 && px_vc == Y0 + H && !hold_s[1])
        begin
            newest <= wb;
            wb     <= third(wb, rb_s2 == rb_s3 ? rb_s3 : newest);
        end
/* a pixel pair inside the picture */
        if (px_stb && in_x && in_y)
        begin
            w_data <= {px1, px0};
            w_loc  <= {wb, yl[7:0], xo};
/* handed to the FIFO */
            w_tgl  <= !w_tgl;
        end
    end

/* FIFO (clk_sd): w_tgl / w_data / w_loc come from clk, which is synchronous */
reg  [33:0] fifo [0:255];
reg  [33:0] f_q;
reg  [7:0]  f_wp, f_rp;
/* the toggle as seen last */
reg         wt_d;
always @(posedge clk_sd)
begin
    if (w_tgl != wt_d)
    begin
/* the FIFO's memory, read registered */
        fifo[f_wp] <= {w_loc, w_data};
    end
    f_q <= fifo[f_rp];
end

/* Line fetch + SDRAM requests (clk_sd). Reads (the screen cannot wait) go first. */
/* pclk: frame start, next line on screen */
reg         f_tgl, l_tgl;
reg  [3:0]  ft_s, lt_s;
reg  [1:0]  rbs1, rbs2;
/* next line to fetch, line on screen */
reg  [8:0]  fn, fd;
/* next word of line fn */
reg  [7:0]  fw;
/* buffer on screen */
reg  [1:0]  frb;
reg         busy, is_rd, f_wait, f_has;
/* the read in flight belongs to the previous frame */
reg         stale;
/* line buffer address of the read */
reg  [9:0]  lb_wa;
wire        f_ev = ft_s[3] != ft_s[2];
wire        l_ev = lt_s[3] != lt_s[2];
/* lines are fetched up to three ahead; the line buffer */
wire        need = fn < H && {1'b0, fn} <= {1'b0, fd} + FETCH_AHEAD;

reg [15:0] lbuf [0:1023];
always @(posedge clk_sd)
/* a word read from the SDRAM */
    if (busy && is_rd && m_ack)
    begin
        lbuf[lb_wa] <= m_rdata;
    end

always @(posedge clk_sd or negedge rst_sd_n)
/* at reset */
    if (!rst_sd_n)
    begin
        wt_d   <= 1'b0;
        f_wp   <= 8'd0;
/* pointers and synchronisers */
        f_rp   <= 8'd0;
        ft_s   <= 4'd0;
        lt_s   <= 4'd0;
/* the reader's buffer */
        rbs1   <= BUF_START_RD;
        rbs2   <= BUF_START_RD;
/* nothing to fetch before the first frame start */
        fn     <= H[8:0];
        fd     <= 9'd0;
        fw     <= 8'd0;
/* no access running */
        frb    <= BUF_START_RD;
        busy   <= 1'b0;
        is_rd  <= 1'b0;
/* nothing waiting */
        f_wait <= 1'b0;
        f_has  <= 1'b0;
        stale  <= 1'b0;
/* no request */
        lb_wa  <= 10'd0;
        m_req  <= 1'b0;
        m_we   <= 1'b0;
/* address and data */
        m_addr <= 21'd0;
        m_wdata <= 16'd0;
    end
    else
    begin
        wt_d <= w_tgl;
/* a word enters the FIFO */
        if (w_tgl != wt_d)
        begin
            f_wp <= f_wp + 8'd1;
        end
        ft_s <= {ft_s[2:0], f_tgl};
/* the reader's line toggle and buffer */
        lt_s <= {lt_s[2:0], l_tgl};
        rbs1 <= rb;
        rbs2 <= rbs1;

/* FIFO head -> f_has (f_q is read one clock after f_rp is set) */
        if (f_wait)
        begin
            f_wait <= 1'b0;
            f_has  <= 1'b1;
        end
/* the FIFO's output register is filled */
        else if (!f_has && f_wp != f_rp)
        begin
            f_wait <= 1'b1;
        end

        if (f_ev)
        begin
/* a frame starts: line 0, word 0 */
            fn  <= 9'd0;
            fd  <= 9'd0;
            fw  <= 8'd0;
/* the buffer of this frame; a read still running is stale */
            frb <= rbs2;
            if (busy && is_rd)
            begin
                stale <= 1'b1;
            end
        end
/* a line was shown */
        else if (l_ev)
        begin
            fd <= fd + 9'd1;
        end

        if (!busy)
        begin
/* a line word is read */
            if (need && !f_ev)
            begin
                busy    <= 1'b1;
                is_rd   <= 1'b1;
/* the read request */
                m_req   <= 1'b1;
                m_we    <= 1'b0;
                m_addr  <= {1'b0, FB_BANK0 + {1'b0, frb}, fn[7:0], fw, 1'b0};
/* its place in the line buffer */
                lb_wa   <= {fn[1:0], fw};
                stale   <= 1'b0;
            end
            else if (f_has)
            begin
/* a pixel word from the FIFO is written */
                busy    <= 1'b1;
                is_rd   <= 1'b0;
                m_req   <= 1'b1;
/* the write request */
                m_we    <= 1'b1;
                m_addr  <= {1'b0, FB_BANK0 + {1'b0, f_q[33:32]}, f_q[31:16], 1'b0};
                m_wdata <= f_q[15:0];
/* taken out of the FIFO */
                f_has   <= 1'b0;
                f_rp    <= f_rp + 8'd1;
            end
        end
        else if (m_ack)
        begin
/* the access is over */
            busy  <= 1'b0;
            m_req <= 1'b0;
            if (is_rd && !f_ev && !stale)
            begin
/* the last word of a line: the next line */
                if (fw == W - 1)
                begin
                    fw <= 8'd0;
                    fn <= fn + 9'd1;
                end
                else
                begin
/* the next word */
                    fw <= fw + 8'd1;
                end
            end
        end
    end

/* Reader (pclk) */
/* A line / frame starts with the active area, then front porch, sync, back porch. */
/* content pixels left of the screen: 2 * (376 - width) / 2 */
wire [10:0] h_skip = m60 ? H_SKIP_60   : H_SKIP_50;
/* (576 - 2 * 240) / 2 */
wire [9:0]  v_off  = m60 ? 10'd0    : V_OFF_50;
wire [10:0] h_act  = m60 ? H_ACT_60  : H_ACT_50;
wire [9:0]  v_act  = m60 ? V_ACT_60  : V_ACT_50;
/* the totals of the two video modes */
wire [10:0] h_max  = m60 ? H_MAX_60  : H_MAX_50;
wire [9:0]  v_max  = m60 ? V_MAX_60  : V_MAX_50;
wire [10:0] hs_beg = m60 ? HS_BEG_60  : HS_BEG_50;
/* sync positions */
wire [10:0] hs_end = m60 ? HS_END_60  : HS_END_50;
wire [9:0]  vs_beg = m60 ? VS_BEG_60  : VS_BEG_50;
wire [9:0]  vs_end = m60 ? VS_END_60  : VS_END_50;

/* counters; the newest buffer, synchronised */
reg  [10:0] h;
reg  [9:0]  v;
reg  [1:0]  nw_s1, nw_s2, nw_s3;
/* content line (2 per picture line) */
wire [9:0]  sv    = v - v_off;
/* content pixel (2 per hi-res pixel) */
wire [10:0] sh    = h + h_skip;
wire        cont  = v >= v_off && v < v_off + LINE_DOUBLE * H && h < h_act;
wire        act   = h < h_act && v < v_act;
/* the syncs, active high; the palette */
wire        hs_ah = h >= hs_beg && h < hs_end;
wire        vs_ah = v >= vs_beg && v < vs_end;

reg  [17:0] pal [0:255];
/* its file; the pipeline: line buffer word, colour index */
initial $readmemh(PAL_HEX, pal);

reg  [15:0] lq;
reg  [7:0]  ci;
/* palette output, delays */
reg  [17:0] pq;
reg         pix_d;
reg         cont_d;
/* picture area and syncs, delayed */
reg  [2:0]  act_d, hs_d, vs_d;

always @(posedge pclk)
begin
    lq <= lbuf[{sv[2:1], sh[9:2]}];
/* the palette */
    pq <= pal[ci];
end

always @(posedge pclk or negedge prst_n)
    if (!prst_n)
    begin
/* at reset */
        h      <= 11'd0;
        v      <= 10'd0;
        rb     <= BUF_START_RD;
/* toggles; synchronisers */
        f_tgl  <= 1'b0;
        l_tgl  <= 1'b0;
        nw_s1  <= 2'd1;
/* pipeline */
        nw_s2  <= 2'd1;
        nw_s3  <= 2'd1;
        pix_d  <= 1'b0;
/* the colour index */
        ci     <= 8'd0;
        cont_d <= 1'b0;
        act_d  <= 3'b000;
/* syncs */
        hs_d   <= 3'b000;
        vs_d   <= 3'b000;
        rgb    <= 18'd0;
/* the pins idle */
        hsync  <= 1'b1;
        vsync  <= 1'b1;
        active <= 1'b0;
    end
    else
    begin
/* the newest buffer, synchronised */
        nw_s1 <= newest;
        nw_s2 <= nw_s1;
        nw_s3 <= nw_s2;
/* the end of a line: the next line */
        if (h == h_max)
        begin
            h <= 11'd0;
            v <= v == v_max ? 10'd0 : v + 10'd1;
        end
        else
        begin
/* the next pixel */
            h <= h + 11'd1;
        end
/* frame start (after the picture) */
        if (h == 11'd0 && v == v_act)
        begin
            if (nw_s2 == nw_s3)
            begin
                rb <= nw_s3;
            end
/* the frame toggle; a line toggle at every second screen line */
            f_tgl <= !f_tgl;
        end
        if (h == 11'd0 && v >= v_off + FIRST_REPEAT && v < v_off + LINE_DOUBLE * H && !sv[0])
        begin
/* picture line sv / 2 on screen now */
            l_tgl <= !l_tgl;
        end

/* stage 1: line buffer word (lq); stage 2: pixel colour (ci, 0 = black outside the */
/* picture); stage 3: palette (pq); stage 4: the outputs */
        pix_d  <= sh[1];
        cont_d <= cont;
        ci     <= cont_d ? (pix_d ? lq[15:8] : lq[7:0]) : 8'h00;
/* the pipeline's delays */
        act_d  <= {act_d[1:0], act};
        hs_d   <= {hs_d[1:0], hs_ah};
        vs_d   <= {vs_d[1:0], vs_ah};

/* the pixel out */
        rgb    <= pq;
        active <= act_d[2];
        hsync  <= !hs_d[2];
/* the vertical sync */
        vsync  <= !vs_d[2];
    end

endmodule

`default_nettype wire
