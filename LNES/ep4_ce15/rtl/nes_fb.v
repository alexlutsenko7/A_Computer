/* nes_fb -- LNES frame buffer video: the PPU's picture goes into SDRAM and is shown at */
/* 640 x 480 @ 60 Hz (as LTari's atari_fb, here for the NES's 256 x 240 pixels) */
/* */
/* Writer (clk): one pixel per dot (px_stb with x, y, colour 0-63 and the three emphasis */
/* bits); two pixels make a 16-bit word {emphasis, 0, right pixel, left pixel}, 128 words */
/* per line. Each word goes through a 256-entry FIFO (clk_sd) into SDRAM. */
/* */
/* Three buffers (triple buffering): the writer fills one; at px_eof (the frame is */
/* complete) it becomes the newest, and the writer goes on in the buffer that is neither */
/* the newest nor the one on screen. The reader takes the newest buffer at the start of */
/* each output frame, so every frame it shows is complete. The NES's clock is chosen so */
/* that its frame rate is the VGA frame rate within 9 ppm (nes_pll.v): a frame is shown */
/* twice or left out about once in half an hour. */
/* */
/* SDRAM byte address of a word: {3'd2 + buffer, line[7:0], word[7:0], 1'b0}: */
/* buffers at 0x40000 / 0x60000 / 0x80000, 512 bytes per line. */
/* */
/* Reader (pclk = 25.208 MHz, 800 x 525): fetches each picture line once into a 4-line */
/* buffer (block RAM, written at clk_sd), up to 3 lines ahead of the line on screen, and */
/* shows every line twice at 2 screen pixels per pixel: 512 x 480 in the middle of the */
/* 640 x 480, black left and right. Colours from the palette (PAL_HEX, 512 entries of */
/* 12 bits: emphasis * 64 + colour, tools/mk_nestables.py). - syncs, 4 pclk after h / v. */
/* */
/* SDRAM port (clk_sd): m_req is held until m_ack (one access at a time). */
/* Screenshots (ESP32): hold = 1 keeps the newest buffer as it is. */
`default_nettype none

module nes_fb #(
/* words per line, lines */
    parameter integer W  = 128,
    parameter integer H  = 240,
    parameter         PAL_HEX = "nes_palette.hex"
)(
/* PPU side (clk) */
    input  wire        clk,
    input  wire        rst_n,
    input  wire        px_stb,
    input  wire [7:0]  px_x,
    input  wire [7:0]  px_y,
    input  wire [5:0]  px_c,
    input  wire [2:0]  px_e,
    input  wire        px_eof,
/* no buffer change (screenshot); quasi-static */
    input  wire        hold,
/* the last complete buffer */
    output reg  [1:0]  newest,

/* SDRAM side (clk_sd = 4 x clk, rising edges aligned) */
    input  wire        clk_sd,
    input  wire        rst_sd_n,
    output reg         m_req,
    output reg         m_we,
    output reg  [21:0] m_addr,
    output reg  [15:0] m_wdata,
    input  wire        m_ack,
    input  wire [15:0] m_rdata,

/* video side */
    input  wire        pclk,
    input  wire        prst_n,
/* {red, green, blue}, 4 bits each */
    output reg  [11:0] rgb,
    output reg         hsync,
    output reg         vsync,
    output reg         active
);

/* the last of the three buffers; the buffer read after reset */
localparam [1:0] BUF_LAST = 2'd2;
localparam [1:0] BUF_START_RD = 2'd2;
/* lines fetched ahead of the line shown */
localparam [9:0] FETCH_AHEAD = 10'd3;
/* SDRAM bank (128 KB units) of the first frame buffer */
localparam [2:0] FB_BANK0 = 3'd2;
/* the picture's first screen column: (640 - 512) / 2; its width on screen */
localparam [10:0] H_OFF = 11'd64;
localparam [10:0] H_PIC = 11'd512;
/* the VGA mode: 640 x 480 in 800 x 525 */
localparam [10:0] H_ACT = 11'd640;
localparam [9:0]  V_ACT = 10'd480;
localparam [10:0] H_MAX = 11'd799;
/* last line of a frame; the syncs' first pixel / line and the first after them */
localparam [9:0]  V_MAX = 10'd524;
localparam [10:0] HS_BEG = 11'd656;
localparam [10:0] HS_END = 11'd752;
/* the vertical sync */
localparam [9:0]  VS_BEG = 10'd490;
localparam [9:0]  VS_END = 10'd492;
/* the first line toggle comes two screen lines into the picture */
localparam [9:0] FIRST_REPEAT = 10'd2;

/* the buffer that is neither a nor b (a == b only by a glitch: any other one) */
function [1:0] third(input [1:0] a, input [1:0] b);
    third = (a != b && a != 2'd3 && b != 2'd3) ? 2'd3 - a - b : (a == BUF_LAST ? 2'd0 : a + 2'd1);
endfunction

/* Writer (clk) */
reg  [1:0]  rb;
reg  [1:0]  wb;
reg  [1:0]  hold_s;
/* the reader's buffer, synchronised; the pixel pair being collected */
reg  [1:0]  rb_s1, rb_s2, rb_s3;
reg  [5:0]  w_left;
reg  [15:0] w_data;
/* {buffer, line, word} */
reg  [17:0] w_loc;
reg         w_tgl;

always @(posedge clk or negedge rst_n)
/* at reset */
    if (!rst_n)
    begin
/* at reset: buffer 0 written, 1 newest, 2 read */
        wb     <= 2'd0;
        newest <= 2'd1;
        rb_s1  <= BUF_START_RD;
/* the synchronisers */
        rb_s2  <= BUF_START_RD;
        rb_s3  <= BUF_START_RD;
        hold_s <= 2'b00;
/* no word yet */
        w_left <= 6'd0;
        w_data <= 16'd0;
        w_loc  <= 18'd0;
/* no word handed over yet */
        w_tgl  <= 1'b0;
    end
    else
    begin
/* the buffer the reader shows */
        rb_s1 <= rb;
        rb_s2 <= rb_s1;
        rb_s3 <= rb_s2;
/* the screenshot's hold, synchronised */
        hold_s <= {hold_s[0], hold};
/* frame complete */
        if (px_eof && !hold_s[1])
        begin
            newest <= wb;
            wb     <= third(wb, rb_s2 == rb_s3 ? rb_s3 : newest);
        end
/* the left pixel waits for the right one; the pair is handed to the FIFO */
        if (px_stb && !px_x[0])
        begin
            w_left <= px_c;
        end
        if (px_stb && px_x[0])
        begin
/* the pair as a word, and where it goes */
            w_data <= {px_e, 1'b0, px_c, w_left};
            w_loc  <= {wb, px_y, 1'b0, px_x[7:1]};
            w_tgl  <= !w_tgl;
        end
    end

/* FIFO (clk_sd): w_tgl / w_data / w_loc come from clk, which is synchronous */
reg  [33:0] fifo [0:255];
reg  [33:0] f_q;
reg  [7:0]  f_wp, f_rp;
/* the write toggle as seen last */
reg         wt_d;
always @(posedge clk_sd)
begin
    if (w_tgl != wt_d)
    begin
/* a word enters the FIFO's memory */
        fifo[f_wp] <= {w_loc, w_data};
    end
/* the FIFO's memory, read registered */
    f_q <= fifo[f_rp];
end

/* Line fetch + SDRAM requests (clk_sd). Reads (the screen cannot wait) go first. */
reg         f_tgl, l_tgl;
reg  [3:0]  ft_s, lt_s;
reg  [1:0]  rbs1, rbs2;
/* next line to fetch, line on screen, next word of line fn */
reg  [8:0]  fn, fd;
reg  [7:0]  fw;
/* buffer on screen */
reg  [1:0]  frb;
reg         busy, is_rd, f_wait, f_has;
/* the read in flight belongs to the previous frame */
reg         stale;
reg  [8:0]  lb_wa;
wire        f_ev = ft_s[3] != ft_s[2];
/* a line was shown */
wire        l_ev = lt_s[3] != lt_s[2];
/* lines are fetched up to three ahead */
wire        need = fn < H && {1'b0, fn} <= {1'b0, fd} + FETCH_AHEAD;

/* the line buffer: 4 lines of 128 words */
reg [15:0] lbuf [0:511];
always @(posedge clk_sd)
    if (busy && is_rd && m_ack)
    begin
/* a word read from the SDRAM goes into the line buffer */
        lbuf[lb_wa] <= m_rdata;
    end

always @(posedge clk_sd or negedge rst_sd_n)
    if (!rst_sd_n)
    begin
/* at reset */
        wt_d   <= 1'b0;
        f_wp   <= 8'd0;
        f_rp   <= 8'd0;
/* synchronisers */
        ft_s   <= 4'd0;
        lt_s   <= 4'd0;
        rbs1   <= BUF_START_RD;
/* the reader's buffer */
        rbs2   <= BUF_START_RD;
/* nothing to fetch before the first frame start */
        fn     <= H[8:0];
        fd     <= 9'd0;
        fw     <= 8'd0;
/* the buffer on screen */
        frb    <= BUF_START_RD;
/* no access running */
        busy   <= 1'b0;
        is_rd  <= 1'b0;
        f_wait <= 1'b0;
/* no word waiting */
        f_has  <= 1'b0;
        stale  <= 1'b0;
/* no request */
        lb_wa  <= 9'd0;
        m_req  <= 1'b0;
        m_we   <= 1'b0;
/* address and data */
        m_addr <= 22'd0;
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
/* the reader's line toggle */
        lt_s <= {lt_s[2:0], l_tgl};
/* the reader's buffer */
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
/* a frame starts: line 0, word 0, the buffer of this frame */
            fn  <= 9'd0;
            fd  <= 9'd0;
            fw  <= 8'd0;
/* the buffer of this frame */
            frb <= rbs2;
/* a read still running is stale */
            if (busy && is_rd)
            begin
                stale <= 1'b1;
            end
        end
        else if (l_ev)
        begin
/* a line was shown: the next one may be fetched */
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
                m_addr  <= {2'b00, FB_BANK0 + {1'b0, frb}, fn[7:0], fw, 1'b0};
/* its place in the line buffer */
                lb_wa   <= {fn[1:0], fw[6:0]};
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
                m_addr  <= {2'b00, FB_BANK0 + {1'b0, f_q[33:32]}, f_q[31:16], 1'b0};
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
reg  [10:0] h;
reg  [9:0]  v;
reg  [1:0]  nw_s1, nw_s2, nw_s3;
/* content pixel (2 per picture pixel) */
wire [10:0] sh    = h - H_OFF;
wire        cont  = h >= H_OFF && sh < H_PIC && v < V_ACT;
wire        act   = h < H_ACT && v < V_ACT;
/* the syncs, active high */
wire        hs_ah = h >= HS_BEG && h < HS_END;
wire        vs_ah = v >= VS_BEG && v < VS_END;

reg  [11:0] pal [0:511];
/* the palette's file */
initial $readmemh(PAL_HEX, pal);

/* the pipeline: line buffer word, palette index, colour */
reg  [15:0] lq;
reg  [8:0]  ci;
reg  [11:0] pq;
/* the right pixel of a pair; delays */
reg         pix_d;
reg  [2:0]  cont_d;
reg  [2:0]  act_d, hs_d, vs_d;

/* line buffer and palette are read registered */
always @(posedge pclk)
begin
    lq <= lbuf[{v[2:1], sh[8:2]}];
    pq <= pal[ci];
end

/* the reader */
always @(posedge pclk or negedge prst_n)
    if (!prst_n)
    begin
        h      <= 11'd0;
/* the counters */
        v      <= 10'd0;
        rb     <= BUF_START_RD;
/* toggles; synchronisers */
        f_tgl  <= 1'b0;
        l_tgl  <= 1'b0;
        nw_s1  <= 2'd1;
/* the newest buffer */
        nw_s2  <= 2'd1;
        nw_s3  <= 2'd1;
/* pipeline */
        pix_d  <= 1'b0;
        ci     <= 9'd0;
        cont_d <= 3'b000;
/* delays of the picture area and the syncs */
        act_d  <= 3'b000;
        hs_d   <= 3'b000;
        vs_d   <= 3'b000;
/* the pins idle */
        rgb    <= 12'd0;
        hsync  <= 1'b1;
        vsync  <= 1'b1;
/* no picture */
        active <= 1'b0;
    end
    else
    begin
/* the newest buffer, synchronised */
        nw_s1 <= newest;
        nw_s2 <= nw_s1;
        nw_s3 <= nw_s2;
/* the counters */
        if (h == H_MAX)
        begin
            h <= 11'd0;
            v <= v == V_MAX ? 10'd0 : v + 10'd1;
        end
        else
        begin
/* the next pixel */
            h <= h + 11'd1;
        end
/* frame start (after the picture): the newest complete buffer */
        if (h == 11'd0 && v == V_ACT)
        begin
            if (nw_s2 == nw_s3)
            begin
                rb <= nw_s3;
            end
/* the frame toggle */
            f_tgl <= !f_tgl;
        end
/* a line toggle at every second screen line: picture line v / 2 is on screen now */
        if (h == 11'd0 && v >= FIRST_REPEAT && v < V_ACT && !v[0])
        begin
            l_tgl <= !l_tgl;
        end

/* stage 1: line buffer word (lq); stage 2: palette index (ci); stage 3: colour (pq); */
/* stage 4: the outputs, black outside the picture */
        pix_d  <= sh[1];
        cont_d <= {cont_d[1:0], cont};
        ci     <= {lq[15:13], pix_d ? lq[11:6] : lq[5:0]};
/* the picture area and the syncs, delayed */
        act_d  <= {act_d[1:0], act};
        hs_d   <= {hs_d[1:0], hs_ah};
        vs_d   <= {vs_d[1:0], vs_ah};

/* the pixel out */
        rgb    <= cont_d[2] ? pq : 12'd0;
        active <= act_d[2];
        hsync  <= !hs_d[2];
/* the vertical sync */
        vsync  <= !vs_d[2];
    end

endmodule

`default_nettype wire
