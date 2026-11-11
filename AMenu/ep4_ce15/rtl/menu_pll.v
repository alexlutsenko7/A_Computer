/* menu_pll -- 50 MHz in: c0 = 75 MHz (50 * 3 / 2) for the ESP32 link and the loader registers */
/* (tape_loader / esp_link need >= 3 clocks per half period of the 8 MHz SPI clock) */
`default_nettype none

module menu_pll (
    input  wire inclk0,
    output wire c0,
    output wire locked
);

/* the five outputs of the PLL; one is used */
wire [4:0] clk_bus;
assign c0 = clk_bus[0];

/* the PLL: 50 MHz x 3 / 2 = 75 MHz */
altpll altpll_component (
    .areset (1'b0),
    .inclk  ({1'b0, inclk0}),
    .clk    (clk_bus),
    .locked (locked)
);
defparam
    altpll_component.clk0_divide_by          = 2,
    altpll_component.clk0_duty_cycle         = 50,
    altpll_component.clk0_multiply_by        = 3,
    altpll_component.clk0_phase_shift        = "0",
    altpll_component.bandwidth_type          = "AUTO",
    altpll_component.compensate_clock        = "CLK0",
    altpll_component.inclk0_input_frequency  = 20000,
    altpll_component.intended_device_family  = "Cyclone IV E",
    altpll_component.lpm_hint                = "CBX_MODULE_PREFIX=menu_pll",
    altpll_component.lpm_type                = "altpll",
    altpll_component.operation_mode          = "NORMAL",
    altpll_component.pll_type                = "AUTO",
    altpll_component.port_activeclock        = "PORT_UNUSED",
    altpll_component.port_areset             = "PORT_USED",
    altpll_component.port_clkbad0            = "PORT_UNUSED",
    altpll_component.port_clkbad1            = "PORT_UNUSED",
    altpll_component.port_clkloss            = "PORT_UNUSED",
    altpll_component.port_clkswitch          = "PORT_UNUSED",
    altpll_component.port_configupdate       = "PORT_UNUSED",
    altpll_component.port_fbin               = "PORT_UNUSED",
    altpll_component.port_inclk0             = "PORT_USED",
    altpll_component.port_inclk1             = "PORT_UNUSED",
    altpll_component.port_locked             = "PORT_USED",
    altpll_component.port_pfdena             = "PORT_UNUSED",
    altpll_component.port_phasecounterselect = "PORT_UNUSED",
    altpll_component.port_phasedone          = "PORT_UNUSED",
    altpll_component.port_phasestep          = "PORT_UNUSED",
    altpll_component.port_phaseupdown        = "PORT_UNUSED",
    altpll_component.port_pllena             = "PORT_UNUSED",
    altpll_component.port_scanaclr           = "PORT_UNUSED",
    altpll_component.port_scanclk            = "PORT_UNUSED",
    altpll_component.port_scanclkena         = "PORT_UNUSED",
    altpll_component.port_scandata           = "PORT_UNUSED",
    altpll_component.port_scandataout        = "PORT_UNUSED",
    altpll_component.port_scandone           = "PORT_UNUSED",
    altpll_component.port_scanread           = "PORT_UNUSED",
    altpll_component.port_scanwrite          = "PORT_UNUSED",
    altpll_component.port_clk0               = "PORT_USED",
    altpll_component.port_clk1               = "PORT_UNUSED",
    altpll_component.port_clk2               = "PORT_UNUSED",
    altpll_component.port_clk3               = "PORT_UNUSED",
    altpll_component.port_clk4               = "PORT_UNUSED",
    altpll_component.port_clk5               = "PORT_UNUSED",
    altpll_component.self_reset_on_loss_lock = "OFF",
    altpll_component.width_clock             = 5;

endmodule

`default_nettype wire
