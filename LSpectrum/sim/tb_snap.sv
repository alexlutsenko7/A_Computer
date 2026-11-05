//=============================================================================
// tb_snap -- snapshot freeze / restore of zx_bus with the real T80
//
// zx_bus + sdram_ram + SDRAM model (I/O delays as tb_lspectrum) + JT49. The Z80
// test program (mk_snapprog.py) is placed in ROM 0. It runs three times from reset:
//   run 0  undisturbed
//   run 1  frozen at random moments; each freeze reads all registers, the state
//          word, the AY registers (then restores the AY select), random RAM bytes
//          (compared with the SDRAM model) and writes screen bytes the program
//          never touches (checked against the video shadow at the end)
//   run 2  as run 1, and every freeze also restores everything it read: register
//          words -> DIR (PC - 1 in HALT, as esp32_v2/src/snap.cpp) -> LOAD (the T80 is reset),
//          7FFD/border/MIC/beeper, AY registers and select
// Runs 1 and 0 must end identical (RAM incl. R stored by the program, registers,
// AY). Run 2 must too, except what depends on the exact interrupt timing (each
// LOAD costs one T-state, the T80's reset state): the interrupt counter, the stack
// area, R.
//
//   +define+TURBO=0|1   (default 1)    +define+FREEZES=n  freezes per run (default 60)
//=============================================================================
`timescale 1ns/1ps

`ifndef TURBO
 `define TURBO 1
`endif
`ifndef FREEZES
 `define FREEZES 60
`endif

module tb_snap;

localparam realtime H = 4.464;
localparam real T_CK  = 2 * H;
localparam real TCO   = 4.0;
localparam real TBACK = 0.5;
localparam real SD_SHIFT = 1.339;

reg clk = 0, clk56 = 0;
always #(H) clk = ~clk;
initial begin #(H); forever begin clk56 = ~clk56; #(2 * H); end end

reg rst_n = 0, run = 0, ram_rst_n = 0;
initial #200 ram_rst_n = 1;

//-----------------------------------------------------------------------------
// SDRAM
//-----------------------------------------------------------------------------
wire        cke, cs_n, ras_n, cas_n, we_n, dq_oe;
wire [1:0]  ba, dqm;
wire [12:0] a;
wire [15:0] dq_o;
reg  [15:0] dq_i;
wire        bus_req, bus_we, ram_ack, ram_ready;
wire [17:0] bus_addr;
wire [7:0]  bus_din, ram_dout;

sdram_ram #(.ADDR_BITS(18), .CLK_MHZ(112)) u_ram (
    .clk(clk), .rst_n(ram_rst_n), .req(bus_req), .we(bus_we), .addr(bus_addr), .din(bus_din), .wide(1'b0), .din_hi(8'd0), .dout_w(),
    .dout(ram_dout), .ack(ram_ack), .ready(ram_ready),
    .sd_cke(cke), .sd_cs_n(cs_n), .sd_ras_n(ras_n), .sd_cas_n(cas_n), .sd_we_n(we_n),
    .sd_ba(ba), .sd_a(a), .sd_dqm(dqm), .sd_dq_o(dq_o), .sd_dq_oe(dq_oe), .sd_dq_i(dq_i)
);

reg         m_clk = 0, m_cke = 0, m_cs_n = 1, m_ras_n = 1, m_cas_n = 1, m_we_n = 1;
reg  [1:0]  m_ba = 0, m_dqm = 3;
reg  [12:0] m_a = 0;
reg  [15:0] m_dq_drv = 'z;
wire [15:0] m_dq;
always @(clk)                                         m_clk <= #(TCO + SD_SHIFT) ~clk;
always @(cke, cs_n, ras_n, cas_n, we_n, ba, a, dqm)   {m_cke, m_cs_n, m_ras_n, m_cas_n, m_we_n, m_ba, m_a, m_dqm}
                                                         <= #(TCO) {cke, cs_n, ras_n, cas_n, we_n, ba, a, dqm};
always @(dq_oe, dq_o)                                 m_dq_drv <= #(TCO) (dq_oe ? dq_o : 16'hzzzz);
assign m_dq = m_dq_drv;
always @(m_dq)                                        dq_i <= #(TBACK) m_dq;

sdram_model #(.T_CK(T_CK)) u_sdram (
    .clk(m_clk), .cke(m_cke), .cs_n(m_cs_n), .ras_n(m_ras_n), .cas_n(m_cas_n), .we_n(m_we_n),
    .ba(m_ba), .a(m_a), .dqm(m_dqm), .dq(m_dq)
);

function automatic [23:0] sd_key(input [17:0] ad);
    sd_key = {ad[11:10], 7'd0, ad[17:12], ad[9:1]};
endfunction

function automatic [7:0] sd_peek(input [17:0] ad);
    logic [15:0] w;
    begin
        w = u_sdram.mem.exists(sd_key(ad)) ? u_sdram.mem[sd_key(ad)] : 16'h0000;
        sd_peek = ad[0] ? w[15:8] : w[7:0];
    end
endfunction

task automatic sd_poke(input [17:0] ad, input [7:0] v);
    logic [15:0] w;
    begin
        w = u_sdram.mem.exists(sd_key(ad)) ? u_sdram.mem[sd_key(ad)] : 16'h0000;
        if (ad[0]) w[15:8] = v; else w[7:0] = v;
        u_sdram.mem[sd_key(ad)] = w;
    end
endtask

//-----------------------------------------------------------------------------
// Machine: bus + CPU + AY
//-----------------------------------------------------------------------------
reg         snap_freeze = 0, snap_req = 0;
reg  [3:0]  snap_cmd = 0;
reg  [17:0] snap_addr = 0;
reg  [31:0] snap_wdata = 0;
wire        snap_frozen, snap_ack;
wire [31:0] snap_rdata;
wire        sh_we, sh_page7, ay_bdir, ay_bc1, mic, beeper, cen_tgl;
wire [12:0] sh_addr;
wire [7:0]  sh_data, ay_din, ay_dout;
wire [2:0]  border;

zx_bus #(.FRAME_T(1500)) u_bus (
    .clk(clk), .rst_n(rst_n), .run(run), .turbo(1'b`TURBO), .diag_key(1'b0), .vid50(1'b0), .vsync_n(1'b1),
    .kb_rows({40{1'b1}}), .joy(5'd0), .ltape_on(1'b0), .ltape_lvl(1'b0),
    .cen_tgl(cen_tgl), .hold(1'b0), .mic(mic),
    .sd_req(bus_req), .sd_we(bus_we), .sd_addr(bus_addr), .sd_din(bus_din), .sd_dout(ram_dout), .sd_ack(ram_ack),
    .sh_we(sh_we), .sh_page7(sh_page7), .sh_addr(sh_addr), .sh_data(sh_data),
    .ay_bdir(ay_bdir), .ay_bc1(ay_bc1), .ay_din(ay_din), .ay_dout(ay_dout),
    .border(border), .screen7(), .beeper(beeper), .diag_rom(), .cpu_running(),
    .snap_freeze(snap_freeze), .snap_req(snap_req), .snap_cmd(snap_cmd), .snap_addr(snap_addr),
    .snap_wdata(snap_wdata), .snap_frozen(snap_frozen), .snap_ack(snap_ack), .snap_rdata(snap_rdata),
    .cont_en(1'b1)
);

reg ay_cen = 0;
always @(posedge clk) ay_cen <= !ay_cen;
jt49_bus u_ay (
    .rst_n(rst_n), .clk(clk), .clk_en(ay_cen), .bdir(ay_bdir), .bc1(ay_bc1), .din(ay_din), .sel(1'b0),
    .dout(ay_dout), .sound(), .A(), .B(), .C(), .sample(), .IOA_in(8'hFF), .IOA_out(), .IOB_in(8'hFF), .IOB_out()
);

// screen shadow model (what zx_video would hold)
reg [7:0] sh5 [0:8191], sh7 [0:8191];
always @(posedge clk) if (sh_we) begin
    if (sh_page7) sh7[sh_addr] <= sh_data; else sh5[sh_addr] <= sh_data;
end

//-----------------------------------------------------------------------------
// Snapshot port driver (as tape_loader: 56 MHz, acknowledge synchronised)
//-----------------------------------------------------------------------------
reg [1:0] sack_s = 0, sfrz_s = 0;
always @(posedge clk56) begin sack_s <= {sack_s[0], snap_ack}; sfrz_s <= {sfrz_s[0], snap_frozen}; end

integer errors = 0;

task automatic cmd(input [3:0] c, input [17:0] ad, input [31:0] d, output [31:0] r);
    begin
        @(posedge clk56);
        snap_wdata <= d;
        @(posedge clk56);
        snap_cmd  <= c;
        snap_addr <= ad;
        snap_req  <= !snap_req;
        @(posedge clk56);
        @(posedge clk56);
        while (snap_req != sack_s[1]) @(posedge clk56);
        r = snap_rdata;
    end
endtask

//-----------------------------------------------------------------------------
// Program, runs, checks
//-----------------------------------------------------------------------------
reg  [7:0]  prog [0:4095];
integer     prog_len;
reg  [7:0]  ram_end [0:2][0:131071];
reg  [31:0] regs_end [0:2][0:6];
reg  [7:0]  ay_end [0:2][0:15];
reg  [7:0]  wrote [0:511];                  // screen bytes written by the driver (page 5/7 offset 1A00-1AFF)
integer     n_frz, n_halt, n_load, n_ldir;
reg         in_run = 0;

// sanity: CPU must never move while frozen
always @(posedge clk) if (u_bus.frz_q && u_bus.cen) begin errors++; $display("%t ERROR: cen while frozen", $realtime); end

task automatic freeze_and_check(input integer mode);
    reg [31:0] r, w [0:6], st;
    reg [7:0]  ayv [0:15];
    reg [17:0] ad;
    integer    i, t;
    reg [7:0]  v;
    begin
        snap_freeze <= 1;
        t = 0;
        while (!sfrz_s[1]) begin @(posedge clk56); t++; if (t > 5000) begin errors++; $display("%t ERROR: no freeze", $realtime); disable freeze_and_check; end end
        n_frz++;
        if (u_bus.cpu_mc !== 3'd1 || u_bus.cpu_ts !== 3'd2) begin errors++; $display("%t ERROR: frozen in M%0d T%0d", $realtime, u_bus.cpu_mc, u_bus.cpu_ts); end
        for (i = 0; i < 7; i++) begin
            cmd(3, i, 0, w[i]);
            if (w[i] !== (i == 6 ? {12'd0, u_bus.cpu_regs[211:192]} : u_bus.cpu_regs[32 * i +: 32])) begin
                errors++; $display("%t ERROR: REG word %0d = %08h", $realtime, i, w[i]);
            end
        end
        cmd(10, 0, 0, st);
        if (st[24]) n_halt++;
        if (sd_peek(18'h20000 + w[2][15:0]) == 8'hED && sd_peek(18'h20000 + w[2][15:0] + 1) == 8'hB0) n_ldir++;
        if (st[7:0] !== u_bus.p7ffd || st[10:8] !== border || st[23:16] !== u_bus.ay_sel) begin errors++; $display("%t ERROR: STATE %08h", $realtime, st); end
        for (i = 0; i < 16; i++) begin cmd(6, i, 0, r); ayv[i] = r[7:0]; end
        for (i = 0; i < 20; i++) begin                            // RAM reads vs the model
            ad = $urandom_range(18'h1FFFF, 0);
            cmd(1, ad, 0, r);
            if (r[7:0] !== sd_peek(ad)) begin errors++; $display("%t ERROR: MRD %05h = %02h, model %02h", $realtime, ad, r[7:0], sd_peek(ad)); end
        end
        for (i = 0; i < 4; i++) begin                             // screen bytes (attributes 1A00-1AFF of page 5 / 7)
            t = $urandom_range(511, 0);
            v = $urandom;
            ad = (t < 256 ? 18'h14000 : 18'h1C000) + 18'h1A00 + t % 256;
            cmd(2, ad, v, r);
            wrote[t] = v;
        end
        if (mode == 2) begin                                      // restore everything
            w[2][15:0] = st[24] ? w[2][15:0] - 16'd1 : w[2][15:0];
            for (i = 0; i < 7; i++) cmd(4, i, w[i], r);
            cmd(5, 0, 0, r);
            n_load++;
            cmd(9, 0, {19'd0, beeper, mic, st[10:0]}, r);
            for (i = 0; i < 16; i++) cmd(7, i, ayv[i], r);
        end
        cmd(8, 0, st[23:16], r);                                  // AY select back
        snap_freeze <= 0;
        @(posedge clk56);
    end
endtask

task automatic one_run(input integer mode);
    integer i, k;
    begin
        rst_n = 0; run = 0;
        u_sdram.mem.delete();
        for (i = 0; i < prog_len; i++) sd_poke(18'h20000 + i, prog[i]);
        for (i = 0; i < 8192; i++) begin sh5[i] = 0; sh7[i] = 0; end
        for (i = 0; i < 512; i++) wrote[i] = 0;
        n_frz = 0; n_halt = 0; n_load = 0; n_ldir = 0;
        repeat (20) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge clk);
        run = 1;
        k = 0;
        while (sd_peek(18'h09FFF) !== 8'h55) begin
            if (mode && k < `FREEZES) begin
                repeat ($urandom_range(3000, 50)) @(posedge clk56);
                if (sd_peek(18'h09FFF) !== 8'h55) freeze_and_check(mode);
                k++;
            end else
                repeat (100) @(posedge clk);
        end
        repeat (2000) @(posedge clk);                              // DI + HALT
        snap_freeze <= 1;
        while (!sfrz_s[1]) @(posedge clk56);
        for (i = 0; i < 7; i++) cmd(3, i, 0, regs_end[mode][i]);
        snap_freeze <= 0;
        for (i = 0; i < 131072; i++) ram_end[mode][i] = sd_peek(i);
        for (i = 0; i < 16; i++) ay_end[mode][i] = u_ay.u_jt49.regarray[i];
        // the screen shadow follows every write to pages 5 / 7 (CPU and snapshot commands)
        for (i = 0; i < 6912; i++) begin
            if (sh5[i] !== sd_peek(18'h14000 + i)) begin errors++; if (errors < 10) $display("ERROR: shadow 5 %04h", i); end
            if (sh7[i] !== sd_peek(18'h1C000 + i)) begin errors++; if (errors < 10) $display("ERROR: shadow 7 %04h", i); end
        end
        for (i = 0; i < 512; i++)
            if (sd_peek((i < 256 ? 18'h14000 : 18'h1C000) + 18'h1A00 + i % 256) !== wrote[i]) begin
                errors++; $display("ERROR: written screen byte %0d lost", i);
            end
        $display("%t run %0d done: %0d freezes (%0d in HALT, %0d inside LDIR), %0d LOADs, INTs %0d, checksum %02h%02h, PC %04h",
                 $realtime, mode, n_frz, n_halt, n_ldir, n_load,
                 {ram_end[mode][16'h9E01], ram_end[mode][16'h9E00]}, ram_end[mode][16'h9F01], ram_end[mode][16'h9F00], regs_end[mode][2][15:0]);
    end
endtask

function automatic bit skip(input integer ad, input integer mode);
    skip = (ad >= 18'h14000 + 18'h1A00 && ad < 18'h14000 + 18'h1B00) ||       // driver's screen bytes
           (ad >= 18'h1C000 + 18'h1A00 && ad < 18'h1C000 + 18'h1B00) ||
           (mode == 2 && ((ad >= 18'h09E00 && ad < 18'h09E02) ||               // INT counter
                          ad == 18'h09FFE ||                                   // R
                          (ad >= 18'h0BE00 && ad < 18'h0BF00)));               // stack
endfunction

task automatic compare(input integer m);
    integer i, bad;
    begin
        bad = 0;
        for (i = 0; i < 131072; i++)
            if (!skip(i, m) && ram_end[m][i] !== ram_end[0][i]) begin
                bad++; if (bad <= 8) $display("  ERROR run %0d: RAM %05h = %02h, run 0: %02h", m, i, ram_end[m][i], ram_end[0][i]);
            end
        // R: not here (the endless HALT at the end adds M1 cycles until the testbench looks;
        // the program stores R at 9FFE before it)
        for (i = 0; i < 7; i++)
            if ((i == 1 ? regs_end[m][i] & 32'hFFFF00FF : regs_end[m][i]) !==
                (i == 1 ? regs_end[0][i] & 32'hFFFF00FF : regs_end[0][i])) begin
                bad++; $display("  ERROR run %0d: register word %0d = %08h, run 0: %08h", m, i, regs_end[m][i], regs_end[0][i]);
            end
        for (i = 0; i < 16; i++)
            if (ay_end[m][i] !== ay_end[0][i]) begin bad++; $display("  ERROR run %0d: AY R%0d = %02h, run 0: %02h", m, i, ay_end[m][i], ay_end[0][i]); end
        $display("run %0d vs run 0: %0d differences", m, bad);
        errors += bad;
    end
endtask

initial begin
    integer f, c;
    f = $fopen("snap_prog.hex", "r");
    prog_len = 0;
    while ($fscanf(f, "%h\n", c) == 1) begin prog[prog_len] = c; prog_len++; end
    $fclose(f);
    $display("TURBO=%0d, program %0d bytes", `TURBO, prog_len);
    wait (ram_ready === 1'b1);
    one_run(0);
    one_run(1);
    one_run(2);
    compare(1);
    compare(2);
    if (u_sdram.errors) errors++;
    if (errors) $display("FAIL (%0d errors)", errors); else $display("SNAPSHOT TEST PASSED");
    $finish;
end

// progress: PC of the last opcode fetch, interrupts, loop counter
reg [15:0] last_pc = 0;
integer    n_int = 0;
always @(posedge clk) if (u_bus.mstart && !u_bus.cpu_m1_n) last_pc = u_bus.cpu_a;
always @(negedge u_bus.int_n) n_int++;
`ifdef TRACE
always #(`TRACE) $display("%t PC~%04h INTs %0d loop %02h ready %0d run %0d frozen %0d", $realtime, last_pc, n_int, sd_peek(18'h09F02), ram_ready, run, u_bus.frz_q);
`endif

initial begin #(`ifdef TMAX `TMAX `else 400_000_000 `endif); $display("TIMEOUT"); $finish; end

endmodule
