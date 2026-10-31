//=============================================================================
// ram_tester -- endless self-test of a 2^ADDR_BITS x 8 RAM with req/ack interface
//
// One pass = 4 phases over all bytes (ADDR_BITS = 18: 262144):
//   0: sequential write   pattern(addr, seed)
//   1: sequential verify
//   2: scrambled write    pattern(addr, ~seed)   (bit-reversed order -> row misses)
//   3: scrambled verify   (rotated order, different from phase 2)
// The seed changes every pass, so every bit is written 0 and 1 in each pass.
// The pattern depends on all address bits, so address faults are caught too.
//
// inject: a pulse corrupts bit 0 of the next written byte (checks the checker).
//=============================================================================
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

    output reg         error,         // sticky
    output reg         pass_tick,     // 1-cycle pulse per completed pass
    output reg  [15:0] pass_count,
    output reg  [ADDR_BITS-1:0] fail_addr,     // first failure
    output reg  [7:0]  fail_exp,
    output reg  [7:0]  fail_got
);

localparam integer AW = ADDR_BITS;

function [AW-1:0] bitrev(input [AW-1:0] v);
    integer k;
    for (k = 0; k < AW; k = k + 1) bitrev[k] = v[AW-1-k];
endfunction

localparam [2*AW-1:0] K_10 = {AW{2'b10}};
localparam [2*AW-1:0] K_01 = {AW{2'b01}};

// Address order per phase; each is a permutation of 0 .. 2^AW-1
function [AW-1:0] amap(input [1:0] ph, input [AW-1:0] c);
    case (ph)
        2'd2:    amap = bitrev(c) ^ K_10[AW-1:0];                   // jumps across rows/banks
        2'd3:    amap = {c[7:0], c[AW-1:8]} ^ K_01[AW-1:0];         // rotated order
        default: amap = c;
    endcase
endfunction

// Data pattern: every address bit flips at least one data bit
function [7:0] pattern(input [AW-1:0] a, input [7:0] s);
    integer k;
    begin
        pattern = s;
        for (k = 0; k < AW; k = k + 1)
            if (a[k]) pattern = pattern ^ (8'h01 << ((k * 3) % 8));
    end
endfunction

localparam [1:0] T_START = 2'd0,
                 T_ISSUE = 2'd1,
                 T_WAIT  = 2'd2;

reg  [1:0]  st;
reg  [1:0]  phase;
reg  [AW-1:0] cnt;
reg  [7:0]  seed;
reg  [7:0]  exp_d;
reg         inj_pend;

wire [AW-1:0] a_now = amap(phase, cnt);
wire [7:0]  pseed = phase[1] ? ~seed : seed;
wire [7:0]  p_now = pattern(a_now, pseed);

always @(posedge clk) begin
    req       <= 1'b0;
    pass_tick <= 1'b0;
    if (inject) inj_pend <= 1'b1;

    if (!rst_n) begin
        st         <= T_START;
        phase      <= 2'd0;
        cnt        <= {AW{1'b0}};
        seed       <= 8'h00;
        error      <= 1'b0;
        pass_count <= 16'd0;
        inj_pend   <= 1'b0;
    end else begin
        case (st)
        T_START:
            if (ram_ready) st <= T_ISSUE;

        T_ISSUE: begin
            req    <= 1'b1;
            we     <= ~phase[0];
            addr   <= a_now;
            exp_d  <= p_now;
            wdata  <= p_now;
            if (~phase[0] && (inj_pend || inject)) begin
                wdata[0] <= ~p_now[0];
                inj_pend <= 1'b0;
            end
            st <= T_WAIT;
        end

        T_WAIT:
            if (ack) begin
                if (!we && rdata != exp_d && !error) begin
                    error     <= 1'b1;
                    fail_addr <= addr;
                    fail_exp  <= exp_d;
                    fail_got  <= rdata;
                end
                cnt <= cnt + 1'b1;
                if (&cnt) begin
                    phase <= phase + 2'd1;
                    if (phase == 2'd3) begin
                        seed       <= seed + 8'h3B;
                        pass_count <= pass_count + 16'd1;
                        pass_tick  <= 1'b1;
                    end
                end
                st <= T_ISSUE;
            end

        default: st <= T_START;
        endcase
    end
end

endmodule

`default_nettype wire
