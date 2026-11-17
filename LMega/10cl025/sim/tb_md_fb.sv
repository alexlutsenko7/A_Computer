/* tb_md_fb -- LMega's third video mode: a 50 Hz picture through the frame buffer onto a 60 Hz screen */
/* */
/* md_fb + md_mem (with the SDRAM controller and the SDRAM model) + md_video in frame buffer mode, */
/* fed by a made-up 50 Hz VDP timing: lines of 3,420 master clocks, 313 lines, 240 picture lines. */
/* Every pixel's colour is its column (red = column / 16, green = column % 16) and its line (blue). */
/* Checked on the VGA side: lines of 3,412 clk_sd, 525 lines between two vertical syncs (60 Hz), */
/* 480 picture lines, 320 colour steps in a picture line, the colour in the middle of a line, and */
/* no timing error in the SDRAM model. Prints the measurements and RESULT: PASS / FAIL; */
/* ./run_fb_sim.sh */
`timescale 1ns/1ps

module tb_md_fb;

/* clk_sd half period (107.386 MHz) */
localparam realtime HSD = 4.6561;
/* the stand-in VDP's timing, in master clocks and lines */
localparam integer LINE_CLKS = 3420;
localparam integer PIX_CLKS = 8;
localparam integer PIXELS = 320;
/* the horizontal sync's place and length */
localparam integer HS_AT = 2800;
localparam integer HS_LEN = 260;
localparam integer LINES = 313;
/* the picture's lines, the vertical sync's place and length */
localparam integer PIC_LINES = 240;
localparam integer VS_AT = 270;
localparam integer VS_LEN = 3;
/* what the output must show */
localparam integer OUT_LINE_CLKS = 3412;
localparam integer OUT_LINES = 525;
localparam integer COLOUR_STEPS = 319;
/* every line is shown twice; lines and colour steps that may be missing or extra at the edges */
localparam integer DOUBLE = 2;
localparam integer EDGE = 2;
/* frames simulated, the frame that is measured */
localparam integer FRAMES = 4;
localparam integer MEASURED = 3;
/* colour fields */
localparam integer NIBBLE = 16;
/* SDRAM: pin delays, the clock's shift, both data masks high */
localparam real T_CK  = 2 * HSD;
localparam real TCO   = 4.0;
localparam real TBACK = 0.5;
/* the SDRAM clock's shift */
localparam real SD_SHIFT = 1.339;
localparam integer DQM_OFF = 3;
/* the reset's end; the clock in the middle of a line and the red and green it must show there (column 160) */
localparam integer RST_NS = 300;
localparam integer MID_CLK = 1983;
localparam [7:0] MID_RG = 8'hA0;

/* the clocks */
reg clk_sd = 0, mclk = 0;
always #(HSD)
begin
/* the faster clock */
    clk_sd = ~clk_sd;
/* the master clock: every second edge */
    if (clk_sd)
    begin
        mclk = ~mclk;
    end
end

/* the stand-in VDP */
integer hcnt = 0, vcnt = 0, frame = 0;
wire       in_pic_x = hcnt < PIXELS * PIX_CLKS;
wire       in_pic_y = vcnt < PIC_LINES;
/* a pixel every eight clocks; the two syncs */
wire       ce_pix = hcnt % PIX_CLKS == PIX_CLKS - 1;
wire       hs = hcnt >= HS_AT && hcnt < HS_AT + HS_LEN;
wire       vs = vcnt >= VS_AT && vcnt < VS_AT + VS_LEN;
/* the pixel's column */
wire [8:0] col = hcnt / PIX_CLKS;
always @(posedge mclk)
begin
    if (hcnt == LINE_CLKS - 1)
    begin
/* the line is over */
        hcnt <= 0;
/* the next line, the next frame */
        if (vcnt == LINES - 1)
        begin
            vcnt  <= 0;
            frame <= frame + 1;
        end
        else
        begin
/* the next line */
            vcnt <= vcnt + 1;
        end
    end
    else
    begin
        hcnt <= hcnt + 1;
    end
end

reg rst_n = 0;
/* the reset */
initial #RST_NS rst_n = 1;

/* the frame buffer, the memory, the video output */
wire        fbr_req, fbr_ack, fbr_stb, fbw_req, fbw_ack, fb_frame, fb_line, fb_h40;
wire [22:0] fbr_addr, fbw_addr;
wire [15:0] fbw_data, fb_sd_q;
/* the line buffer's port, the picture's size */
wire [10:0] fb_addr;
wire [11:0] fb_px;
wire [8:0]  fb_lines;
/* SDRAM pins */
wire        cke, cs_n, ras_n, cas_n, we_n, dq_oe;
wire [1:0]  ba, dqm;
wire [12:0] a;
/* data out and in */
wire [15:0] dq_o;
reg  [15:0] dq_i;

md_fb u_fb (
    .mclk(mclk), .ce_pix(ce_pix), .hbl(!in_pic_x), .vbl(!in_pic_y),
    .r(col / NIBBLE), .g(col % NIBBLE), .b(vcnt % NIBBLE), .h40(1'b1), .on(1'b1),
    .clk_sd(clk_sd), .rst_sd_n(rst_n),
    .fbr_req(fbr_req), .fbr_addr(fbr_addr), .fbr_ack(fbr_ack), .fbr_stb(fbr_stb),
    .fbw_req(fbw_req), .fbw_addr(fbw_addr), .fbw_data(fbw_data), .fbw_ack(fbw_ack), .fb_q(fb_sd_q),
    .frame_start(fb_frame), .line_done(fb_line), .rd_addr(fb_addr), .rd_q(fb_px),
    .pic_lines(fb_lines), .pic_h40(fb_h40)
);

/* the memory with the SDRAM controller */
md_mem u_mem (
    .clk_sd(clk_sd), .rst_sd_n(rst_n),
    .mem_req(1'b0), .mem_ack(), .mem_we(1'b0), .mem_addr(23'd0), .mem_be(2'b00), .mem_wdata(16'd0), .mem_rdata(),
    .vram_req(1'b0), .vram_ack(), .vram_we(1'b0), .vram_a(15'd0), .vram_d(16'd0), .vram_q(),
    .vram_u_n(1'b1), .vram_l_n(1'b1), .vram32_req(1'b0), .vram32_ack(), .vram32_a(15'd0), .vram32_q(),
    .fbr_req(fbr_req), .fbr_addr(fbr_addr), .fbr_ack(fbr_ack), .fbr_stb(fbr_stb),
    .fbw_req(fbw_req), .fbw_addr(fbw_addr), .fbw_data(fbw_data), .fbw_ack(fbw_ack), .fb_q(fb_sd_q),
    .x_req(1'b0), .x_we(1'b0), .x_addr(23'd0), .x_din(8'd0), .x_ack(), .x_dout(),
    .clr_go(1'b0), .clr_done(),
    .sd_cke(cke), .sd_cs_n(cs_n), .sd_ras_n(ras_n), .sd_cas_n(cas_n), .sd_we_n(we_n),
    .sd_ba(ba), .sd_a(a), .sd_dqm(dqm), .sd_dq_o(dq_o), .sd_dq_oe(dq_oe), .sd_dq_i(dq_i)
);

/* pins as seen by the SDRAM (transport delays, as the other testbenches) */
reg         m_clk = 0, m_cke = 0, m_cs_n = 1, m_ras_n = 1, m_cas_n = 1, m_we_n = 1;
reg  [1:0]  m_ba = 0, m_dqm = DQM_OFF;
reg  [12:0] m_a = 0;
/* the data pins */
reg  [15:0] m_dq_drv = 'z;
wire [15:0] m_dq;
always @(clk_sd) m_clk <= #(TCO + SD_SHIFT) ~clk_sd;
/* commands and address, delayed */
always @(cke, cs_n, ras_n, cas_n, we_n, ba, a, dqm)
    {m_cke, m_cs_n, m_ras_n, m_cas_n, m_we_n, m_ba, m_a, m_dqm}
       <= #(TCO) {cke, cs_n, ras_n, cas_n, we_n, ba, a, dqm};
/* the data bus, delayed */
always @(dq_oe, dq_o) m_dq_drv <= #(TCO) (dq_oe ? dq_o : 16'hzzzz);
assign m_dq = m_dq_drv;
always @(m_dq) dq_i <= #(TBACK) m_dq;

/* the SDRAM */
sdram_model #(.T_CK(T_CK)) u_sdram (
    .clk(m_clk), .cke(m_cke), .cs_n(m_cs_n), .ras_n(m_ras_n), .cas_n(m_cas_n), .we_n(m_we_n),
    .ba(m_ba), .a(m_a), .dqm(m_dqm), .dq(m_dq)
);

/* the video output in frame buffer mode (its VDP side is not used for the picture) */
wire [3:0] vga_r, vga_g, vga_b;
wire       vga_hs, vga_vs;
md_video #(.FONT_HEX("../../../AMenu/ep4_ce15/rtl/menu_font.hex")) u_video (
    .mclk(mclk), .ce_pix(ce_pix), .hs(hs), .vs(vs), .hbl(!in_pic_x), .vbl(!in_pic_y),
    .r(4'd0), .g(4'd0), .b(4'd0), .h40(1'b1),
    .clk_sd(clk_sd), .fb_mode(1'b1), .fb_q(fb_px), .fb_lines(fb_lines), .fb_h40(fb_h40),
    .fb_addr(fb_addr), .fb_frame(fb_frame), .fb_line(fb_line),
    .osd_wclk(mclk), .osd_we(1'b0), .osd_waddr(10'd0), .osd_wdata(8'd0),
    .osd_on(1'b0), .osd_full(1'b0),
    .vga_r(vga_r), .vga_g(vga_g), .vga_b(vga_b), .vga_hs(vga_hs), .vga_vs(vga_vs)
);

/* measurements on the VGA side */
integer t = 0, hs_last = 0, hs_period = 0, hs_bad = 0, lines = 0, lines_frame = 0, steps = 0, steps_max = 0;
integer lit_lines = 0, lit_frame = 0, lit_now = 0, mid_ok = 0, mid_bad = 0;
reg        hs_d = 1, vs_d = 1;
/* the colour seen last */
reg [7:0]  rg_d = 0;
always @(posedge clk_sd)
begin
    t    <= t + 1;
/* the syncs as seen last */
    hs_d <= vga_hs;
    vs_d <= vga_vs;
    rg_d <= {vga_r, vga_g};
/* the colour in the middle of a picture line of the measured frame */
    if (frame == MEASURED && t - hs_last == MID_CLK && {vga_r, vga_g, vga_b} != 12'd0)
    begin
        if ({vga_r, vga_g} == MID_RG)
        begin
            mid_ok <= mid_ok + 1;
        end
        else
        begin
/* a wrong colour */
            mid_bad <= mid_bad + 1;
        end
    end
/* a line starts with the sync's falling edge */
    if (hs_d && !vga_hs)
    begin
        hs_period <= t - hs_last;
        hs_last   <= t;
/* one more line */
        lines     <= lines + 1;
/* lines whose period is wrong, in the measured frame */
        if (frame == MEASURED && t - hs_last != OUT_LINE_CLKS)
        begin
            hs_bad <= hs_bad + 1;
        end
/* the picture lines, and the colour changes of the widest one */
        if (lit_now != 0)
        begin
            lit_lines <= lit_lines + 1;
        end
        if (steps > steps_max)
        begin
/* the widest line so far */
            steps_max <= steps;
        end
        steps   <= 0;
        lit_now <= 0;
    end
    else
    begin
/* a colour change */
        if ({vga_r, vga_g} != rg_d)
        begin
            steps <= steps + 1;
        end
        if ({vga_r, vga_g, vga_b} != 12'd0)
        begin
/* the line shows something */
            lit_now <= 1;
        end
    end
/* a frame starts with the vertical sync's falling edge */
    if (vs_d && !vga_vs)
    begin
        lines_frame <= lines;
        lit_frame   <= lit_lines;
/* the next frame's counts */
        lines       <= 0;
        lit_lines   <= 0;
    end
end

initial
begin
/* four frames of the stand-in VDP, then the verdict */
    wait (frame == FRAMES);
    $display("line period %0d clk_sd (wanted %0d), wrong periods in a frame %0d", hs_period, OUT_LINE_CLKS, hs_bad);
    $display("lines per frame %0d (wanted %0d), picture lines %0d (wanted %0d)", lines_frame, OUT_LINES, lit_frame,
             DOUBLE * PIC_LINES);
/* the picture's width, its contents, the memory's timing */
    $display("colour changes in a picture line %0d (wanted %0d or one more for the edge)", steps_max, COLOUR_STEPS);
    $display("middle of the lines: right colour %0d times, wrong %0d times; SDRAM errors %0d", mid_ok, mid_bad,
             u_sdram.errors);
    $display("RESULT: %s", (hs_period == OUT_LINE_CLKS && hs_bad == 0 && lines_frame == OUT_LINES &&
                            lit_frame >= DOUBLE * PIC_LINES - EDGE && lit_frame <= DOUBLE * PIC_LINES &&
                            steps_max >= COLOUR_STEPS && steps_max <= COLOUR_STEPS + EDGE &&
                            mid_ok > PIC_LINES && mid_bad == 0 && u_sdram.errors == 0) ? "PASS" : "FAIL");
/* the end */
    $finish;
end

endmodule
