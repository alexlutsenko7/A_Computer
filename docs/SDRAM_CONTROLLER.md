# SDRAM controller — how it works and why each detail is there

Covers `DDR_TEST/rtl/sdram_ram.v` (the controller), `DDR_TEST/rtl/DDR_TEST.v` / `sys_pll.v` (clocking),
`DDR_TEST/DDR_TEST.qsf` / `DDR_TEST.sdc` (I/O placement and timing) and `DDR_TEST/sim/` (verification).
State as of 2026-10-05: 112 MHz, CL2, 18-bit (256 KB) window; passes simulation, static timing at all corners,
and hardware.

The design has two halves and both must be right:
1. **Protocol**: sending legal command sequences with legal spacing (sections 2-6). Mistakes here show up in
   simulation.
2. **Electrical timing at the pins**: getting command, address and data to the chip, and the read data back,
   inside the setup/hold windows at 112 MHz across temperature and voltage (sections 7-9). Mistakes here usually
   pass simulation and fail on hardware, often only sometimes. This is where most home-made SDRAM designs fail.

---------------------------------------------------------------------------------------------------------------

## 1. The chip: W9825G6KH-6

- 32 MB = 4 banks x 8192 rows x 512 columns x 16 bit.
  Address pins A[12:0] carry the row (13 bits) on ACTIVATE, and the column (A[8:0], **9 bits**) on READ/WRITE.
  BA[1:0] select the bank. (The vendor demo uses 10 column bits, which is wrong for this chip, see section 12.)
- "-6" speed grade: CL3 up to 166 MHz, **CL2 up to 133 MHz**. We run CL2 at 112 MHz.
- Each bank has one "row buffer". A row must be **opened** (ACTIVATE) before its columns can be read or
  written, and **closed** (PRECHARGE) before another row of the same bank can be opened. The 4 banks are
  independent, so up to 4 rows (one per bank) can be open at once.
- Data is stored as charge and leaks: every row must be refreshed at least every 64 ms (8192 rows, so on
  average one AUTO REFRESH every 7.8 us). AUTO REFRESH requires all banks to be closed.

### Commands (sampled on the rising edge of the SDRAM clock)
`{CS_N, RAS_N, CAS_N, WE_N}`, the `CMD_*` constants in the code:

| Command | CS RAS CAS WE | Address pins | Effect |
|---|---|---|---|
| NOP | 0 1 1 1 | — | nothing (CS_N stays low all the time, which is why Quartus says DRAM_CS_N is "stuck at GND") |
| ACTIVATE (ACT) | 0 0 1 1 | BA = bank, A = row | opens the row |
| READ (RD) | 0 1 0 1 | BA, A[8:0] = column, A10 = 0 | data appears CL clocks later |
| WRITE (WR) | 0 1 0 0 | BA, A[8:0] = column, A10 = 0 | data is taken from DQ in the same clock |
| PRECHARGE (PRE) | 0 0 1 0 | BA, A10 = 0: one bank; A10 = 1: all banks | closes row(s) |
| AUTO REFRESH (REF) | 0 0 0 1 | — | refreshes one row internally (all banks must be closed) |
| LOAD MODE (MRS) | 0 0 0 0 | A = mode value | sets burst length, CAS latency |

DQM (LDQM/UDQM): a byte mask. On a write, DQM = 1 means "do not write that byte". On a read it disables the output
drivers (2-clock latency). We use DQM for byte writes.

### Timing rules and their values at 112 MHz (8.93 ns per clock)
Values from the datasheet `docs/vendor/W9825G6KH_datasheet.pdf` p.15, column "-6". Converted to cycles by the
controller as `ceil(ns x CLK_MHZ / 1000)`, so they adapt if `CLK_MHZ` changes.
The chip on this board is confirmed **-6** (2026-10-05), so 15 ns applies. **-6I/-6J/-6L parts need tRCD = tRP =
18 ns**: at 112 MHz 2 clocks = 17.86 ns would be too short; set `T_RCD`/`T_RP` from 18 ns (3 clocks) for those.

| Rule | Meaning | Datasheet | Cycles @112 | Actual |
|---|---|---|---|---|
| tRCD | ACT -> READ/WRITE same bank | 15 ns | 2 | 17.9 ns |
| tRP | PRE -> ACT/REF same bank | 15 ns | 2 | 17.9 ns |
| tRAS | ACT -> PRE same bank (min) | 42 ns | 5 | 44.6 ns |
| tRC | ACT -> ACT same bank | 60 ns | 7 | 62.5 ns |
| tRRD | ACT -> ACT different banks | 2 clk | 2 | (code uses ceil(12 ns) = 2 at 112 MHz) |
| tRFC | REF -> any command | 60 ns | 7 | 62.5 ns |
| tWR | last write data -> PRE | 2 clk | 2 | |
| tMRD | MRS -> any command | 2 clk | 2 | |
| tREFI | average refresh interval | 7.8125 us | forced at 840 | 7.5 us |
| tRAS max | ACT -> PRE (max) | 100 us | — | rows are closed by every refresh, at most every 7.6 us |
| power-up | pause before first command | 200 us | 22500 | 200.9 us |

---------------------------------------------------------------------------------------------------------------

## 2. Interface to the user logic (the "RAM" side)

```
req   : 1-cycle pulse starts an access
we    : 1 = write, 0 = read
addr  : byte address [ADDR_BITS-1:0]   } must stay stable from req until ack
din   : write data                     }
ack   : 1-cycle pulse when done (write: accepted; read: dout valid)
dout  : read data; valid during the ack cycle, then held until the next read completes
ready : 1 after SDRAM initialisation; a req before that is remembered and served afterwards
wide  : 1 = 16-bit access of the word at addr (addr[0] = 0)   } stable from req until ack;
din_hi: high byte of a 16-bit write                           } tie to 0 for a byte RAM
dout_w: the 16-bit word of a read; valid during the ack cycle only
```
Only one access can be outstanding. `addr/we/din` are **not latched**: the requester keeps them stable (a Z80 does
this naturally). That saved a multiplexer level in the critical path at 112 MHz (section 10).

---------------------------------------------------------------------------------------------------------------

## 3. Address mapping

The RAM is byte-wide but the SDRAM is 16-bit, so two bytes share one SDRAM word:

```
addr[0]                byte lane: 0 = DQ[7:0] (LDQM), 1 = DQ[15:8] (UDQM)
addr[9:1]              column  (9 bits -> one row = 512 words = 1 KB)
addr[11:10]            bank
addr[ADDR_BITS-1:12]   row     (18-bit window -> 64 rows per bank used)
```
- Writes: the byte is put on **both** halves of DQ (`{din, din}`) and DQM masks the other half. No
  read-modify-write is needed.
- Reads: the whole word is read and `addr[0]` picks the byte.
- 16-bit accesses (`wide = 1`, used by L64's frame buffer): writes put `{din_hi, din}` on DQ with both DQM
  low; reads return the whole word on `dout_w`. LSpectrum ties `wide` to 0.
- **Why the bank bits sit just above the column:** consecutive 1 KB blocks rotate through banks 0,1,2,3. Code,
  stack and data in different 1 KB areas tend to land in different banks, so they can keep their rows open at
  the same time (section 5). For the ZX map: RAM pages at 0x00000-0x1FFFF, ROMs at 0x20000+.

---------------------------------------------------------------------------------------------------------------

## 4. Initialisation (states `S_INIT_*`)

The datasheet order, done once after reset:
1. **`S_INIT_WAIT`** — 200 us with NOPs on the bus, CKE high and DQM high (`init_cnt` = 22500 clocks).
2. **`S_INIT_PRE`** — PRECHARGE ALL (A10 = 1), then wait tRP.
3. **`S_INIT_REF`** — 8 x AUTO REFRESH, each followed by tRFC.
4. **`S_INIT_MRS`** — LOAD MODE REGISTER = `0x020`:
   burst length 1 (A2:0 = 000), sequential (A3 = 0), **CAS latency 2** (A6:4 = 010), write burst = programmed
   (A9 = 0). Then wait tMRD, set `ready`, go to `S_IDLE`.

Burst length 1 means every READ/WRITE moves exactly one 16-bit word. That fits random byte access from a CPU and
avoids burst-termination rules.

---------------------------------------------------------------------------------------------------------------

## 5. Normal operation: open-row ("open page") policy

After an access the row is **left open**. The next access to the same bank:
- **same row** -> "hit": READ/WRITE immediately;
- **bank closed** -> ACT, wait tRCD, READ/WRITE;
- **different row open** -> "conflict": PRE, wait tRP, ACT, wait tRCD, READ/WRITE.

With 4 banks, up to four 1 KB windows are hot at a time. A Z80 mostly runs sequential code with a few
data/stack areas, so most accesses hit.

### Bookkeeping per bank (registers)
- `row_open[b]` — is a row open in bank b; `open_row[b]` — which one.
- **Age counters** (4 bits, saturate at 15): `act_age[b]`, `pre_age[b]`, `wr_age[b]` count clocks since the
  last ACT / PRE / WRITE on bank b; `act_any_age` counts clocks since the last ACT on any bank. A command sets its
  counter to 1; every clock adds 1.
- Every timing rule is then one compare:
  - `pre_ok[b]` (may close b) = `act_age >= tRAS && wr_age >= tWR`
  - `rp_ok[b]` (precharge finished) = `pre_age >= tRP`
  - READ/WRITE allowed after `act_age >= tRCD`
  - ACT allowed when `rp_ok && act_age >= tRC && act_any_age >= tRRD`

  Because each rule is enforced by its own counter, no sequence of requests can break a rule, however requests
  arrive. The simulation model independently checks every rule on every command (section 11).
- `wait_cnt` (4 bits): spacing after REF (tRFC), MRS (tMRD) and the read capture delay.

### The decision each clock (state `S_IDLE`, when `wait_cnt == 0`)
Priority order:
1. **Refresh due?** (`ref_force`, or `ref_early` and no request): if banks are open and `pre_ok` for all ->
   PRECHARGE ALL; when all closed and `rp_ok` -> AUTO REFRESH, reset the refresh timer, wait tRFC.
2. **Request present** (`pend` or `req` this very cycle):
   - hit and tRCD satisfied -> **WRITE** (ack at once: "posted" write) or **READ** (go to `S_READ`);
   - other row open in the bank and `pre_ok` -> **PRE** that bank;
   - bank closed and ACT rules satisfied -> **ACT**.

   Each clock issues at most one command, so a conflict naturally becomes PRE ... ACT ... READ over several
   clocks.

The request is decoded **in the same clock it arrives** (`have = pend | req`): a read hit issues READ on the very
edge that first sees `req`. `pend` only remembers a request that could not be started immediately.

### Read completion (`S_READ`)
READ is issued at edge E0. The data is captured from the pins at edge E3 (section 8) into `dq_in`. At that same
edge E3 the controller raises `ack` and `rd_valid`, and `dout` is driven combinationally from `dq_in` during the
ack cycle, then held in `dout_hold`. This saves one clock compared with registering `dout`.

### Latency (clock edges from the one that sees `req` to the one that sees `ack`)
| Case | Commands | Clocks | at 112 MHz |
|---|---|---|---|
| write, row hit | WR | 1 | 8.9 ns |
| read, row hit | RD | 4 | 35.7 ns |
| read, bank closed | ACT, -, RD | 6 | 53.6 ns |
| read, row conflict | PRE, -, ACT, -, RD | 8 | 71.4 ns |
| worst (refresh collision) | PRE all, -, REF, 7 clk, ACT, -, RD | ~20 | ~180 ns |

---------------------------------------------------------------------------------------------------------------

## 6. Refresh strategy

- `ref_timer` counts clocks since the last REF.
- **Early refresh**: after 420 clocks (3.75 us) a refresh is done **only if no request is pending**. A CPU
  leaves plenty of idle clocks, so in practice refreshes happen in gaps and cost nothing.
- **Forced refresh**: at 840 clocks (7.5 us) refresh wins over a pending request. Because a refresh happens at
  least every 7.5 us (+ at most one access already in progress), 8192 refreshes take < 64 ms. Measured maximum
  gap in simulation: 7597.7 ns (limit 7812.5).
- Refresh needs all banks closed, so it costs re-opening rows afterwards. It also limits how long any row stays
  open (tRAS max 100 us).
- `ref_force/ref_early` are registered flags (computed a clock ahead) to keep the 12-bit compare off the
  critical path.

Later, with the Z80, refresh can be placed in the CPU's own refresh slot (M1 T3/T4), when the CPU is guaranteed
not to access memory.

---------------------------------------------------------------------------------------------------------------

## 7. Clocking — the SDRAM clock and why it is made this way

```
CLOCK_50 -> PLL --c0--> clk     112 MHz, all logic incl. the controller and SDRAM I/O registers
                \--c1--> clk_sd  112 MHz delayed by 1.339 ns (requested 1250 ps; the PLL steps in 223 ps)
clk_sd -> DDIO output (datain_h = 0, datain_l = 1) -> DRAM_CLK pin  = inverted clk_sd
```
- **Why inverted:** the controller launches commands on the rising edge of `clk`; the SDRAM samples on the rising
  edge of DRAM_CLK. With an inverted clock the SDRAM samples about half a period later, so the command has had
  ~4.5 ns to settle (setup) and stays ~4.5 ns after (hold). With a non-inverted clock both edges happen at
  nearly the same moment and setup/hold depends on tiny delay differences (vendor demo: 0°, unconstrained).
- **Why a DDIO output instead of routing the PLL clock straight to the pin:** the DDIO register sits in the same
  kind of I/O cell as the command/data output registers. Its clock-to-pin delay therefore tracks theirs over
  temperature and voltage. A clock routed differently can drift relative to the data by a few ns between hot
  and cold.
- **Why the extra 1.339 ns:** it moves the SDRAM clock edge so that the command windows and the read-data
  window both have margin (section 9). It was chosen by compiling 500/1000/1500 ps and comparing slacks.
- `compensate_clock = CLK0`: the PLL aligns `clk` at the registers with CLOCK_50 at the pin, so all internal
  timing is relative to a known reference.

---------------------------------------------------------------------------------------------------------------

## 8. The SDRAM pins: I/O registers in the IOE

Every SDRAM signal is driven from, or captured into, a register **inside the I/O cell (IOE)** of its pin:

| QSF assignment | Effect |
|---|---|
| `FAST_OUTPUT_REGISTER ON` (ADDR, BA, RAS/CAS/WE, DQM, DQ) | output register placed in the IOE: short, fixed clock-to-pin delay, the same on every build |
| `FAST_OUTPUT_ENABLE_REGISTER ON` (DQ) | the tri-state enable register in the IOE too (Quartus duplicates `sd_dq_oe` into 16 copies) |
| `FAST_INPUT_REGISTER ON` (DQ) | read data captured right at the pin (`dq_in`) |
| `ALLOW_SYNCH_CTRL_USAGE OFF` on `sdram_ram:u_ram` | **essential**: otherwise synthesis builds address registers with "synchronous clear + load", which IOE registers do not support; Quartus then silently leaves them in the core ("Can't pack ... cannot simultaneously use clear and load") with a long, build-dependent delay |

Without IOE registers the pin delays depend on where the fitter happens to put the logic. A design can then
work on one build and fail after an unrelated change. Check: `output_files/DDR_TEST.fit.rpt`, table "Bidir Pins"
/ "Output Pins", columns Input/Output/Output Enable Register = yes; and no "Can't pack" warnings.

### DQ bus direction
- DQ is driven only during the clock of a WRITE command (`sd_dq_oe` high for exactly one clock).
- The tri-state buffer is in the top level: `assign DRAM_DQ = dq_oe ? dq_o : 'z`.
- Turnaround is safe: a READ's data appears 2+ clocks after the command and the bus is released long before the
  next WRITE, because only one access is in flight. The testbench checks for bus contention.

---------------------------------------------------------------------------------------------------------------

## 9. Timing at the pins — where the windows are

Times are relative to the `clk` rising edge E0 at the registers. `d` = clock-to-pin delay of an IOE output
register (similar for the DDIO clock and the command pins, roughly 2-5 ns depending on corner). One clock =
8.929 ns, so E1 = 8.93, E2 = 17.86, E3 = 26.79.

```
clk (FPGA)     E0            E1            E2            E3
               |_____        |_____        |_____        |_____
               0             8.93          17.86         26.79

DRAM_CLK            S0            S1            S2
(pin)               5.80+d        14.73+d       23.66+d      (= clk_sd + 1.339 ns, inverted)

command pins   [== READ ===========][== next =======...      changes at 0+d, 8.93+d, ...
                    ^ sampled at S0: setup 5.80 ns, hold 3.13 ns (need tIS 1.5 / tIH 0.8)

DQ at FPGA pin                              [=== data ===]
(READ, CL2)                                  ^ from S1+tAC = 20.7+d+board
                                                           ^ until S2+tOH = 26.7+d+board
dq_in capture                                              E3 = 26.79
```

**Read data:** the data word for a READ sampled at S0 is driven by the chip after S1 (access time tAC = 6.0 ns
max at CL2) and held until tOH = 3.0 ns (min) after S2. The FPGA captures at **E3**, the 3rd edge after issuing
READ (`RD_CAPTURE = CL + 1`). E3 must fall inside the window; with ~0.5 ns of board delay that means about
`0 < d < 5.3 ns` (minus register setup/hold). The simulation sweep agrees: reads pass for d = 0...5 ns and fail
at 6 ns. The real device's d lies inside that range at all corners, which the static timing analysis confirms
with real silicon numbers (section 10).

**Commands/write data:** launched at E0, sampled at S0 = 5.80+d. Since the clock pin and command pins both carry
the same d, d cancels out: setup ≈ 5.8 ns, hold ≈ 3.1 ns before per-pin skew, versus 1.5 / 0.8 required.

---------------------------------------------------------------------------------------------------------------

## 10. Static timing constraints (`DDR_TEST.sdc`) and results

```tcl
create_clock -name CLOCK_50 -period 20.000 [get_ports CLOCK_50]
derive_pll_clocks                       ;# clk = ...pll1|clk[0], clk_sd = ...pll1|clk[1]
derive_clock_uncertainty
create_generated_clock -name sdram_clk -source [get_pins $clk_sd] -invert [get_ports DRAM_CLK]

set_output_delay -clock sdram_clk -max  2.0 $sdram_out   ;# tIS 1.5 + 0.5 board skew
set_output_delay -clock sdram_clk -min -1.3 $sdram_out   ;# -(tIH 0.8 + 0.5)
set_input_delay  -clock sdram_clk -max  6.5 DRAM_DQ      ;# tAC 6.0 + 0.5
set_input_delay  -clock sdram_clk -min  2.5 DRAM_DQ      ;# tOH 3.0 - 0.5
set_multicycle_path -from sdram_clk -to clk -setup -end 2
```
- `sdram_clk` is described at the **pin**, so Quartus knows exactly when the chip sees its clock, including the
  DDIO delay and the PLL phase.
- Output delays are the chip's input setup/hold; input delays are the chip's access/hold times (+/- board).
- **The multicycle**: by default Quartus would assume read data launched by the SDRAM clock edge S1 is captured
  at the next FPGA edge (E2). We capture at E3, so `-setup 2`. **No `-hold` multicycle**: the default hold check
  (one period before the setup edge) is exactly the physical requirement, that the *next* word must not arrive
  before E3. An extra `-hold 1` (a common recipe) hides real hold failures. In this design it once reported
  +11.5 ns hold slack where the truth was -0.55 ns.
- `set_false_path` for CKE (constant), buttons and LED.

Results at 112 MHz, worst slack per corner (`quartus_sta -t DDR_TEST/sta_io.tcl`):

| | out setup | out hold | in setup | in hold | core setup |
|---|---|---|---|---|---|
| Slow 85 °C | 1.18 | 1.84 | 0.74 | 3.25 | 0.59 |
| Fast 0 °C | 2.08 | 1.73 | 2.58 | 1.27 | 5.31 |

All positive, so the design meets timing over temperature and voltage. Core logic Fmax ≈ 122 MHz.

### What made 112 MHz close (it did not at first)
The critical path was the same-cycle request decode, ending at the IOE registers on the far edge of the chip:
- `wait_cnt` was 16 bits because it also counted the 200 us init. It was split into a 16-bit `init_cnt` and a
  4-bit `wait_cnt`.
- Address/data/DQM registers are now loaded **every clock** (`sd_a <= hit ? column : row`, `sd_dq_o <= {din,din}`,
  `sd_dqm <= mask`). Only `cmd` depends on the full decision; the chip ignores A/DQ/DQM unless a command uses
  them.
- Refresh compare registered (`ref_force/ref_early`).
- The request is no longer latched (`addr` held by the requester).

---------------------------------------------------------------------------------------------------------------

## 11. Verification

1. **Simulation** (`DDR_TEST/sim`, Questa: `./run_sim.sh [TCO] [PASSES] [SD_SHIFT]`):
   - `sdram_model.sv`, a behavioural W9825G6KH. It checks **every** rule on every command: power-up pause,
     8 refreshes before MRS, ACT to an open bank, READ/WRITE to a closed bank, tRCD, tRP, tRAS, tRC, tRRD, tWR,
     tRFC, tMRD, refresh interval, illegal CL/burst mode, unknown write data. It drives read data only in the
     real valid window (X before tAC and after tOH, Z after tHZ).
   - The testbench adds realistic **I/O delays** (`TCO` on clock/commands, 0.5 ns back) plus the PLL shift.
     Without them, a zero-delay simulation "passes" designs that cannot work.
   - Independent X-aware read check in the testbench (the tester's `!=` treats X as equal, which once hid a
     failure), bus-contention check, latency histogram.
   - Results at 112 MHz: 2 full passes (~2.1 M accesses), 0 errors; injected error detected; TCO sweep passes
     0-5 ns and fails at 6 ns, as predicted in section 9.
2. **Static timing**: section 10, both corners, I/O and core.
3. **Hardware**: `ram_tester` runs forever over the whole window. Each pass: sequential write, verify,
   bit-reversed-order write (forces row conflicts and bank changes), rotated-order verify. A new data seed each
   pass, a pattern depending on every address bit, every bit written as 0 and 1. LED: slow blink = OK, fast =
   error (sticky), steady = stalled; KEY injects one bit error to prove the checker works.

---------------------------------------------------------------------------------------------------------------

## 12. Typical reasons SDRAM designs fail (checklist)

| # | Mistake | Symptom | Here |
|---|---|---|---|
| 1 | No or wrong timing constraints on SDRAM pins | random errors, change with temperature or after unrelated edits | full SDC, all corners checked |
| 2 | SDRAM clock = system clock at 0°, or routed differently from data | works on one board/build, not another | inverted DDIO clock + tuned phase |
| 3 | I/O registers not in the IOEs (often silently, see sync clear/load) | timing varies build to build | FAST_* + ALLOW_SYNCH_CTRL_USAGE OFF; checked in fit report |
| 4 | Read data sampled on the wrong edge (off-by-one CL) | every read wrong, or wrong only hot/cold | capture edge derived (section 9) and swept in sim |
| 5 | Wrong geometry (e.g. 10 column bits on a 9-column chip) | aliasing: writes overwrite other addresses; constant-pattern tests pass | 9 columns; address-dependent patterns |
| 6 | Weak test (one constant pattern, e.g. 0x5555) | real faults invisible | 4-phase, address-dependent, scrambled order, error injection |
| 7 | Missing/short power-up, < 8 refreshes, MRS before refresh | chip in undefined state, sometimes works | datasheet sequence, checked by model |
| 8 | Refresh forgotten or starved by long bursts of accesses | data decays after ms-seconds, pattern-dependent | forced refresh at 7.5 us, max gap checked |
| 9 | tRAS/tRC/tWR violated in rare request orders | rare corruption | per-bank age counters; model checks every command |
| 10 | DQ driven while the chip drives (turnaround) | corrupted reads after writes | OE only in the WRITE clock; contention check |
| 11 | CAS latency in the mode register differs from the capture logic | all reads off by one | single `CAS_LATENCY` parameter drives both |
| 12 | Controller and user logic in unrelated clock domains without proper crossing | rare lock-ups or bad data | one clock domain everywhere |
| 13 | Too-fast clock for the CL (CL2 > 133 MHz on -6) | marginal reads | 112 MHz, CL2 |

If you remember the symptoms of your earlier attempt (always wrong / random / temperature dependent / only some
addresses / only after a while), they usually point to one line of this table.

---------------------------------------------------------------------------------------------------------------

## 13. Changing things safely

| Change | How | Then |
|---|---|---|
| Clock frequency | `CLK_MHZ` (DDR_TEST.v) + PLL multiply/divide (sys_pll.v); timings recompute | re-tune `SD_PHASE_PS`, run `sta_io.tcl`, sim with `+define+CLK_MHZ` |
| SDRAM clock phase | `SD_PHASE_PS` (PLL steps of 223 ps at VCO 560 MHz) | compile + `sta_io.tcl`; set sim `SD_SHIFT` to the achieved value (fit report / clocks table) |
| CAS latency | `CAS_LATENCY` (3 needed above 133 MHz); `RD_CAPTURE` follows | resweep phase, sim |
| Window size | `ADDR_BITS` (max 25 = 32 MB) | row width follows automatically |
| Address map | `c_col/c_bank/c_row` in sdram_ram.v | keep column = 9 bits, bank above column |
