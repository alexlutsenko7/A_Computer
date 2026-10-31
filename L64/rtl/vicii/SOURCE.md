# Source of L64/rtl/vicii/

VIC-II Kawari (Verilog VIC-II replacement by Randy Rossi), GPL-3 (`LICENSE`, every file has the GPL-3 header).

- Repository: https://github.com/randyrossi/vicii-kawari
- Commit: `95ed201` (2026-10-08)
- Path: `hdl/` (only the files a plain VIC-II needs; Kawari's extensions, its RGB output and its
  scan doubler are not built)

Our files: `config.vh` (build configuration: no extensions, no RGB / DVI / luma-chroma output), `SOURCE.md`.

Changes (each marked `// L64:` in the code):
- `addressgen.v`: output `vic_addr_o` = the 14-bit VIC address (our memory bus does not use the multiplexed `ado`).
- `vicii.v`: outputs `vic_addr` and `phase` (= `phi_phase_start`, the tick of the half cycle), and
  `pixel` / `raster_x_o` / `raster_line_o` (= `pixel_color3`, `raster_x`, `raster_line`: the colour index
  of each dot, as Kawari's scan doubler takes it; L64's frame buffer `../c64_fb.v` stores it).
- `vicii.v`, `registers.v`, `registers_no_eeprom.vi`: input `ext_rst` restarts the internal reset sequence
  (Kawari relied on `rst` powering up as 1; Quartus drops that register, as its input is constant 0, and the
  whole chip was optimised away). The chip type is set from `standard_sw` alone (0 = 6569R3 PAL).
- `bus_access.v`: the c-access line buffer `char_buf` is read through a register (`buf_q`), so it fits a block RAM.
- `registers.v`: power-up values for `chip` and the (unused) scan doubler settings (simulation; same as the
  hardware default).
- `vicii.v`: in the (unused) scan doubler hookup `is_native_x_in` = 1.
- `hires_vga_sync.v` (the scan doubler) is not copied.
