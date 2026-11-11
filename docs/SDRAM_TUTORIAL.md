# SDR SDRAM with an FPGA — a complete tutorial

Written for the L project (QMTECH Cyclone IV EP4CE15 + Winbond W9825G6KH-6), but everything except
the numbers applies to any FPGA and any SDR SDRAM.

How to read it:
- Part A explains what an SDRAM is and why it behaves the way it does.
- Part B is the chip's interface: pins, commands, rules.
- Part C shows every operation clock by clock.
- Part D is the controller logic, using our design as the worked example.
- Part E is the physical layer: getting signals to and from the chip at 112 MHz. Most failures are here.
- Part F covers timing constraints and static timing analysis.
- Part G covers verification and debugging.
- Part H lists hands-on experiments for the board.

The reference document for every number is the datasheet: `docs/vendor/W9825G6KH_datasheet.pdf` (Winbond,
rev A04, March 2017). Page references are given as [DS p.N]. Our implementation is in `DDR_TEST/ep4_ce15/rtl/sdram_ram.v`.
`docs/SDRAM_CONTROLLER.md` is the short reference for it.

---------------------------------------------------------------------------------------------------------------

# Part A — What is inside an SDRAM

## A.1 The storage cell
A DRAM bit is a tiny capacitor plus one transistor. A charged capacitor is 1, a discharged one is 0. That makes
DRAM dense and cheap: 1 transistor per bit, against 6 for SRAM. It has three consequences that explain every
"strange" DRAM rule:

1. **Reading is destructive and slow.** The capacitor is far too small to drive anything. To read, a whole **row**
   of cells is connected to long wires (bit lines). Each capacitor nudges its bit line by a few tens of mV, and a
   **sense amplifier** per column amplifies that to a full logic level. That takes time: the **row access**.
2. **The row has to be written back.** Sensing drains the capacitors. The sense amplifiers drive the full levels
   back into the cells (restore). The row must stay connected long enough for this to finish: that is the
   minimum **tRAS**.
3. **Charge leaks.** Every row loses its charge within some tens of ms. Each row must be read and restored
   periodically: **refresh**.

## A.2 Rows, columns and the "row buffer"
```
                 column 0   column 1   ...   column 511       (x16 bits each)
row 0      ->    [cell]     [cell]           [cell]
row 1      ->    [cell]     [cell]           [cell]
...                                                     8192 rows
row 8191   ->    [cell]     [cell]           [cell]
                    |          |                |
                 [sense amplifiers = "row buffer" = 512 x 16 bits = 1 KB]
                                  |
                           column decoder -> DQ[15:0]
```
- **ACTIVATE (open a row):** copies one row (here 1 KB) into the sense amplifiers. Slow (tRCD = 15 ns before
  the data can be used).
- **READ/WRITE a column:** works on the sense amplifiers only. Fast (one per clock), with a fixed pipeline delay
  for reads (CAS latency).
- **PRECHARGE (close the row):** disconnects the row (it has been restored) and resets the bit lines to the
  half-voltage needed for the next sensing. Takes tRP = 15 ns before another row can be opened.

The sense amplifiers act as a 1 KB cache that you manage by hand. An access to the row that is already open is
fast (a "row hit"). An access to another row of the same bank has to close and reopen first (a "row conflict").

## A.3 Banks
The chip contains **4 independent arrays (banks)**, each with its own row buffer [DS p.6]. While one bank is busy
opening or closing a row, another bank can be read. Our 32 MB chip is 4 banks x 8192 rows x 512 columns x 16
bits [DS p.3].

## A.4 What "synchronous" adds (SDR SDRAM vs older DRAM)
Older DRAM (FPM/EDO) was asynchronous: you toggled RAS/CAS strobes and waited for analog delays. SDR SDRAM samples
**every input on the rising edge of its clock** and produces read data a fixed number of clocks later. Every
operation therefore becomes "put a command on the pins, wait N clocks". That makes it easy for an FPGA state
machine to drive. The price is that the clock and data must arrive at the chip with correct timing (Part E).
"SDR" = single data rate: one data word per clock (DDR uses both edges).

## A.5 Refresh in practice
The chip has an internal row counter. Each **AUTO REFRESH** command refreshes the next row (in all 4 banks at
once) and advances the counter. The datasheet requires **8192 refreshes per 64 ms** [DS p.15 tREF], i.e. one
every 7.8125 us on average. During a refresh all banks must be closed and nothing else can happen for tRC.

---------------------------------------------------------------------------------------------------------------

# Part B — The chip's interface (W9825G6KH-6)

## B.1 Pins [DS p.4-5]
| Pin(s) | Dir | Meaning |
|---|---|---|
| CLK | in | clock; everything is sampled on its **rising** edge |
| CKE | in | clock enable; low = power-down / self-refresh / suspend. We keep it high |
| CS# | in | chip select; high = ignore the command (DESELECT) |
| RAS#, CAS#, WE# | in | together with CS# they encode the command |
| BS0, BS1 (BA) | in | bank select |
| A0-A12 | in | row address (13 bits) on ACTIVATE; column (A0-A8, **9 bits**) on READ/WRITE; A10 has special meaning |
| DQ0-DQ15 | in/out | data |
| LDQM, UDQM | in | byte masks for DQ[7:0] / DQ[15:8] |

## B.2 Commands [DS p.12, Table 1]
| Command | CS# RAS# CAS# WE# | BA | A10 | Other A | Notes |
|---|---|---|---|---|---|
| NOP | L H H H | x | x | x | idle clock |
| DESELECT | H x x x | x | x | x | same as NOP |
| ACTIVATE | L L H H | bank | row | row | opens a row in a bank |
| READ | L H L H | bank | 0 | column | CAS latency later, data appears |
| READ + auto-precharge | L H L H | bank | 1 | column | closes the row automatically afterwards |
| WRITE | L H L L | bank | 0 | column | data must be on DQ **in the same clock** |
| WRITE + auto-precharge | L H L L | bank | 1 | column | |
| PRECHARGE (one bank) | L L H L | bank | 0 | x | closes the row of that bank |
| PRECHARGE ALL | L L H L | x | 1 | x | closes all banks |
| AUTO REFRESH | L L L H | x | x | x | all banks must be closed |
| MODE REGISTER SET | L L L L | 0 | mode | mode | configuration |
| BURST STOP | L H H L | x | x | x | only for full-page bursts |

Our controller encodes them as `{CS#, RAS#, CAS#, WE#}` (`CMD_*` in sdram_ram.v). CS# is always 0. We use NOP
instead of DESELECT, which is why Quartus reports DRAM_CS_N as "stuck at GND".

## B.3 The mode register [DS p.20]
Written once by MODE REGISTER SET, with the value on A[12:0]:
| Bits | Field | Our value |
|---|---|---|
| A2:A0 | burst length: 000=1, 001=2, 010=4, 011=8, 111=full page | 000 (1 word) |
| A3 | burst type: 0 sequential, 1 interleave | 0 |
| A6:A4 | CAS latency: 010=2, 011=3 | 010 (CL2) |
| A8:A7 | test mode, must be 00 | 00 |
| A9 | write burst: 0 = same as read burst, 1 = single writes | 0 |
| A12:A10, BA | reserved, 0 | 0 |
So the value is `0x020`.

**Burst length** is how many consecutive columns a single READ/WRITE transfers (one per clock). Bursts suit
cache-line or video fetches. A CPU doing random single-byte accesses wants burst length 1: every command moves
exactly one word, and there are no "burst still running" interactions to handle.

**CAS latency (CL)** is the number of clocks between the READ command and its data. Its allowed values are tied
to the clock frequency [DS p.4, p.15]:
| Speed grade | CL2 max | CL3 max |
|---|---|---|
| -6 / -6I / -6J / -6L | 133 MHz (tCK >= 7.5 ns) | 166 MHz (tCK >= 6 ns) |
| -75 | 100 MHz | 133 MHz |
At 112 MHz CL2 is legal on a -6 part. CL2 is one clock faster per read than CL3.

## B.4 The timing rules [DS p.15]
Every rule is a minimum time between two commands. Values for **-6** (and in brackets **-6I/-6J/-6L** where
different):
| Symbol | From -> to | -6 | Meaning |
|---|---|---|---|
| tRCD | ACT -> READ/WRITE (same bank) | 15 ns [18] | row must be sensed before its columns are used |
| tRAS | ACT -> PRE (same bank) | 42 ns min, 100 us max | restore must finish; a row must not stay open longer than 100 us |
| tRP | PRE -> ACT/REF | 15 ns [18] | bit lines must be precharged |
| tRC | ACT -> ACT (same bank), REF -> REF/ACT | 60 ns | whole row cycle; also the refresh duration |
| tRRD | ACT -> ACT (different banks) | 2 clk | power/current limit |
| tCCD | READ/WRITE -> READ/WRITE | 1 clk | columns can be accessed every clock |
| tWR | last write data -> PRE | 2 clk | write data must reach the cells before closing |
| tRSC (tMRD) | MRS -> next command | 2 clk | |
| tREF | 8192 refreshes within | 64 ms | at 0-70 °C (-6) |
| tCK | clock period, CL2 | >= 7.5 ns | |

> **Chip marking matters.** The chip on this board is confirmed **W9825G6KH-6** (checked 5 October 2026), so
> tRCD = tRP = 15 ns and our 2-clock spacing (17.86 ns at 112 MHz) is correct. On another board with a **-6I/-6J/-6L**
> part (industrial, 18 ns) it would be 0.14 ns too short: set the 15 to 18 in `T_RCD`/`T_RP` (3 clocks: +1 clock
> on row misses).

And the pin timing (Part E uses these):
| Symbol | Meaning | -6 |
|---|---|---|
| tAC (CL2) | CLK rising -> read data valid (max) | 6.0 ns |
| tOH | read data held after the next CLK rising (min) | 3.0 ns |
| tLZ / tHZ (CL2) | output turns on / off | 0 / 6.0 ns |
| tCMS/tAS/tDS/tCKS | setup of command/address/write data/CKE before CLK | 1.5 ns |
| tCMH/tAH/tDH/tCKH | hold after CLK | 0.8 ns |
| tCH, tCL | clock high / low time | >= 2 ns |

## B.5 DQM
- On a **write**, DQM high means "don't write this byte", with **zero latency** (it applies to the data in the
  same clock). This is how we write single bytes into 16-bit words.
- On a **read**, DQM high puts the output drivers into Hi-Z **2 clocks later** [DS p.5]. It is used to avoid bus
  clashes when a read burst is interrupted by a write. We don't need that with burst length 1.
- During power-up DQM should be held high [DS p.7].

## B.6 Power-up sequence [DS p.7]
1. Apply power and clock, hold CKE and DQM high, NOP on the command pins.
2. Wait **200 us**.
3. PRECHARGE ALL.
4. **8 x AUTO REFRESH** (each followed by tRC), before or after step 5.
5. MODE REGISTER SET, then wait tRSC.
Skipping the pause or the refreshes often "mostly works", which makes such bugs hard to find.

---------------------------------------------------------------------------------------------------------------

# Part C — Every operation, clock by clock

Conventions: our system clock `clk` is 112 MHz (8.93 ns). Edges are named **E0, E1, ...**. A command shown at En
is **launched** by the FPGA at En and **sampled by the SDRAM about half a clock later** (Part E explains why). The
SDRAM clock edges are named **S0, S1, ...**, with Sn about 0.65 clocks after En.

## C.1 Read, row already open (row hit) — 4 clocks
```
          E0       E1       E2       E3       E4
clk     __|‾‾|__|‾‾|__|‾‾|__|‾‾|__|‾‾|__
cmd       [READ ][NOP   ][NOP   ][NOP   ]
BA/A      [bank, column]
SDRAM        S0       S1       S2
DQ                       (driven after S1+tAC ... until S2+tOH)
                                 [ data ]
dq_in                            captured at E3
ack                                    [ack]   (raised at E3; requester sees it in the clock after E3)
dout                                   [data]  (combinational from dq_in during the ack clock, then held)
```
`req` is seen at E0, READ is issued at E0 (same clock), and `ack` is visible from E3 to E4: **4 clocks** from the
clock where `req` was high to the clock where `ack` is high.

## C.2 Read, bank closed — 6 clocks
```
E0: ACT (bank, row)
E1: NOP              (tRCD = 2 clocks: 17.9 ns >= 15)
E2: READ (bank, column)
E5: data captured, ack
```

## C.3 Read, another row open in that bank (row conflict) — 8 clocks
```
E0: PRE (bank)       (allowed only if tRAS and tWR since that row's ACT/WRITE are met)
E1: NOP              (tRP = 2 clocks)
E2: ACT (bank, new row)
E3: NOP              (tRCD)
E4: READ
E7: data, ack
```

## C.4 Write (row hit) — 1 clock, "posted"
```
          E0
cmd       [WRITE]           BA = bank, A = column, A10 = 0
DQ        [{din,din}]       both bytes carry the same value...
DQM       [01 or 10]        ...and DQM masks the byte that must not change
ack       [ack]             raised at E0: the write is done as far as the user is concerned
```
The SDRAM takes the data at S0. The controller is free again at E1. The only lasting effect is that this bank
must not be precharged before **tWR = 2 clocks** (tracked by `wr_age`).

## C.5 Refresh
```
En:   PRE ALL (A10=1)    (only when every open bank satisfies tRAS and tWR)
En+2: AUTO REFRESH       (tRP)
...   7 clocks           (tRC = 60 ns -> 7 clocks = 62.5 ns)
En+9: next command (any bank is closed, so the next access needs ACT)
```

## C.6 Initialisation
```
reset released
  22 500 clocks (200.9 us) NOP, DQM=11
  PRE ALL, wait 2
  REF, wait 7   (x8)
  MRS 0x020, wait 2
  ready = 1
```

## C.7 Why not "close the row after every access"? (closed-page policy)
Alternative: READ/WRITE **with auto-precharge** (A10 = 1), so every access is ACT -> READ+AP. Every access then
costs the same (6 clocks for a read here), there are no row conflicts and no bookkeeping, and refresh can start
at once. With a CPU, most accesses go to the same few rows, so keeping rows open makes the common case 4 clocks
instead of 6. We chose **open-page** for speed. Closed-page is the right choice when you need fully deterministic
timing. Both are easy with this chip.

---------------------------------------------------------------------------------------------------------------

# Part D — The controller logic (`sdram_ram.v`)

## D.1 User interface
```verilog
input  req;  input we;  input [17:0] addr;  input [7:0] din;
output ack;  output [7:0] dout;  output ready;
```
`req` is a one-clock pulse. addr/we/din are held by the requester until `ack`. One access at a time.

## D.2 Address mapping
```
addr[0]        -> byte lane (DQM select)        16-bit SDRAM word, 2 bytes per word
addr[9:1]      -> column  (9 bits, 1 KB rows)
addr[11:10]    -> bank
addr[17:12]    -> row     (only the rows we need)
```
Why the bank bits sit right above the column bits: a CPU uses several areas at once (code, stack, variables,
screen). Each 1 KB block goes to the next bank, so different areas tend to land in different banks. Each bank
keeps its own row open, so all of them stay "hot". If the bank were the top address bits instead, code and stack
in the same 64 KB would fight over one bank's single row buffer.

## D.3 Keeping track of the banks (the "age" counters)
For each bank `b`:
```verilog
row_open[b]   // a row is open
open_row[b]   // which row
act_age[b]    // clocks since ACT on this bank   (saturates at 15)
pre_age[b]    // clocks since PRE on this bank
wr_age[b]     // clocks since WRITE on this bank
act_any_age   // clocks since ACT on any bank
```
Every clock all ages increase by 1. Issuing a command sets the matching age to 1. Every datasheet rule becomes a
comparison:
```verilog
pre_ok[b] = !row_open[b] || (act_age[b] >= T_RAS && wr_age[b] >= T_WR);   // may close b
rp_ok[b]  = pre_age[b] >= T_RP;                                             // b finished closing
read/write allowed if  act_age[b] >= T_RCD
ACT allowed if         rp_ok[b] && act_age[b] >= T_RC && act_any_age >= T_RRD
```
The `T_*` values are computed from nanoseconds by `ceil(ns * CLK_MHZ / 1000)`, so changing `CLK_MHZ`
re-derives all of them. **Why this structure:** each rule is enforced in exactly one place, independently of what
sequence of requests arrives. A design that instead hard-codes sequences ("after ACT wait 2, then READ, then
...") tends to break when an unusual sequence happens, for example a refresh in the middle of a row conflict.

## D.4 The decision, every clock (`S_IDLE`)
```
if (wait_cnt != 0)                          -> do nothing (spacing after REF/MRS)
else if refresh due (forced, or early and idle):
        if any row open and all pre_ok      -> PRE ALL
        else if all closed and all rp_ok    -> REF, reset refresh timer, wait tRC
else if a request is present:
        if its row is open in its bank:
             if act_age >= tRCD             -> WRITE (ack now) or READ (go to S_READ)
        else if another row is open there:
             if pre_ok                      -> PRE that bank
        else (bank closed):
             if ACT allowed                 -> ACT
```
At most one command per clock. A row conflict therefore becomes PRE, wait, ACT, wait, READ over consecutive
clocks, each step taken as soon as its rule allows.

**Same-clock start:** a request is acted on in the very clock in which `req` is high (`have = pend | req`). `pend`
only remembers a request that had to wait (refresh in progress, or a read still completing). This saves one
clock per access.

## D.5 Reading the data (`S_READ`)
READ is issued at E0 and `wait_cnt` counts to E3. At E3 the data is captured at the pin into `dq_in`, and in the
same edge `ack` and `rd_valid` are raised. `dout` is a multiplexer: `rd_valid ? byte_of(dq_in) : dout_hold`. In
the ack clock the user sees the fresh byte straight from the capture register, and afterwards the held copy. This
saves a further clock.

## D.6 Refresh scheduling
- `ref_timer` counts clocks since the last REF.
- After 420 clocks (3.75 us): refresh if idle ("early").
- At 840 clocks (7.5 us): refresh even if a request is waiting ("forced"). The request waits about 10 clocks.
- So the gap between refreshes is at most 7.5 us + one access ≈ 7.6 us < 7.8125 us, which meets 8192 per 64 ms
  [DS p.15]. The simulation measures the actual maximum gap: 7597.7 ns.
- Refresh closes every row, which also guarantees tRAS max (100 us) is never exceeded.

## D.7 Registers that drive the pins
Every SDRAM output is a register: `cmd`, `sd_ba`, `sd_a`, `sd_dqm`, `sd_dq_o`, `sd_dq_oe`. On the input side,
`dq_in` captures DQ. No pin is ever driven by combinational logic. This is required for predictable pin timing
(Part E). For 112 MHz these registers are loaded **every clock** with "what the next command would need"
(`sd_a <= hit ? column : row`, `sd_dq_o <= {din,din}`, DQM from `we` and `addr[0]`). Only `cmd` depends on the
full decision. The SDRAM ignores A/DQ/DQM unless the command uses them, so this is harmless, and it removes
logic from the slowest paths.

---------------------------------------------------------------------------------------------------------------

# Part E — The physical layer: making 112 MHz work at the pins

This is the part that decides whether a design works on real boards. Simulation without delays says nothing
about it.

## E.1 Basic I/O timing terms
- **tco (clock-to-out)**: delay from a register's clock edge to its output pin changing. For a Cyclone IV IOE
  output register this is roughly 2-5 ns, depending on corner.
- **Setup (tsu)**: how long before the receiving clock edge the data must be stable.
- **Hold (th)**: how long after the edge it must stay stable.
- **Corners**: delays change with chip speed grade, temperature and voltage. Quartus analyses a **slow** corner
  (hot, low voltage: long delays, so setup is critical) and a **fast** corner (cold, high voltage: short delays,
  so hold is critical). A design must pass both. "It works on my desk" only checks one point in between.
- **Slack**: the margin by which a requirement is met. Positive = OK, negative = violation.

## E.2 The fundamental problem
At 112 MHz a clock period is 8.93 ns. The SDRAM needs command/address stable 1.5 ns before and 0.8 ns after its
clock edge: a 2.3 ns window that must sit inside every 8.93 ns, at **the chip's pins**. Read data comes back
6.0 ns after the SDRAM clock edge and stays valid only until 3.0 ns after the *next* edge. The FPGA must sample it
inside that window. Delays of 2-5 ns (tco, board traces, input buffers), varying with temperature, are the same
order of magnitude as the windows. They cannot be ignored.

## E.3 Where the SDRAM clock comes from: the options
**Option 1 — the system clock sent straight to the SDRAM (0°).** Command launched at FPGA edge E0, SDRAM samples
at its own edge, which is E0 + (clock path delay). Command arrival is E0 + tco. Both delays are a few ns and
uncontrolled, so setup or hold can fail depending on which one is longer. This is the vendor demo
(`PLL_SDRAM`, 0°), and it has no timing constraints. It works on the demo board by luck of the routing.

**Option 2 — a PLL output with a phase shift.** Better: the clock edge can be moved to the middle of the command
window. But the clock leaves the FPGA through a different path (PLL -> clock network -> pin) than the data (IOE
register -> pin). Their delays differ and drift differently with temperature, so the margin must cover the
drift. Common in tutorials, often with a magic -3 ns. The demo's unused `sdram_pll0` has exactly that.

**Option 3 — inverted clock through a DDIO output register (our choice).**
```verilog
altddio_out ( .datain_h(1'b0), .datain_l(1'b1), .outclock(clk_sd), .dataout(DRAM_CLK) )
```
A DDIO (double data rate) output register drives `datain_h` while the clock is high and `datain_l` while it is
low. With h=0, l=1 the pin outputs the **inverted** clock. Two benefits:
1. The DDIO register is an **IOE output register**, the same kind of cell as the command and data registers. Its
   tco tracks theirs over temperature and voltage, so the clock and the data it samples move **together**.
2. Inversion puts the SDRAM's sampling edge in the **middle** of the FPGA clock period. The command launched at
   E0 changes at E0+tco and is sampled at E0 + T/2 + tco. Both carry the same tco, so the delays cancel:
   setup ≈ T/2 and hold ≈ T/2.

**Fine-tuning:** `clk_sd` is a second PLL output, `clk` delayed by 1.339 ns. It moves the SDRAM edge slightly
later, which balances the command window against the read window (E.6). The value came from compiling with
several phases and comparing slacks (E.8).

## E.4 Registers in the I/O cells (IOE registers)
A Cyclone IV pin has its own small registers right at the pad: input, output and output-enable. If the last
register before a pin is placed in the core instead, the path goes through general routing. Its delay then
depends on placement and **changes from build to build**. A design can pass, and after an unrelated edit fail.

QSF assignments used:
```tcl
set_instance_assignment -name FAST_OUTPUT_REGISTER ON         -to DRAM_ADDR[*]   (also BA, RAS/CAS/WE, DQM, DQ)
set_instance_assignment -name FAST_OUTPUT_ENABLE_REGISTER ON  -to DRAM_DQ[*]
set_instance_assignment -name FAST_INPUT_REGISTER ON          -to DRAM_DQ[*]
set_instance_assignment -name ALLOW_SYNCH_CTRL_USAGE OFF      -to "sdram_ram:u_ram"
```
The last line was found the hard way. Synthesis likes to build registers with "synchronous clear" and
"synchronous load" inputs. IOE registers don't have those. Quartus then silently keeps the register in the core
and only warns "Can't pack node ... cannot simultaneously use clear and load". With ALLOW_SYNCH_CTRL_USAGE OFF,
synthesis puts that logic in front of the register instead, and the register can be packed.

How to verify: in `output_files/DDR_TEST.fit.rpt`, tables "Output Pins" and "Bidir Pins": the columns "Output
Register", "Output Enable Register" and "Input Register" must say **yes** for every SDRAM pin.

The rules for the RTL that make packing possible:
- each pin is driven directly by one register (no logic after it);
- the input register `dq_in <= DRAM_DQ` is unconditional (no enable, no reset);
- the tri-state is `assign DRAM_DQ = dq_oe ? dq_o : 'z;` with `dq_oe` and `dq_o` both registers.

## E.5 The command/write window, with numbers
Times relative to the FPGA clock edge E0 at the registers; `d` = IOE tco (same for all SDRAM outputs). Clock
period T = 8.929 ns; `clk_sd` = `clk` + 1.339 ns; DRAM_CLK = inverted `clk_sd`.
```
DRAM_CLK rising edge at the pin:  E0 + T/2 + 1.339 + d = E0 + 5.80 + d
command pins change at:           E0 + d   (and next at E0 + 8.93 + d)
setup at the SDRAM = 5.80 ns      (needs 1.5)   -> 4.3 ns spare
hold  at the SDRAM = 3.13 ns      (needs 0.8)   -> 2.3 ns spare
```
These are ideal numbers. Real pins differ by a few hundred ps (pin-to-pin skew, trace lengths), which is what the
static timing analysis accounts for (F.4).

## E.6 The read window, with numbers (the critical one)
READ is launched at E0. The SDRAM samples it at S0 = 5.80 + d. With CL2 the data belongs to SDRAM edge S2:
- it is driven out after S1 = 14.73 + d, at the latest by **tAC = 6.0 ns**: valid from 20.73 + d;
- it is held until at least **tOH = 3.0 ns** after S2 = 23.66 + d: valid until 26.66 + d;
- add about 0.5 ns of board delay back to the FPGA: window **[21.2 + d, 27.2 + d]** at the FPGA pin.

Which FPGA edge can sample it? E2 = 17.86 is too early, E3 = 26.79 is inside, E4 = 35.7 is too late. So we
capture at **E3**: `RD_CAPTURE = CL + 1 = 3`.

E3 must be inside the window with room for the input register's setup and hold:
- late enough: 26.79 >= 21.2 + d + tsu, so **d <= ~5.3 ns** (slow corner limit)
- early enough: 26.79 + th <= 27.2 + d, so **d >= ~0 ns** (fast corner limit)

Simulation with modelled delays confirms this: reads pass for d = 0 ... 5 ns and fail at 6 ns (section G.2). The
real chip's d is inside that range at both corners, and STA confirms it with silicon numbers.

**Why the window gets smaller at higher clock speeds:** tAC and tOH are fixed in ns. The valid window lasts about
`T - tAC + tOH` = 5.9 ns at 112 MHz (7.0 ns at 100 MHz). Above roughly 133 MHz CL2 is no longer allowed, and
CL3 adds a clock.

## E.7 Bus turnaround
DQ is driven by the FPGA only during the WRITE clock (`dq_oe` = 1 for one clock). The SDRAM drives DQ only around
S1...S2 + tHZ after a READ. Because our controller never has a READ and a WRITE in flight together, the two never
overlap. Controllers that pipeline reads and writes must insert gaps or use DQM [DS p.37]. The testbench checks
for contention anyway.

## E.8 Choosing the clock phase
Procedure used:
1. Compile with `SD_PHASE_PS` = 500, 1000, 1500.
2. Run `quartus_sta -t sta_io.tcl` (prints worst slack per corner for SDRAM outputs, DQ inputs and core logic).
3. Outputs gain setup slack and lose hold slack as the phase increases. Inputs do the opposite.
4. Pick the value where the minimum of all four is largest. At 112 MHz: 1250 ps requested, 1339 ps realised (the
   PLL moves in 223 ps steps = VCO period / 8 at 560 MHz).

---------------------------------------------------------------------------------------------------------------

# Part F — Timing constraints (SDC) and static timing analysis

## F.1 Why constraints are not optional
Quartus only checks what it is told. Without an SDC for the SDRAM pins, the timing report is "clean" because
nothing is checked: the vendor demo's report only checks the JTAG clock. The design may still fail.

## F.2 Our SDC, line by line (`DDR_TEST/ep4_ce15/DDR_TEST.sdc`)
```tcl
create_clock -name CLOCK_50 -period 20.000 [get_ports CLOCK_50]
derive_pll_clocks           ;# creates clk (pll1|clk[0]) and clk_sd (pll1|clk[1]) with their real phases
derive_clock_uncertainty    ;# adds PLL jitter etc.
```
```tcl
create_generated_clock -name sdram_clk -source [get_pins $clk_sd] -invert [get_ports DRAM_CLK]
```
This describes the clock **as it appears at the DRAM_CLK pin**: derived from `clk_sd` and inverted (the DDIO).
Quartus adds the real path delay, so all SDRAM timing is referenced to the moment the chip sees its clock edge.

```tcl
set_output_delay -clock sdram_clk -max  2.0 $sdram_out    ;# tCMS/tDS 1.5 + 0.5 board skew
set_output_delay -clock sdram_clk -min -1.3 $sdram_out    ;# -(tCMH/tDH 0.8 + 0.5)
```
An output delay says "outside the FPGA, this much time is used up". `-max` is the receiver's setup requirement
(plus board), `-min` is minus its hold requirement.

```tcl
set_input_delay  -clock sdram_clk -max 6.5 DRAM_DQ        ;# tAC 6.0 + 0.5 board
set_input_delay  -clock sdram_clk -min 2.5 DRAM_DQ        ;# tOH 3.0 - 0.5
```
An input delay says "data arrives at the pin this long after sdram_clk". Max = latest (tAC), min = earliest
change (tOH).

```tcl
set_multicycle_path -from [get_clocks sdram_clk] -to [get_clocks $clk100] -setup -end 2
```
**The multicycle.** By default Quartus assumes data launched by an `sdram_clk` edge is captured by the *next*
`clk` edge. Our data (launched by S1, see E.6) is captured one `clk` edge later, at E3. `-setup -end 2` moves
the capture edge one clock later.

**There is deliberately no `-hold` multicycle.** After moving the setup edge, Quartus checks hold against the
edge one period earlier. That edge is exactly the physical hold requirement: data from the *next* read (launched
by S2) must not arrive before E3. A frequently copied recipe adds `-hold 1` to "restore" hold. Here that would
check against an edge another period earlier and make every hold path look 8.9 ns better than it is. During
this project that recipe showed +11.5 ns hold slack where the truth was -0.55 ns (fixed, then re-closed).

```tcl
set_false_path -to [get_ports DRAM_CKE]      ;# constant
set_false_path -from [get_ports {RESET_N KEY}]
set_false_path -to   [get_ports LEDR]
```

## F.3 Reading the reports
- `output_files/DDR_TEST.sta.summary`: worst slack per clock, per corner. All must be >= 0.
- `DDR_TEST/ep4_ce15/sta_io.tcl` gives the SDRAM-specific view:
```
SLACK slow  out_setup / out_hold / in_setup / in_hold / core_setup / core_hold
SLACK fast  ...
```
- Clock names in reports: `u_pll|...|clk[0]` = `clk`, `sdram_clk` = DRAM_CLK pin. "Setup 'sdram_clk'" = paths
  that end at the SDRAM (outputs). "Setup 'clk[0]'" = paths that end in the FPGA (including DQ inputs and core
  logic).

## F.4 Our results at 112 MHz (ns)
| | out setup | out hold | in setup | in hold | core setup |
|---|---|---|---|---|---|
| Slow 85 °C | 1.18 | 1.84 | 0.74 | 3.25 | 0.59 |
| Fast 0 °C | 2.08 | 1.73 | 2.58 | 1.27 | 5.31 |

These are smaller than the ideal numbers in E.5/E.6 because they include the real per-pin delays, clock
uncertainty and our 0.5 ns board allowance. All positive at both corners.

## F.5 Making the core logic fast enough (what changed between 100 and 112 MHz)
The slowest path was "request arrives -> decide the command -> load an IOE register". IOE registers sit at the
chip edge, far from the logic. Fixes that kept the zero-latency behaviour:
1. `wait_cnt` 16 -> 4 bits (the 200 us count moved to its own `init_cnt`).
2. Address/data/DQM registers loaded every clock, not only when a command is decided.
3. Refresh-due comparisons registered one clock ahead.
4. Requester holds addr/we/din instead of the controller latching them (one multiplexer fewer).
Result: core slack from about 0 ns to +0.59 ns, Fmax about 122 MHz.

---------------------------------------------------------------------------------------------------------------

# Part G — Verification and debugging

## G.1 The SDRAM model (`DDR_TEST/ep4_ce15/sim/sdram_model.sv`)
A behavioural chip that:
- stores data (sparse array) and implements ACT/READ/WRITE/PRE/REF/MRS with BL1;
- drives read data only in its real window: X from S1 + tOH, valid from S1 + tAC, X again from S2 + tOH, Z after
  tHZ. A capture at the wrong moment therefore gets X, not "lucky" data;
- checks **every** rule on every command and reports violations: power-up pause, 8 refreshes, open/closed bank
  state, tRCD, tRP, tRAS, tRC, tRRD, tWR, tRFC, tMRD, refresh interval, illegal mode, unknown write data.

## G.2 The testbench (`tb_ddr_test.sv`)
- **Modelled I/O delays.** `TCO` delays the clock and the commands into the model, the PLL shift is added to the
  clock, and 0.5 ns is added on the way back. Without this, a zero-delay simulation would sample read data at the
  "right" edge for the wrong reason.
- **X-aware read check.** `!==` compares, independent of the tester. The tester's own `!=` treats X as "not
  different", which once hid a failing case.
- Bus-contention check, latency histogram, refresh-gap statistics.
- **TCO sweep:** `./run_sim.sh <TCO> 1` for several values shows the read window directly (0-5 ns pass, 6 ns
  fail).

## G.3 The hardware tester (`ram_tester.v`)
Each pass over the whole window:
1. Sequential write, pattern = f(address, seed).
2. Sequential verify.
3. Write in bit-reversed address order: consecutive accesses jump across rows and banks, which provokes row
   conflicts and precharge timing.
4. Verify in a third, rotated order.
Then a new seed: every bit is written as both 0 and 1. The pattern changes when any single address bit changes,
so address faults (aliasing) are detected. KEY injects one deliberate error to prove the checker works. The LED
shows OK / error / stalled. The first failing address, expected byte and actual byte are kept in registers
(`fail_addr/fail_exp/fail_got`) for SignalTap.

## G.4 Symptom -> likely cause
| Symptom | Likely cause |
|---|---|
| Every read wrong or all X / FF | wrong CAS latency vs capture edge, mode register not written, init sequence wrong |
| Errors only when hot, or only cold | pin timing marginal (wrong clock phase, missing constraints, registers not in IOEs) |
| Random single-bit errors, different each run | pin timing, or a hold violation (often hidden by a wrong `-hold` multicycle) |
| Errors at addresses that differ in one bit (e.g. +512 words) | wrong column/row/bank width: aliasing |
| Writes to one byte corrupt the other byte | DQM inverted or wrong lane |
| Works for a while, then data decays | refresh missing, too rare, or starved by long access bursts |
| Works after reset, fails after an unrelated code change | registers not packed in IOEs / no constraints, placement-dependent |
| Only after a write followed by a read | bus turnaround contention |
| Only with some access orders | a bank timing rule (tRAS/tRP/tWR/tRC) violated in a rare sequence |

## G.5 Looking inside on hardware
SignalTap (Quartus Tools -> Signal Tap Logic Analyzer) can capture `fail_addr`, `fail_exp`, `fail_got`,
`u_ram|cmd`, `u_ram|state` when `error` rises. The XOR of expected and actual tells you which data bits are
wrong. The failing address tells you row, bank and column. Ask, and I'll add a ready-made SignalTap setup.

---------------------------------------------------------------------------------------------------------------

# Part H — Experiments to do on the board (learning by breaking it)

Each takes one rebuild. None can damage anything. I can set any of them up on request. Expected results come
from the analysis above.

| # | Change | Expected result |
|---|---|---|
| 1 | `RD_CAPTURE` 3 -> 2 (sample one clock early) | every read wrong immediately; simulation fails too |
| 2 | `RD_CAPTURE` 3 -> 4 (one clock late) | every read wrong (data already gone) |
| 3 | `SD_PHASE_PS` -> 4000 or 6000 | STA shows negative slack; hardware errors (possibly only some bits / temperatures) |
| 4 | remove `ALLOW_SYNCH_CTRL_USAGE OFF` | "Can't pack" warnings, lower slack; may still work today, which is the danger |
| 5 | map column to `addr[10:1]` (10 bits, like the vendor demo) | aliasing: tester reports errors at addresses that differ by 1 KB |
| 6 | disable refresh, and change the tester to wait seconds between write and verify | data loss after some seconds (retention is longer than 64 ms at room temperature, so it is temperature dependent) |
| 7 | add `-hold -end 1` to the SDC | report gets "better" by a whole clock period on DQ hold: learn to distrust it |
| 8 | `CAS_LATENCY` 2 -> 3 | still works (RD_CAPTURE follows); one clock more read latency |
| 9 | `CLK_MHZ` 112 -> 125 + PLL change | see which paths fail first (likely DQ input setup and core) |

---------------------------------------------------------------------------------------------------------------

# Appendix 1 — The vendor demo controller compared

`CYCLONE_IV_EP4CE15-master/.../Sdram_Control/` is Terasic's DE0 controller:
- Two dual-clock FIFOs (write side, read side) and page-mode bursts: built for streaming video, not CPU random
  access.
- `Sdram_Params.h`: 10 column bits. The W9825G6KH has 9, so half the address space aliases. Its test writes one
  constant (0x5555) everywhere, so it cannot notice.
- 100 MHz, CL3, SDRAM clock straight from a PLL at 0° (its unused alternative has -3 ns).
- No SDC (the referenced file is missing): nothing about the SDRAM is timing-checked.
- `command.v` infers latches.
It "works" on the board because the board is short and the routing happened to fall right. It is a good example of
why section G.4's "fails after an unrelated change" exists.

# Appendix 2 — Glossary
| Term | Meaning |
|---|---|
| ACT / activate | open a row (copy it into the sense amplifiers) |
| PRE / precharge | close the row(s), prepare bit lines |
| CL / CAS latency | clocks from READ to data |
| BL / burst length | words transferred per READ/WRITE |
| row hit / conflict | access to the open row / to another row in the same bank |
| open-page / closed-page | leave rows open after access / auto-precharge every access |
| DQM | byte mask: write enable per byte (0 latency), read output enable (2 latency) |
| tco | register clock-to-output delay |
| setup / hold | stability required before / after a clock edge |
| slack | margin to a timing requirement (negative = failing) |
| corner | process/voltage/temperature extreme used for timing analysis |
| IOE | I/O element: the pin cell, with its own registers |
| DDIO | double-data-rate I/O register (two values per clock) |
| SDC | Synopsys Design Constraints: timing constraint file |
| STA | static timing analysis (Quartus Timing Analyzer) |
| multicycle path | tells STA that capture happens N clocks after launch |

---------------------------------------------------------------------------------------------------------------

# Appendix 3 — Development history: what was simulated, measured and changed

This is the actual sequence from the first version of the controller to the one running on the board, all on
5 October 2026. Each step lists what was run, what it showed, and what was changed because of it. Several of
the lessons in Parts E-G come directly from these steps.

## 3.1 The tools and how they were used
- **Simulation:** Questa FSE (installed with Quartus 25.1), called from WSL by `DDR_TEST/ep4_ce15/sim/run_sim.sh [TCO] [PASSES] [SD_SHIFT]`.
  The script compiles the RTL (`sdram_ram.v`, `ram_tester.v`) plus the testbench and SDRAM model, runs to the end,
  and prints:
  - pass count and error counts (tester, strict testbench read check, SDRAM model rule violations);
  - read and write latency (min / average / max) and a latency histogram;
  - number of each SDRAM command issued, and the longest gap between refreshes.
- **What the simulation contains:** the real controller and the real hardware tester (the same code as on the
  board), the behavioural W9825G6KH model (G.1), and transport delays that model the FPGA output delay (`TCO`),
  the PLL clock shift (`SD_SHIFT`) and 0.5 ns back to the FPGA. One full test pass over 128 KB took about 1 minute
  of simulation; 2 passes over 256 KB about 5 minutes.
- **Compilation:** `quartus_sh --flow compile DDR_TEST`, about 30-40 s each.
- **Static timing:** `quartus_sta -t sta_io.tcl` prints the worst slack per corner for SDRAM outputs, DQ inputs
  and core logic. Individual paths were listed with `get_timing_paths` to see which registers were involved.
- **Hardware:** program `DDR_TEST.sof`, watch the LED, press KEY (error injection) and RESET.

## 3.2 Step by step

| # | What was run | What it showed | What was changed |
|---|---|---|---|
| 1 | First controller at **100 MHz**, CL2, open-row, inverted DDIO clock, capture at E3. Simulation, 1 pass, TCO 4 ns | PASS, 0 model errors. But a read hit took **5 clocks**, not the intended 4 | `dout` made combinational from the capture register during the ack clock (plus a hold register); ack raised one clock earlier |
| 2 | Simulation, 2 passes + error injection | PASS; read hit now **4 clocks**; injected error caught | — |
| 3 | TCO sweep 1, 2, 7, 8, 9 ns | TCO = 1 ns **passed**, although the analysis said it must fail | Investigated: the tester compares with `!=`, and `X != value` is X, which an `if` treats as false, so X data was never reported. Added an independent X-aware check (`!==`) in the testbench. Re-run: TCO 1 ns FAIL (data X), 2 ns PASS, matching the analysis |
| 4 | First Quartus compile (100 MHz, SDRAM clock = inverted clk, no phase shift) | Timing met, but warning "Can't pack node `sd_a[0..4]` ... cannot simultaneously use clear and load": 5 address registers left in the core | `ALLOW_SYNCH_CTRL_USAGE OFF` on the controller; removed the fast-register assignment on `DRAM_CS_N` (a constant). All SDRAM registers then packed into IOEs; core setup slack 0.70 -> 1.21 ns |
| 5 | Detailed I/O timing report | DQ input **hold slack +11.5 ns**: impossible for a 8.9-10 ns clock | The SDC had `-hold -end 1` next to the setup multicycle. Removed it. True result: fast-corner DQ hold **-0.55 ns** (a real failure) |
| 6 | Recompile with the corrected SDC | Fitter added input delay to fix hold: in-hold fast +0.59, but in-setup slow dropped 3.8 -> 0.99; out-setup slow only 0.49, out-hold 3.2 (lopsided) | Added PLL output c1 = clk + **1.5 ns** to drive the DDIO SDRAM clock |
| 7 | Recompile with the 1.5 ns shift | Worst SDRAM I/O slack 0.49 -> **1.19 ns**; all corners balanced (out 1.87/2.22, in 1.46/1.19) | Testbench given the same 1.5 ns shift |
| 8 | Simulation regression: 2 passes at TCO 4, plus TCO 0.5, 1, 6.5, 7.5 | PASS 0.5-6.5 ns, FAIL 7.5 ns (expected: data sampled too late) | — |
| 9 | **Hardware, 100 MHz** | LED slow blink; KEY -> fast blink; RESET -> slow | — |
| 10 | Changed to **112 MHz** (PLL 50x56/25). Split the 200 us counter from `wait_cnt` (16 -> 4 bits). Compiled with SDRAM clock delay 500 / 1000 / 1500 ps | I/O passed at all three phases, but **core setup -0.036 ns** (failing) at 500/1000, +0.10 at 1500 | Listed the worst 400 core paths: all start at the request inputs (`req`, `addr`, `pend`) and end at IOE registers (`sd_dq_o`, `sd_a`, `cmd`) or bank timers |
| 11 | Restructured the request decode | — | Address/data/DQM registers loaded every clock instead of only on a decision; refresh-due flags registered one clock early; request no longer latched (requester holds addr/we/din) |
| 12 | Recompile at 1250 ps (PLL gives **1339 ps**) | Core setup **+0.74 ns** (Fmax 122 MHz); I/O worst +0.74 ns | Testbench clock set to 112 MHz and SD_SHIFT to the achieved 1.339 ns |
| 13 | Simulation at 112 MHz, 2 passes | Data perfect, but **26 666 "tWR violated"** model errors | Found to be a testbench artefact: the simulator rounds the half period to 4.464 ns, so the clock is 8.928 ns, while the model computed tWR = 2 x 8.928571 ns. The controller's correct 2-clock spacing measured 0.001 ns "short". Model given a 10 ps tolerance on clock-based limits |
| 14 | Re-run 112 MHz, 2 passes + sweep 0, 0.5, 1, 2, 5, 6, 7 ns | PASS, 0 errors; sweep passes 0-5 ns and fails at 6 and 7 ns (window narrower than at 100 MHz, as calculated) | — |
| 15 | **Hardware, 112 MHz** | Passed (slow blink, injection detected) | — |
| 16 | Window widened to **18 bits** (256 KB); module renamed `sdram_ram` with `ADDR_BITS`; tester made generic (pattern = XOR of one data bit per address bit) | Core slack 0.74 -> 0.59 ns (one more row bit to compare); I/O unchanged | Cleaned all width-truncation warnings (sized constants) so new warnings stand out |
| 17 | Simulation, 2 passes over 256 KB (~2.1 million accesses) + TCO 1 and 5 ns | PASS, 0 errors | — |
| 18 | **Hardware, 112 MHz, 256 KB** | Passed; soak test by the user | — |

## 3.3 How the timing results moved (worst slack, ns)

| Version | out setup (slow) | out hold (fast) | in setup (slow) | in hold (fast) | core setup (slow) |
|---|---|---|---|---|---|
| 100 MHz, first compiles (wrong `-hold` multicycle) | 0.49 | 3.37 | 3.80 | "+11.5" (false) | 0.70, after IOE packing 1.21 |
| 100 MHz, SDC fixed, before recompile | 0.49 | 3.37 | 3.80 | **-0.55** | 1.21 |
| 100 MHz, after fitter fix | 0.49 | 3.37 | 0.99 | 0.59 | 1.21 |
| 100 MHz, SDRAM clock +1.5 ns | 1.87 | 2.11 | 1.46 | 1.19 | 1.09 |
| 112 MHz, 500 ps, before restructuring | 0.28 | — | 0.90 | 0.67 | **-0.04** |
| 112 MHz, 1500 ps, before restructuring | 1.40 | — | 0.52 | 1.50 | 0.10 |
| 112 MHz, 1339 ps, restructured (17-bit) | 1.18 | 1.73 | 0.74 | 1.27 | 0.74 |
| 112 MHz, 1339 ps, 18-bit (current) | 1.18 | 1.73 | 0.74 | 1.27 | 0.59 |

## 3.4 How the simulated latency moved (clocks, from req to ack)

| Version | read hit | read min / avg / max | write min / avg / max | longest refresh gap |
|---|---|---|---|---|
| 100 MHz, first | 5 | 5 / 6.49 / 20 | 1 / 3.36 / 18 | 7600 ns |
| 100 MHz, dout bypass | 4 | 4 / 5.48 / 19 | 1 / 3.36 / 18 | 7600 ns |
| 112 MHz | 4 | 4 / 5.50 / 20 | 1 / 3.34 / 18 | 7597.7 ns |
| 112 MHz, 256 KB | 4 | 4 / 5.94 / 20 | 1 / 3.34 / 18 | 7597.7 ns |
The averages depend on the test's address order (the bit-reversed phase deliberately causes row conflicts). The
per-case latencies (4 hit / 6 bank idle / 8 conflict) did not change.

## 3.5 Lessons from this history
1. **A passing simulation proved nothing until it was made able to fail.** The X-blind compare (step 3) and the
   zero-delay case would both have hidden a wrong capture edge.
2. **A "clean" timing report is only as good as the SDC.** The wrong hold multicycle (step 5) turned a real
   -0.55 ns failure into +11.5 ns.
3. **Read the warnings.** Unpacked I/O registers (step 4) gave no timing error at the time. They would have made
   the margins depend on placement.
4. **Balance, don't maximise.** The clock shift (steps 6-7) gave up slack where there was plenty and moved it to
   where there was little.
5. **Not every error is in the design.** The 26 666 model errors (step 13) were the testbench's own rounding.
   The data was correct, and checking that first avoided "fixing" correct RTL.
6. **Speed comes from structure, not tools.** 112 MHz did not close through compiler settings. It closed by
   moving logic off the path into the I/O registers (step 11) without adding latency.
