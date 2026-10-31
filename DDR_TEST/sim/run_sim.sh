#!/bin/bash
# Run the testbench with Questa (Windows install, called from WSL).
# Usage: ./run_sim.sh [TCO_ns] [PASSES] [SD_SHIFT_ns]
cd "$(dirname "$0")"
Q=/mnt/c/Altera/questa_fse/win64
TCO=${1:-4.0}
PASSES=${2:-2}
SHIFT=${3:-1.339}
rm -rf work
$Q/vlib.exe work >/dev/null
$Q/vlog.exe -quiet ../rtl/sdram_ram.v ../rtl/ram_tester.v || exit 1
$Q/vlog.exe -quiet -sv +define+TCO=$TCO +define+PASSES=$PASSES +define+SD_SHIFT=$SHIFT sdram_model.sv tb_ddr_test.sv || exit 1
$Q/vsim.exe -c -quiet tb_ddr_test -do "run -all; quit -f" | grep -vE '^# (//|Loading|\s*$)'
