/* ram_tester -- endless self-test of a 2^ADDR_BITS x 8 RAM with req/ack interface */
/* */
/* One pass = 4 phases over all bytes (ADDR_BITS = 18: 262144): */
/* 0: sequential write   pattern(addr, seed) */
/* 1: sequential verify */
/* 2: scrambled write    pattern(addr, ~seed)   (bit-reversed order -> row misses) */
/* 3: scrambled verify   (rotated order, different from phase 2) */
/* The seed changes every pass, so every bit is written 0 and 1 in each pass. */
/* The pattern depends on all address bits, so address faults are caught too. */
/* */
/* inject: a pulse corrupts bit 0 of the next written byte (checks the checker). */
`default_nettype none

module ram_tester #(
    parameter integer ADDR_BITS = 18
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire        ram_ready,
    output reg         req,
    output reg         we,
    output reg  [ADDR_BITS-1:0] addr,
    output reg  [7:0]  wdata,
    input  wire [7:0]  rdata,
    input  wire        ack,

    input  wire        inject,

/* sticky */
    output reg         error,
/* 1-cycle pulse per completed pass */
    output reg         pass_tick,
    output reg  [15:0] pass_count,
/* first failure */
    output reg  [ADDR_BITS-1:0] fail_addr,
    output reg  [7:0]  fail_exp,
    output reg  [7:0]  fail_got
);

/* the pattern's moving bit advances by 3 positions per pass */
localparam integer PAT_STEP = 3;
/* bits of a data byte */
localparam integer PAT_BITS = 8;
/* added to the seed after each pass (odd: all 256 seeds come up) */
localparam [7:0] SEED_STEP = 8'h3B;

localparam integer AW = ADDR_BITS;

/* the address with its bits in reverse order */
function [AW-1:0] bitrev(input [AW-1:0] v);
    integer k;
/* bit by bit */
    for (k = 0; k < AW; k = k + 1)
    begin
        bitrev[k] = v[AW-1-k];
    end
endfunction

/* alternating bit patterns as wide as two addresses */
localparam [2*AW-1:0] K_10 = {AW{2'b10}};
localparam [2*AW-1:0] K_01 = {AW{2'b01}};

/* Address order per phase; each is a permutation of 0 .. 2^AW-1 */
function [AW-1:0] amap(input [1:0] ph, input [AW-1:0] c);
    case (ph)
/* jumps across rows/banks */
        2'd2: amap = bitrev(c) ^ K_10[AW-1:0];
/* rotated order */
        2'd3: amap = {c[7:0], c[AW-1:8]} ^ K_01[AW-1:0];
        default: amap = c;
    endcase
endfunction

/* Data pattern: every address bit flips at least one data bit */
function [7:0] pattern(input [AW-1:0] a, input [7:0] s);
    integer k;
    begin
        pattern = s;
/* one data bit flipped per set address bit */
        for (k = 0; k < AW; k = k + 1)
        begin
            if (a[k])
            begin
                pattern = pattern ^ (8'h01 << ((k * PAT_STEP) % PAT_BITS));
            end
        end
    end
endfunction

/* the tester's states */
localparam [1:0] T_START = 2'd0,
                 T_ISSUE = 2'd1,
                 T_WAIT  = 2'd2;

/* state, phase (0 / 1 sequential write / verify, 2 / 3 scrambled), address counter */
reg  [1:0]  st;
reg  [1:0]  phase;
reg  [AW-1:0] cnt;
/* the pass's seed, the byte expected, an error to inject */
reg  [7:0]  seed;
reg  [7:0]  exp_d;
reg         inj_pend;

/* the address and the pattern of this step */
wire [AW-1:0] a_now = amap(phase, cnt);
wire [7:0]  pseed = phase[1] ? ~seed : seed;
wire [7:0]  p_now = pattern(a_now, pseed);

/* the test, one access after the other */
always @(posedge clk)
begin
    req       <= 1'b0;
    pass_tick <= 1'b0;
/* a key press is remembered until the next write */
    if (inject)
    begin
        inj_pend <= 1'b1;
    end

/* reset */
    if (!rst_n)
    begin
        st         <= T_START;
        phase      <= 2'd0;
/* address 0, seed 0, no error */
        cnt        <= {AW{1'b0}};
        seed       <= 8'h00;
        error      <= 1'b0;
/* no pass yet, nothing to inject */
        pass_count <= 16'd0;
        inj_pend   <= 1'b0;
    end
    else
    begin
/* the test loop */
        case (st)
            T_START:
/* wait for the RAM's initialisation */
                if (ram_ready)
                begin
                    st <= T_ISSUE;
                end

/* issue a write or a read */
            T_ISSUE:
            begin
                req    <= 1'b1;
                we     <= ~phase[0];
/* the pattern expected and written */
                addr   <= a_now;
                exp_d  <= p_now;
                wdata  <= p_now;
/* one flipped bit when an error is to be injected */
                if (~phase[0] && (inj_pend || inject))
                begin
                    wdata[0] <= ~p_now[0];
                    inj_pend <= 1'b0;
                end
/* then wait for the ack */
                st <= T_WAIT;
            end

            T_WAIT:
                if (ack)
                begin
/* a read that differs: the first failure is kept */
                    if (!we && rdata != exp_d && !error)
                    begin
                        error     <= 1'b1;
                        fail_addr <= addr;
/* what was expected, what came; the next address */
                        fail_exp  <= exp_d;
                        fail_got  <= rdata;
                    end
                    cnt <= cnt + 1'b1;
/* the last address of a phase */
                    if (&cnt)
                    begin
                        phase <= phase + 2'd1;
                        if (phase == 2'd3)
                        begin
/* a whole pass: new seed, counted, the LED's tick */
                            seed       <= seed + SEED_STEP;
                            pass_count <= pass_count + 16'd1;
                            pass_tick  <= 1'b1;
                        end
                    end
/* the next access; any other state restarts */
                    st <= T_ISSUE;
                end

            default: st <= T_START;
        endcase
    end
end

endmodule

`default_nettype wire
