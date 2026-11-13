#!/bin/bash
# stp.sh COMMAND ... -- one call of the JTAG driver (jt.tcl), its own lines only
cd "$(dirname "$0")"
/mnt/c/Altera/quartus/bin64/quartus_stp.exe -t jt.tcl "$@" 2>&1 | grep -v "^Info\|^    Info\|TBB\|^$"
