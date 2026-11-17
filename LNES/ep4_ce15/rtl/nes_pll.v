/* nes_pll -- 50 MHz in, VCO 943.75 MHz (50 * 151 / 8): */
/* c0 = 21.449 MHz (VCO / 44): clk, the whole machine (the NES's master clock is 21.477 MHz: */
/* -0.13 %); 4 per PPU dot, 12 per CPU cycle. Chosen so that the NES's frame (89,341.5 dots) */
/* lasts as long as the VGA frame of 800 x 525 pixels at 25.208 MHz, within 9 ppm: the */
/* frame buffer hardly ever has to repeat or drop a frame. */
/* c1 = 85.795 MHz (VCO / 11) = 4 x c0, rising edges aligned: SDRAM controller, tape loader + */
/* ESP32 link, frame buffer, audio */
/* c2 = c1 delayed by SD_PHASE_PS, drives the SDRAM clock DDIO */
`default_nettype none

module nes_pll #(
    parameter SD_PHASE_PS = "1250"
)(
    input  wire inclk0,
    output wire c0,
    output wire c1,
    output wire c2,
    output wire locked
);

/* the five outputs of the PLL; three are used */
wire [4:0] clk_bus;
assign c0 = clk_bus[0];
assign c1 = clk_bus[1];
/* the delayed clock for the SDRAM */
assign c2 = clk_bus[2];

/* the PLL */
altpll altpll_component (
    .areset (1'b0),
    .inclk  ({1'b0, inclk0}),
    .clk    (clk_bus),
    .locked (locked)
);
defparam
    altpll_component.clk0_divide_by          = 352,
    altpll_component.clk0_duty_cycle         = 50,
    altpll_component.clk0_multiply_by        = 151,
    altpll_component.clk0_phase_shift        = "0",
    altpll_component.clk1_divide_by          = 88,
    altpll_component.clk1_duty_cycle         = 50,
    altpll_component.clk1_multiply_by        = 151,
    altpll_component.clk1_phase_shift        = "0",
    altpll_component.clk2_divide_by          = 88,
    altpll_component.clk2_duty_cycle         = 50,
    altpll_component.clk2_multiply_by        = 151,
    altpll_component.clk2_phase_shift        = SD_PHASE_PS,
    altpll_component.bandwidth_type          = "AUTO",
    altpll_component.compensate_clock        = "CLK1",
    altpll_component.inclk0_input_frequency  = 20000,
    altpll_component.intended_device_family  = "Cyclone IV E",
    altpll_component.lpm_hint                = "CBX_MODULE_PREFIX=nes_pll",
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
    altpll_component.port_clk2               = "PORT_USED",
    altpll_component.port_clk3               = "PORT_UNUSED",
    altpll_component.port_clk4               = "PORT_UNUSED",
    altpll_component.port_clk5               = "PORT_UNUSED",
    altpll_component.self_reset_on_loss_lock = "OFF",
    altpll_component.width_clock             = 5;

endmodule

`default_nettype wire
