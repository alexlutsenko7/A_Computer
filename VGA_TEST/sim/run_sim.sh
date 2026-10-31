#!/bin/bash
# Run the VGA_TEST testbench with Questa (Windows install, called from WSL).
cd "$(dirname "$0")"
Q=/mnt/c/Altera/questa_fse/win64
rm -rf work
$Q/vlib.exe work >/dev/null
$Q/vlog.exe -quiet ../rtl/VGA_TEST.v ../rtl/vga_timing.v || exit 1   # vga_pll, vga_clkmux: models in the testbench
$Q/vlog.exe -quiet -sv tb_vga_test.sv || exit 1
$Q/vsim.exe -c -quiet tb_vga_test -do "run -all; quit -f" | grep -vE '^# (//|Loading|\s*$)'
