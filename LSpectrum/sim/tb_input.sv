//=============================================================================
// tb_input -- input latency: Kempston joystick and USB keyboard (UART) to the CPU
//
// zx_bus + real T80 + SDRAM model + real zx_keyboard (112 MHz). mk_inputprog.py:
// border = (Kempston Fire ? 2 : 0) | (Space ? 4 : 0),
//   phase 1: tight polling loop, interrupts off      -> raw hardware latency;
//   phase 2: HALT, one read per 50 Hz frame (a game)  -> + waiting for the frame.
// Per event (press and release, random phase):
//   Kempston: t0 = joystick pin changes;
//   keyboard: t0 = start bit of the first byte of the CH9350 packet (13 bytes,
//             115200 8N1), t_mx = the matrix changes (zx_keyboard rows);
//   t_in  = first IN (port 1F / row 7 of FE) that returns the new state;
//   t_out = border changes (OUT FE).
// Defines: TURBO=0/1, N_TIGHT, N_FRAME (events per input and phase).
//=============================================================================
`timescale 1ns/1ps

`ifndef TURBO
 `define TURBO 0
`endif
`ifndef N_TIGHT
 `define N_TIGHT 6
`endif
`ifndef N_FRAME
 `define N_FRAME 6
`endif

module tb_input;

localparam realtime H = 4.464;
localparam real T_CK  = 2 * H;
localparam real TCO   = 4.0;
localparam real TBACK = 0.5;
localparam real SD_SHIFT = 1.339;

reg clk = 0;
always #(H) clk = ~clk;

reg rst_n = 0, run = 0, ram_rst_n = 0;
initial #200 ram_rst_n = 1;

//-----------------------------------------------------------------------------
// SDRAM (as tb_float)
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

task automatic sd_poke(input [17:0] ad, input [7:0] v);
    logic [15:0] w;
    begin
        w = u_sdram.mem.exists(sd_key(ad)) ? u_sdram.mem[sd_key(ad)] : 16'h0000;
        if (ad[0]) w[15:8] = v; else w[7:0] = v;
        u_sdram.mem[sd_key(ad)] = w;
    end
endtask

//-----------------------------------------------------------------------------
// Keyboard (real zx_keyboard) and joystick
//-----------------------------------------------------------------------------
reg         kbd_rx = 1;
reg  [4:0]  joy = 0;                    // fire, up, down, left, right (active high, as zx_bus sees it)
wire [39:0] kb_rows;

zx_keyboard #(.CLK_HZ(112000000)) u_kbd (
    .clk(clk), .rst_n(ram_rst_n), .rx(kbd_rx), .block(1'b0), .rows(kb_rows),
    .lkeys(), .f1(), .f8_tgl(), .cad(), .seen(), .raw()
);

task automatic uart_send(input [7:0] b);
    integer i;
    begin
        kbd_rx = 0; #8680;
        for (i = 0; i < 8; i++) begin kbd_rx = b[i]; #8680; end
        kbd_rx = 1; #8680;
    end
endtask

task automatic key_frame(input [7:0] k);     // as tb_lspectrum: 57 AB 01 88 08 mods 00 k 00 00 00 00 00
    begin
        uart_send(8'h57); uart_send(8'hAB);
        uart_send(8'h01); uart_send(8'h88); uart_send(8'h08);
        uart_send(8'h00); uart_send(8'h00);
        uart_send(k); uart_send(8'h00); uart_send(8'h00); uart_send(8'h00); uart_send(8'h00); uart_send(8'h00);
    end
endtask

//-----------------------------------------------------------------------------
// Machine: bus + CPU + AY
//-----------------------------------------------------------------------------
wire        sh_we, sh_page7, ay_bdir, ay_bc1, mic, beeper, cen_tgl, snap_frozen, snap_ack;
wire [12:0] sh_addr;
wire [7:0]  sh_data, ay_din, ay_dout;
wire [2:0]  border;
wire [31:0] snap_rdata;

zx_bus u_bus (
    .clk(clk), .rst_n(rst_n), .run(run), .turbo(`TURBO ? 1'b1 : 1'b0), .diag_key(1'b0), .vid50(1'b0), .vsync_n(1'b1),
    .kb_rows(kb_rows), .joy(joy), .ltape_on(1'b0), .ltape_lvl(1'b0),
    .cen_tgl(cen_tgl), .hold(1'b0), .mic(mic),
    .sd_req(bus_req), .sd_we(bus_we), .sd_addr(bus_addr), .sd_din(bus_din), .sd_dout(ram_dout), .sd_ack(ram_ack),
    .sh_we(sh_we), .sh_page7(sh_page7), .sh_addr(sh_addr), .sh_data(sh_data),
    .ay_bdir(ay_bdir), .ay_bc1(ay_bc1), .ay_din(ay_din), .ay_dout(ay_dout),
    .border(border), .screen7(), .beeper(beeper), .diag_rom(), .cpu_running(),
    .snap_freeze(1'b0), .snap_req(1'b0), .snap_cmd(4'd0), .snap_addr(18'd0),
    .snap_wdata(32'd0), .snap_frozen(snap_frozen), .snap_ack(snap_ack), .snap_rdata(snap_rdata),
    .cont_en(1'b1)
);

reg ay_cen = 0;
always @(posedge clk) ay_cen <= !ay_cen;
jt49_bus u_ay (
    .rst_n(rst_n), .clk(clk), .clk_en(ay_cen), .bdir(ay_bdir), .bc1(ay_bc1), .din(ay_din), .sel(1'b0),
    .dout(ay_dout), .sound(), .A(), .B(), .C(), .sample(), .IOA_in(8'hFF), .IOA_out(), .IOB_in(8'hFF), .IOB_out()
);

//-----------------------------------------------------------------------------
// Probes
//-----------------------------------------------------------------------------
realtime t_int = 0;                     // last interrupt
realtime t_in_j = 0, t_in_k = 0, t_mx = 0, t_out_j = 0, t_out_k = 0;
reg      want_j = 0, want_k = 0;        // state being waited for
reg      arm_j = 0, arm_k = 0;
wire     in_rd = u_bus.cen && u_bus.cpu_ts == 3'd2 && u_bus.smp_io && !u_bus.smp_iow;

always @(posedge clk) begin
    if (u_bus.int_start) t_int = $realtime;
    if (arm_j && in_rd && u_bus.a_lat[7:0] == 8'h1F && u_bus.cpu_din[4] == want_j) begin t_in_j = $realtime; arm_j = 0; end
    if (arm_k && in_rd && u_bus.a_lat[7:0] == 8'hFE && !u_bus.a_lat[15] && u_bus.cpu_din[0] == !want_k) begin t_in_k = $realtime; arm_k = 0; end
end
always @(kb_rows[35]) t_mx = $realtime;
always @(border) begin
    if (border[1] == want_j) t_out_j = $realtime;
    if (border[2] == want_k) t_out_k = $realtime;
end

//-----------------------------------------------------------------------------
// Test
//-----------------------------------------------------------------------------
reg  [7:0] prog [0:1023];
integer    prog_len, i, n;
real       sum_j_in, sum_j_out, max_j_out, sum_k_mx, sum_k_in, sum_k_out, max_k_out;
real       d_in, d_out, d_mx, d_ph;

task automatic reset_stats;
    begin sum_j_in = 0; sum_j_out = 0; max_j_out = 0; sum_k_mx = 0; sum_k_in = 0; sum_k_out = 0; max_k_out = 0; n = 0; end
endtask

task automatic joy_event(input bit v);
    realtime t0;
    begin
        want_j = v; t_in_j = 0; t_out_j = 0; arm_j = 1;
        t0 = $realtime; joy[4] = v;
        d_ph = (t0 - t_int) / 1e6;
        wait (t_out_j != 0);
        d_in = (t_in_j - t0) / 1e3; d_out = (t_out_j - t0) / 1e3;
        $display("  Kempston %s  (%5.2f ms after INT): IN 1F %9.1f us, border %9.1f us",
                 v ? "press  " : "release", d_ph, d_in, d_out);
        sum_j_in += d_in; sum_j_out += d_out; if (d_out > max_j_out) max_j_out = d_out;
    end
endtask

task automatic key_event(input bit v);
    realtime t0;
    begin
        want_k = v; t_in_k = 0; t_out_k = 0; arm_k = 1;
        t0 = $realtime;
        d_ph = (t0 - t_int) / 1e6;
        key_frame(v ? 8'h2C : 8'h00);        // Space / none
        wait (t_out_k != 0);
        d_mx = (t_mx - t0) / 1e3; d_in = (t_in_k - t0) / 1e3; d_out = (t_out_k - t0) / 1e3;
        $display("  Key      %s  (%5.2f ms after INT): matrix %7.1f us, IN FE %9.1f us, border %9.1f us",
                 v ? "press  " : "release", d_ph, d_mx, d_in, d_out);
        sum_k_mx += d_mx; sum_k_in += d_in; sum_k_out += d_out; if (d_out > max_k_out) max_k_out = d_out;
    end
endtask

task automatic gap(input integer max_us);     // random phase against the frame
    #((1000 + $urandom_range(max_us)) * 1us);
endtask

task automatic summary;
    begin
        $display("  => Kempston: mean IN %0.1f us, mean border %0.1f us, max border %0.1f us",
                 sum_j_in / n, sum_j_out / n, max_j_out);
        $display("  => Keyboard: mean matrix %0.1f us, mean IN %0.1f us, mean border %0.1f us, max border %0.1f us",
                 sum_k_mx / n, sum_k_in / n, sum_k_out / n, max_k_out);
    end
endtask

initial begin
    integer f, c;
    void'($urandom(12345));
    f = $fopen("input_prog.hex", "r");
    prog_len = 0;
    while ($fscanf(f, "%h\n", c) == 1) begin prog[prog_len] = c; prog_len++; end
    $fclose(f);
    wait (ram_ready === 1'b1);
    for (i = 0; i < prog_len; i++) sd_poke(18'h20000 + i, prog[i]);
    repeat (20) @(posedge clk);
    rst_n = 1;
    repeat (4) @(posedge clk);
    run = 1;
    @(posedge u_bus.int_start);
    $display("CPU %s, 128K frame 70908 T = %0.2f ms", `TURBO ? "turbo 28 MHz" : "normal 3.5469 MHz",
             70908.0 / (`TURBO ? 28.0 : 3.5469) / 1000.0);

    $display("Phase 1: tight polling loop (raw latency)");
    reset_stats;
    for (i = 0; i < `N_TIGHT; i++) begin
        gap(2000); joy_event(1); gap(2000); joy_event(0);
        gap(2000); key_event(1); gap(2000); key_event(0);
        n += 2;
    end
    summary;

    $display("Phase 2: HALT + one read per frame (as a game)");
    sd_poke(18'h08000, 8'h01);                // Z80 8000 (page 2) = mode 1
    @(posedge u_bus.int_start);
    reset_stats;
    for (i = 0; i < `N_FRAME; i++) begin
        gap(20000); joy_event(1); gap(20000); joy_event(0);
        gap(20000); key_event(1); gap(20000); key_event(0);
        n += 2;
    end
    summary;
    if (u_sdram.errors) $display("SDRAM model errors: %0d", u_sdram.errors);
    $display("INPUT LATENCY SIM DONE");
    $finish;
end

initial begin #3s; $display("TIMEOUT"); $finish; end

endmodule
