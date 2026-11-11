#!/bin/bash
# Whole-machine simulation with Questa (Windows install, called from WSL).
# Usage: ./run_sim.sh [vlog defines...]   e.g. ./run_sim.sh +define+RUN_MS=200 +define+KEYS
# Writes screen.ppm (and screen.png if python3 is available).
cd "$(dirname "$0")"
Q=/mnt/c/Altera/questa_fse/win64
T80=../../../T80
rm -rf work
$Q/vlib.exe work >/dev/null
$Q/vcom.exe -quiet -93 $T80/T80_Pack.vhd $T80/T80_ALU.vhd $T80/T80_MCode.vhd $T80/T80_Reg.vhd $T80/T80.vhd || exit 1
$Q/vlog.exe -quiet ../rtl/zx_system.v ../rtl/zx_bus.v ../rtl/cpu_t80.v ../rtl/zx_video.v ../rtl/zx_keyboard.v \
    ../rtl/rom_loader.v ../rtl/sd_dac.v ../rtl/bt_i2s.v ../rtl/sdram_ram.v ../rtl/vga_timing.v ../rtl/jt49/*.v \
    ../rtl/tape_loader.v ../rtl/esp_link.v || exit 1
$Q/vlog.exe -quiet -sv "$@" sdram_model.sv flash_model.v tb_lspectrum.sv || exit 1
$Q/vsim.exe -c -quiet -t ps tb_lspectrum -do "run -all; quit -f" | grep -vE '^# (//|Loading|\s*$)'
python3 -I ppm2png.py screen.ppm screen.png 2>/dev/null
