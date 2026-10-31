//=============================================================================
// VGA_TEST -- colour bars on the QM_Atrix adapter's VGA output (prototype fit:
//             adapter J2 plugged into U8, see docs/BOARD_PINOUT.md)
//
// 60 Hz: 640x480 at 25.000 MHz.  50 Hz: 720x576 (576p) at 27.000 MHz.
// Chosen by the adapter's 50/60 switch (S1 -> U7.22 D2); KEY1 swaps the choice.
// 15 bars (42-43 px at 640, 48 px at 720): ZX colours, each bright then normal,
// black in the middle:
//   white, white, yellow, yellow, cyan, cyan, green | BLACK | green, magenta,
//   magenta, red, red, blue, blue        (bright = both DAC bits, normal = high bit)
// A 1 px white frame marks the edges of the active area (checks centring/size).
//
// Pixel clock: both PLL outputs go to a global clock control block. A mode
// change is sequenced from the 50 MHz domain: video reset on, clock disabled,
// select changed, clock enabled, video reset off. No clock glitch can reach
// the video logic, and the video logic always starts a mode from reset.
//
// LED (E4): on = 50 Hz (576p), off = 60 Hz (640x480).
// KEY1 (Y13): each press swaps 50/60 relative to the switch.
// RESET_N (W13): restarts everything.
// GND_TIE (AB17, AA17): the adapter's J2.49/J2.50 ground these pins. They are
//                       inputs here and must never be driven by any design.
//=============================================================================
`default_nettype none

module VGA_TEST #(
    parameter SW_HIGH_IS_50 = 1'b1      // reference: vsync_select = 1 -> 50 Hz
)(
    input  wire       CLOCK_50,
    input  wire       RESET_N,
    input  wire       SW_50_60,
    input  wire       KEY1,             // active low, 4.7k pull-up on the board
    input  wire [1:0] GND_TIE,          // tied to GND on the adapter, unused
    output wire       LEDR,

    output reg        VGA_R,
    output reg        VGA_R_LOW,
    output reg        VGA_G,
    output reg        VGA_G_LOW,
    output reg        VGA_B,
    output reg        VGA_B_LOW,
    output reg        VGA_HSYNC,
    output reg        VGA_VSYNC
);

//-----------------------------------------------------------------------------
// PLL and 50 MHz control domain
//-----------------------------------------------------------------------------
wire clk25, clk27, locked;

vga_pll u_pll (
    .inclk0 (CLOCK_50),
    .c0     (clk25),
    .c1     (clk27),
    .locked (locked)
);

wire       arst50_n = RESET_N & locked;
reg  [2:0] rst50_sr;
always @(posedge CLOCK_50 or negedge arst50_n)
    if (!arst50_n) rst50_sr <= 3'b000;
    else           rst50_sr <= {rst50_sr[1:0], 1'b1};
wire rst50_n = rst50_sr[2];

// 50/60 switch and KEY1: synchronise, accept a new level after ~10 ms stable
wire sw_50, key_down;

debounce u_db_sw  (.clk(CLOCK_50), .rst_n(rst50_n), .in(SW_HIGH_IS_50 ? SW_50_60 : !SW_50_60), .out(sw_50));
debounce u_db_key (.clk(CLOCK_50), .rst_n(rst50_n), .in(!KEY1), .out(key_down));

reg key_d, flip;
always @(posedge CLOCK_50 or negedge rst50_n)
    if (!rst50_n) begin
        key_d <= 1'b0;
        flip  <= 1'b0;
    end else begin
        key_d <= key_down;
        if (key_down && !key_d)
            flip <= !flip;
    end

wire mode_req = sw_50 ^ flip;

//-----------------------------------------------------------------------------
// Pixel clock switch sequencer (50 MHz domain)
//-----------------------------------------------------------------------------
localparam [1:0] S_OFF = 2'd0,          // clock disabled, waiting to switch
                 S_SEL = 2'd1,          // select changed, waiting to enable
                 S_ENA = 2'd2,          // clock running, video still in reset
                 S_RUN = 2'd3;          // video running

reg  [1:0] state;
reg  [3:0] wait_cnt;
reg        sel;                         // 0 = 25 MHz / 640x480, 1 = 27 MHz / 576p
reg        clk_ena;
reg        video_run;

always @(posedge CLOCK_50 or negedge rst50_n)
    if (!rst50_n) begin
        state     <= S_OFF;
        wait_cnt  <= 4'd0;
        sel       <= 1'b0;
        clk_ena   <= 1'b0;
        video_run <= 1'b0;
    end else begin
        wait_cnt <= wait_cnt + 4'd1;
        case (state)
            S_OFF: if (&wait_cnt) begin sel <= mode_req; state <= S_SEL; end
            S_SEL: if (&wait_cnt) begin clk_ena <= 1'b1; state <= S_ENA; end
            S_ENA: if (&wait_cnt) begin video_run <= 1'b1; state <= S_RUN; end
            S_RUN: begin
                wait_cnt <= 4'd0;
                if (mode_req != sel) begin
                    video_run <= 1'b0;  // asynchronous reset of the video logic
                    clk_ena   <= 1'b0;
                    state     <= S_OFF;
                end
            end
        endcase
    end

wire clk;                               // pixel clock, 25 or 27 MHz

vga_clkmux u_clkmux (
    .clk0   (clk25),
    .clk1   (clk27),
    .sel    (sel),
    .ena    (clk_ena),
    .outclk (clk)
);

// Video reset: asserted asynchronously, released on the pixel clock
reg [2:0] rst_sr;
always @(posedge clk or negedge video_run)
    if (!video_run) rst_sr <= 3'b000;
    else            rst_sr <= {rst_sr[1:0], 1'b1};
wire rst_n = rst_sr[2];

//-----------------------------------------------------------------------------
// Sync generator (mode = sel, static while the video logic runs)
//-----------------------------------------------------------------------------
wire [9:0] hcnt, vcnt, x, y, h_act, v_act;
wire       active, hsync_n, vsync_n;

vga_timing u_timing (
    .clk     (clk),
    .rst_n   (rst_n),
    .mode_50 (sel),
    .hcnt    (hcnt),
    .vcnt    (vcnt),
    .active  (active),
    .x       (x),
    .y       (y),
    .h_act   (h_act),
    .v_act   (v_act),
    .hsync_n (hsync_n),
    .vsync_n (vsync_n)
);

//-----------------------------------------------------------------------------
// Colour bars: bar = floor(x * 15 / h_act), kept as a running fraction
// (acc = 15 * x mod h_act), so it works for both widths.
//-----------------------------------------------------------------------------
reg [3:0] bar;
reg [9:0] acc;

always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
        bar <= 4'd0;
        acc <= 10'd0;
    end else if (!active) begin
        bar <= 4'd0;
        acc <= 10'd0;
    end else if (acc + 10'd15 >= h_act) begin
        bar <= bar + 4'd1;
        acc <= acc + 10'd15 - h_act;
    end else
        acc <= acc + 10'd15;

reg  [2:0]  grb;                        // ZX colour number: G R B
reg         bright;

always @* begin
    case (bar)
        4'd0:    begin grb = 3'd7; bright = 1'b1; end   // white
        4'd1:    begin grb = 3'd7; bright = 1'b0; end
        4'd2:    begin grb = 3'd6; bright = 1'b1; end   // yellow
        4'd3:    begin grb = 3'd6; bright = 1'b0; end
        4'd4:    begin grb = 3'd5; bright = 1'b1; end   // cyan
        4'd5:    begin grb = 3'd5; bright = 1'b0; end
        4'd6:    begin grb = 3'd4; bright = 1'b1; end   // green
        4'd7:    begin grb = 3'd0; bright = 1'b0; end   // black (middle)
        4'd8:    begin grb = 3'd4; bright = 1'b0; end   // green
        4'd9:    begin grb = 3'd3; bright = 1'b1; end   // magenta
        4'd10:   begin grb = 3'd3; bright = 1'b0; end
        4'd11:   begin grb = 3'd2; bright = 1'b1; end   // red
        4'd12:   begin grb = 3'd2; bright = 1'b0; end
        4'd13:   begin grb = 3'd1; bright = 1'b1; end   // blue
        default: begin grb = 3'd1; bright = 1'b0; end
    endcase
end

wire edge_px = (x == 10'd0) || (x == h_act - 10'd1) || (y == 10'd0) || (y == v_act - 10'd1);

// Output registers (packed into the I/O cells): colour and syncs stay aligned
always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
        {VGA_R, VGA_R_LOW, VGA_G, VGA_G_LOW, VGA_B, VGA_B_LOW} <= 6'd0;
        VGA_HSYNC <= 1'b1;
        VGA_VSYNC <= 1'b1;
    end else begin
        if (!active)
            {VGA_R, VGA_R_LOW, VGA_G, VGA_G_LOW, VGA_B, VGA_B_LOW} <= 6'd0;
        else if (edge_px)
            {VGA_R, VGA_R_LOW, VGA_G, VGA_G_LOW, VGA_B, VGA_B_LOW} <= 6'b111111;
        else begin
            VGA_R <= grb[1];  VGA_R_LOW <= grb[1] & bright;
            VGA_G <= grb[2];  VGA_G_LOW <= grb[2] & bright;
            VGA_B <= grb[0];  VGA_B_LOW <= grb[0] & bright;
        end
        VGA_HSYNC <= hsync_n;
        VGA_VSYNC <= vsync_n;
    end

assign LEDR = !sel;                     // active low LED

endmodule

//-----------------------------------------------------------------------------
// 2-FF synchroniser + ~10 ms (2^19 clocks at 50 MHz) stability filter
//-----------------------------------------------------------------------------
module debounce (
    input  wire clk,
    input  wire rst_n,
    input  wire in,
    output reg  out
);
reg [1:0]  sync;
reg [18:0] cnt;
always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
        sync <= 2'b00;
        cnt  <= 19'd0;
        out  <= 1'b0;
    end else begin
        sync <= {sync[0], in};
        if (sync[1] == out)
            cnt <= 19'd0;
        else if (&cnt)
            out <= sync[1];
        else
            cnt <= cnt + 19'd1;
    end
endmodule

`default_nettype wire
