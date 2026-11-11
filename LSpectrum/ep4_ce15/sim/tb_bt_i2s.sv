/* tb_bt_i2s -- bt_i2s against an ESP32-like I2S master (Philips, 44.1 kHz). */
/* */
/* 1. Transport: every received word (both channels) equals the sample the DUT */
/* loaded for it, for 16-bit and (+define+SLOT32) 32-bit slots. */
/* 2. Beeper 1 kHz square: the received swing is large and centred on 0. */
/* 3. A constant AY level: the DC blocker brings the output back to ~0. */
`timescale 1ps/1ps
`default_nettype none

module tb_bt_i2s;

/* half a period of the 112 MHz clock, ps */
localparam integer CLK_HALF_PS = 4464;
/* DDS step of the AY clock enable, as in zx_system */
localparam [32:0] AY_DDS_STEP = 33'd136016246;
/* the first two words are not compared */
localparam integer WORDS_SKIP = 2;
/* highest 16-bit sample */
localparam integer SAMPLE_MAX = 32767;
/* lowest 16-bit sample, without its sign */
localparam integer SAMPLE_MIN_ABS = 32768;
/* bits of a sample */
localparam integer WORD_BITS = 16;
/* index of a word's last bit */
localparam integer LAST_BIT = 15;
/* errors listed */
localparam integer LIST_MAX = 10;
/* AY level of the first part of the test */
localparam [9:0] AY_QUIET = 10'd300;
/* smallest swing the beeper must give */
localparam integer SWING_MIN = 7000;
/* largest mean that still counts as no DC */
localparam integer MEAN_MAX = 300;
/* AY level of the last part of the test */
localparam [9:0] AY_LOUD = 10'd1000;
/* largest sample that still counts as silence */
localparam integer SILENCE_MAX = 100;

/* the slot length of the I2S master */
`ifdef SLOT32
localparam integer SLOT = 32;
`else
/* 16 bits by default */
localparam integer SLOT = 16;
`endif
/* ps */
localparam real BCLK_HALF = 1.0e12 / (44100.0 * 2 * SLOT) / 2;

reg clk = 0, rst_n = 0;
/* 112 MHz */
always #CLK_HALF_PS clk = !clk;

reg  [31:0] ay_dds = 0;
reg         ay_cen = 0;
/* the AY's clock enable, as in zx_system */
wire [32:0] ay_next = {1'b0, ay_dds} + AY_DDS_STEP;
always @(posedge clk)
begin
    ay_dds <= ay_next[31:0];
/* the sound inputs */
    ay_cen <= ay_next[32];
end

reg  [9:0] ay_sound = 0;
reg        beeper = 0;
/* the I2S pins; the design under test */
reg        bclk = 0, lrck = 0;
wire       data;

bt_i2s dut (
    .clk(clk), .rst_n(rst_n), .ay_cen(ay_cen), .ay_sound(ay_sound), .beeper(beeper),
    .i2s_bclk(bclk), .i2s_lrck(lrck), .i2s_data(data)
);

/* I2S master: LRCK changes on the falling BCLK edge, data is read on the rising one */
integer falls = 0;
reg     run = 0;
always
begin
/* rising edge */
    #(BCLK_HALF)
        if (run)
        begin
            bclk = 1;
        end
/* falling edge */
    #(BCLK_HALF)
        if (run)
        begin
            bclk  = 0;
/* the frame clock from the bit count */
            falls = falls + 1;
            lrck  = (falls / SLOT) % WORDS_SKIP;
        end
end

/* expected words: what the DUT loads at each word start (the first falling edge, */
/* whose word has no load, is skipped by starting the queue after it) */
logic signed [15:0] expq[$];
always @(posedge clk)
    if (dut.word_start && falls >= 1)
    begin
/* what the design will send */
        expq.push_back(dut.sample);
    end

/* received words, statistics */
reg  [15:0] rx;
integer     words = 0, errors = 0;
integer     vmin, vmax;
/* sum and count; a new measurement */
real        vsum;
integer     vcnt;

/* the statistics start again */
task automatic clear_stats;
    vmin = SAMPLE_MAX;
    vmax = -SAMPLE_MIN_ABS;
/* empty */
    vsum = 0;
    vcnt = 0;
endtask

/* Word w starts at the falling edge number w*SLOT; its 16 bits are read on the */
/* rising edges after falling edges w*SLOT+1 .. w*SLOT+16 (Philips: one BCLK late, */
/* so with 16-bit slots the LSB is read in the next slot). */
always @(posedge bclk)
begin : receive
    integer b;
    logic signed [15:0] e, v;
/* the bit's place in the slot */
    b = (falls - 1) % SLOT;
    if (falls >= 1 && b < WORD_BITS)
    begin
        rx = {rx[14:0], data};
    end
/* a whole word */
    if (falls >= 1 && b == LAST_BIT)
    begin
        v = rx;
        if (expq.size() == 0)
        begin
/* a word the design did not load */
            if (words >= WORDS_SKIP)
            begin
                $display("ERROR: word without a load");
                errors++;
            end
        end
        else
        begin
/* compared with what was loaded */
            e = expq.pop_front();
            if (words >= WORDS_SKIP && v !== e)
            begin
                if (errors < LIST_MAX)
                begin
/* the first ten are listed */
                    $display("ERROR: word %0d got %0d expected %0d", words, v, e);
                end
                errors++;
            end
        end
/* statistics */
        words++;
        if (v < vmin)
        begin
            vmin = v;
        end
/* maximum, sum */
        if (v > vmax)
        begin
            vmax = v;
        end
        vsum += v;
/* count */
        vcnt++;
    end
end

/* the test */
initial
begin
    clear_stats();
    #100ns rst_n = 1;
/* the master starts */
    #1us run = 1;

/* 1+2: beeper 1 kHz with some AY, 50 ms */
    ay_sound = AY_QUIET;
    fork
        begin : beep
            forever
            begin
/* the beeper toggles every 500 us; after 20 ms the statistics start */
                #500us beeper = !beeper;
            end
        end
        #20ms clear_stats();
    join_any
    #30ms;
/* 30 ms measured */
    disable beep;
    $display("beeper 1 kHz: min %0d max %0d mean %0.1f (%0d words)", vmin, vmax, vsum / vcnt, vcnt);
    if (vmax - vmin < SWING_MIN)
    begin
/* counted; the mean must be near 0 */
        $display("ERROR: beeper swing too small");
        errors++;
    end
    if (vsum / vcnt > MEAN_MAX || vsum / vcnt < -MEAN_MAX)
    begin
/* counted */
        $display("ERROR: beeper not centred");
        errors++;
    end

/* 3: constant level: DC must decay (fc ~27 Hz -> tau ~6 ms) */
    beeper = 1;
    ay_sound = AY_LOUD;
    #60ms clear_stats();
/* 5 ms measured */
    #5ms;
    $display("constant input after 60 ms: min %0d max %0d", vmin, vmax);
    if (vmax > SILENCE_MAX || vmin < -SILENCE_MAX)
    begin
/* counted; the result */
        $display("ERROR: DC not removed");
        errors++;
    end

    $display("%0d words, %0d errors (slot %0d)", words, errors, SLOT);
/* the verdict */
    if (errors == 0)
    begin
        $display("PASS");
    end
    else
    begin
        $display("FAIL");
    end
/* the end */
    $finish;
end

endmodule

`default_nettype wire
