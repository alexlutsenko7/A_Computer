/* tb_next_video -- LNext's video output (next_video.v) alone: a made-up picture in the Next's */
/* timing goes in (14 MHz: 912 pixel times per line, 311 lines), the VGA output is written as */
/* video.ppm (one frame, every clk28 a pixel, as a monitor would draw it from the syncs). */
/* The OSD is on, full screen, with a text in its first and last rows. Checks: lines per frame */
/* (622), pixel times per line (912), and that the input's colours come out twice (two output */
/* lines per input line; looked at left of the OSD). The OSD is for the eye: video.png. */
/* Then the screenshot grabber's side: lines are held in the buffer (two of the picture, one */
/* of the vertical blanking) and read pixel by pixel; the line's green must be the line's own, */
/* its red must step as the columns do, a second reading must give the same, the monitor must */
/* get black meanwhile, and the picture's place and the frame's lines must be reported. */
/* RESULT: PASS / FAIL. */
`timescale 1ns/1ps

module tb_next_video;

/* half period of clk28 */
localparam realtime H28 = 17.857;
/* the input's timing in pixel times of 14 MHz and in lines */
localparam integer H_TOTAL = 912;
localparam integer HS_LEN = 66;
localparam integer H_FIRST = 190;
localparam integer H_ACT = 640;
localparam integer V_TOTAL = 311;
localparam integer V_FIRST = 30;
localparam integer V_ACT = 256;
localparam integer VS_LEN = 4;
/* the picture file: pixel times and lines of a frame */
localparam integer PIC_W = 912;
localparam integer PIC_H = 640;
/* frames to run before the one that is written (the output measures the picture first) */
localparam integer FRAMES = 3;
/* OSD: its text memory's size, a row's characters */
localparam integer TXT_LEN = 768;
localparam integer ROW_LEN = 32;
/* 4-bit colour to 8 bits */
localparam integer C4_TO_8 = 17;
/* the columns of the picture looked at for the doubling: left of the OSD (its lines differ) */
localparam integer CHECK_FIRST = 4;
localparam integer CHECK_END = 60;
/* the grabber's test: lines taken, pixels read of each, the columns' step of one red level, */
/* clocks from a pixel's place to its colour, clocks the black picture is looked at */
localparam integer G_LINE_A = 37;
localparam integer G_LINE_B = 200;
localparam integer G_LINE_VBL = 10;
localparam integer G_PIXELS = 16;
localparam integer G_STEP = 32;
localparam integer G_RD_CLOCKS = 3;
localparam integer G_BLACK_CLOCKS = 4000;
localparam integer RED_LEVELS = 8;

reg clk28 = 0, clk14 = 0, clk7 = 0;
/* all clocks from one process: their edges fall together as from one PLL */
integer phase = 0;
always #(H28)
begin
    clk28 = ~clk28;
    if (clk28)
    begin
        phase = phase + 1;
        clk14 = phase[0];
    end
end

/* the input: a colour that depends on the position, so every line and column is known */
integer hx = 0, vy = 0;
reg  [8:0] rgb;
reg        hs_n, vs_n, hb_n, vb_n;
always @(posedge clk14)
begin
    if (hx == H_TOTAL - 1)
    begin
        hx <= 0;
        vy <= vy == V_TOTAL - 1 ? 0 : vy + 1;
    end
    else
    begin
        hx <= hx + 1;
    end
    hs_n <= !(hx < HS_LEN);
    vs_n <= !(vy < VS_LEN);
    hb_n <= hx >= H_FIRST && hx < H_FIRST + H_ACT;
    vb_n <= vy >= V_FIRST && vy < V_FIRST + V_ACT;
/* red from the column, green from the line, blue a frame around the picture */
    rgb  <= {hx[7:5], vy[5:3], (hx == H_FIRST || hx == H_FIRST + H_ACT - 1 || vy == V_FIRST || vy == V_FIRST + V_ACT - 1) ? 3'd7 : 3'd0};
end

/* OSD text: written through the port as the loader does */
reg        osd_clk = 0, osd_we = 0;
reg  [9:0] osd_addr = 0;
reg  [7:0] osd_data = 0;
always #9 osd_clk = ~osd_clk;

wire [3:0] vr, vg, vb;
wire       vhs, vvs;
/* the OSD on; the grabber's wires */
reg        osd_on = 1;
reg        g_on = 0, g_req = 0, g_arm = 0;
reg  [9:0] g_line = 0, g_x = 0;
wire [8:0] g_q;
wire       g_held, g_vbl;
wire [9:0] g_first, g_end, g_lines;
/* what was read of a line, twice */
reg  [8:0] g_got [0:G_PIXELS-1];
reg  [8:0] g_again;
integer    g_bad = 0, gi;

/* take a line and look at its pixels */
task grab_line(input integer line, input bit blank);
begin
    @(posedge clk28);
    g_line = line; g_arm = 1; g_req = ~g_req;
/* the line before is let go first (the ESP32's next command comes far later than that) */
    repeat (G_RD_CLOCKS) @(posedge clk28);
    wait (g_held);
    if (g_vbl !== blank)
    begin
        g_bad = g_bad + 1;
    end
/* pixels a red step apart, from inside the picture */
    for (gi = 0; gi < G_PIXELS; gi++)
    begin
        @(posedge clk28);
        g_x = g_first + 4 + gi * G_STEP;
        repeat (G_RD_CLOCKS) @(posedge clk28);
        g_got[gi] = g_q;
    end
/* a picture line: its own green, red one level up per step */
    for (gi = 0; gi < G_PIXELS && !blank; gi++)
    begin
        if (g_got[gi][5:3] !== line[5:3])
        begin
            g_bad = g_bad + 1;
        end
        if (gi > 0 && g_got[gi][8:6] !== ((g_got[gi - 1][8:6] + 1) % RED_LEVELS))
        begin
            g_bad = g_bad + 1;
        end
    end
/* still the same a few lines later */
    repeat (4 * H_TOTAL) @(posedge clk28);
    for (gi = 0; gi < G_PIXELS; gi++)
    begin
        @(posedge clk28);
        g_x = g_first + 4 + gi * G_STEP;
        repeat (G_RD_CLOCKS) @(posedge clk28);
        g_again = g_q;
        if (g_again !== g_got[gi])
        begin
            g_bad = g_bad + 1;
        end
    end
end
endtask

next_video #(.FONT_HEX("../../../AMenu/ep4_ce15/rtl/menu_font.hex")) dut (
    .clk14(clk14), .rgb(rgb), .hs_n(hs_n), .vs_n(vs_n), .hb_n(hb_n), .vb_n(vb_n),
    .clk28(clk28),
    .osd_wclk(osd_clk), .osd_we(osd_we), .osd_waddr(osd_addr), .osd_wdata(osd_data),
    .osd_on(osd_on), .osd_full(1'b1),
    .g_on(g_on), .g_req(g_req), .g_arm(g_arm), .g_line(g_line), .g_x(g_x), .g_q(g_q),
    .g_held(g_held), .g_vbl(g_vbl), .g_first(g_first), .g_end(g_end), .g_lines(g_lines),
    .vga_r(vr), .vga_g(vg), .vga_b(vb), .vga_hs(vhs), .vga_vs(vvs)
);

/* the output as a monitor sees it: position from the syncs' falling edges */
integer ox = 0, oy = 0, frame = 0, lines = 0, pixels = 0, errors = 0;
integer file;
reg     hs_q = 1, vs_q = 1;
reg [11:0] pic [0:PIC_H-1][0:PIC_W-1];
integer px, py;
reg [11:0] first_line [0:PIC_W-1];
integer    twice_bad = 0;

always @(posedge clk28)
begin
    hs_q <= vhs;
    vs_q <= vvs;
    if (hs_q && !vhs)
    begin
        pixels <= ox + 1;
        ox <= 0;
        oy <= oy + 1;
    end
    else
    begin
        ox <= ox + 1;
    end
    if (vs_q && !vvs)
    begin
        lines <= oy;
        oy <= 0;
        frame <= frame + 1;
    end
    if (frame == FRAMES && ox < PIC_W && oy < PIC_H)
    begin
        pic[oy][ox] = {vr, vg, vb};
    end
end

integer i;
string  text;
initial
begin
/* an empty picture */
    for (py = 0; py < PIC_H; py++)
    begin
        for (px = 0; px < PIC_W; px++)
        begin
            pic[py][px] = 12'd0;
        end
    end
/* the OSD's text: spaces, a line at the top and one at the bottom */
    for (i = 0; i < TXT_LEN; i++)
    begin
        @(posedge osd_clk);
        osd_we = 1; osd_addr = i; osd_data = 8'h20;
    end
    text = " LNext OSD test: first row";
    for (i = 0; i < text.len(); i++)
    begin
        @(posedge osd_clk);
        osd_addr = i; osd_data = text[i];
    end
    text = " last row";
    for (i = 0; i < text.len(); i++)
    begin
        @(posedge osd_clk);
        osd_addr = TXT_LEN - ROW_LEN + i; osd_data = text[i] | 8'h80;
    end
    @(posedge osd_clk);
    osd_we = 0;
    wait (frame == FRAMES + 1);
/* the picture file */
    file = $fopen("video.ppm", "w");
    $fwrite(file, "P3\n%0d %0d\n255\n", PIC_W, PIC_H);
    for (py = 0; py < PIC_H; py++)
    begin
        for (px = 0; px < PIC_W; px++)
        begin
            $fwrite(file, "%0d %0d %0d ", pic[py][px][11:8] * C4_TO_8, pic[py][px][7:4] * C4_TO_8, pic[py][px][3:0] * C4_TO_8);
        end
        $fwrite(file, "\n");
    end
    $fclose(file);
/* every picture line twice: the lines 2n and 2n+1 below the top of the frame are equal */
    for (py = 2 * V_FIRST + 8; py < 2 * (V_FIRST + V_ACT) - 8; py = py + 2)
    begin
        for (px = H_FIRST + CHECK_FIRST; px < H_FIRST + CHECK_END; px++)
        begin
            if (pic[py][px] !== pic[py + 1][px] && pic[py][px] !== pic[py - 1][px])
            begin
                twice_bad = twice_bad + 1;
            end
        end
    end
    $display("lines per frame %0d, pixel times per line %0d, pixels not doubled %0d", lines, pixels, twice_bad);
    if (lines != 2 * V_TOTAL || pixels != H_TOTAL || twice_bad != 0)
    begin
        errors = errors + 1;
    end
/* the grabber: the OSD off, so only the picture could light the monitor */
    osd_on = 0;
    @(posedge clk28);
    g_on = 1; g_arm = 0; g_req = ~g_req;
    grab_line(G_LINE_A, 0);
    grab_line(G_LINE_B, 0);
    grab_line(G_LINE_VBL, 1);
/* black on the monitor all the while */
    for (i = 0; i < G_BLACK_CLOCKS; i++)
    begin
        @(posedge clk28);
        if ({vr, vg, vb} !== 12'd0)
        begin
            g_bad = g_bad + 1;
        end
    end
/* let go: the buffer is written again */
    g_on = 0; g_arm = 0; g_req = ~g_req;
    repeat (2 * H_TOTAL) @(posedge clk28);
    if (g_held !== 1'b0)
    begin
        g_bad = g_bad + 1;
    end
    $display("grabber: picture from %0d to %0d, %0d lines, errors %0d", g_first, g_end, g_lines, g_bad);
    if (g_bad != 0 || (g_end - g_first) != H_ACT || g_lines != V_TOTAL)
    begin
        errors = errors + 1;
    end
    $display("RESULT: %s", errors == 0 ? "PASS" : "FAIL");
    $finish;
end

endmodule
