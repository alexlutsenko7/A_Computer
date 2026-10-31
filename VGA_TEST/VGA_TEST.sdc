# VGA_TEST timing constraints

create_clock -name CLOCK_50 -period 20.000 [get_ports CLOCK_50]
derive_pll_clocks
derive_clock_uncertainty

set clk25 u_pll|altpll_component|auto_generated|pll1|clk[0]
set clk27 u_pll|altpll_component|auto_generated|pll1|clk[1]

# Both pixel clocks reach the video logic through the clock control block, but
# only one at a time.
set_clock_groups -physically_exclusive -group [get_clocks $clk25] -group [get_clocks $clk27]

# 50 MHz control domain -> video domain: the mode select is static while the
# video logic runs (changed only while it is held in reset), and the video
# reset is asynchronous (released through a synchroniser).
set_false_path -from [get_clocks CLOCK_50] -to [get_clocks [list $clk25 $clk27]]

# VGA outputs: the monitor samples with its own PLL locked to HSYNC, so there is
# no board-level setup/hold relation. Fast output registers keep the skew small.
set_false_path -to [get_ports {VGA_R VGA_R_LOW VGA_G VGA_G_LOW VGA_B VGA_B_LOW VGA_HSYNC VGA_VSYNC LEDR}]

# Asynchronous / slow inputs (synchronised in the design)
set_false_path -from [get_ports {RESET_N KEY1 SW_50_60 GND_TIE[*]}]
