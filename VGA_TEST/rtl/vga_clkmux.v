//=============================================================================
// vga_clkmux -- Cyclone IV global clock control block: dynamic select between
//               two PLL outputs, with clock enable (glitch-free gating on the
//               falling edge of the output clock).
//
// Switch safely: ena = 0, wait a few clocks, change sel, wait, ena = 1
// (sequenced by the caller from a clock that always runs).
//=============================================================================
`default_nettype none

module vga_clkmux (
    input  wire clk0,       // PLL c0, selected when sel = 0
    input  wire clk1,       // PLL c1, selected when sel = 1
    input  wire sel,
    input  wire ena,
    output wire outclk
);

// inclk[3:2] are the PLL-output inputs of the clock control block
altclkctrl #(
    .clock_type             ("Global Clock"),
    .ena_register_mode      ("falling edge"),
    .intended_device_family ("Cyclone IV E"),
    .number_of_clocks       (4),
    .width_clkselect        (2),
    .lpm_type               ("altclkctrl")
) u_clkctrl (
    .inclk     ({clk1, clk0, 1'b0, 1'b0}),
    .clkselect ({1'b1, sel}),
    .ena       (ena),
    .outclk    (outclk)
);

endmodule

`default_nettype wire
