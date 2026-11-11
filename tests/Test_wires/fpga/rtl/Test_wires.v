/* Test_wires -- FPGA side of the ESP32 <-> FPGA wiring test (Test_wires/README.md). */
/* */
/* Same pins as the LSpectrum_ESP revision, same directions: */
/* FPGA -> ESP32: R1 U7.7 (ESP_MISO, GPIO35)   R2 U7.8  (ESP_IRQ, GPIO34) */
/* F1 U7.19 (BT_DATA, GPIO22)   F2 U7.20 (BT_TX,  GPIO16) */
/* ESP32 -> FPGA: P1 U7.9  (ESP_SCK, GPIO14)   P2 U7.10 (ESP_MOSI, GPIO13) */
/* N1 U7.11 (ESP_CS_N, GPIO33)  H1 U7.17 (BT_BCLK, GPIO26) */
/* H2 U7.18 (BT_LRCK, GPIO25)   E1 U7.21 (BT_RX, GPIO17) */
/* */
/* Every output sends the same 10-byte UART frame (115200 8N1, 50 MHz / 434), */
/* except byte 1, which names the pin it leaves on: */
/* 0 A5   1 id (C1 = R1, C2 = R2, C3 = F1, C4 = F2)   2 input levels (bits 0-5) */
/* 3-8 rising-edge counters of the 6 inputs (mod 256)   9 check = 5A ^ bytes 1-8 */
/* Input bit order: 0 P1, 1 P2, 2 N1, 3 H1, 4 H2, 5 E1. Levels and counters are */
/* latched when a frame starts. Frames repeat every 120 bit times (~1.04 ms). */
/* The inputs have weak pull-ups (an open wire reads 1). LED blinks at ~1.5 Hz. */
`default_nettype none

module Test_wires (
    input  wire       CLOCK_50,
    input  wire       RESET_N,
    output wire       LEDR,

/* R1 */
    output wire       ESP_MISO,
/* R2 */
    output wire       ESP_IRQ,
/* F1 */
    output wire       BT_DATA,
/* F2 */
    output wire       BT_TX,

/* P1 */
    input  wire       ESP_SCK,
/* P2 */
    input  wire       ESP_MOSI,
/* N1 */
    input  wire       ESP_CS_N,
/* H1 */
    input  wire       BT_BCLK,
/* H2 */
    input  wire       BT_LRCK,
/* E1 */
    input  wire       BT_RX
);

/* edge counters (one per input line) */
localparam integer COUNTERS = 6;
/* bits of a UART byte: start, 8 data, stop */
localparam [6:0] BITS_PER_BYTE = 7'd10;
/* start value of the report's checksum */
localparam [7:0] CHK_SEED = 8'h5A;
/* the bit slot of the stop bit */
localparam [3:0] STOP_BIT = 4'd9;
/* identity byte of output R1 */
localparam [7:0] ID_R1 = 8'hC1;
/* identity byte of output R2 */
localparam [7:0] ID_R2 = 8'hC2;
/* identity byte of output F1 */
localparam [7:0] ID_F1 = 8'hC3;
/* identity byte of output F2 */
localparam [7:0] ID_F2 = 8'hC4;
/* output lines that carry a report */
localparam integer OUTPUTS = 4;
/* the report's last byte: the checksum */
localparam [3:0] CHK_BYTE = 4'd9;

/* 50 MHz / 115200 */
localparam integer BIT_CLKS = 434;
localparam integer NBYTES = 10, FRAME_BITS = 120;

/* reset */
reg [1:0] rst_s = 2'b00;
always @(posedge CLOCK_50) rst_s <= {rst_s[0], RESET_N};
wire rst = !rst_s[1];

/* inputs: 2 synchroniser flip-flops, one more for the edge */
wire [5:0] pins = {BT_RX, BT_LRCK, BT_BCLK, ESP_CS_N, ESP_MOSI, ESP_SCK};
reg  [5:0] s1, s2, s3;
always @(posedge CLOCK_50)
begin
/* three stages */
    s1 <= pins;
    s2 <= s1;
    s3 <= s2;
end
/* a rising edge */
wire [5:0] rise = s2 & ~s3;

/* eight-bit edge counters, cleared by reset */
reg [7:0] cnt [0:5];
integer i;
always @(posedge CLOCK_50)
/* per input */
    for (i = 0; i < COUNTERS; i = i + 1)
    begin
        if (rst)
        begin
            cnt[i] <= 8'd0;
        end
/* one more edge */
        else if (rise[i])
        begin
            cnt[i] <= cnt[i] + 8'd1;
        end
    end

/* frame timing */
reg [8:0] baud;
/* 0..FRAME_BITS-1 */
reg [6:0] bitn;
wire tick = baud == BIT_CLKS - 1;
always @(posedge CLOCK_50)
/* reset */
    if (rst)
    begin
        baud <= 9'd0;
        bitn <= 7'd0;
    end
    else
    begin
/* a bit time, then the next bit of the frame */
        baud <= tick ? 9'd0 : baud + 9'd1;
        if (tick)
        begin
            bitn <= bitn == FRAME_BITS - 1 ? 7'd0 : bitn + 7'd1;
        end
    end

/* snapshot at the frame start */
reg [7:0] lvl = 8'd0, c [0:5];
initial
    for (i = 0; i < COUNTERS; i = i + 1)
    begin
/* all 0 at the start */
        c[i] = 8'd0;
    end
always @(posedge CLOCK_50)
    if (tick && bitn == FRAME_BITS - 1)
    begin
/* levels and counters as they are now */
        lvl <= {2'b00, s2};
        for (i = 0; i < COUNTERS; i = i + 1)
        begin
            c[i] <= cnt[i];
        end
    end

/* the byte being sent (start bit, 8 data bits LSB first, stop bit) */
wire [6:0] q10 = bitn / BITS_PER_BYTE, r10 = bitn % BITS_PER_BYTE;
wire [3:0] byten = q10[3:0];
/* the bit inside the byte; the checksum without the id */
wire [3:0] bitb  = r10[3:0];
wire [7:0] chk0  = CHK_SEED ^ lvl ^ c[0] ^ c[1] ^ c[2] ^ c[3] ^ c[4] ^ c[5];

/* byte byten without the id / check bytes */
reg [7:0] cur;
always @*
    case (byten)
/* the frame's bytes */
        4'd0: cur = 8'hA5;
        4'd2: cur = lvl;
        4'd3: cur = c[0];
/* the six counters */
        4'd4: cur = c[1];
        4'd5: cur = c[2];
        4'd6: cur = c[3];
/* the last two, and the checksum */
        4'd7: cur = c[4];
        4'd8: cur = c[5];
        default: cur = chk0;
    endcase

/* between frames; start and stop bit */
wire idle  = byten >= NBYTES;
wire start = bitb == 4'd0;
wire stop  = bitb == STOP_BIT;
/* data bit 0-7 for bitb 1-8 */
wire [2:0] dbit = bitb[2:0] - 3'd1;

/* one output per pin; only the id byte and the check byte differ */
wire [7:0] ID [0:3];
/* R1 */
assign ID[0] = ID_R1;
/* R2 */
assign ID[1] = ID_R2;
/* F1 */
assign ID[2] = ID_F1;
/* F2 */
assign ID[3] = ID_F2;

/* registered: clean edges, no glitches */
reg [3:0] tx = 4'hF;
genvar g;
generate for (g = 0; g < OUTPUTS; g = g + 1)
begin : gl
/* the id and the checksum differ per output */
    wire [7:0] b = byten == 4'd1 ? ID[g] : byten == CHK_BYTE ? chk0 ^ ID[g] : cur;
    always @(posedge CLOCK_50)
        if (rst)
        begin
/* idle high; start bit low, data bits, stop bit high */
            tx[g] <= 1'b1;
        end
        else
        begin
            tx[g] <= idle || stop ? 1'b1 : start ? 1'b0 : b[dbit];
        end
end
endgenerate

/* the four outputs */
assign ESP_MISO = tx[0];
assign ESP_IRQ  = tx[1];
/* the Bluetooth pins */
assign BT_DATA  = tx[2];
assign BT_TX    = tx[3];

/* LED (active low): blink */
reg [24:0] led_cnt = 25'd0;
always @(posedge CLOCK_50) led_cnt <= led_cnt + 25'd1;
/* the LED */
assign LEDR = led_cnt[24];

endmodule
`default_nettype wire
