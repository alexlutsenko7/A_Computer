# LTari design notes (clean-room)

Facts collected from the **Altirra Hardware Reference Manual, 2026-01-02 edition** (Avery Lee; `ref/altirra_hw_ref.pdf`,
text in `ref/altirra_hw_ref.txt`), in our own words, with the manual's section numbers. No other Atari FPGA core's HDL
is read (docs/PLAN.md, "LTari"). Our HDL is written from these notes and the manual.

## System (ch. 2)
- Chips: 6502C (with HALT), ANTIC (DMA, refresh, display timing, playfield), GTIA (colour generation, P/M,
  triggers, console keys, speaker), POKEY (sound, serial I/O, keyboard, paddles), PIA 6520 (joystick directions,
  SIO control lines, XL/XE memory control), MMU (address decode / banking).
- Only the CPU writes; ANTIC reads (DMA) or does refresh cycles. ANTIC halts the CPU for its cycles.
- Clocks (PAL): master 14.18757 MHz, machine (CPU) clock = master / 8 = 1.773447 MHz; colour clock = 2 x machine
  clock (3.547 MHz); hi-res dot = 2 x colour clock (7.094 MHz). 114 machine cycles per line, 312 lines
  (non-interlaced, 15.557 kHz, 49.86 Hz).
- Floating bus: XL/XE with pull-ups read $FF on unmapped addresses (130XE: some XE lack pull-ups and float; we
  return $FF). Unmapped: $D100-D1FF, $D500-D5FF without cartridge, $D600-D7FF. ANTIC's unused registers read $FF.
- Power-up RAM: undefined (alternating $00/$FF blocks after a long power-off). We clear RAM at start (L64 lesson).

### PIA (2.5), $D300-D3FF, 4 registers mirrored (A1:A0)
- $D300 PORTA / DDRA, $D301 PORTB / DDRB, $D302 PACTL, $D303 PBCTL. Control bit 2 = 1: data register, 0: DDR.
- DDR bit 1 = output. Port A output bits read back as (output AND external); port B output bits read the output.
- Port A = joystick 1/2 directions (bits 0-3 stick 1: up, down, left, right, active low; bits 4-7 stick 2).
- CA2 = SIO motor, CB2 = SIO command (control bits 5:3 = 110 low, 111 high). CA1 = SIO proceed, CB1 = SIO interrupt.
- Control bits 7 / 6 = IRQ status of C1 / C2 (read only); reading the data register clears them. Bit 0 / 3 enable.
- Reset: all registers 0 (inputs, DDR selected). XL/XE: the Reset button resets the PIA too.
- 130XE: port B bit 6 floats (reads 1 then decays to 0 when switched to input; we can return 1).

### MMU / bank switching (2.6, 2.7), XL/XE, from PORTB outputs (inputs read as 1 through pull-ups)
- bit 0 = 1: OS ROM at $C000-CFFF and $D800-FFFF (16 KB ROM, its $D000-D7FF part = self-test window).
- bit 1 = 0: BASIC ROM at $A000-BFFF. Priority there: cartridge > BASIC > RAM.
- bit 7 = 0 (and OS on): self-test ROM at $5000-57FF (= ROM $D000-D7FF); it wins over the 130XE window there.
- 130XE (64 KB extra): bits 3:2 = bank (16 KB) for the window $4000-7FFF; bit 4 = 0: CPU uses the window;
  bit 5 = 0: ANTIC uses the window (same bank). 800XL mode: bits 2-5 have no memory function.
- Writes to addresses mapped to ROM / cartridge are ignored (no write-through to RAM).
- $D000-D7FF hardware always visible: $D000 GTIA, $D200 POKEY, $D300 PIA, $D400 ANTIC, $D500 cartridge control.
- Cartridge sense: RD5 (cartridge at $A000-BFFF) -> GTIA TRIG3 = 1 when present (XL/XE OS uses it).
- Reset button (XL/XE): resets CPU, ANTIC, MMU and PIA (no RNMI).

## ANTIC (ch. 4), $D400-D4FF, low 4 address bits decoded
- Reset clears NMIEN, DMACTL, the playfield DMA clock; other registers keep values (NMIST power-up $7F typical).
- Playfield widths (DMACTL 1:0): 00 off, 01 narrow 128 colour clocks (64 cycles), 10 normal 160 (80 cycles),
  11 wide 192 (96 cycles; 178 visible). Same centre.
- Modes (IR low nibble): char 2 (8 lines, hi-res, 40 B), 3 (10 lines, descenders for $60-7F), 4 (8, multicolour 4x8,
  bit 7 -> PF3 for 11), 5 (16), 6 (8 lines, 20 B, 64 chars, top 2 bits = colour PF0-3), 7 (16); map 8 (8 lines,
  10 B, 4 col), 9 (4, 10 B, 2 col), A (4, 20 B, 4 col), B (2, 20 B, 2 col), C (1, 20 B, 2 col), D (2, 40 B, 4 col),
  E (1, 40 B, 4 col), F (1, 40 B, hi-res). Bit 7 of a byte = leftmost pixel. Multicolour pairs: 00 BAK, 01 PF0,
  10 PF1, 11 PF2. Hi-res modes (2, 3, F): hue = PF2, a 1 bit takes PF1's luminance.
- Char set: CHBASE top 6 (1 KB sets, modes 2-5) or 7 bits (512 B, modes 6-7); 8 bytes per char, row = low 3 bits.
  CHACTL: bit 0 blank chars with bit 7, bit 1 invert chars with bit 7 (modes 2/3 only), bit 2 vertical flip.
  CHBASE change takes effect 2 cycles later.
- Display list instruction: bit 7 DLI, 6 LMS (2 address bytes follow, LSB first), 5 VSCROL, 4 HSCROL, 3:0 mode.
  Mode 0 = blank, bits 6:4 = 1-8 lines. Mode 1 = jump (2 address bytes); $41 = jump and wait for VBL (JVB).
  The DL pointer's low 10 bits count, upper 6 do not (wraps inside 1 KB; jumps go anywhere).
- Display list active scan lines 8-247 (240 max, PAL too); VBL from line 248; the DL resumes at line 8.
- DMACTL bit 5 = DL DMA (off: the last instruction byte repeats, no address fetches), bit 2 missiles, bit 3 players
  (forces missiles), bit 4 one-line P/M resolution.
- NMIs: NMIEN bit 7 DLI, bit 6 VBI. NMI pulled at cycle 8 of scan line 248 (VBI) or of the last scan line of a DLI mode
  line. NMIST bit 7 DLI, 6 VBI, 5 reset; set from cycle 7; DLI bit cleared at line 248, VBI bit cleared at a DLI;
  NMIRES ($D40F write) clears. Status is set even when the interrupt is disabled.
- WSYNC ($D40A write): RDY low from the cycle after the write until cycle 105 (writes up to cycle 103 wait for this
  line, from 104 the next line). Only read cycles stall (6502 ignores RDY on writes).
- VCOUNT ($D40B) = line / 2; PAL counts to $9B ($9C for one cycle at the end); increments at cycle 111.
- Playfield DMA: fetch every 8 cycles (modes 8, 9), every 4 (6, 7, A-C), every 2 (2-5, D-F). Char modes fetch the
  name on the first line (into the 48-byte line buffer) and the char data on every line, 3 cycles after the name
  slot. Map modes fetch only on the first line (line buffer replays). Map DMA starts at cycle 28 / 20 / 12
  (narrow / normal / wide); char name fetches start at 26 / 18 / 10. No DMA at or after cycle 106 (the address still
  counts). HSCROL: the window starts 1 cycle later per 2 colour clocks of scroll; with HSCROL, narrow uses the normal
  window and normal the wide window.
- Memory scan counter: 4 KB wrap (upper 4 bits fixed during a line).
- Per-line fixed slots: cycle 0 missile DMA, 1 display list byte, 2-5 players, 6-7 LMS / jump address. Refresh:
  9 cycles from cycle 25, every 4; a refresh blocked by playfield DMA moves to the next free cycle (only one pending,
  others dropped).
- P/M DMA: lines 8-247; PMBASE bits 7:2 (two-line, 1 KB aligned) or 7:3 (one-line, 2 KB). Sections: missiles at
  +$180 / +$300, players 0-3 from +$200 / +$400; offset = VCOUNT line bits 7:1 (two-line) or 7:0.
- Event deadlines (fig. 6): DL DMA enable by cycle 113 of the line before; NMIEN by cycle 7; PF start deadlines
  24 / 16 / 8 (narrow / normal / wide), stop 88 / 96 / 104.

## GTIA (ch. 6), $D000-D0FF, low 5 bits decoded ($D000-D01F)
- Writes: $D000-03 HPOSP0-3, $D004-07 HPOSM0-3, $D008-0B SIZEP0-3, $D00C SIZEM, $D00D-10 GRAFP0-3, $D011 GRAFM,
  $D012-15 COLPM0-3, $D016-19 COLPF0-3, $D01A COLBK, $D01B PRIOR, $D01C VDELAY, $D01D GRACTL, $D01E HITCLR,
  $D01F CONSOL (bits 0-3 out: speaker bit 3).
- Reads: $D000-03 M0PF-M3PF, $D004-07 P0PF-P3PF, $D008-0B M0PL-M3PL, $D00C-0F P0PL-P3PL (collisions), $D010-13
  TRIG0-3 (1 = not pressed; TRIG3 = cartridge present on XL/XE), $D014 PAL (PAL GTIA reads $01, NTSC $0F),
  $D01F CONSOL (bits 0-2 = START, SELECT, OPTION, 0 = pressed). GTIA drives all data bits in its range.
- Not reset: registers must be cleared by software; power-on reads in table 13 (collisions 0, TRIG 1).
- Horizontal: 228 colour clocks per line, visible $22-DD (188). Playfield: narrow $40-BF, normal $30-CF, wide $20-DF
  clipped to $2C-DD. Vertical: lines 8-247 (240). VSYNC: PAL lines 275-277 (NTSC 251-253).
- ANx bus (ANTIC -> GTIA, 3 bits per colour clock): 000 background, 001 vsync, 010 hblank + next line lo-res,
  011 hblank + next line hi-res, 100-111 lo-res PF0-PF3 / hi-res pixel pair 00-11. Hi-res pair: 1 = PF1 luminance.
- Position relation (from 6.10 / 4.14 examples): a write at machine cycle 65 changes a colour register from colour
  clock $81 (1 clock later), so cycle c covers colour clocks 2c-2 / 2c-1; a byte fetched at cycle c is shown from
  colour clock 2(c+4) (normal mode E: fetch at 20 -> $30, at 66 -> $8C).
- Colour registers: bits 7:4 hue (0 = grey), 3:1 luminance, bit 0 ignored (only GTIA mode 9 gives 16 lums).
- PAL hues (table 14, ideal UV angles): 1 135.0, 2 112.5, 3 90.0, 4 67.5, 5 45.0, 6 22.5, 7 337.5, 8 315.0, 9 292.5,
  10 270.0, 11 225.0, 12 202.5, 13 180.0, 14 157.5, 15 135.0 degrees; the RGB palette is computed by us from these.
- Mid-line write delays (table 18): colour 1 cclk, PRIOR 3:0 / 5: 2, PRIOR 7:6: 3-5, GRAFx 3, HPOS/SIZE 5.

## POKEY (ch. 5), $D200-D2FF, low 4 bits decoded; unassigned reads $FF
- Writes: $D200/2/4/6 AUDF1-4, $D201/3/5/7 AUDC1-4, $D208 AUDCTL, $D209 STIMER, $D20A SKRES, $D20B POTGO,
  $D20D SEROUT, $D20E IRQEN, $D20F SKCTL. Reads: $D200-07 POT0-7, $D208 ALLPOT, $D209 KBCODE, $D20A RANDOM,
  $D20D SERIN, $D20E IRQST, $D20F SKSTAT.
- No reset pin. SKCTL bits 1:0 = 00: init mode (15 kHz / 64 kHz clocks, polynomials, serial, keyboard held; RANDOM
  stuck at $FF). 15 kHz clock: 7-bit poly, 64 kHz: 5-bit poly (exact reset phases in 5.2).
- IRQEN bit = 1 enables; IRQST bit reads 0 when that IRQ is pending, 1 otherwise (disabled ones locked at 1;
  appendix IRQST [D20E, R]: bits 7 BRK, 6 KBD, 5 SIN, 4 SOT, 3 STR, 2 T4, 1 T2, 0 T1),
  except bit 3 (serial output complete: live, not latched). IRQ line = any pending. Shared with the PIA IRQs.
  IRQ reaches the CPU 2-3 unhalted cycles after IRQST changes.
- Keyboard: KBCODE bits 5:0 scan code, bit 6 Shift, bit 7 Control (latched with the key); keyboard IRQ = bit 6;
  SKSTAT bit 2 = 0 while a key is down, bit 3 = 0 while Shift is down. Same key again: KBCODE unchanged, IRQ again.
  Scan codes: table 11 (e.g. A $3F, Return $0C, Space $21, Esc $1C). START / SELECT / OPTION are GTIA CONSOL,
  Break is IRQ bit 7, Reset (XL/XE) is the system reset.

## GTIA players / missiles, priority, collisions (6.5-6.9)
- Object shift register loaded (ORed) with its graphics register when the colour clock equals HPOS; shifts out
  from the top when the size state machine (state' = (state + 1) AND size; reset to 0 at a load) reaches 0:
  1 / 2 / 4 colour clocks per bit (size 00 or 10 / 01 / 11). Runs through blanking. HPOS uses the same colour
  clock numbers as the playfield (normal playfield $30-$CF).
- VDELAY bit (missiles 0-3, players 4-7): DMA data loaded only on odd lines. GRACTL bit 2 latches triggers.
- Priority = the manual's equations of PRI0-3 (PRIOR 3:0), MULTI (bit 5) and the object / playfield signals;
  selected colours are ORed. Fifth player (bit 4): missiles take PF3's colour and layer (PF3 beats PF0-2).
  Without it the missiles count with their players.
- Hi-res lines: the priority logic sees PF2; a 1 pixel takes PF1's luminance on top of everything; collisions
  see PF2 when either pixel of the pair is 1.
- Collisions only in colour clocks $22-$DD of lines 8-247; P/M vs playfield before priority; a player never
  collides with itself; no missile-missile; HITCLR clears; colours do not matter.
- GTIA modes (PRIOR 7:6): 4-bit pixels from two colour clocks' AN1:0 (AN2 ignored, so the border is 0000).
  9: COLBK hue, luminance ORed in (16 shades). 11: hue ORed with COLBK's, COLBK's luminance (0000: luminance 0).
  10: 0-3 = P0-P3 colours (act as that player for priority, no collision), x100-x111 PF0-3, 10xx COLBK; shown one
  colour clock later than the other modes. Playfield in 9 / 11 counts as background: no PF collisions.

## SIO bus and disk drives (9.1, 10.2)
- Bytes: 1 start, 8 data LSB first, 1 stop, 19,200 baud nominal (POKEY divisor $28: ~18,900).
- Command frame: the computer pulls the command line (PIA CB2) low, sends device, command, AUX1, AUX2,
  checksum (8-bit sum with carry added back), then raises the line. The device answers only after the line is
  high: ACK $41 / NAK $4E within 16 ms (else the OS retries; up to 28 sends); for a write the computer then sends
  its data frame + checksum, the device ACKs it (850 us-16 ms later); then, at least 250 us after the ACK's end,
  Complete $43 / Error $45, and for a read the data frame + checksum (may follow at once).
- Disk D1: = $31. Status $53 -> 4 bytes: drive status (bit 7 enhanced density, 5 double density, 3 write
  protected failure), inverted FDC status ($FF = fine), format timeout (keep $E0 or more), 0. Read $52 / put
  $50 / write $57: AUX = sector number (1-based); sectors 1-3 are 128 bytes even on double density. Format $21
  returns a sector-sized list of bad sectors ending in $FFFF. Invalid sector: NAK.

## Our implementation plan (skeleton, step 2)
- Clocks: atari_pll from 50 MHz, M=143 N=7 (VCO 1021.43 MHz): clk = /36 = 28.37302 MHz (2 x master: 16 clk per
  machine cycle, 8 per colour clock, 4 per hi-res pixel), clk_sd = /12 = 85.119 MHz (3 x clk, edges aligned), clk_sdo = clk_sd delayed (SDRAM clock).
  -75 ppm vs PAL (49.856 Hz). Video: a second PLL (VCO 756.25 MHz, as LSpectrum), 25.208 MHz 640x480@60 and 27.009 MHz
  720x576@50 (576p).
- Machine cycle = 16 clk ticks (as L64's 16 ticks per phi half): ANTIC decides per cycle whether it takes the
  bus (DMA / refresh) or the CPU runs; T65 enable once per cycle; WSYNC holds the CPU only on read cycles.
- Memory in SDRAM (byte addresses): 0x00000-0x0FFFF main RAM, 0x10000-0x1FFFF 130XE extra banks 0-3,
  0x20000 ROM image (header page 0x20000, OS 16 KB at 0x21000, BASIC 8 KB at 0x25000), 0x28000+ cartridge image,
  frame buffers 0x40000-0x9FFFF (3 x 128 KB).
  RAM cleared at every start.
- Frame buffer: GTIA output per hi-res pixel (8 bits: hue + luminance), visible $22-DD x lines 8-247 =
  376 x 240; shown at 2 x 2: 640 x 480 shows the middle 320 x 240 (the normal playfield's width, all lines),
  720 x 576 the middle 360 x 240 (48 black lines above and below).
- First simulation target: AltirraOS cold start -> Altirra BASIC "READY" on the GR.0 screen (needs ANTIC mode 2,
  display list, NMI VBI, WSYNC, VCOUNT; GTIA colours + CONSOL + TRIG3 + PAL; PIA + PORTB; POKEY IRQs, timers,
  RANDOM, SKCTL; SIO with no device answering, so the OS's disk boot attempt times out).

## Still to read
- 4.7 scrolling (VSCROL / HSCROL detail), 4.12 abnormal DMA (later), 6 GTIA (display generation, horizontal positions,
  P/M, collisions, priorities, PAL colours), 5 POKEY, 9-10 SIO and disk protocol (for the ESP32 drive).
- GTIA reads of the unused addresses $D015-$D01E return $0F (manual, Table 13 "GTIA Register Map", read column);
  software depends on it: the Delirium Tremens depacker does LSR $D017 and branches on the result (with $00 its
  stage 2 took another path and the demo crashed; found by an RTL-vs-6502-reference trace comparison, 2026-10-31).
