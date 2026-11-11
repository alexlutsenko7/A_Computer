/* tb_floatgame -- a game's floating-bus sync on zx_bus + T80 (Sidewize) */
/* */
/* Loads a .z80 image (mk_z80img.py: RAM pages, register words, 7FFD, border) */
/* into the SDRAM model, restores the registers through the snapshot port */
/* (DIR + LOAD) and runs it. Every read of an unanswered port (A0 = 1, A5 = 1) */
/* is compared with Fuse 1.6's rule: the port is read after the whole I/O */
/* contention (early: C:1 then T1; late: contended high byte C:1,C:1,C:1 between */
/* T2..T4, otherwise 2 T), i.e. at the start of T4; byte phase x = t - 14362 - */
/* 228 * row (0..127): x mod 8 = 2 bitmap, 3 attr, 4/5 the same + 1 column. */
/* The sync loop at WAIT_PC (IN A,(C) ; CP E ; JP NZ) is logged per exit. */
/* Sidewize (+define+SIDEWIZE_KEMPSTON): Kempston control poked in, fire starts the game; then the joystick moves. */
/* +define+FRAMES=n (default 12)   +define+IMG="file"  +define+WAIT_PC=16'h.... */
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
module tb_floatgame;

/* half periods of a clock period */
localparam integer HALVES = 2;
/* the SDRAM controller's reset ends after 200 ns */
localparam integer RAM_RST_NS = 200;
/* both data masks high */
localparam integer DQM_OFF = 3;
/* keys of the Spectrum matrix */
localparam integer MATRIX_KEYS = 40;
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
/* T-states left of an uncontended port read */
localparam integer UNCONT_REST = 2;
/* frame T-state of the first screen fetch */
localparam integer T_FIRST_FETCH = 14362;
/* bitmap bytes fetched per cell */
localparam integer CELL_BYTES = 2;
/* cell slot of the second bitmap byte */
localparam integer SLOT_BITMAP2 = 4;
/* cell slot of the second attribute byte */
localparam integer SLOT_ATTR2 = 5;
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
/* byte kind 2: an attribute byte */
localparam integer KIND_ATTR = 2;
/* T-state 2 */
localparam [2:0] TS_T2 = 3'd2;
/* SDRAM address of RAM page 7 */
localparam [17:0] PAGE7 = 18'h1C000;
/* SDRAM address of RAM page 5 */
localparam [17:0] PAGE5 = 18'h14000;
/* bytes of the 128 KB RAM */
localparam integer RAM_SIZE = 131072;
/* register words of the CPU */
localparam integer REG_WORDS = 7;
/* bytes of the two ROMs */
localparam integer ROM_SIZE = 32768;
/* clocks of the reset */
localparam integer RESET_CLKS = 20;
/* clocks between the reset's end and the start */
localparam integer RUN_CLKS = 4;
/* the wait is done twice */
localparam integer TWICE = 2;
/* frames between two fire button toggles */
localparam integer FIRE_FRAMES = 3;
/* frames per joystick direction */
localparam integer DIR_FRAMES = 6;
/* steps of the joystick pattern */
localparam integer DIR_STEPS = 6;
/* frames between two progress lines */
localparam integer PROGRESS_EVERY = 5;

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
reg  [39:0] kb_rows = {MATRIX_KEYS{1'b1}};
/* fire, up, down, left, right */
reg  [4:0]  joy = 5'd0;
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

/* the AY at half the clock */
reg ay_cen = 0;
always @(posedge clk) ay_cen <= !ay_cen;
/* the AY */
jt49_bus u_ay (
    .rst_n(rst_n), .clk(clk), .clk_en(ay_cen), .bdir(ay_bdir), .bc1(ay_bc1), .din(ay_din), .sel(1'b0),
    .dout(ay_dout), .sound(), .A(), .B(), .C(), .sample(), .IOA_in(8'hFF), .IOA_out(), .IOB_in(8'hFF), .IOB_out()
);

/* defaults: frames logged, the memory image, the address of the game's sync loop */
`ifndef FRAMES
 `define FRAMES 12
`endif
/* the memory image */
`ifndef IMG
 `define IMG "sw_img.hex"
`endif
/* the sync loop's address */
`ifndef WAIT_PC
 `define WAIT_PC 16'h9CFC
`endif

/* Snapshot port driver (as tb_snap) */
reg [1:0] sack_s = 0;
always @(posedge clk56) sack_s <= {sack_s[0], snap_ack};
/* one command: data first, then the request toggles */
task automatic cmd(input [3:0] c, input [17:0] ad, input [31:0] d);
    begin
        @(posedge clk56);
        snap_wdata <= d;
/* the next clock */
        @(posedge clk56);
/* command, address */
        snap_cmd <= c;
        snap_addr <= ad;
        snap_req <= !snap_req;
/* the acknowledge is waited for */
        @(posedge clk56);
        @(posedge clk56);
        while (snap_req != sack_s[1])
        begin
/* one more clock */
            @(posedge clk56);
        end
    end
endtask

/* Fuse model */
/* ula_contention_no_mreq (128K) */
function automatic integer cd(input integer t);
    integer rel;
    begin
/* T-states since the first contended one */
        rel = t - T_FIRST_CONT;
        cd = 0;
        if (rel >= 0 && rel / LINE_TSTATES < SCR_LINES && rel % LINE_TSTATES < SCR_TSTATES)
        begin
/* 6, 5, 4, 3, 2, 1, 0, 0 by the place in the cell */
            case ((rel % LINE_TSTATES) % CELL)
                0: cd = 6;
                1: cd = 5;
/* 4 and less */
                2: cd = 4;
/* the later ones */
                3: cd = 3;
                4: cd = 2;
                5: cd = 1;
/* none */
                default: cd = 0;
            endcase
        end
    end
endfunction

/* readport: early + late */
function automatic integer fuse_read_t(input integer s, input bit hic);
    integer t;
    begin
/* from the start of the cycle */
        t = s;
        if (hic)
        begin
            t = t + cd(t);
        end
/* the second T-state */
        t = t + 1;
        if (hic)
        begin
            t = t + cd(t);
/* the third */
            t = t + 1;
            t = t + cd(t);
/* the fourth */
            t = t + 1;
            t = t + cd(t);
        end
        else
        begin
/* not contended: two more */
            t = t + UNCONT_REST;
        end
/* the result */
        fuse_read_t = t;
    end
endfunction

/* kind: 0 FF, 1 bitmap, 2 attribute */
task automatic fuse_byte(input integer t, input [17:0] base, output [7:0] v, output integer kind);
    integer rel, row, x, col;
    begin
        v = 8'hFF;
/* no screen byte yet */
        kind = 0;
/* T-states since the first picture byte */
        rel = t - T_FIRST_FETCH;
        if (rel >= 0)
        begin
/* line and place in the line */
            row = rel / LINE_TSTATES;
            x = rel % LINE_TSTATES;
            if (row < SCR_LINES && x < SCR_TSTATES)
            begin
/* the column of the byte fetched */
                col = (x / CELL) * CELL_BYTES + ((x % CELL == SLOT_BITMAP2 || x % CELL == SLOT_ATTR2) ? 1 : 0);
                case (x % CELL)
                    2, 4:
                    begin
/* a bitmap byte */
                        v = sd_peek(base + (((row & ROW_THIRD_MASK) << ROW_THIRD_SHIFT) | ((row & ROW_PIXEL_MASK) << ROW_PIXEL_SHIFT) | ((row & ROW_CHAR_MASK) << ROW_CHAR_SHIFT) | col));
                        kind = 1;
                    end
                    3, 5:
                    begin
/* an attribute byte */
                        v = sd_peek(base + BITMAP_BYTES + (row / CHAR_LINES) * CHARS_PER_ROW + col);
                        kind = KIND_ATTR;
                    end
                    default: ;
                endcase
            end
        end
    end
endtask

/* Logging */
integer tcount = 0, s_start = 0, frame = 0;
reg [15:0] last_pc = 0;
reg        logging = 0;
/* counters */
integer    n_rd = 0, n_diff = 0, n_wait = 0, polls = 0, first_fuse = -1, n_false = 0, n_late = 0;
integer    rtl_kind;
/* the PC of the last opcode fetch */
always @(posedge clk)
    if (u_bus.mstart && !u_bus.cpu_m1_n)
    begin
        last_pc = u_bus.cpu_a;
    end
/* the sync loop has run */
reg        in_game = 0;
always @(posedge clk)
    if (last_pc == `WAIT_PC)
    begin
/* in the game from now on */
        in_game <= 1'b1;
    end

/* every read of the port is checked */
always @(posedge clk)
begin
    reg [7:0] fv, ev;
    integer fk, ft;
/* the screen's base address */
    reg [17:0] base;
/* the frame starts */
    if (u_bus.int_start)
    begin
/* T-states from 0; frames counted while logging */
        tcount = 0;
        if (logging)
        begin
            frame++;
        end
    end
/* a T-state; an opcode fetch of the NOP run */
    else if (u_bus.cen_raw)
    begin
        tcount = tcount + 1;
    end
    if (u_bus.mstart)
    begin
/* its T-state; a read of port FF */
        s_start = tcount;
    end
/* floating-bus class the RTL used, at its sample (zx_bus: io_k = 1, chk[1]) */
    if (u_bus.chk[1] && u_bus.io_k == 3'd1 && u_bus.smp_io && !u_bus.smp_iow)
    begin
        rtl_kind = !u_bus.fb_scr ? 0 : u_bus.fb_attr ? KIND_ATTR : 1;
    end
/* a read of the floating-bus port while logging */
    if (logging && u_bus.cen && u_bus.cpu_ts == TS_T2 && u_bus.smp_io && !u_bus.smp_iow &&
        u_bus.a_lat[0] && u_bus.a_lat[5] && !(u_bus.a_lat[15:14] == 2'b11 && !u_bus.a_lat[1]))
    begin
/* the screen's page; Fuse's T-state and byte */
        base = u_bus.p7ffd[3] ? PAGE7 : PAGE5;
        ft = fuse_read_t(s_start, u_bus.a_lat[15:14] == 2'b01);
        fuse_byte(ft, base, fv, fk);
/* counted; a difference from Fuse */
        n_rd++;
        if (fv !== u_bus.cpu_din)
        begin
            n_diff++;
        end
/* inside the game's sync loop */
        if (last_pc == `WAIT_PC)
        begin
/* E */
            ev = u_bus.cpu_regs[103:96];
            polls++;
/* Fuse's first match */
            if (first_fuse < 0 && fv == ev)
            begin
                first_fuse = s_start;
            end
/* the loop ends on this byte */
            if (u_bus.cpu_din == ev)
            begin
                n_wait++;
/* on a bitmap byte: false */
                if (rtl_kind == 1)
                begin
                    n_false++;
                end
/* later than Fuse */
                if (first_fuse < 0 || first_fuse < s_start)
                begin
                    n_late++;
                end
/* reported */
                $display("frame %3d wait E=%02h exit T %6d (row %3d) after %4d polls, RTL byte from %s, Fuse at this poll: %02h (%s, T %0d); Fuse would exit %s",
                         frame, ev, s_start, (s_start - T_FIRST_CONT) / LINE_TSTATES, polls,
                         rtl_kind == KIND_ATTR ? "ATTR" : rtl_kind == 1 ? "BITMAP" : "idle",
                         fv, fk == KIND_ATTR ? "attr" : fk == 1 ? "bitmap" : "idle", ft,
                         first_fuse < 0 ? "NOT YET" : first_fuse == s_start ? "here" : $sformatf("earlier, T %0d", first_fuse));
/* flushed; the next wait starts */
                $fflush();
                polls = 0;
                first_fuse = -1;
            end
        end
    end
end

/* Run */
reg [7:0]  img_b [0:131072 + 8];
reg [31:0] img_w [0:6];
/* the test */
initial
begin
    integer f, i, c;
    f = $fopen(`IMG, "r");
/* the RAM image */
    for (i = 0; i < RAM_SIZE; i++)
    begin
        c = $fscanf(f, "%h\n", img_b[i]);
    end
/* the registers */
    for (i = 0; i < REG_WORDS; i++)
    begin
        c = $fscanf(f, "%h\n", img_w[i]);
    end
/* 7FFD and the border */
    c = $fscanf(f, "%h\n", img_b[131072]);
    c = $fscanf(f, "%h\n", img_b[131073]);
    $fclose(f);
/* the ROMs */
    $readmemh("roms.mem", rom_img);
    wait (ram_ready === 1'b1);
/* into the SDRAM model */
    for (i = 0; i < ROM_SIZE; i++)
    begin
        sd_poke(18'h20000 + i, rom_img[i]);
    end
/* the RAM */
    for (i = 0; i < RAM_SIZE; i++)
    begin
        sd_poke(i, img_b[i]);
    end
`ifdef SIDEWIZE_KEMPSTON
/* (92CF) = 65A2 */
    sd_poke(18'h08000 + 18'h12CF, 8'hA2);
    sd_poke(18'h08000 + 18'h12D0, 8'h65);
`endif
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
    snap_freeze <= 1;
/* the CPU starts */
    run = 1;
    while (!u_bus.snap_frozen)
    begin
/* frozen: the registers are loaded */
        @(posedge clk);
    end
    for (i = 0; i < REG_WORDS; i++)
    begin
        cmd(4, i, img_w[i]);
    end
/* LOAD; the machine state */
    cmd(5, 0, 0);
    cmd(9, 0, {21'd0, img_b[131073][2:0], img_b[131072]});
/* released */
    snap_freeze <= 0;
    $display("started: PC %04h 7FFD %02h", img_w[2][15:0], img_b[131072]);
/* Sidewize: control = Kempston (as menu key 2 sets it, without its 1 s port-1F check), */
/* then fire ends the title music and starts the game */
    repeat (TWICE)
    begin
        @(posedge u_bus.int_start);
    end
/* pulse fire until the game runs */
    while (!in_game)
    begin
/* three frames per toggle */
        repeat (FIRE_FRAMES)
        begin
            if (!in_game)
            begin
                @(posedge u_bus.int_start);
            end
        end
/* fire toggles */
        joy = joy ^ 5'b10000;
        $display("%t fire %0d, PC~%04h", $realtime, joy[4], last_pc);
        $fflush();
    end
/* released; logging starts with a frame */
    joy = 5'd0;
    @(posedge u_bus.int_start);
/* logging on */
    $display("%t game running: logging", $realtime);
    $fflush();
    logging = 1;
/* play: the player moves around (one direction for 6 frames each, fire held now and then) */
    while (frame < `FRAMES)
    begin
/* three directions */
        case ((frame / DIR_FRAMES) % DIR_STEPS)
            0: joy = 5'b01000;
            1: joy = 5'b00001;
/* fire with a direction, nothing, fire with another */
            2: joy = 5'b00100;
            3: joy = 5'b10010;
            4: joy = 5'b00000;
/* fire with the last direction */
            default: joy = 5'b10001;
        endcase
/* a clock */
        @(posedge clk);
    end
/* the summary */
    $display("%0d frames: %0d floating-bus reads, %0d differ from Fuse; %0d sync exits, %0d on a BITMAP byte, %0d later than Fuse's first match",
             frame, n_rd, n_diff, n_wait, n_false, n_late);
/* the end */
    $finish;
end
/* the ROM image */
reg [7:0] rom_img [0:49151];

/* progress every fifth frame */
always @(posedge clk)
    if (logging && u_bus.int_start && frame % PROGRESS_EVERY == 0)
    begin
        $display("%t frame %0d PC~%04h", $realtime, frame, last_pc);
    end
/* the simulation's time limit, unless the command line gives one */
`ifndef TMAX
`define TMAX 2_000_000_000
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
