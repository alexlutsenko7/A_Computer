# Prints worst slack per corner for SDRAM I/O and core paths: quartus_sta -t sta_io.tcl
project_open DDR_TEST
set clk {u_pll|altpll_component|auto_generated|pll1|clk[0]}
foreach m {slow fast} {
    create_timing_netlist -model $m
    read_sdc
    update_timing_netlist
    foreach {k cmd} [list \
        "out_setup" {report_timing -setup -to [get_ports {DRAM_*}] -npaths 1} \
        "out_hold"  {report_timing -hold  -to [get_ports {DRAM_*}] -npaths 1} \
        "in_setup"  {report_timing -setup -from [get_ports {DRAM_DQ[*]}] -npaths 1} \
        "in_hold"   {report_timing -hold  -from [get_ports {DRAM_DQ[*]}] -npaths 1} \
        "core_setup" "report_timing -setup -from_clock {$clk} -to \[get_registers *\] -npaths 1" \
        "core_hold"  "report_timing -hold  -from_clock {$clk} -to \[get_registers *\] -npaths 1"] {
        set r [eval $cmd]
        puts [format "SLACK %-5s %-10s %7.3f" $m $k [lindex $r 1]]
    }
    delete_timing_netlist
}
project_close
