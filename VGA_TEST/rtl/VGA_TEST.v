/* VGA_TEST -- colour bars on the QM_Atrix adapter's VGA output (prototype fit: */
/* adapter J2 plugged into U8, see docs/BOARD_PINOUT.md) */
/* */
/* 60 Hz: 640x480 at 25.000 MHz.  50 Hz: 720x576 (576p) at 27.000 MHz. */
/* Chosen by the adapter's 50/60 switch (S1 -> U7.22 D2); KEY1 swaps the choice. */
/* 15 bars (42-43 px at 640, 48 px at 720): ZX colours, each bright then normal, */
/* black in the middle: */
/* white, white, yellow, yellow, cyan, cyan, green | BLACK | green, magenta, */
/* magenta, red, red, blue, blue        (bright = both DAC bits, normal = high bit) */
/* A 1 px white frame marks the edges of the active area (checks centring/size). */
/* */
/* Pixel clock: both PLL outputs go to a global clock control block. A mode */
/* change is sequenced from the 50 MHz domain: video reset on, clock disabled, */
/* select changed, clock enabled, video reset off. No clock glitch can reach */
/* the video logic, and the video logic always starts a mode from reset. */
/* */
/* LED (E4): on = 50 Hz (576p), off = 60 Hz (640x480). */
/* KEY1 (Y13): each press swaps 50/60 relative to the switch. */
/* RESET_N (W13): restarts everything. */
/* GND_TIE (AB17, AA17): the adapter's J2.49/J2.50 ground these pins. They are */
/* inputs here and must never be driven by any design. */
`default_nettype none

module VGA_TEST #(
/* reference: vsync_select = 1 -> 50 Hz */
    parameter SW_HIGH_IS_50 = 1'b1
)(
    input  wire       CLOCK_50,
    input  wire       RESET_N,
    input  wire       SW_50_60,
/* active low, 4.7k pull-up on the board */
    input  wire       KEY1,
/* tied to GND on the adapter, unused */
    input  wire [1:0] GND_TIE,
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

/* colour bars across the picture */
localparam [9:0] BARS = 10'd15;
/* green + red (the colour is {G, R, B}) */
localparam [2:0] COL_YELLOW = 3'd6;
/* green + blue */
localparam [2:0] COL_CYAN = 3'd5;
/* green */
localparam [2:0] COL_GREEN = 3'd4;
/* red + blue */
localparam [2:0] COL_MAGENTA = 3'd3;
/* red */
localparam [2:0] COL_RED = 3'd2;

/* PLL and 50 MHz control domain */
wire clk25, clk27, locked;

vga_pll u_pll (
    .inclk0 (CLOCK_50),
    .c0     (clk25),
    .c1     (clk27),
    .locked (locked)
);

/* reset: asserted at once, released on the clock */
wire       arst50_n = RESET_N & locked;
reg  [2:0] rst50_sr;
always @(posedge CLOCK_50 or negedge arst50_n)
/* asserted */
    if (!arst50_n)
    begin
        rst50_sr <= 3'b000;
    end
    else
    begin
/* three clocks later */
        rst50_sr <= {rst50_sr[1:0], 1'b1};
    end
wire rst50_n = rst50_sr[2];

/* 50/60 switch and KEY1: synchronise, accept a new level after ~10 ms stable */
wire sw_50, key_down;

debounce u_db_sw  (.clk(CLOCK_50), .rst_n(rst50_n), .in(SW_HIGH_IS_50 ? SW_50_60 : !SW_50_60), .out(sw_50));
debounce u_db_key (.clk(CLOCK_50), .rst_n(rst50_n), .in(!KEY1), .out(key_down));

/* a key press toggles the mode */
reg key_d, flip;
always @(posedge CLOCK_50 or negedge rst50_n)
    if (!rst50_n)
    begin
/* nothing pressed yet */
        key_d <= 1'b0;
        flip  <= 1'b0;
    end
    else
    begin
/* a new press */
        key_d <= key_down;
        if (key_down && !key_d)
        begin
            flip <= !flip;
        end
    end

/* the mode asked for: the switch, toggled by the key */
wire mode_req = sw_50 ^ flip;

/* Pixel clock switch sequencer (50 MHz domain) */
/* clock disabled, waiting to switch */
localparam [1:0] S_OFF = 2'd0,
/* select changed, waiting to enable */
                 S_SEL = 2'd1,
/* clock running, video still in reset */
                 S_ENA = 2'd2,
/* video running */
                 S_RUN = 2'd3;

reg  [1:0] state;
reg  [3:0] wait_cnt;
/* 0 = 25 MHz / 640x480, 1 = 27 MHz / 576p */
reg        sel;
reg        clk_ena;
reg        video_run;

/* the switch sequence */
always @(posedge CLOCK_50 or negedge rst50_n)
    if (!rst50_n)
    begin
        state     <= S_OFF;
/* nothing selected, nothing enabled */
        wait_cnt  <= 4'd0;
        sel       <= 1'b0;
        clk_ena   <= 1'b0;
/* the video logic in reset; a step every 16 clocks */
        video_run <= 1'b0;
    end
    else
    begin
        wait_cnt <= wait_cnt + 4'd1;
        case (state)
/* everything off: select the clock */
            S_OFF:
                if (&wait_cnt)
                begin
/* the clock for the mode asked for */
                    sel <= mode_req;
                    state <= S_SEL;
                end
/* selected: enable it */
            S_SEL:
                if (&wait_cnt)
                begin
/* the clock runs */
                    clk_ena <= 1'b1;
                    state <= S_ENA;
                end
/* enabled: release the video reset */
            S_ENA:
                if (&wait_cnt)
                begin
/* the video logic starts */
                    video_run <= 1'b1;
                    state <= S_RUN;
                end
/* running: watch for a mode change */
            S_RUN:
            begin
                wait_cnt <= 4'd0;
                if (mode_req != sel)
                begin
/* asynchronous reset of the video logic */
                    video_run <= 1'b0;
                    clk_ena   <= 1'b0;
                    state     <= S_OFF;
                end
            end
        endcase
    end

/* pixel clock, 25 or 27 MHz */
wire clk;

vga_clkmux u_clkmux (
    .clk0   (clk25),
    .clk1   (clk27),
    .sel    (sel),
    .ena    (clk_ena),
    .outclk (clk)
);

/* Video reset: asserted asynchronously, released on the pixel clock */
reg [2:0] rst_sr;
always @(posedge clk or negedge video_run)
    if (!video_run)
    begin
/* asserted; released after three pixel clocks */
        rst_sr <= 3'b000;
    end
    else
    begin
        rst_sr <= {rst_sr[1:0], 1'b1};
    end
wire rst_n = rst_sr[2];

/* Sync generator (mode = sel, static while the video logic runs) */
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

/* Colour bars: bar = floor(x * 15 / h_act), kept as a running fraction */
/* (acc = 15 * x mod h_act), so it works for both widths. */
reg [3:0] bar;
reg [9:0] acc;

always @(posedge clk or negedge rst_n)
/* one step per pixel */
    if (!rst_n)
    begin
        bar <= 4'd0;
        acc <= 10'd0;
    end
/* outside the picture */
    else if (!active)
    begin
        bar <= 4'd0;
        acc <= 10'd0;
    end
/* a new bar every 1/15 of the width */
    else if (acc + BARS >= h_act)
    begin
        bar <= bar + 4'd1;
        acc <= acc + BARS - h_act;
    end
    else
    begin
/* not yet */
        acc <= acc + BARS;
    end

/* ZX colour number: G R B */
reg  [2:0]  grb;
reg         bright;

/* bar number -> colour and brightness */
always @*
begin
    case (bar)
/* white */
        4'd0:
        begin
            grb = 3'd7;
            bright = 1'b1;
        end
/* the same, normal */
        4'd1:
        begin
            grb = 3'd7;
            bright = 1'b0;
        end
/* yellow */
        4'd2:
        begin
            grb = COL_YELLOW;
            bright = 1'b1;
        end
/* normal */
        4'd3:
        begin
            grb = COL_YELLOW;
            bright = 1'b0;
        end
/* cyan */
        4'd4:
        begin
            grb = COL_CYAN;
            bright = 1'b1;
        end
/* normal */
        4'd5:
        begin
            grb = COL_CYAN;
            bright = 1'b0;
        end
/* green */
        4'd6:
        begin
            grb = COL_GREEN;
            bright = 1'b1;
        end
/* black (middle) */
        4'd7:
        begin
            grb = 3'd0;
            bright = 1'b0;
        end
/* green */
        4'd8:
        begin
            grb = COL_GREEN;
            bright = 1'b0;
        end
/* magenta */
        4'd9:
        begin
            grb = COL_MAGENTA;
            bright = 1'b1;
        end
/* normal */
        4'd10:
        begin
            grb = COL_MAGENTA;
            bright = 1'b0;
        end
/* red */
        4'd11:
        begin
            grb = COL_RED;
            bright = 1'b1;
        end
/* normal */
        4'd12:
        begin
            grb = COL_RED;
            bright = 1'b0;
        end
/* blue */
        4'd13:
        begin
            grb = 3'd1;
            bright = 1'b1;
        end
/* normal (bar 14) */
        default:
        begin
            grb = 3'd1;
            bright = 1'b0;
        end
    endcase
end

/* the frame around the picture */
wire edge_px = (x == 10'd0) || (x == h_act - 10'd1) || (y == 10'd0) || (y == v_act - 10'd1);

/* Output registers (packed into the I/O cells): colour and syncs stay aligned */
always @(posedge clk or negedge rst_n)
    if (!rst_n)
    begin
        {VGA_R, VGA_R_LOW, VGA_G, VGA_G_LOW, VGA_B, VGA_B_LOW} <= 6'd0;
/* syncs inactive */
        VGA_HSYNC <= 1'b1;
        VGA_VSYNC <= 1'b1;
    end
    else
    begin
        if (!active)
        begin
/* black outside the picture, white on its edge */
            {VGA_R, VGA_R_LOW, VGA_G, VGA_G_LOW, VGA_B, VGA_B_LOW} <= 6'd0;
        end
        else if (edge_px)
        begin
            {VGA_R, VGA_R_LOW, VGA_G, VGA_G_LOW, VGA_B, VGA_B_LOW} <= 6'b111111;
        end
        else
        begin
/* the bar: the high DAC bit, the low one only when bright */
            VGA_R <= grb[1];
            VGA_R_LOW <= grb[1] & bright;
            VGA_G <= grb[2];
/* green and blue */
            VGA_G_LOW <= grb[2] & bright;
            VGA_B <= grb[0];
            VGA_B_LOW <= grb[0] & bright;
        end
/* the syncs */
        VGA_HSYNC <= hsync_n;
        VGA_VSYNC <= vsync_n;
    end

/* active low LED */
assign LEDR = !sel;

endmodule

/* 2-FF synchroniser + ~10 ms (2^19 clocks at 50 MHz) stability filter */
module debounce (
    input  wire clk,
    input  wire rst_n,
    input  wire in,
    output reg  out
);
reg [1:0]  sync;
reg [18:0] cnt;
/* synchronise, then count while the input differs from the output */
always @(posedge clk or negedge rst_n)
    if (!rst_n)
    begin
        sync <= 2'b00;
/* counter and output cleared */
        cnt  <= 19'd0;
        out  <= 1'b0;
    end
    else
    begin
/* the same as the output: nothing to count */
        sync <= {sync[0], in};
        if (sync[1] == out)
        begin
            cnt <= 19'd0;
        end
/* stable long enough: taken over */
        else if (&cnt)
        begin
            out <= sync[1];
        end
        else
        begin
/* still counting */
            cnt <= cnt + 19'd1;
        end
    end
endmodule

`default_nettype wire
