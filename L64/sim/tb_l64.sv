//=============================================================================
// tb_l64 -- whole C64 (c64_system) with ROMs from the flash model:
//   flash (bit-reversed, as in the .jic) -> ROM loader -> SDRAM model (with I/O
//   delays, as tb_lspectrum) -> T65 boots the KERNAL, BASIC prints its banner.
//
//   ROM image: c64roms.mem in this folder (tools/mk_c64rom.py from your own ROM files;
//   not part of the project). For speed, run_sim.sh can patch the KERNAL's RAM test
//   (it only sets the top of memory), see there.
//   +define+RUN_MS=<ms>   longest simulated time (default 400); stops at "READY."
//   +define+DISK          1541 test: disk.d64 (tools/mk_d64.py) in the drive (the testbench does the
//                         ESP32's job: the track under the head is put into the track buffer), after
//                         READY it types LOAD"$",8 and waits for the directory (disk name TEST, file
//                         HELLO) and READY.; needs a ROM image with the 1541 ROM. RUN_MS counts from
//                         the start of the load (default 4000 with DISK).
//   +define+M50           VGA in the 50 Hz mode (default: 800 x 600 @ 60 Hz)
//   +define+DIRTYRAM      the RAM holds a game's reset protection at power-up, as after a game and
//                         Ctrl+Alt+Del (SDRAM keeps its contents): "CBM80" at $8004, a border-flashing
//                         loop at $8209; the RAM clear must remove it, so BASIC starts
//   +define+SNAPTEST      after READY: freeze, read registers / CIA state / I/O shadow through the snapshot
//                         port, restore with a test program in the restore bank (red border, A/X/Y =
//                         55/66/77, RTI into the frozen state) and check that the C64 runs on
//   +define+TURBO         turbo (F6) allowed: without DISK the CPU runs turbo all the time; with DISK
//                         while the 1541 motor runs, and each new track reaches the buffer 2 ms
//                         after the head moved (as the ESP32 takes its time; the C64 waits)
// Output: the text screen ($0400) as text every 50 ms, screen.ppm (one VGA frame).
//=============================================================================
`timescale 1ns/1ps
`ifndef RUN_MS
 `ifdef DISK
  `define RUN_MS 4000
 `else
  `define RUN_MS 400
 `endif
`endif

module tb_l64;
localparam realtime HSD = 5.289;        // clk_sd half period (94.53 MHz); clk = clk_sd / 3, edges aligned
localparam real T_CK  = 2 * HSD;
localparam real TCO   = 4.0;
localparam real TBACK = 0.5;
localparam real SD_SHIFT = 1.339;

reg clk_sd = 0, clk = 0;
integer ph = 0;
always #(HSD) begin
    clk_sd = ~clk_sd;
    ph = (ph == 2) ? 0 : ph + 1;
    if (ph == 0) clk = ~clk;
end

// pixel clock: 39.80 MHz (60 Hz) or 31.51 MHz (50 Hz), not related to clk / clk_sd
`ifdef M50
localparam realtime HP = 15.867;
localparam integer  FW = 1008, FH = 624;
wire m60 = 1'b0;
`else
localparam realtime HP = 12.562;
localparam integer  FW = 1056, FH = 628;
wire m60 = 1'b1;
`endif
reg pclk = 0;
initial begin #3.7; forever #(HP) pclk = ~pclk; end

reg rst_n = 0;
initial #300 rst_n = 1;

reg kbd_rx = 1;
wire        cke, cs_n, ras_n, cas_n, we_n, dq_oe;
wire [1:0]  ba, dqm;
wire [12:0] a;
wire [15:0] dq_o;
reg  [15:0] dq_i;
wire        f_dclk, f_ncs, f_mosi, f_miso;
wire [3:0]  vr, vg, vb;
wire        hs, vs, aud, led;

c64_system #(.FLASH_DIV(2), .KBD_WAIT_MS(1), .FONT_HEX("../../AMenu/rtl/menu_font.hex")) u_sys (
    .clk(clk), .por_n(rst_n), .rst_n(rst_n), .clk_sd(clk_sd), .rst_sd_n(rst_n),
    .kbd_rx(kbd_rx), .joy1_n(5'b11111), .joy2_n(5'b11111),
    .sd_cke(cke), .sd_cs_n(cs_n), .sd_ras_n(ras_n), .sd_cas_n(cas_n), .sd_we_n(we_n),
    .sd_ba(ba), .sd_a(a), .sd_dqm(dqm), .sd_dq_o(dq_o), .sd_dq_oe(dq_oe), .sd_dq_i(dq_i),
    .kbd_cad(), .kbd_f8(), .pclk(pclk), .prst_n(rst_n), .m60(m60),
    .f_dclk(f_dclk), .f_ncs(f_ncs), .f_mosi(f_mosi), .f_miso(f_miso),
    .vga_r(vr), .vga_g(vg), .vga_b(vb), .vga_hs(hs), .vga_vs(vs),
    .audio(aud), .bt_bclk(1'b0), .bt_lrck(1'b0), .bt_data(), .bt_tx(), .bt_rx(1'b1),
    .esp_sck(1'b0), .esp_mosi(1'b0), .esp_cs_n(1'b1), .esp_miso(), .esp_irq(), .led(led)
);

flash_model #(.BASE(24'h200000), .LEN(49152), .REVERSE(1), .FILE("c64roms.mem")) u_flash (
    .dclk(f_dclk), .ncs(f_ncs), .mosi(f_mosi), .miso(f_miso));

// pins as seen by the SDRAM (transport delays, as tb_lspectrum)
reg         m_clk = 0, m_cke = 0, m_cs_n = 1, m_ras_n = 1, m_cas_n = 1, m_we_n = 1;
reg  [1:0]  m_ba = 0, m_dqm = 3;
reg  [12:0] m_a = 0;
reg  [15:0] m_dq_drv = 'z;
wire [15:0] m_dq;
always @(clk_sd)                                      m_clk <= #(TCO + SD_SHIFT) ~clk_sd;
always @(cke, cs_n, ras_n, cas_n, we_n, ba, a, dqm)   {m_cke, m_cs_n, m_ras_n, m_cas_n, m_we_n, m_ba, m_a, m_dqm}
                                                         <= #(TCO) {cke, cs_n, ras_n, cas_n, we_n, ba, a, dqm};
always @(dq_oe, dq_o)                                 m_dq_drv <= #(TCO) (dq_oe ? dq_o : 16'hzzzz);
assign m_dq = m_dq_drv;
always @(m_dq)                                        dq_i <= #(TBACK) m_dq;

sdram_model #(.T_CK(T_CK)) u_sdram (
    .clk(m_clk), .cke(m_cke), .cs_n(m_cs_n), .ras_n(m_ras_n), .cas_n(m_cas_n), .we_n(m_we_n),
    .ba(m_ba), .a(m_a), .dqm(m_dqm), .dq(m_dq)
);

task automatic sd_poke(input [17:0] ad, input [7:0] v);
    logic [15:0] w;
    logic [23:0] key;
    begin
        key = {ad[11:10], 7'd0, ad[17:12], ad[9:1]};
        w = u_sdram.mem.exists(key) ? u_sdram.mem[key] : 16'h0000;
        if (ad[0]) w[15:8] = v; else w[7:0] = v;
        u_sdram.mem[key] = w;
    end
endtask

function automatic [7:0] sd_peek(input [19:0] ad);
    logic [15:0] w;
    logic [23:0] key;
    begin
        key = {ad[11:10], 5'd0, ad[19:12], ad[9:1]};       // {bank, row, column} as in sdram_model
        w = u_sdram.mem.exists(key) ? u_sdram.mem[key] : 16'hxxxx;
        sd_peek = ad[0] ? w[15:8] : w[7:0];
    end
endfunction

`ifdef DIRTYRAM
initial begin
    static byte cart[9]  = '{8'h09, 8'h82, 8'h09, 8'h82, 8'hC3, 8'hC2, 8'hCD, 8'h38, 8'h30};
    static byte loop[15] = '{8'hA2, 8'hFF, 8'h78, 8'h9A, 8'hD8, 8'hE8, 8'h8E, 8'h11, 8'hD0,
                             8'hEE, 8'h20, 8'hD0, 8'h4C, 8'h12, 8'h82};
    for (int k = 0; k < 9; k++)  sd_poke(18'h08000 + k, cart[k]);
    for (int k = 0; k < 15; k++) sd_poke(18'h08209 + k, loop[k]);
    $display("RAM before power-up: CBM80 at $8004, reset handler at $8209");
end
`endif

// screen code -> ASCII (upper case set)
function automatic byte scr2asc(input [7:0] c);
    logic [7:0] b;
    begin
        b = c & 8'h7F;
        if (^b === 1'bx)       scr2asc = "?";
        else if (b == 0)       scr2asc = "@";
        else if (b < 27)       scr2asc = 8'h40 + b;
        else if (b < 32)       scr2asc = " ";
        else if (b < 64)       scr2asc = b;
        else                   scr2asc = "#";
    end
endfunction

string screen_txt;
task automatic show_screen;
    integer r, c;
    string line;
    begin
        screen_txt = "";
        $display("%t screen:", $time);
        for (r = 0; r < 25; r++) begin
            line = "";
            for (c = 0; c < 40; c++) line = {line, string'(scr2asc(sd_peek(18'h400 + r * 40 + c)))};
            $display("  |%s|", line);
            screen_txt = {screen_txt, line};
        end
    end
endtask

function automatic integer count_text(input string s, input string t);
    integer i;
    begin
        count_text = 0;
        for (i = 0; i + t.len() <= s.len(); i++) if (s.substr(i, i + t.len() - 1) == t) count_text++;
    end
endfunction

function automatic bit has_text(input string s, input string t);
    integer i;
    begin
        has_text = 0;
        for (i = 0; i + t.len() <= s.len(); i++) if (s.substr(i, i + t.len() - 1) == t) has_text = 1;
    end
endfunction

// one VGA frame (FW x FH pixel clocks from a vsync edge, blanking included)
task automatic grab(input string fname);
    integer f, x, y;
    reg vs0;
    begin
        vs0 = vs;
        @(vs);
        f = $fopen(fname, "w");
        $fwrite(f, "P3\n%0d %0d\n255\n", FW, FH);
        for (y = 0; y < FH; y++)
            for (x = 0; x < FW; x++) begin
                @(posedge pclk);
                $fwrite(f, "%0d %0d %0d\n", vr * 17, vg * 17, vb * 17);
            end
        $fclose(f);
        $display("%t wrote %s", $time, fname);
    end
endtask

`ifdef TRACE
integer n_sd = 0;
always @(posedge clk_sd)
    if (u_sys.ld_done && n_sd < 60) begin
        n_sd++;
        $display("%t sd: req %b we %b addr %05h ack %b | a_busy %b bus_pend %b tgl %b/%b sm_pend %b | ram state %0d pend %b",
                 $time, u_sys.u_ram.req, u_sys.u_ram.we, u_sys.u_ram.addr, u_sys.ram_ack, u_sys.a_busy, u_sys.bus_pend,
                 u_sys.m_req_tgl, u_sys.m_rq_d, u_sys.sm_pend, u_sys.u_ram.state, u_sys.u_ram.pend);
    end
// first CPU cycles after the reset: address, R/W, data in, arbiter state
integer n_tr = 0;
always @(posedge clk)
    if (u_sys.cpu_ce && u_sys.c64_rst_n && n_tr < `TRACE) begin
        n_tr++;
        $display("%t cpu A %04h rw %b di %02h | own_vic %b cpu_cyc %b frz %b | a_busy %b bus_pend %b m_dout %02h",
                 $time, u_sys.cpu_a_full[15:0], u_sys.cpu_rw_n, u_sys.cpu_di, u_sys.own_vic, u_sys.cpu_cyc,
                 u_sys.frz_now, u_sys.a_busy, u_sys.bus_pend, u_sys.m_dout);
    end
`endif
integer t_ms, errors = 0, n_hs = 0, n_vs = 0;

`ifdef VICTEST
// the VIC-II on the real bus with the CPU held in reset: registers set as the KERNAL does,
// HELLO in screen RAM, one raster line of c- / g-accesses logged, one frame written
integer n_log = 0, vi;
reg log_on = 0;
always @(posedge clk)
    if (log_on && n_log < 40 && (u_sys.u_vic.raster_line == 9'd59 || u_sys.u_vic.raster_line == 9'd60)) begin
        if (u_sys.phase[2])
            $display("%t t2  clk_phi %b aec %b ba %b type %0d vic_addr %04h", $time, u_sys.clk_phi, u_sys.aec, u_sys.ba,
                     u_sys.u_vic.cycle_type, u_sys.vic_addr);
        if (u_sys.phase[0]) begin
            n_log++;
            $display("%t DAV clk_phi %b aec %b type %0d own_vic %b m_addr %05h m_dout %02h dbi %03h",
                     $time, u_sys.clk_phi, u_sys.aec, u_sys.u_vic.cycle_type, u_sys.own_vic, u_sys.m_addr, u_sys.m_dout, u_sys.vic_dbi);
        end
    end
always @(posedge clk_sd)
    if (log_on && n_log < 40 && (u_sys.u_vic.raster_line == 9'd59 || u_sys.u_vic.raster_line == 9'd60) && (u_sys.a_req || u_sys.ram_ack))
        $display("%t   sd: req %b ack %b addr %05h dout %02h", $time, u_sys.a_req, u_sys.ram_ack, u_sys.a_addr, u_sys.ram_dout);
`endif

`ifdef DISK
// 1541 DOS job queue ($0000-$0005: job codes $80 read, $90 write, $B0 seek, $E0 execute; results
// 01 ok, 02 header, 03 sync, 04 data block, 05 data checksum, ...) and the job's track / sector
reg [7:0] jq [0:5];
integer jn = 0;
reg     job_on = 0;
initial for (int k = 0; k < 6; k++) jq[k] = 8'h00;
always @(posedge clk) begin
    for (int k = 0; k < 6; k++)
        if (u_sys.u_drive.ram[k] !== jq[k]) begin
            jq[k] = u_sys.u_drive.ram[k];
            if (job_on && jn < 200)
            begin
            jn++;
            $display("%t JOB %0d = %02h  (T/S %0d/%0d) head %0d", $time, k, jq[k],
                     u_sys.u_drive.ram[6 + 2*k], u_sys.u_drive.ram[7 + 2*k], u_sys.d_track);
            end
        end
end
// every ms after LOAD: drive CPU address, C64 CPU address, serial bus, disk surface activity
integer n_sync = 0, n_byte = 0;
reg     sp = 1, bp = 1;
always @(posedge clk) begin
    sp <= u_sys.u_drive.sync_n;  bp <= u_sys.u_drive.byte_n;
    if (sp && !u_sys.u_drive.sync_n) n_sync++;
    if (bp && !u_sys.u_drive.byte_n) n_byte++;
end
initial begin
    wait (job_on);
    repeat (60) begin
        #20ms;
        $display("%t drv A %04h | c64 A %04h | ATN %b CLK %b DATA %b (c64 out a/c/d %b%b%b) | motor %b track %0d syncs %0d bytes %0d",
                 $time, u_sys.u_drive.cpu_a[15:0], u_sys.cb_a, !u_sys.cia2_pa_out_w[3], u_sys.iec_clk, u_sys.iec_data,
                 u_sys.cia2_pa_out_w[3], u_sys.cia2_pa_out_w[4], u_sys.cia2_pa_out_w[5], u_sys.d_motor, u_sys.d_track, n_sync, n_byte);
    end
end
// the ESP32's part of the drive: keep the track under the head in the track buffer
reg [7:0] d64 [0:174847];
integer   fd, i, loaded = 0;
`ifdef TURBO
localparam [7:0] MCTL0 = 8'd5;          // disk + turbo allowed
`else
localparam [7:0] MCTL0 = 8'd1;
`endif
function automatic integer spt(input integer t); spt = t <= 17 ? 21 : t <= 24 ? 19 : t <= 30 ? 18 : 17; endfunction
function automatic integer doff(input integer t, input integer sct);
    integer k, n;
    begin n = 0; for (k = 1; k < t; k++) n += spt(k); doff = (n + sct) * 256; end
endfunction
initial begin
    fd = $fopen("disk.d64", "rb");
    if (!fd) begin $display("FAIL: no disk.d64"); $finish; end
    i = $fread(d64, fd);
    $fclose(fd);
    force u_sys.u_tape.mctl = {d64[doff(18, 0) + 8'hA3], d64[doff(18, 0) + 8'hA2], 8'd0, MCTL0};
end
always @(posedge clk_sd) begin
    integer t, sc, b;
    t = u_sys.d_track;
    if (t >= 1 && t <= 35 && t != loaded) begin
`ifdef TURBO
        force u_sys.u_tape.mctl = {d64[doff(18, 0) + 8'hA3], d64[doff(18, 0) + 8'hA2], 8'd0, MCTL0};
        #2ms;
        t = u_sys.d_track;
`endif
        for (sc = 0; sc < spt(t); sc++)
            for (b = 0; b < 256; b++) u_sys.u_drive.tbuf[sc * 256 + b] = d64[doff(t, sc) + b];
        loaded = t;
        force u_sys.u_tape.mctl = {d64[doff(18, 0) + 8'hA3], d64[doff(18, 0) + 8'hA2], 2'd0, t[5:0], MCTL0};
        $display("%t drive: track %0d loaded (head)", $time, t);
    end
end
`endif
`ifdef SNAPTEST
// the ESP32's snapshot commands, driven straight into c64_system's snapshot port
reg [31:0] s_rd, s_d;
reg [3:0]  s_c;
reg [17:0] s_a;
reg        s_r;
task automatic snapc(input [3:0] c, input [17:0] a, input [31:0] d);
    begin
        @(posedge clk_sd);
        s_c = c; s_a = a; s_d = d;
        force u_sys.snap_cmd = s_c; force u_sys.snap_addr = s_a; force u_sys.snap_wdata = s_d;
        s_r = !u_sys.snap_ack;
        force u_sys.snap_req = s_r;
        wait (u_sys.snap_ack == s_r);
        @(posedge clk_sd);
        s_rd = u_sys.snap_rdata;
    end
endtask
reg [17:0] st_pc;
task automatic st8(input [7:0] b); begin sd_poke(18'h30000 + st_pc, b); st_pc++; end endtask
task automatic st_sta(input [7:0] v, input [15:0] a); begin st8(8'hA9); st8(v); st8(8'h8D); st8(a[7:0]); st8(a[15:8]); end endtask
task automatic snap_test;
    reg [31:0] r0, r1, c1, c2;
    reg [7:0]  sp;
    integer    w;
    begin
        #20ms;
        // screenshot path: hold the frame buffers, read them through MRD while the C64 runs
        begin
            reg [19:0] fb;
            snapc(4'd4, 18'd0, 4);
            fb = 20'h40000 + u_sys.fb_newest * 20'h20000;
            snapc(4'd1, 18'd0, 0);
            $display("%t screenshot read: top border %02h (EE expected), SDRAM %02h", $time, s_rd[7:0], sd_peek(fb));
            if (s_rd[7:0] != 8'hEE || s_rd[7:0] != sd_peek(fb)) begin $display("FAIL: screenshot border"); errors++; end
            snapc(4'd1, 18'd100 * 256 + 18'd100, 0);
            $display("   screen area %02h (66 = blue expected), SDRAM %02h", s_rd[7:0], sd_peek(fb + 100 * 256 + 100));
            if (s_rd[7:0] != 8'h66) begin $display("FAIL: screenshot screen area"); errors++; end
            snapc(4'd4, 18'd0, 0);
            snapc(4'd2, 18'h20000, 8'h41);              // track buffer MWR with an odd data byte, then MRD
            snapc(4'd1, 18'h20000, 0);
            if (s_rd[7:0] != 8'h41) begin $display("FAIL: track buffer read after the hold (%02h)", s_rd[7:0]); errors++; end
        end
        force u_sys.snap_freeze = 1'b1;
        wait (u_sys.frz_q);
        snapc(4'd3, 18'd0, 0); r0 = s_rd;
        snapc(4'd3, 18'd1, 0); r1 = s_rd;
        snapc(4'd3, 18'd2, 0); c1 = s_rd;
        snapc(4'd3, 18'd3, 0); c2 = s_rd;
        $display("%t frozen: A %02h X %02h Y %02h P %02h S %02h PC %04h (bus %04h) | CIA1 IMR %02h CRA %02h CRB %02h | CIA2 IMR %02h",
                 $time, r0[7:0], r0[15:8], r0[23:16], r0[31:24], r1[7:0], r1[31:16], u_sys.cpu_a_full[15:0], c1[4:0], c1[15:8], c1[23:16], c2[4:0]);
        snapc(4'd1, 18'h3D020, 0); $display("   shadow: D020 %02h (border 14 expected)", s_rd[7:0]);
        if (s_rd[3:0] != 4'd14) begin $display("FAIL: I/O shadow D020"); errors++; end
        snapc(4'd1, 18'h3D021, 0); $display("   shadow: D021 %02h (6)", s_rd[7:0]);
        snapc(4'd1, 18'h3D800, 0); $display("   shadow: D800 %02h (colour RAM, 14)", s_rd[7:0]);
        snapc(4'd1, 18'h3D418, 0); $display("   shadow: D418 %02h (SID volume)", s_rd[7:0]);
        snapc(4'd1, 18'h3DC0E, 0); $display("   shadow: DC0E %02h (CIA1 CRA)", s_rd[7:0]);
        if (c1[4:0] != 5'h01) begin $display("FAIL: CIA1 IMR %02h (01 expected: timer A)", c1[4:0]); errors++; end
        // the restore program, as the ESP32 builds it (shortened)
        sd_poke(18'h3FFFC, 8'h00); sd_poke(18'h3FFFD, 8'h20);
        st_pc = 18'h2000;
        st8(8'h78); st8(8'hD8);
        st_sta(8'h02, 16'hD020);                                    // red border
        sp = r1[7:0];
        st8(8'hA2); st8(sp - 8'd3); st8(8'h9A);
        st_sta(r0[31:24], 16'h0100 + (sp - 8'd2));
        st_sta(r1[23:16], 16'h0100 + (sp - 8'd1));
        st_sta(r1[31:24], 16'h0100 + sp);
        st8(8'hA9); st8(8'h55); st8(8'hA2); st8(8'h66); st8(8'hA0); st8(8'h77);
        st8(8'h40);
        snapc(4'd4, 18'd0, 3);                                      // restore mode, CPU reset
        release u_sys.snap_freeze;
        #100us;
        snapc(4'd4, 18'd0, 1);                                      // CPU runs the program
        w = 0;
        while (u_sys.rmode && w < 2000) begin #1us; w++; end
        $display("%t restore mode %0d after %0d us: A %02h X %02h Y %02h S %02h PC %04h, border %0d",
                 $time, u_sys.rmode, w, u_sys.cpu_regs[7:0], u_sys.cpu_regs[15:8], u_sys.cpu_regs[23:16], u_sys.cpu_regs[39:32],
                 u_sys.cpu_regs[63:48], u_sys.u_vic.vic_registers.ec);
        if (u_sys.rmode) begin $display("FAIL: restore mode did not end"); errors++; end
        if (u_sys.cpu_regs[7:0] != 8'h55 || u_sys.cpu_regs[15:8] != 8'h66 || u_sys.cpu_regs[23:16] != 8'h77) begin
            $display("FAIL: registers"); errors++; end
        if (u_sys.cpu_regs[39:32] != sp) begin $display("FAIL: S"); errors++; end
        if (u_sys.cpu_regs[63:48] != r1[31:16]) begin $display("FAIL: PC"); errors++; end
        if (u_sys.u_vic.vic_registers.ec != 4'd2) begin $display("FAIL: border not red"); errors++; end
        snapc(4'd4, 18'd0, 0);
        release u_sys.snap_cmd; release u_sys.snap_addr; release u_sys.snap_wdata; release u_sys.snap_req;
        #50ms;
        $display("%t running on: cpu A %04h", $time, u_sys.cb_a);
        show_screen;
    end
endtask
`endif
always @(posedge hs) n_hs++;
always @(posedge vs) n_vs++;
`ifdef TURBO
`ifndef DISK
initial force u_sys.t_allow = 1'b1;     // turbo from the start
`endif
// turbo statistics: CPU cycles per 1 ms, drive cycles per 1 ms
integer n_cce = 0, n_dce = 0;
always @(posedge clk) begin
    if (u_sys.cpu_ce) n_cce++;
    if (u_sys.u_drive.ph2_f) n_dce++;
end
always begin
    #10ms;
    $display("%t turbo %0d: CPU %0d kHz, drive %0d kHz, wait %0d", $time, u_sys.turbo, n_cce / 10, n_dce / 10, u_sys.drv_wait);
    n_cce = 0; n_dce = 0;
end
`endif
initial begin
    wait (u_sys.ld_done);
    $display("%t ROMs loaded (bad_image %0d), first bytes CHAR %02h BASIC %02h KERNAL[FFFC] %02h%02h", $time,
             u_sys.bad_image, sd_peek(18'h11000), sd_peek(18'h12000), sd_peek(18'h15FFD), sd_peek(18'h15FFC));
`ifdef TRACE
    #100us;
`endif
`ifdef VICTEST
    force u_sys.c64_rst_n = 1'b0;
    for (vi = 0; vi < 1000; vi++) begin sd_poke(18'h400 + vi, 8'h20); u_sys.cram[vi] = 4'd14; end
    sd_poke(18'h400, 8); sd_poke(18'h401, 5); sd_poke(18'h402, 12); sd_poke(18'h403, 12); sd_poke(18'h404, 15);
    force u_sys.u_vic.vic_registers.yscroll = 3'd3;
    force u_sys.u_vic.vic_registers.rsel    = 1'b1;
    force u_sys.u_vic.vic_registers.den     = 1'b1;
    force u_sys.u_vic.vic_registers.csel    = 1'b1;
    force u_sys.u_vic.vic_registers.cb      = 3'b010;
    force u_sys.u_vic.vic_registers.vm      = 4'b0001;
    force u_sys.u_vic.vic_registers.ec      = 4'd14;
    force u_sys.u_vic.vic_registers.b0c     = 4'd6;
    #25ms;
    log_on = 1;
    #20ms;
    grab("victest.ppm");
    $finish;
`endif
    for (t_ms = 50; t_ms <= `RUN_MS; t_ms += 50) begin
        #50ms;
        $display("%t PC area: cpu A %04h", $time, u_sys.cb_a);
        show_screen;
        if (has_text(screen_txt, "READY.")) break;
    end
`ifdef SNAPTEST
    snap_test;
`endif
`ifdef DISK
    // the 1541 runs its power-up self-test for about a second (motor on): wait until it is idle
    begin
        integer w;
        for (w = 0; w < 300 && u_sys.d_motor; w++) #10ms;
        #100ms;
        $display("%t drive idle (motor %0d) after %0d ms", $time, u_sys.d_motor, w * 10);
    end
    // LOAD"$",8 RETURN into the keyboard buffer
    begin
        static byte cmd[10] = '{"L", "O", "A", "D", 8'h22, "$", 8'h22, ",", "8", 8'h0D};
        for (i = 0; i < 10; i++) sd_poke(18'h277 + i, cmd[i]);
        sd_poke(18'hC6, 8'd10);
        $display("%t typed LOAD\"$\",8", $time);
        job_on = 1;
    end
    for (t_ms = 50; t_ms <= `RUN_MS; t_ms += 50) begin
        #50ms;
        show_screen;
        $display("%t drive: track %0d motor %0d led %0d | cpu A %04h", $time, u_sys.d_track, u_sys.d_motor, u_sys.d_led, u_sys.cb_a);
        if (has_text(screen_txt, "BLOCKS FREE")) break;
        if (count_text(screen_txt, "READY.") == 2 && sd_peek(18'hC6) == 0) begin     // loaded: LIST it
            static byte lst[5] = '{"L", "I", "S", "T", 8'h0D};
            for (i = 0; i < 5; i++) sd_poke(18'h277 + i, lst[i]);
            sd_poke(18'hC6, 8'd5);
            $display("%t typed LIST", $time);
        end
    end
    if (!has_text(screen_txt, "TEST")) begin $display("FAIL: no directory (disk name)"); errors++; end
    if (!has_text(screen_txt, "HELLO")) begin $display("FAIL: no directory entry HELLO"); errors++; end
`endif
    if (!has_text(screen_txt, "COMMODORE 64 BASIC V2")) begin $display("FAIL: no BASIC banner"); errors++; end
    if (!has_text(screen_txt, "38911 BASIC BYTES FREE")) begin $display("FAIL: wrong memory size"); errors++; end
    if (!has_text(screen_txt, "READY.")) begin $display("FAIL: no READY."); errors++; end
`ifdef DIRTYRAM
    if (sd_peek(20'h08004) != 8'h00) begin $display("FAIL: RAM not cleared ($8004 = %02h)", sd_peek(20'h08004)); errors++; end
`endif
    $display("%t VGA sync edges so far: hsync %0d, vsync %0d", $time, n_hs, n_vs);
    $display("%t VIC-II: border %0d, background %0d, DEN %0d, frame buffer newest %0d", $time,
             u_sys.u_vic.vic_registers.ec, u_sys.u_vic.vic_registers.b0c, u_sys.u_vic.vic_registers.den, u_sys.u_fb.newest);
    if (n_vs < 2) begin $display("FAIL: no vsync"); errors++; end
    else grab("screen.ppm");
    if (errors) $display("RESULT: FAIL"); else $display("RESULT: PASS");
    $finish;
end

endmodule
