#!/bin/bash
# LNext loader test (Questa, Windows install, from WSL): ./run_loader_sim.sh
# next_loader.v's command FIFO and UART receive FIFO in their one block RAM, through the ESP32
# link (tb_next_loader.sv). Run twice: with the simulation arrays, and with the altsyncram
# that Quartus builds (Intel's simulation library).
cd "$(dirname "$0")"
Q=/mnt/c/Altera/questa_fse/win64
fail=0
for ram in arrays altsyncram; do
    def=""
    [ $ram = altsyncram ] && def="+define+ALTERA_RESERVED_QIS"
    rm -rf work_loader
    $Q/vlib.exe work_loader >/dev/null
    $Q/vlog.exe -quiet -work work_loader $def ../../../LSpectrum/ep4_ce15/rtl/esp_link.v ../rtl/next_loader.v || exit 1
    $Q/vlog.exe -quiet -work work_loader -sv tb_next_loader.sv || exit 1
    $Q/vsim.exe -c -quiet -lib work_loader -L altera_mf_ver -suppress 2685,2718 -t ps tb_next_loader -do "run -all; quit -f" \
        | tr -d '\r' | grep -vE '^# (//|Loading|\s*$)' > loader_$ram.log
    echo "--- $ram"
    tail -n 8 loader_$ram.log
    grep -q "^# PASS$" loader_$ram.log || fail=1
done
[ $fail = 0 ] && echo "LOADER SIM PASSED" || { echo "LOADER SIM FAILED"; exit 1; }
