//=============================================================================
// tb_floatgame -- a game's floating-bus sync on zx_bus + T80 (Sidewize)
//
// Loads a .z80 image (mk_z80img.py: RAM pages, register words, 7FFD, border)
// into the SDRAM model, restores the registers through the snapshot port
// (DIR + LOAD) and runs it. Every read of an unanswered port (A0 = 1, A5 = 1)
// is compared with Fuse 1.6's rule: the port is read after the whole I/O
// contention (early: C:1 then T1; late: contended high byte C:1,C:1,C:1 between
// T2..T4, otherwise 2 T), i.e. at the start of T4; byte phase x = t - 14362 -
// 228 * row (0..127): x mod 8 = 2 bitmap, 3 attr, 4/5 the same + 1 column.
// The sync loop at WAIT_PC (IN A,(C) ; CP E ; JP NZ) is logged per exit.
// Sidewize (+define+SIDEWIZE_KEMPSTON): Kempston control poked in, fire starts the game; then the joystick moves.
//   +define+FRAMES=n (default 12)   +define+IMG="file"  +define+WAIT_PC=16'h....
//=============================================================================
`timescale 1ns/1ps

`ifndef TURBO
 `define TURBO 1
`endif
`ifndef FREEZES
 `define FREEZES 60
`endif

module tb_floatgame;

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
reg  [39:0] kb_rows = {40{1'b1}};
reg  [4:0]  joy = 5'd0;                  // fire, up, down, left, right
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
    .kb_rows(kb_rows), .joy(joy), .ltape_on(1'b0), .ltape_lvl(1'b0),
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


`ifndef FRAMES
 `define FRAMES 12
`endif
`ifndef IMG
 `define IMG "sw_img.hex"
`endif
`ifndef WAIT_PC
 `define WAIT_PC 16'h9CFC
`endif

//-----------------------------------------------------------------------------
// Snapshot port driver (as tb_snap)
//-----------------------------------------------------------------------------
reg [1:0] sack_s = 0;
always @(posedge clk56) sack_s <= {sack_s[0], snap_ack};
task automatic cmd(input [3:0] c, input [17:0] ad, input [31:0] d);
    begin
        @(posedge clk56); snap_wdata <= d;
        @(posedge clk56); snap_cmd <= c; snap_addr <= ad; snap_req <= !snap_req;
        @(posedge clk56); @(posedge clk56);
        while (snap_req != sack_s[1]) @(posedge clk56);
    end
endtask

//-----------------------------------------------------------------------------
// Fuse model
//-----------------------------------------------------------------------------
function automatic integer cd(input integer t);       // ula_contention_no_mreq (128K)
    integer rel;
    begin
        rel = t - 14361; cd = 0;
        if (rel >= 0 && rel / 228 < 192 && rel % 228 < 128)
            case ((rel % 228) % 8) 0: cd = 6; 1: cd = 5; 2: cd = 4; 3: cd = 3; 4: cd = 2; 5: cd = 1; default: cd = 0; endcase
    end
endfunction

function automatic integer fuse_read_t(input integer s, input bit hic);   // readport: early + late
    integer t;
    begin
        t = s;
        if (hic) t = t + cd(t);
        t = t + 1;
        if (hic) begin t = t + cd(t); t = t + 1; t = t + cd(t); t = t + 1; t = t + cd(t); end
        else t = t + 2;
        fuse_read_t = t;
    end
endfunction

// kind: 0 FF, 1 bitmap, 2 attribute
task automatic fuse_byte(input integer t, input [17:0] base, output [7:0] v, output integer kind);
    integer rel, row, x, col;
    begin
        v = 8'hFF; kind = 0;
        rel = t - 14362;
        if (rel >= 0) begin
            row = rel / 228; x = rel % 228;
            if (row < 192 && x < 128) begin
                col = (x / 8) * 2 + ((x % 8 == 4 || x % 8 == 5) ? 1 : 0);
                case (x % 8)
                    2, 4: begin v = sd_peek(base + (((row & 8'hC0) << 5) | ((row & 7) << 8) | ((row & 8'h38) << 2) | col)); kind = 1; end
                    3, 5: begin v = sd_peek(base + 6144 + (row / 8) * 32 + col); kind = 2; end
                    default: ;
                endcase
            end
        end
    end
endtask

//-----------------------------------------------------------------------------
// Logging
//-----------------------------------------------------------------------------
integer tcount = 0, s_start = 0, frame = 0;
reg [15:0] last_pc = 0;
reg        logging = 0;
integer    n_rd = 0, n_diff = 0, n_wait = 0, polls = 0, first_fuse = -1, n_false = 0, n_late = 0;
integer    rtl_kind;
always @(posedge clk) if (u_bus.mstart && !u_bus.cpu_m1_n) last_pc = u_bus.cpu_a;
reg        in_game = 0;                 // the sync loop has run
always @(posedge clk) if (last_pc == `WAIT_PC) in_game <= 1'b1;

always @(posedge clk) begin
    reg [7:0] fv, ev; integer fk, ft; reg [17:0] base;
    if (u_bus.int_start) begin tcount = 0; if (logging) frame++; end
    else if (u_bus.cen_raw) tcount = tcount + 1;
    if (u_bus.mstart) s_start = tcount;
    // floating-bus class the RTL used, at its sample (zx_bus: io_k = 1, chk[1])
    if (u_bus.chk[1] && u_bus.io_k == 3'd1 && u_bus.smp_io && !u_bus.smp_iow)
        rtl_kind = !u_bus.fb_scr ? 0 : u_bus.fb_attr ? 2 : 1;
    if (logging && u_bus.cen && u_bus.cpu_ts == 3'd2 && u_bus.smp_io && !u_bus.smp_iow &&
        u_bus.a_lat[0] && u_bus.a_lat[5] && !(u_bus.a_lat[15:14] == 2'b11 && !u_bus.a_lat[1])) begin
        base = u_bus.p7ffd[3] ? 18'h1C000 : 18'h14000;
        ft = fuse_read_t(s_start, u_bus.a_lat[15:14] == 2'b01);
        fuse_byte(ft, base, fv, fk);
        n_rd++;
        if (fv !== u_bus.cpu_din) n_diff++;
        if (last_pc == `WAIT_PC) begin
            ev = u_bus.cpu_regs[103:96];                        // E
            polls++;
            if (first_fuse < 0 && fv == ev) first_fuse = s_start;
            if (u_bus.cpu_din == ev) begin
                n_wait++;
                if (rtl_kind == 1) n_false++;
                if (first_fuse < 0 || first_fuse < s_start) n_late++;
                $display("frame %3d wait E=%02h exit T %6d (row %3d) after %4d polls, RTL byte from %s, Fuse at this poll: %02h (%s, T %0d); Fuse would exit %s",
                         frame, ev, s_start, (s_start - 14361) / 228, polls,
                         rtl_kind == 2 ? "ATTR" : rtl_kind == 1 ? "BITMAP" : "idle",
                         fv, fk == 2 ? "attr" : fk == 1 ? "bitmap" : "idle", ft,
                         first_fuse < 0 ? "NOT YET" : first_fuse == s_start ? "here" : $sformatf("earlier, T %0d", first_fuse));
                $fflush();
                polls = 0; first_fuse = -1;
            end
        end
    end
end

//-----------------------------------------------------------------------------
// Run
//-----------------------------------------------------------------------------
reg [7:0]  img_b [0:131072 + 8];
reg [31:0] img_w [0:6];
initial begin
    integer f, i, c;
    f = $fopen(`IMG, "r");
    for (i = 0; i < 131072; i++) begin c = $fscanf(f, "%h\n", img_b[i]); end
    for (i = 0; i < 7; i++) begin c = $fscanf(f, "%h\n", img_w[i]); end
    c = $fscanf(f, "%h\n", img_b[131072]); c = $fscanf(f, "%h\n", img_b[131073]);
    $fclose(f);
    $readmemh("roms.mem", rom_img);
    wait (ram_ready === 1'b1);
    for (i = 0; i < 32768; i++) sd_poke(18'h20000 + i, rom_img[i]);
    for (i = 0; i < 131072; i++) sd_poke(i, img_b[i]);
`ifdef SIDEWIZE_KEMPSTON
    sd_poke(18'h08000 + 18'h12CF, 8'hA2); sd_poke(18'h08000 + 18'h12D0, 8'h65);   // (92CF) = 65A2
`endif
    repeat (20) @(posedge clk);
    rst_n = 1;
    repeat (4) @(posedge clk);
    snap_freeze <= 1;
    run = 1;
    while (!u_bus.snap_frozen) @(posedge clk);
    for (i = 0; i < 7; i++) cmd(4, i, img_w[i]);
    cmd(5, 0, 0);
    cmd(9, 0, {21'd0, img_b[131073][2:0], img_b[131072]});
    snap_freeze <= 0;
    $display("started: PC %04h 7FFD %02h", img_w[2][15:0], img_b[131072]);
    // Sidewize: control = Kempston (as menu key 2 sets it, without its 1 s port-1F check),
    // then fire ends the title music and starts the game
    repeat (2) @(posedge u_bus.int_start);
    // pulse fire until the game runs
    while (!in_game) begin
        repeat (3) if (!in_game) @(posedge u_bus.int_start);
        joy = joy ^ 5'b10000;
        $display("%t fire %0d, PC~%04h", $realtime, joy[4], last_pc); $fflush();
    end
    joy = 5'd0;
    @(posedge u_bus.int_start);
    $display("%t game running: logging", $realtime); $fflush();
    logging = 1;
    // play: the player moves around (one direction for 6 frames each, fire held now and then)
    while (frame < `FRAMES) begin
        case ((frame / 6) % 6)
            0: joy = 5'b01000; 1: joy = 5'b00001; 2: joy = 5'b00100; 3: joy = 5'b10010; 4: joy = 5'b00000; default: joy = 5'b10001;
        endcase
        @(posedge clk);
    end
    $display("%0d frames: %0d floating-bus reads, %0d differ from Fuse; %0d sync exits, %0d on a BITMAP byte, %0d later than Fuse's first match",
             frame, n_rd, n_diff, n_wait, n_false, n_late);
    $finish;
end
reg [7:0] rom_img [0:49151];

always @(posedge clk) if (logging && u_bus.int_start && frame % 5 == 0) $display("%t frame %0d PC~%04h", $realtime, frame, last_pc);
initial begin #(`ifdef TMAX `TMAX `else 2_000_000_000 `endif); $display("TIMEOUT"); $finish; end

endmodule
