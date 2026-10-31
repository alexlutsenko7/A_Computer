#!/bin/bash
# Snapshot freeze / restore test of zx_bus with the real T80 (Questa, Windows install, from WSL).
# Usage: ./run_snap_sim.sh [vlog defines...]   e.g. +define+TURBO=0 +define+FREEZES=100
cd "$(dirname "$0")"
Q=/mnt/c/Altera/questa_fse/win64
T80=../../T80
python3 -I mk_snapprog.py snap_prog.hex || exit 1
rm -rf work_snap
$Q/vlib.exe work_snap >/dev/null
$Q/vcom.exe -quiet -93 -work work_snap $T80/T80_Pack.vhd $T80/T80_ALU.vhd $T80/T80_MCode.vhd $T80/T80_Reg.vhd $T80/T80.vhd || exit 1
$Q/vlog.exe -quiet -work work_snap ../rtl/zx_bus.v ../rtl/cpu_t80.v ../rtl/sdram_ram.v ../rtl/jt49/*.v || exit 1
$Q/vlog.exe -quiet -work work_snap -sv "$@" sdram_model.sv tb_snap.sv || exit 1
$Q/vsim.exe -c -quiet -lib work_snap -t ps tb_snap -do "run -all; quit -f" | grep -vE '^# (//|Loading|\s*$)'
