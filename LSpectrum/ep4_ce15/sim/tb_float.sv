/* tb_float -- floating bus (zx_bus) with the real T80 */
/* */
/* Screen page 5 gets a known pattern (testbench backdoor); mk_floatprog.py runs */
/* 3000 x IN A,(FF) after each interrupt. For every port FF read the testbench */
/* computes the expected byte with its own T-state counter (Fuse 1.6's rule, 128K): */
/* read after all of the I/O cycle's contention, at the start of its 4th T-state */
/* (readport: early C:1 + 1; late C:1,+1,C:1,+1,C:1 when A, the port's high byte, is */
/* 40-7F, else + 2); x = t - 14362 - 228 * row, row 0..191, x 0..127: x mod 8 = */
/* 2 bitmap, 3 attribute, 4 / 5 the same for the next column (2 * (x / 8)); else FF. */
/* Then contention / floating bus off: all FF. */
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
module tb_float;

/* half periods of a clock period */
localparam integer HALVES = 2;
/* the SDRAM controller's reset ends after 200 ns */
localparam integer RAM_RST_NS = 200;
/* both data masks high */
localparam integer DQM_OFF = 3;
/* keys of the Spectrum matrix */
localparam integer MATRIX_KEYS = 40;
/* screen pattern: the multiplier */
localparam integer PAT_MUL = 7;
/* screen pattern: the added constant */
localparam integer PAT_ADD = 3;
/* the pattern byte used where the pattern would give FF */
localparam [7:0] NOT_FF = 8'h5A;
/* frame T-state of the first contended cycle */
localparam integer T_FIRST_CONT = 14361;
/* T-states of a line */
localparam integer LINE_TSTATES = 228;
/* lines of the picture */
localparam integer SCR_LINES = 192;
/* T-states of a line that fetch screen bytes */
localparam integer SCR_TSTATES = 128;
/* T-states of a fetch cell */
localparam integer CELL = 8;
/* frame T-state of the first screen fetch */
localparam integer T_FIRST_FETCH = 14362;
/* bitmap bytes fetched per cell */
localparam integer CELL_BYTES = 2;
/* the screen third of a line */
localparam [7:0] ROW_THIRD_MASK = 8'hC0;
/* screen address: the screen third goes to bits 12:11 */
localparam integer ROW_THIRD_SHIFT = 5;
/* the line inside a character row */
localparam integer ROW_PIXEL_MASK = 7;
/* screen address: the line inside a character goes to bits 10:8 */
localparam integer ROW_PIXEL_SHIFT = 8;
/* the character row inside a screen third */
localparam [7:0] ROW_CHAR_MASK = 8'h38;
/* screen address: the character row goes to bits 7:5 */
localparam integer ROW_CHAR_SHIFT = 2;
/* bytes of the bitmap: the attributes follow */
localparam integer BITMAP_BYTES = 6144;
/* pixel lines of a character row */
localparam integer CHAR_LINES = 8;
/* characters of a text row */
localparam integer CHARS_PER_ROW = 32;
/* T-state 2 */
localparam [2:0] TS_T2 = 3'd2;
/* T-states from T2 to the end of a port read */
localparam integer READ_REST = 3;
/* errors listed */
localparam integer LIST_MAX = 12;
/* bytes of a screen */
localparam integer SCREEN_BYTES = 6912;
/* clocks of the reset */
localparam integer RESET_CLKS = 20;
/* clocks between the reset's end and the start */
localparam integer RUN_CLKS = 4;
/* two frames */
localparam integer TWO_FRAMES = 2;
/* the simulation stops after 300 ms */
localparam integer TIME_LIMIT = 300_000_000;

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
reg         snap_freeze = 0, snap_req = 0, cont_en = 1;
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

zx_bus u_bus (
    .clk(clk), .rst_n(rst_n), .run(run), .turbo(1'b0), .diag_key(1'b0), .vid50(1'b0), .vsync_n(1'b1),
    .kb_rows({MATRIX_KEYS{1'b1}}), .joy(5'd0), .ltape_on(1'b0), .ltape_lvl(1'b0),
    .cen_tgl(cen_tgl), .hold(1'b0), .mic(mic),
    .sd_req(bus_req), .sd_we(bus_we), .sd_addr(bus_addr), .sd_din(bus_din), .sd_dout(ram_dout), .sd_ack(ram_ack),
    .sh_we(sh_we), .sh_page7(sh_page7), .sh_addr(sh_addr), .sh_data(sh_data),
    .ay_bdir(ay_bdir), .ay_bc1(ay_bc1), .ay_din(ay_din), .ay_dout(ay_dout),
    .border(border), .screen7(), .beeper(beeper), .diag_rom(), .cpu_running(),
    .snap_freeze(snap_freeze), .snap_req(snap_req), .snap_cmd(snap_cmd), .snap_addr(snap_addr),
    .snap_wdata(snap_wdata), .snap_frozen(snap_frozen), .snap_ack(snap_ack), .snap_rdata(snap_rdata),
    .cont_en(cont_en)
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

/* the test program */
reg  [7:0]  prog [0:8191];
integer     prog_len;
/* T-states of the frame, counters */
integer tcount = 0, s_start = 0, i, bad = 0, n_rd = 0, n_scr = 0, smp_t = 0, n_cont = 0;
reg     checking = 0;

/* the pattern in page 5 */
function automatic [7:0] scr(input integer off);
    reg [7:0] v;
    begin
        v = (off * PAT_MUL + PAT_ADD) & 8'hFF;
/* FF is not used (it would look like the idle bus) */
        scr = (v == 8'hFF) ? NOT_FF : v;
    end
endfunction

/* 128K contention delay at T-state t (ula_contention_no_mreq) */
function automatic integer cdelay(input integer t);
    integer rel;
    begin
        rel = t - T_FIRST_CONT;
/* no delay outside the picture */
        cdelay = 0;
        if (rel >= 0 && rel / LINE_TSTATES < SCR_LINES && rel % LINE_TSTATES < SCR_TSTATES)
        begin
            case ((rel % LINE_TSTATES) % CELL)
/* 6, 5, 4, 3, 2, 1, 0, 0 T-states by the position in the cell */
                0: cdelay = 6;
                1: cdelay = 5;
                2: cdelay = 4;
/* the later ones */
                3: cdelay = 3;
                4: cdelay = 2;
                5: cdelay = 1;
/* none */
                default: cdelay = 0;
            endcase
        end
    end
endfunction

/* the byte the ULA fetches at a T-state */
function automatic [7:0] expect_fb(input integer t);
    integer rel, row, tl, col;
    begin
        expect_fb = 8'hFF;
/* T-states since the first picture byte */
        rel = t - T_FIRST_FETCH;
        if (rel >= 0)
        begin
            row = rel / LINE_TSTATES;
/* inside the picture */
            tl = rel % LINE_TSTATES;
            if (row < SCR_LINES && tl < SCR_TSTATES)
            begin
                col = (tl / CELL) * CELL_BYTES;
/* bitmap, attribute, bitmap + 1, attribute + 1; else idle */
                case (tl % CELL)
                    2: expect_fb = scr(((row & ROW_THIRD_MASK) << ROW_THIRD_SHIFT) | ((row & ROW_PIXEL_MASK) << ROW_PIXEL_SHIFT) | ((row & ROW_CHAR_MASK) << ROW_CHAR_SHIFT) | col);
                    3: expect_fb = scr(BITMAP_BYTES + (row / CHAR_LINES) * CHARS_PER_ROW + col);
/* the second pair */
                    4: expect_fb = scr(((row & ROW_THIRD_MASK) << ROW_THIRD_SHIFT) | ((row & ROW_PIXEL_MASK) << ROW_PIXEL_SHIFT) | ((row & ROW_CHAR_MASK) << ROW_CHAR_SHIFT) | (col + 1));
                    5: expect_fb = scr(BITMAP_BYTES + (row / CHAR_LINES) * CHARS_PER_ROW + col + 1);
                    default: ;
                endcase
            end
        end
    end
endfunction

/* every read of the port is checked */
always @(posedge clk)
begin
/* the frame starts */
    if (u_bus.int_start)
    begin
        tcount = 0;
    end
/* a T-state; the start of an M-cycle */
    else if (u_bus.cen_raw)
    begin
        tcount = tcount + 1;
    end
    if (u_bus.mstart)
    begin
/* its T-state; a read of port FF */
        s_start = tcount;
    end
    if (checking && u_bus.cen && u_bus.cpu_ts == TS_T2 && u_bus.smp_io && !u_bus.smp_iow && u_bus.a_lat[7:0] == 8'hFF)
    begin
        n_rd++;
/* a screen byte came */
        if (u_bus.cpu_din != 8'hFF)
        begin
            n_scr++;
        end
/* Fuse readport: early + late contention, then the read (high byte 40-7F, from A: contended) */
        smp_t = s_start;
        if (cont_en && u_bus.a_lat[15:14] == 2'b01)
        begin
            smp_t = smp_t + cdelay(smp_t) + 1;
/* three more T-states, each with its contention */
            smp_t = smp_t + cdelay(smp_t) + 1;
            smp_t = smp_t + cdelay(smp_t) + 1;
            smp_t = smp_t + cdelay(smp_t);
        end
        else
        begin
/* not contended; reads with a contended high byte are counted */
            smp_t = smp_t + READ_REST;
        end
        if (u_bus.a_lat[15:14] == 2'b01)
        begin
            n_cont++;
        end
/* the byte must be the one the ULA would fetch then */
        if (u_bus.cpu_din !== (cont_en ? expect_fb(smp_t) : 8'hFF))
        begin
            bad++;
            if (bad < LIST_MAX)
            begin
/* the first few are listed */
                $display("  ERROR: IN (%04h) at T %0d: %02h, expected %02h", u_bus.a_lat, s_start, u_bus.cpu_din, cont_en ? expect_fb(smp_t) : 8'hFF);
            end
        end
    end
end

/* the test */
initial
begin
    integer f, c;
    f = $fopen("float_prog.hex", "r");
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
    for (i = 0; i < SCREEN_BYTES; i++)
    begin
/* the pattern into the screen */
        sd_poke(18'h14000 + i, scr(i));
    end
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
/* the CPU starts; two frames to settle */
    run = 1;
    repeat (TWO_FRAMES)
    begin
        @(posedge u_bus.int_start);
    end
/* two frames checked */
    checking = 1;
    repeat (TWO_FRAMES)
    begin
        @(posedge u_bus.int_start);
    end
/* the result; then with the floating bus off */
    $display("floating bus on: %0d reads of port FF, %0d returned screen bytes, %0d with a contended high byte", n_rd, n_scr, n_cont);
/* the same with contention off */
    cont_en = 0;
    n_rd = 0;
/* counters cleared; one frame */
    n_scr = 0;
    @(posedge u_bus.int_start);
    repeat (1)
    begin
/* one more; the result */
        @(posedge u_bus.int_start);
    end
    $display("floating bus off: %0d reads, %0d not FF", n_rd, n_scr);
    if (bad || u_sdram.errors || n_rd == 0)
    begin
/* the verdict */
        $display("FAIL (%0d)", bad);
    end
    else
    begin
        $display("FLOATING BUS TEST PASSED");
    end
/* the end */
    $finish;
end

initial
begin
    #TIME_LIMIT;
/* the simulation hangs */
    $display("TIMEOUT");
    $finish;
end

endmodule
