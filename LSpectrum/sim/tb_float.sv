//=============================================================================
// tb_float -- floating bus (zx_bus) with the real T80
//
// Screen page 5 gets a known pattern (testbench backdoor); mk_floatprog.py runs
// 3000 x IN A,(FF) after each interrupt. For every port FF read the testbench
// computes the expected byte with its own T-state counter (Fuse 1.6's rule, 128K):
// read after all of the I/O cycle's contention, at the start of its 4th T-state
// (readport: early C:1 + 1; late C:1,+1,C:1,+1,C:1 when A, the port's high byte, is
// 40-7F, else + 2); x = t - 14362 - 228 * row, row 0..191, x 0..127: x mod 8 =
// 2 bitmap, 3 attribute, 4 / 5 the same for the next column (2 * (x / 8)); else FF.
// Then contention / floating bus off: all FF.
//=============================================================================
`timescale 1ns/1ps

`ifndef TURBO
 `define TURBO 1
`endif
`ifndef FREEZES
 `define FREEZES 60
`endif

module tb_float;

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


reg  [7:0]  prog [0:8191];
integer     prog_len;
integer tcount = 0, s_start = 0, i, bad = 0, n_rd = 0, n_scr = 0, smp_t = 0, n_cont = 0;
reg     checking = 0;

function automatic [7:0] scr(input integer off);       // the pattern in page 5
    reg [7:0] v;
    begin v = (off * 7 + 3) & 8'hFF; scr = (v == 8'hFF) ? 8'h5A : v; end
endfunction

// 128K contention delay at T-state t (ula_contention_no_mreq)
function automatic integer cdelay(input integer t);
    integer rel;
    begin
        rel = t - 14361; cdelay = 0;
        if (rel >= 0 && rel / 228 < 192 && rel % 228 < 128)
            case ((rel % 228) % 8) 0: cdelay = 6; 1: cdelay = 5; 2: cdelay = 4; 3: cdelay = 3; 4: cdelay = 2; 5: cdelay = 1; default: cdelay = 0; endcase
    end
endfunction

function automatic [7:0] expect_fb(input integer t);
    integer rel, row, tl, col;
    begin
        expect_fb = 8'hFF;
        rel = t - 14362;
        if (rel >= 0) begin
            row = rel / 228; tl = rel % 228;
            if (row < 192 && tl < 128) begin
                col = (tl / 8) * 2;
                case (tl % 8)
                    2: expect_fb = scr(((row & 8'hC0) << 5) | ((row & 7) << 8) | ((row & 8'h38) << 2) | col);
                    3: expect_fb = scr(6144 + (row / 8) * 32 + col);
                    4: expect_fb = scr(((row & 8'hC0) << 5) | ((row & 7) << 8) | ((row & 8'h38) << 2) | (col + 1));
                    5: expect_fb = scr(6144 + (row / 8) * 32 + col + 1);
                    default: ;
                endcase
            end
        end
    end
endfunction

always @(posedge clk) begin
    if (u_bus.int_start) tcount = 0;
    else if (u_bus.cen_raw) tcount = tcount + 1;
    if (u_bus.mstart) s_start = tcount;
    if (checking && u_bus.cen && u_bus.cpu_ts == 3'd2 && u_bus.smp_io && !u_bus.smp_iow && u_bus.a_lat[7:0] == 8'hFF) begin
        n_rd++;
        if (u_bus.cpu_din != 8'hFF) n_scr++;
        // Fuse readport: early + late contention, then the read (high byte 40-7F, from A: contended)
        smp_t = s_start;
        if (cont_en && u_bus.a_lat[15:14] == 2'b01) begin
            smp_t = smp_t + cdelay(smp_t) + 1;
            smp_t = smp_t + cdelay(smp_t) + 1;
            smp_t = smp_t + cdelay(smp_t) + 1;
            smp_t = smp_t + cdelay(smp_t);
        end else
            smp_t = smp_t + 3;
        if (u_bus.a_lat[15:14] == 2'b01) n_cont++;
        if (u_bus.cpu_din !== (cont_en ? expect_fb(smp_t) : 8'hFF)) begin
            bad++;
            if (bad < 12) $display("  ERROR: IN (%04h) at T %0d: %02h, expected %02h", u_bus.a_lat, s_start, u_bus.cpu_din, cont_en ? expect_fb(smp_t) : 8'hFF);
        end
    end
end

initial begin
    integer f, c;
    f = $fopen("float_prog.hex", "r");
    prog_len = 0;
    while ($fscanf(f, "%h\n", c) == 1) begin prog[prog_len] = c; prog_len++; end
    $fclose(f);
    wait (ram_ready === 1'b1);
    for (i = 0; i < prog_len; i++) sd_poke(18'h20000 + i, prog[i]);
    for (i = 0; i < 6912; i++) sd_poke(18'h14000 + i, scr(i));
    repeat (20) @(posedge clk);
    rst_n = 1;
    repeat (4) @(posedge clk);
    run = 1;
    repeat (2) @(posedge u_bus.int_start);
    checking = 1;
    repeat (2) @(posedge u_bus.int_start);
    $display("floating bus on: %0d reads of port FF, %0d returned screen bytes, %0d with a contended high byte", n_rd, n_scr, n_cont);
    cont_en = 0; n_rd = 0; n_scr = 0;
    @(posedge u_bus.int_start);
    repeat (1) @(posedge u_bus.int_start);
    $display("floating bus off: %0d reads, %0d not FF", n_rd, n_scr);
    if (bad || u_sdram.errors || n_rd == 0) $display("FAIL (%0d)", bad); else $display("FLOATING BUS TEST PASSED");
    $finish;
end

initial begin #300_000_000; $display("TIMEOUT"); $finish; end

endmodule
