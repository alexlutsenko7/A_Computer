//=============================================================================
// tb_ddr_test -- sdram_ram + ram_tester + W9825G6KH model
//
// IO delays are modelled (FPGA clock-to-out and board delays), because the
// read capture edge only works with realistic delays.
//   +define+TCO=<ns>   FPGA output delay for clock and command/data pins
//   +define+SD_SHIFT=<ns> extra SDRAM clock delay from PLL c1 (as SD_PHASE_PS in DDR_TEST.v)
//   +define+CLK_MHZ=<n>   system clock (112)
//   +define+PASSES=<n> passes to run (default 2; pass 2 checks error injection)
//=============================================================================
`timescale 1ns/1ps

`ifndef TCO
 `define TCO 4.0
`endif
`ifndef PASSES
 `define PASSES 2
`endif
`ifndef SD_SHIFT
 `define SD_SHIFT 1.339
`endif
`ifndef CLK_MHZ
 `define CLK_MHZ 112
`endif

module tb_ddr_test;

localparam real TCO   = `TCO;
localparam real TBACK = 0.5;   // SDRAM -> FPGA board + input delay
localparam real SD_SHIFT = `SD_SHIFT;
localparam real T_CK     = 1000.0 / `CLK_MHZ;

reg clk = 0;
always #(T_CK / 2) clk = ~clk;

reg rst_n = 0;
initial #100 rst_n = 1;

// controller <-> tester
wire        req, we, ack, ready;
localparam integer AW = 18;
wire [AW-1:0] addr;
wire [7:0]  din, dout;
reg         inject = 0;
wire        error, pass_tick;
wire [15:0] pass_count;
wire [AW-1:0] fail_addr;
wire [7:0]  fail_exp, fail_got;

// controller <-> pins
wire        cke, cs_n, ras_n, cas_n, we_n;
wire [1:0]  ba, dqm;
wire [12:0] a;
wire [15:0] dq_o;
wire        dq_oe;
reg  [15:0] dq_i;

sdram_ram #(.ADDR_BITS(AW), .CLK_MHZ(`CLK_MHZ)) u_ram (
    .clk(clk), .rst_n(rst_n),
    .req(req), .we(we), .addr(addr), .din(din), .dout(dout), .ack(ack), .ready(ready),
    .sd_cke(cke), .sd_cs_n(cs_n), .sd_ras_n(ras_n), .sd_cas_n(cas_n), .sd_we_n(we_n),
    .sd_ba(ba), .sd_a(a), .sd_dqm(dqm), .sd_dq_o(dq_o), .sd_dq_oe(dq_oe), .sd_dq_i(dq_i)
);

ram_tester #(.ADDR_BITS(AW)) u_test (
    .clk(clk), .rst_n(rst_n), .ram_ready(ready),
    .req(req), .we(we), .addr(addr), .wdata(din), .rdata(dout), .ack(ack),
    .inject(inject), .error(error), .pass_tick(pass_tick), .pass_count(pass_count),
    .fail_addr(fail_addr), .fail_exp(fail_exp), .fail_got(fail_got)
);

// pins as seen by the SDRAM (transport delays)
reg         m_clk = 0, m_cke = 0, m_cs_n = 1, m_ras_n = 1, m_cas_n = 1, m_we_n = 1;
reg  [1:0]  m_ba = 0, m_dqm = 3;
reg  [12:0] m_a = 0;
reg  [15:0] m_dq_drv = 'z;
wire [15:0] m_dq;

always @(clk)                                         m_clk <= #(TCO + SD_SHIFT) ~clk;   // DDIO: h=0, l=1
always @(cke, cs_n, ras_n, cas_n, we_n, ba, a, dqm)   {m_cke, m_cs_n, m_ras_n, m_cas_n, m_we_n, m_ba, m_a, m_dqm}
                                                         <= #(TCO) {cke, cs_n, ras_n, cas_n, we_n, ba, a, dqm};
always @(dq_oe, dq_o)                                 m_dq_drv <= #(TCO) (dq_oe ? dq_o : 16'hzzzz);
assign m_dq = m_dq_drv;
always @(m_dq)                                        dq_i <= #(TBACK) m_dq;

sdram_model #(.T_CK(T_CK)) u_sdram (
    .clk(m_clk), .cke(m_cke), .cs_n(m_cs_n), .ras_n(m_ras_n), .cas_n(m_cas_n), .we_n(m_we_n),
    .ba(m_ba), .a(m_a), .dqm(m_dqm), .dq(m_dq)
);

// bus contention: FPGA and SDRAM both driving
always @(m_dq_drv, u_sdram.dq_drv)
    if (m_dq_drv !== 16'hzzzz && u_sdram.dq_drv !== 16'hzzzz)
        $display("%t TB ERROR: DQ bus contention", $realtime);

//-----------------------------------------------------------------------------
// Latency statistics (cycles from req to ack)
//-----------------------------------------------------------------------------
longint cyc = 0;
always @(posedge clk) cyc++;

longint t_req, rd_n = 0, wr_n = 0, rd_sum = 0, wr_sum = 0;
int     rd_min = 999, rd_max = 0, wr_min = 999, wr_max = 0;
int     rd_hist [0:31];
bit     cur_we;
int     rd_bad = 0;          // strict (X-aware) read check, independent of the tester
bit     inject_seen = 0;
always @(posedge clk) if (inject) inject_seen <= 1;
initial foreach (rd_hist[k]) rd_hist[k] = 0;

always @(posedge clk) begin
    if (req) begin t_req = cyc; cur_we = we; end
    if (ack) begin
        automatic int l = cyc - t_req;
        if (cur_we) begin
            wr_n++; wr_sum += l;
            if (l < wr_min) wr_min = l;
            if (l > wr_max) wr_max = l;
        end else begin
            if (dout !== u_test.exp_d && !inject_seen) begin
                rd_bad++;
                if (rd_bad <= 10)
                    $display("%t TB ERROR: read addr=%h exp=%h got=%h", $realtime, addr, u_test.exp_d, dout);
            end
            rd_n++; rd_sum += l;
            if (l < rd_min) rd_min = l;
            if (l > rd_max) rd_max = l;
            rd_hist[l > 31 ? 31 : l]++;
        end
    end
end

task automatic report;
    $display("---------------------------------------------------------------");
    $display(" passes=%0d  tester error=%0d  tb read errors=%0d  model errors=%0d",
             pass_count, error, rd_bad, u_sdram.errors);
    $display(" writes: %0d  latency min/avg/max = %0d / %0.2f / %0d clk",
             wr_n, wr_min, real'(wr_sum) / wr_n, wr_max);
    $display(" reads : %0d  latency min/avg/max = %0d / %0.2f / %0d clk",
             rd_n, rd_min, real'(rd_sum) / rd_n, rd_max);
    for (int k = 0; k < 32; k++)
        if (rd_hist[k]) $display("   read latency %2d clk : %0d", k, rd_hist[k]);
    $display(" SDRAM cmds: ACT=%0d PRE=%0d RD=%0d WR=%0d REF=%0d  max REF gap=%0.1f ns",
             u_sdram.n_act, u_sdram.n_pre, u_sdram.n_rd, u_sdram.n_wr, u_sdram.n_ref, u_sdram.max_ref_gap);
    $display("---------------------------------------------------------------");
endtask

//-----------------------------------------------------------------------------
// Sequence
//-----------------------------------------------------------------------------
initial begin
    $display("TB: CLK=%0d MHz, TCO=%0.2f ns, SD_SHIFT=%0.2f ns, PASSES=%0d", `CLK_MHZ, TCO, SD_SHIFT, `PASSES);
    wait (ready);
    $display("%t TB: controller ready", $realtime);

    wait (pass_count == 1);
    report();
    if (error || rd_bad || u_sdram.errors) begin
        $display("TB RESULT: FAIL (pass 1, addr=%h exp=%h got=%h)", fail_addr, fail_exp, fail_got);
        $finish;
    end

    if (`PASSES >= 2) begin
        // pass 2: inject one error, the tester must catch it
        @(posedge clk); inject <= 1;
        @(posedge clk); inject <= 0;
        wait (pass_count == 2);
        report();
        if (!error || u_sdram.errors) begin
            $display("TB RESULT: FAIL (injected error not detected or model errors)");
            $finish;
        end
        $display("TB: injected error caught at addr=%h exp=%h got=%h", fail_addr, fail_exp, fail_got);
    end
    $display("TB RESULT: PASS");
    $finish;
end

// safety timeout
initial begin
    #(200ms);
    $display("TB RESULT: FAIL (timeout)");
    $finish;
end

endmodule
