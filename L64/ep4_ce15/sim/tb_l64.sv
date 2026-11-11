/* tb_l64 -- whole C64 (c64_system) with ROMs from the flash model: */
/* flash (bit-reversed, as in the .jic) -> ROM loader -> SDRAM model (with I/O */
/* delays, as tb_lspectrum) -> T65 boots the KERNAL, BASIC prints its banner. */
/* */
/* ROM image: c64roms.mem in this folder (tools/mk_c64rom.py from your own ROM files; */
/* not part of the project). For speed, run_sim.sh can patch the KERNAL's RAM test */
/* (it only sets the top of memory), see there. */
/* +define+RUN_MS=<ms>   longest simulated time (default 400); stops at "READY." */
/* +define+DISK          1541 test: disk.d64 (tools/mk_d64.py) in the drive (the testbench does the */
/* ESP32's job: the track under the head is put into the track buffer), after */
/* READY it types LOAD"$",8 and waits for the directory (disk name TEST, file */
/* HELLO) and READY.; needs a ROM image with the 1541 ROM. RUN_MS counts from */
/* the start of the load (default 4000 with DISK). */
/* +define+M50           VGA in the 50 Hz mode (default: 800 x 600 @ 60 Hz) */
/* +define+DIRTYRAM      the RAM holds a game's reset protection at power-up, as after a game and */
/* Ctrl+Alt+Del (SDRAM keeps its contents): "CBM80" at $8004, a border-flashing */
/* loop at $8209; the RAM clear must remove it, so BASIC starts */
/* +define+SNAPTEST      after READY: freeze, read registers / CIA state / I/O shadow through the snapshot */
/* port, restore with a test program in the restore bank (red border, A/X/Y = */
/* 55/66/77, RTI into the frozen state) and check that the C64 runs on */
/* +define+TURBO         turbo (F6) allowed: without DISK the CPU runs turbo all the time; with DISK */
/* while the 1541 motor runs, and each new track reaches the buffer 2 ms */
/* after the head moved (as the ESP32 takes its time; the C64 waits) */
/* Output: the text screen ($0400) as text every 50 ms, screen.ppm (one VGA frame). */
`timescale 1ns/1ps
`ifndef RUN_MS
 `ifdef DISK
/* with a disk: 4 seconds */
  `define RUN_MS 4000
 `else
  `define RUN_MS 400
/* the defaults' end */
 `endif
`endif

module tb_l64;

/* clk toggles on every third edge of clk_sd */
localparam integer PH_LAST = 2;
/* the pixel clock starts 3.7 ns late: no fixed relation to clk */
localparam real PCLK_SKEW = 3.7;
/* the reset ends after 300 ns */
localparam integer RST_NS = 300;
/* both data masks high */
localparam integer DQM_OFF = 3;
/* bytes of the cartridge signature left in RAM */
localparam integer SIGNATURE_LEN = 9;
/* bytes of the reset handler left in RAM */
localparam integer HANDLER_LEN = 15;
/* screen code without the inverse bit */
localparam [7:0] CODE_MASK = 8'h7F;
/* screen codes 1 to 26 are the letters */
localparam integer CODE_LETTERS_END = 27;
/* ASCII @: letters follow it */
localparam [7:0] ASCII_AT = 8'h40;
/* screen codes from 32 on are ASCII */
localparam integer CODE_SIGNS = 32;
/* screen codes below 64 are shown; the rest as # */
localparam integer CODE_ASCII_END = 64;
/* rows of the text screen */
localparam integer TEXT_ROWS = 25;
/* columns of the text screen */
localparam integer TEXT_COLS = 40;
/* address of the text screen */
localparam [17:0] SCREEN_ADDR = 18'h400;
/* SDRAM accesses listed */
localparam integer SD_LOG_MAX = 60;
/* bus log lines */
localparam integer BUS_LOG_MAX = 40;
/* first raster line of the bus log */
localparam [8:0] LOG_LINE1 = 9'd59;
/* second raster line of the bus log */
localparam [8:0] LOG_LINE2 = 9'd60;
/* entries of the 1541's job queue */
localparam integer JOBS = 6;
/* job queue changes listed */
localparam integer JOB_LOG_MAX = 200;
/* lines of the drive log */
localparam integer DRIVE_LOG_LINES = 60;
/* last track of speed zone 3 */
localparam integer ZONE3_LAST = 17;
/* sectors per track in zone 3 */
localparam integer ZONE3_SECTORS = 21;
/* last track of speed zone 2 */
localparam integer ZONE2_LAST = 24;
/* sectors per track in zone 2 */
localparam integer ZONE2_SECTORS = 19;
/* last track of speed zone 1 */
localparam integer ZONE1_LAST = 30;
/* sectors per track in zone 1 */
localparam integer ZONE1_SECTORS = 18;
/* sectors per track in zone 0 */
localparam integer ZONE0_SECTORS = 17;
/* bytes of a disk sector */
localparam integer SECTOR = 256;
/* last track of a disk */
localparam integer TRACK_MAX = 35;
/* SDRAM address of the first frame buffer */
localparam [19:0] FB_BASE = 20'h40000;
/* SDRAM bytes of one frame buffer */
localparam [19:0] FB_SIZE = 20'h20000;
/* the border's colour pair in the frame buffer (two light blue pixels) */
localparam [7:0] SHOT_BORDER = 8'hEE;
/* the screen's colour pair in the frame buffer (two blue pixels) */
localparam [7:0] SHOT_SCREEN = 8'h66;
/* the byte written to the track buffer and read back */
localparam [7:0] TB_TEST_BYTE = 8'h41;
/* colour 14: light blue (the border after a reset) */
localparam [3:0] COL_LIGHT_BLUE = 4'd14;
/* start of the restore program inside the restore bank */
localparam [17:0] RESTORE_PC = 18'h2000;
/* microseconds the restore mode may take */
localparam integer RESTORE_US_MAX = 2000;
/* A after the restore program */
localparam [7:0] RESTORED_A = 8'h55;
/* X after the restore program */
localparam [7:0] RESTORED_X = 8'h66;
/* Y after the restore program */
localparam [7:0] RESTORED_Y = 8'h77;
/* colour 2: red */
localparam [3:0] COL_RED = 4'd2;
/* characters of the text screen */
localparam integer SCREEN_CHARS = 1000;
/* the vertical scroll after a reset of the C64 */
localparam [2:0] YSCROLL_DEF = 3'd3;
/* colour 6: blue (the background after a reset) */
localparam [3:0] COL_BLUE = 4'd6;
/* milliseconds between two reports */
localparam integer STEP_MS = 50;
/* 10 ms steps waited for the drive's motor to stop */
localparam integer IDLE_WAIT_MAX = 300;
/* characters of LOAD"$",8 with RETURN */
localparam integer LOAD_CMD_LEN = 10;
/* READY. is on the screen twice after the directory has loaded */
localparam integer READY_TWICE = 2;
/* characters of LIST with RETURN */
localparam integer LIST_CMD_LEN = 5;
/* vertical syncs that must have come */
localparam integer VS_MIN = 2;
/* clk_sd half period (94.53 MHz); clk = clk_sd / 3, edges aligned */
localparam realtime HSD = 5.289;
localparam real T_CK  = 2 * HSD;
/* pin delays, the SDRAM clock's shift */
localparam real TCO   = 4.0;
localparam real TBACK = 0.5;
localparam real SD_SHIFT = 1.339;

/* the two clocks, clk every third edge of clk_sd */
reg clk_sd = 0, clk = 0;
integer ph = 0;
always #(HSD)
begin
/* the faster clock; the phase */
    clk_sd = ~clk_sd;
    ph = (ph == PH_LAST) ? 0 : ph + 1;
    if (ph == 0)
    begin
/* the machine clock */
        clk = ~clk;
    end
end

/* pixel clock: 39.80 MHz (60 Hz) or 31.51 MHz (50 Hz), not related to clk / clk_sd */
`ifdef M50
localparam realtime HP = 15.867;
localparam integer  FW = 1008, FH = 624;
/* the 50 Hz mode */
wire m60 = 1'b0;
`else
localparam realtime HP = 12.562;
/* the frame's size; the 60 Hz mode */
localparam integer  FW = 1056, FH = 628;
wire m60 = 1'b1;
`endif
/* the pixel clock */
reg pclk = 0;
/* the pixel clock, free running */
initial
begin
    #PCLK_SKEW;
    forever
    begin
/* half a period; the reset */
        #(HP) pclk = ~pclk;
    end
end

reg rst_n = 0;
initial #RST_NS rst_n = 1;

/* the keyboard's UART line, idle */
reg kbd_rx = 1;
/* SDRAM pins */
wire        cke, cs_n, ras_n, cas_n, we_n, dq_oe;
wire [1:0]  ba, dqm;
wire [12:0] a;
/* data out and in */
wire [15:0] dq_o;
reg  [15:0] dq_i;
wire        f_dclk, f_ncs, f_mosi, f_miso;
/* the VGA pins, audio, LED; the machine */
wire [3:0]  vr, vg, vb;
wire        hs, vs, aud, led;

c64_system #(.FLASH_DIV(2), .KBD_WAIT_MS(1), .FONT_HEX("../../../AMenu/ep4_ce15/rtl/menu_font.hex")) u_sys (
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

/* the flash with the ROM image */
flash_model #(.BASE(24'h580000), .LEN(49152), .REVERSE(1), .FILE("c64roms.mem")) u_flash (
    .dclk(f_dclk), .ncs(f_ncs), .mosi(f_mosi), .miso(f_miso));

/* pins as seen by the SDRAM (transport delays, as tb_lspectrum) */
reg         m_clk = 0, m_cke = 0, m_cs_n = 1, m_ras_n = 1, m_cas_n = 1, m_we_n = 1;
reg  [1:0]  m_ba = 0, m_dqm = DQM_OFF;
reg  [12:0] m_a = 0;
/* data */
reg  [15:0] m_dq_drv = 'z;
wire [15:0] m_dq;
always @(clk_sd) m_clk <= #(TCO + SD_SHIFT) ~clk_sd;
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

/* a byte straight into the model */
task automatic sd_poke(input [17:0] ad, input [7:0] v);
    logic [15:0] w;
    logic [23:0] key;
    begin
/* {bank, row, column} as in sdram_model */
        key = {ad[11:10], 7'd0, ad[17:12], ad[9:1]};
        w = u_sdram.mem.exists(key) ? u_sdram.mem[key] : 16'h0000;
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
        u_sdram.mem[key] = w;
    end
endtask

function automatic [7:0] sd_peek(input [19:0] ad);
    logic [15:0] w;
/* the model's key of the address */
    logic [23:0] key;
    begin
/* {bank, row, column} as in sdram_model */
        key = {ad[11:10], 5'd0, ad[19:12], ad[9:1]};
        w = u_sdram.mem.exists(key) ? u_sdram.mem[key] : 16'hxxxx;
/* its lane */
        sd_peek = ad[0] ? w[15:8] : w[7:0];
    end
endfunction

`ifdef DIRTYRAM
initial
begin
/* a cartridge signature and a reset handler, as a game leaves them */
    static byte cart[9]  = '{8'h09, 8'h82, 8'h09, 8'h82, 8'hC3, 8'hC2, 8'hCD, 8'h38, 8'h30};
    static byte loop[15] = '{8'hA2, 8'hFF, 8'h78, 8'h9A, 8'hD8, 8'hE8, 8'h8E, 8'h11, 8'hD0,
                             8'hEE, 8'h20, 8'hD0, 8'h4C, 8'h12, 8'h82};
    for (int k = 0; k < SIGNATURE_LEN; k++)
    begin
/* into the RAM */
        sd_poke(18'h08000 + k, cart[k]);
    end
    for (int k = 0; k < HANDLER_LEN; k++)
    begin
        sd_poke(18'h08209 + k, loop[k]);
    end
/* reported */
    $display("RAM before power-up: CBM80 at $8004, reset handler at $8209");
end
`endif

/* screen code -> ASCII (upper case set) */
function automatic byte scr2asc(input [7:0] c);
    logic [7:0] b;
    begin
        b = c & CODE_MASK;
/* unknown */
        if (^b === 1'bx)
        begin
            scr2asc = "?";
        end
        else if (b == 0)
        begin
/* letters */
            scr2asc = "@";
        end
        else if (b < CODE_LETTERS_END)
        begin
            scr2asc = ASCII_AT + b;
        end
/* not shown; digits and signs as ASCII */
        else if (b < CODE_SIGNS)
        begin
            scr2asc = " ";
        end
        else if (b < CODE_ASCII_END)
        begin
/* graphics characters */
            scr2asc = b;
        end
        else
        begin
            scr2asc = "#";
        end
    end
endfunction

string screen_txt;
/* the text screen as text */
task automatic show_screen;
    integer r, c;
    string line;
    begin
/* empty; a headline */
        screen_txt = "";
        $display("%t screen:", $time);
        for (r = 0; r < TEXT_ROWS; r++)
        begin
/* 25 lines of 40 characters */
            line = "";
            for (c = 0; c < TEXT_COLS; c++)
            begin
                line = {line, string'(scr2asc(sd_peek(SCREEN_ADDR + r * TEXT_COLS + c)))};
            end
/* printed and kept */
            $display("  |%s|", line);
            screen_txt = {screen_txt, line};
        end
    end
endtask

function automatic integer count_text(input string s, input string t);
/* how often a text is on the screen */
    integer i;
    begin
        count_text = 0;
        for (i = 0; i + t.len() <= s.len(); i++)
        begin
/* found once more */
            if (s.substr(i, i + t.len() - 1) == t)
            begin
                count_text++;
            end
        end
    end
endfunction

function automatic bit has_text(input string s, input string t);
/* is a text on the screen? */
    integer i;
    begin
        has_text = 0;
        for (i = 0; i + t.len() <= s.len(); i++)
        begin
/* found */
            if (s.substr(i, i + t.len() - 1) == t)
            begin
                has_text = 1;
            end
        end
    end
endfunction

/* one VGA frame (FW x FH pixel clocks from a vsync edge, blanking included) */
task automatic grab(input string fname);
    integer f, x, y;
    reg vs0;
    begin
/* a vsync edge is waited for; the file */
        vs0 = vs;
        @(vs);
        f = $fopen(fname, "w");
/* a PPM header, then every pixel of the frame */
        $fwrite(f, "P3\n%0d %0d\n255\n", FW, FH);
        for (y = 0; y < FH; y++)
        begin
            for (x = 0; x < FW; x++)
            begin
/* one pixel */
                @(posedge pclk);
                $fwrite(f, "%0d %0d %0d\n", vr * 17, vg * 17, vb * 17);
            end
        end
/* the file is written */
        $fclose(f);
        $display("%t wrote %s", $time, fname);
    end
endtask

`ifdef TRACE
/* a log of the first SDRAM accesses */
integer n_sd = 0;
always @(posedge clk_sd)
    if (u_sys.ld_done && n_sd < SD_LOG_MAX)
    begin
/* counted and listed */
        n_sd++;
        $display("%t sd: req %b we %b addr %05h ack %b | a_busy %b bus_pend %b tgl %b/%b sm_pend %b | ram state %0d pend %b",
                 $time, u_sys.u_ram.req, u_sys.u_ram.we, u_sys.u_ram.addr, u_sys.ram_ack, u_sys.a_busy, u_sys.bus_pend,
                 u_sys.m_req_tgl, u_sys.m_rq_d, u_sys.sm_pend, u_sys.u_ram.state, u_sys.u_ram.pend);
    end
/* first CPU cycles after the reset: address, R/W, data in, arbiter state */
integer n_tr = 0;
always @(posedge clk)
    if (u_sys.cpu_ce && u_sys.c64_rst_n && n_tr < `TRACE)
    begin
/* counted and listed */
        n_tr++;
        $display("%t cpu A %04h rw %b di %02h | own_vic %b cpu_cyc %b frz %b | a_busy %b bus_pend %b m_dout %02h",
                 $time, u_sys.cpu_a_full[15:0], u_sys.cpu_rw_n, u_sys.cpu_di, u_sys.own_vic, u_sys.cpu_cyc,
                 u_sys.frz_now, u_sys.a_busy, u_sys.bus_pend, u_sys.m_dout);
    end
`endif
/* counters */
integer t_ms, errors = 0, n_hs = 0, n_vs = 0;

`ifdef VICTEST
/* the VIC-II on the real bus with the CPU held in reset: registers set as the KERNAL does, */
/* HELLO in screen RAM, one raster line of c- / g-accesses logged, one frame written */
integer n_log = 0, vi;
reg log_on = 0;
always @(posedge clk)
/* the bus at two raster lines */
    if (log_on && n_log < BUS_LOG_MAX && (u_sys.u_vic.raster_line == LOG_LINE1 || u_sys.u_vic.raster_line == LOG_LINE2))
    begin
        if (u_sys.phase[2])
        begin
            $display("%t t2  clk_phi %b aec %b ba %b type %0d vic_addr %04h", $time, u_sys.clk_phi, u_sys.aec, u_sys.ba,
                     u_sys.u_vic.cycle_type, u_sys.vic_addr);
        end
/* the data-valid tick */
        if (u_sys.phase[0])
        begin
            n_log++;
            $display("%t DAV clk_phi %b aec %b type %0d own_vic %b m_addr %05h m_dout %02h dbi %03h",
                     $time, u_sys.clk_phi, u_sys.aec, u_sys.u_vic.cycle_type, u_sys.own_vic, u_sys.m_addr, u_sys.m_dout, u_sys.vic_dbi);
        end
    end
/* the SDRAM side at the same lines */
always @(posedge clk_sd)
    if (log_on && n_log < BUS_LOG_MAX && (u_sys.u_vic.raster_line == LOG_LINE1 || u_sys.u_vic.raster_line == LOG_LINE2) && (u_sys.a_req || u_sys.ram_ack))
    begin
        $display("%t   sd: req %b ack %b addr %05h dout %02h", $time, u_sys.a_req, u_sys.ram_ack, u_sys.a_addr, u_sys.ram_dout);
    end
/* the disk test */
`endif

`ifdef DISK
/* 1541 DOS job queue ($0000-$0005: job codes $80 read, $90 write, $B0 seek, $E0 execute; results */
/* 01 ok, 02 header, 03 sync, 04 data block, 05 data checksum, ...) and the job's track / sector */
reg [7:0] jq [0:5];
integer jn = 0;
reg     job_on = 0;
/* the job queue as seen last */
initial
    for (int k = 0; k < JOBS; k++)
    begin
        jq[k] = 8'h00;
    end
/* changes of the job queue are listed */
always @(posedge clk)
begin
    for (int k = 0; k < JOBS; k++)
    begin
        if (u_sys.u_drive.ram[k] !== jq[k])
        begin
/* kept; some are listed */
            jq[k] = u_sys.u_drive.ram[k];
            if (job_on && jn < JOB_LOG_MAX)
            begin
                jn++;
/* the job */
                $display("%t JOB %0d = %02h  (T/S %0d/%0d) head %0d", $time, k, jq[k],
                         u_sys.u_drive.ram[6 + 2*k], u_sys.u_drive.ram[7 + 2*k], u_sys.d_track);
            end
        end
    end
end
/* every ms after LOAD: drive CPU address, C64 CPU address, serial bus, disk surface activity */
integer n_sync = 0, n_byte = 0;
reg     sp = 1, bp = 1;
always @(posedge clk)
begin
/* the previous levels */
    sp <= u_sys.u_drive.sync_n;
    bp <= u_sys.u_drive.byte_n;
    if (sp && !u_sys.u_drive.sync_n)
    begin
/* syncs and bytes counted */
        n_sync++;
    end
    if (bp && !u_sys.u_drive.byte_n)
    begin
        n_byte++;
    end
end
/* the test */
initial
begin
    wait (job_on);
    repeat (DRIVE_LOG_LINES)
    begin
/* a line every 20 ms */
        #20ms;
        $display("%t drv A %04h | c64 A %04h | ATN %b CLK %b DATA %b (c64 out a/c/d %b%b%b) | motor %b track %0d syncs %0d bytes %0d",
                 $time, u_sys.u_drive.cpu_a[15:0], u_sys.cb_a, !u_sys.cia2_pa_out_w[3], u_sys.iec_clk, u_sys.iec_data,
                 u_sys.cia2_pa_out_w[3], u_sys.cia2_pa_out_w[4], u_sys.cia2_pa_out_w[5], u_sys.d_motor, u_sys.d_track, n_sync, n_byte);
    end
end
/* the ESP32's part of the drive: keep the track under the head in the track buffer */
reg [7:0] d64 [0:174847];
integer   fd, i, loaded = 0;
`ifdef TURBO
/* disk + turbo allowed */
localparam [7:0] MCTL0 = 8'd5;
`else
localparam [7:0] MCTL0 = 8'd1;
/* sectors per track by speed zone */
`endif
function automatic integer spt(input integer t);
    spt = t <= ZONE3_LAST ? ZONE3_SECTORS : t <= ZONE2_LAST ? ZONE2_SECTORS : t <= ZONE1_LAST ? ZONE1_SECTORS : ZONE0_SECTORS;
endfunction
/* the offset of a sector in the .d64 file */
function automatic integer doff(input integer t, input integer sct);
    integer k, n;
    begin
        n = 0;
/* the sectors of the tracks before it */
        for (k = 1; k < t; k++)
        begin
            n += spt(k);
        end
        doff = (n + sct) * SECTOR;
    end
endfunction
/* the disk image */
initial
begin
    fd = $fopen("disk.d64", "rb");
    if (!fd)
    begin
/* no file */
        $display("FAIL: no disk.d64");
        $finish;
    end
    i = $fread(d64, fd);
/* read; the disk ID and a disk in the drive */
    $fclose(fd);
    force u_sys.u_tape.mctl = {d64[doff(18, 0) + 8'hA3], d64[doff(18, 0) + 8'hA2], 8'd0, MCTL0};
end
always @(posedge clk_sd)
begin
/* the track under the head goes into the track buffer */
    integer t, sc, b;
    t = u_sys.d_track;
    if (t >= 1 && t <= TRACK_MAX && t != loaded)
    begin
/* turbo: the buffer is filled 2 ms later */
`ifdef TURBO
        force u_sys.u_tape.mctl = {d64[doff(18, 0) + 8'hA3], d64[doff(18, 0) + 8'hA2], 8'd0, MCTL0};
        #2ms;
/* the track then */
        t = u_sys.d_track;
`endif
        for (sc = 0; sc < spt(t); sc++)
        begin
/* its sectors */
            for (b = 0; b < SECTOR; b++)
            begin
                u_sys.u_drive.tbuf[sc * 256 + b] = d64[doff(t, sc) + b];
            end
        end
        loaded = t;
/* the track number for the drive; reported */
        force u_sys.u_tape.mctl = {d64[doff(18, 0) + 8'hA3], d64[doff(18, 0) + 8'hA2], 2'd0, t[5:0], MCTL0};
        $display("%t drive: track %0d loaded (head)", $time, t);
    end
end
`endif
/* the snapshot test */
`ifdef SNAPTEST
/* the ESP32's snapshot commands, driven straight into c64_system's snapshot port */
reg [31:0] s_rd, s_d;
reg [3:0]  s_c;
reg [17:0] s_a;
/* one command through the snapshot port */
reg        s_r;
task automatic snapc(input [3:0] c, input [17:0] a, input [31:0] d);
    begin
        @(posedge clk_sd);
/* command, address, data */
        s_c = c;
        s_a = a;
        s_d = d;
/* forced into the port */
        force u_sys.snap_cmd = s_c;
        force u_sys.snap_addr = s_a;
        force u_sys.snap_wdata = s_d;
/* the request toggles; the acknowledge is waited for */
        s_r = !u_sys.snap_ack;
        force u_sys.snap_req = s_r;
        wait (u_sys.snap_ack == s_r);
/* the answer */
        @(posedge clk_sd);
        s_rd = u_sys.snap_rdata;
    end
endtask
reg [17:0] st_pc;
/* a byte of the restore program */
task automatic st8(input [7:0] b);
    begin
        sd_poke(18'h30000 + st_pc, b);
        st_pc++;
    end
endtask
/* LDA #v / STA a */
task automatic st_sta(input [7:0] v, input [15:0] a);
    begin
        st8(8'hA9);
        st8(v);
/* the store */
        st8(8'h8D);
        st8(a[7:0]);
        st8(a[15:8]);
    end
endtask
/* the test */
task automatic snap_test;
    reg [31:0] r0, r1, c1, c2;
    reg [7:0]  sp;
/* a counter; some time to run */
    integer    w;
    begin
        #20ms;
/* screenshot path: hold the frame buffers, read them through MRD while the C64 runs */
        begin
            reg [19:0] fb;
            snapc(4'd4, 18'd0, 4);
            fb = FB_BASE + u_sys.fb_newest * FB_SIZE;
/* the first byte of the newest buffer */
            snapc(4'd1, 18'd0, 0);
            $display("%t screenshot read: top border %02h (EE expected), SDRAM %02h", $time, s_rd[7:0], sd_peek(fb));
            if (s_rd[7:0] != SHOT_BORDER || s_rd[7:0] != sd_peek(fb))
            begin
/* a wrong border */
                $display("FAIL: screenshot border");
/* counted */
                errors++;
            end
            snapc(4'd1, 18'd100 * 256 + 18'd100, 0);
            $display("   screen area %02h (66 = blue expected), SDRAM %02h", s_rd[7:0], sd_peek(fb + 100 * 256 + 100));
/* a wrong screen byte */
            if (s_rd[7:0] != SHOT_SCREEN)
            begin
                $display("FAIL: screenshot screen area");
                errors++;
            end
/* the hold ends */
            snapc(4'd4, 18'd0, 0);
/* track buffer MWR with an odd data byte, then MRD */
            snapc(4'd2, 18'h20000, 8'h41);
            snapc(4'd1, 18'h20000, 0);
            if (s_rd[7:0] != TB_TEST_BYTE)
            begin
/* counted; the freeze */
                $display("FAIL: track buffer read after the hold (%02h)", s_rd[7:0]);
                errors++;
            end
        end
        force u_sys.snap_freeze = 1'b1;
/* frozen: the register words */
        wait (u_sys.frz_q);
        snapc(4'd3, 18'd0, 0);
        r0 = s_rd;
/* the second word */
        snapc(4'd3, 18'd1, 0);
        r1 = s_rd;
        snapc(4'd3, 18'd2, 0);
/* the CIAs' state */
        c1 = s_rd;
        snapc(4'd3, 18'd3, 0);
        c2 = s_rd;
/* reported */
        $display("%t frozen: A %02h X %02h Y %02h P %02h S %02h PC %04h (bus %04h) | CIA1 IMR %02h CRA %02h CRB %02h | CIA2 IMR %02h",
                 $time, r0[7:0], r0[15:8], r0[23:16], r0[31:24], r1[7:0], r1[31:16], u_sys.cpu_a_full[15:0], c1[4:0], c1[15:8], c1[23:16], c2[4:0]);
        snapc(4'd1, 18'h3D020, 0);
        $display("   shadow: D020 %02h (border 14 expected)", s_rd[7:0]);
/* the border colour in the I/O shadow */
        if (s_rd[3:0] != COL_LIGHT_BLUE)
        begin
            $display("FAIL: I/O shadow D020");
/* one more error */
            errors++;
        end
        snapc(4'd1, 18'h3D021, 0);
        $display("   shadow: D021 %02h (6)", s_rd[7:0]);
/* more shadow bytes, for the log */
        snapc(4'd1, 18'h3D800, 0);
        $display("   shadow: D800 %02h (colour RAM, 14)", s_rd[7:0]);
        snapc(4'd1, 18'h3D418, 0);
/* the SID's volume, CIA1's control register */
        $display("   shadow: D418 %02h (SID volume)", s_rd[7:0]);
        snapc(4'd1, 18'h3DC0E, 0);
        $display("   shadow: DC0E %02h (CIA1 CRA)", s_rd[7:0]);
/* the interrupt mask of CIA1 */
        if (c1[4:0] != 5'h01)
        begin
            $display("FAIL: CIA1 IMR %02h (01 expected: timer A)", c1[4:0]);
/* an error */
            errors++;
        end
/* the restore program, as the ESP32 builds it (shortened) */
        sd_poke(18'h3FFFC, 8'h00);
        sd_poke(18'h3FFFD, 8'h20);
        st_pc = RESTORE_PC;
/* the restore program: SEI, CLD */
        st8(8'h78);
        st8(8'hD8);
/* red border */
        st_sta(8'h02, 16'hD020);
        sp = r1[7:0];
        st8(8'hA2);
/* the stack pointer; the three bytes the RTI takes */
        st8(sp - 8'd3);
        st8(8'h9A);
        st_sta(r0[31:24], 16'h0100 + (sp - 8'd2));
/* PC low and high */
        st_sta(r1[23:16], 16'h0100 + (sp - 8'd1));
        st_sta(r1[31:24], 16'h0100 + sp);
        st8(8'hA9);
/* A, X */
        st8(8'h55);
        st8(8'hA2);
        st8(8'h66);
/* Y; RTI */
        st8(8'hA0);
        st8(8'h77);
        st8(8'h40);
/* restore mode, CPU reset */
        snapc(4'd4, 18'd0, 3);
        release u_sys.snap_freeze;
        #100us;
/* CPU runs the program */
        snapc(4'd4, 18'd0, 1);
        w = 0;
        while (u_sys.rmode && w < RESTORE_US_MAX)
        begin
/* a microsecond; counted */
            #1us;
            w++;
        end
        $display("%t restore mode %0d after %0d us: A %02h X %02h Y %02h S %02h PC %04h, border %0d",
                 $time, u_sys.rmode, w, u_sys.cpu_regs[7:0], u_sys.cpu_regs[15:8], u_sys.cpu_regs[23:16], u_sys.cpu_regs[39:32],
                 u_sys.cpu_regs[63:48], u_sys.u_vic.vic_registers.ec);
/* it never ended */
        if (u_sys.rmode)
        begin
            $display("FAIL: restore mode did not end");
            errors++;
        end
/* A, X, Y */
        if (u_sys.cpu_regs[7:0] != RESTORED_A || u_sys.cpu_regs[15:8] != RESTORED_X || u_sys.cpu_regs[23:16] != RESTORED_Y)
        begin
            $display("FAIL: registers");
            errors++;
        end
/* the stack pointer */
        if (u_sys.cpu_regs[39:32] != sp)
        begin
            $display("FAIL: S");
            errors++;
        end
/* the PC */
        if (u_sys.cpu_regs[63:48] != r1[31:16])
        begin
            $display("FAIL: PC");
            errors++;
        end
/* the border */
        if (u_sys.u_vic.vic_registers.ec != COL_RED)
        begin
            $display("FAIL: border not red");
            errors++;
        end
/* restore mode off; the port is free again */
        snapc(4'd4, 18'd0, 0);
        release u_sys.snap_cmd;
        release u_sys.snap_addr;
/* 50 ms more */
        release u_sys.snap_wdata;
        release u_sys.snap_req;
        #50ms;
/* the machine must run on */
        $display("%t running on: cpu A %04h", $time, u_sys.cb_a);
        show_screen;
    end
endtask
`endif
/* sync edges counted */
always @(posedge hs) n_hs++;
always @(posedge vs) n_vs++;
`ifdef TURBO
/* without a disk */
`ifndef DISK
/* turbo from the start */
initial force u_sys.t_allow = 1'b1;
`endif
/* turbo statistics: CPU cycles per 1 ms, drive cycles per 1 ms */
integer n_cce = 0, n_dce = 0;
always @(posedge clk)
begin
    if (u_sys.cpu_ce)
    begin
/* counted; the drive's clock enables */
        n_cce++;
    end
    if (u_sys.u_drive.ph2_f)
    begin
        n_dce++;
    end
end
/* a line every 10 ms */
always
begin
    #10ms;
    $display("%t turbo %0d: CPU %0d kHz, drive %0d kHz, wait %0d", $time, u_sys.turbo, n_cce / 10, n_dce / 10, u_sys.drv_wait);
/* counters cleared */
    n_cce = 0;
    n_dce = 0;
end
`endif
/* the test */
initial
begin
    wait (u_sys.ld_done);
    $display("%t ROMs loaded (bad_image %0d), first bytes CHAR %02h BASIC %02h KERNAL[FFFC] %02h%02h", $time,
             u_sys.bad_image, sd_peek(18'h11000), sd_peek(18'h12000), sd_peek(18'h15FFD), sd_peek(18'h15FFC));
/* a pause for the trace */
`ifdef TRACE
    #100us;
`endif
/* the VIC-II test: the CPU stays in reset */
`ifdef VICTEST
    force u_sys.c64_rst_n = 1'b0;
    for (vi = 0; vi < SCREEN_CHARS; vi++)
    begin
/* spaces, light blue */
        sd_poke(18'h400 + vi, 8'h20);
        u_sys.cram[vi] = 4'd14;
    end
    sd_poke(18'h400, 8);
/* HELLO in screen codes */
    sd_poke(18'h401, 5);
    sd_poke(18'h402, 12);
    sd_poke(18'h403, 12);
/* the registers as the KERNAL sets them */
    sd_poke(18'h404, 15);
    force u_sys.u_vic.vic_registers.yscroll = YSCROLL_DEF;
    force u_sys.u_vic.vic_registers.rsel    = 1'b1;
/* display on, 40 columns */
    force u_sys.u_vic.vic_registers.den     = 1'b1;
    force u_sys.u_vic.vic_registers.csel    = 1'b1;
    force u_sys.u_vic.vic_registers.cb      = 3'b010;
/* memory pointers, colours */
    force u_sys.u_vic.vic_registers.vm      = 4'b0001;
    force u_sys.u_vic.vic_registers.ec      = COL_LIGHT_BLUE;
    force u_sys.u_vic.vic_registers.b0c     = COL_BLUE;
/* a frame, then the log, then a picture */
    #25ms;
    log_on = 1;
    #20ms;
/* the end */
    grab("victest.ppm");
    $finish;
`endif
/* the screen every 50 ms */
    for (t_ms = STEP_MS; t_ms <= `RUN_MS; t_ms += STEP_MS)
    begin
        #50ms;
        $display("%t PC area: cpu A %04h", $time, u_sys.cb_a);
/* until BASIC is ready */
        show_screen;
        if (has_text(screen_txt, "READY."))
        begin
            break;
        end
    end
/* the snapshot test */
`ifdef SNAPTEST
    snap_test;
`endif
/* the disk test */
`ifdef DISK
/* the 1541 runs its power-up self-test for about a second (motor on): wait until it is idle */
    begin
        integer w;
        for (w = 0; w < IDLE_WAIT_MAX && u_sys.d_motor; w++)
        begin
            #10ms;
        end
/* idle */
        #100ms;
        $display("%t drive idle (motor %0d) after %0d ms", $time, u_sys.d_motor, w * 10);
    end
/* LOAD"$",8 RETURN into the keyboard buffer */
    begin
        static byte cmd[10] = '{"L", "O", "A", "D", 8'h22, "$", 8'h22, ",", "8", 8'h0D};
        for (i = 0; i < LOAD_CMD_LEN; i++)
        begin
            sd_poke(18'h277 + i, cmd[i]);
        end
/* ten characters in the keyboard buffer */
        sd_poke(18'hC6, 8'd10);
        $display("%t typed LOAD\"$\",8", $time);
        job_on = 1;
    end
/* the screen every 50 ms */
    for (t_ms = STEP_MS; t_ms <= `RUN_MS; t_ms += STEP_MS)
    begin
        #50ms;
        show_screen;
/* until the directory is loaded */
        $display("%t drive: track %0d motor %0d led %0d | cpu A %04h", $time, u_sys.d_track, u_sys.d_motor, u_sys.d_led, u_sys.cb_a);
        if (has_text(screen_txt, "BLOCKS FREE"))
        begin
            break;
        end
/* loaded: LIST it */
        if (count_text(screen_txt, "READY.") == READY_TWICE && sd_peek(18'hC6) == 0)
        begin
            static byte lst[5] = '{"L", "I", "S", "T", 8'h0D};
            for (i = 0; i < LIST_CMD_LEN; i++)
            begin
/* LIST into the keyboard buffer */
                sd_poke(18'h277 + i, lst[i]);
            end
            sd_poke(18'hC6, 8'd5);
            $display("%t typed LIST", $time);
        end
    end
/* the disk name */
    if (!has_text(screen_txt, "TEST"))
    begin
        $display("FAIL: no directory (disk name)");
        errors++;
    end
/* the file's name */
    if (!has_text(screen_txt, "HELLO"))
    begin
        $display("FAIL: no directory entry HELLO");
        errors++;
    end
/* the banner */
`endif
    if (!has_text(screen_txt, "COMMODORE 64 BASIC V2"))
    begin
        $display("FAIL: no BASIC banner");
/* counted; the memory size */
        errors++;
    end
    if (!has_text(screen_txt, "38911 BASIC BYTES FREE"))
    begin
        $display("FAIL: wrong memory size");
/* counted; the prompt */
        errors++;
    end
    if (!has_text(screen_txt, "READY."))
    begin
        $display("FAIL: no READY.");
/* counted; the dirty RAM must be clean */
        errors++;
    end
`ifdef DIRTYRAM
    if (sd_peek(20'h08004) != 8'h00)
    begin
/* not cleared */
        $display("FAIL: RAM not cleared ($8004 = %02h)", sd_peek(20'h08004));
        errors++;
    end
`endif
/* video: sync edges */
    $display("%t VGA sync edges so far: hsync %0d, vsync %0d", $time, n_hs, n_vs);
    $display("%t VIC-II: border %0d, background %0d, DEN %0d, frame buffer newest %0d", $time,
             u_sys.u_vic.vic_registers.ec, u_sys.u_vic.vic_registers.b0c, u_sys.u_vic.vic_registers.den, u_sys.u_fb.newest);
    if (n_vs < VS_MIN)
    begin
/* no vertical sync */
        $display("FAIL: no vsync");
        errors++;
    end
    else
    begin
        grab("screen.ppm");
    end
/* the verdict */
    if (errors)
    begin
        $display("RESULT: FAIL");
    end
    else
    begin
/* passed */
        $display("RESULT: PASS");
    end
/* the end */
    $finish;
end

endmodule
