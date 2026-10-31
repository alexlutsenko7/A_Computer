//=============================================================================
// atari_fb -- frame buffer video: GTIA's picture goes into SDRAM and is shown at
//             640 x 480 @ 60 Hz or 720 x 576 @ 50 Hz (as L64's c64_fb, here for GTIA's pixels)
//
// Writer (clk): GTIA's two hi-res pixels per colour clock (px_stb, 8-bit colours
// {hue, luminance}), colour clocks X0..X0+W-1 of lines Y0..Y0+H-1 = 376 x 240, the whole
// visible PAL picture (NOTES.md). One 16-bit word per colour clock (left pixel in bits
// 7:0), 188 words per line. Each word goes through a 256-entry FIFO (clk_sd) into SDRAM.
//
// Three buffers (triple buffering, as c64_fb): the writer fills one; when a frame is
// complete it becomes the newest, and the writer goes on in the buffer that is neither
// the newest nor the one on screen. The reader takes the newest buffer at the start of
// each output frame, so every frame it shows is complete.
//
// SDRAM byte address of a word: {3'd2 + buffer, line[7:0], word[7:0], 1'b0}:
// buffers at 0x40000 / 0x60000 / 0x80000, 512 bytes per line.
//
// Reader (pclk): fetches each picture line once into a 4-line buffer (block RAM,
// written at clk_sd), up to 3 lines ahead of the line on screen, and shows every
// line twice at 2 pixels per hi-res pixel. The 240 lines fill 480 output lines; the
// width is cropped to the middle of the 376 hi-res pixels (as a TV's overscan):
//   m60 = 1: 640 x 480 @ 60 Hz (800 x 525, VESA / CEA VIC 1), pclk 25.208 MHz:
//            hi-res pixels 28..347 (320 = the normal playfield), all 240 lines
//   m60 = 0: 720 x 576 @ 50 Hz (864 x 625, CEA VIC 17), pclk 27.009 MHz:
//            hi-res pixels 8..367 (360), the 480 lines 48 lines below the top
// Both modes: - syncs; the same timing as LSpectrum's vga_timing.
// Output: the PAL palette (PAL_HEX, tools/mk_palette.py, 6 bits per colour; entry 0 is
// black), syncs and active, 4 pclk after h / v.
//
// SDRAM port (clk_sd): m_req is held until m_ack (one access at a time); the
// system's arbiter serves it between the machine's own accesses.
//
// Screenshots (ESP32): hold = 1 keeps the newest buffer as it is (the writer goes on
// overwriting its own buffer), so the ESP32 can read a complete picture from SDRAM.
//=============================================================================
`default_nettype none

module atari_fb #(
    parameter [7:0]   X0 = 8'h22,       // first stored colour clock
    parameter [8:0]   Y0 = 9'd8,        // first stored scan line
    parameter integer W  = 188,         // words (colour clocks) per line
    parameter integer H  = 240,         // lines
    parameter         PAL_HEX = "atari_palette.hex"
)(
    // GTIA side (clk)
    input  wire        clk,
    input  wire        rst_n,           // power-up
    input  wire        px_stb,
    input  wire [7:0]  px_cc,
    input  wire [8:0]  px_vc,
    input  wire [7:0]  px0,
    input  wire [7:0]  px1,
    input  wire        hold,            // no buffer change (screenshot); quasi-static
    output reg  [1:0]  newest,          // the last complete buffer

    // SDRAM side (clk_sd = 3 x clk, rising edges aligned)
    input  wire        clk_sd,
    input  wire        rst_sd_n,
    output reg         m_req,
    output reg         m_we,
    output reg  [20:0] m_addr,
    output reg  [15:0] m_wdata,
    input  wire        m_ack,           // the access is done (m_rdata valid for a read)
    input  wire [15:0] m_rdata,

    // video side
    input  wire        pclk,
    input  wire        prst_n,
    input  wire        m60,             // static while prst_n = 1
    output reg  [17:0] rgb,             // {red, green, blue}, 6 bits each
    output reg         hsync,
    output reg         vsync,
    output reg         active
);

// the buffer that is neither a nor b (a == b only by a glitch: any other one)
function [1:0] third(input [1:0] a, input [1:0] b);
    third = (a != b && a != 2'd3 && b != 2'd3) ? 2'd3 - a - b : (a == 2'd2 ? 2'd0 : a + 2'd1);
endfunction

//-----------------------------------------------------------------------------
// Writer (clk)
//-----------------------------------------------------------------------------
reg  [1:0]  rb;                         // buffer on screen (pclk)
reg  [1:0]  wb;
reg  [1:0]  hold_s;
reg  [1:0]  rb_s1, rb_s2, rb_s3;
reg  [15:0] w_data;
reg  [17:0] w_loc;                      // {buffer, line, word}
reg         w_tgl;

wire [7:0] xo   = px_cc - X0;
wire [8:0] yl   = px_vc - Y0;
wire       in_x = px_cc >= X0 && xo < W;
wire       in_y = px_vc >= Y0 && px_vc < Y0 + H;

always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
        wb     <= 2'd0;
        newest <= 2'd1;
        rb_s1  <= 2'd2;
        rb_s2  <= 2'd2;
        rb_s3  <= 2'd2;
        hold_s <= 2'b00;
        w_data <= 16'd0;
        w_loc  <= 18'd0;
        w_tgl  <= 1'b0;
    end else begin
        rb_s1 <= rb;
        rb_s2 <= rb_s1;
        rb_s3 <= rb_s2;
        hold_s <= {hold_s[0], hold};
        if (px_stb && px_cc == X0 && px_vc == Y0 + H && !hold_s[1]) begin   // frame complete
            newest <= wb;
            wb     <= third(wb, rb_s2 == rb_s3 ? rb_s3 : newest);
        end
        if (px_stb && in_x && in_y) begin
            w_data <= {px1, px0};
            w_loc  <= {wb, yl[7:0], xo};
            w_tgl  <= !w_tgl;
        end
    end

//-----------------------------------------------------------------------------
// FIFO (clk_sd): w_tgl / w_data / w_loc come from clk, which is synchronous
//-----------------------------------------------------------------------------
reg  [33:0] fifo [0:255];
reg  [33:0] f_q;
reg  [7:0]  f_wp, f_rp;
reg         wt_d;
always @(posedge clk_sd) begin
    if (w_tgl != wt_d) fifo[f_wp] <= {w_loc, w_data};
    f_q <= fifo[f_rp];
end

//-----------------------------------------------------------------------------
// Line fetch + SDRAM requests (clk_sd). Reads (the screen cannot wait) go first.
//-----------------------------------------------------------------------------
reg         f_tgl, l_tgl;               // pclk: frame start, next line on screen
reg  [3:0]  ft_s, lt_s;
reg  [1:0]  rbs1, rbs2;
reg  [8:0]  fn, fd;                     // next line to fetch, line on screen
reg  [7:0]  fw;                         // next word of line fn
reg  [1:0]  frb;                        // buffer on screen
reg         busy, is_rd, f_wait, f_has;
reg         stale;                      // the read in flight belongs to the previous frame
reg  [9:0]  lb_wa;                      // line buffer address of the read
wire        f_ev = ft_s[3] != ft_s[2];
wire        l_ev = lt_s[3] != lt_s[2];
wire        need = fn < H && {1'b0, fn} <= {1'b0, fd} + 10'd3;

reg [15:0] lbuf [0:1023];
always @(posedge clk_sd)
    if (busy && is_rd && m_ack) lbuf[lb_wa] <= m_rdata;

always @(posedge clk_sd or negedge rst_sd_n)
    if (!rst_sd_n) begin
        wt_d   <= 1'b0;
        f_wp   <= 8'd0;
        f_rp   <= 8'd0;
        ft_s   <= 4'd0;
        lt_s   <= 4'd0;
        rbs1   <= 2'd2;
        rbs2   <= 2'd2;
        fn     <= H[8:0];               // nothing to fetch before the first frame start
        fd     <= 9'd0;
        fw     <= 8'd0;
        frb    <= 2'd2;
        busy   <= 1'b0;
        is_rd  <= 1'b0;
        f_wait <= 1'b0;
        f_has  <= 1'b0;
        stale  <= 1'b0;
        lb_wa  <= 10'd0;
        m_req  <= 1'b0;
        m_we   <= 1'b0;
        m_addr <= 21'd0;
        m_wdata <= 16'd0;
    end else begin
        wt_d <= w_tgl;
        if (w_tgl != wt_d) f_wp <= f_wp + 8'd1;
        ft_s <= {ft_s[2:0], f_tgl};
        lt_s <= {lt_s[2:0], l_tgl};
        rbs1 <= rb;
        rbs2 <= rbs1;

        // FIFO head -> f_has (f_q is read one clock after f_rp is set)
        if (f_wait) begin
            f_wait <= 1'b0;
            f_has  <= 1'b1;
        end else if (!f_has && f_wp != f_rp)
            f_wait <= 1'b1;

        if (f_ev) begin
            fn  <= 9'd0;
            fd  <= 9'd0;
            fw  <= 8'd0;
            frb <= rbs2;
            if (busy && is_rd) stale <= 1'b1;
        end else if (l_ev)
            fd <= fd + 9'd1;

        if (!busy) begin
            if (need && !f_ev) begin
                busy    <= 1'b1;
                is_rd   <= 1'b1;
                m_req   <= 1'b1;
                m_we    <= 1'b0;
                m_addr  <= {1'b0, 3'd2 + {1'b0, frb}, fn[7:0], fw, 1'b0};
                lb_wa   <= {fn[1:0], fw};
                stale   <= 1'b0;
            end else if (f_has) begin
                busy    <= 1'b1;
                is_rd   <= 1'b0;
                m_req   <= 1'b1;
                m_we    <= 1'b1;
                m_addr  <= {1'b0, 3'd2 + {1'b0, f_q[33:32]}, f_q[31:16], 1'b0};
                m_wdata <= f_q[15:0];
                f_has   <= 1'b0;
                f_rp    <= f_rp + 8'd1;
            end
        end else if (m_ack) begin
            busy  <= 1'b0;
            m_req <= 1'b0;
            if (is_rd && !f_ev && !stale) begin
                if (fw == W - 1) begin
                    fw <= 8'd0;
                    fn <= fn + 9'd1;
                end else
                    fw <= fw + 8'd1;
            end
        end
    end

//-----------------------------------------------------------------------------
// Reader (pclk)
//-----------------------------------------------------------------------------
// A line / frame starts with the active area, then front porch, sync, back porch.
wire [10:0] h_skip = m60 ? 11'd56   : 11'd16;   // content pixels left of the screen: 2 * (376 - width) / 2
wire [9:0]  v_off  = m60 ? 10'd0    : 10'd48;   // (576 - 2 * 240) / 2
wire [10:0] h_act  = m60 ? 11'd640  : 11'd720;
wire [9:0]  v_act  = m60 ? 10'd480  : 10'd576;
wire [10:0] h_max  = m60 ? 11'd799  : 11'd863;
wire [9:0]  v_max  = m60 ? 10'd524  : 10'd624;
wire [10:0] hs_beg = m60 ? 11'd656  : 11'd732;
wire [10:0] hs_end = m60 ? 11'd752  : 11'd796;
wire [9:0]  vs_beg = m60 ? 10'd490  : 10'd581;
wire [9:0]  vs_end = m60 ? 10'd492  : 10'd586;

reg  [10:0] h;
reg  [9:0]  v;
reg  [1:0]  nw_s1, nw_s2, nw_s3;
wire [9:0]  sv    = v - v_off;          // content line (2 per picture line)
wire [10:0] sh    = h + h_skip;         // content pixel (2 per hi-res pixel)
wire        cont  = v >= v_off && v < v_off + 2 * H && h < h_act;
wire        act   = h < h_act && v < v_act;
wire        hs_ah = h >= hs_beg && h < hs_end;
wire        vs_ah = v >= vs_beg && v < vs_end;

reg  [17:0] pal [0:255];
initial $readmemh(PAL_HEX, pal);

reg  [15:0] lq;
reg  [7:0]  ci;
reg  [17:0] pq;
reg         pix_d;
reg         cont_d;
reg  [2:0]  act_d, hs_d, vs_d;

always @(posedge pclk) begin
    lq <= lbuf[{sv[2:1], sh[9:2]}];
    pq <= pal[ci];
end

always @(posedge pclk or negedge prst_n)
    if (!prst_n) begin
        h      <= 11'd0;
        v      <= 10'd0;
        rb     <= 2'd2;
        f_tgl  <= 1'b0;
        l_tgl  <= 1'b0;
        nw_s1  <= 2'd1;
        nw_s2  <= 2'd1;
        nw_s3  <= 2'd1;
        pix_d  <= 1'b0;
        ci     <= 8'd0;
        cont_d <= 1'b0;
        act_d  <= 3'b000;
        hs_d   <= 3'b000;
        vs_d   <= 3'b000;
        rgb    <= 18'd0;
        hsync  <= 1'b1;
        vsync  <= 1'b1;
        active <= 1'b0;
    end else begin
        nw_s1 <= newest;
        nw_s2 <= nw_s1;
        nw_s3 <= nw_s2;
        if (h == h_max) begin
            h <= 11'd0;
            v <= v == v_max ? 10'd0 : v + 10'd1;
        end else
            h <= h + 11'd1;
        if (h == 11'd0 && v == v_act) begin                             // frame start (after the picture)
            if (nw_s2 == nw_s3) rb <= nw_s3;
            f_tgl <= !f_tgl;
        end
        if (h == 11'd0 && v >= v_off + 10'd2 && v < v_off + 2 * H && !sv[0])
            l_tgl <= !l_tgl;                                            // picture line sv / 2 on screen now

        // stage 1: line buffer word (lq); stage 2: pixel colour (ci, 0 = black outside the
        // picture); stage 3: palette (pq); stage 4: the outputs
        pix_d  <= sh[1];
        cont_d <= cont;
        ci     <= cont_d ? (pix_d ? lq[15:8] : lq[7:0]) : 8'h00;
        act_d  <= {act_d[1:0], act};
        hs_d   <= {hs_d[1:0], hs_ah};
        vs_d   <= {vs_d[1:0], vs_ah};

        rgb    <= pq;
        active <= act_d[2];
        hsync  <= !hs_d[2];
        vsync  <= !vs_d[2];
    end

endmodule

`default_nettype wire
