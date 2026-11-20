#!/bin/bash
# LNext keyboard test (Questa, Windows install, from WSL): ./run_kbd_sim.sh
# next_keyboard.v alone: keyboard reports in, the key events for the Next core out (tb_next_keyboard.sv).
cd "$(dirname "$0")"
Q=/mnt/c/Altera/questa_fse/win64
rm -rf work_kbd
$Q/vlib.exe work_kbd >/dev/null
$Q/vlog.exe -quiet -work work_kbd ../rtl/next_keyboard.v || exit 1
$Q/vlog.exe -quiet -work work_kbd -sv tb_next_keyboard.sv || exit 1
$Q/vsim.exe -c -quiet -lib work_kbd -t ps tb_next_keyboard -do "run -all; quit -f" | grep -vE '^# (//|Loading|\s*$)' > kbd.log
tail -n 12 kbd.log
