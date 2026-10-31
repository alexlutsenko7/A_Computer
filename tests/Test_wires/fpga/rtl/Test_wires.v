//=============================================================================
// Test_wires -- FPGA side of the ESP32 <-> FPGA wiring test (Test_wires/README.md).
//
// Same pins as the LSpectrum_ESP revision, same directions:
//   FPGA -> ESP32: R1 U7.7 (ESP_MISO, GPIO35)   R2 U7.8  (ESP_IRQ, GPIO34)
//                  F1 U7.19 (BT_DATA, GPIO22)   F2 U7.20 (BT_TX,  GPIO16)
//   ESP32 -> FPGA: P1 U7.9  (ESP_SCK, GPIO14)   P2 U7.10 (ESP_MOSI, GPIO13)
//                  N1 U7.11 (ESP_CS_N, GPIO33)  H1 U7.17 (BT_BCLK, GPIO26)
//                  H2 U7.18 (BT_LRCK, GPIO25)   E1 U7.21 (BT_RX, GPIO17)
//
// Every output sends the same 10-byte UART frame (115200 8N1, 50 MHz / 434),
// except byte 1, which names the pin it leaves on:
//   0 A5   1 id (C1 = R1, C2 = R2, C3 = F1, C4 = F2)   2 input levels (bits 0-5)
//   3-8 rising-edge counters of the 6 inputs (mod 256)   9 check = 5A ^ bytes 1-8
// Input bit order: 0 P1, 1 P2, 2 N1, 3 H1, 4 H2, 5 E1. Levels and counters are
// latched when a frame starts. Frames repeat every 120 bit times (~1.04 ms).
// The inputs have weak pull-ups (an open wire reads 1). LED blinks at ~1.5 Hz.
//=============================================================================
`default_nettype none

module Test_wires (
    input  wire       CLOCK_50,
    input  wire       RESET_N,
    output wire       LEDR,

    output wire       ESP_MISO,         // R1
    output wire       ESP_IRQ,          // R2
    output wire       BT_DATA,          // F1
    output wire       BT_TX,            // F2

    input  wire       ESP_SCK,          // P1
    input  wire       ESP_MOSI,         // P2
    input  wire       ESP_CS_N,         // N1
    input  wire       BT_BCLK,          // H1
    input  wire       BT_LRCK,          // H2
    input  wire       BT_RX             // E1
);

localparam integer BIT_CLKS = 434;      // 50 MHz / 115200
localparam integer NBYTES = 10, FRAME_BITS = 120;

// reset
reg [1:0] rst_s = 2'b00;
always @(posedge CLOCK_50) rst_s <= {rst_s[0], RESET_N};
wire rst = !rst_s[1];

// inputs: 2 synchroniser flip-flops, one more for the edge
wire [5:0] pins = {BT_RX, BT_LRCK, BT_BCLK, ESP_CS_N, ESP_MOSI, ESP_SCK};
reg  [5:0] s1, s2, s3;
always @(posedge CLOCK_50) begin
    s1 <= pins;
    s2 <= s1;
    s3 <= s2;
end
wire [5:0] rise = s2 & ~s3;

reg [7:0] cnt [0:5];
integer i;
always @(posedge CLOCK_50)
    for (i = 0; i < 6; i = i + 1)
        if (rst) cnt[i] <= 8'd0;
        else if (rise[i]) cnt[i] <= cnt[i] + 8'd1;

// frame timing
reg [8:0] baud;
reg [6:0] bitn;                         // 0..FRAME_BITS-1
wire tick = baud == BIT_CLKS - 1;
always @(posedge CLOCK_50)
    if (rst) begin
        baud <= 9'd0;
        bitn <= 7'd0;
    end else begin
        baud <= tick ? 9'd0 : baud + 9'd1;
        if (tick) bitn <= bitn == FRAME_BITS - 1 ? 7'd0 : bitn + 7'd1;
    end

// snapshot at the frame start
reg [7:0] lvl = 8'd0, c [0:5];
initial for (i = 0; i < 6; i = i + 1) c[i] = 8'd0;
always @(posedge CLOCK_50)
    if (tick && bitn == FRAME_BITS - 1) begin
        lvl <= {2'b00, s2};
        for (i = 0; i < 6; i = i + 1) c[i] <= cnt[i];
    end

// the byte being sent (start bit, 8 data bits LSB first, stop bit)
wire [6:0] q10 = bitn / 7'd10, r10 = bitn % 7'd10;
wire [3:0] byten = q10[3:0];
wire [3:0] bitb  = r10[3:0];
wire [7:0] chk0  = 8'h5A ^ lvl ^ c[0] ^ c[1] ^ c[2] ^ c[3] ^ c[4] ^ c[5];

reg [7:0] cur;                          // byte byten without the id / check bytes
always @*
    case (byten)
        4'd0: cur = 8'hA5;
        4'd2: cur = lvl;
        4'd3: cur = c[0];
        4'd4: cur = c[1];
        4'd5: cur = c[2];
        4'd6: cur = c[3];
        4'd7: cur = c[4];
        4'd8: cur = c[5];
        default: cur = chk0;
    endcase

wire idle  = byten >= NBYTES;
wire start = bitb == 4'd0;
wire stop  = bitb == 4'd9;
wire [2:0] dbit = bitb[2:0] - 3'd1;     // data bit 0-7 for bitb 1-8

// one output per pin; only the id byte and the check byte differ
wire [7:0] ID [0:3];
assign ID[0] = 8'hC1;                   // R1
assign ID[1] = 8'hC2;                   // R2
assign ID[2] = 8'hC3;                   // F1
assign ID[3] = 8'hC4;                   // F2

reg [3:0] tx = 4'hF;                    // registered: clean edges, no glitches
genvar g;
generate for (g = 0; g < 4; g = g + 1) begin : gl
    wire [7:0] b = byten == 4'd1 ? ID[g] : byten == 4'd9 ? chk0 ^ ID[g] : cur;
    always @(posedge CLOCK_50)
        if (rst) tx[g] <= 1'b1;
        else tx[g] <= idle || stop ? 1'b1 : start ? 1'b0 : b[dbit];
end endgenerate

assign ESP_MISO = tx[0];
assign ESP_IRQ  = tx[1];
assign BT_DATA  = tx[2];
assign BT_TX    = tx[3];

// LED (active low): blink
reg [24:0] led_cnt = 25'd0;
always @(posedge CLOCK_50) led_cnt <= led_cnt + 25'd1;
assign LEDR = led_cnt[24];

endmodule
`default_nettype wire
