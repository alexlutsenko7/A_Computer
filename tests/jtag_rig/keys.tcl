# keys.tcl CODE ... -- press and release keys through the rig: PS/2 set 2 codes in hex, "E" before a code = extended, "Wn" = wait n ms
set hw [lindex [get_hardware_names] 0]
set dev [lindex [get_device_names -hardware_name $hw] 0]
start_insystem_source_probe -hardware_name $hw -device_name $dev
proc src {key code} {
    set v [expr {($code << 1) | $key}]
    set s ""
    for {set i 39} {$i >= 0} {incr i -1} { append s [expr {($v >> $i) & 1}] }
    write_source_data -instance_index 0 -value $s
}
foreach k $argv {
    if {[string index $k 0] == "W"} { after [string range $k 1 end]; continue }
    set ext 0
    if {[string index $k 0] == "E"} { set ext 1; set k [string range $k 1 end] }
    src $ext [expr 0x$k]
    after 350
    src 0 0
    after 250
}
end_insystem_source_probe
puts "keys sent: $argv"
