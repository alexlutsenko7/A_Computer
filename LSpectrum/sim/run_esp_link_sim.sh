#!/bin/bash
# esp_link (SPI link from the ESP32) inside tape_loader (Questa, Windows install, from WSL).
# Swept over both machines' link clocks (56 MHz LSpectrum, 94.5 MHz L64), 8 and 4 MHz SPI
# and MISO sample points around the falling edge, where the ESP32 really samples
# (hardware 2026-10-28: at 4 MHz a clean 1-bit shift with MISO changed after the rising edge).
cd "$(dirname "$0")"
Q=/mnt/c/Altera/questa_fse/win64
rm -rf work_esp
$Q/vlib.exe work_esp >/dev/null
$Q/vlog.exe -quiet -work work_esp ../rtl/esp_link.v ../rtl/tape_loader.v || exit 1
$Q/vlog.exe -quiet -work work_esp -sv tb_esp_link.sv || exit 1
fail=0
for clkh in 8929 5289; do
    for spi in "62500:30000 45000 62500 75000" "125000:60000 100000 125000 140000"; do
        half=${spi%%:*}
        for samp in ${spi#*:}; do
            out=$($Q/vsim.exe -c -quiet -lib work_esp -t ps tb_esp_link +CLKH=$clkh +HALF=$half +SAMP=$samp \
                  -do "run -all; quit -f" | tr -d '\r' | grep -vE '^# (//|Loading|\s*$)|Time: 0 ps')
            res=$(echo "$out" | grep -E "^# (PASS|FAIL)$" | tail -1)
            echo "$(echo "$out" | grep "SPI half" | sed 's/^# //'): ${res#\# }"
            echo "$out" | grep -q "^# PASS$" || { echo "$out" | grep "FAIL" | head -5; fail=1; }
        done
    done
done
# the machine menu (AMenu): 75 MHz, FL_HALF 2, flash stream frames (FLS)
for spi in "62500:45000 62500 75000" "125000:100000 125000"; do
    half=${spi%%:*}
    for samp in ${spi#*:}; do
        out=$($Q/vsim.exe -c -quiet -lib work_esp -t ps -GFL_HALF=2 -GFLS=1 tb_esp_link +CLKH=6667 +HALF=$half +SAMP=$samp +FLS \
              -do "run -all; quit -f" | tr -d '\r' | grep -vE '^# (//|Loading|\s*$)|Time: 0 ps')
        res=$(echo "$out" | grep -E "^# (PASS|FAIL)$" | tail -1)
        echo "menu + FLS: $(echo "$out" | grep "SPI half" | sed 's/^# //'): ${res#\# }"
        echo "$out" | grep -q "^# PASS$" || { echo "$out" | grep "FAIL" | head -5; fail=1; }
    done
done
[ $fail = 0 ] && echo "ESP LINK SIM PASSED" || { echo "ESP LINK SIM FAILED"; exit 1; }
