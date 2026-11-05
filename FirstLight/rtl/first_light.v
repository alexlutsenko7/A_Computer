//=============================================================================
// first_light -- the first project of the book (Chapter 4): the core board's
//                LED and KEY1, and color bars on the I/O board's VGA output.
//
// LED:   blinks; slowly at 60 Hz, faster at 50 Hz.
// KEY1:  each press swaps the video between 640x480 at 60 Hz and 720x576 at
//        50 Hz.  KEY0 (RESET_N) restarts everything (60 Hz).
// VGA:   8 color bars in the upper three quarters, a 16-step gray ramp
//        (every value of the 4-bit DAC) in the lower quarter, and a white
//        frame 1 pixel wide around the visible area.
//
// Pixel clock: both PLL outputs go to a global clock control block. A mode
// change is sequenced from the 50 MHz domain: video reset on, clock off,
// select changed, clock on, video reset off. No clock glitch can reach the
// video logic, and every mode starts from reset.
//=============================================================================
`default_nettype none

module first_light (
    input  wire       CLOCK_50,         // 50 MHz oscillator on the core board
    input  wire       RESET_N,          // KEY0, low while pressed
    input  wire       KEY1,             // KEY1, low while pressed
    output wire       LEDR,             // core board LED, lit when low

    output reg  [3:0] VGA_R,
    output reg  [3:0] VGA_G,
    output reg  [3:0] VGA_B,
    output reg        VGA_HS,
    output reg        VGA_VS
);

//-----------------------------------------------------------------------------
// PLL and reset of the 50 MHz domain
//-----------------------------------------------------------------------------
wire clk25, clk27, locked;

vga_pll u_pll (
    .inclk0 (CLOCK_50),
    .c0     (clk25),                    // 25.208 MHz
    .c1     (clk27),                    // 27.009 MHz
    .locked (locked)
);

// Reset: asserted at once, released on the clock after 3 cycles
wire       arst50_n = RESET_N & locked;
reg  [2:0] rst50_sr;
always @(posedge CLOCK_50 or negedge arst50_n)
    if (!arst50_n) rst50_sr <= 3'b000;
    else           rst50_sr <= {rst50_sr[1:0], 1'b1};
wire rst50_n = rst50_sr[2];

//-----------------------------------------------------------------------------
// KEY1: synchronize and debounce; each press flips the requested mode
//-----------------------------------------------------------------------------
wire key_down;
debounce u_db (.clk(CLOCK_50), .rst_n(rst50_n), .in(!KEY1), .out(key_down));

reg key_d, mode_req;                    // mode_req: 0 = 60 Hz, 1 = 50 Hz
always @(posedge CLOCK_50 or negedge rst50_n)
    if (!rst50_n) begin
        key_d    <= 1'b0;
        mode_req <= 1'b0;
    end else begin
        key_d <= key_down;
        if (key_down && !key_d)
            mode_req <= !mode_req;
    end

//-----------------------------------------------------------------------------
// LED: a 26-bit counter at 50 MHz; bit 25 toggles every 0.67 s, bit 23 four
// times as often
//-----------------------------------------------------------------------------
reg [25:0] blink;
always @(posedge CLOCK_50 or negedge rst50_n)
    if (!rst50_n) blink <= 26'd0;
    else          blink <= blink + 26'd1;

//-----------------------------------------------------------------------------
// Pixel clock switch (50 MHz domain)
//-----------------------------------------------------------------------------
localparam [1:0] S_OFF = 2'd0,          // clock off, waiting to switch
                 S_SEL = 2'd1,          // select changed, waiting to enable
                 S_ENA = 2'd2,          // clock running, video still in reset
                 S_RUN = 2'd3;          // video running

reg  [1:0] state;
reg  [3:0] wait_cnt;
reg        sel;                         // 0 = 25.208 MHz / 60 Hz, 1 = 27.009 MHz / 50 Hz
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
                    video_run <= 1'b0;  // resets the video logic at once
                    clk_ena   <= 1'b0;
                    state     <= S_OFF;
                end
            end
        endcase
    end

assign LEDR = sel ? blink[23] : blink[25];

wire clk;                               // the pixel clock

vga_clkmux u_clkmux (
    .clk0   (clk25),
    .clk1   (clk27),
    .sel    (sel),
    .ena    (clk_ena),
    .outclk (clk)
);

// Video reset: asserted at once, released on the pixel clock
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
// The picture. bar = x * 8 / h_act and gray = x * 16 / h_act, each kept as a
// running fraction (acc = n * x mod h_act), so no divider is needed and the
// same logic works for 640 and 720 pixels.
//-----------------------------------------------------------------------------
reg [2:0] bar;
reg [3:0] gray;
reg [9:0] acc8, acc16;

always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
        bar <= 3'd0;  acc8  <= 10'd0;
        gray <= 4'd0; acc16 <= 10'd0;
    end else if (!active) begin
        bar <= 3'd0;  acc8  <= 10'd0;
        gray <= 4'd0; acc16 <= 10'd0;
    end else begin
        if (acc8 + 10'd8 >= h_act) begin
            bar  <= bar + 3'd1;
            acc8 <= acc8 + 10'd8 - h_act;
        end else
            acc8 <= acc8 + 10'd8;
        if (acc16 + 10'd16 >= h_act) begin
            gray  <= gray + 4'd1;
            acc16 <= acc16 + 10'd16 - h_act;
        end else
            acc16 <= acc16 + 10'd16;
    end

reg [2:0] rgb;                          // one bit per color
always @* begin
    case (bar)
        3'd0:    rgb = 3'b111;          // white
        3'd1:    rgb = 3'b110;          // yellow
        3'd2:    rgb = 3'b011;          // cyan
        3'd3:    rgb = 3'b010;          // green
        3'd4:    rgb = 3'b101;          // magenta
        3'd5:    rgb = 3'b100;          // red
        3'd6:    rgb = 3'b001;          // blue
        default: rgb = 3'b000;          // black
    endcase
end

wire frame_px = (x == 10'd0) || (x == h_act - 10'd1) || (y == 10'd0) || (y == v_act - 10'd1);
wire ramp     = (y >= v_act - (v_act >> 2));    // the lower quarter

// Output registers, placed in the I/O cells: colors and syncs change together
always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
        {VGA_R, VGA_G, VGA_B} <= 12'd0;
        VGA_HS <= 1'b1;
        VGA_VS <= 1'b1;
    end else begin
        if (!active)
            {VGA_R, VGA_G, VGA_B} <= 12'd0;     // black outside the picture
        else if (frame_px)
            {VGA_R, VGA_G, VGA_B} <= 12'hFFF;
        else if (ramp)
            {VGA_R, VGA_G, VGA_B} <= {gray, gray, gray};
        else
            {VGA_R, VGA_G, VGA_B} <= {{4{rgb[2]}}, {4{rgb[1]}}, {4{rgb[0]}}};
        VGA_HS <= hsync_n;
        VGA_VS <= vsync_n;
    end

endmodule

//-----------------------------------------------------------------------------
// debounce -- 2-flip-flop synchronizer, then a new level is taken only after
// it has been stable for 2^19 clocks (10.5 ms at 50 MHz)
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
