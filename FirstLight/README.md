# FirstLight — the first project of the book

The project of Chapter 4 ("First light: LED, buttons and color bars"), for the QMTECH Cyclone IV core
board (EP4CE15F23C8) and the L I/O board.

- **LED** (E4): blinks, slowly at 60 Hz and faster at 50 Hz.
- **KEY1** (Y13): each press swaps the video between 640x480 at 60 Hz (25.208 MHz) and 720x576 at 50 Hz
  (576p, 27.009 MHz). **KEY0** (RESET_N, W13) restarts at 60 Hz.
- **VGA** (I/O board, 4 bits per color): 8 color bars, a 16-step gray ramp in the lower quarter (every
  value of the DAC) and a white frame 1 pixel wide around the visible area.

| File | Role |
|---|---|
| `first_light.qpf` / `.qsf` / `.sdc` | Quartus project, settings and pins, timing constraints |
| `first_light_10cl025.qsf` | second revision of the project: the same design for the QMTECH Cyclone 10 LP core board (10CL025YU256I7G); only the device and the pins differ |
| `rtl/first_light.v` | top level: reset, key, LED, pixel clock switch, the picture |
| `rtl/vga_timing.v` | sync generator for both modes |
| `rtl/vga_pll.v` | PLL: 25.208 and 27.009 MHz from one VCO (as LSpectrum) |
| `rtl/vga_clkmux.v` | global clock control block: glitch-free switch between the two pixel clocks |
| `sim/tb_vga_timing.sv` | Questa test of vga_timing alone, both modes (clocks per line, lines per frame, visible area): PASS |
| `sim/tb_first_light.sv` | the whole design with models of the PLL and the clock control block: line period at 60 Hz, KEY1, line period at 50 Hz, pixel colors: PASS (about 40 s) |
| `sim/run_sim.sh` | runs both testbenches |

Build: `quartus_sh --flow compile first_light`, then load `output_files/first_light.sof` with the Programmer
(JTAG). The .sof is lost at power-off; the flash (menu and machines) is not touched.

Last build (Quartus 25.1std Lite): 233 LEs, 1 PLL, 18 pins, timing met at all corners, no unconstrained paths.

Cyclone 10 LP board (revision `first_light_10cl025`, `quartus_sh --flow compile first_light -c first_light_10cl025`):
clock E2, LED D1 = N9, RESET_N = the board's key SW1 (F3); KEY1 = G1 (header U7 pin 7, weak pull-up on) needs a push
button to ground, without it the design stays at 60 Hz. VGA on the same U8 pins. Built 2026-11-12: 235 LEs, 18 pins,
timing met, no unconstrained paths; not yet run on hardware.

On hardware (2026-11-05): LED D5 blinks, 8 bars + 16 gray steps, KEY1 swaps 640x480@60 / 576p (the monitor reports 576p as "800x600@50").
