/* md_fb -- LMega: frame buffer for a 50 Hz game shown on a 60 Hz screen (the third video mode) */
/* */
/* The console runs as a 50 Hz machine at its right speed; the VDP's pictures are stored in the */
/* SDRAM and md_video reads the newest complete one 60 times a second. Every fifth frame on */
/* the screen is a repeat. */
/* */
/* Writer (mclk): the VDP's colours with ce_pix while neither blanking is active, one 16-bit */
/* word per pixel (12 bits used), through a 512-entry FIFO into the SDRAM. Three buffers (triple */
/* buffering, as LNES): the writer fills one; when the VDP's picture ends it becomes the newest, */
/* and the writer goes on in the buffer that is neither the newest nor the one on screen. */
/* */
/* SDRAM byte address of a pixel: {3'b101, buffer, line[7:0], column[8:0], 1'b0}: buffers at */
/* 0x500000 / 0x540000 / 0x580000, one SDRAM row (512 words) per line, so the reads can run. */
/* */
/* Reader (clk_sd): at the start of each screen frame (frame_start) it takes the newest buffer, */
/* then fetches every picture line once, in runs of 8 words, up to 3 lines ahead of the line on */
/* screen (line_done = the next line is on screen), into a 4-line buffer that md_video reads */
/* (rd_addr = {line[1:0], column}, rd_q one clock later). */
/* SDRAM port: md_mem's (fbr_* run reads, fbw_* single writes); one access at a time. */
`default_nettype none

module md_fb (
/* from the VDP (mclk) */
    input  wire        mclk,
    input  wire        ce_pix,
    input  wire        hbl,
    input  wire        vbl,
    input  wire [3:0]  r,
    input  wire [3:0]  g,
    input  wire [3:0]  b,
    input  wire        h40,
/* the mode is on (quasi-static); off: nothing is written or fetched */
    input  wire        on,

    input  wire        clk_sd,
    input  wire        rst_sd_n,
/* md_mem */
    output reg         fbr_req,
    output reg  [22:0] fbr_addr,
    input  wire        fbr_ack,
    input  wire        fbr_stb,
    output reg         fbw_req,
    output reg  [22:0] fbw_addr,
    output reg  [15:0] fbw_data,
    input  wire        fbw_ack,
    input  wire [15:0] fb_q,

/* md_video (clk_sd) */
    input  wire        frame_start,
    input  wire        line_done,
    input  wire [10:0] rd_addr,
    output reg  [11:0] rd_q,
/* the stored picture: lines, 320 pixels per line */
    output reg  [8:0]  pic_lines,
    output reg         pic_h40
);

/* the last of the three buffers; the buffer read after reset */
localparam [1:0] BUF_LAST = 2'd2;
localparam [1:0] BUF_START_RD = 2'd2;
/* lines fetched ahead of the line shown */
localparam [9:0] FETCH_AHEAD = 10'd3;
/* the frame buffers' place in the SDRAM: 0x500000 */
localparam [2:0] AREA_FB = 3'b101;
/* words fetched per line (the wider mode's), the words of a run */
localparam [8:0] LINE_WORDS = 9'd320;
localparam [8:0] RUN_WORDS = 9'd8;
/* lines of a picture before the first one was stored */
localparam [8:0] LINES_DEF = 9'd224;
/* the most lines a picture can have */
localparam [8:0] LINES_MAX = 9'd240;

/* the buffer that is neither a nor b (a == b only by a glitch: any other one) */
function [1:0] third(input [1:0] a, input [1:0] b);
    third = (a != b && a != 2'd3 && b != 2'd3) ? 2'd3 - a - b : (a == BUF_LAST ? 2'd0 : a + 2'd1);
endfunction

/* ---- writer (mclk; the registers start at 0 after configuration) ---- */
reg  [1:0]  wb = 2'd0, newest = 2'd1;
reg  [1:0]  rb = BUF_START_RD;
reg  [1:0]  rb_s1 = BUF_START_RD, rb_s2 = BUF_START_RD;
/* the pixel's column and line */
reg  [8:0]  wx = 9'd0, wy = 9'd0;
reg         hbl_d = 1'b1, vbl_d = 1'b1, line_had = 1'b0;
reg  [1:0]  on_m = 2'b00;
/* the pixel handed to the FIFO: {buffer, line, column, colour} */
reg  [30:0] w_word = 31'd0;
reg         w_tgl = 1'b0;

always @(posedge mclk)
begin
/* the blankings as seen last */
    hbl_d <= hbl;
    vbl_d <= vbl;
    on_m  <= {on_m[0], on};
/* the buffer on screen, from the reader's clock (twice as fast, same source) */
    rb_s1 <= rb;
    rb_s2 <= rb_s1;
/* a pixel of the picture */
    if (ce_pix && !hbl && !vbl && on_m[1] && wy < LINES_MAX)
    begin
        w_word   <= {wb, wy[7:0], wx, r, g, b};
        w_tgl    <= !w_tgl;
/* the next column */
        wx       <= wx + 9'd1;
        line_had <= 1'b1;
    end
/* the end of a line that had pixels */
    if (hbl && !hbl_d)
    begin
        wx <= 9'd0;
        if (line_had)
        begin
/* the next line */
            wy <= wy + 9'd1;
        end
        line_had <= 1'b0;
    end
/* the picture ends: it is the newest one, the next goes into a free buffer */
    if (vbl && !vbl_d)
    begin
        wy <= 9'd0;
        if (wy != 9'd0)
        begin
/* the newest picture */
            newest    <= wb;
            wb        <= third(wb, rb_s1 == rb_s2 ? rb_s2 : newest);
            pic_lines <= wy;
/* its width mode */
            pic_h40   <= h40;
        end
    end
end

/* ---- FIFO (clk_sd): w_tgl / w_word come from mclk, which is synchronous ---- */
reg  [30:0] fifo [0:511];
reg  [30:0] f_q;
reg  [8:0]  f_wp, f_rp;
/* the write toggle as seen last */
reg         wt_d;
always @(posedge clk_sd)
begin
    if (w_tgl != wt_d)
    begin
/* a pixel enters the FIFO's memory */
        fifo[f_wp] <= w_word;
    end
/* the FIFO's memory, read registered */
    f_q <= fifo[f_rp];
end

/* ---- the 4-line buffer md_video reads ---- */
reg  [11:0] lbuf [0:2047];
reg  [10:0] lb_wa;
always @(posedge clk_sd)
begin
/* a word of a run */
    if (fbr_stb)
    begin
        lbuf[lb_wa] <= fb_q[11:0];
    end
    rd_q <= lbuf[rd_addr];
end

/* ---- line fetch and SDRAM requests (clk_sd); reads (the screen cannot wait) go first ---- */
/* next line to fetch, line on screen, next word of line fn, the buffer of this frame */
reg  [8:0]  fn, fd, fw;
reg  [1:0]  frb;
reg  [1:0]  nw_s1, nw_s2;
/* an access runs, it is a read, the FIFO's head */
reg         busy, is_rd, f_wait, f_has, stale;
reg  [1:0]  on_s;
wire        need = on_s[1] && fn < pic_lines && {1'b0, fn} <= {1'b0, fd} + FETCH_AHEAD;

/* the fetcher */
always @(posedge clk_sd or negedge rst_sd_n)
    if (!rst_sd_n)
    begin
        wt_d   <= 1'b0;
/* the FIFO's pointers */
        f_wp   <= 9'd0;
        f_rp   <= 9'd0;
/* nothing to fetch before the first frame start */
        fn     <= LINES_MAX;
        fd     <= 9'd0;
        fw     <= 9'd0;
/* the buffer on screen */
        frb    <= BUF_START_RD;
        rb     <= BUF_START_RD;
        nw_s1  <= 2'd1;
/* the newest buffer, synchronised */
        nw_s2  <= 2'd1;
/* no access running */
        busy   <= 1'b0;
        is_rd  <= 1'b0;
        f_wait <= 1'b0;
/* no pixel waiting */
        f_has  <= 1'b0;
        stale  <= 1'b0;
        on_s   <= 2'b00;
/* no request */
        lb_wa  <= 11'd0;
        fbr_req  <= 1'b0;
        fbr_addr <= 23'd0;
/* no write */
        fbw_req  <= 1'b0;
        fbw_addr <= 23'd0;
        fbw_data <= 16'd0;
    end
    else
    begin
/* the mode, synchronised */
        on_s  <= {on_s[0], on};
        wt_d  <= w_tgl;
/* a pixel enters the FIFO */
        if (w_tgl != wt_d)
        begin
            f_wp <= f_wp + 9'd1;
        end
/* the newest buffer, from the writer's clock */
        nw_s1 <= newest;
        nw_s2 <= nw_s1;

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

/* a screen frame starts: the newest complete picture, from its first line */
        if (frame_start)
        begin
            fn  <= 9'd0;
            fd  <= 9'd0;
/* from the first word */
            fw  <= 9'd0;
            if (nw_s1 == nw_s2)
            begin
                rb  <= nw_s2;
/* its buffer */
                frb <= nw_s2;
            end
/* a read still running belongs to the old frame */
            if (busy && is_rd)
            begin
                stale <= 1'b1;
            end
        end
        else if (line_done)
        begin
/* a line was shown: the next one may be fetched */
            fd <= fd + 9'd1;
        end

/* each word of a run goes to the next place of the line buffer */
        if (fbr_stb)
        begin
            lb_wa <= lb_wa + 11'd1;
        end

        if (!busy)
        begin
/* a run of a line's words is read */
            if (need && !frame_start)
            begin
                busy     <= 1'b1;
                is_rd    <= 1'b1;
/* the read request */
                fbr_req  <= 1'b1;
                fbr_addr <= {AREA_FB, frb, fn[7:0], fw, 1'b0};
                lb_wa    <= {fn[1:0], fw};
/* a fresh read */
                stale    <= 1'b0;
            end
/* a pixel from the FIFO is written */
            else if (f_has)
            begin
                busy     <= 1'b1;
                is_rd    <= 1'b0;
/* the write request */
                fbw_req  <= 1'b1;
                fbw_addr <= {AREA_FB, f_q[30:12], 1'b0};
                fbw_data <= {4'd0, f_q[11:0]};
/* taken out of the FIFO */
                f_has    <= 1'b0;
                f_rp     <= f_rp + 9'd1;
            end
        end
        else if (fbr_ack || fbw_ack)
        begin
/* the access is over */
            busy    <= 1'b0;
            fbr_req <= 1'b0;
            fbw_req <= 1'b0;
/* the next run */
            if (is_rd && !frame_start && !stale)
            begin
/* the last run of a line: the next line */
                if (fw == LINE_WORDS - RUN_WORDS)
                begin
                    fw <= 9'd0;
                    fn <= fn + 9'd1;
                end
                else
                begin
/* the next run of this line */
                    fw <= fw + RUN_WORDS;
                end
            end
        end
    end

/* the picture's size before the first one is stored */
initial
begin
    pic_lines = LINES_DEF;
    pic_h40   = 1'b1;
end

endmodule

/* other files keep the default net type */
`default_nettype wire
