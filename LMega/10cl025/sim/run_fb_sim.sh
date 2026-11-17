#!/bin/bash
# LMega frame buffer video mode test (Questa): ./run_fb_sim.sh
cd "$(dirname "$0")"
Q=/mnt/c/Altera/questa_fse/win64
rm -rf work_fb
$Q/vlib.exe work_fb >/dev/null
$Q/vlog.exe -quiet -work work_fb ../rtl/md_video.v ../rtl/md_fb.v ../rtl/md_mem.v ../rtl/md_sdram.v || exit 1
$Q/vlog.exe -quiet -sv -work work_fb ../../../LSpectrum/ep4_ce15/sim/sdram_model.sv tb_md_fb.sv || exit 1
for try in $(seq 1 400); do
    $Q/vsim.exe -c -quiet -t ps -lib work_fb tb_md_fb -do "run -all; quit -f" | grep -vE '^# (//|Loading|\s*$)' > fb.log
    grep -q "License checkout has been disallowed" fb.log || break
    sleep $((20 + RANDOM % 20))
done
grep -E "line period|lines per frame|colour changes|middle|RESULT|Error|SDRAM MODEL ERROR" fb.log | head -20
