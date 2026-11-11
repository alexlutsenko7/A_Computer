/* flash_if -- user access to the configuration flash (W25Q64 / EPCS64) through */
/* the Cyclone IV / Cyclone 10 LP active-serial pins (DCLK, nCSO, ASDO, DATA0) */
/* */
/* The testbench replaces this module with a flash model (sim/flash_model.v). */
`default_nettype none

module flash_if (
    input  wire dclk,
    input  wire ncs,
    input  wire mosi,
    output wire miso
);

/* the same block under the name each family knows (Cyclone 10 LP: the generic cyclone_asmiblock, as Quartus's own */
/* serial flash loader uses); CYCLONE10LP is defined in the 10cl025/ projects (.qsf VERILOG_MACRO) */
`ifdef CYCLONE10LP
/* the generic block (Cyclone 10 LP) */
cyclone_asmiblock u_asmi (
`else
/* the Cyclone IV E block */
cycloneive_asmiblock u_asmi (
`endif
    .dclkin   (dclk),
    .scein    (ncs),
    .sdoin    (mosi),
/* active low: the design drives the AS pins */
    .oe       (1'b0),
    .data0out (miso)
);

endmodule

`default_nettype wire
