#!/bin/bash
# LNES simulation (Questa, Windows install, from WSL).
# Usage: ./run_sim.sh ROM.nes [work dir name] [vlog defines...]
#   e.g. ./run_sim.sh nestest.nes w1 +define+RUN_MS=600 +define+PRESS_MS=150
# Runs in its own folder (sim/<work dir>, default w), so several can run at the same time; writes
# <work dir>/run.log, frame.ppm and frame.png there.
cd "$(dirname "$0")"
Q=/mnt/c/Altera/questa_fse/win64
ROM=$(realpath "$1"); W=${2:-w}; shift; shift
R=../../rtl
A=../../../../LSpectrum/ep4_ce15
T=../../../../T65
mkdir -p "$W" && cd "$W" || exit 1
cp "$ROM" rom.nes
rm -rf work
$Q/vlib.exe work >/dev/null
$Q/vcom.exe -quiet -2008 $T/T65_Pack.vhd $T/T65_ALU.vhd $T/T65_MCode.vhd $T/T65.vhd || exit 1
RAM=$A/rtl/sdram_ram.v
case " $* " in *+define+FAST*) RAM=../fast_ram.v;; esac
$Q/vlog.exe -quiet $R/nes_ppu.v $R/nes_apu.v $R/nes_mapper.v $R/nes_system.v $R/nes_fb.v $RAM || exit 1
$Q/vlog.exe -quiet -sv '+define+ROM="rom.nes"' "$@" $A/sim/sdram_model.sv ../tb_nes.sv || exit 1
# the free Questa licence lets only a few sessions start: try again while it refuses
for try in $(seq 1 200); do
    $Q/vsim.exe -c -quiet -t ps tb_nes -do "run -all; quit -f" | grep -vE '^# (//|Loading|\s*$)' > run.log
    grep -q "License checkout has been disallowed" run.log || break
    sleep $((20 + RANDOM % 20))
done
python3 -I $A/sim/ppm2png.py frame.ppm frame.png 2>/dev/null
[ -f vga.ppm ] && python3 -I - vga.ppm vga.png <<'PY'
# the VGA picture 1:1 (x in the file = not driven yet: black)
import struct, sys, zlib
tok = open(sys.argv[1]).read().replace('x', '0').split()
w, h = int(tok[1]), int(tok[2])
px = bytes(map(int, tok[4:4 + 3 * w * h]))
raw = b''.join(b'\x00' + px[3 * w * y:3 * w * (y + 1)] for y in range(h))
chunk = lambda t, d: struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d))
open(sys.argv[2], 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) +
                              chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))
PY
tail -n 12 run.log
