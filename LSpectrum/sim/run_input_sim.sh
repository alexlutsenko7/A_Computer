#!/bin/bash
# Input latency (Kempston + USB keyboard UART -> CPU -> border) with the real T80 (Questa, from WSL).
# Usage: [WORK=dir] ./run_input_sim.sh [+define+TURBO=1] [+define+N_TIGHT=n] [+define+N_FRAME=n]
cd "$(dirname "$0")"
W=${WORK:-work_input}
Q=/mnt/c/Altera/questa_fse/win64
T80=../../T80
python3 -I mk_inputprog.py input_prog.hex || exit 1
rm -rf $W
$Q/vlib.exe $W >/dev/null
$Q/vcom.exe -quiet -93 -work $W $T80/T80_Pack.vhd $T80/T80_ALU.vhd $T80/T80_MCode.vhd $T80/T80_Reg.vhd $T80/T80.vhd || exit 1
$Q/vlog.exe -quiet -work $W ../rtl/zx_bus.v ../rtl/cpu_t80.v ../rtl/sdram_ram.v ../rtl/zx_keyboard.v ../rtl/jt49/*.v || exit 1
$Q/vlog.exe -quiet -work $W -sv "$@" sdram_model.sv tb_input.sv || exit 1
$Q/vsim.exe -c -quiet -lib $W -t ps tb_input -do "run -all; quit -f" | grep -vE '^# (//|Loading|\s*$)|metavalue|Time: 0 ps|NUMERIC_STD'
