# Source of L64/ep4_ce15/rtl/cia/

`mos6526.v` (CIA 6526 / 8521; "by Rayne, timers and interrupts rewritten by slingshot"), from the MiSTer
Commodore 64 core: https://github.com/MiSTer-devel/C64_MiSTer, commit `fe6dfe5` (2026-09-06), `rtl/mos6526.v`.
No licence header; part of the MiSTer C64 core, distributed under the GPL (`c64.sv`: GPL-2 or later).

Change (marked `// L64:`): `timerAff`, `timerBff`, `timerAoverflow`, `timerBoverflow` are declared before
their first use (port B), so Questa accepts the file; compiled as SystemVerilog. Output `state` = {CRB, CRA,
IMR} (the interrupt mask cannot be read through the registers), for snapshots.
