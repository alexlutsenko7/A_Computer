#!/bin/bash
# LMega smoke test (Questa, Windows install, from WSL): ./run_sim.sh [vlog defines...]
# Builds testrom.bin (mk_testrom.py), runs it on md_system + md_mem + the SDRAM model, writes run.log,
# frame.ppm / frame.png (the VDP's picture: red and green stripes when everything works).
cd "$(dirname "$0")"
Q=/mnt/c/Altera/questa_fse/win64
R=../rtl
A=../../../LSpectrum/ep4_ce15
T=../../../T80
python3 -I mk_testrom.py > /dev/null || exit 1
cp ../../../FX68K/microrom.mem ../../../FX68K/nanorom.mem .
rm -rf work
$Q/vlib.exe work >/dev/null
# the simulator is stricter than Quartus with two of the third-party files: patched copies in src_sim/
#  - bram.vhd: its first entity (spram, not used here) instantiates one that is declared after it, and
#    instantiations are written without the word "entity"; a blank stands for "no memory file"
#  - jt12_pcm_interpol.v: a register is used above its declaration
mkdir -p src_sim
python3 -I - <<'PY' || exit 1
text = open('../rtl/genesis/bram.vhd').read()
start = text.index('ENTITY spram IS')
end = text.index('END SYN;', start) + len('END SYN;')
text = (text[:start] + text[end:]).replace(': work.dpram_dif', ': entity work.dpram_dif')
# no memory file: the simulation library wants the word UNUSED, not a blank
text = text.replace('string := " "', 'string := "UNUSED"')
open('src_sim/bram.vhd', 'w').write(text)
text = open('../../../JT12/jt12_pcm_interpol.v').read()
assert 'reg sign, last_pcm_wr;' in text
text = text.replace('reg sign, last_pcm_wr;', 'reg sign;')
text = text.replace('reg [stepw-1:0] dn,', 'reg last_pcm_wr;\nreg [stepw-1:0] dn,', 1)
open('src_sim/jt12_pcm_interpol.v', 'w').write(text)
PY
# entities of bram.vhd first: one is used before the file declares it
$Q/vcom.exe -quiet -2008 -just e src_sim/bram.vhd || exit 1
$Q/vcom.exe -quiet -2008 $T/T80_Pack.vhd $T/T80_Reg.vhd $T/T80_MCode.vhd $T/T80_ALU.vhd $T/T80.vhd $T/T80s.vhd \
    src_sim/bram.vhd $R/genesis/vdp_common.vhd $R/genesis/vdp.vhd || exit 1
JT12=$(sed -n 's/.*VERILOG_FILE \[file join $::quartus(qip_path) \(.*\) *\]/..\/..\/..\/JT12\/\1/p' ../../../JT12/jt12.qip | tr -d ' ' | grep -v jt12_pcm_interpol)
$Q/vlog.exe -quiet -sv $JT12 src_sim/jt12_pcm_interpol.v ../../../JT89/jt89.v ../../../JT89/jt89_noise.v ../../../JT89/jt89_vol.v \
    ../../../JT89/jt89_mixer.v ../../../JT89/jt89_tone.v || exit 1
$Q/vlog.exe -quiet $R/md_mem.v $R/md_sdram.v || exit 1
$Q/vlog.exe -quiet -sv -suppress 13314 ../../../FX68K/fx68k.sv ../../../FX68K/fx68kAlu.sv ../../../FX68K/uaddrPla.sv $R/md_system.sv || exit 1
$Q/vlog.exe -quiet -sv "$@" $A/sim/sdram_model.sv tb_md.sv || exit 1
for try in $(seq 1 400); do
    $Q/vsim.exe -c -quiet -t ps -suppress 7061,8315 -L altera_mf tb_md -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run -all; quit -f" | grep -vE '^# (//|Loading|\s*$)' > run.log
    grep -q "License checkout has been disallowed" run.log || break
    sleep $((20 + RANDOM % 20))
done
python3 -I $A/sim/ppm2png.py frame.ppm frame.png 2>/dev/null
tail -n 14 run.log
