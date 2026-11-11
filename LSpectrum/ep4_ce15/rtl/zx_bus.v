/* zx_bus -- ZX Spectrum 128 CPU side: clock enable, bus bridge to the SDRAM, */
/* memory paging, I/O ports, interrupt */
/* */
/* Clock enable (CEN) for the T80, from a 32-bit phase accumulator at 112 MHz: */
/* normal 3.5469 MHz (31-32 clocks per T-state), turbo exactly 28 MHz (every */
/* 4 clocks). CEN pulses are never closer than 4 clocks (the T80 multicycle). */
/* A tick that cannot be given (stall) is owed and given as soon as possible. */
/* */
/* Bus bridge, per M-cycle (see docs/T80_CEN_ANALYSIS.md): */
/* T1, 1st clock after CEN: latch the address and start a speculative SDRAM */
/* read (A is a T80 register output, so this is a normal 1-clock path). */
/* T1, 2nd clock: sample the cycle decode (IORQ/Write; combinational in the */
/* T80 -> 2-clock multicycle into the smp_* registers). */
/* T2, 2nd clock: sample Write/IORQ/DO; 3rd clock: post the memory write */
/* (+ screen shadow write) or perform the I/O write. */
/* The CEN that ends T2 (where the T80 takes the data) is held until the */
/* read of this M-cycle has completed. Only in turbo can that happen. */
/* Writes are posted (the CPU never waits for them); the next read waits for */
/* the SDRAM to finish them first, so a read always sees earlier writes. */
/* */
/* Memory map (SDRAM byte address, 18 bits): */
/* 0x00000-0x1FFFF  RAM pages 0-7 (page n at n * 0x4000) */
/* 0x20000/0x24000  ROM 0 (128K editor) / ROM 1 (48K BASIC), 7FFD bit 4 */
/* 0x28000          DiagROM (both ROM slots) when selected at reset */
/* CPU 0000-3FFF ROM (writes ignored), 4000 page 5, 8000 page 2, C000 7FFD[2:0] */
/* */
/* I/O (partial decoding as on the real 128): */
/* write A0=0          port FE: border [2:0], MIC [3] (to the tape loader's recorder), beeper [4] */
/* write A15=0, A1=0   port 7FFD: RAM page [2:0], screen [3], ROM [4], lock [5] */
/* write A15=1 A14=1 A1=0  AY register select (FFFD); A15=1 A14=0 A1=0  AY data (BFFD) */
/* read  A0=0          keyboard (A8-A15 select rows), EAR on bit 6, bits 5/7 = 1 */
/* EAR = SD tape loader while it plays (ltape_on), else the beeper */
/* read  FFFD          AY register */
/* read  A0=1 A5=0     Kempston joystick (port 1F) */
/* other reads         floating bus (see below), 0xFF in turbo or with contention off */
/* */
/* Interrupt: 32 T-states long. Source: the video's frame mark in 50 Hz video mode */
/* (a real 50.017 Hz frame, placed as on a 128K: zx_video INT_LINE / INT_PX), otherwise a counter of 70908 T-states (128K frame), which */
/* also follows turbo (as in the DE10-Lite reference). */
/* */
/* Memory contention (Level 1, 128K timing; off in turbo or when cont_en = 0): */
/* A frame T-state counter restarts at each interrupt and counts real T-states: */
/* CPU T-states and those lost to contention (cen_raw), not those of a hold or a */
/* snapshot freeze. Contended: T-states 14361 + 228 * line + p, line 0..191, p 0..127, */
/* delay 6,5,4,3,2,1,0,0 for p mod 8 (hpos/vline below: hpos = (t + 3) mod 228, */
/* vline = (t + 3) / 228, contended lines 63..254, hpos < 128). */
/* Memory: at T1 of a memory read / write / opcode fetch to 4000-7FFF, or to */
/* C000-FFFF while an odd RAM page (1, 3, 5, 7) is paged in. I/O: high byte */
/* 40-7F and A0 = 0: C:1, C:3; high byte 40-7F, A0 = 1: C:1 x 4; A0 = 0 only: N:1, */
/* C:3 (checked at the T-states 0, 1, 2, 3 of the cycle). The CPU's cen is withheld */
/* for the delay; those ticks are not owed (they are lost, as on the real machine). */
/* Not done (Level 2): the extra internal T-states some instructions put an address */
/* on the bus for (e.g. INC HL, PUSH, JR), refresh. */
/* */
/* Floating bus (128K timing, on with contention): an I/O read of a port nothing */
/* answers (A0 = 1, not the AY at FFFD, A5 = 1 - e.g. port FF) returns the byte the */
/* ULA fetches at the start of the 4th T-state of the I/O cycle, after all of its */
/* contention (Fuse 1.6 readport: early C:1 + 1 T, late C:1,+1,C:1,+1,C:1 for a */
/* contended high byte, else 2 T): with x = T-state - 14362 - 228 * row (row 0..191, */
/* x 0..127), x mod 8 = 2 bitmap, 3 attribute, 4 bitmap + 1, 5 attribute + 1 of */
/* column 2 * (x / 8); otherwise FF. A contended poll (high byte 40-7F) thus sees */
/* only attributes or FF - games that sync on an attribute (Sidewize) rely on it. */
/* The bridge decides at the start of T2 (hpos then, plus the late contention it */
/* will get) and reads the byte from SDRAM (displayed page 5 / 7) before the CPU */
/* takes it at the end of the wait state. (2026-10-11: was the byte at T2, tl = */
/* T - 14364: half of the contended polls saw a bitmap byte, Sidewize synced early */
/* and its player flickered.) */
/* */
/* Snapshots (.z80 save/load by the ESP32 loader firmware, ESP32/v2/src/snap.c): */
/* snap_freeze stops the CPU at the next instruction boundary: in T2 of an */
/* opcode fetch (M1) that is not an interrupt acknowledge and does not follow a */
/* prefix (CB/ED/DD/FD). There the T80 has written back the previous */
/* instruction and has not yet taken the opcode or incremented PC/R, so its */
/* registers (REG) are the state between two instructions with PC = the next */
/* instruction (in HALT: PC = HALT + 1, the firmware saves PC - 1). */
/* snap_frozen = stopped there and the bridge idle. While frozen, commands */
/* (snap_cmd/addr/wdata stable, snap_req toggled; snap_ack toggles when done, */
/* result in snap_rdata): */
/* 1 MRD   SDRAM byte at addr                      -> rdata[7:0] */
/* 2 MWR   SDRAM byte at addr <= wdata[7:0] (and the screen shadow) */
/* 3 REG   CPU register word addr[2:0] (cpu_t80 layout, 7 x 32 bits) */
/* 4 DIR   register word addr[2:0] <= wdata, for LOAD */
/* 5 LOAD  reset the T80 alone and load all registers from the DIR words */
/* 6 AYRD  AY register addr[3:0]                   -> rdata[7:0] */
/* 7 AYWR  AY register addr[3:0] <= wdata[7:0] */
/* 8 AYSEL AY register select <= wdata[7:0] (as an OUT to FFFD) */
/* 9 PORT  7FFD <= wdata[7:0] (ignores the lock), border/MIC/beeper <= wdata[10:8]/[11]/[12] */
/* 10 STATE rdata = {halt [24], AY select [23:16], beeper [12], MIC [11], border [10:8], 7FFD [7:0]} */
/* AYRD / AYWR change the AY's register select; AYSEL restores it. Leaving the */
/* freeze repeats the opcode read of the frozen M1 (SDRAM reads changed the */
/* data bus), except after LOAD (the T80 starts a new M1 from its reset state). */
`default_nettype none

module zx_bus #(
/* 3.5469 MHz at 112 MHz */
    parameter [31:0] INC_NORMAL   = 32'd136016246,
/* 28 MHz = every 4 clocks */
    parameter [31:0] INC_TURBO    = 32'd1073741824,
/* T-states per 128K frame */
    parameter integer FRAME_T     = 70908
)(
/* 112 MHz */
    input  wire        clk,
/* system reset (CPU and ports) */
    input  wire        rst_n,
/* ROMs loaded: CPU may run */
    input  wire        run,

    input  wire        turbo,
/* F1 held: DiagROM if held when the CPU starts */
    input  wire        diag_key,
/* video in 50 Hz mode (other clock domain) */
    input  wire        vid50,
/* video frame interrupt mark, falling edge (other clock domain) */
    input  wire        vsync_n,
/* 8 rows x 5 keys, active low, row i = A(8+i) */
    input  wire [39:0] kb_rows,
/* Kempston: fire, up, down, left, right (active high) */
    input  wire [4:0]  joy,
/* SD tape loader drives EAR (56 MHz domain) */
    input  wire        ltape_on,
    input  wire        ltape_lvl,
/* toggles on every T-state (incl. contention; for the tape loader) */
    output reg         cen_tgl,
/* tape loader: pause the CPU (56 MHz domain); T-states stop */
    input  wire        hold,
/* port FE bit 3 */
    output reg         mic,

/* SDRAM port (sdram_ram protocol: req pulse, hold until ack) */
    output reg         sd_req,
    output reg         sd_we,
    output reg  [17:0] sd_addr,
    output reg  [7:0]  sd_din,
    input  wire [7:0]  sd_dout,
    input  wire        sd_ack,

/* screen shadow write (pages 5 and 7, first 6912 bytes) */
    output reg         sh_we,
    output reg         sh_page7,
    output reg  [12:0] sh_addr,
    output reg  [7:0]  sh_data,

/* AY-3-8912 bus (jt49_bus) */
    output reg         ay_bdir,
    output reg         ay_bc1,
    output reg  [7:0]  ay_din,
    input  wire [7:0]  ay_dout,

    output reg  [2:0]  border,
/* 7FFD bit 3 */
    output wire        screen7,
    output reg         beeper,
    output reg         diag_rom,
    output wire        cpu_running,

/* snapshot port (tape loader, 56 MHz from the same PLL, edges aligned; see above) */
/* level */
    input  wire        snap_freeze,
/* toggles: execute snap_cmd */
    input  wire        snap_req,
    input  wire [3:0]  snap_cmd,
    input  wire [17:0] snap_addr,
    input  wire [31:0] snap_wdata,
    output reg         snap_frozen,
/* toggles when a command is done */
    output reg         snap_ack,
    output reg  [31:0] snap_rdata,

/* memory contention on (tape loader clock domain) */
    input  wire        cont_en
);

/* T-state 2 of a machine cycle */
localparam [2:0] TS_T2 = 3'd2;
/* first frame line of the picture */
localparam [8:0] SCR_LINE0 = 9'd63;
/* first frame line after the picture (63 + 192) */
localparam [8:0] SCR_LINE_END = 9'd255;
/* floating bus: T-states from T2 to the read point, uncontended */
localparam [7:0] FB_AHEAD = 8'd2;
/* first frame line of the picture, 8 bits */
localparam [7:0] SCR_ROW0 = 8'd63;
/* floating bus: read points 1..128 of a line see screen bytes */
localparam [7:0] FB_X_END = 8'd129;
/* floating bus: first fetch slot of the 8 T-state cell */
localparam [2:0] FB_FETCH_FIRST = 3'd2;
/* floating bus: last fetch slot of the cell */
localparam [2:0] FB_FETCH_LAST = 3'd5;
/* RAM page 2 (at 8000); with the ROM bit: the DiagROM's slot */
localparam [2:0] PAGE_2 = 3'd2;
/* RAM page 5: the normal screen (at 4000) */
localparam [2:0] PAGE_5 = 3'd5;
/* bytes of a screen: 6144 bitmap + 768 attributes */
localparam [13:0] SCREEN_BYTES = 14'd6912;
/* snapshot command: memory write (C_MWR of the command list further down) */
localparam [3:0] SNAP_MWR = 4'd2;
/* rows of the keyboard matrix */
localparam integer KB_ROWS = 8;
/* prefix byte DD */
localparam [7:0] OP_IX = 8'hDD;
/* prefix byte FD */
localparam [7:0] OP_IY = 8'hFD;
/* prefix byte ED */
localparam [7:0] OP_ED = 8'hED;
/* prefix byte CB */
localparam [7:0] OP_CB = 8'hCB;
/* LOAD: the step at which the registers are set */
localparam [2:0] LOAD_DIRSET = 3'd3;
/* LOAD: the last step */
localparam [2:0] LOAD_DONE = 3'd5;
/* AY access: the step of the write strobe */
localparam [2:0] AY_STROBE = 3'd2;
/* AY access: the step at which the data is taken */
localparam [2:0] AY_DONE = 3'd6;
/* the interrupt lasts 32 T-states */
localparam [5:0] INT_LAST = 6'd31;
/* T-states of a line that fetch screen bytes */
localparam [7:0] SCR_TSTATES = 8'd128;
/* contention: the longest delay, 6 T-states */
localparam [2:0] CONT_MAX = 3'd6;
/* line position after a reset (the CPU's first T-state lands on the measured phase) */
localparam [7:0] HPOS_RESET = 8'd3;
/* last T-state of a line (228 per line) */
localparam [7:0] HPOS_LAST = 8'd227;

/* Synchronisers */
reg [2:0] turbo_s, vid50_s, vsync_s, diag_s;
reg [1:0] lon_s, llvl_s, hold_s, sfrz_s, cont_s;
reg [2:0] sreq_s;
/* two or three stages each */
always @(posedge clk)
begin
    hold_s  <= {hold_s[0], hold};
    sfrz_s  <= {sfrz_s[0], snap_freeze};
/* contention switch, snapshot request, tape on */
    cont_s  <= {cont_s[0], cont_en};
    sreq_s  <= {sreq_s[1:0], snap_req};
    lon_s   <= {lon_s[0],  ltape_on};
/* tape level, turbo, 50 Hz mode */
    llvl_s  <= {llvl_s[0], ltape_lvl};
    turbo_s <= {turbo_s[1:0], turbo};
    vid50_s <= {vid50_s[1:0], vid50};
/* vsync, the DiagROM key */
    vsync_s <= {vsync_s[1:0], vsync_n};
    diag_s  <= {diag_s[1:0],  diag_key};
end

/* the CPU runs once the ROM is loaded */
wire cpu_rst_n = rst_n & run;
assign cpu_running = cpu_rst_n;

/* DiagROM select: follows F1 while the CPU is held in reset, frozen when it starts */
always @(posedge clk or negedge rst_n)
    if (!rst_n)
    begin
        diag_rom <= 1'b0;
    end
/* while the CPU waits */
    else if (!run)
    begin
        diag_rom <= diag_s[2];
    end

/* CPU */
wire        cen;
reg         int_n;
wire [7:0]  cpu_din;
/* address, data out, machine cycle and T-state */
wire [15:0] cpu_a;
wire [7:0]  cpu_do;
wire [2:0]  cpu_mc, cpu_ts;
/* the control lines sampled by the bridge; all registers for snapshots */
wire        cpu_iorq, cpu_noread, cpu_write, cpu_m1_n, cpu_intcycle_n, cpu_halt_n;
wire [211:0] cpu_regs;
/* registers for LOAD (7 words) */
reg  [223:0] dir_q;
reg         t80_rst, dirset;
wire        t80_rst_n = cpu_rst_n & !t80_rst;

/* the T80 */
cpu_t80 u_cpu (
    .clk        (clk),
    .rst_n      (t80_rst_n),
    .cen        (cen),
    .int_n      (int_n),
    .nmi_n      (1'b1),
    .din        (cpu_din),
    .a          (cpu_a),
    .dout       (cpu_do),
    .mc         (cpu_mc),
    .ts         (cpu_ts),
    .iorq       (cpu_iorq),
    .noread     (cpu_noread),
    .write      (cpu_write),
    .m1_n       (cpu_m1_n),
    .intcycle_n (cpu_intcycle_n),
    .halt_n     (cpu_halt_n),
    .regs       (cpu_regs),
    .dirset     (dirset),
    .dir        (dir_q[211:0])
);

/* Clock enable: phase accumulator + stall */
reg  [31:0] dds;
reg         tick, owed, cen_d;
/* clocks since the last cen (0 = the clock after it), saturating at 3 */
reg  [1:0]  since;
wire [32:0] dds_next = {1'b0, dds} + {1'b0, (turbo_s[2] ? INC_TURBO : INC_NORMAL)};
wire        stall;
/* snapshot freeze: CPU stopped at an instruction boundary */
reg         frz_q;
/* contention: T-states still to withhold */
reg  [2:0]  cont_cnt;
/* (t + 3) mod 228: 0 = first contended T-state of a line */
reg  [7:0]  hpos;
/* (t + 3) / 228: lines 63..254 are contended */
reg  [8:0]  vline;
/* clocks since the cen that started a CPU T-state */
reg  [2:0]  chk;
/* T-states since the start of this M-cycle */
reg  [2:0]  io_k;
/* floating bus: SDRAM read wanted / byte in fb_data */
reg         fb_pend, fb_valid;
reg  [17:0] fb_addr;
reg  [7:0]  fb_data;

/* cen_raw: a T-state passes (frame time); cen: the CPU takes it (not lost to contention) */
wire cen_raw = (tick | owed) & (since == 2'd3) & !stall & !hold_s[1] & !frz_q & cpu_rst_n;
assign cen = cen_raw & (cont_cnt == 3'd0);

always @(posedge clk or negedge cpu_rst_n)
/* reset */
    if (!cpu_rst_n)
    begin
        dds   <= 32'd0;
        tick  <= 1'b0;
/* nothing owed; an enable may come at once */
        owed  <= 1'b0;
        since <= 2'd3;
        cen_d <= 1'b0;
/* the tape loader's T-state toggle */
        cen_tgl <= 1'b0;
    end
    else
    begin
/* real T-states: the tape keeps time through contention */
        if (cen_raw)
        begin
            cen_tgl <= !cen_tgl;
        end
        dds   <= dds_next[31:0];
/* the accumulator's carry is a T-state; one that could not be given is owed */
        tick  <= dds_next[32];
        owed  <= (tick | owed) & !cen_raw;
/* at least 4 clocks between enables */
        since <= cen_raw ? 2'd0 : (since == 2'd3 ? 2'd3 : since + 2'd1);
        cen_d <= cen;
    end

/* M-cycle tracking */
/* TS before the last cen */
reg  [2:0] ts_prev;
always @(posedge clk or negedge cpu_rst_n)
    if (!cpu_rst_n)
    begin
/* kept at every enable */
        ts_prev <= 3'd0;
    end
    else if (cen)
    begin
        ts_prev <= cpu_ts;
    end

/* first clock of T1 */
wire mstart = cen_d && cpu_ts == 3'd1 && ts_prev != 3'd1;
/* first clock of T2 */
wire t2_1st = cen_d && cpu_ts == TS_T2 && ts_prev != TS_T2;

/* address of this M-cycle */
reg  [15:0] a_lat;
/* interrupt acknowledge M1 */
reg         inta;
/* I/O cycle      (sampled 2 clocks after the T1 cen) */
reg         smp_io;
/* memory access (read or write) in this M-cycle (same) */
reg         smp_nr;
/* write in this M-cycle (same; for the floating bus) */
reg         smp_iow;
/* 2nd clock of T1 / T2, 3rd clock of T2 (single-clock paths) */
reg         t1_2nd, t2_2nd, t2_3rd;
/* Write/IORQ     (sampled 2 clocks after the T2 cen) */
reg         smp_wr2, smp_io2;
/* data out       (sampled 2 clocks after the T2 cen) */
reg  [7:0]  smp_do;

/* Paging and memory map */
reg  [7:0]  p7ffd;
assign screen7 = p7ffd[3];

/* floating bus (see the header): which byte the ULA fetches now */
/* as contention (F5, not in turbo) */
wire        fb_on   = cont_s[1] & !turbo_s[2];
/* nothing answers */
wire        fb_port = a_lat[0] && a_lat[5] && !(a_lat[15] && a_lat[14] && !a_lat[1]);
/* hpos at Fuse's read point, from hpos at the start of T2: the late contention steps */
/* (delay, +1 per T-state). Two pipeline stages, sampled at chk[1] (hpos changes at a */
/* cen_raw, the next one comes >= 4 clocks later). h + its delay: in a contended line */
/* and h < 128, phases 0..5 wait for phase 6 (low bits 110), 6 and 7 do not wait. */
function [7:0] fb_c(input [7:0] h, input scrl);
    fb_c = (scrl && !h[7] && !(h[2] && h[1])) ? {h[7:3], 3'b110} : h;
endfunction
wire        fb_scrl = vline >= SCR_LINE0 && vline < SCR_LINE_END;
/* contended high byte (as io_c) */
wire        fb_hic  = a_lat[15:14] == 2'b01;
/* fb_hrd: hpos when the port is read (> 227: past the line, FF) */
reg  [7:0]  fb_h1, fb_hrd;
always @(posedge clk)
begin
    fb_h1  <= fb_hic ? fb_c(hpos, fb_scrl) + 8'd1 : hpos + FB_AHEAD;
/* one more step ahead */
    fb_hrd <= fb_hic ? fb_c(fb_c(fb_h1, fb_scrl) + 8'd1, fb_scrl) : fb_h1;
end
/* x = T-state - 14362 - 228 * row (hpos 0 = 14361) */
wire [7:0]  fb_x    = fb_hrd - 8'd1;
wire [7:0]  fb_row  = vline[7:0] - SCR_ROW0;
wire        fb_scr  = fb_scrl && fb_hrd >= 8'd1 && fb_hrd < FB_X_END && fb_x[2:0] >= FB_FETCH_FIRST && fb_x[2:0] <= FB_FETCH_LAST;
/* 3, 5: attribute; 2, 4: bitmap */
wire        fb_attr = fb_x[0];
/* 2 * (x / 8) (+1 for 4, 5) */
wire [4:0]  fb_col  = {fb_x[6:3], fb_x[2]};

function [17:0] map_addr(input [15:0] a, input [7:0] pg, input diag);
    case (a[15:14])
/* ROM (or the DiagROM), page 5, page 2 */
        2'd0: map_addr = {1'b1, (diag ? PAGE_2 : {2'b00, pg[4]}), a[13:0]};
        2'd1: map_addr = {1'b0, PAGE_5,    a[13:0]};
        2'd2: map_addr = {1'b0, PAGE_2,    a[13:0]};
/* the page selected by 7FFD */
        default: map_addr = {1'b0, pg[2:0], a[13:0]};
    endcase
endfunction

/* SDRAM access: speculative read per M-cycle, posted writes */
/* wb_valid = a posted write waiting to be issued (cleared when it is issued; */
/* it can never be refilled before that, because each M-cycle waits for its */
/* own read, which is issued after any earlier write). */
reg         rd_pend, rd_done, op_busy, op_we;
reg         wb_valid;
reg         op_snap, smem_req, smem_done, loaded;
/* the access is the floating bus read */
reg         op_fb;
/* last clock of a freeze */
wire        unfreeze = frz_q & !sfrz_s[1];
wire [17:0] sa = snap_addr;
reg  [17:0] wb_addr, rd_addr;
/* the posted write's data; the read is done; T2 waits for it */
reg  [7:0]  wb_data;

wire rd_ok = rd_done | (op_busy & !op_we & sd_ack);
assign stall = (cpu_ts == TS_T2) & !rd_ok;

/* Data to the CPU: interrupt vector bus = FF, I/O data, or memory */
reg  [7:0] io_data;
assign cpu_din = inta ? 8'hFF : smp_io ? io_data : sd_dout;

always @(posedge clk or negedge cpu_rst_n)
/* reset */
    if (!cpu_rst_n)
    begin
        a_lat    <= 16'd0;
        inta     <= 1'b0;
/* cycle decode */
        smp_io   <= 1'b0;
        smp_nr   <= 1'b0;
        smp_iow  <= 1'b0;
/* floating bus */
        fb_pend  <= 1'b0;
        fb_valid <= 1'b0;
        fb_addr  <= 18'd0;
/* no byte */
        fb_data  <= 8'hFF;
        op_fb    <= 1'b0;
        t1_2nd   <= 1'b0;
/* T-state phases; the decode at T2 */
        t2_2nd   <= 1'b0;
        t2_3rd   <= 1'b0;
        smp_wr2  <= 1'b0;
/* I/O, the data out; no read pending */
        smp_io2  <= 1'b0;
        smp_do   <= 8'd0;
        rd_pend  <= 1'b0;
/* nothing read; no access */
        rd_done  <= 1'b0;
        rd_addr  <= 18'd0;
        op_busy  <= 1'b0;
/* no posted write */
        op_we    <= 1'b0;
        wb_valid <= 1'b0;
        wb_addr  <= 18'd0;
/* no snapshot access */
        wb_data  <= 8'd0;
        op_snap  <= 1'b0;
        smem_done <= 1'b0;
/* the SDRAM port */
        sd_req   <= 1'b0;
        sd_we    <= 1'b0;
        sd_addr  <= 18'd0;
/* the screen shadows' write port */
        sd_din   <= 8'd0;
        sh_we    <= 1'b0;
        sh_page7 <= 1'b0;
/* strobes last one clock */
        sh_addr  <= 13'd0;
        sh_data  <= 8'd0;
    end
    else
    begin
        sd_req <= 1'b0;
/* shadow write, snapshot done */
        sh_we  <= 1'b0;
        smem_done <= 1'b0;

/* T1: latch address, start the speculative read */
        t1_2nd <= mstart;
        t2_2nd <= t2_1st;
        if (mstart)
        begin
/* the address; an interrupt acknowledge; the SDRAM address */
            a_lat   <= cpu_a;
            inta    <= !cpu_intcycle_n && cpu_mc == 3'd1;
            rd_addr <= map_addr(cpu_a, p7ffd, diag_rom);
/* a read is wanted; not an I/O cycle yet */
            rd_pend <= 1'b1;
            rd_done <= 1'b0;
            smp_io  <= 1'b0;
        end
/* one clock later: the cycle's kind */
        if (t1_2nd)
        begin
            smp_io <= cpu_iorq;
            smp_nr <= !cpu_noread | cpu_write;
/* an I/O write */
            smp_iow <= cpu_write;
        end

/* floating bus: at the 2nd T-state of an I/O read of an unanswered port, fetch the byte */
/* the ULA has at the read point (fb_hrd, see the header) */
        if (mstart)
        begin
            fb_pend  <= 1'b0;
            fb_valid <= 1'b0;
        end
/* a read of the ULA's port: which screen byte the ULA would fetch then */
        else if (chk[1] && io_k == 3'd1 && smp_io && !smp_iow && !inta && fb_on && fb_port)
        begin
            fb_pend <= fb_scr;
            fb_addr <= {1'b0, (p7ffd[3] ? 3'd7 : PAGE_5),
                        fb_attr ? {4'b0110, fb_row[7:3], fb_col} : {1'b0, fb_row[7:6], fb_row[2:0], fb_row[5:3], fb_col}};
        end
/* T2, second clock: write or I/O, the data */
        if (t2_2nd)
        begin
            smp_wr2 <= cpu_write;
            smp_io2 <= cpu_iorq;
/* the data out; one more clock */
            smp_do  <= cpu_do;
        end
        t2_3rd <= t2_2nd;

/* T2: post the memory write (I/O writes: see the port block) */
        if (t2_3rd && smp_wr2 && !smp_io2)
        begin
/* ROM is write-protected */
            if (a_lat[15:14] != 2'd0)
            begin
                wb_valid <= 1'b1;
                wb_addr  <= map_addr(a_lat, p7ffd, diag_rom);
/* the data; a write into a screen goes to the shadow too */
                wb_data  <= smp_do;
            end
            if ((a_lat[15:14] == 2'd1 || (a_lat[15:14] == 2'd3 && (p7ffd[2:0] == PAGE_5 || p7ffd[2:0] == 3'd7)))
                && a_lat[13:0] < SCREEN_BYTES)
            begin
                sh_we    <= 1'b1;
/* page 7 or 5, the address in it, the data */
                sh_page7 <= a_lat[15:14] == 2'd3 && p7ffd[2:0] == 3'd7;
                sh_addr  <= a_lat[12:0];
                sh_data  <= smp_do;
            end
        end

/* leaving a snapshot freeze: read the opcode of the frozen M1 again (rd_done */
/* falls in the clock frz_q does, so the CEN ending T2 waits for the new read) */
        if (unfreeze && !loaded)
        begin
            rd_pend <= 1'b1;
            rd_done <= 1'b0;
        end

/* SDRAM port: one access at a time, posted write first */
        if (op_busy)
        begin
            if (sd_ack)
            begin
                op_busy <= 1'b0;
/* what kind it was */
                op_snap <= 1'b0;
                op_fb   <= 1'b0;
                if (op_snap)
                begin
/* a snapshot access is done; a floating bus byte */
                    smem_done <= 1'b1;
                end
                else if (op_fb)
                begin
                    fb_data <= sd_dout;
/* valid; a CPU read is done */
                    fb_valid <= 1'b1;
                end
                else if (!op_we)
                begin
                    rd_done   <= 1'b1;
                end
            end
        end
/* a posted write goes first */
        else if (wb_valid)
        begin
            wb_valid <= 1'b0;
            op_busy <= 1'b1;
/* a write request */
            op_we   <= 1'b1;
            sd_req  <= 1'b1;
            sd_we   <= 1'b1;
/* address and data */
            sd_addr <= wb_addr;
            sd_din  <= wb_data;
/* snapshot access (CPU frozen) */
        end
        else if (smem_req && !smem_done && snap_frozen)
        begin
            op_busy <= 1'b1;
            op_snap <= 1'b1;
/* write or read */
            op_we   <= snap_cmd == SNAP_MWR;
            sd_req  <= 1'b1;
            sd_we   <= snap_cmd == SNAP_MWR;
/* address and data */
            sd_addr <= sa;
            sd_din  <= snap_wdata[7:0];
            if (snap_cmd == SNAP_MWR && sa[17] == 1'b0 && (sa[16:14] == PAGE_5 || sa[16:14] == 3'd7)
                && sa[13:0] < SCREEN_BYTES)
            begin
/* a write into a screen: the shadow too */
                sh_we    <= 1'b1;
                sh_page7 <= sa[16:14] == 3'd7;
/* address and data */
                sh_addr  <= sa[12:0];
                sh_data  <= snap_wdata[7:0];
            end
/* floating bus byte (I/O cycle) */
        end
        else if (fb_pend && !mstart)
        begin
            fb_pend <= 1'b0;
            op_busy <= 1'b1;
/* a read for the floating bus */
            op_we   <= 1'b0;
            op_fb   <= 1'b1;
            sd_req  <= 1'b1;
/* of the byte the ULA would fetch; else the CPU's own read */
            sd_we   <= 1'b0;
            sd_addr <= fb_addr;
        end
        else if (rd_pend && !mstart)
        begin
/* the CPU's read */
            rd_pend <= 1'b0;
            op_busy <= 1'b1;
            op_we   <= 1'b0;
/* a read request */
            sd_req  <= 1'b1;
            sd_we   <= 1'b0;
            sd_addr <= rd_addr;
        end
    end

/* I/O ports */
/* Keyboard: AND of all rows selected by a zero on A8..A15 */
reg [4:0] kb_and;
integer   r;
always @*
begin
/* no key pressed */
    kb_and = 5'b11111;
    for (r = 0; r < KB_ROWS; r = r + 1)
    begin
        if (!a_lat[8 + r])
        begin
/* the row's keys; EAR: the tape, or the beeper's level */
            kb_and = kb_and & kb_rows[5*r +: 5];
        end
    end
end

wire ear = lon_s[1] ? llvl_s[1] : beeper;

/* last AY register select (for snapshots) */
reg [7:0] ay_sel;
reg       s_ay_bdir, s_ay_bc1, s_port_we, s_aysel;
reg [7:0] s_ay_din;

/* the I/O port read: FE (keyboard and EAR) */
always @(posedge clk)
    if (!a_lat[0])
    begin
        io_data <= {1'b1, ear, 1'b1, kb_and};
    end
/* FFFD: the AY's register */
    else if (a_lat[15] && a_lat[14] && !a_lat[1])
    begin
        io_data <= ay_dout;
    end
/* 1F: Kempston joystick */
    else if (!a_lat[5])
    begin
        io_data <= {3'b000, joy};
    end
/* floating bus */
    else
    begin
        io_data <= fb_valid ? fb_data : 8'hFF;
    end

/* the ports written by the CPU */
always @(posedge clk or negedge cpu_rst_n)
    if (!cpu_rst_n)
    begin
        border      <= 3'd7;
/* reset: white border */
        beeper      <= 1'b0;
        mic         <= 1'b0;
        p7ffd       <= 8'd0;
/* the AY's bus idle */
        ay_sel      <= 8'd0;
        ay_bdir     <= 1'b0;
        ay_bc1      <= 1'b0;
/* strobes last one clock */
        ay_din      <= 8'd0;
    end
    else
    begin
        ay_bdir <= 1'b0;
        ay_bc1  <= 1'b0;
/* an I/O write */
        if (t2_3rd && smp_wr2 && smp_io2)
        begin
            if (!a_lat[0])
            begin
                border <= smp_do[2:0];
/* port FE: MIC and beeper */
                mic    <= smp_do[3];
                beeper <= smp_do[4];
            end
            if (!a_lat[15] && !a_lat[1] && !p7ffd[5])
            begin
/* 7FFD, unless it is locked */
                p7ffd <= smp_do;
            end
            if (a_lat[15] && !a_lat[1])
            begin
                ay_bdir <= 1'b1;
/* FFFD: latch address, BFFD: write data */
                ay_bc1  <= a_lat[14];
                ay_din  <= smp_do;
                if (a_lat[14])
                begin
/* the register selected */
                    ay_sel <= smp_do;
                end
            end
        end

/* snapshot commands (CPU frozen) */
        if (s_ay_bdir || s_ay_bc1)
        begin
            ay_bdir <= s_ay_bdir;
            ay_bc1  <= s_ay_bc1;
/* the data; a register select is remembered */
            ay_din  <= s_ay_din;
            if (s_aysel)
            begin
                ay_sel <= s_ay_din;
            end
        end
/* the ports written by a snapshot */
        if (s_port_we)
        begin
            p7ffd  <= snap_wdata[7:0];
            border <= snap_wdata[10:8];
/* MIC and beeper */
            mic    <= snap_wdata[11];
            beeper <= snap_wdata[12];
        end
    end

/* Snapshots: instruction boundary tracking, freeze, commands */
/* pstate: what the last opcode fetch (M1, not an interrupt acknowledge) was */
/* P_BOUND an instruction ended (or HALT), P_XY a DD/FD prefix (the next M1 is */
/* the opcode, or another prefix; after DD CB the opcode is no M1 cycle), P_PFX a */
/* CB/ED prefix (the next M1 fetches the opcode) */
localparam [1:0] P_BOUND = 2'd0, P_XY = 2'd1, P_PFX = 2'd2;
reg [1:0] pstate;
wire [7:0] op = cpu_din;

/* reset */
always @(posedge clk or negedge cpu_rst_n)
    if (!cpu_rst_n)
    begin
        pstate <= P_BOUND;
    end
/* after a LOAD: an instruction boundary */
    else if (dirset)
    begin
        pstate <= P_BOUND;
    end
/* at every opcode fetch */
    else if (cen && cpu_mc == 3'd1 && cpu_ts == TS_T2 && !inta)
    begin
        if (!cpu_halt_n || pstate == P_PFX)
        begin
            pstate <= P_BOUND;
        end
/* DD / FD: the next byte still belongs to the instruction */
        else if (op == OP_IX || op == OP_IY)
        begin
            pstate <= P_XY;
        end
/* ED, or CB without DD / FD before it */
        else if (op == OP_ED || (op == OP_CB && pstate == P_BOUND))
        begin
            pstate <= P_PFX;
        end
        else
        begin
/* a complete opcode */
            pstate <= P_BOUND;
        end
    end

/* frz_q: set in T2 of a boundary M1 (not in a clock with cen, which would leave */
/* T2), held while snap_freeze is on (also across LOAD, which resets the T80) */
always @(posedge clk or negedge cpu_rst_n)
    if (!cpu_rst_n)
    begin
        frz_q       <= 1'b0;
/* not frozen; frozen at a boundary, reported when no access is under way */
        snap_frozen <= 1'b0;
    end
    else
    begin
        frz_q       <= sfrz_s[1] && (frz_q || (cpu_mc == 3'd1 && cpu_ts == TS_T2 && !inta && pstate == P_BOUND && !cen));
        snap_frozen <= frz_q && sfrz_s[1] && !wb_valid && !rd_pend && !(op_busy && !op_snap);
    end

/* the snapshot port's commands and states */
localparam [3:0] C_MRD = 4'd1, C_MWR = 4'd2, C_REG = 4'd3, C_DIR = 4'd4, C_LOAD = 4'd5,
                 C_AYRD = 4'd6, C_AYWR = 4'd7, C_AYSEL = 4'd8, C_PORT = 4'd9, C_STATE = 4'd10;
localparam [2:0] S_IDLE = 3'd0, S_MEM = 3'd1, S_LOAD = 3'd2, S_AY = 3'd3, S_DONE = 3'd4;
reg  [2:0] sst;
/* a step counter; the registers as 7 words */
reg  [2:0] scnt;
wire [223:0] regs_ext = {12'd0, cpu_regs};

always @(posedge clk or negedge cpu_rst_n)
/* reset */
    if (!cpu_rst_n)
    begin
        sst        <= S_IDLE;
        scnt       <= 3'd0;
/* no answer */
        snap_ack   <= 1'b0;
        snap_rdata <= 32'd0;
        smem_req   <= 1'b0;
/* the T80 not held */
        t80_rst    <= 1'b0;
        dirset     <= 1'b0;
        loaded     <= 1'b0;
/* no LOAD words; the AY's bus idle */
        dir_q      <= 224'd0;
        s_ay_bdir  <= 1'b0;
        s_ay_bc1   <= 1'b0;
/* no data, no select, no port write */
        s_ay_din   <= 8'd0;
        s_aysel    <= 1'b0;
        s_port_we  <= 1'b0;
    end
    else
    begin
/* strobes last one clock */
        s_ay_bdir <= 1'b0;
        s_ay_bc1  <= 1'b0;
        s_aysel   <= 1'b0;
/* port write, DIRSet; the step counter */
        s_port_we <= 1'b0;
        dirset    <= 1'b0;
        scnt      <= scnt + 3'd1;
/* the freeze ended */
        if (unfreeze)
        begin
            loaded <= 1'b0;
        end
/* the command sequencer */
        case (sst)
            S_IDLE:
                if (sreq_s[2] != snap_ack)
                begin
/* a new command */
                    scnt <= 3'd0;
                    sst  <= S_DONE;
                    case (snap_cmd)
/* memory: through the SDRAM port */
                        C_MRD, C_MWR:
                            if (snap_frozen)
                            begin
                                smem_req <= 1'b1;
/* wait for it; a register word read, a word for LOAD */
                                sst <= S_MEM;
                            end
                        C_REG: snap_rdata <= regs_ext[{snap_addr[2:0], 5'd0} +: 32];
                        C_DIR: dir_q[{snap_addr[2:0], 5'd0} +: 32] <= snap_wdata;
/* LOAD: reset the T80, then set its registers */
                        C_LOAD:
                            if (snap_frozen)
                            begin
                                t80_rst <= 1'b1;
/* next state */
                                sst <= S_LOAD;
                            end
/* select the register first */
                        C_AYRD, C_AYWR:
                        begin
                            s_ay_bdir <= 1'b1;
                            s_ay_bc1  <= 1'b1;
/* the register's number */
                            s_ay_din  <= {4'd0, snap_addr[3:0]};
                            sst       <= S_AY;
                        end
                        C_AYSEL:
                        begin
/* AY select: written as the program would */
                            s_ay_bdir <= 1'b1;
                            s_ay_bc1  <= 1'b1;
                            s_ay_din  <= snap_wdata[7:0];
/* remembered; the ports; the machine's state */
                            s_aysel   <= 1'b1;
                        end
                        C_PORT: s_port_we <= 1'b1;
                        C_STATE: snap_rdata <= {7'd0, !cpu_halt_n, ay_sel, 3'd0, beeper, mic, border, p7ffd};
/* other numbers do nothing */
                        default: ;
                    endcase
                end
/* the memory access is done */
            S_MEM:
                if (smem_done)
                begin
                    smem_req   <= 1'b0;
/* the byte read */
                    snap_rdata <= {24'd0, sd_dout};
                    sst        <= S_DONE;
                end
/* T80 reset (1 clock), then DIRSet (1 clock) */
            S_LOAD:
            begin
                if (scnt == 3'd1)
                begin
                    t80_rst <= 1'b0;
                end
/* the registers */
                if (scnt == LOAD_DIRSET)
                begin
                    dirset  <= 1'b1;
                end
                if (scnt == LOAD_DONE)
                begin
/* done */
                    loaded <= 1'b1;
                    sst <= S_DONE;
                end
            end
/* AY_RD: dout follows the select; AY_WR: write */
            S_AY:
            begin
                if (scnt == AY_STROBE && snap_cmd == C_AYWR)
                begin
                    s_ay_bdir <= 1'b1;
/* the data to write; later the data read */
                    s_ay_din  <= snap_wdata[7:0];
                end
                if (scnt == AY_DONE)
                begin
                    snap_rdata <= {24'd0, ay_dout};
/* done */
                    sst        <= S_DONE;
                end
            end
/* S_DONE (also a few clocks after a write to the AY / ports) */
            default:
            begin
                snap_ack <= sreq_s[2];
                sst      <= S_IDLE;
            end
        endcase
    end

/* Interrupt (32 T-states) */
reg [16:0] frame_t;
reg [5:0]  int_t;
reg        vs_prev;
/* video frame mark */
wire       int_start = (vid50_s[2] && vs_prev && !vsync_s[2]) ||
                       (!vid50_s[2] && cen_raw && frame_t == FRAME_T - 1);

always @(posedge clk or negedge cpu_rst_n)
    if (!cpu_rst_n)
    begin
/* reset */
        frame_t <= 17'd0;
        int_t   <= 6'd0;
        int_n   <= 1'b1;
/* the vsync one clock ago */
        vs_prev <= 1'b1;
    end
    else
    begin
        vs_prev <= vsync_s[2];
        if (int_start)
        begin
/* INT low for 32 T-states */
            int_n <= 1'b0;
            int_t <= 6'd0;
        end
        else if (cen_raw && !int_n)
        begin
/* counted; then high again */
            int_t <= int_t + 6'd1;
            if (int_t == INT_LAST)
            begin
                int_n <= 1'b1;
            end
        end
/* T-states of the frame */
        if (int_start)
        begin
            frame_t <= 17'd0;
        end
        else if (cen_raw)
        begin
/* one more */
            frame_t <= frame_t + 17'd1;
        end
    end

/* Memory contention (Level 1, see the header) */

wire       cont_on  = cont_s[1] & !turbo_s[2];
wire       in_scr   = vline >= SCR_LINE0 && vline < SCR_LINE_END && hpos < SCR_TSTATES;
wire [2:0] cdelay   = !in_scr ? 3'd0 : (hpos[2:1] == 2'b11) ? 3'd0 : CONT_MAX - hpos[2:0];
/* 4000-7FFF */
wire       hi_c     = a_lat[15:14] == 2'b01;
/* + odd page at C000 */
wire       mem_c    = hi_c || (a_lat[15:14] == 2'b11 && p7ffd[0]);
/* C:1, C:3 */
wire       io_c     = (hi_c && !a_lat[0] && io_k <= 3'd1) ||
/* C:1 x 4 */
                      (hi_c &&  a_lat[0]) ||
/* N:1, C:3 */
                      (!hi_c && !a_lat[0] && io_k == 3'd1);

always @(posedge clk or negedge cpu_rst_n)
    if (!cpu_rst_n)
    begin
/* reset */
        hpos     <= HPOS_RESET;
        vline    <= 9'd0;
        chk      <= 3'd0;
/* no T-state under way, no contention */
        io_k     <= 3'd0;
        cont_cnt <= 3'd0;
    end
    else
    begin
        if (int_start)
        begin
/* the frame starts: 3 T-states after the interrupt */
            hpos  <= HPOS_RESET;
            vline <= 9'd0;
        end
        else if (cen_raw)
        begin
/* the end of a line */
            if (hpos == HPOS_LAST)
            begin
                hpos  <= 8'd0;
                vline <= vline == 9'd511 ? vline : vline + 9'd1;
            end
            else
            begin
/* the next T-state; clocks since the enable */
                hpos <= hpos + 8'd1;
            end
        end
        chk <= {chk[1:0], cen_d};
        if (mstart)
        begin
/* T-states of the M-cycle */
            io_k <= 3'd0;
        end
        else if (cen_d)
        begin
            io_k <= io_k + 3'd1;
        end
/* 2 clocks after the cen (smp_io / smp_nr known), before the next cen can come */
        if (chk[1] && cont_on && !inta && (smp_io ? io_c : (io_k == 3'd0 && smp_nr && mem_c)))
        begin
            cont_cnt <= cdelay;
        end
        else if (cen_raw && cont_cnt != 3'd0)
        begin
/* one T-state less to withhold */
            cont_cnt <= cont_cnt - 3'd1;
        end
    end

endmodule

`default_nettype wire
