//=============================================================================
// sd_dac -- first-order sigma-delta DAC (1-bit output into an RC low-pass)
//
// At 112 MHz the noise is far above the audio band; the I/O board's AY output
// has 68 Ohm + 100 nF (fc ~ 23 kHz).
//=============================================================================
`default_nettype none

module sd_dac #(
    parameter integer W = 10
)(
    input  wire         clk,
    input  wire         rst_n,
    input  wire [W-1:0] din,            // unsigned
    output reg          dout
);

reg [W:0] acc;

always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
        acc  <= {(W+1){1'b0}};
        dout <= 1'b0;
    end else begin
        acc  <= {1'b0, acc[W-1:0]} + {1'b0, din};
        dout <= acc[W];
    end

endmodule

`default_nettype wire
