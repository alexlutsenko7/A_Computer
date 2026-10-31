# quartus_sta -t sta_report.tcl : unconstrained ports, worst system-clock paths,
# and the worst CPU-internal / CPU->smp_* paths (to confirm the multicycles apply)
project_open LSpectrum
create_timing_netlist
read_sdc
update_timing_netlist
report_ucp -file output_files/sta_ucp.txt
report_timing -setup -npaths 5 -to_clock [get_clocks {u_pll|altpll_component|auto_generated|pll1|clk[0]}] -detail summary -file output_files/sta_worst.txt
report_timing -setup -npaths 3 -from [get_registers {*u_bus|cpu_t80:u_cpu|*}] -to [get_registers {*u_bus|cpu_t80:u_cpu|*}] -detail summary -file output_files/sta_cpu.txt
report_timing -setup -npaths 3 -to [get_registers {*u_bus|smp_*}] -detail summary -file output_files/sta_smp.txt
delete_timing_netlist
project_close
