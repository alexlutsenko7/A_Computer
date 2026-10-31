#!/bin/bash
# Kawari VIC-II alone (tb_vic.sv): a CPU-style write to $D020 must show in the border (Questa, from WSL).
cd "$(dirname "$0")"
Q=/mnt/c/Altera/questa_fse/win64
R=../rtl
rm -rf work_vic
$Q/vlib.exe work_vic >/dev/null
$Q/vlog.exe -quiet -work work_vic +incdir+$R/vicii $R/vicii/*.v tb_vic.sv || exit 1
$Q/vsim.exe -c -quiet -lib work_vic -t ps -voptargs="+initreg+0 +initmem+0" tb_vic -do "run -all; quit -f" | grep -E "wrote|white|RESULT|Error"
