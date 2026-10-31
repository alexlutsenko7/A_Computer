//=============================================================================
// tb_cont -- memory contention (zx_bus Level 1) with the real T80
//
// mk_contprog.py: 8000 NOPs at 6000 (contended RAM), run after each interrupt.
// Expected (128K, standard Spectrum behaviour): border lines 57 NOPs per 228 T;
// picture lines (63..254 counted as (t + 3) / 228) 41: 16 NOPs stretched to 8 T in
// the 128 contended T-states (M1 at p = 6, 14, .., 126) + 25 in the free 100.
// Lines are counted from the interrupt with the testbench's own T-state counter.
// Then the same with contention off: 57 everywhere.
//=============================================================================
`timescale 1ns/1ps

`ifndef TURBO
 `define TURBO 1
`endif
`ifndef FREEZES
 `define FREEZES 60
`endif

module tb_cont;

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
reg         snap_freeze = 0, snap_req = 0, cont_en = 1;
reg  [3:0]  snap_cmd = 0;
reg  [17:0] snap_addr = 0;
reg  [31:0] snap_wdata = 0;
wire        snap_frozen, snap_ack;
wire [31:0] snap_rdata;
wire        sh_we, sh_page7, ay_bdir, ay_bc1, mic, beeper, cen_tgl;
wire [12:0] sh_addr;
wire [7:0]  sh_data, ay_din, ay_dout;
wire [2:0]  border;

zx_bus u_bus (
    .clk(clk), .rst_n(rst_n), .run(run), .turbo(1'b0), .diag_key(1'b0), .vid50(1'b0), .vsync_n(1'b1),
    .kb_rows({40{1'b1}}), .joy(5'd0), .ltape_on(1'b0), .ltape_lvl(1'b0),
    .cen_tgl(cen_tgl), .hold(1'b0), .mic(mic),
    .sd_req(bus_req), .sd_we(bus_we), .sd_addr(bus_addr), .sd_din(bus_din), .sd_dout(ram_dout), .sd_ack(ram_ack),
    .sh_we(sh_we), .sh_page7(sh_page7), .sh_addr(sh_addr), .sh_data(sh_data),
    .ay_bdir(ay_bdir), .ay_bc1(ay_bc1), .ay_din(ay_din), .ay_dout(ay_dout),
    .border(border), .screen7(), .beeper(beeper), .diag_rom(), .cpu_running(),
    .snap_freeze(snap_freeze), .snap_req(snap_req), .snap_cmd(snap_cmd), .snap_addr(snap_addr),
    .snap_wdata(snap_wdata), .snap_frozen(snap_frozen), .snap_ack(snap_ack), .snap_rdata(snap_rdata),
    .cont_en(cont_en)
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


reg  [7:0]  prog [0:4095];
integer     prog_len;

integer tcount = 0, line_n [0:320], frame = 0, i, bad = 0;
reg     counting = 0;
always @(posedge clk) begin
    if (u_bus.int_start) begin tcount = 0; frame = frame + 1; end
    else if (u_bus.cen_raw) tcount = tcount + 1;
    if (counting && u_bus.mstart && !u_bus.cpu_m1_n && u_bus.cpu_a >= 16'h6000 && u_bus.cpu_a < 16'h7F40)
        line_n[(tcount + 3) / 228] = line_n[(tcount + 3) / 228] + 1;
end

task automatic measure(input integer contended);
    integer exp, n, lo, hi;
    begin
        for (i = 0; i <= 320; i++) line_n[i] = 0;
        @(posedge u_bus.int_start); counting = 1;
        @(posedge u_bus.int_start); counting = 0;
        // lines fully inside the NOP run: from line 2 to the last full line
        hi = 2; while (hi < 320 && line_n[hi + 1] != 0) hi++;
        hi = hi - 1;
        n = 0;
        for (i = 2; i <= hi; i++) begin
            exp = (contended && i >= 64 && i <= 254) ? 41 : 57;          // line 63 starts mid-run
            if (contended && i == 63) exp = -1;
            if (exp >= 0 && line_n[i] != exp) begin
                bad++; if (bad < 12) $display("  ERROR contention %0d: line %0d: %0d NOPs, expected %0d", contended, i, line_n[i], exp);
            end
            n++;
        end
        $display("contention %0d: lines 2..%0d checked (%0d), line 10: %0d NOPs, line 63: %0d, line 64: %0d, line 100: %0d",
                 contended, hi, n, line_n[10], line_n[63], line_n[64], line_n[100]);
    end
endtask

initial begin
    integer f, c;
    f = $fopen("cont_prog.hex", "r");
    prog_len = 0;
    while ($fscanf(f, "%h\n", c) == 1) begin prog[prog_len] = c; prog_len++; end
    $fclose(f);
    wait (ram_ready === 1'b1);
    for (i = 0; i < prog_len; i++) sd_poke(18'h20000 + i, prog[i]);
    repeat (20) @(posedge clk);
    rst_n = 1;
    repeat (4) @(posedge clk);
    run = 1;
    repeat (4) @(posedge u_bus.int_start);       // LDIR done, steady
    measure(1);
    cont_en = 0;
    @(posedge u_bus.int_start);
    measure(0);
    if (bad || u_sdram.errors) $display("FAIL (%0d)", bad); else $display("CONTENTION TEST PASSED");
    $finish;
end

initial begin #300_000_000; $display("TIMEOUT"); $finish; end

endmodule
