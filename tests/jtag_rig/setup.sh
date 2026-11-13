#!/bin/bash
# setup.sh -- makes the scratch copy of the sources with the JTAG test rig in the tops (tmp/jtagtest/work).
# The project folders are not touched. Then build there, e.g.:
#   cd tmp/jtagtest/work/AMenu/10cl025 && quartus_sh --flow compile AMenu
P=$(cd "$(dirname "$0")/../.." && pwd); W=$P/tmp/jtagtest/work
EX="--exclude db --exclude incremental_db --exclude output_files --exclude sim --exclude tools --exclude ref --exclude *.log --exclude *.qws --exclude greybox_tmp"
mkdir -p $W
rsync -a --delete $EX $P/T80 $P/T65 $P/AMenu $P/LSpectrum $P/L64 $P/LTari $P/roms $W/
cp $P/tests/jtag_rig/jtag_test.v $P/tmp/jtagtest/jtag_test.v
python3 $P/tests/jtag_rig/patch.py $W
