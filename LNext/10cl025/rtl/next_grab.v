/* next_grab -- LNext: screenshots (Print Screen). The Next's picture is mixed from its layers */
/* as it goes to the monitor and is stored nowhere, so the ESP32 takes it line by line out of */
/* the video output's line buffer (next_video.v) while the CPU waits and the monitor shows a */
/* black picture. It uses the tape loader's memory commands, which next_sd.v passes on: */
/*   3 GRAB    wdata [15] on (CPU waits, black picture), [14] wait for a line, [9:0] its number */
/*             counted from the vertical sync; the line before is let go */
/*   4 STATE   rdata [31] the line is held, [30] it lies in the vertical blanking, */
/*             [29:20] lines of a frame, [19:10] the first pixel after the picture in a line, */
/*             [9:0] the picture's first pixel */
/*   1 MRD     addr [17] set: the held line's pixel addr[10:1]. Its colour is 9 bits, */
/*             {red, green, blue} of 3 bits each: addr[0] = 0 reads the colour's bits 7:0, */
/*             addr[0] = 1 reads its bit 8 in bit 0 */
/* Everything runs in the machine's 28 MHz clock; a command and its data stand until answered. */
`default_nettype none

module next_grab (
    input  wire        clk,
    input  wire        rst,

/* the memory command (next_sd.v answers it) */
    input  wire [3:0]  snap_cmd,
    input  wire [17:0] snap_addr,
    input  wire [15:0] snap_wdata,
/* the command is ours; our answer; one of ours that is not a read was taken */
    output wire        ext_sel,
    output wire [31:0] ext_rdata,
    input  wire        ext_stb,

/* to the video output (next_video.v) */
    output reg         g_on,
    output reg         g_req,
    output reg         g_arm,
    output reg  [9:0]  g_line,
    output wire [9:0]  g_x,
    input  wire [8:0]  g_q,
/* the line is held; it lies in the vertical blanking; the picture's place, the frame's lines */
    input  wire        g_held,
    input  wire        g_vbl,
    input  wire [9:0]  g_first,
    input  wire [9:0]  g_end,
    input  wire [9:0]  g_lines
);

/* the memory commands */
localparam [3:0] SNAP_MRD = 4'd1;
localparam [3:0] SNAP_GRAB = 4'd3;
localparam [3:0] SNAP_STATE = 4'd4;
/* a read's address: the grabber's pixels, the colour's top bit */
localparam integer A_GRAB = 17;
localparam integer A_TOP = 0;
/* GRAB: on, wait for a line */
localparam integer W_ON = 15;
localparam integer W_ARM = 14;
/* a colour's bits */
localparam integer RGB_TOP = 8;

/* which commands are ours */
wire is_rd = snap_cmd == SNAP_MRD && snap_addr[A_GRAB];
assign ext_sel = is_rd || snap_cmd == SNAP_GRAB || snap_cmd == SNAP_STATE;

/* the pixel asked for */
assign g_x = snap_addr[10:1];

/* the answers: a pixel's byte, the state (GRAB answers the state too) */
wire [7:0] px_byte = snap_addr[A_TOP] ? {7'd0, g_q[RGB_TOP]} : g_q[7:0];
assign ext_rdata = is_rd ? {24'd0, px_byte} : {g_held, g_vbl, g_lines, g_end, g_first};

always @(posedge clk)
    if (rst)
    begin
/* at reset: no screenshot */
        g_on   <= 1'b0;
        g_req  <= 1'b0;
        g_arm  <= 1'b0;
        g_line <= 10'd0;
    end
    else if (ext_stb && snap_cmd == SNAP_GRAB)
    begin
/* the ESP32's order; the change of g_req passes it to the buffer's write side */
        g_on   <= snap_wdata[W_ON];
        g_arm  <= snap_wdata[W_ARM];
        g_line <= snap_wdata[9:0];
        g_req  <= !g_req;
    end

endmodule

`default_nettype wire
