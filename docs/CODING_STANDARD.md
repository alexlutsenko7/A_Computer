# Coding standard

Every piece of code I ask you to write or change, in any project, is formatted to this standard (given 2026-11-11).
Third-party code that is kept as an unchanged copy is not reformatted.

(a) All `#define` come right after the `#include` section.
(b) All global variables are defined after the include section: arrays / enums first, then variables.
(c) In every function, the local variables are declared at the beginning, followed by the code.
(d) Only one `return` statement per function.
(e) Every `if` has brackets `{}`, however simple the statement is.
(f) Every bracket `{` `}` is on a line of its own, except where a semicolon follows the bracket (`};`, `} while (...);`).
(g) Variables are declared with sized type specifiers (`int32_t`, not `int`); `bool` and `float` are allowed.
(h) Variable names start with their type: `ui32_status`, not `status`. Globals start with `g_`: `g_ui32_status`.
(i) Every number is a `#define`, except `0`.
(j) Every variable is initialized right after the declarations, on a line of its own; arrays need no initialization unless it is required.
(k) At least one comment per three lines. Comments start in column 0 and use `/* ... */`, also for several lines: each line its own comment.


## Conventions

- Prefixes: `ui8_ ui16_ ui32_ ui64_`, `i8_ i16_ i32_ i64_`, `b_` bool, `f_` float, `c_` char (text), `p` + pointee for
  pointers (`pui8_`, `pc_`, `p_` for void), `a` + element for arrays (`aui8_`, `ac_`), `s_` struct, `e_` enum.
  Function parameters are variables too. Function names carry no prefix.
- `char` is kept for text (string literals, library calls).
- File-scope `static` variables count as globals (`g_`).
- Verilog (user, 2026-11-11: comments and constants are what matters there; no renaming, nothing else): every
  `if` / `else` with `begin` ... `end`, each on its own line; the comment rule (k); numbers as `localparam`.
  Signal names are NOT changed (the .sdc, .qsf, testbenches and the pin generator refer to them).
- Verilog reading of rule (i) (Claude's, to be confirmed by the user). Every number gets a `localparam` with a
  comment, declared right after the module header and keeping the literal's width (`localparam [9:0] H_SYNC_50 =
  10'd64;`), except:
  0 and 1; all bits set (`8'hFF`: the complement of 0); binary literals (bit patterns such as `2'b01`, `3'b101`);
  vector bounds, bit and part selects (everything inside `[...]`); numbers in `parameter` / `localparam` / `` `define ``
  lines (that is where they get their names); a literal connected to a named port or parameter (`.DIV(2)`: the port
  name names it); case labels (the index column of a table) and one-line table rows (`8'h07: key_pos = 7'd18;`).
  In testbenches also test vectors: the arguments of a task call (`sd_poke(21'h29FFA, 8'h00);`), a literal handed
  alone to a probe function (`sd_peek(18'h09FFF)`), array elements being filled and `'{...}` lists.
  The same number with two meanings in one file gets two names.
- Verilog tools in `tmp/coding_standard_harness/`: vfmt.py (formatter), vlint.py (`--runs` = rule k), vnum.py
  (lists the literals rule (i) still wants named; `--tb` for testbenches), vname.py (turns a list of
  `LITERAL[@lines] NAME | comment` into localparams and proves that the names put back give the old code),
  vbuild.sh / vall.sh (bitstream proof, below).
- Third-party code kept as an unchanged copy (T80, T65, JT49, Kawari VIC-II, SID, CIA, VIA) is not reformatted.
- Results are named: a function that can fail returns `XX_OK` (0) or a named error (`FL_ERROR`), never a bare number.
- An infinite loop with returns becomes a loop on a `b_done` flag with one result variable.
- A prototype's types change together with every definition of it (also the models in `test/`).
- On the ESP32 `int32_t` is `long`, not `int`: a prototype, its definition and every function pointer of that type
  must change in the same step, or the firmware does not compile (the PC tests do not notice: there both are `int`).
- Signal names in Verilog / VHDL are not changed (user, 2026-11-11). Third-party VHDL stays as it is (user agreed).
- A module without a test is checked by an old-versus-new harness: both versions compiled on the PC against the same
  stubs, outputs compared byte for byte.
- Constant lookup tables (palettes, offset tables, slot addresses) keep their numbers as data, where a name per value
  would say nothing; values with a meaning get names (Claude's reading of rule (i): to be confirmed by the user).
- Comments start in column 0 also inside functions (fixed in all converted files 2026-11-11).
- `tmp/coding_standard_harness/`: lint.py (checks the rules), the old-vs-new harnesses and eq_all.sh (reruns them).
- Enum values and bit-field widths are definitions, like #define.
- Rule (k) is counted in statements: a call or condition written over several lines is one line; lines with only a
  brace do not count. `tmp/coding_standard_harness/cpass.py` lists the gaps and inserts comments, and refuses any
  change that is more than a comment.
- Where a function's local variables and their start values need a comment only to keep rule (k), the comments are
  `/* local variables */` and `/* start values */`.
- A one-line initializer (`= { 1, 2, 3 };`) keeps its braces on the line (the bracket is followed by a semicolon).
- Reference file: `ESP32/v2/src/util.cpp`.

## Conversion of the existing code (started 2026-11-11)

Each converted file is verified before the next: C / C++ by the host tests (`ESP32_test/v2/test/run_host_test.sh`) and a
firmware compile; Verilog by a rebuild that must give the same bitstream: `tmp/coding_standard_harness/vall.sh`
builds every Quartus revision from the working tree in a scratch copy (`tmp/vbuild/work`, never the project's own
`db` / `output_files`) and compares the raw bitstream (.rbf) with the one of the project's existing .sof. Identical
bits = the hardware-verified design is unchanged and needs no new hardware test.

| Code | State |
|---|---|
| `ESP32/v2/src/util.h`, `util.cpp` | done 2026-11-11, host tests PASS |
| `ESP32/v2/src/flash.h`, `flash.cpp` | done 2026-11-11, host tests PASS (flash update, power cuts), firmware compiles |
| `ESP32/v2/src/shot.h`, `shot.cpp` | done 2026-11-11: firmware compiles; output byte-identical to the old code on 72 test pictures, names and error cases (old-vs-new harness on the PC) |
| `ESP32/v2/src/fat.h`, `fat.cpp` | done 2026-11-11: host tests PASS (3 card images, listing, playing, saving, snapshots) |
| `ESP32/v2/src/espupd.h`, `espupd.cpp`, `update.h`, `update.cpp` | done 2026-11-11: update tests PASS (7 scenarios, power cuts); espupd by compile only |
| `ESP32/v2/src/save.h`, `save.cpp` | done 2026-11-11: saving tests PASS |
| `ESP32/v2/src/hal.h`, `tape.h`, `tape.cpp` | done 2026-11-11: 34 signals identical to the reference on every card image |
| `ESP32/v2/src/snap.h`, `snap.cpp` | done 2026-11-11: snapshot tests PASS (6 file versions load, 4 bad files rejected, 8 saved files as before) |
| `ESP32/v2/src/bt.h`, `bt.cpp` | done 2026-11-11: old-vs-new harness, identical output over a scripted session (2,533 lines: received lines, keys, PIN typing, screen, commands) |
| `ESP32/v2/src/atari.h`, `atari.cpp` | done 2026-11-11: old-vs-new harness identical (SIO commands, .atr / .xex / .car, screenshot, snapshots; 14.5 million register writes) |
| `ESP32/v2/src/c64.h`, `c64.cpp` | done 2026-11-11: ROM install test PASS; old-vs-new harness identical (.prg / .t64, .tap, recording, 1541, snapshots, screenshot) |
| `ESP32/v2/src/esp_hw.cpp`, `hw.h`, `sd.h`, `osd.h`, `loader.h`, `reset.h` | done 2026-11-11: old-vs-new on a mock Arduino (tmp/coding_standard_harness/mock), identical: link frames, bursts, OSD, memory cache, SD, flash stream, housekeeping, machine left / reset |
| `ESP32/v2/src/main.cpp` | done 2026-11-11: old-vs-new with pseudo-random keys and stub results, 4 machine modes x 70 seeds, identical; 98 % of its lines executed |
| `ESP32/v2/v2.ino` (Bluetooth A2DP source, I2S, commands) | done 2026-11-11: compiles; setup / loop split into helpers in the old order (no PC test: needs the hardware test) |
| `ESP32_test/v2/test/` (host_test.c, save_test.c, snap_test.c, c64rom_test.cpp, update_test.cpp, host_hw.h) | done 2026-11-11: host tests PASS; the two flash tests print the same logs as before, byte for byte. The flash model they shared as two copies is one file now (`test/flash_model.cpp`, `.h`) |
| temporary bridges (`fat.h` unions, `fw_file`, `slow_mode`, `machine_*` defines) | removed 2026-11-11 |
| rule (k), `ESP32/v2` | done 2026-11-11: no run of more than three code lines without a comment in any file (lint.py --runs: 0); a statement written over several lines counts as one line. Checked: nothing but comments changed (43 files compared without comments and white space), host tests PASS, harnesses identical |
| firmware `ESP32/v2` with all of the above | compiles, 1,188,803 bytes |
| `ESP32/v1` | **works on hardware (user, 2026-11-11: all machines, all sound options, wired and Bluetooth, power cycles, all software loaded)**; done 2026-11-11: the converted v2 files with v1's own differences (320-entry list in a static array, its shell sort, no PSRAM allocator, UART2 on GPIO16 / 17, 1.25 MB firmware slot). Host tests PASS; old-vs-new identical for main.cpp (280 runs) and esp_hw.cpp; compiles, 1,173,195 bytes (89 %) |
| generated headers `src/atari_palette.h`, `src/atari_xexboot.h` | left as generated (they follow their Python generators in LTari/ep4_ce15/tools) |
| `ESP32_test/v1/ESPLinkTest/ESPLinkTest.ino` | done 2026-11-11: all rules incl. (k); compiles (345,647 bytes). No PC test: by review; `osdtest` is four page functions instead of one with `goto` |
| `ESP32_test/v1/Test_wires` (.ino, .h) | done 2026-11-11: all rules incl. (k); compiles (350,415 bytes). The sampling and burst loops keep their structure; lambdas became functions. No PC test: by review. The FPGA side (`fpga/rtl`) goes with the Verilog |
| Own Verilog, 81 files: AMenu, LSpectrum, L64, LTari, DDR_TEST (both boards), FirstLight, VGA_TEST, tests/Test_wires/fpga, tests/t80_fmax, all testbenches and models, Book/src | done 2026-11-11: formatted (begin / end, `/* */` comments in column 0), rule (k) (vlint.py --runs: 0 problems), rule (i) (vnum.py: 0 literals left; about 1,000 named constants). Proof: all 16 Quartus revisions rebuilt from the converted sources give bitstreams identical to the existing .sof files (vall.sh, log tmp/vbuild/results/vall_final.log), so no new hardware test of the FPGA is needed. Testbenches: see the simulation row |
| Simulations with the converted testbenches | SIM_ROW |
| Python tools | not converted (user, 2026-11-11: leave Python as it is) |
