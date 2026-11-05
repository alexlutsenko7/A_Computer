// tb_first_light -- the whole FirstLight design, with simple models of the two
// Altera components it uses (the PLL and the clock control block).
// Checks: the line period at 60 Hz, a press of KEY1, the line period at 50 Hz,
// and the color of a few pixels in each mode.
`timescale 1ns/1ps

// Model of vga_pll: two free-running clocks and a locked signal after 10 us
module vga_pll (input wire inclk0, output reg c0 = 0, output reg c1 = 0, output reg locked = 0);
    always #19.835 c0 = !c0;            // 25.208 MHz
    always #18.512 c1 = !c1;            // 27.009 MHz
    initial #10000 locked = 1;
endmodule

// Model of vga_clkmux: the selected clock while ena is 1
module vga_clkmux (input wire clk0, clk1, sel, ena, output wire outclk);
    assign outclk = ena & (sel ? clk1 : clk0);
endmodule

module tb_first_light;

reg CLOCK_50 = 0, RESET_N = 0, KEY1 = 1;
always #10 CLOCK_50 = !CLOCK_50;

wire LEDR, VGA_HS, VGA_VS;
wire [3:0] VGA_R, VGA_G, VGA_B;

first_light dut (.CLOCK_50(CLOCK_50), .RESET_N(RESET_N), .KEY1(KEY1), .LEDR(LEDR),
                 .VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B), .VGA_HS(VGA_HS), .VGA_VS(VGA_VS));

integer errors = 0;

// Time between two falling edges of VGA_HS, in ns
task line_period(output real t);
    real t0;
    begin
        @(negedge VGA_HS); t0 = $realtime;
        @(negedge VGA_HS); t  = $realtime - t0;
    end
endtask

task expect_line(input real want_ns, input [79:0] what);
    real t;
    begin
        line_period(t);
        $display("%0s: line period %0.1f ns", what, t);
        if (t < want_ns - 1.0 || t > want_ns + 1.0) begin
            $display("ERROR: expected %0.1f ns", want_ns); errors = errors + 1;
        end
    end
endtask

// The color the design puts out for pixel (px, py): the output registers take
// the value one clock after the pixel counters show it.
task expect_pixel(input integer px, input integer py, input [11:0] want);
    begin
        @(posedge dut.clk iff (dut.active && dut.x == px && dut.y == py));
        @(posedge dut.clk); #1;
        if ({VGA_R, VGA_G, VGA_B} !== want) begin
            $display("ERROR: pixel (%0d, %0d) is %h, expected %h", px, py, {VGA_R, VGA_G, VGA_B}, want);
            errors = errors + 1;
        end else
            $display("pixel (%0d, %0d) = %h", px, py, want);
    end
endtask

initial begin
    #200 RESET_N = 1;

    // 640 x 480: 800 pixels at 25.208 MHz = 31,738 ns per line
    expect_line(800 * 39.670, "60 Hz");
    expect_pixel( 40, 100, 12'hFFF);    // bar 0, white
    expect_pixel(600, 100, 12'h000);    // bar 7, black
    expect_pixel(  0, 100, 12'hFFF);    // the white frame
    expect_pixel(300, 400, 12'h777);    // ramp step 7
    if (LEDR !== 1'b0 && LEDR !== 1'b1) begin $display("ERROR: LED undefined"); errors = errors + 1; end

    // KEY1: held for 15 ms, longer than the 10.5 ms debounce filter
    KEY1 = 0; #15_000_000; KEY1 = 1;
    wait (dut.state == 2'd3 && dut.sel == 1'b1);
    $display("KEY1 pressed: 50 Hz mode running");

    // 720 x 576: 864 pixels at 27.009 MHz = 31,989 ns per line
    expect_line(864 * 37.024, "50 Hz");
    expect_pixel( 40, 100, 12'hFFF);    // bar 0, white
    expect_pixel(680, 100, 12'h000);    // bar 7, black
    expect_pixel(360, 500, 12'h888);    // ramp step 8

    if (errors == 0) $display("PASS");
    else             $display("FAIL: %0d errors", errors);
    $finish;
end

initial begin
    #200_000_000 $display("FAIL: timeout"); $finish;
end

endmodule
