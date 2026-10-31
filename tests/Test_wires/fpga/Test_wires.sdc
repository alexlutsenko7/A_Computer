# Test_wires timing constraints

create_clock -name CLOCK_50 -period 20.000 [get_ports CLOCK_50]
derive_clock_uncertainty

# Asynchronous inputs (synchronised in the design) and slow outputs (UART / LED)
set_false_path -from [get_ports {RESET_N ESP_SCK ESP_MOSI ESP_CS_N BT_BCLK BT_LRCK BT_RX}]
set_false_path -to [get_ports {LEDR ESP_MISO ESP_IRQ BT_DATA BT_TX}]
