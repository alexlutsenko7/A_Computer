/* tb_vga_test -- checks VGA_TEST: per-mode line/frame totals, sync widths and */
/* pixel clock; mode changes by S1 and KEY1; bar layout in both modes. */
/* vga_pll and vga_clkmux are replaced by behavioural models. */
`timescale 1ns/1ps

module vga_pll (input wire inclk0, output reg c0 = 0, output reg c1 = 0, output wire locked);

/* half a period of the 25 MHz clock, ns */
localparam real C0_HALF = 20.000;
/* half a period of the 27 MHz clock, ns */
localparam real C1_HALF = 18.519;
/* 25 MHz */
    always #C0_HALF c0 = ~c0;
/* 27 MHz */
    always #C1_HALF c1 = ~c1;
    assign locked = 1'b1;
endmodule

/* Clock control block model: select mux, enable latched on the falling edge */
module vga_clkmux (input wire clk0, input wire clk1, input wire sel, input wire ena, output wire outclk);
    wire src = sel ? clk1 : clk0;
    reg  ena_l = 0;
/* the enable changes only while the clock is low */
    always @(negedge src) ena_l <= ena;
    assign outclk = src & ena_l;
endmodule

/* the testbench */
module tb_vga_test;

/* half a period of the 50 MHz clock, ns */
localparam integer CLK50_HALF = 10;
/* horizontal sync width at 50 Hz */
localparam integer HS_50 = 64;
/* horizontal sync width at 60 Hz */
localparam integer HS_60 = 96;
/* the reset ends after 200 ns */
localparam integer RST_NS = 200;
/* time the key is held, ns */
localparam integer KEY_HOLD_NS = 15_000_000;
/* milliseconds in a second */
localparam real MS_PER_S = 1000.0;
/* lines per frame at 60 Hz */
localparam integer LINES_60 = 525;
/* pixels per line at 60 Hz */
localparam integer LEN_60 = 800;
/* vertical sync lines at 60 Hz */
localparam integer VS_60 = 2;
/* shortest pixel period accepted at 60 Hz, ns */
localparam real PER_60_MIN = 39.9;
/* longest pixel period accepted at 60 Hz, ns */
localparam real PER_60_MAX = 40.1;
/* lines per frame at 50 Hz */
localparam integer LINES_50 = 625;
/* pixels per line at 50 Hz */
localparam integer LEN_50 = 864;
/* vertical sync lines at 50 Hz */
localparam integer VS_50 = 5;
/* shortest pixel period accepted at 50 Hz, ns */
localparam real PER_50_MIN = 37.0;
/* longest pixel period accepted at 50 Hz, ns */
localparam real PER_50_MAX = 37.1;
/* checks that must have been made */
localparam integer CHECKS_MIN = 8;
    reg clk50 = 0, rst_n = 0, sw = 0, key1 = 1;
    always #CLK50_HALF clk50 = ~clk50;

/* the design under test */
    wire r, rl, g, gl, b, bl, hs, vs, led;
    VGA_TEST dut (.CLOCK_50(clk50), .RESET_N(rst_n), .SW_50_60(sw), .KEY1(key1), .GND_TIE(2'b00), .LEDR(led),
                  .VGA_R(r), .VGA_R_LOW(rl), .VGA_G(g), .VGA_G_LOW(gl), .VGA_B(b), .VGA_B_LOW(bl),
                  .VGA_HSYNC(hs), .VGA_VSYNC(vs));
    wire pclk = dut.clk;

/* Frame statistics, counted in pixel clocks; a frame during which the */
/* video logic was in reset (mode change) is marked and not checked. */
    integer hcnt = 0, hlow = 0, lines = 0, vlow = 0, line_len = 0, line_hs = 0, hs_bad = 0;
    reg     hs_d = 1, vs_d = 1, was_reset = 1;
    realtime t_last = 0, period = 0;
/* per frame: lines, line length, vsync lines, bad hsyncs, pixel period, reset seen */
    integer nf = 0, f_lines [0:63], f_len [0:63], f_vs [0:63], f_hsbad [0:63];
    real    f_period [0:63];
    reg     f_reset [0:63];

/* every pixel clock */
    always @(posedge pclk)
    begin
        period = $realtime - t_last;
        t_last = $realtime;
/* pixels of the line; sync low */
        hcnt <= hcnt + 1;
        if (!hs)
        begin
            hlow <= hlow + 1;
        end
/* line start */
        if (hs_d && !hs)
        begin
            line_len = hcnt;
            line_hs = hlow;
/* the next line */
            hcnt <= 1;
            hlow <= 1;
            lines <= lines + 1;
/* a line with vsync low */
            if (!vs)
            begin
                vlow <= vlow + 1;
            end
/* the hsync's length must fit the mode */
            if (line_hs != 0 && line_hs != (dut.sel ? HS_50 : HS_60))
            begin
                hs_bad <= hs_bad + 1;
            end
/* frame start */
            if (vs_d && !vs)
            begin
                f_lines[nf] = lines;
                f_len[nf] = line_len;
/* vsync lines, bad hsyncs, the pixel period */
                f_vs[nf] = vlow;
                f_hsbad[nf] = hs_bad;
                f_period[nf] = period;
/* marked; the next frame */
                f_reset[nf] = was_reset;
                nf <= nf + 1;
                lines <= 1;
/* counted from 1 again */
                vlow <= 1;
                hs_bad <= 0;
                was_reset = 0;
            end
        end
/* the syncs one clock ago */
        hs_d <= hs;
        vs_d <= vs;
    end
/* a reset of the video logic marks the frame */
    always @(negedge dut.rst_n) was_reset = 1;

/* Bar layout on active line 100 of the current mode */
    task automatic check_bars(input integer w);
        reg [5:0] c, prev;
        integer run, n, i;
/* the runs and their colours */
        integer runs [0:31];
        reg [5:0] cols [0:31];
        begin
            wait (dut.u_timing.active && dut.u_timing.y == 100 && dut.u_timing.x == 0);
/* from the first pixel of line 100 */
            @(posedge pclk);
            n = 0;
            run = 0;
/* pixel by pixel */
            prev = 6'h3f;
            for (i = 0; i < w; i++)
            begin
                #1 c = {r, rl, g, gl, b, bl};
/* the colour changes: the run is kept */
                if (i != 0 && c != prev)
                begin
                    runs[n] = run;
                    cols[n] = prev;
/* a new run */
                    n++;
                    run = 0;
                end
/* this pixel */
                prev = c;
                run++;
                @(posedge pclk);
            end
/* the last run */
            runs[n] = run;
            cols[n] = prev;
            n++;
/* printed */
            $write("bars %0d px (RrGgBb:width):", w);
            for (i = 0; i < n; i++)
            begin
                $write(" %b:%0d", cols[i], runs[i]);
            end
/* the end of the line */
            $display("");
        end
    endtask

/* the test sequence */
    integer f, errors = 0, checked = 0;
    initial
    begin
        #RST_NS rst_n = 1;
/* the bars at 640 pixels; three frames */
        check_bars(640);
        wait (nf == 3);
/* S1 -> 50 Hz */
        sw = 1;
        wait (nf == 6);
/* the bars at 720 pixels */
        check_bars(720);
        wait (nf == 8);
/* KEY1 -> 60 Hz again */
        key1 = 0;
        #KEY_HOLD_NS key1 = 1;
        wait (nf == 12);
/* every frame: what was measured */
        for (f = 1; f < nf; f++)
        begin
            $display("frame %2d: %0d lines x %0d px, vsync %0d lines, pclk %.3f MHz, %.3f Hz%s", f, f_lines[f], f_len[f],
                     f_vs[f], MS_PER_S / f_period[f], 1.0e9 / (f_lines[f] * f_len[f] * f_period[f]),
                     f_reset[f] ? "  (mode change, not checked)" : "");
/* frames not marked must have the right format */
            if (!f_reset[f])
            begin
                checked++;
                if (!((f_lines[f] == LINES_60 && f_len[f] == LEN_60 && f_vs[f] == VS_60 && f_period[f] > PER_60_MIN && f_period[f] < PER_60_MAX) ||
                      (f_lines[f] == LINES_50 && f_len[f] == LEN_50 && f_vs[f] == VS_50 && f_period[f] > PER_50_MIN && f_period[f] < PER_50_MAX)) ||
                    f_hsbad[f] != 0)
                begin
/* malformed */
                    $display("ERROR frame %0d malformed", f);
                    errors++;
                end
            end
        end
/* the verdict */
        if (errors || checked < CHECKS_MIN)
        begin
            $display("FAIL (%0d errors, %0d frames checked)", errors, checked);
        end
        else
        begin
            $display("PASS (%0d frames checked)", checked);
        end
/* the end */
        $finish;
    end
endmodule
