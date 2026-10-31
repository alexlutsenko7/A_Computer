# Source of T65/

T65 (6502 core, VHDL), copied **unchanged** from the MiSTer Commodore 64 core:

- Repository: https://github.com/MiSTer-devel/C64_MiSTer
- Commit: `fe6dfe5` (2026-09-06)
- Path in that repository: `rtl/t65/`
- Version: T65(b) Ver 315 (SzGy, April 2020)
- Files: `T65_Pack.vhd`, `T65_ALU.vhd`, `T65_MCode.vhd`, `T65.vhd`

Licence: BSD-style (Daniel Wallner, Mike Johnson, Wolfgang Scherr, Morten Leikvoll; header of `T65.vhd`):
redistribution in source and synthesised form is allowed if the copyright notice is kept.

Used by `L64/` (6510 CPU; the 6510 I/O port is in `L64/rtl/c64_system.v`), later the 1541 drive.
