//=============================================================================
// pokey -- POKEY: timers / audio, IRQs, keyboard, RANDOM, serial port
//
// Written from the Altirra Hardware Reference Manual (ch. 5; LTari/NOTES.md).
// cyc_end = one machine cycle (1.773 MHz); everything here steps once per cycle.
//
// Timers: AUDF1-4 count down on their clock (machine clock for 1 / 3 with AUDCTL 6 / 5,
// else 64 kHz (/28) or 15 kHz (/114) by AUDCTL 0; 2 / 4 from 1 / 3 when linked, AUDCTL 4
// / 3). Period N+4 cycles (machine clock, 8-bit) or N+7 (linked), (N+1) ticks on the
// slow clocks; a timer fires 3 cycles after its underflow (the reload delay).
// IRQST reads 0 for a pending interrupt (IRQ line = any); bit 3 (serial output idle)
// is live, not latched.
// Serial: SKCTL 6:4 selects the clocks (NOTES.md / table 10); a clock pulse per timer
// underflow, one bit per two pulses. Output: SEROUT -> shift register at the next
// output clock (start, 8 data LSB first, stop). Input: asynchronous (timer 3+4 held until
// the start bit) when SKCTL 4 is set, sampled in the middle of each bit.
// Audio: 4 channels, square / poly-4 / poly-5 / poly-9/17 / volume only, high-pass
// 1 <- 3 and 2 <- 4; out = sum of the active volumes (0-60).
//=============================================================================
`default_nettype none

module pokey (
    input  wire        clk,
    input  wire        rst_n,           // power-up only (POKEY has no reset pin)
    input  wire        cyc_end,

    input  wire        reg_we,
    input  wire        reg_re,          // a CPU read (one strobe per read cycle)
    input  wire [3:0]  reg_a,
    input  wire [7:0]  reg_d,
    output reg  [7:0]  reg_q,
    output wire        irq,

    // keyboard (from the keyboard interface, clk domain)
    input  wire        key_stb,         // a new key press: code / shift / ctrl valid
    input  wire [5:0]  key_code,
    input  wire        key_down,        // a key is held
    input  wire        key_shift,
    input  wire        key_ctrl,
    input  wire        key_break,       // Break pressed (one strobe)

    // SIO
    output reg         sio_out,         // data out (1 = mark)
    input  wire        sio_in,          // data in
    output reg         so_stb,          // a byte goes into the output shift register (one clk)
    output reg  [7:0]  so_byte,         // that byte (the SIO bridge's copy for the ESP32)

    output reg  [5:0]  audio
);

reg  [7:0] audf [1:4];
reg  [7:0] audc [1:4];
reg  [7:0] audctl, skctl, irqen;
reg  [7:0] irq_p;                       // pending (1 = pending), bit 3 unused here
reg  [7:0] kbcode, serin;
reg        sk_ovr, sk_frm, sk_kbd, sk_shift;

wire       init = skctl[1:0] == 2'b00;
wire [2:0] skm = skctl[6:4];
wire       async_in = skm[0];           // 001, 011, 101, 111: channel 3+4 asynchronous

//-----------------------------------------------------------------------------
// Base clocks and polynomial counters
//-----------------------------------------------------------------------------
reg  [6:0] c15;
reg  [4:0] c64;
wire       t15 = c15 == 7'd113;
wire       t64 = c64 == 5'd27;
reg  [3:0] p4;
reg  [4:0] p5;
reg  [16:0] p17;

always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
        c15 <= 7'd0; c64 <= 5'd0; p4 <= 4'd0; p5 <= 5'd0; p17 <= 17'd0;
    end else if (cyc_end) begin
        if (init) begin
            c15 <= 7'd0; c64 <= 5'd0; p4 <= 4'd0; p5 <= 5'd0; p17 <= 17'd0;
        end else begin
            c15 <= t15 ? 7'd0 : c15 + 7'd1;
            c64 <= t64 ? 5'd0 : c64 + 5'd1;
            p4  <= {p4[2:0], ~(p4[3] ^ p4[2])};                       // 1 + x3 + x4 (XNOR)
            p5  <= {p5[3:0], ~(p5[4] ^ p5[2])};                       // 1 + x3 + x5
            if (audctl[7]) p17[8:0] <= {~(p17[0] ^ p17[4]), p17[8:1]};  // 9-bit: 1 + x4 + x9
            else           p17 <= {~(p17[0] ^ p17[5]), p17[16:1]};      // 17-bit: 1 + x12 + x17
        end
    end

//-----------------------------------------------------------------------------
// Timers
//-----------------------------------------------------------------------------
reg  [7:0] cnt [1:4];
reg  [3:0] fire;                        // timer fired (pulse, one cycle), bit 0 = timer 1
reg  [2:0] dly [1:4];                   // reload delay after an underflow
reg        stimer;
wire       base = audctl[0] ? t15 : t64;
wire       link12 = audctl[4], link34 = audctl[3];
reg        uf1, uf3;                    // low timer underflow (clocks the linked high timer)
reg        hold34;                      // asynchronous receive: timers 3+4 held

always @(posedge clk or negedge rst_n)
    if (!rst_n) begin : trst
        integer i;
        for (i = 1; i <= 4; i = i + 1) begin cnt[i] <= 8'd0; dly[i] <= 3'd0; end
        fire <= 4'd0; uf1 <= 1'b0; uf3 <= 1'b0;
    end else if (cyc_end) begin : tim
        integer i;
        reg [3:0] tk;
        fire <= 4'd0;
        tk[0] = audctl[6] ? 1'b1 : base;
        tk[1] = link12 ? uf1 : base;
        tk[2] = audctl[5] ? 1'b1 : base;
        tk[3] = link34 ? uf3 : base;
        uf1 <= 1'b0; uf3 <= 1'b0;
        if (stimer) begin
            for (i = 1; i <= 4; i = i + 1) begin cnt[i] <= audf[i]; dly[i] <= 3'd0; end
        end else begin
            for (i = 1; i <= 4; i = i + 1) begin
                if ((i == 3 || i == 4) && hold34 && async_in) begin
                    cnt[i] <= audf[i]; dly[i] <= 3'd0;
                end else if (dly[i] != 3'd0) begin
                    dly[i] <= dly[i] - 3'd1;
                    if (dly[i] == 3'd1) begin
                        fire[i - 1] <= 1'b1;
                        // a linked low timer is reloaded only with its high timer
                        if (!((i == 1 && link12) || (i == 3 && link34))) cnt[i] <= audf[i];
                        if (i == 2 && link12) cnt[1] <= audf[1];
                        if (i == 4 && link34) cnt[3] <= audf[3];
                    end
                end else if (tk[i - 1]) begin
                    if (cnt[i] == 8'd0) begin
                        if (i == 1) uf1 <= 1'b1;
                        if (i == 3) uf3 <= 1'b1;
                        if ((i == 1 && link12) || (i == 3 && link34)) begin
                            cnt[i] <= 8'hFF;                      // linked low timer: wraps, fires
                            fire[i - 1] <= 1'b1;
                        end else
                            dly[i] <= ((i == 2 && link12) || (i == 4 && link34)) ? 3'd6 :
                                      ((i == 1 && audctl[6]) || (i == 3 && audctl[5])) ? 3'd3 : 3'd1;
                    end else
                        cnt[i] <= cnt[i] - 8'd1;
                end
            end
        end
    end

//-----------------------------------------------------------------------------
// Serial port
//-----------------------------------------------------------------------------
// output clock source: 0 none (external), 1 timer 4, 2 timer 2
wire [1:0] oclk_src = (skm == 3'b010 || skm == 3'b100 || skm == 3'b011 || skm == 3'b101) ? 2'd1 :
                      (skm == 3'b110 || skm == 3'b111) ? 2'd2 : 2'd0;
wire       iclk_t4  = skm == 3'b010 || skm == 3'b110 || async_in;
reg        oph, iph;                    // divide-by-two of the clocks
reg  [9:0] osh;                         // output shift register (bit 0 next), 0 = idle
reg  [3:0] obits;
reg  [7:0] serout;
reg        serout_full;
reg  [9:0] ish;
reg  [3:0] ibits;
reg        irun;                        // receiving a byte
reg        sio_in_d;
reg        serout_wr;                   // SEROUT written (one clk)
wire       o_idle = obits == 4'd0;

always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
        oph <= 1'b0; iph <= 1'b0; osh <= 10'd0; obits <= 4'd0; serout_full <= 1'b0;
        ish <= 10'd0; ibits <= 4'd0; irun <= 1'b0; sio_in_d <= 1'b1; sio_out <= 1'b1;
        hold34 <= 1'b0; so_stb <= 1'b0; so_byte <= 8'd0;
    end else begin
      so_stb <= 1'b0;
      if (serout_wr) serout_full <= 1'b1;
      if (cyc_end) begin
        sio_in_d <= sio_in;
        if (init) begin
            obits <= 4'd0; serout_full <= 1'b0; ibits <= 4'd0; irun <= 1'b0;
            hold34 <= async_in;
        end else begin
            // output: a bit per two pulses of the output clock
            if ((oclk_src == 2'd1 && fire[3]) || (oclk_src == 2'd2 && fire[1])) begin
                oph <= !oph;
                if (!oph) begin
                    if (obits != 4'd0) begin
                        sio_out <= osh[0];
                        osh     <= {1'b1, osh[9:1]};
                        obits   <= obits - 4'd1;
                    end else if (serout_full) begin
                        osh         <= {1'b1, serout, 1'b0};
                        obits       <= 4'd10;
                        serout_full <= 1'b0;
                        so_stb      <= 1'b1;
                        so_byte     <= serout;
                    end
                end
            end
            // input (asynchronous: timers 3+4 run from the start bit)
            if (async_in && !irun) begin
                hold34 <= 1'b1;
                if (sio_in_d && !sio_in) begin hold34 <= 1'b0; irun <= 1'b1; ibits <= 4'd0; iph <= 1'b0; end
            end
            if (iclk_t4 && fire[3] && (irun || !async_in)) begin
                iph <= !iph;
                if (!iph) begin                                  // sample (middle of the bit)
                    if (!irun && !sio_in) begin irun <= 1'b1; ibits <= 4'd1; ish <= {1'b0, ish[9:1]}; end
                    else if (irun) begin
                        ish   <= {sio_in, ish[9:1]};
                        ibits <= ibits + 4'd1;
                        if (ibits == 4'd9) begin irun <= 1'b0; hold34 <= async_in; end
                    end
                end
            end
        end
      end
    end

//-----------------------------------------------------------------------------
// Registers, IRQs, keyboard
//-----------------------------------------------------------------------------
wire [7:0] irqst = ~{irq_p[7:4], o_idle, irq_p[2:0]};
assign irq = |(irq_p & {irqen[7:4], 1'b0, irqen[2:0]}) || (o_idle && irqen[3]);

always @* begin
    case (reg_a)
        4'h0, 4'h1, 4'h2, 4'h3, 4'h4, 4'h5, 4'h6, 4'h7: reg_q = 8'hE4;   // POT (no paddles)
        4'h8:    reg_q = 8'h00;                                          // ALLPOT
        4'h9:    reg_q = kbcode;
        4'hA:    reg_q = init ? 8'hFF : ~p17[7:0];
        4'hD:    reg_q = serin;
        4'hE:    reg_q = irqst;
        4'hF:    reg_q = {!sk_frm, 1'b1, !sk_ovr, sio_in, sk_shift, sk_kbd, !irun, 1'b1};
        default: reg_q = 8'hFF;
    endcase
end

reg ibyte_d;
always @(posedge clk or negedge rst_n)
    if (!rst_n) begin : rrst
        integer i;
        for (i = 1; i <= 4; i = i + 1) begin audf[i] <= 8'd0; audc[i] <= 8'd0; end
        audctl <= 8'd0; skctl <= 8'd0; irqen <= 8'd0; irq_p <= 8'd0;
        kbcode <= 8'hFF; serin <= 8'd0; serout <= 8'd0;
        sk_ovr <= 1'b0; sk_frm <= 1'b0; sk_kbd <= 1'b1; sk_shift <= 1'b1;
        stimer <= 1'b0; ibyte_d <= 1'b0; serout_wr <= 1'b0;
    end else begin
        if (cyc_end) stimer <= 1'b0;
        if (reg_we)
            case (reg_a)
                4'h0, 4'h2, 4'h4, 4'h6: audf[{1'b0, reg_a[2:1]} + 3'd1] <= reg_d;
                4'h1, 4'h3, 4'h5, 4'h7: audc[{1'b0, reg_a[2:1]} + 3'd1] <= reg_d;
                4'h8: audctl <= reg_d;
                4'h9: stimer <= 1'b1;
                4'hA: begin sk_ovr <= 1'b0; sk_frm <= 1'b0; end      // SKRES
                4'hD: serout <= reg_d;
                4'hE: begin irqen <= reg_d; irq_p <= irq_p & reg_d; end
                4'hF: skctl <= reg_d;
                default: ;
            endcase
        if (cyc_end) begin
            // timers 1, 2, 4
            if (fire[0] && irqen[0]) irq_p[0] <= 1'b1;
            if (fire[1] && irqen[1]) irq_p[1] <= 1'b1;
            if (fire[3] && irqen[2]) irq_p[2] <= 1'b1;
            // serial output: SEROUT taken into the shift register
            if (obits == 4'd0 && serout_full && ((oclk_src == 2'd1 && fire[3]) || (oclk_src == 2'd2 && fire[1])) && !oph
                && irqen[4]) irq_p[4] <= 1'b1;
            // serial input: a byte complete
            ibyte_d <= irun;
            if (ibyte_d && !irun) begin
                serin <= ish[8:1];
                sk_frm <= sk_frm | !ish[9];
                if (irqen[5]) begin
                    if (irq_p[5]) sk_ovr <= 1'b1;
                    irq_p[5] <= 1'b1;
                end
            end
        end
        // keyboard
        sk_kbd   <= !key_down;
        sk_shift <= !key_shift;
        if (key_stb && !init && skctl[1]) begin
            kbcode <= {key_ctrl, key_shift, key_code};
            if (irqen[6]) irq_p[6] <= 1'b1;
        end
        if (key_break && irqen[7]) irq_p[7] <= 1'b1;
        serout_wr <= reg_we && reg_a == 4'hD;
    end

//-----------------------------------------------------------------------------
// Audio
//-----------------------------------------------------------------------------
reg  [3:0] ch;                          // channel flip-flops (output level)
reg  [1:0] hp;                          // high-pass flip-flops (1, 2)
always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
        ch <= 4'b0000; hp <= 2'b11; audio <= 6'd0;
    end else if (cyc_end) begin : aud
        integer i;
        reg [3:0] o;
        reg [6:0] sum;
        for (i = 1; i <= 4; i = i + 1)
            if (stimer) ch[i - 1] <= 1'b1;
            else if (fire[i - 1] && (audc[i][7] || p5[0])) begin           // poly-5 masks the pulses
                if (audc[i][5])      ch[i - 1] <= !ch[i - 1];               // square
                else if (audc[i][6]) ch[i - 1] <= p4[0];                    // poly-4
                else                 ch[i - 1] <= p17[0];                   // poly-9/17
            end
        // high-pass: channel 3 / 4 clocks the flip-flop that samples channel 1 / 2
        if (audctl[2]) begin if (fire[2]) hp[0] <= ch[0]; end else hp[0] <= 1'b1;
        if (audctl[1]) begin if (fire[3]) hp[1] <= ch[1]; end else hp[1] <= 1'b1;
        o[0] = audc[1][4] ? 1'b1 : ch[0] ^ hp[0] ^ !audctl[2];
        o[1] = audc[2][4] ? 1'b1 : ch[1] ^ hp[1] ^ !audctl[1];
        o[2] = audc[3][4] ? 1'b1 : ch[2];
        o[3] = audc[4][4] ? 1'b1 : ch[3];
        sum = 7'd0;
        for (i = 1; i <= 4; i = i + 1) if (o[i - 1]) sum = sum + {3'd0, audc[i][3:0]};
        audio <= sum[5:0] | {6{sum[6]}};
    end

endmodule

`default_nettype wire
