#!/bin/bash
# PC test of fat.cpp + tape.cpp + save.cpp + snap.cpp (compiled as C) (w64devkit gcc for Windows, called from WSL):
# builds test card images (FAT32 with MBR, FAT16 without, FAT32 with 4 KB clusters),
# lists + plays every TAP/TZX in them and compares each signal with tools/tzxref.py.
set -e
cd "$(dirname "$0")"
GCC=${W64GCC:-/mnt/c/Tools/w64devkit/w64devkit/bin/gcc.exe}
W=work
rm -rf $W && mkdir -p $W/tree
python3 -I ../tools/mktest.py $W/tree
$GCC -O2 -Wall -Wextra -o $W/host_test.exe host_test.c -x c ../src/fat.cpp ../src/tape.cpp ../src/util.cpp
fail=0
for cfg in "32 --mbr --spc 1" "16 --spc 4" "32 --spc 8"; do
    set -- $cfg
    tag="fat$1${2:+_}${2#--}"
    img=$W/$tag.img
    python3 -I ../tools/mkimg.py $img $W/tree --fat $cfg
    mkdir -p $W/out_$tag
    if ! (cd $W && ./host_test.exe $tag.img out_$tag > $tag.log); then
        echo "  host_test reported errors:"; grep ERROR $W/$tag.log; fail=1
    fi
    tail -1 $W/$tag.log
    python3 -I compare.py $W/tree $W/$tag.log $W/out_$tag || fail=1
done
# start in the middle (pause/continue, rewind): normal block, inside a loop, a return without a call
for sb in 3 13 20; do
    mkdir -p $W/out_from$sb
    (cd $W && ./host_test.exe fat32_mbr.img out_from$sb $sb > from$sb.log) || { grep ERROR $W/from$sb.log; fail=1; }
    echo "start at block $sb:"
    python3 -I compare.py $W/tree $W/from$sb.log $W/out_from$sb $sb || fail=1
done
# saving: decoder + FAT writing, on fresh copies of the images; checked by tools/fatcheck.py
$GCC -O2 -Wall -Wextra -DHOST_TEST -o $W/save_test.exe save_test.c -x c ../src/fat.cpp ../src/save.cpp ../src/util.cpp
python3 -I mksave.py $W
for tag in fat32_mbr fat16_spc fat32_spc; do
    cp $W/$tag.img $W/s_$tag.img
    echo "saving on $tag:"
    (cd $W && ./save_test.exe s_$tag.img save save1.tap / HELLO > s1.log && cat s1.log | sed 's/^/  /' &&
              ./save_test.exe s_$tag.img save save2.tap GAMES TWOPARTS noise > s2.log && grep -E "^status|ERROR" s2.log | sed 's/^/  /' &&
              ./save_test.exe s_$tag.img save save3.tap / NOHDR > s3.log && grep -E "^status|ERROR" s3.log | sed 's/^/  /' &&
              ./save_test.exe s_$tag.img save save1.tap / NOTHING empty > s4.log && grep -E "^status|ERROR" s4.log | sed 's/^/  /' &&
              ./save_test.exe s_$tag.img many GAMES 60 | sed 's/^/  /') || { echo "  save_test FAILED"; fail=1; }
    python3 -I ../tools/fatcheck.py $W/s_$tag.img /HELLO.TAP $W/save1.tap /GAMES/TWOPARTS.TAP $W/save2.tap \
        /NOHDR.TAP $W/save3.tap || fail=1
done
# snapshots (.z80): loading reference files (versions 1/2/3, 48K/128K, bad ones), and
# save + reload round trips; checked by z80ref.py (independent decoder) and fatcheck.py
$GCC -O2 -Wall -Wextra -DHOST_TEST -o $W/snap_test.exe snap_test.c -x c ../src/fat.cpp ../src/snap.cpp ../src/shot.cpp ../src/util.cpp
rm -rf $W/z80tree && mkdir -p $W/z80tree/SNAPS $W/z80tree/GAMES $W/z80exp
python3 -I z80ref.py gen $W/z80tree/SNAPS $W/z80exp
for cfg in "32 --mbr --spc 1" "16 --spc 4" "32 --spc 8"; do
    set -- $cfg
    tag="z_fat$1${2:+_}${2#--}"
    python3 -I ../tools/mkimg.py $W/$tag.img $W/z80tree --fat $cfg
    echo "snapshots on $tag:"
    for f in $W/z80tree/SNAPS/*.Z80; do
        n=$(basename $f)
        (cd $W && ./snap_test.exe $tag.img load /SNAPS/$n $n.dump > $n.log) || { echo "  snap_test load $n FAILED"; cat $W/$n.log; fail=1; continue; }
        python3 -I z80ref.py check $W/$n.dump $W/z80exp/$n.dump && echo "  load $n: $(head -1 $W/$n.log)" || fail=1
    done
    for s in 1 2 3 4 5 6 7 8; do
        dir=/; [ $((s % 2)) = 0 ] && dir=GAMES
        (cd $W && ./snap_test.exe $tag.img save $dir SNAP$s $s exp$s.dump out$s.z80 > sv$s.log) ||
            { echo "  snap_test save $s FAILED"; cat $W/sv$s.log; fail=1; continue; }
        python3 -I z80ref.py checksave $W/out$s.z80 $W/exp$s.dump || fail=1
    done
    # screenshots (Print Screen): BMP of the shown screen (page 5 / 7) with the border, every pixel checked
    (cd $W && ./snap_test.exe $tag.img shot shot.bmp 24 > shot.log) || { echo "  snap_test shot FAILED"; cat $W/shot.log; fail=1; }
    echo "  screenshot: $(head -1 $W/shot.log)"
    python3 -I ../tools/fatcheck.py $W/$tag.img /SNAP1.Z80 $W/out1.z80 /GAMES/SNAP2.Z80 $W/out2.z80 \
        /SNAP7.Z80 $W/out7.z80 /GAMES/SNAP8.Z80 $W/out8.z80 /SCRN0002.BMP $W/shot.bmp || fail=1
done
# L64 ROM install (c64.cpp as C++, flash + pass-through model, cut-offs); needs the local C64 ROMs
ROMS=../../../L64/roms_local
if [ -f $ROMS/kernal.bin ]; then
    mkdir -p $W/c64rom/tree/ROMS/C64
    cp $ROMS/kernal.bin $ROMS/basic.bin $ROMS/char.bin $ROMS/dos1541.bin $W/c64rom/tree/ROMS/C64/
    python3 -I ../tools/mkimg.py $W/c64rom/card.img $W/c64rom/tree --fat 32 --mbr --spc 8 > /dev/null
    ${GCC%gcc.exe}g++.exe -O2 -Wall -Wextra -o $W/c64rom/c64rom_test.exe c64rom_test.cpp \
        ../src/c64.cpp ../src/flash.cpp ../src/fat.cpp ../src/util.cpp ../src/tape.cpp ../src/save.cpp ../src/shot.cpp
    for b in 5 25; do
        echo "C64 ROM install, pass-through busy $b us:"
        (cd $W/c64rom && ./c64rom_test.exe card.img tree/ROMS/C64 $b > busy$b.log) || fail=1
        sed 's/^/  /' $W/c64rom/busy$b.log
    done
else
    echo "C64 ROM install test skipped (no $ROMS/kernal.bin)"
fi
# flash update (update.cpp + flash.cpp + fat.cpp delete): needs AMenu/output_files/LUPDATE.BIN (tools/mk_update.py)
UPD=../../../AMenu/output_files/LUPDATE.BIN
if [ -f $UPD ]; then
    mkdir -p $W/update/tree
    cp $UPD $W/update/tree/
    python3 -I ../tools/mkimg.py $W/update/card.img $W/update/tree --fat 32 --mbr --spc 1 --mb 64 > /dev/null
    ${GCC%gcc.exe}g++.exe -O2 -Wall -Wextra -o $W/update/update_test.exe update_test.cpp \
        ../src/update.cpp ../src/flash.cpp ../src/fat.cpp ../src/util.cpp
    echo "Flash update:"
    (cd $W/update && ./update_test.exe card.img tree/LUPDATE.BIN > update.log) || fail=1
    sed 's/^/  /' $W/update/update.log
else
    echo "Flash update test skipped (no $UPD)"
fi
[ $fail = 0 ] && echo "HOST TEST PASSED" || { echo "HOST TEST FAILED"; exit 1; }
