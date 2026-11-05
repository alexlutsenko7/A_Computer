# first_light -- timing constraints

# The one clock that comes from outside: the 50 MHz oscillator (20 ns period)
create_clock -name CLOCK_50 -period 20.000 [get_ports CLOCK_50]

# The PLL's output clocks, worked out from its settings
derive_pll_clocks
derive_clock_uncertainty

set clk25 u_pll|altpll_component|auto_generated|pll1|clk[0]
set clk27 u_pll|altpll_component|auto_generated|pll1|clk[1]

# Both pixel clocks reach the video logic through the clock control block,
# but never at the same time.
set_clock_groups -physically_exclusive -group [get_clocks $clk25] -group [get_clocks $clk27]

# 50 MHz domain -> video domain: the mode select changes only while the video
# logic is held in reset, and that reset is released through a synchronizer.
set_false_path -from [get_clocks CLOCK_50] -to [get_clocks [list $clk25 $clk27]]

# VGA outputs: the monitor samples them with its own PLL locked to HSYNC, so
# there is no setup / hold relation on the board. The LED is far too slow to matter.
set_false_path -to [get_ports {VGA_R[*] VGA_G[*] VGA_B[*] VGA_HS VGA_VS LEDR}]

# The keys are asynchronous; the design synchronizes them.
set_false_path -from [get_ports {RESET_N KEY1}]
