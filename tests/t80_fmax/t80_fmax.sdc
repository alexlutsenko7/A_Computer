# Tight target (80 MHz) so the fitter optimises hard; Fmax is read from the report.
create_clock -name clk -period 12.500 [get_ports clk]
derive_clock_uncertainty
set_false_path -from [all_inputs]
set_false_path -to   [all_outputs]
