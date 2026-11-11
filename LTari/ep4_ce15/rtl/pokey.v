/* pokey -- POKEY: timers / audio, IRQs, keyboard, RANDOM, serial port */
/* */
/* Written from the Altirra Hardware Reference Manual (ch. 5; LTari/ep4_ce15/NOTES.md). */
/* cyc_end = one machine cycle (1.773 MHz); everything here steps once per cycle. */
/* */
/* Timers: AUDF1-4 count down on their clock (machine clock for 1 / 3 with AUDCTL 6 / 5, */
/* else 64 kHz (/28) or 15 kHz (/114) by AUDCTL 0; 2 / 4 from 1 / 3 when linked, AUDCTL 4 */
/* / 3). Period N+4 cycles (machine clock, 8-bit) or N+7 (linked), (N+1) ticks on the */
/* slow clocks; a timer fires 3 cycles after its underflow (the reload delay). */
/* IRQST reads 0 for a pending interrupt (IRQ line = any); bit 3 (serial output idle) */
/* is live, not latched. */
/* Serial: SKCTL 6:4 selects the clocks (NOTES.md / table 10); a clock pulse per timer */
/* underflow, one bit per two pulses. Output: SEROUT -> shift register at the next */
/* output clock (start, 8 data LSB first, stop). Input: asynchronous (timer 3+4 held until */
/* the start bit) when SKCTL 4 is set, sampled in the middle of each bit. */
/* Audio: 4 channels, square / poly-4 / poly-5 / poly-9/17 / volume only, high-pass */
/* 1 <- 3 and 2 <- 4; out = sum of the active volumes (0-60). */
`default_nettype none

module pokey (
    input  wire        clk,
/* power-up only (POKEY has no reset pin) */
    input  wire        rst_n,
    input  wire        cyc_end,

    input  wire        reg_we,
/* a CPU read (one strobe per read cycle) */
    input  wire        reg_re,
    input  wire [3:0]  reg_a,
    input  wire [7:0]  reg_d,
    output reg  [7:0]  reg_q,
    output wire        irq,

/* keyboard (from the keyboard interface, clk domain) */
/* a new key press: code / shift / ctrl valid */
    input  wire        key_stb,
    input  wire [5:0]  key_code,
/* a key is held */
    input  wire        key_down,
    input  wire        key_shift,
    input  wire        key_ctrl,
/* Break pressed (one strobe) */
    input  wire        key_break,

/* SIO */
/* data out (1 = mark) */
    output reg         sio_out,
/* data in */
    input  wire        sio_in,
/* a byte goes into the output shift register (one clk) */
    output reg         so_stb,
/* that byte (the SIO bridge's copy for the ESP32) */
    output reg  [7:0]  so_byte,

    output reg  [5:0]  audio
);

/* the 15 kHz base clock: one tick per 114 cycles */
localparam [6:0] DIV15_LAST = 7'd113;
/* the 64 kHz base clock: one tick per 28 cycles */
localparam [4:0] DIV64_LAST = 5'd27;
/* timers / audio channels (numbered 1 to 4) */
localparam integer CHANNELS = 4;
/* channel 3 (the low timer of the pair 3+4) */
localparam integer CH3 = 3;
/* channel 2 (the high timer of the pair 1+2) */
localparam integer CH2 = 2;
/* cycles from underflow to the pulse: high timer of a linked pair */
localparam [2:0] DLY_LINKED_HI = 3'd6;
/* cycles from underflow to the pulse: timer on the 1.79 MHz clock */
localparam [2:0] DLY_FAST = 3'd3;
/* serial output clock source: timer 2 */
localparam [1:0] OCLK_TIMER2 = 2'd2;
/* bits of a byte sent: start, 8 data, stop */
localparam [3:0] OUT_BITS = 4'd10;
/* bit count before the stop bit of a byte received */
localparam [3:0] IN_LAST = 4'd9;
/* register 0A read: RANDOM */
localparam [3:0] REG_RANDOM = 4'hA;
/* register 0D write: SEROUT */
localparam [3:0] REG_SEROUT = 4'hD;
/* bits of the audio output */
localparam integer AUDIO_BITS = 6;

reg  [7:0] audf [1:4];
reg  [7:0] audc [1:4];
/* the control registers */
reg  [7:0] audctl, skctl, irqen;
/* pending (1 = pending), bit 3 unused here */
reg  [7:0] irq_p;
reg  [7:0] kbcode, serin;
reg        sk_ovr, sk_frm, sk_kbd, sk_shift;

/* the initialisation state; the serial mode */
wire       init = skctl[1:0] == 2'b00;
wire [2:0] skm = skctl[6:4];
/* 001, 011, 101, 111: channel 3+4 asynchronous */
wire       async_in = skm[0];

/* Base clocks and polynomial counters */
reg  [6:0] c15;
reg  [4:0] c64;
wire       t15 = c15 == DIV15_LAST;
/* the 64 kHz tick; the polynomial counters */
wire       t64 = c64 == DIV64_LAST;
reg  [3:0] p4;
reg  [4:0] p5;
/* 17 (or 9) bits */
reg  [16:0] p17;

always @(posedge clk or negedge rst_n)
    if (!rst_n)
    begin
/* at reset */
        c15 <= 7'd0;
        c64 <= 5'd0;
        p4 <= 4'd0;
/* the polynomial counters */
        p5 <= 5'd0;
        p17 <= 17'd0;
    end
    else if (cyc_end)
    begin
/* held during initialisation */
        if (init)
        begin
            c15 <= 7'd0;
            c64 <= 5'd0;
/* the polynomial counters */
            p4 <= 4'd0;
            p5 <= 5'd0;
            p17 <= 17'd0;
        end
        else
        begin
/* the dividers */
            c15 <= t15 ? 7'd0 : c15 + 7'd1;
            c64 <= t64 ? 5'd0 : c64 + 5'd1;
/* 1 + x3 + x4 (XNOR) */
            p4  <= {p4[2:0], ~(p4[3] ^ p4[2])};
/* 1 + x3 + x5 */
            p5  <= {p5[3:0], ~(p5[4] ^ p5[2])};
/* 9-bit: 1 + x4 + x9 */
            if (audctl[7])
            begin
                p17[8:0] <= {~(p17[0] ^ p17[4]), p17[8:1]};
            end
/* 17-bit: 1 + x12 + x17 */
            else
            begin
                p17 <= {~(p17[0] ^ p17[5]), p17[16:1]};
            end
        end
    end

/* Timers */
reg  [7:0] cnt [1:4];
/* timer fired (pulse, one cycle), bit 0 = timer 1 */
reg  [3:0] fire;
/* reload delay after an underflow */
reg  [2:0] dly [1:4];
reg        stimer;
wire       base = audctl[0] ? t15 : t64;
/* timers linked to 16 bits */
wire       link12 = audctl[4], link34 = audctl[3];
/* low timer underflow (clocks the linked high timer) */
reg        uf1, uf3;
/* asynchronous receive: timers 3+4 held */
reg        hold34;

always @(posedge clk or negedge rst_n)
    if (!rst_n)
    begin : trst
/* loop index; at reset */
        integer i;
        for (i = 1; i <= CHANNELS; i = i + 1)
        begin
            cnt[i] <= 8'd0;
/* no delay, no pulse */
            dly[i] <= 3'd0;
        end
        fire <= 4'd0;
        uf1 <= 1'b0;
/* no underflow */
        uf3 <= 1'b0;
    end
    else if (cyc_end)
    begin : tim
        integer i;
/* the clock of each timer this cycle */
        reg [3:0] tk;
        fire <= 4'd0;
        tk[0] = audctl[6] ? 1'b1 : base;
/* base clock, 1.79 MHz or the low timer's underflow */
        tk[1] = link12 ? uf1 : base;
        tk[2] = audctl[5] ? 1'b1 : base;
        tk[3] = link34 ? uf3 : base;
/* no underflow by default */
        uf1 <= 1'b0;
        uf3 <= 1'b0;
        if (stimer)
        begin
/* STIMER: every timer reloads */
            for (i = 1; i <= CHANNELS; i = i + 1)
            begin
                cnt[i] <= audf[i];
                dly[i] <= 3'd0;
            end
        end
        else
        begin
/* every timer */
            for (i = 1; i <= CHANNELS; i = i + 1)
            begin
                if ((i == CH3 || i == CHANNELS) && hold34 && async_in)
                begin
                    cnt[i] <= audf[i];
/* no pulse pending */
                    dly[i] <= 3'd0;
                end
                else if (dly[i] != 3'd0)
                begin
                    dly[i] <= dly[i] - 3'd1;
/* the pulse comes at the end of the delay */
                    if (dly[i] == 3'd1)
                    begin
                        fire[i - 1] <= 1'b1;
/* a linked low timer is reloaded only with its high timer */
                        if (!((i == 1 && link12) || (i == CH3 && link34)))
                        begin
                            cnt[i] <= audf[i];
                        end
                        if (i == CH2 && link12)
                        begin
/* the low timer of channels 1+2 */
                            cnt[1] <= audf[1];
                        end
                        if (i == CHANNELS && link34)
                        begin
                            cnt[3] <= audf[3];
                        end
                    end
                end
/* a clock of this timer */
                else if (tk[i - 1])
                begin
                    if (cnt[i] == 8'd0)
                    begin
                        if (i == 1)
                        begin
/* the low timers' underflow */
                            uf1 <= 1'b1;
                        end
                        if (i == CH3)
                        begin
                            uf3 <= 1'b1;
                        end
/* a linked low timer */
                        if ((i == 1 && link12) || (i == CH3 && link34))
                        begin
/* linked low timer: wraps, fires */
                            cnt[i] <= 8'hFF;
                            fire[i - 1] <= 1'b1;
                        end
                        else
                        begin
                            dly[i] <= ((i == CH2 && link12) || (i == CHANNELS && link34)) ? DLY_LINKED_HI :
                                      ((i == 1 && audctl[6]) || (i == CH3 && audctl[5])) ? DLY_FAST : 3'd1;
                        end
                    end
                    else
                    begin
/* one down */
                        cnt[i] <= cnt[i] - 8'd1;
                    end
                end
            end
        end
    end

/* Serial port */
/* output clock source: 0 none (external), 1 timer 4, 2 timer 2 */
wire [1:0] oclk_src = (skm == 3'b010 || skm == 3'b100 || skm == 3'b011 || skm == 3'b101) ? 2'd1 :
                      (skm == 3'b110 || skm == 3'b111) ? OCLK_TIMER2 : 2'd0;
wire       iclk_t4  = skm == 3'b010 || skm == 3'b110 || async_in;
/* divide-by-two of the clocks */
reg        oph, iph;
/* output shift register (bit 0 next), 0 = idle */
reg  [9:0] osh;
reg  [3:0] obits;
reg  [7:0] serout;
/* output register full; the input shift register */
reg        serout_full;
reg  [9:0] ish;
reg  [3:0] ibits;
/* receiving a byte */
reg        irun;
reg        sio_in_d;
/* SEROUT written (one clk) */
reg        serout_wr;
wire       o_idle = obits == 4'd0;

always @(posedge clk or negedge rst_n)
/* at reset */
    if (!rst_n)
    begin
        oph <= 1'b0;
        iph <= 1'b0;
/* the output side */
        osh <= 10'd0;
        obits <= 4'd0;
        serout_full <= 1'b0;
/* the input side */
        ish <= 10'd0;
        ibits <= 4'd0;
        irun <= 1'b0;
/* the lines idle */
        sio_in_d <= 1'b1;
        sio_out <= 1'b1;
        hold34 <= 1'b0;
/* no byte for the bridge */
        so_stb <= 1'b0;
        so_byte <= 8'd0;
    end
    else
    begin
        so_stb <= 1'b0;
/* a byte was written to SEROUT */
        if (serout_wr)
        begin
            serout_full <= 1'b1;
        end
        if (cyc_end)
        begin
/* the input line as seen last */
            sio_in_d <= sio_in;
            if (init)
            begin
                obits <= 4'd0;
/* both directions idle */
                serout_full <= 1'b0;
                ibits <= 4'd0;
                irun <= 1'b0;
/* timers 3+4 wait for a start bit */
                hold34 <= async_in;
            end
            else
            begin
/* output: a bit per two pulses of the output clock */
                if ((oclk_src == 2'd1 && fire[3]) || (oclk_src == OCLK_TIMER2 && fire[1]))
                begin
                    oph <= !oph;
                    if (!oph)
                    begin
/* a bit goes out */
                        if (obits != 4'd0)
                        begin
                            sio_out <= osh[0];
                            osh     <= {1'b1, osh[9:1]};
/* counted; the next byte is loaded */
                            obits   <= obits - 4'd1;
                        end
                        else if (serout_full)
                        begin
                            osh         <= {1'b1, serout, 1'b0};
/* ten bits; the register is free */
                            obits       <= OUT_BITS;
                            serout_full <= 1'b0;
                            so_stb      <= 1'b1;
/* the byte for the SIO bridge */
                            so_byte     <= serout;
                        end
                    end
                end
/* input (asynchronous: timers 3+4 run from the start bit) */
                if (async_in && !irun)
                begin
                    hold34 <= 1'b1;
                    if (sio_in_d && !sio_in)
                    begin
/* the timers run */
                        hold34 <= 1'b0;
                        irun <= 1'b1;
                        ibits <= 4'd0;
/* the bit phase starts */
                        iph <= 1'b0;
                    end
                end
                if (iclk_t4 && fire[3] && (irun || !async_in))
                begin
                    iph <= !iph;
/* sample (middle of the bit) */
                    if (!iph)
                    begin
                        if (!irun && !sio_in)
                        begin
                            irun <= 1'b1;
/* the first bit */
                            ibits <= 4'd1;
                            ish <= {1'b0, ish[9:1]};
                        end
                        else if (irun)
                        begin
/* a bit comes in */
                            ish   <= {sio_in, ish[9:1]};
                            ibits <= ibits + 4'd1;
                            if (ibits == IN_LAST)
                            begin
/* the byte is complete */
                                irun <= 1'b0;
                                hold34 <= async_in;
                            end
                        end
                    end
                end
            end
        end
    end

/* Registers, IRQs, keyboard */
wire [7:0] irqst = ~{irq_p[7:4], o_idle, irq_p[2:0]};
assign irq = |(irq_p & {irqen[7:4], 1'b0, irqen[2:0]}) || (o_idle && irqen[3]);

always @*
begin
/* the register read */
    case (reg_a)
/* POT (no paddles) */
        4'h0, 4'h1, 4'h2, 4'h3, 4'h4, 4'h5, 4'h6, 4'h7: reg_q = 8'hE4;
/* ALLPOT */
        4'h8: reg_q = 8'h00;
        4'h9: reg_q = kbcode;
        REG_RANDOM: reg_q = init ? 8'hFF : ~p17[7:0];
/* serial input, interrupt status, serial status */
        4'hD: reg_q = serin;
        4'hE: reg_q = irqst;
        4'hF: reg_q = {!sk_frm, 1'b1, !sk_ovr, sio_in, sk_shift, sk_kbd, !irun, 1'b1};
/* the others read FF */
        default: reg_q = 8'hFF;
    endcase
end

reg ibyte_d;
always @(posedge clk or negedge rst_n)
/* at reset */
    if (!rst_n)
    begin : rrst
        integer i;
        for (i = 1; i <= CHANNELS; i = i + 1)
        begin
/* frequencies and controls */
            audf[i] <= 8'd0;
            audc[i] <= 8'd0;
        end
        audctl <= 8'd0;
/* control registers, interrupts */
        skctl <= 8'd0;
        irqen <= 8'd0;
        irq_p <= 8'd0;
/* keyboard and serial registers */
        kbcode <= 8'hFF;
        serin <= 8'd0;
        serout <= 8'd0;
/* status flags (active low in the register) */
        sk_ovr <= 1'b0;
        sk_frm <= 1'b0;
        sk_kbd <= 1'b1;
/* no STIMER, no byte */
        sk_shift <= 1'b1;
        stimer <= 1'b0;
        ibyte_d <= 1'b0;
/* no write to SEROUT */
        serout_wr <= 1'b0;
    end
    else
    begin
        if (cyc_end)
        begin
            stimer <= 1'b0;
        end
/* a register write */
        if (reg_we)
        begin
            case (reg_a)
                4'h0, 4'h2, 4'h4, 4'h6: audf[{1'b0, reg_a[2:1]} + 3'd1] <= reg_d;
/* controls; AUDCTL; STIMER */
                4'h1, 4'h3, 4'h5, 4'h7: audc[{1'b0, reg_a[2:1]} + 3'd1] <= reg_d;
                4'h8: audctl <= reg_d;
                4'h9: stimer <= 1'b1;
/* SKRES */
                4'hA:
                begin
                    sk_ovr <= 1'b0;
                    sk_frm <= 1'b0;
                end
/* the byte to send; the interrupt enables */
                4'hD: serout <= reg_d;
                4'hE:
                begin
                    irqen <= reg_d;
/* a disabled interrupt is cleared; SKCTL */
                    irq_p <= irq_p & reg_d;
                end
                4'hF: skctl <= reg_d;
                default: ;
            endcase
        end
/* the interrupt sources */
        if (cyc_end)
        begin
/* timers 1, 2, 4 */
            if (fire[0] && irqen[0])
            begin
                irq_p[0] <= 1'b1;
            end
            if (fire[1] && irqen[1])
            begin
/* timer 2; timer 4 */
                irq_p[1] <= 1'b1;
            end
            if (fire[3] && irqen[2])
            begin
                irq_p[2] <= 1'b1;
            end
/* serial output: SEROUT taken into the shift register */
            if (obits == 4'd0 && serout_full && ((oclk_src == 2'd1 && fire[3]) || (oclk_src == OCLK_TIMER2 && fire[1])) && !oph
                && irqen[4])
            begin
                irq_p[4] <= 1'b1;
            end
/* serial input: a byte complete */
            ibyte_d <= irun;
            if (ibyte_d && !irun)
            begin
                serin <= ish[8:1];
/* a framing error */
                sk_frm <= sk_frm | !ish[9];
                if (irqen[5])
                begin
                    if (irq_p[5])
                    begin
/* an overrun; the interrupt */
                        sk_ovr <= 1'b1;
                    end
                    irq_p[5] <= 1'b1;
                end
            end
        end
/* keyboard */
        sk_kbd   <= !key_down;
        sk_shift <= !key_shift;
        if (key_stb && !init && skctl[1])
        begin
/* the key code */
            kbcode <= {key_ctrl, key_shift, key_code};
            if (irqen[6])
            begin
                irq_p[6] <= 1'b1;
            end
        end
/* Break */
        if (key_break && irqen[7])
        begin
            irq_p[7] <= 1'b1;
        end
        serout_wr <= reg_we && reg_a == REG_SEROUT;
    end

/* Audio */
/* channel flip-flops (output level) */
reg  [3:0] ch;
/* high-pass flip-flops (1, 2) */
reg  [1:0] hp;
always @(posedge clk or negedge rst_n)
    if (!rst_n)
    begin
/* at reset */
        ch <= 4'b0000;
        hp <= 2'b11;
        audio <= 6'd0;
    end
/* the audio channels */
    else if (cyc_end)
    begin : aud
        integer i;
        reg [3:0] o;
/* the sum; every channel */
        reg [6:0] sum;
        for (i = 1; i <= CHANNELS; i = i + 1)
        begin
            if (stimer)
            begin
/* STIMER sets the outputs */
                ch[i - 1] <= 1'b1;
            end
/* poly-5 masks the pulses */
            else if (fire[i - 1] && (audc[i][7] || p5[0]))
            begin
/* square */
                if (audc[i][5])
                begin
                    ch[i - 1] <= !ch[i - 1];
                end
/* poly-4 */
                else if (audc[i][6])
                begin
                    ch[i - 1] <= p4[0];
                end
/* poly-9/17 */
                else
                begin
                    ch[i - 1] <= p17[0];
                end
            end
        end
/* high-pass: channel 3 / 4 clocks the flip-flop that samples channel 1 / 2 */
        if (audctl[2])
        begin
            if (fire[2])
            begin
                hp[0] <= ch[0];
            end
        end
        else
        begin
/* no high-pass */
            hp[0] <= 1'b1;
        end
        if (audctl[1])
        begin
            if (fire[3])
            begin
/* sampled by timer 4 */
                hp[1] <= ch[1];
            end
        end
        else
        begin
            hp[1] <= 1'b1;
        end
        o[0] = audc[1][4] ? 1'b1 : ch[0] ^ hp[0] ^ !audctl[2];
/* volume-only channels are on */
        o[1] = audc[2][4] ? 1'b1 : ch[1] ^ hp[1] ^ !audctl[1];
        o[2] = audc[3][4] ? 1'b1 : ch[2];
        o[3] = audc[4][4] ? 1'b1 : ch[3];
/* the volumes of the channels that are on */
        sum = 7'd0;
        for (i = 1; i <= CHANNELS; i = i + 1)
        begin
            if (o[i - 1])
            begin
/* the sum, limited to 6 bits */
                sum = sum + {3'd0, audc[i][3:0]};
            end
        end
        audio <= sum[5:0] | {AUDIO_BITS{sum[6]}};
    end

endmodule

`default_nettype wire
