#!/bin/bash
# Memory contention test (zx_bus Level 1) with the real T80 (Questa, Windows install, from WSL).
cd "$(dirname "$0")"
Q=/mnt/c/Altera/questa_fse/win64
T80=../../T80
python3 -I mk_contprog.py cont_prog.hex || exit 1
rm -rf work_cont
$Q/vlib.exe work_cont >/dev/null
$Q/vcom.exe -quiet -93 -work work_cont $T80/T80_Pack.vhd $T80/T80_ALU.vhd $T80/T80_MCode.vhd $T80/T80_Reg.vhd $T80/T80.vhd || exit 1
$Q/vlog.exe -quiet -work work_cont ../rtl/zx_bus.v ../rtl/cpu_t80.v ../rtl/sdram_ram.v ../rtl/jt49/*.v || exit 1
$Q/vlog.exe -quiet -work work_cont -sv "$@" sdram_model.sv tb_cont.sv || exit 1
$Q/vsim.exe -c -quiet -lib work_cont -t ps tb_cont -do "run -all; quit -f" | grep -vE '^# (//|Loading|\s*$)|metavalue|Time: 0 ps|NUMERIC_STD'
