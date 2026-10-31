//=============================================================================
// c64_fb -- frame buffer video: the VIC-II picture goes into SDRAM and is shown
//           at 60 Hz (800 x 600) or 50 Hz (the VIC-II's own 1008 x 624 timing)
//
// Writer (clk = dot4x): Kawari's colour index per dot, taken as its scan doubler
// took it (the dot at raster_x is complete when raster_x moves on). 400 dots
// (raster_x X0..X0+399) x 284 lines (raster lines Y0..Y0+283) = the whole visible
// PAL picture, 4 dots per 16-bit word (first dot in bits 3:0), 100 words per line.
// Each word goes through a 256-entry FIFO (clk_sd) into SDRAM.
//
// Three buffers (triple buffering): the writer fills one; when a frame is complete
// it becomes the newest, and the writer goes on in the buffer that is neither the
// newest nor the one on screen. The reader takes the newest buffer at the start
// of each output frame, so every frame it shows is complete (at 60 Hz every 5th
// C64 frame is shown twice; at 50 Hz each frame once, one frame late).
//
// SDRAM byte address of a word: {3'd2 + buffer, line[8:0], word[6:0], 1'b0}:
// buffers at 0x40000 / 0x60000 / 0x80000, 256 bytes per line.
//
// Reader (pclk): fetches each picture line once into a 4-line buffer (block RAM,
// written at clk_sd), up to 3 lines ahead of the line on screen, and shows every
// line twice at 2 pixels per dot: 800 x 568 in the middle of a 800 x 600 area.
//   m60 = 1: 800 x 600 @ 60 Hz, VESA timing (1056 x 628, + syncs), pclk 39.80 MHz
//            (VESA 40.00: -0.5 %), 37.69 kHz, 60.02 Hz
//   m60 = 0: 800 x 600 active in 1008 x 624, - syncs, pclk 31.51 MHz = the C64's
//            dot4x: 31.26 kHz, 50.12 Hz, the picture timing the VIC-II's scan doubler had
// Output: Kawari's palette (6 bits per colour), syncs and active, 2 pclk after h/v.
//
// SDRAM port (clk_sd): m_req is held until m_ack (one access at a time); the
// system's arbiter serves it between the C64's own accesses.
//
// Screenshots (ESP32): hold = 1 keeps the newest buffer as it is (the writer goes on
// overwriting its own buffer), so the ESP32 can read a complete picture from SDRAM.
//=============================================================================
`default_nettype none

module c64_fb #(
    parameter [9:0]   X0 = 10'd92,      // first stored dot (Kawari raster_x)
    parameter [8:0]   Y0 = 9'd16,       // first stored raster line
    parameter integer W4 = 100,         // words per line (4 dots each)
    parameter integer H  = 284          // lines
)(
    // VIC-II side (dot4x)
    input  wire        clk,
    input  wire        rst_n,           // power-up
    input  wire [3:0]  pixel,
    input  wire [9:0]  rx,
    input  wire [8:0]  rline,
    input  wire        hold,            // no buffer change (screenshot); quasi-static
    output reg  [1:0]  newest,          // the last complete buffer

    // SDRAM side (clk_sd = 3 x clk, rising edges aligned)
    input  wire        clk_sd,
    input  wire        rst_sd_n,
    output reg         m_req,
    output reg         m_we,
    output reg  [19:0] m_addr,
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
reg  [3:0]  p_d;
reg  [9:0]  x_d;
reg  [11:0] sh;                         // the line's last 3 dots
reg  [1:0]  wb;
reg  [1:0]  hold_s;
reg  [1:0]  rb_s1, rb_s2, rb_s3;
reg  [15:0] w_data;
reg  [17:0] w_loc;                      // {buffer, line, word}
reg         w_tgl;

wire       ev   = rx != x_d;            // the dot at x_d (colour p_d) is complete
wire [9:0] xo   = x_d - X0;
wire [8:0] yl   = rline - Y0;
wire       in_x = x_d >= X0 && xo < W4 * 4;
wire       in_y = rline >= Y0 && rline < Y0 + H;

always @(posedge clk) begin
    p_d <= pixel;
    x_d <= rx;
end

always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
        sh     <= 12'd0;
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
        if (ev && x_d == X0 && rline == Y0 + H && !hold_s[1]) begin     // frame complete
            newest <= wb;
            wb     <= third(wb, rb_s2 == rb_s3 ? rb_s3 : newest);
        end
        if (ev && in_x && in_y) begin
            sh <= {p_d, sh[11:4]};
            if (xo[1:0] == 2'd3) begin
                w_data <= {p_d, sh};
                w_loc  <= {wb, yl, xo[8:2]};
                w_tgl  <= !w_tgl;
            end
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
reg  [6:0]  fw;                         // next word of line fn
reg  [1:0]  frb;                        // buffer on screen
reg         busy, is_rd, f_wait, f_has;
reg         stale;                      // the read in flight belongs to the previous frame
reg  [8:0]  lb_wa;                      // line buffer address of the read
wire        f_ev = ft_s[3] != ft_s[2];
wire        l_ev = lt_s[3] != lt_s[2];
wire        need = fn < H && {1'b0, fn} <= {1'b0, fd} + 10'd3;

reg [15:0] lbuf [0:511];
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
        fw     <= 7'd0;
        frb    <= 2'd2;
        busy   <= 1'b0;
        is_rd  <= 1'b0;
        f_wait <= 1'b0;
        f_has  <= 1'b0;
        stale  <= 1'b0;
        lb_wa  <= 9'd0;
        m_req  <= 1'b0;
        m_we   <= 1'b0;
        m_addr <= 20'd0;
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
            fw  <= 7'd0;
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
                m_addr  <= {3'd2 + {1'b0, frb}, fn, fw, 1'b0};
                lb_wa   <= {fn[1:0], fw};
                stale   <= 1'b0;
            end else if (f_has) begin
                busy    <= 1'b1;
                is_rd   <= 1'b0;
                m_req   <= 1'b1;
                m_we    <= 1'b1;
                m_addr  <= {3'd2 + {1'b0, f_q[33:32]}, f_q[31:16], 1'b0};
                m_wdata <= f_q[15:0];
                f_has   <= 1'b0;
                f_rp    <= f_rp + 8'd1;
            end
        end else if (m_ack) begin
            busy  <= 1'b0;
            m_req <= 1'b0;
            if (is_rd && !f_ev && !stale) begin
                if (fw == W4 - 1) begin
                    fw <= 7'd0;
                    fn <= fn + 9'd1;
                end else
                    fw <= fw + 7'd1;
            end
        end
    end

//-----------------------------------------------------------------------------
// Reader (pclk)
//-----------------------------------------------------------------------------
wire [10:0] h_max  = m60 ? 11'd1055 : 11'd1007;
wire [9:0]  v_max  = m60 ? 10'd627  : 10'd623;
wire [10:0] hs_beg = m60 ? 11'd840  : 11'd824;
wire [10:0] hs_end = m60 ? 11'd968  : 11'd900;
wire [9:0]  vs_beg = m60 ? 10'd601  : 10'd603;
wire [9:0]  vs_end = m60 ? 10'd605  : 10'd619;

reg  [10:0] h;
reg  [9:0]  v;
reg  [1:0]  nw_s1, nw_s2, nw_s3;
wire [9:0]  sv    = v - 10'd16;         // content line (2 per picture line)
wire        cont  = v >= 10'd16 && v < 10'd16 + 2 * H && h < 11'd800;
wire        act   = h < 11'd800 && v < 10'd600;
wire        hs_ah = h >= hs_beg && h < hs_end;
wire        vs_ah = v >= vs_beg && v < vs_end;

reg  [15:0] lq;
reg  [1:0]  nib_d;
reg         cont_d, act_d, hs_d, vs_d;

always @(posedge pclk) lq <= lbuf[{sv[2:1], h[9:3]}];

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
        nib_d  <= 2'd0;
        cont_d <= 1'b0;
        act_d  <= 1'b0;
        hs_d   <= 1'b0;
        vs_d   <= 1'b0;
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
        if (h == 11'd0 && v == 10'd600) begin                          // frame start (after the picture)
            if (nw_s2 == nw_s3) rb <= nw_s3;
            f_tgl <= !f_tgl;
        end
        if (h == 11'd0 && v >= 10'd18 && v < 10'd16 + 2 * H && !sv[0])
            l_tgl <= !l_tgl;                                            // picture line sv / 2 on screen now

        nib_d  <= h[2:1];
        cont_d <= cont;
        act_d  <= act;
        hs_d   <= hs_ah;
        vs_d   <= vs_ah;

        rgb    <= cont_d ? palette(lq[{nib_d, 2'b00} +: 4]) : 18'd0;
        active <= act_d;
        hsync  <= m60 ? hs_d : !hs_d;
        vsync  <= m60 ? vs_d : !vs_d;
    end

// Kawari's default palette (registers.v, full brightness)
function [17:0] palette(input [3:0] c);
    case (c)
        4'd0:  palette = {6'h00, 6'h00, 6'h00};     // black
        4'd1:  palette = {6'h3f, 6'h3f, 6'h3f};     // white
        4'd2:  palette = {6'h2b, 6'h0a, 6'h0a};     // red
        4'd3:  palette = {6'h18, 6'h36, 6'h33};     // cyan
        4'd4:  palette = {6'h2c, 6'h0f, 6'h2d};     // purple
        4'd5:  palette = {6'h12, 6'h31, 6'h12};     // green
        4'd6:  palette = {6'h0d, 6'h0e, 6'h31};     // blue
        4'd7:  palette = {6'h39, 6'h3b, 6'h13};     // yellow
        4'd8:  palette = {6'h2d, 6'h16, 6'h07};     // orange
        4'd9:  palette = {6'h1a, 6'h0e, 6'h02};     // brown
        4'd10: palette = {6'h3a, 6'h1d, 6'h1b};     // pink
        4'd11: palette = {6'h13, 6'h13, 6'h13};     // dark grey
        4'd12: palette = {6'h21, 6'h21, 6'h21};     // grey
        4'd13: palette = {6'h29, 6'h3e, 6'h27};     // light green
        4'd14: palette = {6'h1c, 6'h1f, 6'h39};     // light blue
        default: palette = {6'h2d, 6'h2d, 6'h2d};   // light grey
    endcase
endfunction

endmodule

`default_nettype wire
