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
| `rtl/first_light.v` | top level: reset, key, LED, pixel clock switch, the picture |
| `rtl/vga_timing.v` | sync generator for both modes |
| `rtl/vga_pll.v` | PLL: 25.208 and 27.009 MHz from one VCO (as LSpectrum) |
| `rtl/vga_clkmux.v` | global clock control block: glitch-free switch between the two pixel clocks |
| `sim/tb_vga_timing.sv`, `sim/run_sim.sh` | Questa test of both modes (clocks per line, lines per frame, visible area): PASS |

Build: `quartus_sh --flow compile first_light`, then load `output_files/first_light.sof` with the Programmer
(JTAG). The .sof is lost at power-off; the flash (menu and machines) is not touched.

Last build (Quartus 25.1std Lite): 233 LEs, 1 PLL, 18 pins, timing met at all corners, no unconstrained paths.

On hardware (2026-11-05): LED D5 blinks, 8 bars + 16 gray steps, KEY1 swaps 640x480@60 / 576p (the monitor reports 576p as "800x600@50").
