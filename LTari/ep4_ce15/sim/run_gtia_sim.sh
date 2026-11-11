#!/bin/bash
# GTIA unit test (Questa): ./run_gtia_sim.sh
cd "$(dirname "$0")"
Q=/mnt/c/Altera/questa_fse/win64
rm -rf work_gtia
$Q/vlib.exe work_gtia >/dev/null
$Q/vlog.exe -quiet -work work_gtia ../rtl/gtia.v || exit 1
$Q/vlog.exe -quiet -sv -work work_gtia tb_gtia.sv || exit 1
$Q/vsim.exe -c -quiet -lib work_gtia tb_gtia -do "run -all; quit -f" | grep -E "ok |FAIL|RESULT|Error"
