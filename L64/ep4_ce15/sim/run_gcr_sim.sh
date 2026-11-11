#!/bin/bash
# c1541_gcr alone (tb_gcr.sv): read a track as the 1541 DOS does and check every header and data block.
cd "$(dirname "$0")"
Q=/mnt/c/Altera/questa_fse/win64
rm -rf work_gcr
$Q/vlib.exe work_gcr >/dev/null
$Q/vlog.exe -quiet -work work_gcr -sv ../rtl/c1541_gcr.v tb_gcr.sv || exit 1
$Q/vsim.exe -c -quiet -lib work_gcr -t ps -voptargs="+initreg+0 +initmem+0" tb_gcr -do "run -all; quit -f" | grep -E "ERROR|headers|RESULT|Error"
