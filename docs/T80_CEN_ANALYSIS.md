# Can the T80 be slowed down / sped up with a clock enable (CEN)? — analysis

Question: run the T80 from the 112 MHz system clock, step it with a clock enable (CEN) at ~3.5 MHz normally and
~28 MHz in turbo, and stall it (withhold CEN) when the SDRAM is not ready. Does this work?

**Answer: yes.** The code shows it (section 1), and the MiSTer ZX Spectrum core already does exactly this with
the same T80, at the same 112 MHz system clock, with SDRAM and turbo loading (section 2). What has to be done
carefully is the timing constraints and the bridge (sections 3-5). Source analysed: `T80/` (commit af0e6723).

## 1. What the T80 code shows

### 1.1 Every register respects CEN
| Clocked process | File:line | Gated by |
|---|---|---|
| main register/flag/address process | T80.vhd:438 | `ClkEn` (= `CEN and not BusAck`, line 380) |
| R800 multiplier | T80.vhd:970 | `ClkEn` (unused in Z80 mode) |
| register-file address/bus | T80.vhd:1000 | `ClkEn` |
| BusB/BusA | T80.vhd:1176 | `ClkEn` |
| register file | T80_Reg.vhd:133 | `CEN` |
| MCycle/TState sequencer, interrupts, wait | T80.vhd:1294-1304 | `CEN` |
| wrappers T80se / T80pa bus signals, DI_Reg | T80se.vhd, T80pa.vhd | `CLKEN` / `CEN_p`,`CEN_n` |

Exceptions (harmless): the NMI edge detector (`NMI_s`, T80.vhd:1296) runs every clock, so NMI_n must be a clean
synchronous signal. The `DIRSet` register-load port (snapshot loading) is unused; tie it to 0.

**Consequence:** when CEN is low, the whole CPU is frozen. Holding CEN low simply stretches the current
T-state, and the CPU cannot tell. Stalling for the SDRAM by withholding CEN is therefore safe in any T-state.

### 1.2 When the CPU needs the memory data (bus timing in CEN edges)
- **Address:** updated on the CEN edge that **starts T1** (end of the previous cycle, `T_Res`, T80.vhd:553-600).
- **Opcode fetch (M1):** `IR <= DInst` on the CEN edge that **ends T2**, only if `WAIT_n = 1` (T80.vhd:510, 718).
- **Memory read:**
  - T80se latches `DI_Reg` on the same edge (end of T2).
  - T80pa latches it at `CEN_n` in the middle of T3 (+half a T-state, like a real Z80).
- **Memory write:** data on DO and WR_n are active from T2.
- **M1 T3/T4:** refresh cycle; the CPU does not need memory, so this slot is free for SDRAM refresh.
- **INT_n:** sampled on the CEN edge at the end of each instruction's last cycle.
- **WAIT_n:** sampled at the end of T2; if low, TState stays at 2 (Z80-style wait state).

So the memory system has **2 T-states from address to data** for opcode fetches, 2 (T80se) or 2.5 (T80pa) for
reads.

**Do not start the SDRAM access on RD_n/MREQ_n.** In T80se those signals are registered on the CEN edge that
ends T1, so they appear one whole T-state after the address and leave only 1 T-state. The bridge should start the
access at T1 itself, using MCycle/TState and the address.

### 1.3 Data input path
`DInst` goes only into the `IR` and `WZ` registers (T80.vhd:510/515/718). The path from the memory data into
the CPU is therefore short, and can be a normal single-clock path.

## 2. Proof from an existing design: MiSTer ZX Spectrum core (same commit)
`ZX-Spectrum.sv` and `ZX-Spectrum.sdc` at af0e6723:
- PLL: `clk_sys = 112.000 MHz` from 50 MHz (the same as ours).
- CPU: `T80pa` clocked by clk_sys with `CEN_p/CEN_n` from a counter; speeds: original (ULA-generated CEN),
  7/14/28/56 MHz.
- **Tape loading automatically switches to turbo** (`tape_active` -> fastest setting), the same idea as your tape
  simulator GPIO.
- **SDRAM stall:** `if(!turbo[4:2] & !ram_ready) cpu_en <= 0;` stops the CEN in 28/56 MHz when the SDRAM
  is not ready, which is our "stall CEN" plan.
- Video reads a block-RAM shadow (`dpram vram`) of the screen pages, written in parallel with SDRAM writes,
  which is also our plan.
- SDC: `set_multicycle_path -from {emu|cpu|*} -setup 2 / -hold 1` (and `-to`): the T80 is given 2 system
  clocks.

Differences that matter for us:
- MiSTer runs on a Cyclone V; ours is an EP4CE15 C8. **Measured** (section 6): the T80 alone reaches 63.5 MHz
  (15.75 ns) at the slow corner. So a 4-clock allowance (35.7 ns, 28 MHz turbo) has ~20 ns spare, and even the
  2-clock allowance MiSTer uses (17.9 ns, 56 MHz) would fit the CPU itself with ~2 ns to spare. (The 44 MHz seen
  in the MAX10 reference design was that whole, unconstrained clock domain, not the T80's own limit.)
- Their T80pa has half-T paths (CEN_n -> CEN_p), so a blanket multicycle of N is only safe if CEN_p and CEN_n are
  at least N clocks apart.

## 3. Recommended configuration
1. **Wrapper:** our own thin wrapper around the `T80` core, modelled on T80se (one CEN), which additionally
   exports `MC`/`TS` (the core has these outputs). Reasons:
   - with one CEN, every CPU-internal path is CEN-to-CEN, i.e. at least 4 clocks at 28 MHz. That gives a single,
     simple multicycle rule (section 4);
   - the bridge can start the SDRAM access at T1 using MC/TS (1.2);
   - exact half-T-state bus timing (T80pa) is only needed to emulate the real ULA bus, which this VGA-based design
     does not do. Contention, if wanted later, is done by gating CEN.
   T80pa stays an option, with path-specific constraints.
2. **CEN generation:** a 32-bit phase accumulator (DDS) at 112 MHz.
   - Normal: 3.5469 MHz average (31.58 clocks per T-state, either 31 or 32), or 3.5 MHz (exactly 32).
   - Turbo: **28 MHz = exactly every 4 clocks** (112/4, no jitter).
   - The speed can change on any clock (new increment); no glitches, no clock multiplexer.
3. **Stall:** CEN is suppressed while the bridge waits for the SDRAM. Only needed in turbo; in normal mode the
   SDRAM is always ready long before the CEN edge.

## 4. Timing constraints for the CPU
- CPU-internal paths (`-from cpu -to cpu`): `set_multicycle_path -setup 4` and `-hold 3`, valid because
  consecutive CENs are never closer than 4 clocks.
  **Why `-hold 3` is right here, while Part F of the tutorial warns against a hold multicycle:** here the launch
  and capture registers are in the same clock domain and both change only on CEN. The data must stay stable
  for the whole CEN period, which is exactly what setup N / hold N-1 describes. For the SDRAM read path the
  launching edge is a different clock (the SDRAM's), and moving the hold check hid a real hold requirement.
- Memory data and INT/WAIT into the CPU: normal single-clock paths (short: into IR/WZ/DI_Reg), or registered
  in the bridge.
- CPU outputs used by the bridge (address, MC/TS, Write/NoRead/IORQ decode): the decode is deep combinational
  logic from IR. The bridge samples it one or two clocks after the CEN edge, with a matching 2-clock multicycle
  for those specific paths.
- If a faster turbo is ever wanted (every 3 clocks = 37.3 MHz), the multicycle becomes 3 and the T80 must meet
  26.8 ns. That needs a measurement on this FPGA.

## 5. Memory timing budget with this scheme (112 MHz system clock)
| Mode | Clocks per T | Address -> opcode needed | SDRAM read (incl. 1 bridge clock) | Result |
|---|---|---|---|---|
| Normal 3.5469 MHz | 31-32 | ~63 clocks | 5 / 7 / 9 (hit / idle bank / conflict), worst ~21 with refresh | never stalls: exact Spectrum T-state timing |
| Turbo 28 MHz | 4 | 8 clocks | 5 / 7 / 9 | hit and idle bank fit; conflict stalls 1 clock; refresh collision (rare) more |
| 56 MHz (possible later) | 2 | 4 clocks | 5 / 7 / 9 | every read stalls 1+ clocks (effective speed well below 56); CPU logic fits (15.75 ns needed, 17.9 available) |
Writes are posted (1 clock) and never stall.

The SDRAM refresh can be steered into M1 T3/T4 (8 clocks free per instruction in turbo), which makes refresh
collisions rarer.

## 6. Open points
- **T80 speed on the EP4CE15 C8: measured 2026-10-05** with `tests/t80_fmax/` (T80se + all I/O registered,
  Quartus 25.1, targets 62.5 and 80 MHz): **Fmax 63.5 MHz slow 85 °C, 67.4 MHz slow 0 °C** (15.75 ns),
  2 588 LEs. Critical path IR -> decode -> ALU -> F (flags). Requirement for 28 MHz turbo: 35.7 ns (multicycle 4)
  -> large margin. In the full design routing will cost some of it; still far inside.
- Bridge details (when to sample MC/TS/Write, posting writes, ROM write protection, page mapping, video shadow
  writes) belong to the bridge design, step 4 in PLAN.md.
