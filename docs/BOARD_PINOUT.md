# QMTECH Cyclone IV EP4CE15F23 core board — header pinout

Source: `docs/vendor/QMTECH_EP4CE15F23_V2_schematic.pdf` (QMTECH, rev 2, 2021-08-28), read from the schematic
image. **Verify against your board revision / silkscreen before wiring.** The SDRAM pins in this schematic match
the vendor demo project, which works on the user's board.

All user I/O banks are VCCIO = 3.3 V (LVTTL/LVCMOS). Cyclone IV I/O is **not 5 V tolerant**.

## On-board
| Function | FPGA pin | Notes |
|---|---|---|
| 50 MHz oscillator | T2 | |
| KEY0 (SW1) | W13 | active low, 4.7k pull-up (used as RESET_N in DDR_TEST) — the button farther from the long edge |
| KEY1 (SW2) | Y13 | active low, 4.7k pull-up (used as KEY in DDR_TEST) — the button closest to the long edge |
| LED0 (D5) | E4 | active low (anode to 3V3 via 1k) |
| Config flash W25Q64 | DCLK K2, DATA0 K1, ASDO D1, nCSO E2 | dedicated AS pins; reachable from user logic via `cycloneive_asmiblock` |
| SDRAM W9825G6KH | see DDR_TEST.qsf | |

## Header U8 (HDR 32x2) — "right" header
| Pin | Signal | Pin | Signal |
|---|---|---|---|
| 1 | GND | 2 | GND |
| 3 | 3V3 | 4 | 3V3 |
| 5 | AA11 (CLK15, clock input) | 6 | AB11 (CLK14, clock input) |
| 7 | AA13 | 8 | AB13 |
| 9 | AA14 | 10 | AB14 |
| 11 | AA15 | 12 | AB15 |
| 13 | AA16 | 14 | AB16 |
| 15 | AA17 | 16 | AB17 |
| 17 | AA18 | 18 | AB18 |
| 19 | AA19 | 20 | AB19 |
| 21 | AA20 | 22 | AB20 |
| 23 | Y22 | 24 | Y21 |
| 25 | W22 | 26 | W21 |
| 27 | V22 | 28 | V21 |
| 29 | U22 | 30 | U21 |
| 31 | R22 | 32 | R21 |
| 33 | P22 | 34 | P21 |
| 35 | N22 | 36 | N21 |
| 37 | M22 | 38 | M21 |
| 39 | L22 | 40 | L21 |
| 41 | K22 | 42 | K21 |
| 43 | J22 | 44 | J21 |
| 45 | H22 | 46 | H21 |
| 47 | F22 | 48 | F21 |
| 49 | E22 | 50 | E21 |
| 51 | D22 | 52 | D21 |
| 53 | C22 | 54 | C21 |
| 55 | B22 | 56 | B21 |
| 57 | N20 | 58 | N19 |
| 59 | M20 | 60 | M19 |
| 61 | GND | 62 | GND |
| 63 | VIN (5 V) | 64 | VIN (5 V) |

## Header U7 (HDR 32x2) — "left" header
| Pin | Signal | Pin | Signal |
|---|---|---|---|
| 1 | GND | 2 | GND |
| 3 | 3V3 | 4 | 3V3 |
| 5 | n.c. | 6 | n.c. |
| 7 | R1 | 8 | R2 |
| 9 | P1 | 10 | P2 |
| 11 | N1 | 12 | N2 |
| 13 | M1 | 14 | M2 |
| 15 | J1 | 16 | J2 |
| 17 | H1 | 18 | H2 |
| 19 | F1 | 20 | F2 |
| 21 | E1 | 22 | D2 |
| 23 | C1 | 24 | C2 |
| 25 | B1 | 26 | B2 |
| 27 | B3 | 28 | A3 |
| 29 | B4 | 30 | A4 |
| 31 | C4 | 32 | C3 |
| 33 | B5 | 34 | A5 |
| 35 | B6 | 36 | A6 |
| 37 | B7 | 38 | A7 |
| 39 | B8 | 40 | A8 |
| 41 | B9 | 42 | A9 |
| 43 | B10 | 44 | A10 |
| 45 | B13 | 46 | A13 |
| 47 | B14 | 48 | A14 |
| 49 | B15 | 50 | A15 |
| 51 | B16 | 52 | A16 |
| 53 | B17 | 54 | A17 |
| 55 | B18 | 56 | A18 |
| 57 | B19 | 58 | A19 |
| 59 | B20 | 60 | A20 |
| 61 | GND | 62 | GND |
| 63 | VIN (5 V) | 64 | VIN (5 V) |

Pin numbers 1/2, 61/62 GND and 63/64 VIN are as drawn; the exact pin-5/6 and power-row assignment should be
checked with a meter before connecting a board.

## ZX Spectrum I/O — Extra_PCB_CycloneIV I/O board

The I/O board (`../Extra_PCB_CycloneIV/`) sits beside the core board; its 2x32 J1 holes are wired to **U8** with
**each pin pair swapped**: I/O board J1 pin 2k-1 -> U8 pin 2k, J1 pin 2k -> U8 pin 2k-1. The power pairs carry the
same net on both pins (1/2 GND, 3/4 3V3, 61/62 GND, 63/64 VIN), so they stay correct; every signal lands on the
partner pin of the one in the I/O board's J1 table, always in the same I/O bank. U7 is not used.

| J1 (I/O board) | U8 | FPGA | Bank | Signal | Dir | Notes |
|---|---|---|---|---|---|---|
| 1, 2 | 2, 1 | — | | GND | | |
| 3, 4 | 4, 3 | — | | (3V3, not connected on the I/O board) | | |
| 5, 6 | 6, 5 | AB11, AA11 | | (not connected) | | clock inputs only |
| 7 | 8 | AB13 | 4 | ESP_SCK | in | link clock from the ESP32 (D14), 8 MHz, weak pull-up |
| 8 | 7 | AA13 | 4 | ESP_MOSI | in | link data from the ESP32 (D13), weak pull-up |
| 9 | 10 | AB14 | 4 | ESP_CS_N | in | link select (D33), weak pull-up |
| 10 | 9 | AA14 | 4 | ESP_MISO | out | link data to the ESP32 (D35) |
| 11 | 12 | AB15 | 4 | ESP_IRQ | out | link interrupt to the ESP32 (D34), active high |
| 12 | 11 | AA15 | 4 | BT_BCLK | in | I2S bit clock from the ESP32 (D26), weak pull-up |
| 13 | 14 | AB16 | 4 | BT_LRCK | in | I2S word select from the ESP32 (D25), weak pull-up |
| 14 | 13 | AA16 | 4 | BT_DATA | out | I2S data (machine sound) to the ESP32 (D22) |
| 15 | 16 | AB17 | 4 | BT_TX | out | UART 115200 to the ESP32 (RX2, GPIO16): F3 menu |
| 16 | 15 | AA17 | 4 | BT_RX | in | UART from the ESP32 (TX2, GPIO17), weak pull-up |
| 17 | 18 | AB18 | 4 | KB_IN | in | keyboard module J5.3, weak pull-up |
| 18 | 17 | AA18 | 4 | AUDIO_AY | out | AY sigma-delta -> RC filter -> jack J3 |
| 19 | 20 | AB19 | 4 | KB_OUT | in | keyboard module J5.2, weak pull-up |
| 20 | 19 | AA19 | 4 | AUDIO_BEEP | out | beeper (port FE bit 4) -> jack J3 |
| 21 | 22 | AB20 | 4 | JOY1_UP_N | in | DB9 J4 pin 1; 3k3 pull-up on the board |
| 22 | 21 | AA20 | 4 | JOY1_DOWN_N | in | J4 pin 2 |
| 23 | 24 | Y21 | 5 | JOY1_LEFT_N | in | J4 pin 3 |
| 24 | 23 | Y22 | 5 | JOY1_RIGHT_N | in | J4 pin 4 |
| 25 | 26 | W21 | 5 | JOY1_FIRE_N | in | J4 pin 6 |
| 26 | 25 | W22 | 5 | JOY2_UP_N | in | DB9 J6 pin 1 |
| 27 | 28 | V21 | 5 | JOY2_DOWN_N | in | J6 pin 2 |
| 28 | 27 | V22 | 5 | JOY2_LEFT_N | in | J6 pin 3 |
| 29 | 30 | U21 | 5 | JOY2_RIGHT_N | in | J6 pin 4 |
| 30 | 29 | U22 | 5 | JOY2_FIRE_N | in | J6 pin 6 |
| 45 | 46 | H21 | 6 | VGA_VS | out | 22 Ohm + 6p8 on the board |
| 47 | 48 | F21 | 6 | VGA_HS | out | 22 Ohm + 6p8 on the board |
| 49 | 50 | E21 | 6 | VGA_R[3] | out | 523 Ohm (MSB) |
| 50 | 49 | E22 | 6 | VGA_R[1] | out | 2.1k |
| 51 | 52 | D21 | 6 | VGA_R[2] | out | 1.05k |
| 52 | 51 | D22 | 6 | VGA_R[0] | out | 4.22k (LSB) |
| 53 | 54 | C21 | 6 | VGA_G[3] | out |  |
| 54 | 53 | C22 | 6 | VGA_G[1] | out |  |
| 55 | 56 | B21 | 6 | VGA_G[2] | out |  |
| 56 | 55 | B22 | 6 | VGA_G[0] | out |  |
| 57 | 58 | N19 | 5 | VGA_B[3] | out |  |
| 58 | 57 | N20 | 5 | VGA_B[1] | out |  |
| 59 | 60 | M19 | 5 | VGA_B[2] | out |  |
| 60 | 59 | M20 | 5 | VGA_B[0] | out |  |
| 31-44, 46, 48 | 32-43, 45, 47 | | | (not connected) | | includes N22/N21 = DEV_OE/DEV_CLRn: keep those options off |
| 61, 62 | 62, 61 | — | | GND | | |
| 63, 64 | 64, 63 | — | | VIN 5 V | | feeds the I/O board: keyboard module, ESP32 VIN, K7803 (its own 3.3 V) |

- VGA: binary-weighted DAC per colour into 75 Ohm, 0.7 V full scale. LSpectrum maps the ZX colours to
  normal = 4'hE, bright = 4'hF (`rtl/LSpectrum.v`).
- Joystick mode from the F4 menu (zx_system.v): both Kempston (lines ANDed, default), DB9-1 Kempston + DB9-2 Cursor,
  or Interface 2 (DB9-1 Sinclair 1, DB9-2 Sinclair 2).
- Keyboard module: both lines are inputs (RX = KB_OUT AND KB_IN), so either direction works.
- The SD card is on the ESP32 (D18 SCK, D19 MISO, D23 MOSI, D5 CS), not on the FPGA.

### On-board
- KEY0 (W13) = reset of everything (the ESP32 restarts). KEY1 (Y13) = back to the machine menu (AMenu). LED (E4) on = turbo.

Electrical notes:
- Unused pins are inputs ("Reserve all unused pins: As input tri-stated").
- Inputs from the ESP32 and the keyboard module have the FPGA's weak pull-up (~25 kOhm, `WEAK_PULL_UP_RESISTOR ON`),
  so they are defined when the ESP32 or the module is unplugged. The joysticks have 3k3 pull-ups on the I/O board.
- Inputs are synchronised (2 flip-flops) in the FPGA.
- During FPGA configuration all user pins are inputs with weak pull-ups: VGA/audio outputs float high for
  ~0.3 s at power-up. Harmless for a resistor DAC and an RC filter.
- **Check the U8 pin numbering against the board with a meter** before connecting (it was read from the
  schematic image): confirm pins 1/2 = GND, 3/4 = 3.3 V, 61/62 = GND, 63/64 = VIN.

## QMTECH Cyclone 10 LP core board (10CL025YU256I7G)

The second core board (schematic V1, 2023-11-09, `vendor/QMTECH_10CL025_V1_schematic.pdf`). Same size, same headers
at the same places, W9825G6KH SDRAM, W25Q64 flash, 50 MHz oscillator. Differences that matter:

- **One user key** (SW1 = KEY0, F3, 4.7 k pull-up). SW3 is nCONFIG: it reloads the factory image (the machine menu).
  The machines' KEY1 input is on header U7 pin 7 (G1) with a weak pull-up, free for a second button to ground.
- U8 pins 5 / 6 are GND (clock inputs on the EP4CE15 board); the I/O board leaves them unconnected.
- U8 pins 39-44 are dual-purpose configuration pins (J16 DEV_OE, J15 DEV_CLRN, G16 INIT_DONE, G15 CRC_ERROR,
  F16 nCEO, F15 CLKUSR); the I/O board has no signal there.
- U7 has I/O only on pins 7-46 (47-60 not connected).
- The projects are in each machine's `10cl025/` folder, generated by `tools/mk_10cl025_qsf.py`, which holds this
  table in code.

| Part | 10CL025 | EP4CE15 |
|---|---|---|
| 50 MHz oscillator | E2 | T2 |
| KEY0 (RESET_N) | F3 | W13 |
| KEY1 | G1 (U7.7, no button on the board) | Y13 |
| LED (active low) | N9 | E4 |
| SDRAM CLK / CKE / CS / RAS / CAS / WE | P2 / R1 / P8 / M8 / M7 / P6 | Y6 / W6 / AA3 / AB3 / AA4 / AB4 |
| SDRAM BA0, BA1 / LDQM, UDQM | N8, L8 / N6, P1 | Y1, W2 / AA5, W7 |
| SDRAM A0..A12 | R7 T7 T10 R10 R6 T5 R5 T4 R4 T3 T6 R3 T2 | V2 V1 U2 U1 V3 V4 Y2 AA1 Y3 V5 W1 Y4 V6 |
| SDRAM DQ0..DQ15 | K5 L3 L4 L7 N3 M6 P3 N5 N2 N1 L1 L2 K1 K2 J1 J2 | AA10 AB9 AA9 AB8 AA8 AB7 AA7 AB5 Y7 W8 Y8 V9 V10 Y10 W10 V11 |

Header U8 with the I/O board (J1 wired pair-swapped, as on the EP4CE15 board):

| U8 | J1 | Signal | 10CL025 | EP4CE15 |
|---|---|---|---|---|
| 7 | 8 | ESP_MOSI | R11 | AA13 |
| 8 | 7 | ESP_SCK | T11 | AB13 |
| 9 | 10 | ESP_MISO | R12 | AA14 |
| 10 | 9 | ESP_CS_N | T12 | AB14 |
| 11 | 12 | BT_BCLK | M10 | AA15 |
| 12 | 11 | ESP_IRQ | P9 | AB15 |
| 13 | 14 | BT_DATA | P11 | AA16 |
| 14 | 13 | BT_LRCK | N11 | AB16 |
| 15 | 16 | BT_RX | R13 | AA17 |
| 16 | 15 | BT_TX | T13 | AB17 |
| 17 | 18 | AUDIO_AY | R14 | AA18 |
| 18 | 17 | KB_IN | T14 | AB18 |
| 19 | 20 | AUDIO_BEEP | N12 | AA19 |
| 20 | 19 | KB_OUT | T15 | AB19 |
| 21 | 22 | JOY1_DOWN_N | N14 | AA20 |
| 22 | 21 | JOY1_UP_N | P14 | AB20 |
| 23 | 24 | JOY1_RIGHT_N | P15 | Y22 |
| 24 | 23 | JOY1_LEFT_N | R16 | Y21 |
| 25 | 26 | JOY2_UP_N | N15 | W22 |
| 26 | 25 | JOY1_FIRE_N | P16 | W21 |
| 27 | 28 | JOY2_LEFT_N | L15 | V22 |
| 28 | 27 | JOY2_DOWN_N | N16 | V21 |
| 29 | 30 | JOY2_FIRE_N | L16 | U22 |
| 30 | 29 | JOY2_RIGHT_N | L13 | U21 |
| 31 | 32 | - | L14 | R22 |
| 32 | 31 | - | K15 | R21 |
| 33 | 34 | - | K16 | P22 |
| 34 | 33 | - | J13 | P21 |
| 35 | 36 | - | J14 | N22 |
| 36 | 35 | - | F13 | N21 |
| 37 | 38 | - | D12 | M22 |
| 38 | 37 | - | F14 | M21 |
| 39 | 40 | - | J16 | L22 |
| 40 | 39 | - | J15 | L21 |
| 41 | 42 | - | G16 | K22 |
| 42 | 41 | - | G15 | K21 |
| 43 | 44 | - | F16 | J22 |
| 44 | 43 | - | F15 | J21 |
| 45 | 46 | - | D15 | H22 |
| 46 | 45 | VGA_VS | D16 | H21 |
| 47 | 48 | - | D14 | F22 |
| 48 | 47 | VGA_HS | C14 | F21 |
| 49 | 50 | VGA_R[1] | C16 | E22 |
| 50 | 49 | VGA_R[3] | C15 | E21 |
| 51 | 52 | VGA_R[0] | B16 | D22 |
| 52 | 51 | VGA_R[2] | A15 | D21 |
| 53 | 54 | VGA_G[1] | B14 | C22 |
| 54 | 53 | VGA_G[3] | A14 | C21 |
| 55 | 56 | VGA_G[0] | B13 | B22 |
| 56 | 55 | VGA_G[2] | A13 | B21 |
| 57 | 58 | VGA_B[1] | B12 | N20 |
| 58 | 57 | VGA_B[3] | A12 | N19 |
| 59 | 60 | VGA_B[0] | B11 | M20 |
| 60 | 59 | VGA_B[2] | A11 | M19 |
