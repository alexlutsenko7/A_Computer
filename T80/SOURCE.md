# T80 — source and version

- Origin: https://github.com/MiSTer-devel/ZX-Spectrum_MISTer/tree/af0e6723942ec1b30c0908beacd7b7a37d54294b/rtl/T80
- Commit: `af0e6723942ec1b30c0908beacd7b7a37d54294b` (2026-07-24, "Implement Zilog Z80 SCF/CCF undocumented flag behavior (#60)")
- Copied unchanged on 2026-10-05. Do not edit these files; put wrappers/changes outside this folder.
- Version: T80(c) 351 (Sorgelig, MiSTer) on T80(b) 303 (MikeJ) on T80 0250 (Daniel Wallner).
  Header claims: passes ZEXDOC, ZEXALL, Z80Full, Z80memptr. Newer than the standalone repo
  https://github.com/MiSTer-devel/T80 (last change 2021-03-30). Fixes since then in this copy:
  - 2026-07: Zilog SCF/CCF undocumented X/Y flag behaviour (Q register); INI/IND/INIR/INDR undocumented flags (zxall 102-103)
  - 2023-12: X/Y flags for LDxR/INxR/OTxR; MEMPTR for INIR/INDR/OTIR/OTDR
- Licence: BSD-style (Daniel Wallner), see the header of T80.vhd: keep the copyright notice in source and
  reproduce it in documentation of synthesized (bitstream) distributions.
- The user's previous copy (T80(b) ver 303, 2010) is in `Reference_ZX_On_DE10_Lite/` and stays as reference.

## SHA-256 (first 16 hex digits)
```
0beab4907254270b  GBse.vhd
f106b928d5e6e363  README
b0ec667b617f4c4b  T80.qip
8e880dce21b9c961  T80.vhd
9b950c6daa0f3ec5  T8080se.vhd
823a062b8be87350  T80_ALU.vhd
78454892dea4cb2e  T80_MCode.vhd
646954fa24baa028  T80_Pack.vhd
b40f92eb96fc55fa  T80_Reg.vhd
e70e7bde8888fbca  T80a.vhd
3667b90adfa35727  T80as.vhd
e67354e5fed26f92  T80pa.vhd
4c1f72fcf5133d06  T80s.vhd
d528be5e4a75a8e4  T80se.vhd
0b8d8b357ec6fbd2  T80sed.vhd
```
Files needed for a Z80 build: T80_Pack, T80_ALU, T80_MCode, T80_Reg, T80, plus one wrapper (T80se or T80pa).
