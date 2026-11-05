#!/bin/bash
# Questa (Windows install, called from WSL or Git Bash):
#   1. tb_vga_timing: vga_timing alone, both modes (clocks per line, lines per frame, visible area)
#   2. tb_first_light: the whole design with models of the PLL and the clock control block
cd "$(dirname "$0")"
Q=${QUESTA:-/mnt/c/Altera/questa_fse/win64}
rm -rf work
$Q/vlib.exe work > /dev/null
$Q/vlog.exe -quiet ../rtl/vga_timing.v ../rtl/first_light.v || exit 1   # vga_pll, vga_clkmux: models in tb_first_light.sv
$Q/vlog.exe -quiet -sv tb_vga_timing.sv tb_first_light.sv || exit 1
for tb in tb_vga_timing tb_first_light; do
    echo "== $tb"
    $Q/vsim.exe -c -quiet $tb -do "run -all; quit -f" | grep -E '^# [^*]' | grep -vE '^# (//|Loading|run|quit|vsim|Start time|End time)'
done
