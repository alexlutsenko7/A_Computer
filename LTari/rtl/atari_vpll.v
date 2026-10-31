// atari_vpll -- 50 MHz in, VCO 756.25 MHz (as LSpectrum's vga_pll):
//               c0 = 27.009 MHz (50 * 121 / 224): VGA pixel clock, 720 x 576 @ 50 Hz (576p, 50.017 Hz)
//               c1 = 25.208 MHz (50 * 121 / 240): VGA pixel clock, 640 x 480 @ 60 Hz (60.02 Hz)
//               (to the clock switch vga_clkmux, which needs both from one PLL)
`default_nettype none

module atari_vpll (
    input  wire inclk0,
    output wire c0,
    output wire c1,
    output wire locked
);

wire [4:0] clk_bus;
assign c0 = clk_bus[0];
assign c1 = clk_bus[1];

altpll altpll_component (
    .areset (1'b0),
    .inclk  ({1'b0, inclk0}),
    .clk    (clk_bus),
    .locked (locked)
);
defparam
    altpll_component.clk0_divide_by          = 224,
    altpll_component.clk0_duty_cycle         = 50,
    altpll_component.clk0_multiply_by        = 121,
    altpll_component.clk0_phase_shift        = "0",
    altpll_component.clk1_divide_by          = 240,
    altpll_component.clk1_duty_cycle         = 50,
    altpll_component.clk1_multiply_by        = 121,
    altpll_component.clk1_phase_shift        = "0",
    altpll_component.bandwidth_type          = "AUTO",
    altpll_component.compensate_clock        = "CLK1",
    altpll_component.inclk0_input_frequency  = 20000,
    altpll_component.intended_device_family  = "Cyclone IV E",
    altpll_component.lpm_hint                = "CBX_MODULE_PREFIX=atari_vpll",
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
    altpll_component.port_clk1               = "PORT_USED",
    altpll_component.port_clk2               = "PORT_UNUSED",
    altpll_component.port_clk3               = "PORT_UNUSED",
    altpll_component.port_clk4               = "PORT_UNUSED",
    altpll_component.port_clk5               = "PORT_UNUSED",
    altpll_component.self_reset_on_loss_lock = "OFF",
    altpll_component.width_clock             = 5;

endmodule

`default_nettype wire
