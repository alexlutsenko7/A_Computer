#!/bin/bash
# ROM loader: the search for the machine's ROM area (tag in area 1 / 2 / 3, none)
cd "$(dirname "$0")"
Q=/mnt/c/Altera/questa_fse/win64
rm -rf work_rl
$Q/vlib.exe work_rl >/dev/null
$Q/vlog.exe -quiet -work work_rl ../rtl/rom_loader.v flash_model.v || exit 1
$Q/vlog.exe -quiet -sv -work work_rl tb_rom_loader.sv || exit 1
$Q/vsim.exe -c -quiet -t ps -lib work_rl tb_rom_loader -do "run -all; quit -f" | grep -vE '^# (//|Loading|\s*$)'
