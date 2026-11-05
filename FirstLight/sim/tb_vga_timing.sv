// tb_vga_timing -- checks both modes of vga_timing: clocks per line, lines per
// frame, visible pixels per line and visible lines per frame.
`timescale 1ns/1ps
module tb_vga_timing;

reg clk = 0, rst_n = 0, mode_50 = 0;
always #19.837 clk = !clk;              // 25.208 MHz (the period does not matter here)

wire [9:0] hcnt, vcnt, x, y, h_act, v_act;
wire active, hsync_n, vsync_n;

vga_timing dut (.clk(clk), .rst_n(rst_n), .mode_50(mode_50),
                .hcnt(hcnt), .vcnt(vcnt), .active(active), .x(x), .y(y),
                .h_act(h_act), .v_act(v_act), .hsync_n(hsync_n), .vsync_n(vsync_n));

integer errors = 0;

// Measure one whole frame, from one vsync start to the next
task check_mode(input integer m, input integer h_total, input integer v_total,
                input integer h_vis, input integer v_vis);
    integer clocks, lines, vis, vis_lines, line_vis;
    reg hs_d, vs_d;
    begin
        rst_n = 0; mode_50 = m; repeat (4) @(posedge clk); rst_n = 1;
        vs_d = 1;                                       // wait for a frame start,
        forever begin                                   // seen at a clock edge
            @(posedge clk);
            if (vs_d && !vsync_n) break;
            vs_d = vsync_n;
        end
        clocks = 0; lines = 1; vis = 0; vis_lines = 0; line_vis = 0; hs_d = 0; vs_d = 0;
        forever begin                                   // until the next frame
            @(posedge clk);
            clocks = clocks + 1;
            if (vs_d && !vsync_n) break;
            vs_d = vsync_n;
            if (active) begin vis = vis + 1; line_vis = line_vis + 1; end
            if (hs_d && !hsync_n) begin                 // a line starts
                lines = lines + 1;
                if (line_vis) begin
                    vis_lines = vis_lines + 1;
                    if (line_vis != h_vis) begin
                        $display("ERROR mode %0d: %0d visible pixels in a line, expected %0d", m, line_vis, h_vis);
                        errors = errors + 1;
                    end
                end
                line_vis = 0;
            end
            hs_d = hsync_n;
            if (clocks > 2 * h_total * v_total) begin
                $display("ERROR mode %0d: no second frame", m); errors = errors + 1; disable check_mode;
            end
        end
        $display("mode %0d: %0d clocks per frame = %0d lines of %0d, %0d visible lines, %0d visible pixels",
                 m, clocks, lines, clocks / lines, vis_lines, vis);
        if (clocks != h_total * v_total || lines != v_total || vis_lines != v_vis || vis != h_vis * v_vis) begin
            $display("ERROR mode %0d: expected %0d lines of %0d clocks, %0d x %0d visible", m, v_total, h_total, h_vis, v_vis);
            errors = errors + 1;
        end
    end
endtask

initial begin
    check_mode(0, 800, 525, 640, 480);
    check_mode(1, 864, 625, 720, 576);
    if (errors == 0) $display("PASS");
    else             $display("FAIL: %0d errors", errors);
    $finish;
end

endmodule
