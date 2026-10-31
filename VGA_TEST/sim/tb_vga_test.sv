//=============================================================================
// tb_vga_test -- checks VGA_TEST: per-mode line/frame totals, sync widths and
// pixel clock; mode changes by S1 and KEY1; bar layout in both modes.
// vga_pll and vga_clkmux are replaced by behavioural models.
//=============================================================================
`timescale 1ns/1ps

module vga_pll (input wire inclk0, output reg c0 = 0, output reg c1 = 0, output wire locked);
    always #20.000 c0 = ~c0;                        // 25 MHz
    always #18.519 c1 = ~c1;                        // 27 MHz
    assign locked = 1'b1;
endmodule

// Clock control block model: select mux, enable latched on the falling edge
module vga_clkmux (input wire clk0, input wire clk1, input wire sel, input wire ena, output wire outclk);
    wire src = sel ? clk1 : clk0;
    reg  ena_l = 0;
    always @(negedge src) ena_l <= ena;
    assign outclk = src & ena_l;
endmodule

module tb_vga_test;
    reg clk50 = 0, rst_n = 0, sw = 0, key1 = 1;
    always #10 clk50 = ~clk50;

    wire r, rl, g, gl, b, bl, hs, vs, led;
    VGA_TEST dut (.CLOCK_50(clk50), .RESET_N(rst_n), .SW_50_60(sw), .KEY1(key1), .GND_TIE(2'b00), .LEDR(led),
                  .VGA_R(r), .VGA_R_LOW(rl), .VGA_G(g), .VGA_G_LOW(gl), .VGA_B(b), .VGA_B_LOW(bl),
                  .VGA_HSYNC(hs), .VGA_VSYNC(vs));
    wire pclk = dut.clk;

    // Frame statistics, counted in pixel clocks; a frame during which the
    // video logic was in reset (mode change) is marked and not checked.
    integer hcnt = 0, hlow = 0, lines = 0, vlow = 0, line_len = 0, line_hs = 0, hs_bad = 0;
    reg     hs_d = 1, vs_d = 1, was_reset = 1;
    realtime t_last = 0, period = 0;
    integer nf = 0, f_lines [0:63], f_len [0:63], f_vs [0:63], f_hsbad [0:63];
    real    f_period [0:63];
    reg     f_reset [0:63];

    always @(posedge pclk) begin
        period = $realtime - t_last; t_last = $realtime;
        hcnt <= hcnt + 1;
        if (!hs) hlow <= hlow + 1;
        if (hs_d && !hs) begin                                  // line start
            line_len = hcnt; line_hs = hlow;
            hcnt <= 1; hlow <= 1;
            lines <= lines + 1;
            if (!vs) vlow <= vlow + 1;
            if (line_hs != 0 && line_hs != (dut.sel ? 64 : 96)) hs_bad <= hs_bad + 1;
            if (vs_d && !vs) begin                              // frame start
                f_lines[nf] = lines; f_len[nf] = line_len; f_vs[nf] = vlow; f_hsbad[nf] = hs_bad;
                f_period[nf] = period; f_reset[nf] = was_reset;
                nf <= nf + 1;
                lines <= 1; vlow <= 1; hs_bad <= 0; was_reset = 0;
            end
        end
        hs_d <= hs; vs_d <= vs;
    end
    always @(negedge dut.rst_n) was_reset = 1;

    // Bar layout on active line 100 of the current mode
    task automatic check_bars(input integer w);
        reg [5:0] c, prev; integer run, n, i; integer runs [0:31]; reg [5:0] cols [0:31];
        begin
            wait (dut.u_timing.active && dut.u_timing.y == 100 && dut.u_timing.x == 0);
            @(posedge pclk);
            n = 0; run = 0; prev = 6'h3f;
            for (i = 0; i < w; i++) begin
                #1 c = {r, rl, g, gl, b, bl};
                if (i != 0 && c != prev) begin runs[n] = run; cols[n] = prev; n++; run = 0; end
                prev = c; run++;
                @(posedge pclk);
            end
            runs[n] = run; cols[n] = prev; n++;
            $write("bars %0d px (RrGgBb:width):", w);
            for (i = 0; i < n; i++) $write(" %b:%0d", cols[i], runs[i]);
            $display("");
        end
    endtask

    integer f, errors = 0, checked = 0;
    initial begin
        #200 rst_n = 1;
        check_bars(640);
        wait (nf == 3);
        sw = 1;                                         // S1 -> 50 Hz
        wait (nf == 6);
        check_bars(720);
        wait (nf == 8);
        key1 = 0; #15_000_000 key1 = 1;                 // KEY1 -> 60 Hz again
        wait (nf == 12);
        for (f = 1; f < nf; f++) begin
            $display("frame %2d: %0d lines x %0d px, vsync %0d lines, pclk %.3f MHz, %.3f Hz%s", f, f_lines[f], f_len[f],
                     f_vs[f], 1000.0 / f_period[f], 1.0e9 / (f_lines[f] * f_len[f] * f_period[f]),
                     f_reset[f] ? "  (mode change, not checked)" : "");
            if (!f_reset[f]) begin
                checked++;
                if (!((f_lines[f] == 525 && f_len[f] == 800 && f_vs[f] == 2 && f_period[f] > 39.9 && f_period[f] < 40.1) ||
                      (f_lines[f] == 625 && f_len[f] == 864 && f_vs[f] == 5 && f_period[f] > 37.0 && f_period[f] < 37.1)) ||
                    f_hsbad[f] != 0) begin
                    $display("ERROR frame %0d malformed", f); errors++;
                end
            end
        end
        if (errors || checked < 8) $display("FAIL (%0d errors, %0d frames checked)", errors, checked);
        else $display("PASS (%0d frames checked)", checked);
        $finish;
    end
endmodule
