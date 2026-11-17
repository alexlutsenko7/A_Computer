/* nes_apu -- LNES: the sound part of the NES's CPU chip (2A03, NTSC), our own design */
/* */
/* Written from the public NESdev documentation only: two pulse channels (duty, envelope, sweep, */
/* length counter), triangle (linear counter), noise (15-bit shift register), the delta sample */
/* channel (DMC, fetches its bytes from the cartridge through the system: dmc_req / dmc_ack), the */
/* frame counter (4 or 5 steps, interrupt) and the two non-linear mixers as tables. */
/* */
/* Time base: cyc is one clk per CPU cycle (its end); odd = the second CPU cycle of a sound cycle. */
/* Registers $4000-$4017: reg_we (one clk) with reg_a = the low five address bits; reg_re reads */
/* $4015 (the status, in reg_q). */
/* Output: audio, 10 bits unsigned: the pulse table (PULSE_HEX, 31 entries) + the table of */
/* triangle, noise and DMC (TND_HEX, 203 entries), both made by tools/mk_nestables.py. */
`default_nettype none

module nes_apu #(
    parameter PULSE_HEX = "nes_pulse.hex",
    parameter TND_HEX   = "nes_tnd.hex"
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        cyc,
    input  wire        odd,

    input  wire        reg_we,
    input  wire        reg_re,
    input  wire [4:0]  reg_a,
    input  wire [7:0]  reg_d,
    output wire [7:0]  reg_q,
    output wire        irq,

/* the sample channel's memory reads */
    output wire        dmc_req,
    output wire [15:0] dmc_addr,
    input  wire        dmc_ack,
    input  wire [7:0]  dmc_d,

    output reg  [9:0]  audio
);

/* register numbers (address - $4000) */
localparam [4:0] R_P2_CTL = 5'd4;
localparam [4:0] R_P2_SWEEP = 5'd5;
localparam [4:0] R_P2_LO = 5'd6;
/* the triangle's registers */
localparam [4:0] R_P2_HI = 5'd7;
localparam [4:0] R_TRI_CTL = 5'd8;
localparam [4:0] R_TRI_LO = 5'd10;
/* the triangle's period */
localparam [4:0] R_TRI_HI = 5'd11;
localparam [4:0] R_NOI_CTL = 5'd12;
localparam [4:0] R_NOI_PER = 5'd14;
/* the noise's length */
localparam [4:0] R_NOI_LEN = 5'd15;
localparam [4:0] R_DMC_CTL = 5'd16;
localparam [4:0] R_DMC_DAC = 5'd17;
/* the sample's address and length */
localparam [4:0] R_DMC_ADDR = 5'd18;
localparam [4:0] R_DMC_LEN = 5'd19;
localparam [4:0] R_STATUS = 5'd21;
/* the frame counter */
localparam [4:0] R_FRAME = 5'd23;
localparam [4:0] R_P1_LO = 5'd2;
localparam [4:0] R_P1_HI = 5'd3;
/* frame counter, in CPU cycles: the four steps, the interrupt, the two sequence lengths */
localparam [15:0] FC_STEP1 = 16'd7457;
localparam [15:0] FC_STEP2 = 16'd14913;
localparam [15:0] FC_STEP3 = 16'd22371;
/* the last step of the 4-step sequence and its length */
localparam [15:0] FC_IRQ = 16'd29828;
localparam [15:0] FC_STEP4 = 16'd29829;
localparam [15:0] FC_END4 = 16'd29830;
/* the 5-step sequence */
localparam [15:0] FC_STEP5 = 16'd37281;
localparam [15:0] FC_END5 = 16'd37282;
/* a write to $4017 restarts the sequence 3 or 4 CPU cycles later */
localparam [2:0] FC_DELAY_ODD = 3'd3;
localparam [2:0] FC_DELAY_EVEN = 3'd4;
/* envelope: the start level */
localparam [3:0] ENV_MAX = 4'd15;
/* a pulse period below this is silent */
localparam [10:0] PULSE_MIN = 11'd8;
/* DMC: output level limits for a step of 2, bits of a byte, the sample area's start */
localparam [6:0] DMC_UP_MAX = 7'd125;
localparam [6:0] DMC_DN_MIN = 7'd2;
localparam [6:0] DMC_STEP = 7'd2;
/* the sample area's bits per byte */
localparam [3:0] DMC_BITS = 4'd8;
/* weights of the triangle and the noise in the mixer table's index */
localparam integer TRI_WEIGHT = 3;
localparam integer NOI_WEIGHT = 2;
/* pulse channels */
localparam integer PULSES = 2;

/* length counter values, by the five bits written */
function [7:0] len_val(input [4:0] n);
    case (n)
        5'd0:  len_val = 8'd10;
/* values 0-2 */
        5'd1:  len_val = 8'd254;
        5'd2:  len_val = 8'd20;
        5'd3:  len_val = 8'd2;
/* values 4-6 */
        5'd4:  len_val = 8'd40;
        5'd5:  len_val = 8'd4;
        5'd6:  len_val = 8'd80;
/* values 7-9 */
        5'd7:  len_val = 8'd6;
        5'd8:  len_val = 8'd160;
        5'd9:  len_val = 8'd8;
/* values 10-12 */
        5'd10: len_val = 8'd60;
        5'd11: len_val = 8'd10;
        5'd12: len_val = 8'd14;
/* values 13-15 */
        5'd13: len_val = 8'd12;
        5'd14: len_val = 8'd26;
        5'd15: len_val = 8'd14;
/* values 16-18 */
        5'd16: len_val = 8'd12;
        5'd17: len_val = 8'd16;
        5'd18: len_val = 8'd24;
/* values 19-21 */
        5'd19: len_val = 8'd18;
        5'd20: len_val = 8'd48;
        5'd21: len_val = 8'd20;
/* values 22-24 */
        5'd22: len_val = 8'd96;
        5'd23: len_val = 8'd22;
        5'd24: len_val = 8'd192;
/* values 25-27 */
        5'd25: len_val = 8'd24;
        5'd26: len_val = 8'd72;
        5'd27: len_val = 8'd26;
/* values 28-30 */
        5'd28: len_val = 8'd16;
        5'd29: len_val = 8'd28;
        5'd30: len_val = 8'd32;
/* value 31 */
        default: len_val = 8'd30;
    endcase
endfunction

/* noise periods in CPU cycles, less one (NTSC) */
function [11:0] noi_per(input [3:0] n);
    case (n)
        4'd0:  noi_per = 12'd3;
/* periods 0-2 */
        4'd1:  noi_per = 12'd7;
        4'd2:  noi_per = 12'd15;
        4'd3:  noi_per = 12'd31;
/* periods 4-6 */
        4'd4:  noi_per = 12'd63;
        4'd5:  noi_per = 12'd95;
        4'd6:  noi_per = 12'd127;
/* periods 7-9 */
        4'd7:  noi_per = 12'd159;
        4'd8:  noi_per = 12'd201;
        4'd9:  noi_per = 12'd253;
/* periods 10-12 */
        4'd10: noi_per = 12'd379;
        4'd11: noi_per = 12'd507;
        4'd12: noi_per = 12'd761;
/* periods 13-15 */
        4'd13: noi_per = 12'd1015;
        4'd14: noi_per = 12'd2033;
        default: noi_per = 12'd4067;
    endcase
endfunction

/* DMC bit periods in CPU cycles, less one (NTSC) */
function [8:0] dmc_per(input [3:0] n);
    case (n)
        4'd0:  dmc_per = 9'd427;
/* periods 0-2 */
        4'd1:  dmc_per = 9'd379;
        4'd2:  dmc_per = 9'd339;
        4'd3:  dmc_per = 9'd319;
/* periods 4-6 */
        4'd4:  dmc_per = 9'd285;
        4'd5:  dmc_per = 9'd253;
        4'd6:  dmc_per = 9'd225;
/* periods 7-9 */
        4'd7:  dmc_per = 9'd213;
        4'd8:  dmc_per = 9'd189;
        4'd9:  dmc_per = 9'd159;
/* periods 10-12 */
        4'd10: dmc_per = 9'd141;
        4'd11: dmc_per = 9'd127;
        4'd12: dmc_per = 9'd105;
/* periods 13-15 */
        4'd13: dmc_per = 9'd83;
        4'd14: dmc_per = 9'd71;
        default: dmc_per = 9'd53;
    endcase
endfunction

/* the eight steps of a pulse, by duty */
function duty_bit(input [1:0] d, input [2:0] s);
    case (d)
        2'b00: duty_bit = s == 3'b111;
/* a quarter and a half */
        2'b01: duty_bit = s[2:1] == 2'b11;
        2'b10: duty_bit = s[2];
        default: duty_bit = s[2:1] != 2'b11;
    endcase
endfunction

/* a loop counter */
integer k;

/* Frame counter */
reg  [15:0] fc;
reg         fc_mode, fc_inh, frame_irq;
reg  [2:0]  fc_rst;
/* restart at once (5-step mode) */
reg         fc_now;
/* the quarter and half frame clocks of this CPU cycle */
wire        st1 = fc == FC_STEP1;
wire        st2 = fc == FC_STEP2;
wire        st3 = fc == FC_STEP3;
/* the last step and the end of the sequence in use */
wire        st4 = fc == (fc_mode ? FC_STEP5 : FC_STEP4);
wire        fc_wrap = fc == (fc_mode ? FC_END5 : FC_END4);
wire        qf  = cyc && (st1 || st2 || st3 || st4 || fc_now);
/* the half frame clock */
wire        hf  = cyc && (st2 || st4 || fc_now);

/* Pulse channels (index 0 and 1) */
reg  [1:0]  p_duty  [0:1];
reg         p_halt  [0:1];
reg         p_const [0:1];
/* the sweep unit */
reg  [3:0]  p_vol   [0:1];
reg         p_sw_en [0:1];
reg  [2:0]  p_sw_p  [0:1];
/* the sweep: direction, shift, reload, divider */
reg         p_sw_neg [0:1];
reg  [2:0]  p_sw_sh [0:1];
reg         p_sw_rl [0:1];
/* the period and the timer */
reg  [2:0]  p_sw_div [0:1];
reg  [10:0] p_per   [0:1];
reg  [10:0] p_tmr   [0:1];
/* the duty step, the length counter */
reg  [2:0]  p_seq   [0:1];
reg  [7:0]  p_len   [0:1];
reg         p_start [0:1];
/* the envelope's divider and level */
reg  [3:0]  p_div   [0:1];
reg  [3:0]  p_decay [0:1];
reg  [1:0]  p_en;

/* the sweep's target period (pulse 1 subtracts one more) and the channel's output */
reg  [11:0] p_tgt   [0:1];
reg         p_mute  [0:1];
reg  [3:0]  p_out   [0:1];
/* the period's change, as a scratch value */
reg  [10:0] p_delta;
always @*
begin
    for (k = 0; k < PULSES; k = k + 1)
    begin
/* how much the sweep moves the period */
        p_delta   = p_per[k] >> p_sw_sh[k];
        p_tgt[k]  = p_sw_neg[k] ? {1'b0, p_per[k]} - {1'b0, p_delta} - (k == 0 ? 12'd1 : 12'd0) :
                                  {1'b0, p_per[k]} + {1'b0, p_delta};
        p_mute[k] = p_per[k] < PULSE_MIN || (!p_sw_neg[k] && p_tgt[k][11]);
/* the level while the duty step is high */
        p_out[k]  = (duty_bit(p_duty[k], p_seq[k]) && p_len[k] != 8'd0 && !p_mute[k]) ?
                    (p_const[k] ? p_vol[k] : p_decay[k]) : 4'd0;
    end
end

/* Triangle */
reg         t_ctrl;
reg  [6:0]  t_lin_rl, t_lin;
reg         t_rl_flag;
/* its timer and its 32 steps */
reg  [10:0] t_per, t_tmr;
reg  [4:0]  t_seq;
reg  [7:0]  t_len;
/* the channel is on */
reg         t_en;
wire [3:0]  t_out = t_seq[4] ? t_seq[3:0] : ~t_seq[3:0];

/* Noise */
reg         n_halt, n_const, n_mode, n_start, n_en;
reg  [3:0]  n_vol, n_per, n_div, n_decay;
reg  [11:0] n_tmr;
/* the shift register and the length counter */
reg  [14:0] n_lfsr;
reg  [7:0]  n_len;
wire        n_fb  = n_lfsr[0] ^ (n_mode ? n_lfsr[6] : n_lfsr[1]);
/* its level */
wire [3:0]  n_out = (!n_lfsr[0] && n_len != 8'd0) ? (n_const ? n_vol : n_decay) : 4'd0;

/* DMC */
reg         d_irq_en, d_loop, d_irq, d_full, d_silence;
reg  [3:0]  d_rate;
reg  [6:0]  d_level;
/* its registers and buffers */
reg  [7:0]  d_areg, d_lreg, d_buf, d_shift;
reg  [14:0] d_addr;
reg  [11:0] d_rem;
/* its bit timer and bit counter */
reg  [8:0]  d_tmr;
reg  [3:0]  d_bits;
assign dmc_req  = !d_full && d_rem != 12'd0;
/* the sample's address in the cartridge */
assign dmc_addr = {1'b1, d_addr};

assign irq   = frame_irq || d_irq;
assign reg_q = {d_irq, frame_irq, 1'b0, d_rem != 12'd0, n_len != 8'd0, t_len != 8'd0,
                p_len[1] != 8'd0, p_len[0] != 8'd0};

/* Mixer tables */
reg  [9:0] pulse_tab [0:31];
reg  [9:0] tnd_tab   [0:255];
initial $readmemh(PULSE_HEX, pulse_tab);
/* the mixer's pipeline */
initial $readmemh(TND_HEX, tnd_tab);
reg  [4:0] mix_p;
reg  [7:0] mix_t;
/* the tables' outputs */
reg  [9:0] mix_pq, mix_tq;
always @(posedge clk)
begin
    mix_p  <= {1'b0, p_out[0]} + {1'b0, p_out[1]};
/* the index of the second table */
    mix_t  <= TRI_WEIGHT * {4'd0, t_out} + NOI_WEIGHT * {4'd0, n_out} + {1'b0, d_level};
/* the tables, then their sum */
    mix_pq <= pulse_tab[mix_p];
    mix_tq <= tnd_tab[mix_t];
    audio  <= mix_pq + mix_tq;
end

/* which pulse channel a register belongs to */
wire        ch = reg_a[2];

always @(posedge clk or negedge rst_n)
    if (!rst_n)
    begin
/* at reset: the frame counter */
        fc <= 16'd0;
        fc_mode <= 1'b0;
        fc_inh <= 1'b0;
/* no interrupt */
        frame_irq <= 1'b0;
        fc_rst <= 3'd0;
        fc_now <= 1'b0;
/* the pulse channels */
        for (k = 0; k < PULSES; k = k + 1)
        begin
            p_duty[k] <= 2'd0;
            p_halt[k] <= 1'b0;
/* its volume and sweep */
            p_const[k] <= 1'b0;
            p_vol[k] <= 4'd0;
            p_sw_en[k] <= 1'b0;
/* the sweep */
            p_sw_p[k] <= 3'd0;
            p_sw_neg[k] <= 1'b0;
            p_sw_sh[k] <= 3'd0;
/* the sweep's reload flag and divider */
            p_sw_rl[k] <= 1'b0;
            p_sw_div[k] <= 3'd0;
            p_per[k] <= 11'd0;
/* the timer, the duty step */
            p_tmr[k] <= 11'd0;
            p_seq[k] <= 3'd0;
            p_len[k] <= 8'd0;
/* the envelope */
            p_start[k] <= 1'b0;
            p_div[k] <= 4'd0;
            p_decay[k] <= 4'd0;
        end
/* both channels off */
        p_en <= 2'b00;
/* the triangle */
        t_ctrl <= 1'b0;
        t_lin_rl <= 7'd0;
        t_lin <= 7'd0;
/* its timer */
        t_rl_flag <= 1'b0;
        t_per <= 11'd0;
        t_tmr <= 11'd0;
/* the 32 steps */
        t_seq <= 5'd0;
        t_len <= 8'd0;
        t_en <= 1'b0;
/* the noise */
        n_halt <= 1'b0;
        n_const <= 1'b0;
        n_mode <= 1'b0;
/* its envelope */
        n_start <= 1'b0;
        n_en <= 1'b0;
        n_vol <= 4'd0;
/* its period */
        n_per <= 4'd0;
        n_div <= 4'd0;
        n_decay <= 4'd0;
/* its timer */
        n_tmr <= 12'd0;
        n_lfsr <= 15'd1;
        n_len <= 8'd0;
/* the sample channel */
        d_irq_en <= 1'b0;
        d_loop <= 1'b0;
        d_irq <= 1'b0;
/* no sample */
        d_full <= 1'b0;
        d_silence <= 1'b1;
        d_rate <= 4'd0;
/* the level */
        d_level <= 7'd0;
        d_areg <= 8'd0;
        d_lreg <= 8'd0;
/* its buffers */
        d_buf <= 8'd0;
        d_shift <= 8'd0;
        d_addr <= 15'd0;
/* nothing to play */
        d_rem <= 12'd0;
        d_tmr <= 9'd0;
        d_bits <= DMC_BITS;
    end
    else
    begin
/* ---- once per CPU cycle ---- */
        if (cyc)
        begin
            fc_now <= 1'b0;
/* the frame counter, restarted a few cycles after a write to $4017 */
            if (fc_rst != 3'd0)
            begin
                fc_rst <= fc_rst - 3'd1;
                if (fc_rst == 3'd1)
                begin
/* the sequence starts again */
                    fc     <= 16'd0;
                    fc_now <= fc_mode;
                end
                else
                begin
                    fc <= fc + 16'd1;
                end
            end
/* the sequence ends */
            else if (fc_wrap)
            begin
                fc <= 16'd0;
            end
            else
            begin
                fc <= fc + 16'd1;
            end
/* the interrupt of the 4-step sequence */
            if (!fc_mode && !fc_inh && fc >= FC_IRQ)
            begin
                frame_irq <= 1'b1;
            end

/* pulse timers run at half the CPU clock */
            if (odd)
            begin
                for (k = 0; k < PULSES; k = k + 1)
                begin
                    if (p_tmr[k] == 11'd0)
                    begin
/* the next step of the duty sequence */
                        p_tmr[k] <= p_per[k];
                        p_seq[k] <= p_seq[k] + 3'd1;
                    end
                    else
                    begin
                        p_tmr[k] <= p_tmr[k] - 11'd1;
                    end
                end
            end
/* triangle: steps only while both counters run */
            if (t_tmr == 11'd0)
            begin
                t_tmr <= t_per;
                if (t_len != 8'd0 && t_lin != 7'd0)
                begin
/* the next of the 32 steps */
                    t_seq <= t_seq + 5'd1;
                end
            end
            else
            begin
                t_tmr <= t_tmr - 11'd1;
            end
/* noise */
            if (n_tmr == 12'd0)
            begin
                n_tmr  <= noi_per(n_per);
                n_lfsr <= {n_fb, n_lfsr[14:1]};
            end
            else
            begin
/* the timer counts */
                n_tmr <= n_tmr - 12'd1;
            end
/* DMC: one bit per period moves the level by 2 */
            if (d_tmr == 9'd0)
            begin
                d_tmr <= dmc_per(d_rate);
                if (!d_silence)
                begin
/* a 1 bit: up, a 0 bit: down */
                    if (d_shift[0] && d_level <= DMC_UP_MAX)
                    begin
                        d_level <= d_level + DMC_STEP;
                    end
                    if (!d_shift[0] && d_level >= DMC_DN_MIN)
                    begin
/* down */
                        d_level <= d_level - DMC_STEP;
                    end
                end
                d_shift <= {1'b0, d_shift[7:1]};
/* a byte is done: the next one from the buffer */
                if (d_bits == 4'd1)
                begin
                    d_bits    <= DMC_BITS;
                    d_silence <= !d_full;
/* the next byte */
                    if (d_full)
                    begin
                        d_shift <= d_buf;
                        d_full  <= 1'b0;
                    end
                end
                else
                begin
/* the next bit */
                    d_bits <= d_bits - 4'd1;
                end
            end
            else
            begin
                d_tmr <= d_tmr - 9'd1;
            end
        end

/* ---- quarter frame: envelopes and the linear counter ---- */
        if (qf)
        begin
            for (k = 0; k < PULSES; k = k + 1)
            begin
                if (p_start[k])
                begin
/* the envelope starts again */
                    p_start[k] <= 1'b0;
                    p_decay[k] <= ENV_MAX;
                    p_div[k]   <= p_vol[k];
                end
/* the divider counts */
                else if (p_div[k] != 4'd0)
                begin
                    p_div[k] <= p_div[k] - 4'd1;
                end
                else
                begin
                    p_div[k] <= p_vol[k];
/* the level falls, or starts again when looping */
                    if (p_decay[k] != 4'd0)
                    begin
                        p_decay[k] <= p_decay[k] - 4'd1;
                    end
                    else if (p_halt[k])
                    begin
/* the level starts again */
                        p_decay[k] <= ENV_MAX;
                    end
                end
            end
/* the noise's envelope */
            if (n_start)
            begin
                n_start <= 1'b0;
                n_decay <= ENV_MAX;
/* its divider */
                n_div   <= n_vol;
            end
            else if (n_div != 4'd0)
            begin
                n_div <= n_div - 4'd1;
            end
            else
            begin
/* the divider starts again */
                n_div <= n_vol;
                if (n_decay != 4'd0)
                begin
                    n_decay <= n_decay - 4'd1;
                end
/* the level starts again when looping */
                else if (n_halt)
                begin
                    n_decay <= ENV_MAX;
                end
            end
/* the triangle's linear counter */
            if (t_rl_flag)
            begin
                t_lin <= t_lin_rl;
            end
            else if (t_lin != 7'd0)
            begin
/* the linear counter counts down */
                t_lin <= t_lin - 7'd1;
            end
            if (!t_ctrl)
            begin
                t_rl_flag <= 1'b0;
            end
        end

/* ---- half frame: length counters and sweeps ---- */
        if (hf)
        begin
            for (k = 0; k < PULSES; k = k + 1)
            begin
                if (!p_halt[k] && p_len[k] != 8'd0)
                begin
/* the length counter counts down */
                    p_len[k] <= p_len[k] - 8'd1;
                end
/* the sweep moves the period */
                if (p_sw_div[k] == 3'd0 && p_sw_en[k] && p_sw_sh[k] != 3'd0 && !p_mute[k])
                begin
                    p_per[k] <= p_tgt[k][10:0];
                end
                if (p_sw_div[k] == 3'd0 || p_sw_rl[k])
                begin
/* the divider starts again */
                    p_sw_div[k] <= p_sw_p[k];
                    p_sw_rl[k]  <= 1'b0;
                end
                else
                begin
                    p_sw_div[k] <= p_sw_div[k] - 3'd1;
                end
            end
/* the length counters */
            if (!t_ctrl && t_len != 8'd0)
            begin
                t_len <= t_len - 8'd1;
            end
            if (!n_halt && n_len != 8'd0)
            begin
/* the noise's */
                n_len <= n_len - 8'd1;
            end
        end

/* ---- the DMC got its byte ---- */
        if (dmc_ack)
        begin
            d_buf  <= dmc_d;
            d_full <= 1'b1;
/* the next address */
            d_addr <= d_addr + 15'd1;
/* the last byte: start again or stop (and interrupt) */
            if (d_rem == 12'd1 && d_loop)
            begin
                d_addr <= {1'b1, d_areg, 6'd0};
                d_rem  <= {d_lreg, 4'd1};
            end
            else
            begin
/* one byte less */
                d_rem <= d_rem - 12'd1;
                if (d_rem == 12'd1 && d_irq_en)
                begin
                    d_irq <= 1'b1;
                end
            end
        end

/* ---- the status read clears the frame interrupt ---- */
        if (reg_re && reg_a == R_STATUS)
        begin
            frame_irq <= 1'b0;
        end

/* ---- register writes ---- */
        if (reg_we)
        begin
            case (reg_a)
                5'd0, R_P2_CTL:
                begin
/* duty, envelope, volume */
                    p_duty[ch]  <= reg_d[7:6];
                    p_halt[ch]  <= reg_d[5];
                    p_const[ch] <= reg_d[4];
/* the volume */
                    p_vol[ch]   <= reg_d[3:0];
                end
                5'd1, R_P2_SWEEP:
                begin
                    p_sw_en[ch]  <= reg_d[7];
/* period, direction, shift */
                    p_sw_p[ch]   <= reg_d[6:4];
                    p_sw_neg[ch] <= reg_d[3];
                    p_sw_sh[ch]  <= reg_d[2:0];
/* the divider is loaded at the next half frame */
                    p_sw_rl[ch]  <= 1'b1;
                end
                R_P1_LO, R_P2_LO: p_per[ch][7:0] <= reg_d;
/* the high bits restart the pulse and its envelope */
                R_P1_HI, R_P2_HI:
                begin
                    p_per[ch][10:8] <= reg_d[2:0];
                    p_seq[ch]       <= 3'd0;
/* the envelope starts again */
                    p_start[ch]     <= 1'b1;
                    if (p_en[ch])
                    begin
                        p_len[ch] <= len_val(reg_d[7:3]);
                    end
                end
/* the triangle: control and linear counter value */
                R_TRI_CTL:
                begin
                    t_ctrl   <= reg_d[7];
                    t_lin_rl <= reg_d[6:0];
                end
/* its period's low bits */
                R_TRI_LO: t_per[7:0] <= reg_d;
                R_TRI_HI:
                begin
                    t_per[10:8] <= reg_d[2:0];
/* the linear counter is loaded at the next quarter frame */
                    t_rl_flag   <= 1'b1;
                    if (t_en)
                    begin
                        t_len <= len_val(reg_d[7:3]);
                    end
                end
/* the noise: envelope and volume */
                R_NOI_CTL:
                begin
                    n_halt  <= reg_d[5];
                    n_const <= reg_d[4];
/* its volume */
                    n_vol   <= reg_d[3:0];
                end
                R_NOI_PER:
                begin
                    n_mode <= reg_d[7];
/* its period */
                    n_per  <= reg_d[3:0];
                end
                R_NOI_LEN:
                begin
                    n_start <= 1'b1;
/* its length counter */
                    if (n_en)
                    begin
                        n_len <= len_val(reg_d[7:3]);
                    end
                end
                R_DMC_CTL:
                begin
/* the sample: interrupt, loop, rate */
                    d_irq_en <= reg_d[7];
                    d_loop   <= reg_d[6];
                    d_rate   <= reg_d[3:0];
/* interrupt off: the flag goes */
                    if (!reg_d[7])
                    begin
                        d_irq <= 1'b0;
                    end
                end
                R_DMC_DAC:  d_level <= reg_d[6:0];
/* address and length */
                R_DMC_ADDR: d_areg  <= reg_d;
                R_DMC_LEN:  d_lreg  <= reg_d;
/* channel enables: a disabled channel's length counter is cleared */
                R_STATUS:
                begin
                    p_en <= reg_d[1:0];
                    t_en <= reg_d[2];
/* the noise channel */
                    n_en <= reg_d[3];
                    if (!reg_d[0])
                    begin
                        p_len[0] <= 8'd0;
                    end
/* the second pulse */
                    if (!reg_d[1])
                    begin
                        p_len[1] <= 8'd0;
                    end
                    if (!reg_d[2])
                    begin
/* the triangle */
                        t_len <= 8'd0;
                    end
                    if (!reg_d[3])
                    begin
                        n_len <= 8'd0;
                    end
/* the sample: stopped, or started when it is not playing */
                    d_irq <= 1'b0;
                    if (!reg_d[4])
                    begin
                        d_rem <= 12'd0;
                    end
/* the sample starts again */
                    else if (d_rem == 12'd0)
                    begin
                        d_addr <= {1'b1, d_areg, 6'd0};
                        d_rem  <= {d_lreg, 4'd1};
                    end
                end
/* the frame counter: mode and interrupt inhibit */
                R_FRAME:
                begin
                    fc_mode <= reg_d[7];
                    fc_inh  <= reg_d[6];
/* restarted a few cycles later */
                    fc_rst  <= odd ? FC_DELAY_ODD : FC_DELAY_EVEN;
                    if (reg_d[6])
                    begin
                        frame_irq <= 1'b0;
                    end
                end
/* the other addresses have no register */
                default: ;
            endcase
        end
    end

endmodule

`default_nettype wire
