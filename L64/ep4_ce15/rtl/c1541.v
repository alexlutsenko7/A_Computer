/* c1541 -- Commodore 1541 disk drive (device 8) for L64 */
/* */
/* The drive's own computer, as on the 1541 logic board: 6502 (T65) at 1 MHz, */
/* 2 KB RAM ($0000-$07FF), 16 KB DOS ROM ($C000-$FFFF, mirrored at $8000), VIA1 $1800 */
/* (serial bus), VIA2 $1C00 (disk mechanics, GCR data); address decode as the */
/* board's 74LS42 on {A15, A12, A11, A10}. VIAs: iecdrv_via6522 (Gideon Zweijtzer, */
/* GPL-3). The disk surface: c1541_gcr (the current track made from the track buffer). */
/* */
/* Clock: clk = the C64's 31.510 MHz; the drive cycle (1.000 MHz) comes from a DDS: */
/* ph2_f = end of the cycle (CPU enable, VIA "falling"), ph2_r 16 clocks earlier (VIA */
/* "rising", RAM writes). Turbo (L64's F6 while loading): the DDS advances by 32 */
/* clocks' worth per C64 CPU cycle (c64_cyc) instead of per clock, so the drive (and its */
/* disk surface) keeps exactly the normal ratio of 1.0156 drive cycles per C64 cycle */
/* however fast the C64 runs; drive cycles are then at least 5 clocks apart, ph2_r 4 clocks */
/* after ph2_f. */
/* */
/* Serial bus (open collector, 1 = pulled low): the C64 drives atn / clk / data */
/* (CIA2 PA3-5, after the inverters), the drive clk / data; bus_* = the line levels. */
/* VIA1 PB: 0 DATA in, 1 DATA out, 2 CLK in, 3 CLK out, 4 ATN acknowledge, 5-6 device */
/* number (00 = 8), 7 ATN in; CA1 = ATN. The ATN acknowledge logic pulls DATA low while */
/* PB4 differs from ATN (the board's XOR gate). */
/* VIA2 PB: 0-1 stepper phase, 2 motor, 3 LED, 4 write protect (0 = protected), */
/* 5-6 density, 7 SYNC; PA = GCR byte; CA1 = byte ready (also the CPU's SO via CA2 = SOE), */
/* CB2 = read (1) / write (0). */
/* */
/* Memories (block RAM): RAM 2 KB; ROM 16 KB, written by rom_wr (the ROM loader, clk_sd */
/* domain); track buffer 8 KB = 21 sectors x 256, port A for the ESP32 (clk_sd), port B */
/* for the disk surface. */
`default_nettype none

module c1541 (
    input  wire        clk,
/* drive reset (C64 reset) */
    input  wire        rst,
    input  wire        turbo,
/* turbo: one pulse per C64 CPU cycle */
    input  wire        c64_cyc,

/* serial bus */
/* 1 = the C64 pulls ATN low */
    input  wire        c64_atn,
    input  wire        c64_clk,
    input  wire        c64_data,
/* line levels (1 = high) */
    output wire        bus_clk,
    output wire        bus_data,

/* disk (from the ESP32, quasi-static) */
/* a .d64 is inserted */
    input  wire        disk,
/* read only */
    input  wire        wprot,
/* the track in the track buffer */
    input  wire [5:0]  loaded,
    input  wire [7:0]  id1,
    input  wire [7:0]  id2,
/* the head position (1..35) */
    output wire [5:0]  track,
    output wire        motor,
    output wire        led,
    output wire [20:0] dirty,
/* one clock pulses (clk domain) */
    input  wire [20:0] dirty_clr,

/* ROM load and track buffer port A (clk_sd) */
    input  wire        clk_sd,
    input  wire        rom_wr,
    input  wire [13:0] rom_a,
    input  wire [7:0]  rom_d,
    input  wire        tb_we,
    input  wire [12:0] tb_a,
    input  wire [7:0]  tb_d,
    output reg  [7:0]  tb_q
);

/* one drive clock cycle in the DDS accumulator (2^32) */
localparam [33:0] DDS_ONE = 34'h100000000;
/* clocks from the falling to the rising edge of the drive clock, turbo */
localparam [4:0] HALF_TURBO = 5'd4;
/* clocks from the falling to the rising edge of the drive clock, normal speed */
localparam [4:0] HALF_NORMAL = 5'd16;
/* address decoder output of VIA 1 ($1800) */
localparam [3:0] SEL_VIA1 = 4'd6;
/* address decoder output of VIA 2 ($1C00) */
localparam [3:0] SEL_VIA2 = 4'd7;
/* head position after reset in half tracks: track 18 */
localparam [6:0] HTRACK_RESET = 7'd34;
/* last half track the head can reach */
localparam [6:0] HTRACK_MAX = 7'd83;
/* last track of a disk, in the half-track counter's width */
localparam [6:0] TRACK_MAX7 = 7'd35;
/* last track of a disk */
localparam [5:0] TRACK_MAX = 6'd35;

/* 1 MHz drive cycle */
/* dds counts in units of 2^-32 drive cycles; a cycle is due when it reaches 2^32 */
/* 1.000 / 31.510 * 2^32 per clock */
localparam [33:0] STEP   = 34'd136305484;
/* 32 x STEP per C64 cycle (turbo) */
localparam [33:0] STEP_T = 34'd4361775488;
reg  [33:0] dds;
reg         ph2_f, ph2_r;
/* clocks since the last falling edge */
reg  [4:0]  half;
/* turbo: >= 5 clocks apart */
wire        due   = dds[33:32] != 2'b00 && (!turbo || half == 5'd0);
wire [33:0] dds_a = dds + (turbo ? (c64_cyc ? STEP_T : 34'd0) : STEP);
always @(posedge clk or posedge rst)
/* at reset */
    if (rst)
    begin
        dds <= 34'd0;
        ph2_f <= 1'b0;
/* no rising edge */
        ph2_r <= 1'b0;
        half <= 5'd0;
    end
    else
    begin
        dds   <= due ? dds_a - DDS_ONE : dds_a;
/* the falling edge; the rising edge half a cycle later */
        ph2_f <= due;
        ph2_r <= half == 5'd1;
        if (due)
        begin
/* the half cycle is counted down */
            half <= turbo ? HALF_TURBO : HALF_NORMAL;
        end
        else if (half != 5'd0)
        begin
            half <= half - 5'd1;
        end
    end

/* CPU and address decode */
wire [23:0] cpu_a;
wire [7:0]  cpu_do;
wire        cpu_rw;
/* the CPU's data in; interrupts */
reg  [7:0]  cpu_di;
wire        via1_irq, via2_irq, soe;
wire        byte_n;

/* the address decoder (74LS42) */
wire [3:0] ls42   = {cpu_a[15], cpu_a[12:10]};
wire       ram_cs = ls42 == 4'd0 || ls42 == 4'd1;
wire       v1_cs  = ls42 == SEL_VIA1;
/* the second VIA; the ROM */
wire       v2_cs  = ls42 == SEL_VIA2;
wire       rom_cs = cpu_a[15];

T65 u_cpu (
    .Mode    (2'b00),
    .BCD_en  (1'b1),
    .Res_n   (!rst),
    .Enable  (ph2_f),
    .Clk     (clk),
    .Rdy     (1'b1),
    .Abort_n (1'b1),
    .IRQ_n   (!(via1_irq | via2_irq)),
    .NMI_n   (1'b1),
    .SO_n    (byte_n | !soe),
    .R_W_n   (cpu_rw),
    .Sync    (),
    .EF      (),
    .MF      (),
    .XF      (),
    .ML_n    (),
    .VP_n    (),
    .VDA     (),
    .VPA     (),
    .A       (cpu_a),
    .DI      (cpu_di),
    .DO      (cpu_do),
    .Regs    (),
    .DEBUG   (),
    .NMI_ack ()
);

/* 2 KB RAM, 16 KB ROM */
reg  [7:0] ram [0:2047];
reg  [7:0] rom [0:16383];
reg  [7:0] ram_q, rom_q;
/* a RAM write */
always @(posedge clk)
begin
    if (ph2_r && !cpu_rw && ram_cs)
    begin
        ram[cpu_a[10:0]] <= cpu_do;
    end
/* both read registered */
    ram_q <= ram[cpu_a[10:0]];
    rom_q <= rom[cpu_a[13:0]];
end
always @(posedge clk_sd)
/* the ROM is loaded from the SDRAM domain */
    if (rom_wr)
    begin
        rom[rom_a] <= rom_d;
    end

wire [7:0] v1_do, v2_do;
/* the CPU's data in */
always @*
begin
    if (ram_cs)
    begin
        cpu_di = ram_q;
    end
/* the first VIA */
    else if (v1_cs)
    begin
        cpu_di = v1_do;
    end
    else if (v2_cs)
    begin
/* the second VIA; the ROM */
        cpu_di = v2_do;
    end
    else if (rom_cs)
    begin
        cpu_di = rom_q;
    end
    else
    begin
/* open bus */
        cpu_di = 8'hFF;
    end
end

/* VIA1: serial bus */
wire [7:0] v1_pa_o, v1_pa_t, v1_pb_o, v1_pb_t;
wire       v1_ca2_o, v1_ca2_t, v1_cb1_o, v1_cb1_t, v1_cb2_o, v1_cb2_t;
/* outputs, inputs pulled up */
wire [7:0] v1_pb = v1_pb_o | ~v1_pb_t;
wire       atn_low = c64_atn;
wire       drv_data = v1_pb[1] | (v1_pb[4] ^ atn_low);
/* the bus lines: wired AND of the C64's and the drive's outputs */
wire       drv_clk  = v1_pb[3];
assign bus_clk  = !(c64_clk  | drv_clk);
assign bus_data = !(c64_data | drv_data);

/* the first VIA */
iecdrv_via6522 u_via1 (
    .clock    (clk),
    .rising   (ph2_r),
    .falling  (ph2_f),
    .reset    (rst),
    .addr     (cpu_a[3:0]),
    .wen      (!cpu_rw && v1_cs),
    .ren      (cpu_rw && v1_cs),
    .data_in  (cpu_do),
    .data_out (v1_do),
    .phi2_ref (),
    .port_a_o (v1_pa_o),
    .port_a_t (v1_pa_t),
    .port_a_i (v1_pa_o | ~v1_pa_t),
    .port_b_o (v1_pb_o),
    .port_b_t (v1_pb_t),
/* 7 ATN, 6:5 device 8, 2 CLK, 0 DATA */
    .port_b_i ({atn_low, 2'b00, 1'b1, 1'b1, !bus_clk, 1'b1, !bus_data} & v1_pb),
    .ca1_i    (atn_low),
    .ca2_o    (v1_ca2_o),
    .ca2_i    (v1_ca2_o | !v1_ca2_t),
    .ca2_t    (v1_ca2_t),
    .cb1_o    (v1_cb1_o),
    .cb1_i    (v1_cb1_o | !v1_cb1_t),
    .cb1_t    (v1_cb1_t),
    .cb2_o    (v1_cb2_o),
    .cb2_i    (v1_cb2_o | !v1_cb2_t),
    .cb2_t    (v1_cb2_t),
    .irq      (via1_irq)
);

/* VIA2: disk mechanics and data */
wire [7:0] v2_pa_o, v2_pa_t, v2_pb_o, v2_pb_t;
wire       v2_ca2_o, v2_ca2_t, v2_cb1_o, v2_cb1_t, v2_cb2_o, v2_cb2_t;
wire [7:0] v2_pb = v2_pb_o | ~v2_pb_t;
/* port A as the pins show it */
wire [7:0] v2_pa = v2_pa_o | ~v2_pa_t;
wire       sync_n;
wire [7:0] gcr_byte;
/* byte ready enable, read / write mode, motor */
assign soe   = v2_ca2_o | !v2_ca2_t;
wire   rmode = v2_cb2_o | !v2_cb2_t;
assign motor = v2_pb[2];
/* the LED; the second VIA */
assign led   = v2_pb[3];

iecdrv_via6522 u_via2 (
    .clock    (clk),
    .rising   (ph2_r),
    .falling  (ph2_f),
    .reset    (rst),
    .addr     (cpu_a[3:0]),
    .wen      (!cpu_rw && v2_cs),
    .ren      (cpu_rw && v2_cs),
    .data_in  (cpu_do),
    .data_out (v2_do),
    .phi2_ref (),
    .port_a_o (v2_pa_o),
    .port_a_t (v2_pa_t),
    .port_a_i (gcr_byte & v2_pa),
    .port_b_o (v2_pb_o),
    .port_b_t (v2_pb_t),
    .port_b_i ({sync_n, 2'b11, !(wprot && disk), 4'b1111} & v2_pb),
    .ca1_i    (byte_n | !soe),
    .ca2_o    (v2_ca2_o),
    .ca2_i    (soe),
    .ca2_t    (v2_ca2_t),
    .cb1_o    (v2_cb1_o),
    .cb1_i    (v2_cb1_o | !v2_cb1_t),
    .cb1_t    (v2_cb1_t),
    .cb2_o    (v2_cb2_o),
    .cb2_i    (rmode),
    .cb2_t    (v2_cb2_t),
    .irq      (via2_irq)
);

/* Head stepper: phases 0-1-2-3 forward = one half track each; 35 tracks = half */
/* tracks 0..68 (track = half / 2 + 1); starts on track 18 */
reg [6:0] htrack;
reg [1:0] phase_p;
/* the first phase after a reset is where the head already is */
reg       phase_ok;
always @(posedge clk or posedge rst)
    if (rst)
    begin
/* at reset: track 18 */
        htrack   <= HTRACK_RESET;
        phase_p  <= 2'd0;
        phase_ok <= 1'b0;
    end
/* the stepper's phase as seen last */
    else if (ph2_f)
    begin
        phase_p  <= v2_pb[1:0];
        phase_ok <= 1'b1;
/* one phase up: a half track in */
        if (phase_ok && motor)
        begin
            if (v2_pb[1:0] == phase_p + 2'd1 && htrack < HTRACK_MAX)
            begin
                htrack <= htrack + 7'd1;
            end
/* one phase down: a half track out */
            else if (v2_pb[1:0] == phase_p - 2'd1 && htrack != 7'd0)
            begin
                htrack <= htrack - 7'd1;
            end
        end
    end
wire [6:0] tr7 = {1'b0, htrack[6:1]} + 7'd1;
/* tracks above 35 read as 35 */
assign track = tr7 > TRACK_MAX7 ? TRACK_MAX : tr7[5:0];

/* Track buffer (8 KB) and the disk surface */
reg  [7:0]  tbuf [0:8191];
reg  [7:0]  tb_qb;
wire [12:0] g_a, g_wa;
/* the GCR side's port */
wire        g_we;
wire [7:0]  g_d;
always @(posedge clk_sd)
begin
/* the loader's port */
    if (tb_we)
    begin
        tbuf[tb_a] <= tb_d;
    end
    tb_q <= tbuf[tb_a];
end
/* one address per port (true dual port block RAM) */
wire [12:0] g_pa = g_we ? g_wa : g_a;
always @(posedge clk)
begin
    if (g_we)
    begin
/* the drive's port */
        tbuf[g_pa] <= g_d;
    end
    tb_qb <= tbuf[g_pa];
end

c1541_gcr u_gcr (
    .clk       (clk),
    .rst       (rst),
    .ce        (ph2_f),
    .valid     (disk && loaded == track && htrack[0] == 1'b0),
    .track     (track),
    .id1       (id1),
    .id2       (id2),
    .density   (v2_pb[6:5]),
    .motor     (motor),
    .mode      (rmode),
    .din       (v2_pa),
    .sync_n    (sync_n),
    .byte_n    (byte_n),
    .dout      (gcr_byte),
    .buf_a     (g_a),
    .buf_q     (tb_qb),
    .buf_wa    (g_wa),
    .buf_we    (g_we),
    .buf_d     (g_d),
    .dirty     (dirty),
    .dirty_clr (dirty_clr)
);

endmodule

/* other files keep the default net type */
`default_nettype wire
