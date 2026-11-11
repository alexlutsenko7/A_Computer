/* Test_wires testbench: drives the 6 inputs, writes the 4 outputs sampled at 1 MHz */
/* to samples.txt (as the ESP32 does); check_samples.py decodes them like the sketch. */
`timescale 1ns/1ps
module tb_test_wires;

/* half a period of the 50 MHz clock, ns */
localparam integer CLK_HALF = 10;
/* the reset ends after 1000 ns */
localparam integer RST_NS = 1000;
/* edges of the slow input pattern */
localparam integer SLOW_EDGES = 37;
/* half a period of the slow input pattern, ns */
localparam integer SLOW_HALF_NS = 250;
/* edges of the fast input pattern */
localparam integer FAST_EDGES = 200;
/* half a period of the fast input pattern, ns */
localparam real FAST_HALF_NS = 62.5;
/* clocks the outputs are watched */
localparam integer RUN_CLKS = 16000;
reg clk = 0, rst_n = 0;
/* 50 MHz */
always #CLK_HALF clk = ~clk;
reg [5:0] in = 6'b101100;
wire r1, r2, f1, f2, led;
/* the design under test */
Test_wires dut (.CLOCK_50(clk), .RESET_N(rst_n), .LEDR(led),
    .ESP_MISO(r1), .ESP_IRQ(r2), .BT_DATA(f1), .BT_TX(f2),
    .ESP_SCK(in[0]), .ESP_MOSI(in[1]), .ESP_CS_N(in[2]), .BT_BCLK(in[3]), .BT_LRCK(in[4]), .BT_RX(in[5]));
integer fd, k;
initial
begin
/* samples go into a file; reset ends */
    fd = $fopen("samples.txt", "w");
    #RST_NS rst_n = 1;
    #5ms in = 6'b010011;
/* 37 pulses on MOSI at 2 MHz */
    #3ms
        for (k = 0; k < SLOW_EDGES; k = k + 1)
        begin
            in[1] = 1;
/* low again */
            #SLOW_HALF_NS;
            in[1] = 0;
            #SLOW_HALF_NS;
        end
/* 8 MHz */
    for (k = 0; k < FAST_EDGES; k = k + 1)
    begin
        in[0] = 1;
        #FAST_HALF_NS;
/* low */
        in[0] = 0;
        #FAST_HALF_NS;
    end
end
/* the four outputs sampled every microsecond, as the ESP32 does */
initial
begin
    #2us;
    repeat (RUN_CLKS)
    begin
/* one line per sample */
        $fdisplay(fd, "%0d%0d%0d%0d", r1, r2, f1, f2);
        #1us;
    end
/* done */
    $fclose(fd);
    $finish;
end
endmodule
