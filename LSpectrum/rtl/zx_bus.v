//=============================================================================
// zx_bus -- ZX Spectrum 128 CPU side: clock enable, bus bridge to the SDRAM,
//           memory paging, I/O ports, interrupt
//
// Clock enable (CEN) for the T80, from a 32-bit phase accumulator at 112 MHz:
//   normal 3.5469 MHz (31-32 clocks per T-state), turbo exactly 28 MHz (every
//   4 clocks). CEN pulses are never closer than 4 clocks (the T80 multicycle).
//   A tick that cannot be given (stall) is owed and given as soon as possible.
//
// Bus bridge, per M-cycle (see docs/T80_CEN_ANALYSIS.md):
//   T1, 1st clock after CEN: latch the address and start a speculative SDRAM
//       read (A is a T80 register output, so this is a normal 1-clock path).
//   T1, 2nd clock: sample the cycle decode (IORQ/Write; combinational in the
//       T80 -> 2-clock multicycle into the smp_* registers).
//   T2, 2nd clock: sample Write/IORQ/DO; 3rd clock: post the memory write
//       (+ screen shadow write) or perform the I/O write.
//   The CEN that ends T2 (where the T80 takes the data) is held until the
//   read of this M-cycle has completed. Only in turbo can that happen.
//   Writes are posted (the CPU never waits for them); the next read waits for
//   the SDRAM to finish them first, so a read always sees earlier writes.
//
// Memory map (SDRAM byte address, 18 bits):
//   0x00000-0x1FFFF  RAM pages 0-7 (page n at n * 0x4000)
//   0x20000/0x24000  ROM 0 (128K editor) / ROM 1 (48K BASIC), 7FFD bit 4
//   0x28000          DiagROM (both ROM slots) when selected at reset
//   CPU 0000-3FFF ROM (writes ignored), 4000 page 5, 8000 page 2, C000 7FFD[2:0]
//
// I/O (partial decoding as on the real 128):
//   write A0=0          port FE: border [2:0], MIC [3] (to the tape loader's recorder), beeper [4]
//   write A15=0, A1=0   port 7FFD: RAM page [2:0], screen [3], ROM [4], lock [5]
//   write A15=1 A14=1 A1=0  AY register select (FFFD); A15=1 A14=0 A1=0  AY data (BFFD)
//   read  A0=0          keyboard (A8-A15 select rows), EAR on bit 6, bits 5/7 = 1
//                       EAR = SD tape loader while it plays (ltape_on), else the beeper
//   read  FFFD          AY register
//   read  A0=1 A5=0     Kempston joystick (port 1F)
//   other reads         floating bus (see below), 0xFF in turbo or with contention off
//
// Interrupt: 32 T-states long. Source: the video's frame mark in 50 Hz video mode
// (a real 50.017 Hz frame, placed as on a 128K: zx_video INT_LINE / INT_PX), otherwise a counter of 70908 T-states (128K frame), which
// also follows turbo (as in the DE10-Lite reference).
//
// Memory contention (Level 1, 128K timing; off in turbo or when cont_en = 0):
//   A frame T-state counter restarts at each interrupt and counts real T-states:
//   CPU T-states and those lost to contention (cen_raw), not those of a hold or a
//   snapshot freeze. Contended: T-states 14361 + 228 * line + p, line 0..191, p 0..127,
//   delay 6,5,4,3,2,1,0,0 for p mod 8 (hpos/vline below: hpos = (t + 3) mod 228,
//   vline = (t + 3) / 228, contended lines 63..254, hpos < 128).
//   Memory: at T1 of a memory read / write / opcode fetch to 4000-7FFF, or to
//   C000-FFFF while an odd RAM page (1, 3, 5, 7) is paged in. I/O: high byte
//   40-7F and A0 = 0: C:1, C:3; high byte 40-7F, A0 = 1: C:1 x 4; A0 = 0 only: N:1,
//   C:3 (checked at the T-states 0, 1, 2, 3 of the cycle). The CPU's cen is withheld
//   for the delay; those ticks are not owed (they are lost, as on the real machine).
//   Not done (Level 2): the extra internal T-states some instructions put an address
//   on the bus for (e.g. INC HL, PUSH, JR), refresh.
//
// Floating bus (128K timing, on with contention): an I/O read of a port nothing
//   answers (A0 = 1, not the AY at FFFD, A5 = 1 - e.g. port FF) returns the byte the
//   ULA fetches at the start of the 4th T-state of the I/O cycle, after all of its
//   contention (Fuse 1.6 readport: early C:1 + 1 T, late C:1,+1,C:1,+1,C:1 for a
//   contended high byte, else 2 T): with x = T-state - 14362 - 228 * row (row 0..191,
//   x 0..127), x mod 8 = 2 bitmap, 3 attribute, 4 bitmap + 1, 5 attribute + 1 of
//   column 2 * (x / 8); otherwise FF. A contended poll (high byte 40-7F) thus sees
//   only attributes or FF - games that sync on an attribute (Sidewize) rely on it.
//   The bridge decides at the start of T2 (hpos then, plus the late contention it
//   will get) and reads the byte from SDRAM (displayed page 5 / 7) before the CPU
//   takes it at the end of the wait state. (2026-10-11: was the byte at T2, tl =
//   T - 14364: half of the contended polls saw a bitmap byte, Sidewize synced early
//   and its player flickered.)
//
// Snapshots (.z80 save/load by the ESP32 loader firmware, esp32/src/snap.c):
//   snap_freeze stops the CPU at the next instruction boundary: in T2 of an
//   opcode fetch (M1) that is not an interrupt acknowledge and does not follow a
//   prefix (CB/ED/DD/FD). There the T80 has written back the previous
//   instruction and has not yet taken the opcode or incremented PC/R, so its
//   registers (REG) are the state between two instructions with PC = the next
//   instruction (in HALT: PC = HALT + 1, the firmware saves PC - 1).
//   snap_frozen = stopped there and the bridge idle. While frozen, commands
//   (snap_cmd/addr/wdata stable, snap_req toggled; snap_ack toggles when done,
//   result in snap_rdata):
//     1 MRD   SDRAM byte at addr                      -> rdata[7:0]
//     2 MWR   SDRAM byte at addr <= wdata[7:0] (and the screen shadow)
//     3 REG   CPU register word addr[2:0] (cpu_t80 layout, 7 x 32 bits)
//     4 DIR   register word addr[2:0] <= wdata, for LOAD
//     5 LOAD  reset the T80 alone and load all registers from the DIR words
//     6 AYRD  AY register addr[3:0]                   -> rdata[7:0]
//     7 AYWR  AY register addr[3:0] <= wdata[7:0]
//     8 AYSEL AY register select <= wdata[7:0] (as an OUT to FFFD)
//     9 PORT  7FFD <= wdata[7:0] (ignores the lock), border/MIC/beeper <= wdata[10:8]/[11]/[12]
//    10 STATE rdata = {halt [24], AY select [23:16], beeper [12], MIC [11], border [10:8], 7FFD [7:0]}
//   AYRD / AYWR change the AY's register select; AYSEL restores it. Leaving the
//   freeze repeats the opcode read of the frozen M1 (SDRAM reads changed the
//   data bus), except after LOAD (the T80 starts a new M1 from its reset state).
//=============================================================================
`default_nettype none

module zx_bus #(
    parameter [31:0] INC_NORMAL   = 32'd136016246,   // 3.5469 MHz at 112 MHz
    parameter [31:0] INC_TURBO    = 32'd1073741824,  // 28 MHz = every 4 clocks
    parameter integer FRAME_T     = 70908            // T-states per 128K frame
)(
    input  wire        clk,             // 112 MHz
    input  wire        rst_n,           // system reset (CPU and ports)
    input  wire        run,             // ROMs loaded: CPU may run

    input  wire        turbo,
    input  wire        diag_key,        // F1 held: DiagROM if held when the CPU starts
    input  wire        vid50,           // video in 50 Hz mode (other clock domain)
    input  wire        vsync_n,         // video frame interrupt mark, falling edge (other clock domain)
    input  wire [39:0] kb_rows,         // 8 rows x 5 keys, active low, row i = A(8+i)
    input  wire [4:0]  joy,             // Kempston: fire, up, down, left, right (active high)
    input  wire        ltape_on,        // SD tape loader drives EAR (56 MHz domain)
    input  wire        ltape_lvl,
    output reg         cen_tgl,         // toggles on every T-state (incl. contention; for the tape loader)
    input  wire        hold,            // tape loader: pause the CPU (56 MHz domain); T-states stop
    output reg         mic,             // port FE bit 3

    // SDRAM port (sdram_ram protocol: req pulse, hold until ack)
    output reg         sd_req,
    output reg         sd_we,
    output reg  [17:0] sd_addr,
    output reg  [7:0]  sd_din,
    input  wire [7:0]  sd_dout,
    input  wire        sd_ack,

    // screen shadow write (pages 5 and 7, first 6912 bytes)
    output reg         sh_we,
    output reg         sh_page7,
    output reg  [12:0] sh_addr,
    output reg  [7:0]  sh_data,

    // AY-3-8912 bus (jt49_bus)
    output reg         ay_bdir,
    output reg         ay_bc1,
    output reg  [7:0]  ay_din,
    input  wire [7:0]  ay_dout,

    output reg  [2:0]  border,
    output wire        screen7,         // 7FFD bit 3
    output reg         beeper,
    output reg         diag_rom,
    output wire        cpu_running,

    // snapshot port (tape loader, 56 MHz from the same PLL, edges aligned; see above)
    input  wire        snap_freeze,     // level
    input  wire        snap_req,        // toggles: execute snap_cmd
    input  wire [3:0]  snap_cmd,
    input  wire [17:0] snap_addr,
    input  wire [31:0] snap_wdata,
    output reg         snap_frozen,
    output reg         snap_ack,        // toggles when a command is done
    output reg  [31:0] snap_rdata,

    input  wire        cont_en          // memory contention on (tape loader clock domain)
);

//-----------------------------------------------------------------------------
// Synchronisers
//-----------------------------------------------------------------------------
reg [2:0] turbo_s, vid50_s, vsync_s, diag_s;
reg [1:0] lon_s, llvl_s, hold_s, sfrz_s, cont_s;
reg [2:0] sreq_s;
always @(posedge clk) begin
    hold_s  <= {hold_s[0], hold};
    sfrz_s  <= {sfrz_s[0], snap_freeze};
    cont_s  <= {cont_s[0], cont_en};
    sreq_s  <= {sreq_s[1:0], snap_req};
    lon_s   <= {lon_s[0],  ltape_on};
    llvl_s  <= {llvl_s[0], ltape_lvl};
    turbo_s <= {turbo_s[1:0], turbo};
    vid50_s <= {vid50_s[1:0], vid50};
    vsync_s <= {vsync_s[1:0], vsync_n};
    diag_s  <= {diag_s[1:0],  diag_key};
end

wire cpu_rst_n = rst_n & run;
assign cpu_running = cpu_rst_n;

// DiagROM select: follows F1 while the CPU is held in reset, frozen when it starts
always @(posedge clk or negedge rst_n)
    if (!rst_n)          diag_rom <= 1'b0;
    else if (!run)       diag_rom <= diag_s[2];

//-----------------------------------------------------------------------------
// CPU
//-----------------------------------------------------------------------------
wire        cen;
reg         int_n;
wire [7:0]  cpu_din;
wire [15:0] cpu_a;
wire [7:0]  cpu_do;
wire [2:0]  cpu_mc, cpu_ts;
wire        cpu_iorq, cpu_noread, cpu_write, cpu_m1_n, cpu_intcycle_n, cpu_halt_n;
wire [211:0] cpu_regs;
reg  [223:0] dir_q;                     // registers for LOAD (7 words)
reg         t80_rst, dirset;
wire        t80_rst_n = cpu_rst_n & !t80_rst;

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

//-----------------------------------------------------------------------------
// Clock enable: phase accumulator + stall
//-----------------------------------------------------------------------------
reg  [31:0] dds;
reg         tick, owed, cen_d;
reg  [1:0]  since;                      // clocks since the last cen (0 = the clock after it), saturating at 3
wire [32:0] dds_next = {1'b0, dds} + {1'b0, (turbo_s[2] ? INC_TURBO : INC_NORMAL)};
wire        stall;
reg         frz_q;                      // snapshot freeze: CPU stopped at an instruction boundary
reg  [2:0]  cont_cnt;                   // contention: T-states still to withhold
reg  [7:0]  hpos;                       // (t + 3) mod 228: 0 = first contended T-state of a line
reg  [8:0]  vline;                      // (t + 3) / 228: lines 63..254 are contended
reg  [2:0]  chk;                        // clocks since the cen that started a CPU T-state
reg  [2:0]  io_k;                       // T-states since the start of this M-cycle
reg         fb_pend, fb_valid;          // floating bus: SDRAM read wanted / byte in fb_data
reg  [17:0] fb_addr;
reg  [7:0]  fb_data;

// cen_raw: a T-state passes (frame time); cen: the CPU takes it (not lost to contention)
wire cen_raw = (tick | owed) & (since == 2'd3) & !stall & !hold_s[1] & !frz_q & cpu_rst_n;
assign cen = cen_raw & (cont_cnt == 3'd0);

always @(posedge clk or negedge cpu_rst_n)
    if (!cpu_rst_n) begin
        dds   <= 32'd0;
        tick  <= 1'b0;
        owed  <= 1'b0;
        since <= 2'd3;
        cen_d <= 1'b0;
        cen_tgl <= 1'b0;
    end else begin
        if (cen_raw) cen_tgl <= !cen_tgl;               // real T-states: the tape keeps time through contention
        dds   <= dds_next[31:0];
        tick  <= dds_next[32];
        owed  <= (tick | owed) & !cen_raw;
        since <= cen_raw ? 2'd0 : (since == 2'd3 ? 2'd3 : since + 2'd1);
        cen_d <= cen;
    end

//-----------------------------------------------------------------------------
// M-cycle tracking
//-----------------------------------------------------------------------------
reg  [2:0] ts_prev;                     // TS before the last cen
always @(posedge clk or negedge cpu_rst_n)
    if (!cpu_rst_n)  ts_prev <= 3'd0;
    else if (cen)    ts_prev <= cpu_ts;

wire mstart = cen_d && cpu_ts == 3'd1 && ts_prev != 3'd1;   // first clock of T1
wire t2_1st = cen_d && cpu_ts == 3'd2 && ts_prev != 3'd2;   // first clock of T2

reg  [15:0] a_lat;                      // address of this M-cycle
reg         inta;                       // interrupt acknowledge M1
reg         smp_io;                     // I/O cycle      (sampled 2 clocks after the T1 cen)
reg         smp_nr;                     // memory access (read or write) in this M-cycle (same)
reg         smp_iow;                    // write in this M-cycle (same; for the floating bus)
reg         t1_2nd, t2_2nd, t2_3rd;     // 2nd clock of T1 / T2, 3rd clock of T2 (single-clock paths)
reg         smp_wr2, smp_io2;           // Write/IORQ     (sampled 2 clocks after the T2 cen)
reg  [7:0]  smp_do;                     // data out       (sampled 2 clocks after the T2 cen)

//-----------------------------------------------------------------------------
// Paging and memory map
//-----------------------------------------------------------------------------
reg  [7:0]  p7ffd;
assign screen7 = p7ffd[3];

// floating bus (see the header): which byte the ULA fetches now
wire        fb_on   = cont_s[1] & !turbo_s[2];              // as contention (F5, not in turbo)
wire        fb_port = a_lat[0] && a_lat[5] && !(a_lat[15] && a_lat[14] && !a_lat[1]);   // nothing answers
// hpos at Fuse's read point, from hpos at the start of T2: the late contention steps
// (delay, +1 per T-state). Two pipeline stages, sampled at chk[1] (hpos changes at a
// cen_raw, the next one comes >= 4 clocks later). h + its delay: in a contended line
// and h < 128, phases 0..5 wait for phase 6 (low bits 110), 6 and 7 do not wait.
function [7:0] fb_c(input [7:0] h, input scrl);
    fb_c = (scrl && !h[7] && !(h[2] && h[1])) ? {h[7:3], 3'b110} : h;
endfunction
wire        fb_scrl = vline >= 9'd63 && vline < 9'd255;
wire        fb_hic  = a_lat[15:14] == 2'b01;                    // contended high byte (as io_c)
reg  [7:0]  fb_h1, fb_hrd;                                      // fb_hrd: hpos when the port is read (> 227: past the line, FF)
always @(posedge clk) begin
    fb_h1  <= fb_hic ? fb_c(hpos, fb_scrl) + 8'd1 : hpos + 8'd2;
    fb_hrd <= fb_hic ? fb_c(fb_c(fb_h1, fb_scrl) + 8'd1, fb_scrl) : fb_h1;
end
wire [7:0]  fb_x    = fb_hrd - 8'd1;                            // x = T-state - 14362 - 228 * row (hpos 0 = 14361)
wire [7:0]  fb_row  = vline[7:0] - 8'd63;
wire        fb_scr  = fb_scrl && fb_hrd >= 8'd1 && fb_hrd < 8'd129 && fb_x[2:0] >= 3'd2 && fb_x[2:0] <= 3'd5;
wire        fb_attr = fb_x[0];                                  // 3, 5: attribute; 2, 4: bitmap
wire [4:0]  fb_col  = {fb_x[6:3], fb_x[2]};                     // 2 * (x / 8) (+1 for 4, 5)

function [17:0] map_addr(input [15:0] a, input [7:0] pg, input diag);
    case (a[15:14])
        2'd0:    map_addr = {1'b1, (diag ? 3'd2 : {2'b00, pg[4]}), a[13:0]};
        2'd1:    map_addr = {1'b0, 3'd5,    a[13:0]};
        2'd2:    map_addr = {1'b0, 3'd2,    a[13:0]};
        default: map_addr = {1'b0, pg[2:0], a[13:0]};
    endcase
endfunction

//-----------------------------------------------------------------------------
// SDRAM access: speculative read per M-cycle, posted writes
// wb_valid = a posted write waiting to be issued (cleared when it is issued;
// it can never be refilled before that, because each M-cycle waits for its
// own read, which is issued after any earlier write).
//-----------------------------------------------------------------------------
reg         rd_pend, rd_done, op_busy, op_we;
reg         wb_valid;
reg         op_snap, smem_req, smem_done, loaded;
reg         op_fb;
wire        unfreeze = frz_q & !sfrz_s[1];  // last clock of a freeze
wire [17:0] sa = snap_addr;
reg  [17:0] wb_addr, rd_addr;
reg  [7:0]  wb_data;

wire rd_ok = rd_done | (op_busy & !op_we & sd_ack);
assign stall = (cpu_ts == 3'd2) & !rd_ok;

// Data to the CPU: interrupt vector bus = FF, I/O data, or memory
reg  [7:0] io_data;
assign cpu_din = inta ? 8'hFF : smp_io ? io_data : sd_dout;

always @(posedge clk or negedge cpu_rst_n)
    if (!cpu_rst_n) begin
        a_lat    <= 16'd0;
        inta     <= 1'b0;
        smp_io   <= 1'b0;
        smp_nr   <= 1'b0;
        smp_iow  <= 1'b0;
        fb_pend  <= 1'b0;
        fb_valid <= 1'b0;
        fb_addr  <= 18'd0;
        fb_data  <= 8'hFF;
        op_fb    <= 1'b0;
        t1_2nd   <= 1'b0;
        t2_2nd   <= 1'b0;
        t2_3rd   <= 1'b0;
        smp_wr2  <= 1'b0;
        smp_io2  <= 1'b0;
        smp_do   <= 8'd0;
        rd_pend  <= 1'b0;
        rd_done  <= 1'b0;
        rd_addr  <= 18'd0;
        op_busy  <= 1'b0;
        op_we    <= 1'b0;
        wb_valid <= 1'b0;
        wb_addr  <= 18'd0;
        wb_data  <= 8'd0;
        op_snap  <= 1'b0;
        smem_done <= 1'b0;
        sd_req   <= 1'b0;
        sd_we    <= 1'b0;
        sd_addr  <= 18'd0;
        sd_din   <= 8'd0;
        sh_we    <= 1'b0;
        sh_page7 <= 1'b0;
        sh_addr  <= 13'd0;
        sh_data  <= 8'd0;
    end else begin
        sd_req <= 1'b0;
        sh_we  <= 1'b0;
        smem_done <= 1'b0;

        // T1: latch address, start the speculative read
        t1_2nd <= mstart;
        t2_2nd <= t2_1st;
        if (mstart) begin
            a_lat   <= cpu_a;
            inta    <= !cpu_intcycle_n && cpu_mc == 3'd1;
            rd_addr <= map_addr(cpu_a, p7ffd, diag_rom);
            rd_pend <= 1'b1;
            rd_done <= 1'b0;
            smp_io  <= 1'b0;
        end
        if (t1_2nd) begin
            smp_io <= cpu_iorq;
            smp_nr <= !cpu_noread | cpu_write;
            smp_iow <= cpu_write;
        end

        // floating bus: at the 2nd T-state of an I/O read of an unanswered port, fetch the byte
        // the ULA has at the read point (fb_hrd, see the header)
        if (mstart) begin
            fb_pend  <= 1'b0;
            fb_valid <= 1'b0;
        end else if (chk[1] && io_k == 3'd1 && smp_io && !smp_iow && !inta && fb_on && fb_port) begin
            fb_pend <= fb_scr;
            fb_addr <= {1'b0, (p7ffd[3] ? 3'd7 : 3'd5),
                        fb_attr ? {4'b0110, fb_row[7:3], fb_col} : {1'b0, fb_row[7:6], fb_row[2:0], fb_row[5:3], fb_col}};
        end
        if (t2_2nd) begin
            smp_wr2 <= cpu_write;
            smp_io2 <= cpu_iorq;
            smp_do  <= cpu_do;
        end
        t2_3rd <= t2_2nd;

        // T2: post the memory write (I/O writes: see the port block)
        if (t2_3rd && smp_wr2 && !smp_io2) begin
            if (a_lat[15:14] != 2'd0) begin             // ROM is write-protected
                wb_valid <= 1'b1;
                wb_addr  <= map_addr(a_lat, p7ffd, diag_rom);
                wb_data  <= smp_do;
            end
            if ((a_lat[15:14] == 2'd1 || (a_lat[15:14] == 2'd3 && (p7ffd[2:0] == 3'd5 || p7ffd[2:0] == 3'd7)))
                && a_lat[13:0] < 14'd6912) begin
                sh_we    <= 1'b1;
                sh_page7 <= a_lat[15:14] == 2'd3 && p7ffd[2:0] == 3'd7;
                sh_addr  <= a_lat[12:0];
                sh_data  <= smp_do;
            end
        end

        // leaving a snapshot freeze: read the opcode of the frozen M1 again (rd_done
        // falls in the clock frz_q does, so the CEN ending T2 waits for the new read)
        if (unfreeze && !loaded) begin
            rd_pend <= 1'b1;
            rd_done <= 1'b0;
        end

        // SDRAM port: one access at a time, posted write first
        if (op_busy) begin
            if (sd_ack) begin
                op_busy <= 1'b0;
                op_snap <= 1'b0;
                op_fb   <= 1'b0;
                if (op_snap)     smem_done <= 1'b1;
                else if (op_fb)  begin fb_data <= sd_dout; fb_valid <= 1'b1; end
                else if (!op_we) rd_done   <= 1'b1;
            end
        end else if (wb_valid) begin
            wb_valid <= 1'b0;
            op_busy <= 1'b1;
            op_we   <= 1'b1;
            sd_req  <= 1'b1;
            sd_we   <= 1'b1;
            sd_addr <= wb_addr;
            sd_din  <= wb_data;
        end else if (smem_req && !smem_done && snap_frozen) begin   // snapshot access (CPU frozen)
            op_busy <= 1'b1;
            op_snap <= 1'b1;
            op_we   <= snap_cmd == 4'd2;
            sd_req  <= 1'b1;
            sd_we   <= snap_cmd == 4'd2;
            sd_addr <= sa;
            sd_din  <= snap_wdata[7:0];
            if (snap_cmd == 4'd2 && sa[17] == 1'b0 && (sa[16:14] == 3'd5 || sa[16:14] == 3'd7)
                && sa[13:0] < 14'd6912) begin
                sh_we    <= 1'b1;
                sh_page7 <= sa[16:14] == 3'd7;
                sh_addr  <= sa[12:0];
                sh_data  <= snap_wdata[7:0];
            end
        end else if (fb_pend && !mstart) begin             // floating bus byte (I/O cycle)
            fb_pend <= 1'b0;
            op_busy <= 1'b1;
            op_we   <= 1'b0;
            op_fb   <= 1'b1;
            sd_req  <= 1'b1;
            sd_we   <= 1'b0;
            sd_addr <= fb_addr;
        end else if (rd_pend && !mstart) begin
            rd_pend <= 1'b0;
            op_busy <= 1'b1;
            op_we   <= 1'b0;
            sd_req  <= 1'b1;
            sd_we   <= 1'b0;
            sd_addr <= rd_addr;
        end
    end

//-----------------------------------------------------------------------------
// I/O ports
//-----------------------------------------------------------------------------
// Keyboard: AND of all rows selected by a zero on A8..A15
reg [4:0] kb_and;
integer   r;
always @* begin
    kb_and = 5'b11111;
    for (r = 0; r < 8; r = r + 1)
        if (!a_lat[8 + r]) kb_and = kb_and & kb_rows[5*r +: 5];
end

wire ear = lon_s[1] ? llvl_s[1] : beeper;

reg [7:0] ay_sel;                       // last AY register select (for snapshots)
reg       s_ay_bdir, s_ay_bc1, s_port_we, s_aysel;
reg [7:0] s_ay_din;

always @(posedge clk)
    if (!a_lat[0])                                   io_data <= {1'b1, ear, 1'b1, kb_and};
    else if (a_lat[15] && a_lat[14] && !a_lat[1])    io_data <= ay_dout;
    else if (!a_lat[5])                              io_data <= {3'b000, joy};
    else                                             io_data <= fb_valid ? fb_data : 8'hFF;   // floating bus

always @(posedge clk or negedge cpu_rst_n)
    if (!cpu_rst_n) begin
        border      <= 3'd7;
        beeper      <= 1'b0;
        mic         <= 1'b0;
        p7ffd       <= 8'd0;
        ay_sel      <= 8'd0;
        ay_bdir     <= 1'b0;
        ay_bc1      <= 1'b0;
        ay_din      <= 8'd0;
    end else begin
        ay_bdir <= 1'b0;
        ay_bc1  <= 1'b0;
        if (t2_3rd && smp_wr2 && smp_io2) begin
            if (!a_lat[0]) begin
                border <= smp_do[2:0];
                mic    <= smp_do[3];
                beeper <= smp_do[4];
            end
            if (!a_lat[15] && !a_lat[1] && !p7ffd[5])
                p7ffd <= smp_do;
            if (a_lat[15] && !a_lat[1]) begin
                ay_bdir <= 1'b1;
                ay_bc1  <= a_lat[14];                   // FFFD: latch address, BFFD: write data
                ay_din  <= smp_do;
                if (a_lat[14]) ay_sel <= smp_do;
            end
        end

        // snapshot commands (CPU frozen)
        if (s_ay_bdir || s_ay_bc1) begin
            ay_bdir <= s_ay_bdir;
            ay_bc1  <= s_ay_bc1;
            ay_din  <= s_ay_din;
            if (s_aysel) ay_sel <= s_ay_din;
        end
        if (s_port_we) begin
            p7ffd  <= snap_wdata[7:0];
            border <= snap_wdata[10:8];
            mic    <= snap_wdata[11];
            beeper <= snap_wdata[12];
        end
    end

//-----------------------------------------------------------------------------
// Snapshots: instruction boundary tracking, freeze, commands
//-----------------------------------------------------------------------------
// pstate: what the last opcode fetch (M1, not an interrupt acknowledge) was
//   P_BOUND an instruction ended (or HALT), P_XY a DD/FD prefix (the next M1 is
//   the opcode, or another prefix; after DD CB the opcode is no M1 cycle), P_PFX a
//   CB/ED prefix (the next M1 fetches the opcode)
localparam [1:0] P_BOUND = 2'd0, P_XY = 2'd1, P_PFX = 2'd2;
reg [1:0] pstate;
wire [7:0] op = cpu_din;

always @(posedge clk or negedge cpu_rst_n)
    if (!cpu_rst_n)
        pstate <= P_BOUND;
    else if (dirset)
        pstate <= P_BOUND;
    else if (cen && cpu_mc == 3'd1 && cpu_ts == 3'd2 && !inta) begin
        if (!cpu_halt_n || pstate == P_PFX)
            pstate <= P_BOUND;
        else if (op == 8'hDD || op == 8'hFD)
            pstate <= P_XY;
        else if (op == 8'hED || (op == 8'hCB && pstate == P_BOUND))
            pstate <= P_PFX;
        else
            pstate <= P_BOUND;
    end

// frz_q: set in T2 of a boundary M1 (not in a clock with cen, which would leave
// T2), held while snap_freeze is on (also across LOAD, which resets the T80)
always @(posedge clk or negedge cpu_rst_n)
    if (!cpu_rst_n) begin
        frz_q       <= 1'b0;
        snap_frozen <= 1'b0;
    end else begin
        frz_q       <= sfrz_s[1] && (frz_q || (cpu_mc == 3'd1 && cpu_ts == 3'd2 && !inta && pstate == P_BOUND && !cen));
        snap_frozen <= frz_q && sfrz_s[1] && !wb_valid && !rd_pend && !(op_busy && !op_snap);
    end

localparam [3:0] C_MRD = 4'd1, C_MWR = 4'd2, C_REG = 4'd3, C_DIR = 4'd4, C_LOAD = 4'd5,
                 C_AYRD = 4'd6, C_AYWR = 4'd7, C_AYSEL = 4'd8, C_PORT = 4'd9, C_STATE = 4'd10;
localparam [2:0] S_IDLE = 3'd0, S_MEM = 3'd1, S_LOAD = 3'd2, S_AY = 3'd3, S_DONE = 3'd4;
reg  [2:0] sst;
reg  [2:0] scnt;
wire [223:0] regs_ext = {12'd0, cpu_regs};

always @(posedge clk or negedge cpu_rst_n)
    if (!cpu_rst_n) begin
        sst        <= S_IDLE;
        scnt       <= 3'd0;
        snap_ack   <= 1'b0;
        snap_rdata <= 32'd0;
        smem_req   <= 1'b0;
        t80_rst    <= 1'b0;
        dirset     <= 1'b0;
        loaded     <= 1'b0;
        dir_q      <= 224'd0;
        s_ay_bdir  <= 1'b0;
        s_ay_bc1   <= 1'b0;
        s_ay_din   <= 8'd0;
        s_aysel    <= 1'b0;
        s_port_we  <= 1'b0;
    end else begin
        s_ay_bdir <= 1'b0;
        s_ay_bc1  <= 1'b0;
        s_aysel   <= 1'b0;
        s_port_we <= 1'b0;
        dirset    <= 1'b0;
        scnt      <= scnt + 3'd1;
        if (unfreeze) loaded <= 1'b0;
        case (sst)
            S_IDLE: if (sreq_s[2] != snap_ack) begin
                scnt <= 3'd0;
                sst  <= S_DONE;
                case (snap_cmd)
                    C_MRD, C_MWR: if (snap_frozen) begin smem_req <= 1'b1; sst <= S_MEM; end
                    C_REG:   snap_rdata <= regs_ext[{snap_addr[2:0], 5'd0} +: 32];
                    C_DIR:   dir_q[{snap_addr[2:0], 5'd0} +: 32] <= snap_wdata;
                    C_LOAD:  if (snap_frozen) begin t80_rst <= 1'b1; sst <= S_LOAD; end
                    C_AYRD, C_AYWR: begin                   // select the register first
                        s_ay_bdir <= 1'b1;
                        s_ay_bc1  <= 1'b1;
                        s_ay_din  <= {4'd0, snap_addr[3:0]};
                        sst       <= S_AY;
                    end
                    C_AYSEL: begin
                        s_ay_bdir <= 1'b1;
                        s_ay_bc1  <= 1'b1;
                        s_ay_din  <= snap_wdata[7:0];
                        s_aysel   <= 1'b1;
                    end
                    C_PORT:  s_port_we <= 1'b1;
                    C_STATE: snap_rdata <= {7'd0, !cpu_halt_n, ay_sel, 3'd0, beeper, mic, border, p7ffd};
                    default: ;
                endcase
            end
            S_MEM: if (smem_done) begin
                smem_req   <= 1'b0;
                snap_rdata <= {24'd0, sd_dout};
                sst        <= S_DONE;
            end
            S_LOAD: begin                               // T80 reset (1 clock), then DIRSet (1 clock)
                if (scnt == 3'd1) t80_rst <= 1'b0;
                if (scnt == 3'd3) dirset  <= 1'b1;
                if (scnt == 3'd5) begin loaded <= 1'b1; sst <= S_DONE; end
            end
            S_AY: begin                                 // AY_RD: dout follows the select; AY_WR: write
                if (scnt == 3'd2 && snap_cmd == C_AYWR) begin
                    s_ay_bdir <= 1'b1;
                    s_ay_din  <= snap_wdata[7:0];
                end
                if (scnt == 3'd6) begin
                    snap_rdata <= {24'd0, ay_dout};
                    sst        <= S_DONE;
                end
            end
            default: begin                              // S_DONE (also a few clocks after a write to the AY / ports)
                snap_ack <= sreq_s[2];
                sst      <= S_IDLE;
            end
        endcase
    end

//-----------------------------------------------------------------------------
// Interrupt (32 T-states)
//-----------------------------------------------------------------------------
reg [16:0] frame_t;
reg [5:0]  int_t;
reg        vs_prev;
wire       int_start = (vid50_s[2] && vs_prev && !vsync_s[2]) ||           // video frame mark
                       (!vid50_s[2] && cen_raw && frame_t == FRAME_T - 1);

always @(posedge clk or negedge cpu_rst_n)
    if (!cpu_rst_n) begin
        frame_t <= 17'd0;
        int_t   <= 6'd0;
        int_n   <= 1'b1;
        vs_prev <= 1'b1;
    end else begin
        vs_prev <= vsync_s[2];
        if (int_start) begin
            int_n <= 1'b0;
            int_t <= 6'd0;
        end else if (cen_raw && !int_n) begin
            int_t <= int_t + 6'd1;
            if (int_t == 6'd31) int_n <= 1'b1;
        end
        if (int_start)
            frame_t <= 17'd0;
        else if (cen_raw)
            frame_t <= frame_t + 17'd1;
    end

//-----------------------------------------------------------------------------
// Memory contention (Level 1, see the header)
//-----------------------------------------------------------------------------

wire       cont_on  = cont_s[1] & !turbo_s[2];
wire       in_scr   = vline >= 9'd63 && vline < 9'd255 && hpos < 8'd128;
wire [2:0] cdelay   = !in_scr ? 3'd0 : (hpos[2:1] == 2'b11) ? 3'd0 : 3'd6 - hpos[2:0];
wire       hi_c     = a_lat[15:14] == 2'b01;                                  // 4000-7FFF
wire       mem_c    = hi_c || (a_lat[15:14] == 2'b11 && p7ffd[0]);             // + odd page at C000
wire       io_c     = (hi_c && !a_lat[0] && io_k <= 3'd1) ||                  // C:1, C:3
                      (hi_c &&  a_lat[0]) ||                                  // C:1 x 4
                      (!hi_c && !a_lat[0] && io_k == 3'd1);                   // N:1, C:3

always @(posedge clk or negedge cpu_rst_n)
    if (!cpu_rst_n) begin
        hpos     <= 8'd3;
        vline    <= 9'd0;
        chk      <= 3'd0;
        io_k     <= 3'd0;
        cont_cnt <= 3'd0;
    end else begin
        if (int_start) begin
            hpos  <= 8'd3;
            vline <= 9'd0;
        end else if (cen_raw) begin
            if (hpos == 8'd227) begin
                hpos  <= 8'd0;
                vline <= vline == 9'd511 ? vline : vline + 9'd1;
            end else
                hpos <= hpos + 8'd1;
        end
        chk <= {chk[1:0], cen_d};
        if (mstart)     io_k <= 3'd0;
        else if (cen_d) io_k <= io_k + 3'd1;
        // 2 clocks after the cen (smp_io / smp_nr known), before the next cen can come
        if (chk[1] && cont_on && !inta && (smp_io ? io_c : (io_k == 3'd0 && smp_nr && mem_c)))
            cont_cnt <= cdelay;
        else if (cen_raw && cont_cnt != 3'd0)
            cont_cnt <= cont_cnt - 3'd1;
    end

endmodule

`default_nettype wire
