// tb_bt_i2s -- bt_i2s against an ESP32-like I2S master (Philips, 44.1 kHz).
//
// 1. Transport: every received word (both channels) equals the sample the DUT
//    loaded for it, for 16-bit and (+define+SLOT32) 32-bit slots.
// 2. Beeper 1 kHz square: the received swing is large and centred on 0.
// 3. A constant AY level: the DC blocker brings the output back to ~0.
`timescale 1ps/1ps
`default_nettype none

module tb_bt_i2s;

`ifdef SLOT32
localparam integer SLOT = 32;
`else
localparam integer SLOT = 16;
`endif
localparam real BCLK_HALF = 1.0e12 / (44100.0 * 2 * SLOT) / 2;   // ps

reg clk = 0, rst_n = 0;
always #4464 clk = !clk;                      // 112 MHz

reg  [31:0] ay_dds = 0;
reg         ay_cen = 0;
wire [32:0] ay_next = {1'b0, ay_dds} + 33'd136016246;
always @(posedge clk) begin
    ay_dds <= ay_next[31:0];
    ay_cen <= ay_next[32];
end

reg  [9:0] ay_sound = 0;
reg        beeper = 0;
reg        bclk = 0, lrck = 0;
wire       data;

bt_i2s dut (
    .clk(clk), .rst_n(rst_n), .ay_cen(ay_cen), .ay_sound(ay_sound), .beeper(beeper),
    .i2s_bclk(bclk), .i2s_lrck(lrck), .i2s_data(data)
);

// I2S master: LRCK changes on the falling BCLK edge, data is read on the rising one
integer falls = 0;
reg     run = 0;
always begin
    #(BCLK_HALF) if (run) bclk = 1;
    #(BCLK_HALF) if (run) begin
        bclk  = 0;
        falls = falls + 1;
        lrck  = (falls / SLOT) % 2;
    end
end

// expected words: what the DUT loads at each word start (the first falling edge,
// whose word has no load, is skipped by starting the queue after it)
logic signed [15:0] expq[$];
always @(posedge clk) if (dut.word_start && falls >= 1) expq.push_back(dut.sample);

reg  [15:0] rx;
integer     words = 0, errors = 0;
integer     vmin, vmax;
real        vsum;
integer     vcnt;

task automatic clear_stats;
    vmin = 32767; vmax = -32768; vsum = 0; vcnt = 0;
endtask

// Word w starts at the falling edge number w*SLOT; its 16 bits are read on the
// rising edges after falling edges w*SLOT+1 .. w*SLOT+16 (Philips: one BCLK late,
// so with 16-bit slots the LSB is read in the next slot).
always @(posedge bclk) begin : receive
    integer b;
    logic signed [15:0] e, v;
    b = (falls - 1) % SLOT;
    if (falls >= 1 && b < 16) rx = {rx[14:0], data};
    if (falls >= 1 && b == 15) begin
        v = rx;
        if (expq.size() == 0) begin
            if (words >= 2) begin $display("ERROR: word without a load"); errors++; end
        end else begin
            e = expq.pop_front();
            if (words >= 2 && v !== e) begin
                if (errors < 10) $display("ERROR: word %0d got %0d expected %0d", words, v, e);
                errors++;
            end
        end
        words++;
        if (v < vmin) vmin = v;
        if (v > vmax) vmax = v;
        vsum += v; vcnt++;
    end
end

initial begin
    clear_stats();
    #100ns rst_n = 1;
    #1us run = 1;

    // 1+2: beeper 1 kHz with some AY, 50 ms
    ay_sound = 10'd300;
    fork
        begin : beep
            forever #500us beeper = !beeper;
        end
        #20ms clear_stats();
    join_any
    #30ms;
    disable beep;
    $display("beeper 1 kHz: min %0d max %0d mean %0.1f (%0d words)", vmin, vmax, vsum / vcnt, vcnt);
    if (vmax - vmin < 7000) begin $display("ERROR: beeper swing too small"); errors++; end
    if (vsum / vcnt > 300 || vsum / vcnt < -300) begin $display("ERROR: beeper not centred"); errors++; end

    // 3: constant level: DC must decay (fc ~27 Hz -> tau ~6 ms)
    beeper = 1; ay_sound = 10'd1000;
    #60ms clear_stats();
    #5ms;
    $display("constant input after 60 ms: min %0d max %0d", vmin, vmax);
    if (vmax > 100 || vmin < -100) begin $display("ERROR: DC not removed"); errors++; end

    $display("%0d words, %0d errors (slot %0d)", words, errors, SLOT);
    if (errors == 0) $display("PASS"); else $display("FAIL");
    $finish;
end

endmodule

`default_nettype wire
