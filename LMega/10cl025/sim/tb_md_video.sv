/* tb_md_video -- LMega's video output (md_video) alone, fed with a made-up VDP timing */
/* */
/* The stand-in VDP: lines of 3,420 master clocks (320 pixels of 8 clocks, the rest blanking with a */
/* sync pulse), 262 lines (224 picture lines, a vertical sync of 3 lines). Every pixel's colour is */
/* its column (red = column / 16, green = column % 16) and its line (blue = line % 16). */
/* Checked on the VGA side: the horizontal sync's period (3,420 clk_sd), two output lines per */
/* VDP line, 524 lines between two vertical syncs, and that the picture's columns come out in */
/* order, two output pixels each (the colour changes 319 times in a picture line). */
/* With +define+INTERLACE the stand-in VDP is in an interlace mode: the vertical sync of every */
/* second field comes half a line late, as the real VDP's. The output frames must all keep 524 */
/* lines (a monitor that takes 60 Hz only shows nothing if their length alternates). */
/* Prints the measurements and RESULT: PASS / FAIL; ./run_video_sim.sh */
`timescale 1ns/1ps

module tb_md_video;

/* clk_sd half period (107.386 MHz) */
localparam realtime HSD = 4.6561;
/* the stand-in VDP's timing, in master clocks and lines */
localparam integer LINE_CLKS = 3420;
localparam integer PIX_CLKS = 8;
localparam integer PIXELS = 320;
/* the horizontal sync's place and length */
localparam integer HS_AT = 2800;
localparam integer HS_LEN = 260;
localparam integer LINES = 262;
/* the picture's lines, the vertical sync's place and length */
localparam integer PIC_LINES = 224;
localparam integer VS_AT = 232;
localparam integer VS_LEN = 3;
/* what the output must show */
localparam integer OUT_LINE_CLKS = 3420;
localparam integer OUT_LINES = 524;
localparam integer COLOUR_STEPS = 319;
/* every line is shown twice; lines and colour steps that may be missing or extra at the edges */
localparam integer DOUBLE = 2;
localparam integer EDGE = 2;
/* frames simulated, the frame that is measured */
localparam integer FRAMES = 6;
localparam integer MEASURED = 2;
/* the vertical sync's delay in the fields that have one: half a line */
`ifdef INTERLACE
localparam integer VS_DELAY = 1710;
`else
localparam integer VS_DELAY = 0;
`endif
/* a number no frame has: the start of the search for the shortest frame */
localparam integer LINES_HUGE = 9999;
/* colour fields */
localparam integer NIBBLE = 16;

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
/* the vertical sync starts and ends with a horizontal one, as the VDP's; in every second field of */
/* an interlace mode both come half a line later */
wire [31:0] vpos = vcnt * LINE_CLKS + hcnt;
wire [31:0] vs_beg = VS_AT * LINE_CLKS + HS_AT + (frame % DOUBLE == 0 ? VS_DELAY : 0);
wire       vs = vpos >= vs_beg && vpos < vs_beg + VS_LEN * LINE_CLKS;
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

wire [3:0] vga_r, vga_g, vga_b;
/* the VGA syncs */
wire       vga_hs, vga_vs;
md_video #(.FONT_HEX("../../../AMenu/ep4_ce15/rtl/menu_font.hex")) u_video (
    .mclk(mclk), .ce_pix(ce_pix), .hs(hs), .vs(vs), .hbl(!in_pic_x), .vbl(!in_pic_y),
    .r(col / NIBBLE), .g(col % NIBBLE), .b(vcnt % NIBBLE), .h40(1'b1),
    .clk_sd(clk_sd), .fb_mode(1'b0), .fb_q(12'd0), .fb_lines(9'd224), .fb_h40(1'b1),
    .fb_addr(), .fb_frame(), .fb_line(), .osd_wclk(mclk), .osd_we(1'b0), .osd_waddr(10'd0), .osd_wdata(8'd0),
    .osd_on(1'b0), .osd_full(1'b0),
    .vga_r(vga_r), .vga_g(vga_g), .vga_b(vga_b), .vga_hs(vga_hs), .vga_vs(vga_vs)
);

/* measurements on the VGA side */
integer t = 0, hs_last = 0, hs_period = 0, hs_bad = 0, lines = 0, lines_frame = 0, steps = 0, steps_max = 0;
integer lit_lines = 0, lit_frame = 0, lit_now = 0;
/* the shortest and the longest frame seen, the frames seen */
integer lines_min = LINES_HUGE, lines_max = 0, frames_seen = 0;
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
/* the first count is not a whole frame */
        frames_seen <= frames_seen + 1;
        if (frames_seen != 0)
        begin
/* the shortest frame */
            if (lines < lines_min)
            begin
                lines_min <= lines;
            end
/* the longest frame */
            if (lines > lines_max)
            begin
                lines_max <= lines;
            end
        end
/* the next frame's counts */
        lines       <= 0;
        lit_lines   <= 0;
    end
end

initial
begin
/* some frames, then the verdict */
    wait (frame == FRAMES);
    $display("line period %0d clk_sd (wanted %0d), wrong periods in a frame %0d", hs_period, OUT_LINE_CLKS, hs_bad);
    $display("lines per frame %0d (wanted %0d), picture lines %0d (wanted %0d)", lines_frame, OUT_LINES, lit_frame,
             DOUBLE * PIC_LINES);
/* every frame must have the same length */
    $display("shortest / longest frame %0d / %0d lines (wanted %0d / %0d)", lines_min, lines_max, OUT_LINES, OUT_LINES);
/* the picture's width in colour steps */
    $display("colour changes in a picture line %0d (wanted %0d or one more for the edge)", steps_max, COLOUR_STEPS);
    $display("RESULT: %s", (hs_period == OUT_LINE_CLKS && hs_bad == 0 && lines_frame == OUT_LINES &&
                            lines_min == OUT_LINES && lines_max == OUT_LINES &&
                            lit_frame >= DOUBLE * PIC_LINES - EDGE && lit_frame <= DOUBLE * PIC_LINES &&
                            steps_max >= COLOUR_STEPS && steps_max <= COLOUR_STEPS + EDGE) ? "PASS" : "FAIL");
    $finish;
end

endmodule
