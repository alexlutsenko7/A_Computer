/* bt_i2s -- machine sound as an I2S slave transmitter for the ESP32 Bluetooth */
/* part of the system controller (ESP32/v2/v2.ino) */
/* */
/* The ESP32 is the I2S master: it drives BCLK (32 x fs = 1.4112 MHz at */
/* 44.1 kHz) and LRCK, and reads DATA on the rising BCLK edge. Format: Philips */
/* I2S, 16-bit signed, MSB first, one BCLK after the LRCK edge; any slot width */
/* >= 16 works (the remaining bits are sent as 0). Both channels carry the same */
/* (mono) sample. */
/* */
/* BCLK/LRCK are asynchronous: they are synchronised to clk, LRCK is taken on the */
/* rising BCLK edge (it changes on the falling one) and DATA changes ~3 clocks */
/* (27 ns) after the falling edge, far ahead of the next rising edge (354 ns). */
/* */
/* Sound: AY (10-bit, x16) + beeper (8192), the same sources as the analog */
/* outputs. Two one-pole low-passes at the AY rate (3.5469 MHz, fc ~35 kHz each) */
/* against aliasing, then one DC-blocking high-pass per sample (fc ~27 Hz), so */
/* silence is 0 whatever the AY volumes or beeper level. */
`default_nettype none

module bt_i2s (
    input  wire       clk,
    input  wire       rst_n,
/* AY clock enable, 3.5469 MHz */
    input  wire       ay_cen,
/* unsigned */
    input  wire [9:0] ay_sound,
    input  wire       beeper,

/* from the ESP32 (asynchronous) */
    input  wire       i2s_bclk,
    input  wire       i2s_lrck,
    output reg        i2s_data
);

/* the beeper's share of the mix */
localparam [14:0] BEEPER_LEVEL = 15'd8192;
/* low-pass filters: 1/16 of the difference per step */
localparam integer LP_SHIFT = 4;
/* DC blocker: 1.0 with 8 fraction bits */
localparam integer HP_ONE = 256;
/* DC blocker: the leak is 1/256 per step */
localparam integer HP_SHIFT = 8;
/* upper limit of a 16-bit sample, in the filter's width */
localparam signed [17:0] CLIP_HI = 18'sd32767;
/* highest 16-bit sample */
localparam signed [15:0] SAMPLE_MAX = 16'sd32767;
/* lower limit of a 16-bit sample (negated where used), in the filter's width */
localparam signed [17:0] CLIP_LO = 18'sd32768;
/* lowest 16-bit sample (negated where used) */
localparam signed [15:0] SAMPLE_MIN = 16'sd32768;

/* Mix and low-pass (4 fraction bits) */
wire [14:0] mix = {1'b0, ay_sound, 4'b0000} + (beeper ? BEEPER_LEVEL : 15'd0);

/* 0 .. 24560 x 16 */
reg  [18:0] lp1, lp2;
wire signed [20:0] d1 = $signed({2'b00, mix, 4'b0000}) - $signed({2'b00, lp1});
wire signed [20:0] d2 = $signed({2'b00, lp1})          - $signed({2'b00, lp2});
/* a sixteenth of the difference per step */
wire signed [20:0] s1 = d1 >>> LP_SHIFT;
wire signed [20:0] s2 = d2 >>> LP_SHIFT;

always @(posedge clk or negedge rst_n)
/* reset */
    if (!rst_n)
    begin
        lp1 <= 19'd0;
        lp2 <= 19'd0;
    end
/* one filter step per AY clock enable */
    else if (ay_cen)
    begin
        lp1 <= lp1 + s1[18:0];
        lp2 <= lp2 + s2[18:0];
    end

/* I2S edges */
reg [2:0] bclk_s;
reg [1:0] lrck_s;
/* LRCK at the last rising BCLK edge */
reg       lrck_q;

always @(posedge clk)
begin
    bclk_s <= {bclk_s[1:0], i2s_bclk};
/* the frame clock; the bit clock's edges */
    lrck_s <= {lrck_s[0], i2s_lrck};
end

wire bclk_rise = bclk_s[2:1] == 2'b01;
wire bclk_fall = bclk_s[2:1] == 2'b10;
/* first rising edge of a new word */
wire word_start = bclk_rise && lrck_s[1] != lrck_q;
/* ... of the left word */
wire frame_start = word_start && !lrck_s[1];

/* DC blocker, once per frame: hp = hp + (x - x_prev) - hp / 256 (8 fraction bits) */
wire        [14:0] x = lp2[18:4];
reg         [14:0] x_prev;
reg  signed [25:0] hp;
/* the next value, its integer part, the sample sent */
wire signed [25:0] hp_next = hp + ($signed({11'd0, x}) - $signed({11'd0, x_prev})) * HP_ONE - (hp >>> HP_SHIFT);
wire signed [17:0] hp_int  = hp[25:8];
reg  signed [15:0] sample;

/* reset */
always @(posedge clk or negedge rst_n)
    if (!rst_n)
    begin
        x_prev <= 15'd0;
/* silence; once per frame */
        hp     <= 26'sd0;
        sample <= 16'sd0;
    end
    else if (frame_start)
    begin
/* the filter step; the sample, clipped to 16 bits */
        x_prev <= x;
        hp     <= hp_next;
        sample <= hp_int >  CLIP_HI ?  SAMPLE_MAX :
                  hp_int < -CLIP_LO ? -SAMPLE_MIN : hp_int[15:0];
    end

/* Shift out: load on the first rising edge of each word, so the MSB goes out on */
/* the following falling edge (Philips: one BCLK after LRCK) */
reg [15:0] sr;

always @(posedge clk or negedge rst_n)
    if (!rst_n)
    begin
/* reset */
        lrck_q   <= 1'b0;
        sr       <= 16'd0;
        i2s_data <= 1'b0;
    end
    else
    begin
/* LRCK is sampled at the rising BCLK */
        if (bclk_rise)
        begin
            lrck_q <= lrck_s[1];
        end
        if (word_start)
        begin
/* a new word; else the next bit at the falling BCLK */
            sr <= sample;
        end
        else if (bclk_fall)
        begin
            i2s_data <= sr[15];
/* shifted */
            sr       <= {sr[14:0], 1'b0};
        end
    end

endmodule

`default_nettype wire
