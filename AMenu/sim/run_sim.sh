#!/bin/bash
# Machine menu testbench (Questa, Windows install, from WSL): power-up case, then the failed-image case.
# Writes menu.ppm / menu.png (power-up) and menu_fail.ppm / menu_fail.png.
cd "$(dirname "$0")"
Q=/mnt/c/Altera/questa_fse/win64
for c in OK FAIL; do
    rm -rf work
    $Q/vlib.exe work >/dev/null
    $Q/vlog.exe -quiet ../rtl/AMenu.v ../rtl/menu_boot.v ../rtl/menu_video.v \
        ../../LSpectrum/rtl/zx_keyboard.v ../../LSpectrum/rtl/vga_timing.v || exit 1
    $Q/vlog.exe -quiet -sv +define+$c tb_amenu.sv || exit 1
    $Q/vsim.exe -c -quiet -t ps tb_amenu -do "run -all; quit -f" | grep -vE '^# (//|Loading|\s*$)'
    n=menu; [ $c = FAIL ] && n=menu_fail
    [ $n != menu ] && mv -f menu.ppm $n.ppm
    python3 -I ../../LSpectrum/sim/ppm2png.py $n.ppm $n.png 2>/dev/null
done
