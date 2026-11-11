# DDR_TEST timing constraints

create_clock -name CLOCK_50 -period 20.000 [get_ports CLOCK_50]
derive_pll_clocks
derive_clock_uncertainty

set clk100 u_pll|altpll_component|auto_generated|pll1|clk[0]
set clk_sd u_pll|altpll_component|auto_generated|pll1|clk[1]

# SDRAM clock: inverted clk_sd (clk100 + 1.5 ns) forwarded through the DDIO output (u_sdclk)
create_generated_clock -name sdram_clk -source [get_pins $clk_sd] -invert [get_ports DRAM_CLK]

# W9825G6KH-6 @ CL2: tIS 1.5, tIH 0.8, tAC 6.0, tOH 3.0 (ns); ~0.5 ns board skew allowance
set sdram_out [get_ports {DRAM_ADDR[*] DRAM_BA[*] DRAM_CS_N DRAM_RAS_N DRAM_CAS_N DRAM_WE_N DRAM_LDQM DRAM_UDQM DRAM_DQ[*]}]
set_output_delay -clock sdram_clk -max  2.0 $sdram_out
set_output_delay -clock sdram_clk -min -1.3 $sdram_out

set_input_delay  -clock sdram_clk -max  6.5 [get_ports {DRAM_DQ[*]}]
set_input_delay  -clock sdram_clk -min  2.5 [get_ports {DRAM_DQ[*]}]

# Read data launched by SDRAM clock edge N is captured by the FPGA 1.5 clk100
# periods later (READ issued at edge 0, sampled at edge CL+1 = 3). The hold
# check then stays one period before that capture edge (default), which is right.
set_multicycle_path -from [get_clocks sdram_clk] -to [get_clocks $clk100] -setup -end 2

# CKE is constant
set_false_path -to [get_ports DRAM_CKE]

# Asynchronous / slow board I/O
set_false_path -from [get_ports {RESET_N KEY}]
set_false_path -to   [get_ports LEDR]
