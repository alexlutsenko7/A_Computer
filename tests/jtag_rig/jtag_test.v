/* jtag_test -- test rig for a core board that has no I/O board yet. Over JTAG (In-System Sources and */
/* Probes) it presses a key, reads status bits, measures the video timing and reads the picture, one */
/* video line at a time. It is added to the tops by patch.py in a scratch copy of the sources only: */
/* the product images never contain it. See README.md. */
`default_nettype none

module jtag_test #(
/* the image's identity, read back with the status (the machines use their core IDs) */
    parameter [31:0] ID = 32'd0
) (
/* the board's 50 MHz oscillator: the time base of the measurements */
    input  wire        clk50,
/* the video: pixel clock, syncs as they go to the pins, {red, green, blue} of four bits each */
    input  wire        pclk,
    input  wire        hs,
    input  wire        vs,
    input  wire [11:0] rgb,
/* sixteen bits of the design, read as they are */
    input  wire [15:0] status,
/* 1 = the key is pressed (KEY1 of a machine) */
    output wire        key,
/* USB key code for the menu's keyboard, 0 = none */
    output wire [7:0]  code
);

/* samples of one video line per read */
localparam integer SAMPLES = 400;
/* the sample counter's value when the line is full */
localparam [8:0] LINE_FULL = 9'd400;
/* hsync edges per measurement of the line rate */
localparam [5:0] H_LAST = 6'd63;

/* source: [0] key, [8:1] code, [19:9] line, [31:20] first pixel, [34:32] step - 1, [38:35] bit of rgb */
wire [39:0] src;
reg  [SAMPLES-1:0] line_q;
altsource_probe #(
    .sld_auto_instance_index ("YES"), .sld_instance_index (0), .instance_id ("GRAB"),
    .probe_width (SAMPLES), .source_width (40), .source_initial_value ("0"), .enable_metastability ("NO")
) u_grab (.probe (line_q), .source (src));
/* the two outputs come straight from the source */
assign key  = src[0];
assign code = src[8:1];

/* pixel domain: the position is counted from the rising edges of the syncs */
reg        hs_d, vs_d;
reg [11:0] h, h_len;
reg [10:0] v, v_len;
/* frames counted: shows that the picture runs */
reg [7:0]  frames;
reg [SAMPLES-1:0] sh;
reg [8:0]  n;
/* the step counter between two samples */
reg [2:0]  st;
/* the chosen bit of the pixel; the edges */
wire       pix    = rgb[src[38:35]];
wire       h_edge = hs && !hs_d;
wire       v_edge = vs && !vs_d;
/* the syncs as they were one clock ago */
always @(posedge pclk)
begin
    hs_d <= hs;
    vs_d <= vs;
/* a line starts */
    if (h_edge)
    begin
/* a new line: its length is known, the samples of the chosen line are handed over */
        h     <= 12'd0;
        h_len <= h + 12'd1;
        v     <= v + 11'd1;
/* no samples yet */
        n     <= 9'd0;
        st    <= 3'd0;
        if (v == src[19:9])
        begin
/* the line's samples for the probe */
            line_q <= sh;
        end
    end
    else
    begin
        h <= h + 12'd1;
    end
    if (v_edge)
    begin
/* a new frame: the line count restarts (the line that starts with this edge is line 0) */
        v      <= 11'd0;
        v_len  <= h_edge ? v + 11'd1 : v;
        frames <= frames + 8'd1;
    end
/* the samples of the chosen line: one every (step) pixels from the first pixel on */
    if (v == src[19:9] && h >= src[31:20] && n != LINE_FULL && !h_edge)
    begin
        if (st == 3'd0)
        begin
            sh[n] <= pix;
/* the next sample comes (step) pixels later */
            n     <= n + 9'd1;
            st    <= src[34:32];
        end
        else
        begin
            st <= st - 3'd1;
        end
    end
end

/* 50 MHz domain: clocks per frame and per 64 lines */
reg [2:0]  vs_s, hs_s;
reg [23:0] vt, v_per;
reg [23:0] ht, h_per;
/* the count of line edges */
reg [5:0]  hn;
always @(posedge clk50)
begin
/* the syncs in this domain; both timers run */
    vs_s <= {vs_s[1:0], vs};
    hs_s <= {hs_s[1:0], hs};
    vt   <= vt + 24'd1;
/* a frame edge */
    ht   <= ht + 24'd1;
    if (vs_s[2:1] == 2'b01)
    begin
/* a frame is over */
        v_per <= vt + 24'd1;
        vt    <= 24'd0;
    end
    if (hs_s[2:1] == 2'b01)
    begin
/* a line is over; every 64th closes a measurement */
        hn <= hn + 6'd1;
        if (hn == H_LAST)
        begin
            h_per <= ht + 24'd1;
/* the line timer restarts */
            ht    <= 24'd0;
        end
    end
end

/* probe: {ID, status, frames, lines per frame, pixels per line, clocks per 64 lines, clocks per frame} */
altsource_probe #(
    .sld_auto_instance_index ("YES"), .sld_instance_index (0), .instance_id ("STAT"),
    .probe_width (127), .source_width (1), .source_initial_value ("0"), .enable_metastability ("NO")
) u_stat (.probe ({ID, status, frames, v_len, h_len, h_per, v_per}), .source ());

endmodule

/* other files keep the default net type */
`default_nettype wire
