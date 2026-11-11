/* tb_first_light -- the whole FirstLight design, with simple models of the two */
/* Altera components it uses (the PLL and the clock control block). */
/* Checks: the line period at 60 Hz, a press of KEY1, the line period at 50 Hz, */
/* and the color of a few pixels in each mode. */
`timescale 1ns/1ps

/* Model of vga_pll: two free-running clocks and a locked signal after 10 us */
module vga_pll (input wire inclk0, output reg c0 = 0, output reg c1 = 0, output reg locked = 0);

/* half a period of the 25.208 MHz clock, ns */
localparam real C0_HALF = 19.835;
/* half a period of the 27.009 MHz clock, ns */
localparam real C1_HALF = 18.512;
/* ns until the PLL model reports lock */
localparam integer LOCK_NS = 10000;
/* 25.208 MHz */
    always #C0_HALF c0 = !c0;
/* 27.009 MHz */
    always #C1_HALF c1 = !c1;
    initial #LOCK_NS locked = 1;
endmodule

/* Model of vga_clkmux: the selected clock while ena is 1 */
module vga_clkmux (input wire clk0, clk1, sel, ena, output wire outclk);
    assign outclk = ena & (sel ? clk1 : clk0);
endmodule

module tb_first_light;

/* half a period of the 50 MHz clock, ns */
localparam integer CLK50_HALF = 10;
/* tolerance on a measured period, ns */
localparam real TOL_NS = 1.0;
/* the reset ends after 200 ns */
localparam integer RST_NS = 200;
/* time before the key changes, ns */
localparam integer KEY_HOLD_NS = 15_000_000;

/* 50 MHz, reset, the key */
reg CLOCK_50 = 0, RESET_N = 0, KEY1 = 1;
always #CLK50_HALF CLOCK_50 = !CLOCK_50;

/* the design under test */
wire LEDR, VGA_HS, VGA_VS;
wire [3:0] VGA_R, VGA_G, VGA_B;

first_light dut (.CLOCK_50(CLOCK_50), .RESET_N(RESET_N), .KEY1(KEY1), .LEDR(LEDR),
                 .VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B), .VGA_HS(VGA_HS), .VGA_VS(VGA_VS));

/* errors found */
integer errors = 0;

/* Time between two falling edges of VGA_HS, in ns */
task line_period(output real t);
    real t0;
    begin
        @(negedge VGA_HS);
/* from one edge to the next */
        t0 = $realtime;
        @(negedge VGA_HS);
        t  = $realtime - t0;
    end
endtask

/* a line period that must be right within 1 ns */
task expect_line(input real want_ns, input [79:0] what);
    real t;
    begin
        line_period(t);
/* said, then checked */
        $display("%0s: line period %0.1f ns", what, t);
        if (t < want_ns - TOL_NS || t > want_ns + TOL_NS)
        begin
            $display("ERROR: expected %0.1f ns", want_ns);
/* counted */
            errors = errors + 1;
        end
    end
endtask

/* The color the design puts out for pixel (px, py): the output registers take */
/* the value one clock after the pixel counters show it. */
task expect_pixel(input integer px, input integer py, input [11:0] want);
    begin
        @(posedge dut.clk iff (dut.active && dut.x == px && dut.y == py));
        @(posedge dut.clk);
/* just after the edge */
        #1;
        if ({VGA_R, VGA_G, VGA_B} !== want)
        begin
            $display("ERROR: pixel (%0d, %0d) is %h, expected %h", px, py, {VGA_R, VGA_G, VGA_B}, want);
/* counted; or said */
            errors = errors + 1;
        end
        else
        begin
            $display("pixel (%0d, %0d) = %h", px, py, want);
        end
    end
endtask

/* the test */
initial
begin
    #RST_NS RESET_N = 1;

/* 640 x 480: 800 pixels at 25.208 MHz = 31,738 ns per line */
    expect_line(800 * 39.670, "60 Hz");
/* bar 0, white */
    expect_pixel( 40, 100, 12'hFFF);
/* bar 7, black */
    expect_pixel(600, 100, 12'h000);
/* the white frame */
    expect_pixel(  0, 100, 12'hFFF);
/* ramp step 7 */
    expect_pixel(300, 400, 12'h777);
    if (LEDR !== 1'b0 && LEDR !== 1'b1)
    begin
/* counted */
        $display("ERROR: LED undefined");
        errors = errors + 1;
    end

/* KEY1: held for 15 ms, longer than the 10.5 ms debounce filter */
    KEY1 = 0;
    #KEY_HOLD_NS;
    KEY1 = 1;
/* the sequencer runs in the other mode */
    wait (dut.state == 2'd3 && dut.sel == 1'b1);
    $display("KEY1 pressed: 50 Hz mode running");

/* 720 x 576: 864 pixels at 27.009 MHz = 31,989 ns per line */
    expect_line(864 * 37.024, "50 Hz");
/* bar 0, white */
    expect_pixel( 40, 100, 12'hFFF);
/* bar 7, black */
    expect_pixel(680, 100, 12'h000);
/* ramp step 8 */
    expect_pixel(360, 500, 12'h888);

    if (errors == 0)
    begin
        $display("PASS");
    end
    else
    begin
/* failed */
        $display("FAIL: %0d errors", errors);
    end
    $finish;
end

/* a simulation that hangs */
initial
begin
    #200_000_000 $display("FAIL: timeout");
    $finish;
end

endmodule
