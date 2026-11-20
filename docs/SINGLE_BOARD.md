# Single board — evaluation (2026-11-20)

Evaluation only: nothing is designed. The board is made only if the design gets enough interest. Until a single board has
passed its tests, the product stays the QMTECH 10CL025 core board + I/O board revision 2.

## Decisions (user)

| Point | Decision |
|---|---|
| Core part | QMTECH's 10CL025 schematic (`docs/vendor/QMTECH_10CL025_V1_schematic.pdf`) **exactly as it is, no change** |
| I/O part | I/O board revision 2 (`Extra_PCB_CycloneIV_R2/`) unchanged, except the joystick sockets (below) |
| PCB | one board, **6 layers** |
| U7, U8 | both 2x32 headers stay, QMTECH's exact pinout, for future expansion; the I/O circuit connects to U8's nets by tracks |
| JP1 (5 V power header) | footprint kept, **not mounted** |
| Joystick sockets | the two existing DB9 sockets, **wired for Sega Mega Drive 6-button pads**; no extra sockets |
| Pads and the ESP32 | pads connect to the **FPGA only**; the ESP32 sees them as keys through the existing link registers |

## Parts

- **FPGA**: 10CL025YU256I7G costs 208 USD at JLCPCB (not acceptable). **10CL025YU256A7G** (automotive grade, same die, package and
  speed grade; JLCPCB pre-order section) is the candidate:
  - it is in Quartus 25.1std Lite's device list;
  - the menu and all seven machines build for it without errors and timing-clean, with no change to sources, constraints or
    settings (scratch builds in `<Machine>/a7g_scratch`, 2026-11-20; Quartus analyses it at -40 and 125 C):

    | Design | LEs | Worst setup slack, A7G / I7G | Worst hold slack, A7G / I7G |
    |---|---|---|---|
    | AMenu | 13,246 | +2.97 / +3.78 ns | +0.13 / +0.13 ns |
    | LSpectrum | 7,771 | +1.00 / +1.11 ns | +0.13 / +0.13 ns |
    | L64 | 15,294 | +1.56 / +1.50 ns | +0.13 / +0.10 ns |
    | LTari 130 | 6,967 | +2.42 / +2.59 ns | +0.13 / +0.14 ns |
    | LTari 800 | 6,999 | +2.42 / +2.63 ns | +0.13 / +0.13 ns |
    | LNES | 6,874 | +2.34 / +2.58 ns | +0.11 / +0.13 ns |
    | LMega | 17,587 | +1.36 / +1.12 ns | +0.09 / +0.13 ns |
    | LNext | 18,401 | +0.98 / +0.53 ns | +0.11 / +0.08 ns |

  - the existing I7G bitstreams should load unchanged: Altera's knowledge base says programming files do not depend on the speed or
    temperature grade; the programmer names both devices "10CL025Y"; an I7G and an A7G `.sof` have the same size and format.
    Not run on an A7G chip.
- **SDRAM**: W9825G6KH-6 (the plain -6, as on both QMTECH boards; the -6I has slower tRCD / tRP and would need a check).
- **Sourcing at JLCPCB**: pre-order = JLCPCB buys the part into the private parts library (lead time shown at the order, about
  2 to 4 weeks; no cancelling after the quotation). Consigned parts = bought elsewhere and delivered to JLCPCB (Zhuhai from inside
  mainland China, Hong Kong from outside); AliExpress parts carry the risk of pulled / remarked FPGAs, and JLCPCB does not test them.
- QMTECH publishes no layout (their repository holds the schematic PDF and the manuals only): the layout is ours.

## The core circuit (from the schematic, about 75 parts)

FPGA with its decoupling (1.2 V: 5 x 100 nF + 4 x 22 uF; 3.3 V: 10 x 100 nF; 2.5 V: 3 x 100 nF), three TPS563201 buck converters
from 5 V (3.3 V, 2.5 V, 1.2 V; 4.7 uH each), SDRAM with five 100 nF and 4.7k pull-ups on its five control lines, 50 MHz oscillator
(Epson SG-8002JC; an equivalent 50 MHz 3.3 V oscillator if it is not in stock), W25Q64JVSSIQ, 2x5 JTAG header, KEY0, the nCONFIG
button, two LEDs, the configuration pull-ups and mode pins. The PLL supplies connect straight to 1.2 V / 2.5 V (no filters), as on
QMTECH's board.

## What the single board means

- **Every signal keeps the FPGA ball it has today**, so the existing bitstreams work for everything except the pads.
- **Two 3.3 V rails stay separate**: QMTECH's buck for the FPGA side, the LDL1117 for the ESP32 / I/O side (J1 never joined them).
- **Power** comes in through USB-C onto the 5 V net that feeds the three buck converters; JP1's pads are an alternative 5 V input
  (no protection against feeding both).
- **KEY1** is U7 pin 7 (ball G1, pull-up) as today; a button on the board on the same net.
- **SDRAM**: placed close to the FPGA as on QMTECH's board; the 1339 ps clock shift was tuned on their trace lengths, the margin is at
  least 1.1 ns; DDR_TEST on the first board confirms it (a new shift would mean new bitstreams).
- **6 layers**: the 256-ball BGA has 0.8 mm pitch and about 95 signal balls in use; solid ground planes and a power layer split for
  the four rails.
- **Each board** needs one JTAG pass for `L.jic`, as today.

## Joystick sockets for Mega Drive pads

| DB9 pin | Revision 2 | Single board |
|---|---|---|
| 1-4 | Up, Down, Left, Right | same |
| 5 | not connected | 5 V for the pad |
| 6 | Fire | same (B / A) |
| 7 | not connected | select, FPGA output |
| 8 | Ground | same |
| 9 | not connected | input (C / Start) |

- Four more FPGA pins (select and pin 9 per socket); the ten existing joystick signals keep their balls.
- The pad runs on 5 V: a 5 V-tolerant buffer or series resistors on the six inputs per socket; a fuse or resistor on pin 5 and a
  series resistor on select.
- Atari / Commodore joysticks keep working in the same sockets (pins 1-4, 6, 8); a Sega Master System pad gains its second button.
- How the 12 buttons are read: select high = Up, Down, Left, Right, B, C; select low = Up, Down, (Left and Right both low), A,
  Start; a 6-button pad counts the select pulses: on the third low all four direction lines are low, on the fourth high they carry
  Z, Y, X, Mode; the counter resets after about 1.5 ms without pulses.
- **FPGA only**: each machine gets a pad reader and merges the pad into the registers the ESP32 already reads (`KEYS`, `KEYRAW`),
  so a pad button is a key for the ESP32 (directions = cursor keys; buttons for Enter, F12, Esc: to be chosen). The firmware should
  not need a change (not checked menu by menu; typing a file name still needs a keyboard). The pad also drives the machine itself.
  While the game list is open the pad steers the list, not the game, as the keyboard does.
- Without a keyboard the consoles (LNES, LMega) can be used completely; the computers only as far as the mapped keys go.

## Capacitors under the FPGA

- The about 18 decoupling capacitors of 100 nF would sit on the bottom side under the BGA, each between a power via and a ground via
  (an 0402 fits between two neighbouring vias at 0.8 mm pitch); everything else stays on the top.
- JLCPCB: on boards of 6 layers and more the vias are filled and capped at no charge (a capacitor pad may sit on a via); every
  assembly order with a BGA is X-rayed (report with the order). Assembly on both sides is an option of their standard assembly
  service (from the order form as remembered, not checked 2026-11-20; the extra cost is not known): confirm both at the quote.
- Issues, all minor: the cost of the second side; about 0.5 mm of height under the board (the through-hole pins stick out further);
  a capacitor there can be replaced by hand.
- Not essential at 112 MHz with close power / ground planes: capacitors tightly around the BGA on the top side would also work.
- Plan: copy QMTECH's choice (turn their board over: capacitors under the FPGA or not); if their underside is empty, still put them
  underneath unless the quote makes the second side expensive.

## Open points

- Decoupling capacitors under the BGA (assembly on two sides) or on the top side only: see above, look at QMTECH's board first.
- Board outline (about 84 x 125 mm expected: above JLCPCB's 100 x 100 mm price step) and a new case.
- Which FPGA pins for the four new pad signals; the level protection part.
- Which pad button is which key.
- Stock of the core parts at JLCPCB; a quote for the 6-layer board with BGA assembly (X-ray).
