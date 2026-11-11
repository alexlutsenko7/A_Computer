#!/bin/bash
# LTari boot simulation (Questa, Windows install, from WSL).
# Usage: ./run_sim.sh [vlog defines...]   e.g. ./run_sim.sh +define+RUN_MS=2000 +define+M800
# Builds atarirom.mem from ../roms (tools/mk_atarirom.py); writes screen.ppm / .png (GTIA) and
# vga.ppm / .png (the frame buffer's VGA output).
cd "$(dirname "$0")"
Q=/mnt/c/Altera/questa_fse/win64
R=../rtl
A=../../../LSpectrum/ep4_ce15
T=../../../T65
python3 -I ../tools/mk_atarirom.py ../roms/altirraos_xl.rom ../roms/altirra_basic.rom atarirom > /dev/null || exit 1
rm -rf work
$Q/vlib.exe work >/dev/null
$Q/vcom.exe -quiet -2008 $T/T65_Pack.vhd $T/T65_ALU.vhd $T/T65_MCode.vhd $T/T65.vhd || exit 1
$Q/vlog.exe -quiet $R/antic.v $R/gtia.v $R/pokey.v $R/pia.v $R/atari_system.v $R/atari_fb.v $R/atari_sio.v \
    $A/rtl/sdram_ram.v $A/rtl/rom_loader.v || exit 1
$Q/vlog.exe -quiet -sv "$@" $A/sim/sdram_model.sv $A/sim/flash_model.v tb_atari.sv || exit 1
$Q/vsim.exe -c -quiet -t ps -voptargs="+acc" tb_atari -do "run -all; quit -f" | grep -vE '^# (//|Loading|\s*$)'
python3 -I $A/sim/ppm2png.py screen.ppm screen.png 2>/dev/null
python3 -I $A/sim/ppm2png.py vga.ppm vga.png 2>/dev/null
