# Source of L64/rtl/sid/

SID 6581/8580, copied unchanged from the MiSTer Commodore 64 core:

- Repository: https://github.com/MiSTer-devel/C64_MiSTer, commit `fe6dfe5` (2026-09-06), path `rtl/sid/`
- `sid_dac.sv`, `sid_filter.sv`: Dag Lem (reDIP-SID) / Alexey Melnikov, CERN-OHL-S v2 (headers)
- `sid_top.sv`, `sid_voice.sv`, `sid_envelope.sv`, `sid_tables.sv`: no header; part of the MiSTer C64 core,
  which is distributed under the GPL (`c64.sv`: GPL-2 or later)

Built with MULTI_FILTERS = 0 (one 6581 filter curve), DUAL = 0. Questa does not accept these files
(use before declaration): the system testbench uses `sim/sid_stub.sv`.
