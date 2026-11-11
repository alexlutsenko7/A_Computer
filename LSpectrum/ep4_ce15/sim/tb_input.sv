/* tb_input -- input latency: Kempston joystick and USB keyboard (UART) to the CPU */
/* */
/* zx_bus + real T80 + SDRAM model + real zx_keyboard (112 MHz). mk_inputprog.py: */
/* border = (Kempston Fire ? 2 : 0) | (Space ? 4 : 0), */
/* phase 1: tight polling loop, interrupts off      -> raw hardware latency; */
/* phase 2: HALT, one read per 50 Hz frame (a game)  -> + waiting for the frame. */
/* Per event (press and release, random phase): */
/* Kempston: t0 = joystick pin changes; */
/* keyboard: t0 = start bit of the first byte of the CH9350 packet (13 bytes, */
/* 115200 8N1), t_mx = the matrix changes (zx_keyboard rows); */
/* t_in  = first IN (port 1F / row 7 of FE) that returns the new state; */
/* t_out = border changes (OUT FE). */
/* Defines: TURBO=0/1, N_TIGHT, N_FRAME (events per input and phase). */
`timescale 1ns/1ps

/* defaults of the command line switches */
`ifndef TURBO
 `define TURBO 0
`endif
/* polls of the tight loop */
`ifndef N_TIGHT
 `define N_TIGHT 6
`endif
/* frames of the game loop */
`ifndef N_FRAME
 `define N_FRAME 6
`endif

/* the testbench; half a period of the 112 MHz clock */
module tb_input;

/* the SDRAM controller's reset ends after 200 ns */
localparam integer RAM_RST_NS = 200;
/* both data masks high */
localparam integer DQM_OFF = 3;
/* a bit of the keyboard's UART at 115200 baud, ns */
localparam integer BIT_NS = 8680;
/* bits of a byte */
localparam integer BYTE_BITS = 8;
/* T-state 2 */
localparam [2:0] TS_T2 = 3'd2;
/* low byte of the Kempston port */
localparam [7:0] PORT_KEMPSTON = 8'h1F;
/* low byte of the keyboard port */
localparam [7:0] PORT_FE = 8'hFE;
/* shortest pause before an event, microseconds */
localparam integer GAP_MIN_US = 1000;
/* seed of the random phases */
localparam integer SEED = 12345;
/* clocks of the reset */
localparam integer RESET_CLKS = 20;
/* clocks between the reset's end and the start */
localparam integer RUN_CLKS = 4;
/* T-states of a frame */
localparam real FRAME_TSTATES = 70908.0;
/* CPU clock in turbo, MHz */
localparam real CPU_MHZ_TURBO = 28.0;
/* CPU clock, MHz */
localparam real CPU_MHZ = 3.5469;
/* microseconds in a millisecond */
localparam real US_PER_MS = 1000.0;
/* events per input and round: press and release */
localparam integer EVENTS_PER_ROUND = 2;

localparam realtime H = 4.464;
localparam real T_CK  = 2 * H;
/* pin delays, the SDRAM clock's shift */
localparam real TCO   = 4.0;
localparam real TBACK = 0.5;
localparam real SD_SHIFT = 1.339;

/* 112 MHz */
reg clk = 0;
always #(H) clk = ~clk;

/* resets */
reg rst_n = 0, run = 0, ram_rst_n = 0;
initial #RAM_RST_NS ram_rst_n = 1;

/* SDRAM (as tb_float) */
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

/* Keyboard (real zx_keyboard) and joystick */
reg         kbd_rx = 1;
/* fire, up, down, left, right (active high, as zx_bus sees it) */
reg  [4:0]  joy = 0;
wire [39:0] kb_rows;

zx_keyboard #(.CLK_HZ(112000000)) u_kbd (
    .clk(clk), .rst_n(ram_rst_n), .rx(kbd_rx), .block(1'b0), .rows(kb_rows),
    .lkeys(), .f1(), .f8_tgl(), .cad(), .seen(), .raw()
);

/* one byte on the keyboard's UART: 115200 baud, 8680 ns per bit */
task automatic uart_send(input [7:0] b);
    integer i;
    begin
        kbd_rx = 0;
/* the start bit, then eight data bits */
        #BIT_NS;
        for (i = 0; i < BYTE_BITS; i++)
        begin
            kbd_rx = b[i];
/* the last bit, then the stop bit */
            #BIT_NS;
        end
        kbd_rx = 1;
        #BIT_NS;
    end
endtask

/* as tb_lspectrum: 57 AB 01 88 08 mods 00 k 00 00 00 00 00 */
task automatic key_frame(input [7:0] k);
    begin
        uart_send(8'h57);
        uart_send(8'hAB);
/* the frame header */
        uart_send(8'h01);
        uart_send(8'h88);
        uart_send(8'h08);
/* modifiers, then the key */
        uart_send(8'h00);
        uart_send(8'h00);
        uart_send(k);
/* the other key slots are empty */
        uart_send(8'h00);
        uart_send(8'h00);
        uart_send(8'h00);
/* the end of the frame */
        uart_send(8'h00);
        uart_send(8'h00);
    end
endtask

/* Machine: bus + CPU + AY */
wire        sh_we, sh_page7, ay_bdir, ay_bc1, mic, beeper, cen_tgl, snap_frozen, snap_ack;
wire [12:0] sh_addr;
wire [7:0]  sh_data, ay_din, ay_dout;
/* the border; the bus with the CPU */
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

/* the AY at half the clock */
reg ay_cen = 0;
always @(posedge clk) ay_cen <= !ay_cen;
jt49_bus u_ay (
    .rst_n(rst_n), .clk(clk), .clk_en(ay_cen), .bdir(ay_bdir), .bc1(ay_bc1), .din(ay_din), .sel(1'b0),
    .dout(ay_dout), .sound(), .A(), .B(), .C(), .sample(), .IOA_in(8'hFF), .IOA_out(), .IOB_in(8'hFF), .IOB_out()
);

/* Probes */
/* last interrupt */
realtime t_int = 0;
realtime t_in_j = 0, t_in_k = 0, t_mx = 0, t_out_j = 0, t_out_k = 0;
/* state being waited for */
reg      want_j = 0, want_k = 0;
reg      arm_j = 0, arm_k = 0;
wire     in_rd = u_bus.cen && u_bus.cpu_ts == TS_T2 && u_bus.smp_io && !u_bus.smp_iow;

/* every read of the port is checked */
always @(posedge clk)
begin
/* the frame starts */
    if (u_bus.int_start)
    begin
        t_int = $realtime;
    end
    if (arm_j && in_rd && u_bus.a_lat[7:0] == PORT_KEMPSTON && u_bus.cpu_din[4] == want_j)
    begin
/* the time the program read the joystick */
        t_in_j = $realtime;
        arm_j = 0;
    end
    if (arm_k && in_rd && u_bus.a_lat[7:0] == PORT_FE && !u_bus.a_lat[15] && u_bus.cpu_din[0] == !want_k)
    begin
/* the time the program read the key */
        t_in_k = $realtime;
        arm_k = 0;
    end
end
always @(kb_rows[35]) t_mx = $realtime;
/* the border answers the joystick */
always @(border)
begin
    if (border[1] == want_j)
    begin
        t_out_j = $realtime;
    end
/* the border answers the key */
    if (border[2] == want_k)
    begin
        t_out_k = $realtime;
    end
end

/* Test */
reg  [7:0] prog [0:1023];
integer    prog_len, i, n;
real       sum_j_in, sum_j_out, max_j_out, sum_k_mx, sum_k_in, sum_k_out, max_k_out;
/* delays of one event */
real       d_in, d_out, d_mx, d_ph;

task automatic reset_stats;
    begin
        sum_j_in = 0;
/* sums and maxima of the joystick */
        sum_j_out = 0;
        max_j_out = 0;
        sum_k_mx = 0;
/* of the keyboard */
        sum_k_in = 0;
        sum_k_out = 0;
        max_k_out = 0;
/* no events yet */
        n = 0;
    end
endtask

task automatic joy_event(input bit v);
    realtime t0;
    begin
/* what the border must show; times cleared */
        want_j = v;
        t_in_j = 0;
        t_out_j = 0;
/* armed; the fire button changes */
        arm_j = 1;
        t0 = $realtime;
        joy[4] = v;
/* the phase in the frame; the border is waited for */
        d_ph = (t0 - t_int) / 1e6;
        wait (t_out_j != 0);
        d_in = (t_in_j - t0) / 1e3;
/* the delays in microseconds */
        d_out = (t_out_j - t0) / 1e3;
        $display("  Kempston %s  (%5.2f ms after INT): IN 1F %9.1f us, border %9.1f us",
                 v ? "press  " : "release", d_ph, d_in, d_out);
        sum_j_in += d_in;
/* summed; the maximum */
        sum_j_out += d_out;
        if (d_out > max_j_out)
        begin
            max_j_out = d_out;
        end
    end
endtask

/* a key event: Space pressed or released */
task automatic key_event(input bit v);
    realtime t0;
    begin
        want_k = v;
/* times cleared, armed */
        t_in_k = 0;
        t_out_k = 0;
        arm_k = 1;
/* the start time, the phase in the frame */
        t0 = $realtime;
        d_ph = (t0 - t_int) / 1e6;
/* Space / none */
        key_frame(v ? 8'h2C : 8'h00);
        wait (t_out_k != 0);
        d_mx = (t_mx - t0) / 1e3;
/* the delays in microseconds */
        d_in = (t_in_k - t0) / 1e3;
        d_out = (t_out_k - t0) / 1e3;
        $display("  Key      %s  (%5.2f ms after INT): matrix %7.1f us, IN FE %9.1f us, border %9.1f us",
                 v ? "press  " : "release", d_ph, d_mx, d_in, d_out);
/* summed */
        sum_k_mx += d_mx;
        sum_k_in += d_in;
        sum_k_out += d_out;
/* the maximum */
        if (d_out > max_k_out)
        begin
            max_k_out = d_out;
        end
    end
endtask

/* random phase against the frame */
task automatic gap(input integer max_us);
    #((GAP_MIN_US + $urandom_range(max_us)) * 1us);
endtask

task automatic summary;
    begin
/* the means of both */
        $display("  => Kempston: mean IN %0.1f us, mean border %0.1f us, max border %0.1f us",
                 sum_j_in / n, sum_j_out / n, max_j_out);
        $display("  => Keyboard: mean matrix %0.1f us, mean IN %0.1f us, mean border %0.1f us, max border %0.1f us",
                 sum_k_mx / n, sum_k_in / n, sum_k_out / n, max_k_out);
    end
endtask

/* the test */
initial
begin
    integer f, c;
    void'($urandom(SEED));
/* the program's file */
    f = $fopen("input_prog.hex", "r");
/* the program's bytes from a file */
    prog_len = 0;
    while ($fscanf(f, "%h\n", c) == 1)
    begin
        prog[prog_len] = c;
/* next byte; the file is read */
        prog_len++;
    end
    $fclose(f);
    wait (ram_ready === 1'b1);
/* the program into the ROM's place */
    for (i = 0; i < prog_len; i++)
    begin
        sd_poke(18'h20000 + i, prog[i]);
    end
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
    @(posedge u_bus.int_start);
    $display("CPU %s, 128K frame 70908 T = %0.2f ms", `TURBO ? "turbo 28 MHz" : "normal 3.5469 MHz",
             FRAME_TSTATES / (`TURBO ? CPU_MHZ_TURBO : CPU_MHZ) / US_PER_MS);

/* phase 1 */
    $display("Phase 1: tight polling loop (raw latency)");
    reset_stats;
    for (i = 0; i < `N_TIGHT; i++)
    begin
/* a joystick press, 2 ms later */
        gap(2000);
        joy_event(1);
        gap(2000);
/* its release; a key press */
        joy_event(0);
        gap(2000);
        key_event(1);
/* its release; two events each */
        gap(2000);
        key_event(0);
        n += EVENTS_PER_ROUND;
    end
/* the summary; phase 2 */
    summary;

    $display("Phase 2: HALT + one read per frame (as a game)");
/* Z80 8000 (page 2) = mode 1 */
    sd_poke(18'h08000, 8'h01);
    @(posedge u_bus.int_start);
    reset_stats;
/* the same events, 20 ms apart */
    for (i = 0; i < `N_FRAME; i++)
    begin
        gap(20000);
        joy_event(1);
/* the release */
        gap(20000);
        joy_event(0);
        gap(20000);
/* the key */
        key_event(1);
        gap(20000);
        key_event(0);
/* counted; the summary */
        n += EVENTS_PER_ROUND;
    end
    summary;
    if (u_sdram.errors)
    begin
/* the model's errors; the end */
        $display("SDRAM model errors: %0d", u_sdram.errors);
    end
    $display("INPUT LATENCY SIM DONE");
/* the end */
    $finish;
end

/* the test */
initial
begin
    #3s;
/* the simulation hangs */
    $display("TIMEOUT");
    $finish;
end

endmodule
