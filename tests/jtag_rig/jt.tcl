# jt.tcl -- driver for the JTAG test rig (quartus_stp -t jt.tcl COMMAND ...)
#   stat                       the status probe, decoded
#   src KEY CODE               set the key (0/1) and the menu key code (hex)
#   grab FILE Y0 YSTEP NY "X0 ..." XSTEP PLANES   lines of the picture as text: "y plane bits" (PLANES: list of rgb bit numbers)
set hw [lindex [get_hardware_names] 0]
set dev [lindex [get_device_names -hardware_name $hw] 0]
start_insystem_source_probe -hardware_name $hw -device_name $dev
proc b2d {b} { set v 0; foreach c [split $b ""] { set v [expr {$v * 2 + $c}] }; return $v }
proc field {bits hi lo} { set n [string length $bits]; return [string range $bits [expr {$n - 1 - $hi}] [expr {$n - 1 - $lo}]] }
proc src {key code line x0 step plane} {
    set v [expr {($plane << 35) | ($step << 32) | ($x0 << 20) | ($line << 9) | ($code << 1) | $key}]
    set s ""
    for {set i 39} {$i >= 0} {incr i -1} { append s [expr {($v >> $i) & 1}] }
    write_source_data -instance_index 0 -value $s
}
proc stat {} {
    set p [read_probe_data -instance_index 1]
    set id [format %08X [b2d [field $p 126 95]]]
    set st [format %04X [b2d [field $p 94 79]]]
    set fr [b2d [field $p 78 71]]; set vl [b2d [field $p 70 60]]; set hl [b2d [field $p 59 48]]
    set hp [b2d [field $p 47 24]]; set vp [b2d [field $p 23 0]]
    set fv [expr {$vp ? 50000000.0 / $vp : 0}]; set fh [expr {$hp ? 50000000.0 * 64 / $hp : 0}]
    puts [format "ID %s status %s frames %d lines/frame %d pixels/line %d  vsync %.3f Hz  hsync %.1f Hz  pixel clock %.4f MHz" \
          $id $st $fr $vl $hl $fv $fh [expr {$fh * $hl / 1e6}]]
    puts [format "   lines per frame from the two rates: %.2f" [expr {$fv ? $fh / $fv : 0}]]
}
set cmd [lindex $argv 0]
if {$cmd == "stat"} {
    stat; after 300; stat
} elseif {$cmd == "src"} {
    src [lindex $argv 1] [expr 0x[lindex $argv 2]] 0 0 0 0
    puts "source set: key [lindex $argv 1] code [lindex $argv 2]"
} elseif {$cmd == "grab"} {
    lassign [lrange $argv 1 end] file y0 ystep ny x0s xstep planes
    set f [open $file w]
    foreach pl $planes {
        foreach x0 $x0s {
            for {set i 0} {$i < $ny} {incr i} {
                set y [expr {$y0 + $i * $ystep}]
                src 0 0 $y $x0 [expr {$xstep - 1}] $pl
                after 40
                puts $f "$i $pl $x0 [read_probe_data -instance_index 0]"
            }
        }
    }
    close $f
    puts "grabbed $ny lines x [llength $planes] planes -> $file"
}
end_insystem_source_probe
