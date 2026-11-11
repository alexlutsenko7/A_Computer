/* tb_ddr_test -- sdram_ram + ram_tester + W9825G6KH model */
/* */
/* IO delays are modelled (FPGA clock-to-out and board delays), because the */
/* read capture edge only works with realistic delays. */
/* +define+TCO=<ns>   FPGA output delay for clock and command/data pins */
/* +define+SD_SHIFT=<ns> extra SDRAM clock delay from PLL c1 (as SD_PHASE_PS in DDR_TEST.v) */
/* +define+CLK_MHZ=<n>   system clock (112) */
/* +define+PASSES=<n> passes to run (default 2; pass 2 checks error injection) */
`timescale 1ns/1ps

/* output delay of the FPGA's pins in ns */
`ifndef TCO
 `define TCO 4.0
`endif
/* passes to run */
`ifndef PASSES
 `define PASSES 2
`endif
/* the SDRAM clock's shift in ns */
`ifndef SD_SHIFT
 `define SD_SHIFT 1.339
`endif
/* the controller's clock */
`ifndef CLK_MHZ
 `define CLK_MHZ 112
`endif

/* the testbench */
module tb_ddr_test;

/* half periods of a clock period */
localparam integer HALVES = 2;
/* the reset ends after 100 ns */
localparam integer RST_NS = 100;
/* both data masks high */
localparam integer DQM_OFF = 3;
/* start value of a minimum search */
localparam integer MIN_START = 999;
/* read errors listed */
localparam integer LIST_MAX = 10;
/* bins of the latency histogram */
localparam integer HIST_BINS = 32;
/* with two passes or more both kinds of phases have run */
localparam integer PASSES_FOR_BOTH = 2;

localparam real TCO   = `TCO;
/* SDRAM -> FPGA board + input delay */
localparam real TBACK = 0.5;
localparam real SD_SHIFT = `SD_SHIFT;
localparam real T_CK     = 1000.0 / `CLK_MHZ;

/* the clock */
reg clk = 0;
always #(T_CK / HALVES) clk = ~clk;

/* reset for 100 ns */
reg rst_n = 0;
initial #RST_NS rst_n = 1;

/* controller <-> tester */
wire        req, we, ack, ready;
localparam integer AW = 18;
wire [AW-1:0] addr;
/* data, the error injection, the tester's results */
wire [7:0]  din, dout;
reg         inject = 0;
wire        error, pass_tick;
/* passes, the first failure */
wire [15:0] pass_count;
wire [AW-1:0] fail_addr;
wire [7:0]  fail_exp, fail_got;

/* controller <-> pins */
wire        cke, cs_n, ras_n, cas_n, we_n;
wire [1:0]  ba, dqm;
wire [12:0] a;
/* data out, its enable, data in */
wire [15:0] dq_o;
wire        dq_oe;
reg  [15:0] dq_i;

/* the controller */
sdram_ram #(.ADDR_BITS(AW), .CLK_MHZ(`CLK_MHZ)) u_ram (
    .clk(clk), .rst_n(rst_n),
    .req(req), .we(we), .addr(addr), .din(din), .dout(dout), .ack(ack), .ready(ready),
    .sd_cke(cke), .sd_cs_n(cs_n), .sd_ras_n(ras_n), .sd_cas_n(cas_n), .sd_we_n(we_n),
    .sd_ba(ba), .sd_a(a), .sd_dqm(dqm), .sd_dq_o(dq_o), .sd_dq_oe(dq_oe), .sd_dq_i(dq_i)
);

/* the tester */
ram_tester #(.ADDR_BITS(AW)) u_test (
    .clk(clk), .rst_n(rst_n), .ram_ready(ready),
    .req(req), .we(we), .addr(addr), .wdata(din), .rdata(dout), .ack(ack),
    .inject(inject), .error(error), .pass_tick(pass_tick), .pass_count(pass_count),
    .fail_addr(fail_addr), .fail_exp(fail_exp), .fail_got(fail_got)
);

/* pins as seen by the SDRAM (transport delays) */
reg         m_clk = 0, m_cke = 0, m_cs_n = 1, m_ras_n = 1, m_cas_n = 1, m_we_n = 1;
reg  [1:0]  m_ba = 0, m_dqm = DQM_OFF;
reg  [12:0] m_a = 0;
/* the data pins */
reg  [15:0] m_dq_drv = 'z;
wire [15:0] m_dq;

/* DDIO: h=0, l=1 */
always @(clk) m_clk <= #(TCO + SD_SHIFT) ~clk;
always @(cke, cs_n, ras_n, cas_n, we_n, ba, a, dqm)
    {m_cke, m_cs_n, m_ras_n, m_cas_n, m_we_n, m_ba, m_a, m_dqm}
       <= #(TCO) {cke, cs_n, ras_n, cas_n, we_n, ba, a, dqm};
/* the data out, high impedance when the controller does not drive */
always @(dq_oe, dq_o) m_dq_drv <= #(TCO) (dq_oe ? dq_o : 16'hzzzz);
/* the data pins: both directions delayed */
assign m_dq = m_dq_drv;
always @(m_dq) dq_i <= #(TBACK) m_dq;

/* the SDRAM model */
sdram_model #(.T_CK(T_CK)) u_sdram (
    .clk(m_clk), .cke(m_cke), .cs_n(m_cs_n), .ras_n(m_ras_n), .cas_n(m_cas_n), .we_n(m_we_n),
    .ba(m_ba), .a(m_a), .dqm(m_dqm), .dq(m_dq)
);

/* bus contention: FPGA and SDRAM both driving */
always @(m_dq_drv, u_sdram.dq_drv)
    if (m_dq_drv !== 16'hzzzz && u_sdram.dq_drv !== 16'hzzzz)
    begin
        $display("%t TB ERROR: DQ bus contention", $realtime);
    end

/* Latency statistics (cycles from req to ack) */
longint cyc = 0;
always @(posedge clk) cyc++;

longint t_req, rd_n = 0, wr_n = 0, rd_sum = 0, wr_sum = 0;
/* minimum and maximum, the histogram of reads, the kind of the access under way */
int     rd_min = MIN_START, rd_max = 0, wr_min = MIN_START, wr_max = 0;
int     rd_hist [0:31];
bit     cur_we;
/* strict (X-aware) read check, independent of the tester */
int     rd_bad = 0;
bit     inject_seen = 0;
always @(posedge clk)
/* an injected error switches the strict check off */
    if (inject)
    begin
        inject_seen <= 1;
    end
/* an empty histogram */
initial
    foreach (rd_hist[k])
    begin
        rd_hist[k] = 0;
    end

/* every access: its latency */
always @(posedge clk)
begin
    if (req)
    begin
        t_req = cyc;
/* the kind of access; the latency at its ack */
        cur_we = we;
    end
    if (ack)
    begin
        automatic int l = cyc - t_req;
/* a write */
        if (cur_we)
        begin
            wr_n++;
            wr_sum += l;
/* shortest and longest */
            if (l < wr_min)
            begin
                wr_min = l;
            end
            if (l > wr_max)
            begin
/* longest */
                wr_max = l;
            end
        end
        else
        begin
/* a read: checked here too, unless an error was injected */
            if (dout !== u_test.exp_d && !inject_seen)
            begin
                rd_bad++;
                if (rd_bad <= LIST_MAX)
                begin
/* the first ten are shown */
                    $display("%t TB ERROR: read addr=%h exp=%h got=%h", $realtime, addr, u_test.exp_d, dout);
                end
            end
/* counted */
            rd_n++;
            rd_sum += l;
            if (l < rd_min)
            begin
/* shortest and longest */
                rd_min = l;
            end
            if (l > rd_max)
            begin
                rd_max = l;
            end
/* into the histogram */
            rd_hist[l > 31 ? 31 : l]++;
        end
    end
end

/* the report */
task automatic report;
    $display("---------------------------------------------------------------");
    $display(" passes=%0d  tester error=%0d  tb read errors=%0d  model errors=%0d",
             pass_count, error, rd_bad, u_sdram.errors);
/* writes and reads */
    $display(" writes: %0d  latency min/avg/max = %0d / %0.2f / %0d clk",
             wr_n, wr_min, real'(wr_sum) / wr_n, wr_max);
    $display(" reads : %0d  latency min/avg/max = %0d / %0.2f / %0d clk",
             rd_n, rd_min, real'(rd_sum) / rd_n, rd_max);
    for (int k = 0; k < HIST_BINS; k++)
    begin
/* a latency that occurred */
        if (rd_hist[k])
        begin
            $display("   read latency %2d clk : %0d", k, rd_hist[k]);
        end
    end
/* the SDRAM's commands */
    $display(" SDRAM cmds: ACT=%0d PRE=%0d RD=%0d WR=%0d REF=%0d  max REF gap=%0.1f ns",
             u_sdram.n_act, u_sdram.n_pre, u_sdram.n_rd, u_sdram.n_wr, u_sdram.n_ref, u_sdram.max_ref_gap);
    $display("---------------------------------------------------------------");
endtask

/* Sequence */
initial
begin
    $display("TB: CLK=%0d MHz, TCO=%0.2f ns, SD_SHIFT=%0.2f ns, PASSES=%0d", `CLK_MHZ, TCO, SD_SHIFT, `PASSES);
    wait (ready);
/* the first pass */
    $display("%t TB: controller ready", $realtime);

    wait (pass_count == 1);
    report();
/* pass 1 must be free of errors */
    if (error || rd_bad || u_sdram.errors)
    begin
        $display("TB RESULT: FAIL (pass 1, addr=%h exp=%h got=%h)", fail_addr, fail_exp, fail_got);
        $finish;
    end

/* a second pass */
    if (`PASSES >= PASSES_FOR_BOTH)
    begin
/* pass 2: inject one error, the tester must catch it */
        @(posedge clk);
        inject <= 1;
        @(posedge clk);
/* one clock long; then the second pass */
        inject <= 0;
        wait (pass_count == 2);
        report();
/* the error must be seen, and nothing else */
        if (!error || u_sdram.errors)
        begin
            $display("TB RESULT: FAIL (injected error not detected or model errors)");
            $finish;
        end
/* the verdict */
        $display("TB: injected error caught at addr=%h exp=%h got=%h", fail_addr, fail_exp, fail_got);
    end
    $display("TB RESULT: PASS");
    $finish;
end

/* safety timeout */
initial
begin
    #(200ms);
/* 200 ms without a verdict */
    $display("TB RESULT: FAIL (timeout)");
    $finish;
end

endmodule
