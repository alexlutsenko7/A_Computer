#!/bin/bash
# Simulates vga_timing with Questa (Windows install, called from WSL or Git Bash).
cd "$(dirname "$0")"
Q=${QUESTA:-/mnt/c/Altera/questa_fse/win64}
rm -rf work
$Q/vlib.exe work > /dev/null
$Q/vlog.exe -quiet ../rtl/vga_timing.v || exit 1
$Q/vlog.exe -quiet -sv tb_vga_timing.sv || exit 1
$Q/vsim.exe -c -quiet tb_vga_timing -do "run -all; quit -f" | grep -vE '^# (//|Loading|\s*$)'
