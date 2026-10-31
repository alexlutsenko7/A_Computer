//=============================================================================
// c64_system -- the Commodore 64 (PAL) without clocks/PLLs and pin buffers
//
//   clk     31.510 MHz VIC-II dot4x clock (c64_pll c0): VIC-II (Kawari), CPU (T65),
//           CIAs, SID, PLA, colour RAM, keyboard, video output
//   clk_sd  94.531 MHz = 3 x clk, rising edges aligned (c64_pll c3): SDRAM controller,
//           ROM loader, tape loader + ESP32 link, audio DAC, Bluetooth I2S
//   pclk    VGA pixel clock: 39.80 MHz (60 Hz, m60 = 1) or 31.51 MHz (50 Hz), the frame
//           buffer reader and the OSD (c64_fb.v, c64_video.v)
//
// Memory (SDRAM, 20-bit byte addresses):
//   0x00000-0x0FFFF  64 KB RAM (cleared to 0 after each ROM load, before the C64 starts)
//   0x10000          ROM image from flash 0x200000 (rom_loader, 48 KB): 0x10000 header
//                    (byte 0 F3, byte 13 = 1: a 1541 ROM is included), 0x11000 CHAR (4 KB),
//                    0x12000 BASIC (8 KB), 0x14000 KERNAL (8 KB), 0x18000 1541 DOS ROM
//                    (16 KB, also copied into the drive's block RAM while loading).
//                    The ROMs are not part of this design: the ESP32 installs them from
//                    the SD card (docs/PLAN.md).
//   0x30000-0x3FFFF  snapshot restore bank (the CPU's whole view in restore mode); its
//                    0xD000-0xDFFF = the I/O shadow: every CPU write to $D000-$DFFF goes there
//                    too, register mirrors folded (VIC-II $D000-$D02E, SID $D400-$D418,
//                    colour RAM, CIA1 $DC00-$DC0F, CIA2 $DD00-$DD0F)
//   0x40000-0x9FFFF  frame buffers (c64_fb.v, 3 x 128 KB, 16-bit accesses)
//   (snapshot port 0x20000-0x21FFF: the 1541 track buffer, not SDRAM)
//
// Bus: each half of the 0.985 MHz phi cycle (16 clk ticks, Kawari's phase[15:0])
// has one owner: the VIC-II while aec = 0 (always in phi1, in phi2 when it
// stole the cycle), else the CPU.
//   tick 2   the CPU's address goes to the SDRAM (CPU halves)
//   tick 3   the VIC-II's address goes to the SDRAM and the colour RAM (Kawari computes
//            the address of a half in the clock edge that starts tick 2: taken at tick 2
//            it would still be the previous one). One access per half, done by tick ~11
//            (worst case with a refresh about 7 ticks after the request).
//   tick 4-12 the frame buffer may start an SDRAM access when no bus access waits (one
//            started at tick 12 is done before the next half's tick 2)
//   tick 12  CPU half: CIA phi2_n (reads/writes), SID and colour RAM writes,
//            6510 port writes
//   tick 15  CPU half: CPU clock enable (T65 takes DI, starts the next cycle);
//            SID 1 MHz enable
//   tick 0   (next half) the VIC-II takes dbi (Kawari DATA_DAV); a CPU write
//            to a VIC-II register is taken here too
// The CPU's outputs are latched at tick 2 of phi1 (cb_*), so address, data and
// R/W stay put for the whole phi2 half and the VIC-II's write at its tick 0.
// RDY = BA (T65 stops on reads only, as the 6510).
//
// Turbo (while the cassette or 1541 motor runs and the ESP32 allows it, MCTL[2] = F6):
// the CPU starts a cycle at tick 6 or 14 of either half (every 8 ticks: up to 3.94 MHz)
// through its own SDRAM port: latch at L, request at L+1, data checked at L+6 (else at the
// next check tick), clock enable one tick later. A cycle that addresses the VIC-II, SID
// or colour RAM is done in the next normal phi2 slot instead. The CIAs get phi2_p / phi2_n
// once per CPU cycle and the 1541 one drive cycle per 0.985 C64 cycles (c1541 turbo), so
// tape timing, the serial bus and fast loaders scale with the CPU; the VIC-II, the SID
// and the TOD clock keep the real time. RDY is not used (the VIC-II has its own SDRAM
// slots). While the 1541's track buffer is being refilled (head on another track), no
// cycle starts: the C64 and the drive pause together.
//
// Resets: por_n (power-up: keyboard), rst_n (C64: CPU, CIAs, SID, port; + KEY0),
// rst_sd_n (clk_sd: SDRAM, ROM loader, tape loader; + KEY0). The
// VIC-II resets itself at power-up only (as the real chip, it has no reset pin).
//=============================================================================
`default_nettype none

module c64_system #(
    parameter integer CLK_HZ      = 31510000,
    parameter integer SD_MHZ      = 95,         // SDRAM timing (94.531 MHz, rounded up)
    parameter integer FLASH_DIV   = 4,
    parameter integer KBD_WAIT_MS = 1500,
    parameter         FONT_HEX    = "../AMenu/rtl/menu_font.hex"   // OSD font: Spleen 8x16, shared with the menu
)(
    input  wire        clk,
    input  wire        por_n,           // synchronous to clk
    input  wire        rst_n,           // synchronous to clk
    input  wire        clk_sd,
    input  wire        rst_sd_n,        // synchronous to clk_sd

    // board inputs (asynchronous)
    input  wire        kbd_rx,
    input  wire [4:0]  joy1_n,          // DB9-1: fire, up, down, left, right (active low)
    input  wire [4:0]  joy2_n,          // DB9-2

    // SDRAM pins (the top level does the DQ tri-state)
    output wire        sd_cke,
    output wire        sd_cs_n,
    output wire        sd_ras_n,
    output wire        sd_cas_n,
    output wire        sd_we_n,
    output wire [1:0]  sd_ba,
    output wire [12:0] sd_a,
    output wire [1:0]  sd_dqm,
    output wire [15:0] sd_dq_o,
    output wire        sd_dq_oe,
    input  wire [15:0] sd_dq_i,

    output wire        kbd_cad,         // Ctrl+Alt+Del (clk domain)
    output wire        kbd_f8,          // toggles on F8 (clk domain, power-up reset only)

    // flash (flash_if)
    output wire        f_dclk,
    output wire        f_ncs,
    output wire        f_mosi,
    input  wire        f_miso,

    // VGA (pclk; the top level switches it between the two modes with prst_n = 0)
    input  wire        pclk,
    input  wire        prst_n,          // synchronous to pclk
    input  wire        m60,             // 1 = 800 x 600 @ 60 Hz, 0 = 50 Hz
    output wire [3:0]  vga_r,
    output wire [3:0]  vga_g,
    output wire [3:0]  vga_b,
    output wire        vga_hs,
    output wire        vga_vs,

    // audio, ESP32
    output wire        audio,           // SID, sigma-delta
    input  wire        bt_bclk,
    input  wire        bt_lrck,
    output wire        bt_data,
    output wire        bt_tx,
    input  wire        bt_rx,
    input  wire        esp_sck,
    input  wire        esp_mosi,
    input  wire        esp_cs_n,
    output wire        esp_miso,
    output wire        esp_irq,

    output reg         led,             // active low: on = 1541 LED; fast blink = C64 ROMs missing in flash
    output wire        c64_run          // the C64 is out of reset (clk domain)
);

//-----------------------------------------------------------------------------
// SDRAM controller (clk_sd), shared by the ROM loader (first) and the bus bridge
//-----------------------------------------------------------------------------
wire        ld_req, ld_we, ld_done, bad_image;
wire        ld_rom_done;                // the ROMs are in SDRAM; then the RAM is cleared (ld_done)
wire        lc_req;                     // the loader's / the RAM clear's SDRAM port
wire [17:0] lc_addr;
wire [7:0]  lc_din;
wire [17:0] ld_addr;
wire [7:0]  ld_din;
wire [7:0]  ram_dout;
wire        ram_ack, ram_ready;

// Bus side (clk domain): the VIC-II's reads toggle m_req_tgl with m_addr held until the
// next request; data in m_dout. The CPU has its own port: c_req_tgl with c_we/c_addr/c_din
// held until c_ack_tgl follows (c_done), read data in c_dout.
// Snapshot port side (clk_sd, tape_loader / ESP32 link): one memory access at a time.
// The arbiter serves the bus first; a snapshot access only starts while no bus
// request waits, so a bus access is delayed by one snapshot access at most
// (~6 clk_sd = 2 ticks: still done long before the data is taken).
reg         m_req_tgl, m_we;
reg  [17:0] m_addr;
reg  [7:0]  m_din;
reg         m_rq_d, bus_pend;
reg  [7:0]  m_dout;
reg         c_req_tgl, c_we;
reg  [17:0] c_addr;
reg  [7:0]  c_din;
reg         c_rq_d, c_pend, c_ack_tgl;
reg  [7:0]  c_dout;

wire        snap_req, snap_freeze;
wire [3:0]  snap_cmd;
wire [17:0] snap_addr;
wire [31:0] snap_wdata;
reg         fb_hold;                    // snapshot CTL: frame buffer hold (screenshot)
wire [1:0]  fb_newest;
wire        fb_rd = fb_hold && snap_cmd == 4'd1;                 // screenshot: frame buffer read, no freeze needed
wire [19:0] fb_a  = {3'd2 + {1'b0, fb_newest}, snap_addr[16:0]}; // the byte in the newest frame buffer
reg  [31:0] snap_rdata;
reg         snap_ack;
reg         sm_pend;                    // snapshot memory access waiting
reg         a_busy, a_bus, a_cpu, a_fb; // an access runs; it is the VIC-II's / CPU's / frame buffer's
reg         a_we;
reg  [19:0] a_addr;
reg  [7:0]  a_din, a_dhi;
reg         a_req;

// frame buffer port (c64_fb) and its time slot (fb_ok: ticks 4-12, from clk)
wire        fb_req, fb_we;
wire [19:0] fb_addr;
wire [15:0] fb_wdata, ram_dout_w;
reg         fb_ok;
wire        fb_ack = a_busy && a_fb && ram_ack;

always @(posedge clk_sd or negedge rst_sd_n)
    if (!rst_sd_n) begin
        m_rq_d   <= 1'b0;
        bus_pend <= 1'b0;
        m_dout   <= 8'hFF;
        c_rq_d   <= 1'b0;
        c_pend   <= 1'b0;
        c_ack_tgl <= 1'b0;
        c_dout   <= 8'hFF;
        a_busy   <= 1'b0;
        a_bus    <= 1'b0;
        a_cpu    <= 1'b0;
        a_fb     <= 1'b0;
        a_we     <= 1'b0;
        a_addr   <= 20'd0;
        a_din    <= 8'd0;
        a_dhi    <= 8'd0;
        a_req    <= 1'b0;
    end else begin
        m_rq_d <= m_req_tgl;
        c_rq_d <= c_req_tgl;
        a_req  <= 1'b0;
        if (m_req_tgl != m_rq_d && ld_done) bus_pend <= 1'b1;   // none kept from the ROM load
        if (c_req_tgl != c_rq_d && ld_done) c_pend   <= 1'b1;
        if (!a_busy && ld_done) begin
            if (bus_pend || m_req_tgl != m_rq_d) begin
                a_busy   <= 1'b1;
                a_bus    <= 1'b1;
                a_cpu    <= 1'b0;
                a_fb     <= 1'b0;
                a_req    <= 1'b1;
                a_we     <= m_we;
                a_addr   <= {2'b00, m_addr};
                a_din    <= m_din;
                bus_pend <= 1'b0;
            end else if (c_pend || c_req_tgl != c_rq_d) begin
                a_busy   <= 1'b1;
                a_bus    <= 1'b0;
                a_cpu    <= 1'b1;
                a_fb     <= 1'b0;
                a_req    <= 1'b1;
                a_we     <= c_we;
                a_addr   <= {2'b00, c_addr};
                a_din    <= c_din;
                c_pend   <= 1'b0;
            end else if (fb_req && fb_ok) begin
                a_busy <= 1'b1;
                a_bus  <= 1'b0;
                a_cpu  <= 1'b0;
                a_fb   <= 1'b1;
                a_req  <= 1'b1;
                a_we   <= fb_we;
                a_addr <= fb_addr;
                a_din  <= fb_wdata[7:0];
                a_dhi  <= fb_wdata[15:8];
            end else if (sm_pend) begin
                a_busy <= 1'b1;
                a_bus  <= 1'b0;
                a_cpu  <= 1'b0;
                a_fb   <= 1'b0;
                a_req  <= 1'b1;
                a_we   <= snap_cmd == 4'd2;
                a_addr <= fb_rd ? fb_a : {2'b00, snap_addr};
                a_din  <= snap_wdata[7:0];
            end
        end else if (a_busy && ram_ack) begin
            a_busy <= 1'b0;
            if (a_bus && !a_we) m_dout <= ram_dout;
            if (a_cpu) begin
                if (!a_we) c_dout <= ram_dout;
                c_ack_tgl <= !c_ack_tgl;
            end
        end
    end

sdram_ram #(.ADDR_BITS(20), .CLK_MHZ(SD_MHZ)) u_ram (
    .clk      (clk_sd),
    .rst_n    (rst_sd_n),
    .req      (ld_done ? a_req  : lc_req),
    .we       (ld_done ? a_we   : ld_we),
    .addr     (ld_done ? a_addr : {2'b00, lc_addr}),
    .din      (ld_done ? a_din  : lc_din),
    .wide     (ld_done && a_fb),
    .din_hi   (a_dhi),
    .dout     (ram_dout),
    .dout_w   (ram_dout_w),
    .ack      (ram_ack),
    .ready    (ram_ready),
    .sd_cke   (sd_cke),
    .sd_cs_n  (sd_cs_n),
    .sd_ras_n (sd_ras_n),
    .sd_cas_n (sd_cas_n),
    .sd_we_n  (sd_we_n),
    .sd_ba    (sd_ba),
    .sd_a     (sd_a),
    .sd_dqm   (sd_dqm),
    .sd_dq_o  (sd_dq_o),
    .sd_dq_oe (sd_dq_oe),
    .sd_dq_i  (sd_dq_i)
);

// ROM reload (tape loader register 0x44, after the ESP32 installed new ROMs): the loader
// restarts, so ld_done falls and the C64 is held in reset until the ROMs are back (and the
// RAM is cleared)
wire       l_reload;
reg  [3:0] rld_sr;
always @(posedge clk_sd or negedge rst_sd_n)
    if (!rst_sd_n) rld_sr <= 4'hF;
    else           rld_sr <= {rld_sr[2:0], !l_reload};
wire ld_rst_n = rst_sd_n & (&rld_sr);

// flash pins: the ROM loader, or the ESP32's pass-through (tape loader register 0x40)
wire ld_dclk, ld_ncs, ld_mosi;
wire fl_en, fl_ncs, fl_dclk, fl_mosi;
wire fl_own = fl_en && ld_done;         // never while the loader reads
assign f_dclk = fl_own ? fl_dclk : ld_dclk;
assign f_ncs  = fl_own ? fl_ncs  : ld_ncs;
assign f_mosi = fl_own ? fl_mosi : ld_mosi;

rom_loader #(.FLASH_ADDR(24'h200000), .SD_BASE(18'h10000), .LEN(49152), .DIV(FLASH_DIV)) u_loader (
    .clk       (clk_sd),
    .rst_n     (ld_rst_n),
    .f_dclk    (ld_dclk),
    .f_ncs     (ld_ncs),
    .f_mosi    (ld_mosi),
    .f_miso    (f_miso),
    .sd_req    (ld_req),
    .sd_we     (ld_we),
    .sd_addr   (ld_addr),
    .sd_din    (ld_din),
    .sd_ack    (ram_ack & !ld_rom_done),
    .done      (ld_rom_done),
    .bad_image (bad_image)
);

// RAM clear (after the ROM load, so at every start: menu, KEY0, ROM reload): the 64 KB RAM
// keeps its contents in SDRAM through a reconfiguration and even a short power-off. A
// game's reset protection ("CBM80" at $8004) would otherwise catch every new start.
reg  [15:0] clr_a;
reg         clr_req, clr_wait;
reg         ld_clr_done;
always @(posedge clk_sd or negedge ld_rst_n)
    if (!ld_rst_n) begin
        clr_a       <= 16'd0;
        clr_req     <= 1'b0;
        clr_wait    <= 1'b0;
        ld_clr_done <= 1'b0;
    end else begin
        clr_req <= 1'b0;
        if (ld_rom_done && !ld_clr_done) begin
            if (!clr_wait) begin
                clr_req  <= 1'b1;
                clr_wait <= 1'b1;
            end else if (ram_ack) begin
                clr_wait <= 1'b0;
                clr_a    <= clr_a + 16'd1;
                if (&clr_a) ld_clr_done <= 1'b1;
            end
        end
    end
assign ld_done = ld_clr_done;

// the loader's / the clear's SDRAM requests (until ld_done)
assign lc_req  = ld_rom_done ? clr_req : ld_req;
assign lc_addr = ld_rom_done ? {2'b00, clr_a} : ld_addr;
assign lc_din  = ld_rom_done ? 8'h00 : ld_din;

//-----------------------------------------------------------------------------
// Keyboard (power-up reset only); the CPU waits for the ROMs and the first keyboard
// packet (at most KBD_WAIT_MS)
//-----------------------------------------------------------------------------
wire [63:0] kb_keys;
wire [17:0] lkeys;
wire [31:0] kb_raw;
wire        kb_restore, kb_seen, kb_f1;
wire        l_osd_on, l_osd_full;

c64_keyboard #(.CLK_HZ(CLK_HZ)) u_kbd (
    .clk     (clk),
    .rst_n   (por_n),
    .rx      (kbd_rx),
    .block   (l_osd_on & l_osd_full),
    .keys    (kb_keys),
    .restore (kb_restore),
    .lkeys   (lkeys),
    .f1      (kb_f1),
    .f8_tgl  (kbd_f8),
    .cad     (kbd_cad),
    .seen    (kb_seen),
    .raw     (kb_raw)
);

localparam integer KBD_WAIT = KBD_WAIT_MS * (CLK_HZ / 1000);
reg [31:0] kbd_cnt;
reg        kbd_ready;
always @(posedge clk or negedge por_n)
    if (!por_n) begin
        kbd_cnt   <= 32'd0;
        kbd_ready <= 1'b0;
    end else if (kb_seen || kbd_cnt == KBD_WAIT)
        kbd_ready <= 1'b1;
    else
        kbd_cnt <= kbd_cnt + 32'd1;

reg [1:0] ld_done_s;
always @(posedge clk) ld_done_s <= {ld_done_s[0], ld_done};
wire run = ld_done_s[1] & kbd_ready;
assign c64_run = run;

// CPU, CIAs, SID and the 6510 port stay in reset until the ROMs are in SDRAM
wire c64_rst_n = rst_n & run;

// the CPU's bus, latched at tick 2 of phi1 (see the CPU section)
reg  [15:0] cb_a;
reg  [7:0]  cb_do;
reg         cb_we;

//-----------------------------------------------------------------------------
// VIC-II (Kawari)
//-----------------------------------------------------------------------------
wire        clk_phi, aec, ba, vic_irq;
wire [15:0] phase;
wire [13:0] vic_addr;
wire [7:0]  vic_dbo;
wire [11:0] vic_dbi;
wire        vic_ce_n, vic_rw, vic_lp;
wire [3:0]  k_pixel;
wire [9:0]  k_rx;
wire [8:0]  k_rline;

vicii u_vic (
    .standard_sw    (1'b0),             // chip 6569R3 (PAL)
    .ext_rst        (!por_n),
    .rst            (),
    .clk_dot4x      (clk),
    .clk_phi        (clk_phi),
    .clk_col16x     (1'b0),             // luma/chroma only (not built)
    .clk_col16x_4tm (1'b0),
    .ado            (),
    .vic_addr       (vic_addr),
    .phase          (phase),
    .pixel          (k_pixel),
    .raster_x_o     (k_rx),
    .raster_line_o  (k_rline),
    .adi            (cb_a[5:0]),
    .dbo            (vic_dbo),
    .dbi            (vic_dbi),
    .ce             (vic_ce_n),
    .rw             (vic_rw),
    .irq            (vic_irq),
    .lp             (vic_lp),
    .aec            (aec),
    .ba_d2          (ba),
    .ras            (),
    .cas            (),
    .ls245_data_dir (),
    .ls245_addr_dir (),
    .vic_write_db   (),
    .vic_write_ab   (),
    .rw_ctl         (),
    .chip           ()
);

wire t2  = phase[2];
wire t3  = phase[3];
wire t12 = phase[12];
wire t15 = phase[15];

reg         turbo;                      // the CPU's timing now (changes between cycles only)
reg         t_busy;                     // turbo: a cycle is latched in cb_* and not yet done
reg         rmode;                      // snapshot restore mode (see the PLA)
reg         cpu_rst;                    // snapshot: CPU-only reset
reg         s_rm, s_rst;                // clk_sd, snapshot CTL: restore mode request (rising edge), CPU reset

// registered: ticks 4-12; turbo: ticks 4-5 and 9-12 (between the VIC-II's access at tick 3 and
// the CPU's at 7 and 15)
always @(posedge clk) fb_ok <= turbo ? (phase[3] || phase[4] || (|phase[11:8])) : |phase[11:3];

//-----------------------------------------------------------------------------
// CPU (T65 as 6510) and its latched bus
//-----------------------------------------------------------------------------
wire [23:0] cpu_a_full;
wire [7:0]  cpu_do;
wire        cpu_rw_n;
reg  [7:0]  cpu_di;
wire        cia1_irq_n, cia2_irq_n;
wire        cpu_sync;
wire [63:0] cpu_regs;

// Snapshot freeze (ESP32): the CPU stops before an opcode fetch (Sync), so its
// registers are an instruction boundary; while frozen the CPU half cycles are idle
// (no CPU bus access) and the snapshot port uses the SDRAM. The tape recorder's
// hold stops the CPU the same way.
reg  [1:0]  frz_s;
reg         frz_q;
wire        l_hold;
always @(posedge clk or negedge c64_rst_n)
    if (!c64_rst_n) begin
        frz_s <= 2'b00;
        frz_q <= 1'b0;
    end else begin
        frz_s <= {frz_s[0], snap_freeze | l_hold};
        if (clk_phi && t15) begin
            if (!frz_s[1])          frz_q <= 1'b0;
            else if (cpu_sync && !t_busy) frz_q <= 1'b1;
        end
    end
// the opcode fetch cycle (Sync) that meets a freeze request is not completed: the CPU
// stops before it, so PC points at the next instruction
wire        frz_now = frz_q || (frz_s[1] && cpu_sync);

//-----------------------------------------------------------------------------
// Turbo cycle control (see the header)
//-----------------------------------------------------------------------------
reg         t_go;                       // turbo: the clock after the latch (request, phi2_p)
reg         t_rdy;                      // turbo: the clock enable of a fast cycle
reg         sl_act;                     // turbo: the latched slow cycle uses this phi cycle's phi2
wire        t_allow, drv_wait;
wire        c_done  = c_ack_tgl == c_req_tgl;
wire        t_slow;                     // the latched cycle addresses the VIC-II, SID or colour RAM
reg         cpu_cyc;                    // CPU half with the CPU on the bus (normal slot)
wire        t_lat   = turbo && (phase[6] || phase[14]) && !t_busy && !frz_now && !drv_wait && c64_rst_n;
wire        t_chk   = turbo && (phase[12] || phase[4]) && t_busy && !t_go && !t_slow && c_done;

wire        cpu_ce  = turbo ? (t_rdy || (sl_act && cpu_cyc && t15))
                            : (clk_phi && t15 && !frz_now);
// CIA enables: phi2_p at tick 0 of the CPU half, phi2_n at tick 12 (frozen / held: the CIAs
// stop with the CPU, so their timers stay in step with it: the KERNAL's tape writing is
// timed by CIA timer interrupts). Turbo: phi2_p after the latch, phi2_n with the data.
wire        cia_p   = turbo ? t_go : (clk_phi && phase[0] && run && !frz_q);
wire        cyc_n_t = t_chk;            // turbo phi2_n of a fast cycle
wire        cia_n   = turbo ? (cyc_n_t || (sl_act && cpu_cyc && t12)) : (clk_phi && t12 && run && !frz_q);

T65 u_cpu (
    .Mode    (2'b00),
    .BCD_en  (1'b1),
    .Res_n   (c64_rst_n && !cpu_rst),
    .Enable  (cpu_ce),
    .Clk     (clk),
    .Rdy     (turbo || ba),
    .Abort_n (1'b1),
    .IRQ_n   (!vic_irq && cia1_irq_n),
    .NMI_n   (cia2_irq_n && !kb_restore),
    .SO_n    (1'b1),
    .R_W_n   (cpu_rw_n),
    .Sync    (cpu_sync),
    .EF      (),
    .MF      (),
    .XF      (),
    .ML_n    (),
    .VP_n    (),
    .VDA     (),
    .VPA     (),
    .A       (cpu_a_full),
    .DI      (cpu_di),
    .DO      (cpu_do),
    .Regs    (cpu_regs),
    .DEBUG   (),
    .NMI_ack ()
);

always @(posedge clk or negedge c64_rst_n)
    if (!c64_rst_n) begin
        cb_a  <= 16'hFFFF;
        cb_do <= 8'hFF;
        cb_we <= 1'b0;
    end else if (turbo ? t_lat : (!clk_phi && t2)) begin
        cb_a  <= cpu_a_full[15:0];
        cb_do <= cpu_do;
        cb_we <= !cpu_rw_n;
    end

//-----------------------------------------------------------------------------
// 6510 I/O port ($00 direction, $01 data): bits 0-2 LORAM/HIRAM/CHAREN (pulled up
// as inputs), 3 cassette write, 4 cassette sense (input, 0 = PLAY pressed),
// 5 cassette motor (0 = on), 6-7 read 0
//-----------------------------------------------------------------------------
reg  [7:0] p_ddr, p_dat;
wire       cass_sense;                  // 0 = a tape is playing
wire [7:0] p_in  = {2'b00, 1'b0, cass_sense, 1'b1, 3'b111};
wire [7:0] p_pin = (p_dat & p_ddr) | (p_in & ~p_ddr);
wire       loram = p_pin[0], hiram = p_pin[1], charen = p_pin[2];
wire       cass_write = p_pin[3];
wire       cass_motor = !p_pin[5] && p_ddr[5];

//-----------------------------------------------------------------------------
// PLA: CPU address decode (no cartridge: GAME = EXROM = 1)
//-----------------------------------------------------------------------------
// Restore mode (snapshot load, rmode): the CPU sees the restore bank (SDRAM 0x30000+) everywhere
// except $D000-$DFFF, which is I/O whatever the port says.
wire [3:0] hi_n   = cb_a[15:12];
wire       io_vis = hi_n == 4'hD && (rmode || ((loram | hiram) && charen));
wire       chr_vis = !rmode && hi_n == 4'hD && (loram | hiram) && !charen;
wire       bas_vis = !rmode && (hi_n == 4'hA || hi_n == 4'hB) && loram && hiram;
wire       ker_vis = !rmode && (hi_n == 4'hE || hi_n == 4'hF) && hiram;
wire [3:0] io_blk = cb_a[11:8];
wire       sel_vic  = io_vis && io_blk[3:2] == 2'b00;      // D000-D3FF
wire       sel_sid  = io_vis && io_blk[3:2] == 2'b01;      // D400-D7FF
wire       sel_cram = io_vis && io_blk[3:2] == 2'b10;      // D800-DBFF
wire       sel_cia1 = io_vis && io_blk == 4'hC;
wire       sel_cia2 = io_vis && io_blk == 4'hD;
wire       sel_port = cb_a[15:1] == 15'd0;                  // $00 / $01 (RAM written as well)

// I/O writes also go to the shadow (0x3D000+), with the register mirrors folded
wire        sh_wr     = io_vis && cb_we;
wire [15:0] io_sh     = sel_vic  ? {cb_a[15:10], 4'd0, cb_a[5:0]} :
                        sel_sid  ? {cb_a[15:10], 5'd0, cb_a[4:0]} :
                        (sel_cia1 || sel_cia2) ? {cb_a[15:8], 4'd0, cb_a[3:0]} : cb_a;
wire [17:0] cpu_mem_a = sh_wr               ? {2'b11, io_sh} :                     // I/O shadow
                        rmode               ? {2'b11, cb_a} :                      // restore bank
                        (!cb_we && chr_vis) ? {6'b010001, cb_a[11:0]} :           // 0x11000 CHAR
                        (!cb_we && bas_vis) ? {5'b01001, cb_a[12:0]} :            // 0x12000 BASIC
                        (!cb_we && ker_vis) ? {5'b01010, cb_a[12:0]} :            // 0x14000 KERNAL
                                              {2'b00, cb_a};                      // RAM
wire        cpu_mem   = !io_vis;        // the read data come from SDRAM
wire        cpu_req   = cpu_mem || sh_wr;   // an SDRAM access

assign t_slow   = sel_vic || sel_sid || sel_cram;
assign vic_ce_n = !(sel_vic && (!turbo || sl_act));
assign vic_rw   = !cb_we;

//-----------------------------------------------------------------------------
// VIC-II memory view: 16 KB bank from CIA2 port A bits 1:0 (inverted); the CHAR
// ROM shows at 0x1000-0x1FFF of banks 0 and 2
//-----------------------------------------------------------------------------
wire [7:0]  cia2_pa_out;
// CIA2's port register gets its value at the CIA's first phi2 after a reset: until then
// the pins are pulled up (bank 0, no serial line pulled low), as on the real board
reg         c2_ok;
wire [7:0]  c2_pa   = c2_ok ? cia2_pa_out : 8'hFF;
wire [1:0]  vbank   = ~c2_pa[1:0];
wire        vic_chr = !vbank[0] && vic_addr[13:12] == 2'b01;
wire [17:0] vic_mem_a = vic_chr ? {6'b010001, vic_addr[11:0]} : {2'b00, vbank, vic_addr};

//-----------------------------------------------------------------------------
// Bus cycle: SDRAM access at tick 2 of each half for its owner
//-----------------------------------------------------------------------------
reg        own_vic;                     // this half belongs to the VIC-II (from tick 2 to tick 2 of the next)
reg  [9:0] cram_ra;
reg  [7:0] vic_last;                    // last byte the VIC-II read (open bus)

always @(posedge clk or negedge por_n)      // power-up only: the VIC-II keeps running through resets
    if (!por_n) begin
        m_req_tgl <= 1'b0;
        m_we      <= 1'b0;
        m_addr    <= 18'd0;
        m_din     <= 8'd0;
        own_vic   <= 1'b1;
        cpu_cyc   <= 1'b0;
        cram_ra   <= 10'd0;
        c_req_tgl <= 1'b0;
        c_we      <= 1'b0;
        c_addr    <= 18'd0;
        c_din     <= 8'd0;
    end else begin
      if (t2) begin
        own_vic <= !aec;
        cpu_cyc <= aec && clk_phi && c64_rst_n && !frz_q && (!turbo || sl_act);
        if (aec) cram_ra <= cb_a[9:0];
        if (aec && clk_phi && c64_rst_n && !frz_q && cpu_req && (!turbo || sl_act)) begin  // CPU read / write
            c_we      <= cb_we;
            c_addr    <= cpu_mem_a;
            c_din     <= cb_do;
            c_req_tgl <= !c_req_tgl;
        end
      end else if (t3 && own_vic) begin                 // VIC-II read: its address is new from tick 2 on
        cram_ra   <= vic_addr[9:0];
        m_we      <= 1'b0;
        m_addr    <= vic_mem_a;
        m_req_tgl <= !m_req_tgl;
      end
      if (t_go && cpu_req && !t_slow) begin             // turbo: the request right after the latch
        c_we      <= cb_we;
        c_addr    <= cpu_mem_a;
        c_din     <= cb_do;
        c_req_tgl <= !c_req_tgl;
      end
    end

// Snapshot restore mode: on with the rising edge of CTL[0] (the ESP32 resets the CPU, whose
// vector and restore program come from the restore bank); off at the first opcode fetch
// after an RTI, before its memory access (the CPU then runs on in the restored state)
reg  [2:0] rm_s;
reg  [1:0] rst_s;
reg        rti_seen;
always @(posedge clk or negedge c64_rst_n)
    if (!c64_rst_n) begin
        rmode    <= 1'b0;
        cpu_rst  <= 1'b0;
        rm_s     <= 3'b000;
        rst_s    <= 2'b00;
        rti_seen <= 1'b0;
    end else begin
        rm_s    <= {rm_s[1:0], s_rm};
        rst_s   <= {rst_s[0], s_rst};
        cpu_rst <= rst_s[1];
        if (rm_s[2:1] == 2'b01) begin
            rmode    <= 1'b1;
            rti_seen <= 1'b0;
        end else if (rmode) begin
            if (cpu_ce && cpu_sync) rti_seen <= cpu_di == 8'h40;
            if (!clk_phi && t2 && !turbo && cpu_sync && rti_seen) begin
                rmode    <= 1'b0;
                rti_seen <= 1'b0;
            end
        end
    end

// Turbo state. The mode changes at tick 1 of phi1, between two cycles.
reg [1:0] tw_s;
always @(posedge clk or negedge c64_rst_n)
    if (!c64_rst_n) begin
        turbo  <= 1'b0;
        t_busy <= 1'b0;
        t_go   <= 1'b0;
        t_rdy  <= 1'b0;
        sl_act <= 1'b0;
        tw_s   <= 2'b00;
    end else begin
        tw_s  <= {tw_s[0], t_allow};
        t_go  <= t_lat;
        t_rdy <= t_chk;
        if (t_lat) t_busy <= 1'b1;
        // sl_act stays on after the clock enable until phi1 tick 2: the VIC-II takes a CPU write
        // at tick 0 of phi1, with its chip select still on (as cb_* stay put in the normal timing)
        if (!clk_phi && t2) sl_act <= turbo && t_busy && t_slow;
        if (cpu_ce && turbo) t_busy <= 1'b0;
        if (!clk_phi && phase[1] && !t_busy) turbo <= tw_s[1];
    end

// VIC-II read data, kept as the open-bus value
always @(posedge clk)
    if (phase[0] && own_vic) vic_last <= m_dout;

//-----------------------------------------------------------------------------
// Colour RAM (1K x 4): CPU writes at tick 12, read port follows the bus owner
//-----------------------------------------------------------------------------
reg [3:0] cram [0:1023];
reg [3:0] cram_q;
wire      cram_we = cpu_cyc && t12 && sel_cram && cb_we;
always @(posedge clk) begin
    if (cram_we) cram[cb_a[9:0]] <= cb_do[3:0];
    cram_q <= cram[cram_ra];
end

assign vic_dbi = {cram_q, own_vic ? m_dout : cb_do};

//-----------------------------------------------------------------------------
// 6510 port writes
//-----------------------------------------------------------------------------
always @(posedge clk or negedge c64_rst_n)
    if (!c64_rst_n) begin
        p_ddr <= 8'h00;
        p_dat <= 8'h00;
    end else if ((turbo ? cyc_n_t : cpu_cyc && t12) && sel_port && cb_we) begin
        if (cb_a[0]) p_dat <= cb_do;
        else         p_ddr <= cb_do;
    end

//-----------------------------------------------------------------------------
// 1541 disk drive (device 8). Present when the ROM image has its DOS ROM (header
// byte 13 = 1); held in reset with the C64. The ESP32 inserts a .d64 and keeps the
// track under the head in the track buffer (tape loader MCTL / MSTAT / MCLR):
//   MCTL  [0] disk inserted, [1] read only, [2] turbo allowed (F6), [13:8] track in the buffer,
//         [23:16] id1, [31:24] id2
//   MSTAT [5:0] head track, [6] motor, [7] LED, [28:8] sectors written by the DOS (dirty)
//   MCLR  [20:0] clear those dirty bits (after writing them to the .d64)
//-----------------------------------------------------------------------------
wire [7:0]  cia2_pa_out_w = c2_ok ? cia2_pa_out : 8'h00;            // before / in reset: no line pulled
always @(posedge clk or negedge c64_rst_n)
    if (!c64_rst_n)  c2_ok <= 1'b0;
    else if (cia_p)  c2_ok <= 1'b1;
wire        iec_clk, iec_data;
wire [31:0] l_mctl, l_mclr;
wire        l_mclr_we;
reg         drv_rom;                    // the image has a 1541 ROM
wire        rom_wr = ld_req && !ld_done && ld_addr[17:14] == 4'b0110;          // 0x18000-0x1BFFF
always @(posedge clk_sd or negedge rst_sd_n)
    if (!rst_sd_n)                                   drv_rom <= 1'b0;
    else if (ld_req && !ld_done && ld_addr == 18'h1000D) drv_rom <= ld_din == 8'h01;

reg  [31:0] mctl_s1, mctl_s;
reg  [1:0]  drom_s;
reg  [20:0] dclr;
reg  [2:0]  dclr_s;
reg  [20:0] dclr_d;
always @(posedge clk_sd) if (l_mclr_we) dclr_d <= l_mclr[20:0];
reg         dclr_t;
always @(posedge clk_sd or negedge rst_sd_n)
    if (!rst_sd_n) dclr_t <= 1'b0;
    else if (l_mclr_we) dclr_t <= !dclr_t;
always @(posedge clk) begin
    mctl_s1 <= l_mctl;  mctl_s <= mctl_s1;
    drom_s  <= {drom_s[0], drv_rom};
    dclr_s  <= {dclr_s[1:0], dclr_t};
    dclr    <= (dclr_s[2] != dclr_s[1]) ? dclr_d : 21'd0;          // dclr_d is static by then
end

wire [5:0]  d_track;
wire        d_motor, d_led;
wire [20:0] d_dirty;
wire        tb_we;
wire [12:0] tb_a;
wire [7:0]  tb_d, tb_q;

// turbo: MCTL[2] (ESP32, F6) and a motor running; the C64 waits while the ESP32 refills the
// track buffer for a new head position
assign t_allow  = mctl_s[2] && (d_motor || cass_motor) && !rmode;
assign drv_wait = mctl_s[0] && d_motor && d_track >= 6'd1 && d_track <= 6'd35 && mctl_s[13:8] != d_track;

c1541 u_drive (
    .clk       (clk),
    .rst       (!(c64_rst_n && drom_s[1])),
    .turbo     (turbo),
    .c64_cyc   (cpu_ce),
    .c64_atn   (cia2_pa_out_w[3]),
    .c64_clk   (cia2_pa_out_w[4]),
    .c64_data  (cia2_pa_out_w[5]),
    .bus_clk   (iec_clk),
    .bus_data  (iec_data),
    .disk      (mctl_s[0]),
    .wprot     (mctl_s[1]),
    .loaded    (mctl_s[13:8]),
    .id1       (mctl_s[23:16]),
    .id2       (mctl_s[31:24]),
    .track     (d_track),
    .motor     (d_motor),
    .led       (d_led),
    .dirty     (d_dirty),
    .dirty_clr (dclr),
    .clk_sd    (clk_sd),
    .rom_wr    (rom_wr),
    .rom_a     (ld_addr[13:0]),
    .rom_d     (ld_din),
    .tb_we     (tb_we),
    .tb_a      (tb_a),
    .tb_d      (tb_d),
    .tb_q      (tb_q)
);

//-----------------------------------------------------------------------------
// CIAs: phi2_p at tick 0 of the CPU half, phi2_n at tick 12; TOD 50 Hz
//-----------------------------------------------------------------------------
wire [7:0] cia1_do, cia2_do, cia1_pa_out, cia1_pb_out, cia2_pb_out;
wire [23:0] cia1_st, cia2_st;           // {CRB, CRA, 3'b0, IMR} (snapshots)
reg  [7:0] cia1_pa_in, cia1_pb_in;
wire       cass_read;

localparam integer TOD_HALF = CLK_HZ / 100;
reg [19:0] tod_cnt;
reg        tod;
always @(posedge clk)
    if (tod_cnt == TOD_HALF - 1) begin
        tod_cnt <= 20'd0;
        tod     <= !tod;
    end else
        tod_cnt <= tod_cnt + 20'd1;

mos6526 u_cia1 (
    .mode    (1'b0),
    .clk     (clk),
    .phi2_p  (cia_p),
    .phi2_n  (cia_n),
    .res_n   (c64_rst_n),
    .cs_n    (!(sel_cia1 && (turbo ? t_busy : cpu_cyc))),
    .rw      (!cb_we),
    .rs      (cb_a[3:0]),
    .db_in   (cb_do),
    .db_out  (cia1_do),
    .pa_in   (cia1_pa_in),
    .pa_out  (cia1_pa_out),
    .pa_oe   (),
    .pb_in   (cia1_pb_in),
    .pb_out  (cia1_pb_out),
    .pb_oe   (),
    .flag_n  (cass_read),
    .pc_n    (),
    .tod     (tod),
    .sp_in   (1'b1),
    .sp_out  (),
    .cnt_in  (1'b1),
    .cnt_out (),
    .irq_n   (cia1_irq_n),
    .state   (cia1_st)
);

// CIA2 port A: 1:0 VIC bank, 3 ATN out, 4 CLK out, 5 DATA out (1 = line pulled low,
// through the inverters), 6 CLK in, 7 DATA in (line levels, with the 1541's pulls).
mos6526 u_cia2 (
    .mode    (1'b0),
    .clk     (clk),
    .phi2_p  (cia_p),
    .phi2_n  (cia_n),
    .res_n   (c64_rst_n),
    .cs_n    (!(sel_cia2 && (turbo ? t_busy : cpu_cyc))),
    .rw      (!cb_we),
    .rs      (cb_a[3:0]),
    .db_in   (cb_do),
    .db_out  (cia2_do),
    .pa_in   ({iec_data, iec_clk, cia2_pa_out[5:0]}),
    .pa_out  (cia2_pa_out),
    .pa_oe   (),
    .pb_in   (cia2_pb_out),
    .pb_out  (cia2_pb_out),
    .pb_oe   (),
    .flag_n  (1'b1),
    .pc_n    (),
    .tod     (tod),
    .sp_in   (1'b1),
    .sp_out  (),
    .cnt_in  (1'b1),
    .cnt_out (),
    .irq_n   (cia2_irq_n),
    .state   (cia2_st)
);

//-----------------------------------------------------------------------------
// Keyboard matrix + joysticks on CIA1 (both directions, as the real wiring):
//   port A = keyboard columns + control port 2, port B = rows + control port 1
// Joystick bits (C64): 0 up, 1 down, 2 left, 3 right, 4 fire, active low.
// Mode (tape loader INTPOS[29:28], ESP32 F4 menu): 0 DB9-1 = port 2, DB9-2 = port 1;
// 1 swapped; 2 both on port 2.
//-----------------------------------------------------------------------------
wire [1:0] joy_mode;
reg  [1:0] jm_s1, jm_s;
reg  [4:0] j1_s1, j1, j2_s1, j2;        // active low, C64 bit order
reg  [4:0] port1, port2;
always @(posedge clk) begin
    jm_s1 <= joy_mode;  jm_s <= jm_s1;
    j1_s1 <= {joy1_n[4], joy1_n[0], joy1_n[1], joy1_n[2], joy1_n[3]};  j1 <= j1_s1;
    j2_s1 <= {joy2_n[4], joy2_n[0], joy2_n[1], joy2_n[2], joy2_n[3]};  j2 <= j2_s1;
    case (jm_s)
        2'd1:    begin port2 <= j2;      port1 <= j1;    end
        2'd2:    begin port2 <= j1 & j2; port1 <= 5'h1F; end
        default: begin port2 <= j1;      port1 <= j2;    end
    endcase
end

integer ka, kb;
reg [7:0] pa_drv, pb_drv, pa_k, pb_k;
always @* begin
    pa_drv = cia1_pa_out & {3'b111, port2};
    pb_drv = cia1_pb_out & {3'b111, port1};
    pa_k = 8'hFF;
    pb_k = 8'hFF;
    for (ka = 0; ka < 8; ka = ka + 1)
        for (kb = 0; kb < 8; kb = kb + 1)
            if (kb_keys[8 * ka + kb]) begin
                if (!pa_drv[ka]) pb_k[kb] = 1'b0;
                if (!pb_drv[kb]) pa_k[ka] = 1'b0;
            end
end

always @(posedge clk) begin
    cia1_pa_in <= pa_drv & pa_k;
    cia1_pb_in <= pb_drv & pb_k;
end

assign vic_lp = cia1_pb_in[4];          // light pen = control port 1 fire

//-----------------------------------------------------------------------------
// SID (6581 or 8580, F5 / ESP32): register access at tick 12 of a CPU half, 1 MHz enable at tick 15
//-----------------------------------------------------------------------------
wire [7:0]  sid_do;
wire [17:0] sid_audio;
wire        l_cont_on;                  // tape loader INTPOS[31] = 0 (reset): 6581; 1: 8580 (F5)
reg  [1:0]  sid_s;
always @(posedge clk) sid_s <= {sid_s[0], !l_cont_on};

sid_top #(.MULTI_FILTERS(0), .DUAL(0)) u_sid (
    .reset       (!c64_rst_n),
    .clk         (clk),
    .ce_1m       (clk_phi && t15 && !frz_q),
    .cs          (sel_sid && cpu_cyc && t12),
    .we          (cb_we),
    .addr        (cb_a[4:0]),
    .data_in     (cb_do),
    .data_out    (sid_do),
    .fc_offset_l (13'd0),
    .pot_x_l     (8'hFF),
    .pot_y_l     (8'hFF),
    .ext_in_l    (18'd0),
    .audio_l     (sid_audio),
    .fc_offset_r (13'd0),
    .pot_x_r     (8'hFF),
    .pot_y_r     (8'hFF),
    .ext_in_r    (18'd0),
    .audio_r     (),
    .filter_en   (1'b1),
    .mode        (sid_s[1]),
    .cfg         (2'b00),
    .ld_clk      (clk),
    .ld_addr     (12'd0),
    .ld_data     (16'd0),
    .ld_wr       (1'b0)
);

//-----------------------------------------------------------------------------
// CPU read data (taken by the T65 at tick 15)
//-----------------------------------------------------------------------------
always @* begin
    if (sel_port)       cpu_di = cb_a[0] ? p_pin : p_ddr;
    else if (cpu_mem)   cpu_di = c_dout;
    else if (sel_vic)   cpu_di = vic_dbo;
    else if (sel_sid)   cpu_di = sid_do;
    else if (sel_cram)  cpu_di = {vic_last[7:4], cram_q};
    else if (sel_cia1)  cpu_di = cia1_do;
    else if (sel_cia2)  cpu_di = cia2_do;
    else                cpu_di = vic_last;               // DE00-DFFF: open bus
end

//-----------------------------------------------------------------------------
// Audio: SID -> sigma-delta pin and Bluetooth I2S (both at clk_sd)
//-----------------------------------------------------------------------------
reg [9:0]  snd;
always @(posedge clk_sd) snd <= {~sid_audio[17], sid_audio[16:8]};    // signed -> unsigned

sd_dac #(.W(10)) u_dac (
    .clk   (clk_sd),
    .rst_n (rst_sd_n),
    .din   (snd),
    .dout  (audio)
);

// bt_i2s low-passes at its "AY" sample rate: 3.5469 MHz from a DDS, as in LSpectrum
reg  [31:0] bt_dds;
reg         bt_cen;
wire [32:0] bt_next = {1'b0, bt_dds} + 33'd161151148;    // 3.5469 / 94.53125 * 2^32
always @(posedge clk_sd) begin
    bt_dds <= bt_next[31:0];
    bt_cen <= bt_next[32];
end

bt_i2s u_bt (
    .clk      (clk_sd),
    .rst_n    (rst_sd_n),
    .ay_cen   (bt_cen),
    .ay_sound (snd),
    .beeper   (1'b0),
    .i2s_bclk (bt_bclk),
    .i2s_lrck (bt_lrck),
    .i2s_data (bt_data)
);

//-----------------------------------------------------------------------------
// Tape loader hardware + ESP32 link (clk_sd). The pulse player counts C64 cycles
// (cen_tgl toggles once per phi cycle while the cassette motor is on).
//-----------------------------------------------------------------------------
reg        cen_tgl;
always @(posedge clk or negedge c64_rst_n)
    if (!c64_rst_n)              cen_tgl <= 1'b0;
    else if (cpu_ce && cass_motor) cen_tgl <= !cen_tgl;     // (cpu_ce is off while frozen / held)

wire       l_tape_on, l_tape_lvl;
wire       osd_we;
wire [9:0] osd_addr;
wire [7:0] osd_data;

tape_loader #(.BAUD_DIV(821), .CORE_ID(32'h4336_0001)) u_tape (
    .clk         (clk_sd),
    .rst_n       (rst_sd_n),
    .keys        (lkeys),
    .keyraw      (kb_raw),
    .cen_tgl     (cen_tgl),
    .mic         (cass_write),
    .hold        (l_hold),
    .tape_on     (l_tape_on),
    .tape_turbo  (),
    .tape_lvl    (l_tape_lvl),
    .osd_on      (l_osd_on),
    .osd_full    (l_osd_full),
    .osd_we      (osd_we),
    .osd_addr    (osd_addr),
    .osd_data    (osd_data),
    .int_pos     (),
    .cont_on     (l_cont_on),
    .joy_mode    (joy_mode),
    .fl_en       (fl_en),
    .fl_ncs      (fl_ncs),
    .fl_dclk     (fl_dclk),
    .fl_mosi     (fl_mosi),
    .fl_miso     (f_miso),
    .reload      (l_reload),
    .mctl        (l_mctl),
    .mstat       ({3'd0, d_dirty, d_led, d_motor, d_track}),
    .mclr        (l_mclr),
    .mclr_we     (l_mclr_we),
    .snap_freeze (snap_freeze),
    .snap_req    (snap_req),
    .snap_cmd    (snap_cmd),
    .snap_addr   (snap_addr),
    .snap_wdata  (snap_wdata),
    .snap_frozen (frz_q),
    .snap_ack    (snap_ack),
    .snap_rdata  (snap_rdata),
    .bt_tx       (bt_tx),
    .bt_rx       (bt_rx),
    .esp_sck     (esp_sck),
    .esp_mosi    (esp_mosi),
    .esp_cs_n    (esp_cs_n),
    .esp_miso    (esp_miso),
    .esp_irq     (esp_irq)
);

reg [1:0] ton_s;
always @(posedge clk) ton_s <= {ton_s[0], l_tape_on};
assign cass_sense = !ton_s[1];
assign cass_read  = !ton_s[1] || l_tape_lvl;

//-----------------------------------------------------------------------------
// Snapshot command port (clk_sd; tape_loader SNAPCMD/SNAPDAT, the ESP32's MRD/MWR
// bursts): command codes as LSpectrum (zx_bus.v)
//   1 MRD  read  SDRAM byte at addr[17:0] (CPU frozen)      -> rdata[7:0]
//          While the frame buffer hold is on (CTL[2], screenshots): the byte at addr[16:0] of
//          the newest frame buffer instead (the C64 may run)
//   2 MWR  write wdata[7:0] to addr[17:0]  (CPU frozen)
//   3 REG  addr[2:0] = 0 -> {P, Y, X, A}, 1 -> {PC, S (16 bits, 01xx)} (T65 Regs, static while
//          frozen), 2 / 3 -> CIA1 / CIA2 {CRB, CRA, 3'b0, IMR}
//   4 CTL  wdata[0] 0 -> 1: restore mode on (it ends by itself at the first opcode fetch after an
//          RTI), wdata[1] = CPU-only reset (level), wdata[2] = frame buffer hold (screenshot);
//          rdata[0] = restore mode
//   others: done at once, rdata 0
// Addresses 0x20000-0x2FFFF are the 1541's track buffer (MRD / MWR without a freeze).
//-----------------------------------------------------------------------------
reg  [2:0] sreq_s;
reg  [1:0] sfz_s;
reg  [1:0] tb_st;                       // track buffer access: 1 = address out, 2 = data in
wire       tb_sel = !fb_rd && snap_addr[17:16] == 2'b10;
assign tb_we = sreq_s[2] != snap_ack && tb_sel && snap_cmd == 4'd2 && tb_st == 2'd0 && !sm_pend;
assign tb_a  = snap_addr[12:0];
assign tb_d  = snap_wdata[7:0];
always @(posedge clk_sd or negedge rst_sd_n)
    if (!rst_sd_n) begin
        sreq_s     <= 3'b000;
        sfz_s      <= 2'b00;
        snap_ack   <= 1'b0;
        snap_rdata <= 32'd0;
        sm_pend    <= 1'b0;
        tb_st      <= 2'd0;
        s_rm       <= 1'b0;
        s_rst      <= 1'b0;
        fb_hold    <= 1'b0;
    end else begin
        sreq_s <= {sreq_s[1:0], snap_req};
        if (tb_st != 2'd0) tb_st <= tb_st + 2'd1;
        if (tb_st == 2'd2) begin                                    // tb_q holds the byte (MRD) now
            tb_st      <= 2'd0;
            snap_rdata <= {24'd0, tb_q};
            snap_ack   <= sreq_s[2];
        end
        sfz_s  <= {sfz_s[0], frz_q};
        if (sm_pend) begin
            if (a_busy && !a_bus && !a_cpu && !a_fb && ram_ack) begin
                sm_pend    <= 1'b0;
                snap_rdata <= {24'd0, ram_dout};
                snap_ack   <= sreq_s[2];
            end
        end else if (sreq_s[2] != snap_ack && tb_st == 2'd0 && tb_sel && (snap_cmd == 4'd1 || snap_cmd == 4'd2)) begin
            tb_st <= 2'd1;                                          // track buffer: no freeze needed
        end else if (sreq_s[2] != snap_ack && tb_st == 2'd0 && !(a_busy && !a_bus && !a_cpu && !a_fb)) begin
            case (snap_cmd)
                4'd1, 4'd2: if (sfz_s[1] || fb_rd) sm_pend <= 1'b1;
                            else begin snap_rdata <= 32'd0; snap_ack <= sreq_s[2]; end
                4'd3: begin
                    case (snap_addr[2:0])
                        3'd0: snap_rdata <= cpu_regs[31:0];
                        3'd1: snap_rdata <= cpu_regs[63:32];
                        3'd2: snap_rdata <= {8'd0, cia1_st};
                        default: snap_rdata <= {8'd0, cia2_st};
                    endcase
                    snap_ack <= sreq_s[2];
                end
                4'd4: begin
                    s_rm       <= snap_wdata[0];
                    s_rst      <= snap_wdata[1];
                    fb_hold    <= snap_wdata[2];
                    snap_rdata <= {31'd0, rmode};
                    snap_ack   <= sreq_s[2];
                end
                default: begin snap_rdata <= 32'd0; snap_ack <= sreq_s[2]; end
            endcase
        end
    end

//-----------------------------------------------------------------------------
// Video
//-----------------------------------------------------------------------------
wire [17:0] f_rgb;
wire        f_hs, f_vs, f_act;

c64_fb u_fb (
    .clk      (clk),
    .rst_n    (por_n),
    .pixel    (k_pixel),
    .rx       (k_rx),
    .rline    (k_rline),
    .hold     (fb_hold),
    .newest   (fb_newest),
    .clk_sd   (clk_sd),
    .rst_sd_n (rst_sd_n),
    .m_req    (fb_req),
    .m_we     (fb_we),
    .m_addr   (fb_addr),
    .m_wdata  (fb_wdata),
    .m_ack    (fb_ack),
    .m_rdata  (ram_dout_w),
    .pclk     (pclk),
    .prst_n   (prst_n),
    .m60      (m60),
    .rgb      (f_rgb),
    .hsync    (f_hs),
    .vsync    (f_vs),
    .active   (f_act)
);

c64_video #(.FONT_HEX(FONT_HEX)) u_video (
    .clk       (pclk),
    .red       (f_rgb[17:12]),
    .green     (f_rgb[11:6]),
    .blue      (f_rgb[5:0]),
    .hsync     (f_hs),
    .vsync     (f_vs),
    .active    (f_act),
    .osd_wclk  (clk_sd),
    .osd_we    (osd_we),
    .osd_waddr (osd_addr),
    .osd_wdata (osd_data),
    .osd_on    (l_osd_on),
    .osd_full  (l_osd_full),
    .vga_r     (vga_r),
    .vga_g     (vga_g),
    .vga_b     (vga_b),
    .vga_hs    (vga_hs),
    .vga_vs    (vga_vs)
);

//-----------------------------------------------------------------------------
// LED (active low): off; fast blink = ROM image missing in flash
//-----------------------------------------------------------------------------
reg [22:0] blink;
always @(posedge clk) begin
    blink <= blink + 23'd1;
    led   <= bad_image ? blink[21] : !d_led;                // on = the 1541's LED
end

endmodule

`default_nettype wire
