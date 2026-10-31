//=============================================================================
// flash_if -- user access to the configuration flash (W25Q64 / EPCS64) through
//             the Cyclone IV active-serial pins (DCLK, nCSO, ASDO, DATA0)
//
// The testbench replaces this module with a flash model (sim/flash_model.v).
//=============================================================================
`default_nettype none

module flash_if (
    input  wire dclk,
    input  wire ncs,
    input  wire mosi,
    output wire miso
);

cycloneive_asmiblock u_asmi (
    .dclkin   (dclk),
    .scein    (ncs),
    .sdoin    (mosi),
    .oe       (1'b0),               // active low: the design drives the AS pins
    .data0out (miso)
);

endmodule

`default_nettype wire
