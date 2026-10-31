#!/bin/bash
# A game's floating-bus sync vs Fuse's rule (tb_floatgame), default Sidewize. Questa, from WSL.
# Usage: ./run_floatgame_sim.sh [SNAP.z80] [vlog defines...]
cd "$(dirname "$0")"
Q=/mnt/c/Altera/questa_fse/win64
T80=../../T80
SNAP=${1:-"../../Games/ZXSpectrum/s2/Sidewize[a].z80"}; shift
python3 -I mk_z80img.py "$SNAP" sw_img.hex || exit 1
rm -rf work_fg
$Q/vlib.exe work_fg >/dev/null
$Q/vcom.exe -quiet -93 -work work_fg $T80/T80_Pack.vhd $T80/T80_ALU.vhd $T80/T80_MCode.vhd $T80/T80_Reg.vhd $T80/T80.vhd || exit 1
$Q/vlog.exe -quiet -work work_fg ../rtl/zx_bus.v ../rtl/cpu_t80.v ../rtl/sdram_ram.v ../rtl/jt49/*.v || exit 1
$Q/vlog.exe -quiet -work work_fg -sv "$@" sdram_model.sv tb_floatgame.sv || exit 1
$Q/vsim.exe -c -quiet -lib work_fg -t ps tb_floatgame -do "run -all; quit -f" | grep --line-buffered -vE '^# (//|Loading|\s*$)|metavalue|Time: 0 ps|NUMERIC_STD'
