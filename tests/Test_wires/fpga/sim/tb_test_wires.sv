// Test_wires testbench: drives the 6 inputs, writes the 4 outputs sampled at 1 MHz
// to samples.txt (as the ESP32 does); check_samples.py decodes them like the sketch.
`timescale 1ns/1ps
module tb_test_wires;
reg clk = 0, rst_n = 0;
always #10 clk = ~clk;
reg [5:0] in = 6'b101100;
wire r1, r2, f1, f2, led;
Test_wires dut (.CLOCK_50(clk), .RESET_N(rst_n), .LEDR(led),
    .ESP_MISO(r1), .ESP_IRQ(r2), .BT_DATA(f1), .BT_TX(f2),
    .ESP_SCK(in[0]), .ESP_MOSI(in[1]), .ESP_CS_N(in[2]), .BT_BCLK(in[3]), .BT_LRCK(in[4]), .BT_RX(in[5]));
integer fd, k;
initial begin
    fd = $fopen("samples.txt", "w");
    #1000 rst_n = 1;
    #5ms in = 6'b010011;
    #3ms for (k = 0; k < 37; k = k + 1) begin in[1] = 1; #250; in[1] = 0; #250; end
    for (k = 0; k < 200; k = k + 1) begin in[0] = 1; #62.5; in[0] = 0; #62.5; end   // 8 MHz
end
initial begin
    #2us;
    repeat (16000) begin
        $fdisplay(fd, "%0d%0d%0d%0d", r1, r2, f1, f2);
        #1us;
    end
    $fclose(fd);
    $finish;
end
endmodule
