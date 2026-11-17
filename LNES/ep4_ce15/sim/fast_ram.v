/* fast_ram -- simulation only: a plain memory with the ports of sdram_ram (the SDRAM pins idle), */
/* for long LNES runs (tb_nes +define+FAST, clk_sd = 2 x clk): an access is acknowledged two */
/* clocks after its request. The SDRAM timing itself is covered by the runs without FAST. */
`timescale 1ns/1ps

module sdram_ram #(
    parameter integer ADDR_BITS   = 22,
    parameter integer CLK_MHZ     = 86,
    parameter integer CAS_LATENCY = 2,
    parameter integer RD_CAPTURE  = 3
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        req,
    input  wire        we,
    input  wire [ADDR_BITS-1:0] addr,
    input  wire [7:0]  din,
    input  wire        wide,
    input  wire [7:0]  din_hi,
    output wire [7:0]  dout,
    output wire [15:0] dout_w,
    output reg         ack,
    output reg         ready,
    output wire        sd_cke,
    output wire        sd_cs_n,
    output wire        sd_ras_n,
    output wire        sd_cas_n,
    output wire        sd_we_n,
    output wire [1:0]  sd_ba,
    output wire [12:0] sd_a,
    output wire [1:0]  sd_dqm,
    output wire [15:0] sd_dq_o,
    output wire        sd_dq_oe,
    input  wire [15:0] sd_dq_i
);

/* the memory, in 16-bit words */
reg [15:0] mem [0:(1 << (ADDR_BITS - 1)) - 1];
reg [15:0] q;
reg        pend;
/* the memory itself */
integer    n;
initial
begin
    for (n = 0; n < (1 << (ADDR_BITS - 1)); n = n + 1)
    begin
/* all zeros */
        mem[n] = 16'd0;
    end
end

assign dout_w = q;
assign dout   = addr[0] ? q[15:8] : q[7:0];
/* the pins do nothing */
assign {sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n} = 5'b01111;
assign sd_ba = 2'b00;
assign sd_a = 13'd0;
/* both data masks high, nothing driven */
assign sd_dqm = 2'b11;
assign sd_dq_o = 16'd0;
assign sd_dq_oe = 1'b0;

/* the access: requested, acknowledged two clocks later */
always @(posedge clk or negedge rst_n)
    if (!rst_n)
    begin
        ack   <= 1'b0;
/* nothing pending */
        pend  <= 1'b0;
        ready <= 1'b0;
        q     <= 16'd0;
    end
    else
    begin
/* ready at once */
        ready <= 1'b1;
        ack   <= pend;
        pend  <= req;
/* the access itself, with the acknowledge */
        if (pend)
        begin
            if (!we)
            begin
                q <= mem[addr[ADDR_BITS-1:1]];
            end
/* a word */
            else if (wide)
            begin
                mem[addr[ADDR_BITS-1:1]] <= {din_hi, din};
            end
            else if (addr[0])
            begin
/* the high byte */
                mem[addr[ADDR_BITS-1:1]][15:8] <= din;
            end
            else
            begin
                mem[addr[ADDR_BITS-1:1]][7:0] <= din;
            end
        end
    end

endmodule
