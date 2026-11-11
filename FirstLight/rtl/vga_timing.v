/* vga_timing -- sync generator for two modes, each on its own pixel clock */
/* */
/* mode_50 = 0: 640x480 at 60 Hz: 25.208 MHz, 800 x 525 -> 31.51 kHz, 60.02 Hz */
/* mode_50 = 1: 720x576 at 50 Hz (CEA-861 576p): 27.009 MHz, 864 x 625 */
/* -> 31.26 kHz, 50.02 Hz */
/* */
/* A line starts with the sync pulse, then the back porch, the active pixels */
/* and the front porch; a frame the same way in lines. Both syncs are negative. */
/* */
/* sync  back porch  active  front porch  total */
/* 640x480 H   96      48        640       16         800 */
/* V    2      33        480       10         525 */
/* 720x576 H   64      68        720       12         864 */
/* V    5      39        576        5         625 */
/* */
/* mode_50 must only change while rst_n is low (the pixel clock changes with it). */
`default_nettype none

module vga_timing (
/* pixel clock */
    input  wire       clk,
    input  wire       rst_n,
/* static while running */
    input  wire       mode_50,

/* 0 .. h_total-1 */
    output reg  [9:0] hcnt,
/* 0 .. v_total-1 */
    output reg  [9:0] vcnt,
/* inside the visible picture */
    output wire       active,
/* 0 .. h_act-1 inside the picture */
    output wire [9:0] x,
/* 0 .. v_act-1 inside the picture */
    output wire [9:0] y,
/* visible width  (640 / 720) */
    output wire [9:0] h_act,
/* visible height (480 / 576) */
    output wire [9:0] v_act,
    output wire       hsync_n,
    output wire       vsync_n
);

/* horizontal sync width, 720x576 at 50 Hz */
localparam [9:0] H_SYNC_50 = 10'd64;
/* horizontal sync width, 640x480 at 60 Hz */
localparam [9:0] H_SYNC_60 = 10'd96;
/* first visible pixel (sync + back porch), 50 Hz */
localparam [9:0] H_START_50 = 10'd132;
/* first visible pixel (sync + back porch), 60 Hz */
localparam [9:0] H_START_60 = 10'd144;
/* pixels per line, 50 Hz */
localparam [9:0] H_TOTAL_50 = 10'd864;
/* pixels per line, 60 Hz */
localparam [9:0] H_TOTAL_60 = 10'd800;
/* vertical sync width in lines, 50 Hz */
localparam [9:0] V_SYNC_50 = 10'd5;
/* vertical sync width in lines, 60 Hz */
localparam [9:0] V_SYNC_60 = 10'd2;
/* first visible line, 50 Hz */
localparam [9:0] V_START_50 = 10'd44;
/* first visible line, 60 Hz */
localparam [9:0] V_START_60 = 10'd35;
/* lines per frame, 50 Hz */
localparam [9:0] V_TOTAL_50 = 10'd625;
/* lines per frame, 60 Hz */
localparam [9:0] V_TOTAL_60 = 10'd525;
/* visible pixels per line, 50 Hz */
localparam [9:0] H_ACT_50 = 10'd720;
/* visible pixels per line, 60 Hz */
localparam [9:0] H_ACT_60 = 10'd640;
/* visible lines, 50 Hz */
localparam [9:0] V_ACT_50 = 10'd576;
/* visible lines, 60 Hz */
localparam [9:0] V_ACT_60 = 10'd480;

wire [9:0] h_sync  = mode_50 ? H_SYNC_50  : H_SYNC_60;
/* sync + back porch */
wire [9:0] h_start = mode_50 ? H_START_50 : H_START_60;
wire [9:0] h_total = mode_50 ? H_TOTAL_50 : H_TOTAL_60;
wire [9:0] v_sync  = mode_50 ? V_SYNC_50   : V_SYNC_60;
/* first picture line, lines per frame */
wire [9:0] v_start = mode_50 ? V_START_50  : V_START_60;
wire [9:0] v_total = mode_50 ? V_TOTAL_50 : V_TOTAL_60;
/* the visible size */
assign     h_act   = mode_50 ? H_ACT_50 : H_ACT_60;
assign     v_act   = mode_50 ? V_ACT_50 : V_ACT_60;

/* the last pixel of a line, the last line of a frame */
wire line_end  = (hcnt == h_total - 10'd1);
wire frame_end = (vcnt == v_total - 10'd1);

/* the two counters */
always @(posedge clk or negedge rst_n)
    if (!rst_n)
    begin
        hcnt <= 10'd0;
/* the line ends: the next one, or the first */
        vcnt <= 10'd0;
    end
    else if (line_end)
    begin
        hcnt <= 10'd0;
/* next line or first; else the next pixel */
        vcnt <= frame_end ? 10'd0 : vcnt + 10'd1;
    end
    else
    begin
        hcnt <= hcnt + 10'd1;
    end

/* position in the picture, and the picture's area */
assign x       = hcnt - h_start;
assign y       = vcnt - v_start;
assign active  = (hcnt >= h_start) && (x < h_act) && (vcnt >= v_start) && (y < v_act);
/* syncs, active low */
assign hsync_n = !(hcnt < h_sync);
assign vsync_n = !(vcnt < v_sync);

endmodule

`default_nettype wire
