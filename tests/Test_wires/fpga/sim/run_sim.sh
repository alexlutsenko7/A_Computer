#!/bin/bash
# Test_wires simulation (Questa FSE): ./run_sim.sh
set -e
cd "$(dirname "$0")"
Q=/mnt/c/Altera/questa_fse/win64
$Q/vlib.exe work >/dev/null
$Q/vlog.exe -sv ../rtl/Test_wires.v tb_test_wires.sv
$Q/vsim.exe -c -do "run -all; quit -f" tb_test_wires | grep -E "Error|Fatal" || true
python3 check_samples.py samples.txt
