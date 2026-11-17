#!/bin/bash
# LMega video output test (Questa): ./run_video_sim.sh
cd "$(dirname "$0")"
Q=/mnt/c/Altera/questa_fse/win64
rm -rf work_video
$Q/vlib.exe work_video >/dev/null
$Q/vlog.exe -quiet -work work_video ../rtl/md_video.v || exit 1
$Q/vlog.exe -quiet -sv -work work_video tb_md_video.sv || exit 1
for try in $(seq 1 400); do
    $Q/vsim.exe -c -quiet -t ps -lib work_video tb_md_video -do "run -all; quit -f" | grep -vE '^# (//|Loading|\s*$)' > video.log
    grep -q "License checkout has been disallowed" video.log || break
    sleep $((20 + RANDOM % 20))
done
grep -E "line period|lines per frame|colour changes|RESULT|Error" video.log
