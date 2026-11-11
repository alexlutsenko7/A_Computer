/* tb_snap -- snapshot freeze / restore of zx_bus with the real T80 */
/* */
/* zx_bus + sdram_ram + SDRAM model (I/O delays as tb_lspectrum) + JT49. The Z80 */
/* test program (mk_snapprog.py) is placed in ROM 0. It runs three times from reset: */
/* run 0  undisturbed */
/* run 1  frozen at random moments; each freeze reads all registers, the state */
/* word, the AY registers (then restores the AY select), random RAM bytes */
/* (compared with the SDRAM model) and writes screen bytes the program */
/* never touches (checked against the video shadow at the end) */
/* run 2  as run 1, and every freeze also restores everything it read: register */
/* words -> DIR (PC - 1 in HALT, as ESP32/v2/src/snap.cpp) -> LOAD (the T80 is reset), */
/* 7FFD/border/MIC/beeper, AY registers and select */
/* Runs 1 and 0 must end identical (RAM incl. R stored by the program, registers, */
/* AY). Run 2 must too, except what depends on the exact interrupt timing (each */
/* LOAD costs one T-state, the T80's reset state): the interrupt counter, the stack */
/* area, R. */
/* */
/* +define+TURBO=0|1   (default 1)    +define+FREEZES=n  freezes per run (default 60) */
`timescale 1ns/1ps

/* defaults of the command line switches */
`ifndef TURBO
 `define TURBO 1
`endif
/* freezes of the snapshot test */
`ifndef FREEZES
 `define FREEZES 60
`endif

/* the testbench; half a period of the 112 MHz clock */
module tb_snap;

/* half periods of a clock period */
localparam integer HALVES = 2;
/* the SDRAM controller's reset ends after 200 ns */
localparam integer RAM_RST_NS = 200;
/* both data masks high */
localparam integer DQM_OFF = 3;
/* keys of the Spectrum matrix */
localparam integer MATRIX_KEYS = 40;
/* clk56 clocks a freeze may take */
localparam integer FREEZE_MAX = 5000;
/* T-state 2 */
localparam [2:0] TS_T2 = 3'd2;
/* register words of the CPU */
localparam integer REG_WORDS = 7;
/* index of the last register word */
localparam integer REG_WORD_LAST = 6;
/* SDRAM address of the ROM (the test program) */
localparam [17:0] ROM_BASE = 18'h20000;
/* prefix byte ED */
localparam [7:0] OP_ED = 8'hED;
/* second byte of LDIR */
localparam [7:0] OP_LDIR2 = 8'hB0;
/* registers of the AY */
localparam integer AY_REGS = 16;
/* random memory reads per freeze */
localparam integer MRD_CHECKS = 20;
/* last SDRAM address of the RAM */
localparam [17:0] RAM_LAST = 18'h1FFFF;
/* screen bytes written per freeze */
localparam integer SCR_WRITES = 4;
/* index of the last test byte */
localparam integer TEST_BYTE_LAST = 511;
/* test bytes per screen page */
localparam integer PAGE_ATTRS = 256;
/* SDRAM address of RAM page 5 */
localparam [17:0] PAGE5 = 18'h14000;
/* SDRAM address of RAM page 7 */
localparam [17:0] PAGE7 = 18'h1C000;
/* offset of the attribute bytes the test writes */
localparam [17:0] ATTR_TEST = 18'h1A00;
/* run mode 2: freezes with restores */
localparam integer MODE_RESTORE = 2;
/* bytes of a screen shadow memory */
localparam integer SHADOW_SIZE = 8192;
/* test bytes of both screen pages */
localparam integer TEST_BYTES = 512;
/* clocks of the reset */
localparam integer RESET_CLKS = 20;
/* clocks between the reset's end and the start */
localparam integer RUN_CLKS = 4;
/* the byte the program writes when it is done */
localparam [7:0] END_MARK = 8'h55;
/* longest time between two freezes, clk56 clocks */
localparam integer FREEZE_GAP_MAX = 3000;
/* shortest time between two freezes, clk56 clocks */
localparam integer FREEZE_GAP_MIN = 50;
/* clocks between two looks at the end mark, without freezes */
localparam integer IDLE_CLKS = 100;
/* clocks waited after the end mark */
localparam integer END_CLKS = 2000;
/* bytes of the 128 KB RAM */
localparam integer RAM_SIZE = 131072;
/* bytes of a screen */
localparam integer SCREEN_BYTES = 6912;
/* shadow errors listed */
localparam integer SHADOW_LIST_MAX = 10;
/* first offset after those bytes */
localparam [17:0] ATTR_TEST_END = 18'h1B00;
/* SDRAM address of the program's checksum */
localparam [17:0] CHK_ADDR = 18'h09E00;
/* first address after the checksum */
localparam [17:0] CHK_END = 18'h09E02;
/* SDRAM address where the program stores R */
localparam [17:0] R_COPY = 18'h09FFE;
/* first SDRAM address of the stack area */
localparam [17:0] STACK_FIRST = 18'h0BE00;
/* first address after the stack area */
localparam [17:0] STACK_END = 18'h0BF00;
/* RAM differences listed */
localparam integer RAM_LIST_MAX = 8;
/* register word 1 without the R register */
localparam [31:0] NOT_R = 32'hFFFF00FF;

localparam realtime H = 4.464;
localparam real T_CK  = 2 * H;
/* pin delays, the SDRAM clock's shift */
localparam real TCO   = 4.0;
localparam real TBACK = 0.5;
localparam real SD_SHIFT = 1.339;

/* 112 MHz */
reg clk = 0, clk56 = 0;
always #(H) clk = ~clk;
initial
begin
/* 56 MHz, rising edges aligned */
    #(H);
    forever
    begin
        clk56 = ~clk56;
/* every 112 MHz period */
        #(HALVES * H);
    end
end

/* resets */
reg rst_n = 0, run = 0, ram_rst_n = 0;
initial #RAM_RST_NS ram_rst_n = 1;

/* SDRAM */
wire        cke, cs_n, ras_n, cas_n, we_n, dq_oe;
wire [1:0]  ba, dqm;
wire [12:0] a;
/* data out and in */
wire [15:0] dq_o;
reg  [15:0] dq_i;
wire        bus_req, bus_we, ram_ack, ram_ready;
/* the bus's side of the controller */
wire [17:0] bus_addr;
wire [7:0]  bus_din, ram_dout;

sdram_ram #(.ADDR_BITS(18), .CLK_MHZ(112)) u_ram (
    .clk(clk), .rst_n(ram_rst_n), .req(bus_req), .we(bus_we), .addr(bus_addr), .din(bus_din), .wide(1'b0), .din_hi(8'd0), .dout_w(),
    .dout(ram_dout), .ack(ram_ack), .ready(ram_ready),
    .sd_cke(cke), .sd_cs_n(cs_n), .sd_ras_n(ras_n), .sd_cas_n(cas_n), .sd_we_n(we_n),
    .sd_ba(ba), .sd_a(a), .sd_dqm(dqm), .sd_dq_o(dq_o), .sd_dq_oe(dq_oe), .sd_dq_i(dq_i)
);

/* the pins as the SDRAM sees them (transport delays) */
reg         m_clk = 0, m_cke = 0, m_cs_n = 1, m_ras_n = 1, m_cas_n = 1, m_we_n = 1;
reg  [1:0]  m_ba = 0, m_dqm = DQM_OFF;
reg  [12:0] m_a = 0;
/* data */
reg  [15:0] m_dq_drv = 'z;
wire [15:0] m_dq;
always @(clk) m_clk <= #(TCO + SD_SHIFT) ~clk;
/* commands and address, delayed */
always @(cke, cs_n, ras_n, cas_n, we_n, ba, a, dqm)
    {m_cke, m_cs_n, m_ras_n, m_cas_n, m_we_n, m_ba, m_a, m_dqm}
       <= #(TCO) {cke, cs_n, ras_n, cas_n, we_n, ba, a, dqm};
/* the data bus, delayed */
always @(dq_oe, dq_o) m_dq_drv <= #(TCO) (dq_oe ? dq_o : 16'hzzzz);
assign m_dq = m_dq_drv;
/* data back, delayed; the model */
always @(m_dq) dq_i <= #(TBACK) m_dq;

sdram_model #(.T_CK(T_CK)) u_sdram (
    .clk(m_clk), .cke(m_cke), .cs_n(m_cs_n), .ras_n(m_ras_n), .cas_n(m_cas_n), .we_n(m_we_n),
    .ba(m_ba), .a(m_a), .dqm(m_dqm), .dq(m_dq)
);

/* the model's memory key of a byte address */
function automatic [23:0] sd_key(input [17:0] ad);
    sd_key = {ad[11:10], 7'd0, ad[17:12], ad[9:1]};
endfunction

/* a byte straight from the model */
function automatic [7:0] sd_peek(input [17:0] ad);
    logic [15:0] w;
    begin
        w = u_sdram.mem.exists(sd_key(ad)) ? u_sdram.mem[sd_key(ad)] : 16'h0000;
/* its lane */
        sd_peek = ad[0] ? w[15:8] : w[7:0];
    end
endfunction

/* a byte straight into the model */
task automatic sd_poke(input [17:0] ad, input [7:0] v);
    logic [15:0] w;
    begin
        w = u_sdram.mem.exists(sd_key(ad)) ? u_sdram.mem[sd_key(ad)] : 16'h0000;
/* the lane written */
        if (ad[0])
        begin
            w[15:8] = v;
        end
        else
        begin
            w[7:0] = v;
        end
/* back into the model */
        u_sdram.mem[sd_key(ad)] = w;
    end
endtask

/* Machine: bus + CPU + AY */
reg         snap_freeze = 0, snap_req = 0;
reg  [3:0]  snap_cmd = 0;
reg  [17:0] snap_addr = 0;
/* data and answers */
reg  [31:0] snap_wdata = 0;
wire        snap_frozen, snap_ack;
wire [31:0] snap_rdata;
/* shadow port, AY bus, the ULA's outputs */
wire        sh_we, sh_page7, ay_bdir, ay_bc1, mic, beeper, cen_tgl;
wire [12:0] sh_addr;
wire [7:0]  sh_data, ay_din, ay_dout;
/* the border; the bus with the CPU */
wire [2:0]  border;

zx_bus #(.FRAME_T(1500)) u_bus (
    .clk(clk), .rst_n(rst_n), .run(run), .turbo(1'b`TURBO), .diag_key(1'b0), .vid50(1'b0), .vsync_n(1'b1),
    .kb_rows({MATRIX_KEYS{1'b1}}), .joy(5'd0), .ltape_on(1'b0), .ltape_lvl(1'b0),
    .cen_tgl(cen_tgl), .hold(1'b0), .mic(mic),
    .sd_req(bus_req), .sd_we(bus_we), .sd_addr(bus_addr), .sd_din(bus_din), .sd_dout(ram_dout), .sd_ack(ram_ack),
    .sh_we(sh_we), .sh_page7(sh_page7), .sh_addr(sh_addr), .sh_data(sh_data),
    .ay_bdir(ay_bdir), .ay_bc1(ay_bc1), .ay_din(ay_din), .ay_dout(ay_dout),
    .border(border), .screen7(), .beeper(beeper), .diag_rom(), .cpu_running(),
    .snap_freeze(snap_freeze), .snap_req(snap_req), .snap_cmd(snap_cmd), .snap_addr(snap_addr),
    .snap_wdata(snap_wdata), .snap_frozen(snap_frozen), .snap_ack(snap_ack), .snap_rdata(snap_rdata),
    .cont_en(1'b1)
);

/* the AY at half the clock */
reg ay_cen = 0;
always @(posedge clk) ay_cen <= !ay_cen;
jt49_bus u_ay (
    .rst_n(rst_n), .clk(clk), .clk_en(ay_cen), .bdir(ay_bdir), .bc1(ay_bc1), .din(ay_din), .sel(1'b0),
    .dout(ay_dout), .sound(), .A(), .B(), .C(), .sample(), .IOA_in(8'hFF), .IOA_out(), .IOB_in(8'hFF), .IOB_out()
);

/* screen shadow model (what zx_video would hold) */
reg [7:0] sh5 [0:8191], sh7 [0:8191];
always @(posedge clk)
    if (sh_we)
    begin
/* page 7 or page 5 */
        if (sh_page7)
        begin
            sh7[sh_addr] <= sh_data;
        end
        else
        begin
            sh5[sh_addr] <= sh_data;
        end
    end

/* Snapshot port driver (as tape_loader: 56 MHz, acknowledge synchronised) */
reg [1:0] sack_s = 0, sfrz_s = 0;
always @(posedge clk56)
begin
/* acknowledge and frozen flag, synchronised */
    sack_s <= {sack_s[0], snap_ack};
    sfrz_s <= {sfrz_s[0], snap_frozen};
end

/* errors counted */
integer errors = 0;

task automatic cmd(input [3:0] c, input [17:0] ad, input [31:0] d, output [31:0] r);
    begin
/* one command: data first, then the request toggles */
        @(posedge clk56);
        snap_wdata <= d;
        @(posedge clk56);
/* command, address */
        snap_cmd  <= c;
        snap_addr <= ad;
        snap_req  <= !snap_req;
/* the acknowledge is waited for */
        @(posedge clk56);
        @(posedge clk56);
        while (snap_req != sack_s[1])
        begin
/* one more clock */
            @(posedge clk56);
        end
/* the answer */
        r = snap_rdata;
    end
endtask

/* Program, runs, checks */
reg  [7:0]  prog [0:4095];
integer     prog_len;
/* what each of the three runs ends with: RAM, registers, AY */
reg  [7:0]  ram_end [0:2][0:131071];
reg  [31:0] regs_end [0:2][0:6];
reg  [7:0]  ay_end [0:2][0:15];
/* screen bytes written by the driver (page 5/7 offset 1A00-1AFF) */
reg  [7:0]  wrote [0:511];
integer     n_frz, n_halt, n_load, n_ldir;
reg         in_run = 0;

/* sanity: CPU must never move while frozen */
always @(posedge clk)
    if (u_bus.frz_q && u_bus.cen)
    begin
        errors++;
/* reported */
        $display("%t ERROR: cen while frozen", $realtime);
    end

/* a freeze at a random point: everything is read and checked, in mode 2 loaded back */
task automatic freeze_and_check(input integer mode);
    reg [31:0] r, w [0:6], st;
    reg [7:0]  ayv [0:15];
/* address, counters, a byte */
    reg [17:0] ad;
    integer    i, t;
    reg [7:0]  v;
    begin
/* the freeze is asked for */
        snap_freeze <= 1;
        t = 0;
        while (!sfrz_s[1])
        begin
/* waited for, with a limit */
            @(posedge clk56);
            t++;
            if (t > FREEZE_MAX)
            begin
/* never frozen */
                errors++;
                $display("%t ERROR: no freeze", $realtime);
                disable freeze_and_check;
            end
        end
/* counted; it must be M1 T2 */
        n_frz++;
        if (u_bus.cpu_mc !== 3'd1 || u_bus.cpu_ts !== TS_T2)
        begin
/* not at an instruction boundary */
            errors++;
            $display("%t ERROR: frozen in M%0d T%0d", $realtime, u_bus.cpu_mc, u_bus.cpu_ts);
        end
        for (i = 0; i < REG_WORDS; i++)
        begin
/* the seven register words */
            cmd(3, i, 0, w[i]);
            if (w[i] !== (i == REG_WORD_LAST ? {12'd0, u_bus.cpu_regs[211:192]} : u_bus.cpu_regs[32 * i +: 32]))
            begin
/* a wrong word */
                errors++;
                $display("%t ERROR: REG word %0d = %08h", $realtime, i, w[i]);
            end
        end
/* the machine state */
        cmd(10, 0, 0, st);
        if (st[24])
        begin
/* frozen in HALT */
            n_halt++;
        end
/* frozen inside LDIR */
        if (sd_peek(ROM_BASE + w[2][15:0]) == OP_ED && sd_peek(ROM_BASE + w[2][15:0] + 1) == OP_LDIR2)
        begin
            n_ldir++;
        end
/* paging, border, AY select */
        if (st[7:0] !== u_bus.p7ffd || st[10:8] !== border || st[23:16] !== u_bus.ay_sel)
        begin
            errors++;
/* reported */
            $display("%t ERROR: STATE %08h", $realtime, st);
        end
        for (i = 0; i < AY_REGS; i++)
        begin
/* the AY registers */
            cmd(6, i, 0, r);
            ayv[i] = r[7:0];
        end
/* RAM reads vs the model */
        for (i = 0; i < MRD_CHECKS; i++)
        begin
/* a random address */
            ad = $urandom_range(RAM_LAST, 0);
            cmd(1, ad, 0, r);
            if (r[7:0] !== sd_peek(ad))
            begin
/* a wrong byte */
                errors++;
                $display("%t ERROR: MRD %05h = %02h, model %02h", $realtime, ad, r[7:0], sd_peek(ad));
            end
        end
/* screen bytes (attributes 1A00-1AFF of page 5 / 7) */
        for (i = 0; i < SCR_WRITES; i++)
        begin
/* a random attribute byte of page 5 or 7 */
            t = $urandom_range(TEST_BYTE_LAST, 0);
            v = $urandom;
            ad = (t < PAGE_ATTRS ? PAGE5 : PAGE7) + ATTR_TEST + t % PAGE_ATTRS;
/* written; remembered */
            cmd(2, ad, v, r);
            wrote[t] = v;
        end
/* restore everything */
        if (mode == MODE_RESTORE)
        begin
/* a HALT is restarted: PC - 1 */
            w[2][15:0] = st[24] ? w[2][15:0] - 16'd1 : w[2][15:0];
            for (i = 0; i < REG_WORDS; i++)
            begin
/* the registers */
                cmd(4, i, w[i], r);
            end
/* LOAD; counted */
            cmd(5, 0, 0, r);
            n_load++;
/* the machine state */
            cmd(9, 0, {19'd0, beeper, mic, st[10:0]}, r);
            for (i = 0; i < AY_REGS; i++)
            begin
/* the AY */
                cmd(7, i, ayv[i], r);
            end
        end
/* AY select back */
        cmd(8, 0, st[23:16], r);
/* released */
        snap_freeze <= 0;
        @(posedge clk56);
    end
endtask

/* one run of the program: mode 0 free, 1 with freezes, 2 with freezes and restores */
task automatic one_run(input integer mode);
    integer i, k;
    begin
/* reset, empty memory */
        rst_n = 0;
        run = 0;
        u_sdram.mem.delete();
/* the program into the ROM's place */
        for (i = 0; i < prog_len; i++)
        begin
            sd_poke(18'h20000 + i, prog[i]);
        end
/* empty shadows */
        for (i = 0; i < SHADOW_SIZE; i++)
        begin
            sh5[i] = 0;
            sh7[i] = 0;
        end
/* nothing written yet */
        for (i = 0; i < TEST_BYTES; i++)
        begin
            wrote[i] = 0;
        end
/* counters */
        n_frz = 0;
        n_halt = 0;
        n_load = 0;
/* no LDIR seen */
        n_ldir = 0;
/* reset */
        repeat (RESET_CLKS)
        begin
/* reset, then run */
            @(posedge clk);
        end
/* reset, then run */
        rst_n = 1;
        repeat (RUN_CLKS)
        begin
/* the CPU starts */
            @(posedge clk);
        end
/* the CPU starts */
        run = 1;
/* until the program's end mark */
        k = 0;
        while (sd_peek(18'h09FFF) !== END_MARK)
        begin
/* freezes at random points */
            if (mode && k < `FREEZES)
            begin
                repeat ($urandom_range(FREEZE_GAP_MAX, FREEZE_GAP_MIN))
                begin
                    @(posedge clk56);
                end
/* not at the end yet */
                if (sd_peek(18'h09FFF) !== END_MARK)
                begin
                    freeze_and_check(mode);
                end
/* counted */
                k++;
            end
            else
            begin
/* no freezes: just wait */
                repeat (IDLE_CLKS)
                begin
                    @(posedge clk);
                end
            end
        end
/* DI + HALT */
        repeat (END_CLKS)
        begin
            @(posedge clk);
        end
/* the final freeze */
        snap_freeze <= 1;
        while (!sfrz_s[1])
        begin
            @(posedge clk56);
        end
/* the registers at the end */
        for (i = 0; i < REG_WORDS; i++)
        begin
            cmd(3, i, 0, regs_end[mode][i]);
        end
/* released; the RAM at the end */
        snap_freeze <= 0;
        for (i = 0; i < RAM_SIZE; i++)
        begin
            ram_end[mode][i] = sd_peek(i);
        end
/* the AY at the end */
        for (i = 0; i < AY_REGS; i++)
        begin
            ay_end[mode][i] = u_ay.u_jt49.regarray[i];
        end
/* the screen shadow follows every write to pages 5 / 7 (CPU and snapshot commands) */
        for (i = 0; i < SCREEN_BYTES; i++)
        begin
/* page 5 */
            if (sh5[i] !== sd_peek(PAGE5 + i))
            begin
                errors++;
/* the first ten are listed */
                if (errors < SHADOW_LIST_MAX)
                begin
                    $display("ERROR: shadow 5 %04h", i);
                end
            end
/* page 7 */
            if (sh7[i] !== sd_peek(PAGE7 + i))
            begin
                errors++;
/* the first ten are listed */
                if (errors < SHADOW_LIST_MAX)
                begin
                    $display("ERROR: shadow 7 %04h", i);
                end
            end
        end
/* the bytes written while frozen must still be there */
        for (i = 0; i < TEST_BYTES; i++)
        begin
            if (sd_peek((i < PAGE_ATTRS ? PAGE5 : PAGE7) + ATTR_TEST + i % PAGE_ATTRS) !== wrote[i])
            begin
/* lost */
                errors++;
                $display("ERROR: written screen byte %0d lost", i);
            end
        end
/* the summary of the run */
        $display("%t run %0d done: %0d freezes (%0d in HALT, %0d inside LDIR), %0d LOADs, INTs %0d, checksum %02h%02h, PC %04h",
                 $realtime, mode, n_frz, n_halt, n_ldir, n_load,
                 {ram_end[mode][16'h9E01], ram_end[mode][16'h9E00]}, ram_end[mode][16'h9F01], ram_end[mode][16'h9F00], regs_end[mode][2][15:0]);
    end
endtask

/* addresses that may differ between the runs */
function automatic bit skip(input integer ad, input integer mode);
/* driver's screen bytes */
    skip = (ad >= PAGE5 + ATTR_TEST && ad < PAGE5 + ATTR_TEST_END) ||
           (ad >= PAGE7 + ATTR_TEST && ad < PAGE7 + ATTR_TEST_END) ||
/* INT counter */
           (mode == MODE_RESTORE && ((ad >= CHK_ADDR && ad < CHK_END) ||
/* R */
                          ad == R_COPY ||
/* stack */
                          (ad >= STACK_FIRST && ad < STACK_END)));
endfunction

/* a run compared with run 0 */
task automatic compare(input integer m);
    integer i, bad;
    begin
/* RAM */
        bad = 0;
        for (i = 0; i < RAM_SIZE; i++)
        begin
/* a difference */
            if (!skip(i, m) && ram_end[m][i] !== ram_end[0][i])
            begin
                bad++;
/* the first eight are listed */
                if (bad <= RAM_LIST_MAX)
                begin
                    $display("  ERROR run %0d: RAM %05h = %02h, run 0: %02h", m, i, ram_end[m][i], ram_end[0][i]);
                end
            end
        end
/* R: not here (the endless HALT at the end adds M1 cycles until the testbench looks; */
/* the program stores R at 9FFE before it) */
        for (i = 0; i < REG_WORDS; i++)
        begin
/* the registers (R left out) */
            if ((i == 1 ? regs_end[m][i] & NOT_R : regs_end[m][i]) !==
                (i == 1 ? regs_end[0][i] & NOT_R : regs_end[0][i]))
            begin
/* a difference */
                bad++;
                $display("  ERROR run %0d: register word %0d = %08h, run 0: %08h", m, i, regs_end[m][i], regs_end[0][i]);
            end
        end
/* the AY */
        for (i = 0; i < AY_REGS; i++)
        begin
            if (ay_end[m][i] !== ay_end[0][i])
            begin
/* a difference */
                bad++;
                $display("  ERROR run %0d: AY R%0d = %02h, run 0: %02h", m, i, ay_end[m][i], ay_end[0][i]);
            end
        end
/* the sum */
        $display("run %0d vs run 0: %0d differences", m, bad);
        errors += bad;
    end
endtask

/* the test */
initial
begin
    integer f, c;
    f = $fopen("snap_prog.hex", "r");
/* the program's bytes */
    prog_len = 0;
    while ($fscanf(f, "%h\n", c) == 1)
    begin
/* next byte */
        prog[prog_len] = c;
        prog_len++;
    end
/* the file is read */
    $fclose(f);
    $display("TURBO=%0d, program %0d bytes", `TURBO, prog_len);
/* the three runs */
    wait (ram_ready === 1'b1);
    one_run(0);
    one_run(1);
/* with restores; compared */
    one_run(2);
    compare(1);
    compare(2);
/* the model's own errors */
    if (u_sdram.errors)
    begin
        errors++;
    end
/* the verdict */
    if (errors)
    begin
        $display("FAIL (%0d errors)", errors);
    end
    else
    begin
/* passed */
        $display("SNAPSHOT TEST PASSED");
    end
/* the end */
    $finish;
end

/* progress: PC of the last opcode fetch, interrupts, loop counter */
reg [15:0] last_pc = 0;
integer    n_int = 0;
/* the PC of the last fetch */
always @(posedge clk)
    if (u_bus.mstart && !u_bus.cpu_m1_n)
    begin
        last_pc = u_bus.cpu_a;
    end
/* interrupts counted */
always @(negedge u_bus.int_n) n_int++;
/* a trace line at intervals */
`ifdef TRACE
always #(`TRACE) $display("%t PC~%04h INTs %0d loop %02h ready %0d run %0d frozen %0d", $realtime, last_pc, n_int, sd_peek(18'h09F02), ram_ready, run, u_bus.frz_q);
`endif

/* the simulation's time limit, unless the command line gives one */
`ifndef TMAX
`define TMAX 400_000_000
`endif
/* the limit */
initial
begin
    #(`TMAX);
/* the simulation hangs */
    $display("TIMEOUT");
    $finish;
end

endmodule
