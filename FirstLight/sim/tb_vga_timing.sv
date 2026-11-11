/* tb_vga_timing -- checks both modes of vga_timing: clocks per line, lines per */
/* frame, visible pixels per line and visible lines per frame. */
`timescale 1ns/1ps
module tb_vga_timing;

/* half a period of the pixel clock, ns */
localparam real CLK_HALF = 19.837;
/* clocks of the reset */
localparam integer RST_CLKS = 4;
/* frames after which the test gives up */
localparam integer FRAMES_MAX = 2;

reg clk = 0, rst_n = 0, mode_50 = 0;
/* 25.208 MHz (the period does not matter here) */
always #CLK_HALF clk = !clk;

wire [9:0] hcnt, vcnt, x, y, h_act, v_act;
wire active, hsync_n, vsync_n;

/* the design under test */
vga_timing dut (.clk(clk), .rst_n(rst_n), .mode_50(mode_50),
                .hcnt(hcnt), .vcnt(vcnt), .active(active), .x(x), .y(y),
                .h_act(h_act), .v_act(v_act), .hsync_n(hsync_n), .vsync_n(vsync_n));

integer errors = 0;

/* Measure one whole frame, from one vsync start to the next */
task check_mode(input integer m, input integer h_total, input integer v_total,
                input integer h_vis, input integer v_vis);
    integer clocks, lines, vis, vis_lines, line_vis;
    reg hs_d, vs_d;
    begin
/* reset in the mode to check */
        rst_n = 0;
        mode_50 = m;
        repeat (RST_CLKS)
        begin
/* four clocks */
            @(posedge clk);
        end
        rst_n = 1;
/* wait for a frame start, */
        vs_d = 1;
/* seen at a clock edge */
        forever
        begin
            @(posedge clk);
            if (vs_d && !vsync_n)
            begin
/* a falling vsync: the frame starts */
                break;
            end
            vs_d = vsync_n;
        end
/* counters from this vsync on */
        clocks = 0;
        lines = 1;
        vis = 0;
/* nothing visible yet */
        vis_lines = 0;
        line_vis = 0;
/* the syncs one clock ago */
        hs_d = 0;
        vs_d = 0;
/* until the next frame */
        forever
        begin
            @(posedge clk);
            clocks = clocks + 1;
/* the next vsync ends the frame */
            if (vs_d && !vsync_n)
            begin
                break;
            end
            vs_d = vsync_n;
/* a visible pixel */
            if (active)
            begin
                vis = vis + 1;
                line_vis = line_vis + 1;
            end
/* a line starts */
            if (hs_d && !hsync_n)
            begin
                lines = lines + 1;
                if (line_vis)
                begin
/* a visible line must have the mode's width */
                    vis_lines = vis_lines + 1;
                    if (line_vis != h_vis)
                    begin
                        $display("ERROR mode %0d: %0d visible pixels in a line, expected %0d", m, line_vis, h_vis);
/* counted */
                        errors = errors + 1;
                    end
                end
                line_vis = 0;
            end
/* the hsync one clock ago; a frame that never ends */
            hs_d = hsync_n;
            if (clocks > FRAMES_MAX * h_total * v_total)
            begin
                $display("ERROR mode %0d: no second frame", m);
/* counted; the check ends */
                errors = errors + 1;
                disable check_mode;
            end
        end
/* what was measured, and what it must be */
        $display("mode %0d: %0d clocks per frame = %0d lines of %0d, %0d visible lines, %0d visible pixels",
                 m, clocks, lines, clocks / lines, vis_lines, vis);
        if (clocks != h_total * v_total || lines != v_total || vis_lines != v_vis || vis != h_vis * v_vis)
        begin
            $display("ERROR mode %0d: expected %0d lines of %0d clocks, %0d x %0d visible", m, v_total, h_total, h_vis, v_vis);
/* counted */
            errors = errors + 1;
        end
    end
endtask

/* both modes */
initial
begin
    check_mode(0, 800, 525, 640, 480);
    check_mode(1, 864, 625, 720, 576);
/* the verdict */
    if (errors == 0)
    begin
        $display("PASS");
    end
    else
    begin
        $display("FAIL: %0d errors", errors);
    end
/* the end */
    $finish;
end

endmodule
