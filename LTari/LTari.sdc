# LTari timing constraints

create_clock -name CLOCK_50 -period 20.000 [get_ports CLOCK_50]
derive_pll_clocks
derive_clock_uncertainty

set clk     u_pll|altpll_component|auto_generated|pll1|clk[0]
set clk_sd  u_pll|altpll_component|auto_generated|pll1|clk[1]
set clk_sdo u_pll|altpll_component|auto_generated|pll1|clk[2]
set clk_v50 u_vpll|altpll_component|auto_generated|pll1|clk[0]
set clk_v60 u_vpll|altpll_component|auto_generated|pll1|clk[1]

# remote update block clock (KEY1 -> machine menu): CLOCK_50 / 4 from a counter bit
create_generated_clock -name ruclk -source [get_ports CLOCK_50] -divide_by 4 [get_registers {ru_div[1]}]

#------------------------------------------------------------------------------
# SDRAM (as LSpectrum / DDR_TEST, here at 85.12 MHz)
#------------------------------------------------------------------------------
create_generated_clock -name sdram_clk -source [get_pins $clk_sdo] -invert [get_ports DRAM_CLK]

set sdram_out [get_ports {DRAM_ADDR[*] DRAM_BA[*] DRAM_CS_N DRAM_RAS_N DRAM_CAS_N DRAM_WE_N DRAM_LDQM DRAM_UDQM DRAM_DQ[*]}]
set_output_delay -clock sdram_clk -max  2.0 $sdram_out
set_output_delay -clock sdram_clk -min -1.3 $sdram_out
set_input_delay  -clock sdram_clk -max  6.5 [get_ports {DRAM_DQ[*]}]
set_input_delay  -clock sdram_clk -min  2.5 [get_ports {DRAM_DQ[*]}]

set_multicycle_path -from [get_clocks sdram_clk] -to [get_clocks $clk_sd] -setup -end 2
set_false_path -to [get_ports DRAM_CKE]

#------------------------------------------------------------------------------
# Clock domains
#------------------------------------------------------------------------------
# clk (28.4 MHz, the Atari) and clk_sd (3 x, same PLL, aligned edges) are timed against
# each other: the bus request toggle, the tape loader keys, the OSD port, the frame
# buffer writer -> FIFO. CLOCK_50 (remote update divider, clock switch sequencer),
# ruclk and the pixel clock (clk_v50 or clk_v60 through the clock switch: only one at a
# time) are asynchronous to them: the frame buffer and the OSD cross with synchronisers
# and dual-clock block RAMs.
set_clock_groups -asynchronous \
    -group [get_clocks CLOCK_50] \
    -group [get_clocks ruclk] \
    -group [get_clocks [list $clk $clk_sd $clk_sdo sdram_clk]] \
    -group [get_clocks $clk_v50] \
    -group [get_clocks $clk_v60]

# SDRAM port owner switches (atari_system: ld_done ? arbiter : (ROM loaded ? RAM clear : loader)),
# as LSpectrum: the new owner's first request comes a clock after the switch
set_multicycle_path -from [get_registers {*u_loader|done *ld_clr_done}] -to [get_registers {*u_ram|*}] -setup 2
set_multicycle_path -from [get_registers {*u_loader|done *ld_clr_done}] -to [get_registers {*u_ram|*}] -hold 1

#------------------------------------------------------------------------------
# Board I/O: asynchronous or not timing-critical
#------------------------------------------------------------------------------
set_false_path -from [get_ports {RESET_N KEY1 KB_IN KB_OUT JOY1_* JOY2_* BT_BCLK BT_LRCK BT_RX}]
set_false_path -from [get_ports {ESP_SCK ESP_MOSI ESP_CS_N}]
set_false_path -to   [get_ports {ESP_MISO ESP_IRQ}]
set_false_path -to   [get_ports {VGA_R[*] VGA_G[*] VGA_B[*] VGA_HS VGA_VS AUDIO_AY AUDIO_BEEP BT_DATA BT_TX LEDR}]

# Configuration flash (ASMI block pins), as LSpectrum
set_false_path -from [get_keepers {*u_asmi~ALTERA_*}]
set_false_path -to   [get_keepers {*u_asmi~ALTERA_*}]
