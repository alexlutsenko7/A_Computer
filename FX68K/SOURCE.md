# FX68K: source and version

The 68000 of LMega (the Sega Mega Drive machine, `LMega/10cl025`).

- Origin: https://github.com/MiSTer-devel/Genesis_MiSTer/tree/adc0c42cfb1fa5d484cc8566767f7d68982bc44a/rtl/FX68K (the copy of fx68k that the MiSTer Genesis core uses; fx68k itself: https://github.com/ijor/fx68k)
- Commit: `adc0c42cfb1fa5d484cc8566767f7d68982bc44a` (2023-02-24).
- Copied unchanged on 2026-11-17. Do not edit these files; put wrappers / changes outside this folder.
- Author: Jorge Cwik. Cycle-exact 68000 from the original microcode (`microrom.mem`, `nanorom.mem`).
- Licence: GPL-3 (see the header of fx68k.sv): the sources of a distributed bitstream must be offered.
- `fx68k.sdc` (multicycle paths inside the core) is taken in through `fx68k.qip`.
- The simulation needs `microrom.mem` / `nanorom.mem` in its working folder (`LMega/10cl025/sim/run_sim.sh` copies them).

## SHA-256 (first 16 hex digits)
```
0ea4e42ad8a4fec5  fx68k.qip
049bdb5cbfa084e9  fx68k.sdc
3e3864d5335285fd  fx68k.sv
2a7d451e8f7ae868  fx68k.txt
8602a84b736eefee  fx68kAlu.sv
9d13082be0cf4b04  microrom.mem
b3998009fb10605e  nanorom.mem
f99e62db62fbf01f  uaddrPla.sv
```
