#!/bin/bash
# Whole-C64 simulation (Questa, Windows install, from WSL).
# Usage: ./run_sim.sh ROMIMAGE.mem [vlog defines...]   e.g. ./run_sim.sh ~/c64roms_fast.mem +define+RUN_MS=600
#   ROMIMAGE.mem: from tools/mk_c64rom.py (your own ROM files). Copied here as c64roms.mem (not in git).
#   For a fast boot, build the image from a KERNAL whose RAM test is skipped: bytes at $FD68 =
#   A9 A0 85 C2 4C 88 FD (LDA #$A0 / STA $C2 / JMP $FD88: top of memory = $A000, as the test finds).
# Writes screen.ppm / screen.png (one VGA frame).
# +initreg+0 / +initmem+0: registers and memories start at 0, as the FPGA powers up (Kawari relies on it).
cd "$(dirname "$0")"
[ -f "$1" ] || { echo "usage: $0 ROMIMAGE.mem [defines]"; exit 1; }
cp -f "$1" c64roms.mem; shift
Q=/mnt/c/Altera/questa_fse/win64
R=../rtl
A=../../LSpectrum
rm -rf work
$Q/vlib.exe work >/dev/null
$Q/vcom.exe -quiet -2008 ../../T65/T65_Pack.vhd ../../T65/T65_ALU.vhd ../../T65/T65_MCode.vhd ../../T65/T65.vhd || exit 1
$Q/vcom.exe -quiet -2008 $R/via/iecdrv_via6522.vhd || exit 1
$Q/vlog.exe -quiet -sv sid_stub.sv $R/cia/mos6526.v || exit 1      # the real SID: Quartus only (see sid_stub.sv)
$Q/vlog.exe -quiet +incdir+$R/vicii $R/vicii/*.v || exit 1
$Q/vlog.exe -quiet $R/c64_system.v $R/c64_keyboard.v $R/c64_video.v $R/c64_fb.v $R/c1541.v $R/c1541_gcr.v \
    $A/rtl/sdram_ram.v $A/rtl/rom_loader.v $A/rtl/tape_loader.v $A/rtl/esp_link.v $A/rtl/sd_dac.v $A/rtl/bt_i2s.v || exit 1
$Q/vlog.exe -quiet -sv "$@" $A/sim/sdram_model.sv $A/sim/flash_model.v tb_l64.sv || exit 1
$Q/vsim.exe -c -quiet -t ps -voptargs="+initreg+0 +initmem+0" tb_l64 -do "run -all; quit -f" | grep -vE '^# (//|Loading|\s*$)'
python3 -I $A/sim/ppm2png.py screen.ppm screen.png 2>/dev/null
