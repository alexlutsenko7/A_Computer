//=============================================================================
// vga_timing -- sync generator for two modes, each on its own pixel clock
//
//   mode_50 = 0: 640x480@60, 25.000 MHz, 800 x 525 -> 31.25 kHz, 59.52 Hz
//                (same as the DE10-Lite reference; VESA uses 25.175 MHz)
//   mode_50 = 1: 720x576@50 (CEA-861 576p), 27.000 MHz, 864 x 625 -> 31.25 kHz, 50.00 Hz
//
// A line starts with the sync pulse, then back porch, active, front porch.
// A frame starts with the sync lines, then back porch, active, front porch.
// Both syncs negative in both modes.
//
//              sync  back porch  active  front porch  total
//   640x480 H   96      48        640       16         800
//           V    2      33        480       10         525
//   720x576 H   64      68        720       12         864
//           V    5      39        576        5         625
//
// History: 640x480 inside 625 lines (800x625) was shown by the user's monitor
// as "800x600@50" (picture squeezed to the top); 850x588 (29.4 kHz) gave
// "Input not supported". A true 576p frame avoids both.
//
// mode_50 must only change while rst_n is low (the pixel clock is switched
// at the same time, see VGA_TEST.v).
//=============================================================================
`default_nettype none

module vga_timing (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       mode_50,        // static while running

    output reg  [9:0] hcnt,
    output reg  [9:0] vcnt,
    output wire       active,
    output wire [9:0] x,              // 0..h_act-1 inside the active area
    output wire [9:0] y,              // 0..v_act-1 inside the active area
    output wire [9:0] h_act,          // active width  (640 / 720)
    output wire [9:0] v_act,          // active height (480 / 576)
    output wire       hsync_n,
    output wire       vsync_n
);

wire [9:0] h_sync  = mode_50 ? 10'd64  : 10'd96;
wire [9:0] h_start = mode_50 ? 10'd132 : 10'd144;   // sync + back porch
wire [9:0] h_total = mode_50 ? 10'd864 : 10'd800;
wire [9:0] v_sync  = mode_50 ? 10'd5   : 10'd2;
wire [9:0] v_start = mode_50 ? 10'd44  : 10'd35;
wire [9:0] v_total = mode_50 ? 10'd625 : 10'd525;
assign     h_act   = mode_50 ? 10'd720 : 10'd640;
assign     v_act   = mode_50 ? 10'd576 : 10'd480;

wire line_end  = (hcnt == h_total - 10'd1);
wire frame_end = (vcnt == v_total - 10'd1);

always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
        hcnt <= 10'd0;
        vcnt <= 10'd0;
    end else if (line_end) begin
        hcnt <= 10'd0;
        vcnt <= frame_end ? 10'd0 : vcnt + 10'd1;
    end else
        hcnt <= hcnt + 10'd1;

assign x       = hcnt - h_start;
assign y       = vcnt - v_start;
assign active  = (hcnt >= h_start) && (x < h_act) && (vcnt >= v_start) && (y < v_act);
assign hsync_n = !(hcnt < h_sync);
assign vsync_n = !(vcnt < v_sync);

endmodule

`default_nettype wire
