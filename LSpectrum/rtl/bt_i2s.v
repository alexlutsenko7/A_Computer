//=============================================================================
// bt_i2s -- machine sound as an I2S slave transmitter for the ESP32 Bluetooth
//           part of the system controller (esp32/esp32.ino)
//
// The ESP32 is the I2S master: it drives BCLK (32 x fs = 1.4112 MHz at
// 44.1 kHz) and LRCK, and reads DATA on the rising BCLK edge. Format: Philips
// I2S, 16-bit signed, MSB first, one BCLK after the LRCK edge; any slot width
// >= 16 works (the remaining bits are sent as 0). Both channels carry the same
// (mono) sample.
//
// BCLK/LRCK are asynchronous: they are synchronised to clk, LRCK is taken on the
// rising BCLK edge (it changes on the falling one) and DATA changes ~3 clocks
// (27 ns) after the falling edge, far ahead of the next rising edge (354 ns).
//
// Sound: AY (10-bit, x16) + beeper (8192), the same sources as the analog
// outputs. Two one-pole low-passes at the AY rate (3.5469 MHz, fc ~35 kHz each)
// against aliasing, then one DC-blocking high-pass per sample (fc ~27 Hz), so
// silence is 0 whatever the AY volumes or beeper level.
//=============================================================================
`default_nettype none

module bt_i2s (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       ay_cen,           // AY clock enable, 3.5469 MHz
    input  wire [9:0] ay_sound,         // unsigned
    input  wire       beeper,

    input  wire       i2s_bclk,         // from the ESP32 (asynchronous)
    input  wire       i2s_lrck,
    output reg        i2s_data
);

//-----------------------------------------------------------------------------
// Mix and low-pass (4 fraction bits)
//-----------------------------------------------------------------------------
wire [14:0] mix = {1'b0, ay_sound, 4'b0000} + (beeper ? 15'd8192 : 15'd0);

reg  [18:0] lp1, lp2;                   // 0 .. 24560 x 16
wire signed [20:0] d1 = $signed({2'b00, mix, 4'b0000}) - $signed({2'b00, lp1});
wire signed [20:0] d2 = $signed({2'b00, lp1})          - $signed({2'b00, lp2});
wire signed [20:0] s1 = d1 >>> 4;
wire signed [20:0] s2 = d2 >>> 4;

always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
        lp1 <= 19'd0;
        lp2 <= 19'd0;
    end else if (ay_cen) begin
        lp1 <= lp1 + s1[18:0];
        lp2 <= lp2 + s2[18:0];
    end

//-----------------------------------------------------------------------------
// I2S edges
//-----------------------------------------------------------------------------
reg [2:0] bclk_s;
reg [1:0] lrck_s;
reg       lrck_q;                       // LRCK at the last rising BCLK edge

always @(posedge clk) begin
    bclk_s <= {bclk_s[1:0], i2s_bclk};
    lrck_s <= {lrck_s[0], i2s_lrck};
end

wire bclk_rise = bclk_s[2:1] == 2'b01;
wire bclk_fall = bclk_s[2:1] == 2'b10;
wire word_start = bclk_rise && lrck_s[1] != lrck_q;     // first rising edge of a new word
wire frame_start = word_start && !lrck_s[1];             // ... of the left word

//-----------------------------------------------------------------------------
// DC blocker, once per frame: hp = hp + (x - x_prev) - hp / 256 (8 fraction bits)
//-----------------------------------------------------------------------------
wire        [14:0] x = lp2[18:4];
reg         [14:0] x_prev;
reg  signed [25:0] hp;
wire signed [25:0] hp_next = hp + ($signed({11'd0, x}) - $signed({11'd0, x_prev})) * 256 - (hp >>> 8);
wire signed [17:0] hp_int  = hp[25:8];
reg  signed [15:0] sample;

always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
        x_prev <= 15'd0;
        hp     <= 26'sd0;
        sample <= 16'sd0;
    end else if (frame_start) begin
        x_prev <= x;
        hp     <= hp_next;
        sample <= hp_int >  18'sd32767 ?  16'sd32767 :
                  hp_int < -18'sd32768 ? -16'sd32768 : hp_int[15:0];
    end

//-----------------------------------------------------------------------------
// Shift out: load on the first rising edge of each word, so the MSB goes out on
// the following falling edge (Philips: one BCLK after LRCK)
//-----------------------------------------------------------------------------
reg [15:0] sr;

always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
        lrck_q   <= 1'b0;
        sr       <= 16'd0;
        i2s_data <= 1'b0;
    end else begin
        if (bclk_rise)
            lrck_q <= lrck_s[1];
        if (word_start)
            sr <= sample;
        else if (bclk_fall) begin
            i2s_data <= sr[15];
            sr       <= {sr[14:0], 1'b0};
        end
    end

endmodule

`default_nettype wire
