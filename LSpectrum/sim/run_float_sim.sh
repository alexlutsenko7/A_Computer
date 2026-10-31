#!/bin/bash
# Floating bus test (zx_bus) with the real T80 (Questa, Windows install, from WSL).
cd "$(dirname "$0")"
Q=/mnt/c/Altera/questa_fse/win64
T80=../../T80
python3 -I mk_floatprog.py float_prog.hex || exit 1
rm -rf work_float
$Q/vlib.exe work_float >/dev/null
$Q/vcom.exe -quiet -93 -work work_float $T80/T80_Pack.vhd $T80/T80_ALU.vhd $T80/T80_MCode.vhd $T80/T80_Reg.vhd $T80/T80.vhd || exit 1
$Q/vlog.exe -quiet -work work_float ../rtl/zx_bus.v ../rtl/cpu_t80.v ../rtl/sdram_ram.v ../rtl/jt49/*.v || exit 1
$Q/vlog.exe -quiet -work work_float -sv "$@" sdram_model.sv tb_float.sv || exit 1
$Q/vsim.exe -c -quiet -lib work_float -t ps tb_float -do "run -all; quit -f" | grep -vE '^# (//|Loading|\s*$)|metavalue|Time: 0 ps|NUMERIC_STD'
