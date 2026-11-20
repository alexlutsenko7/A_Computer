#!/bin/bash
# LNext video output test (Questa, Windows install, from WSL): ./run_video_sim.sh
# next_video.v alone with a made-up picture in the Next's timing and the OSD on (tb_next_video.sv);
# writes video.log and video.ppm / video.png (one frame of the VGA output).
cd "$(dirname "$0")"
Q=/mnt/c/Altera/questa_fse/win64
rm -rf work_video
$Q/vlib.exe work_video >/dev/null
$Q/vlog.exe -quiet -work work_video ../rtl/next_video.v || exit 1
$Q/vlog.exe -quiet -work work_video -sv tb_next_video.sv || exit 1
$Q/vsim.exe -c -quiet -lib work_video -t ps tb_next_video -do "run -all; quit -f" | grep -vE '^# (//|Loading|\s*$)' > video.log
python3 -I ../../../LSpectrum/ep4_ce15/sim/ppm2png.py video.ppm video.png 2>/dev/null
tail -n 6 video.log
