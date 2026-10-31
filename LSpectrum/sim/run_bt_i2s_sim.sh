#!/bin/bash
# bt_i2s (I2S to the ESP32 Bluetooth bridge) with 16- and 32-bit slots (Questa, Windows install, from WSL).
cd "$(dirname "$0")"
Q=/mnt/c/Altera/questa_fse/win64
rm -rf work_bt
$Q/vlib.exe work_bt >/dev/null
$Q/vlog.exe -quiet -work work_bt ../rtl/bt_i2s.v || exit 1
for def in "" "+define+SLOT32"; do
    $Q/vlog.exe -quiet -work work_bt -sv $def tb_bt_i2s.sv || exit 1
    $Q/vsim.exe -c -quiet -lib work_bt -t ps tb_bt_i2s -do "run -all; quit -f" | grep -vE '^# (//|Loading|\s*$)|Time: 0 ps'
done
