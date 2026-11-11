# AMenu timing constraints

create_clock -name CLOCK_50 -period 20.000 [get_ports CLOCK_50]
derive_pll_clocks
derive_clock_uncertainty

# remote update block clock: CLOCK_50 / 4 from a counter bit
create_generated_clock -name ruclk -source [get_ports CLOCK_50] -divide_by 4 [get_registers {ru_div[1]}]

set pclk u_vpll|altpll_component|auto_generated|pll1|clk[0]
set mclk u_mpll|altpll_component|auto_generated|pll1|clk[0]

# Crossings: selection / error (50 MHz -> pixel clock, quasi-static, synchronised),
# start toggle + boot address (50 MHz -> ruclk, toggle synchronised, address static),
# ready / trigger / previous address (ruclk -> 50 MHz, level synchronised, data static)
# ESP32 link clock (mclk, 75 MHz): keyboard report (50 MHz -> mclk, quasi-static, read by the ESP32),
# OSD on (mclk -> 50 MHz / pixel clock, level synchronised), OSD text RAM (written at mclk, read
# at the pixel clock: a character may show late for one frame)
set_clock_groups -asynchronous \
    -group [get_clocks CLOCK_50] \
    -group [get_clocks ruclk] \
    -group [get_clocks $pclk] \
    -group [get_clocks $mclk]

set_false_path -from [get_ports {RESET_N KB_IN KB_OUT JOY1_* JOY2_* BT_RX}]
set_false_path -to   [get_ports {VGA_R[*] VGA_G[*] VGA_B[*] VGA_HS VGA_VS AUDIO_AY AUDIO_BEEP BT_TX LEDR}]

# SPI link from the ESP32: synchronised in esp_link (SCK oversampled); IRQ is a level
set_false_path -from [get_ports {ESP_SCK ESP_MOSI ESP_CS_N}]
set_false_path -to   [get_ports {ESP_MISO ESP_IRQ}]
