//=============================================================================
// atari_system -- LTari: Atari 130XE / 800XL (PAL) without the PLLs and pins
//
// Machine cycle = 16 clk ticks (clk = 28.373 MHz, 2 x the PAL master clock):
//   tick 0   the cycle's owner is known: ANTIC DMA, refresh, or the CPU (whose address,
//            data and R/W changed at its enable at tick 15 of the cycle before)
//   tick 1   bus latched (address, R/W, data, ANTIC or CPU), SDRAM request for RAM / ROM
//   tick 12  chip register writes; read strobes (PIA flags)
//   tick 13  read data latched (SDRAM done by about tick 9; chip registers)
//   tick 15  cyc_end: the CPU (T65 enable) or ANTIC takes the data
// WSYNC holds the CPU through RDY (T65 stops on read cycles only, as the 6502).
//
// Memory (SDRAM, 21-bit byte addresses):
//   0x00000-0x0FFFF  main RAM
//   0x10000-0x1FFFF  130XE extended RAM, banks 0-3 of 16 KB
//   0x20000          ROM image from flash (rom_loader): 0x20000 header (F3 "LTARI ROMS"),
//                    0x21000 OS (16 KB, $C000-$FFFF), 0x25000 BASIC (8 KB, $A000-$BFFF)
//   0x28000-0x2BFFF  cartridge image (written by the ESP32): 8 KB at $A000 or 16 KB at $8000
//   0x30000-0x3FFFF  snapshot restore bank (the CPU's whole view in restore mode, except the I/O at
//                    $D000-$D7FF); its 0x3D000-0x3D7FF = the I/O shadow: every CPU write to $D000-$D7FF
//                    also goes there (GTIA / POKEY / PIA / ANTIC register mirrors folded)
//   0x40000-0x9FFFF  frame buffers (atari_fb.v, 3 x 128 KB, 16-bit accesses)
//   0x100000-0x1FFFFF Atarimax cartridge image (128 KB or 1 MB, 8 KB banks at $A000)
//   RAM (128 KB) cleared after each ROM load, before the machine starts.
// SDRAM users: the bus (CPU / ANTIC, one access per machine cycle), the ESP32's memory port
// (tape loader snapshot commands) and the frame buffer, in this order.
// MMU (XL/XE, NOTES.md): PORTB 0 OS on, 1 BASIC off, 7 self-test off, 3:2 bank,
// 4 CPU / 5 ANTIC window $4000-$7FFF off (130XE only). A cartridge covers BASIC / RAM;
// GTIA's TRIG3 reads 1 while one is in. Writes to ROM / cartridge are dropped.
// I/O $D000 GTIA, $D200 POKEY, $D300 PIA, $D400 ANTIC; $D100, $D500-$D7FF read $FF.
// Snapshots (as L64): freeze stops the whole machine at a cycle boundary before a CPU
// opcode fetch (tick held at 0: no chip acts on tick 0), so the CPU registers are an instruction
// boundary and the SDRAM is free for the ESP32. Restore mode: the CPU (not ANTIC) sees the restore
// bank, where the ESP32's restore program writes the chips and ends with RTI; the first opcode
// fetch after the RTI ends it. NMIs are masked meanwhile.
//=============================================================================
`default_nettype none

module atari_system #(
    parameter integer SD_MHZ    = 85,
    parameter [23:0]  ROM_FLASH = 24'h540000,   // ROM image in the configuration flash
    parameter integer FLASH_DIV = 4
)(
    input  wire        clk,
    input  wire        rst_n,           // machine reset (power-up, KEY0)
    input  wire        clk_sd,          // 3 x clk, rising edges aligned
    input  wire        rst_sd_n,
    input  wire        model130,        // 1 = 130XE (128 KB), 0 = 800XL
    input  wire        reload,          // clk_sd: cold start (ROM reload, RAM clear; the ESP32 after a disk change)
    input  wire [2:0]  cart,            // cartridge (quasi-static): 0 none, 1 standard 8 KB ($A000), 2 standard 16 KB
                                        // ($8000), 3 Atarimax 128 KB, 4 Atarimax 1 MB (bank 0 at start), 5 the same
                                        // starting in bank 127
    input  wire        reset_key,       // the Atari's Reset key (XL/XE: system reset)

    // snapshots (clk_sd levels from the snapshot port; outputs static while frozen)
    input  wire        freeze,          // stop at the next instruction boundary
    input  wire        rm_req,          // rising edge: restore mode on
    input  wire        cpu_rst_req,     // CPU-only reset (level)
    output reg         frozen,
    output reg         rmode,
    output wire [63:0] cpu_regs,        // T65 Regs: {PC, S (16), P, Y, X, A}
    output wire [47:0] pia_st,          // {PBCTL, DDRB, ORB, PACTL, DDRA, ORA}
    output wire [11:0] cart_st,         // {off, bank[6:0], 1'b0, type[2:0]} (Atarimax state)

    // keyboard / console / joysticks
    input  wire        key_stb,
    input  wire [5:0]  key_code,
    input  wire        key_down,
    input  wire        key_shift,
    input  wire        key_ctrl,
    input  wire        key_break,
    input  wire [2:0]  consol_n,        // START, SELECT, OPTION
    input  wire [7:0]  joy_dir_n,       // PORTA: stick 1 bits 3:0, stick 2 bits 7:4
    input  wire [1:0]  joy_trig_n,

    // SDRAM
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

    // flash (flash_if)
    output wire        f_dclk,
    output wire        f_ncs,
    output wire        f_mosi,
    input  wire        f_miso,

    // SIO
    output wire        sio_out,
    input  wire        sio_in,
    output wire        sio_cmd_n,
    output wire        sio_motor_n,
    output wire        so_stb,          // POKEY loads a byte into its output shift register (one clk)
    output wire [7:0]  so_byte,

    // video (GTIA output, 2 hi-res pixels per colour clock) and audio
    output wire        px_stb,
    output wire [7:0]  px_cc,
    output wire [8:0]  px_vc,
    output wire        px_blank,
    output wire [7:0]  px0,
    output wire [7:0]  px1,
    output wire [5:0]  audio,
    output wire        speaker,
    output wire        bad_image,
    output wire        run_o,           // the machine is out of reset (clk)

    // frame buffer SDRAM port (clk_sd, atari_fb: m_req held until m_ack, 16-bit words)
    input  wire        fb_req,
    input  wire        fb_we,
    input  wire [20:0] fb_addr,
    input  wire [15:0] fb_wdata,
    output wire        fb_ack,
    output wire [15:0] fb_rdata,

    // ESP32 memory port (clk_sd, byte accesses: x_req held until x_ack)
    input  wire        x_req,
    input  wire        x_we,
    input  wire [20:0] x_addr,
    input  wire [7:0]  x_din,
    output wire        x_ack,
    output wire [7:0]  x_dout
);

//-----------------------------------------------------------------------------
// SDRAM: ROM loader, then the RAM clear, then the bus
//-----------------------------------------------------------------------------
wire        ld_req, ld_we, ld_rom_done;
wire [17:0] ld_addr;
wire [7:0]  ld_din;
wire [7:0]  ram_dout;
wire [15:0] ram_dout_w;
wire        ram_ack, ram_ready;
reg  [16:0] clr_a;
reg         clr_req, clr_wait, ld_clr_done;
wire        ld_done = ld_clr_done;

// reload (the ESP32, tape loader register 0x44): the loader and the RAM clear start again, so
// ld_done falls and the machine is held in reset until the ROMs are back (a cold start)
reg  [3:0]  rld_sr;
always @(posedge clk_sd or negedge rst_sd_n)
    if (!rst_sd_n) rld_sr <= 4'hF;
    else           rld_sr <= {rld_sr[2:0], !reload};
wire        ld_rst_n = rst_sd_n & (&rld_sr);

rom_loader #(.FLASH_ADDR(ROM_FLASH), .SD_BASE(18'h20000), .LEN(28672), .DIV(FLASH_DIV)) u_loader (
    .clk       (clk_sd),
    .rst_n     (ld_rst_n),
    .f_dclk    (f_dclk),
    .f_ncs     (f_ncs),
    .f_mosi    (f_mosi),
    .f_miso    (f_miso),
    .sd_req    (ld_req),
    .sd_we     (ld_we),
    .sd_addr   (ld_addr),
    .sd_din    (ld_din),
    .sd_ack    (ram_ack & !ld_rom_done),
    .done      (ld_rom_done),
    .bad_image (bad_image)
);

// RAM clear (main + extended, 128 KB): the SDRAM keeps its contents through a
// reconfiguration, and a program's reset handler would catch the next start
always @(posedge clk_sd or negedge ld_rst_n)
    if (!ld_rst_n) begin
        clr_a <= 17'd0; clr_req <= 1'b0; clr_wait <= 1'b0; ld_clr_done <= 1'b0;
    end else begin
        clr_req <= 1'b0;
        if (ld_rom_done && !ld_clr_done) begin
            if (!clr_wait) begin
                clr_req  <= 1'b1;
                clr_wait <= 1'b1;
            end else if (ram_ack) begin
                clr_wait <= 1'b0;
                clr_a    <= clr_a + 17'd1;
                if (&clr_a) ld_clr_done <= 1'b1;
            end
        end
    end

// Arbiter: the bus (clk domain request toggle, held until the access is done) first, then
// the ESP32 (the link drops a byte that is not done within ~1 us), then the frame buffer
// (FIFO and line buffer slack). The bus asks at tick 1 and takes the data at tick 13
// (36 clk_sd later); an access in progress delays it by one access at most (~8 clk_sd,
// plus a refresh): it is done in time.
reg         m_req_tgl, m_we;
reg  [20:0] m_addr;
reg  [7:0]  m_din;
reg         m_rq_d;
reg  [7:0]  m_dout;
reg         a_req, a_busy, a_we, a_wide;
reg  [1:0]  a_own;                      // 0 bus, 1 frame buffer, 2 ESP32
reg  [20:0] a_addr;
reg  [7:0]  a_din, a_dhi;
reg  [7:0]  x_q;
reg         x_done;

always @(posedge clk_sd or negedge rst_sd_n)
    if (!rst_sd_n) begin
        m_rq_d <= 1'b0; m_dout <= 8'hFF; a_req <= 1'b0; a_busy <= 1'b0; a_we <= 1'b0;
        a_wide <= 1'b0; a_own <= 2'd0; a_addr <= 21'd0; a_din <= 8'd0; a_dhi <= 8'd0;
        x_q <= 8'hFF; x_done <= 1'b0;
    end else begin
        a_req <= 1'b0;
        if (!x_req) x_done <= 1'b0;
        if (!a_busy && ld_done) begin
            if (m_req_tgl != m_rq_d) begin
                m_rq_d <= m_req_tgl;
                a_busy <= 1'b1; a_req <= 1'b1; a_own <= 2'd0; a_wide <= 1'b0;
                a_we   <= m_we; a_addr <= m_addr; a_din <= m_din;
            end else if (x_req && !x_done) begin
                a_busy <= 1'b1; a_req <= 1'b1; a_own <= 2'd2; a_wide <= 1'b0;
                a_we   <= x_we; a_addr <= x_addr; a_din <= x_din;
            end else if (fb_req && !fb_ack) begin
                a_busy <= 1'b1; a_req <= 1'b1; a_own <= 2'd1; a_wide <= 1'b1;
                a_we   <= fb_we; a_addr <= fb_addr; a_din <= fb_wdata[7:0]; a_dhi <= fb_wdata[15:8];
            end
        end else if (a_busy && ram_ack) begin
            a_busy <= 1'b0;
            if (a_own == 2'd0 && !a_we) m_dout <= ram_dout;
            if (a_own == 2'd2) begin
                if (!a_we) x_q <= ram_dout;
                x_done <= 1'b1;
            end
        end
    end

assign fb_ack   = a_busy && a_own == 2'd1 && ram_ack;
assign fb_rdata = ram_dout_w;
assign x_ack    = x_done;
assign x_dout   = x_q;

wire        lc_req  = ld_rom_done ? clr_req : ld_req;
wire [20:0] lc_addr = ld_rom_done ? {4'b0000, clr_a} : {3'b000, ld_addr};
wire [7:0]  lc_din  = ld_rom_done ? 8'h00 : ld_din;

sdram_ram #(.ADDR_BITS(21), .CLK_MHZ(SD_MHZ)) u_ram (
    .clk      (clk_sd),
    .rst_n    (rst_sd_n),
    .req      (ld_done ? a_req  : lc_req),
    .we       (ld_done ? a_we   : 1'b1),
    .addr     (ld_done ? a_addr : lc_addr),
    .din      (ld_done ? a_din  : lc_din),
    .wide     (ld_done && a_wide),
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

//-----------------------------------------------------------------------------
// Machine timing and resets
//-----------------------------------------------------------------------------
reg  [1:0] ld_done_s;
reg        run, mrst_n;                 // machine running; CPU / ANTIC / PIA / MMU reset (+ Reset key)
always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
        ld_done_s <= 2'b00; run <= 1'b0; mrst_n <= 1'b0;
    end else begin
        ld_done_s <= {ld_done_s[0], ld_done};
        run       <= ld_done_s[1];
        mrst_n    <= ld_done_s[1] && !reset_key;
    end

reg  [3:0] tick;
wire       cpu_sync;
reg  [1:0] frz_s;
wire       frz_now = tick == 4'd0 && (frozen || (frz_s[1] && cpu_sync));
always @(posedge clk or negedge run)
    if (!run) tick <= 4'd0;
    else if (!frz_now) tick <= tick + 4'd1;

// freeze: at tick 0, when the CPU's next own cycle is an opcode fetch (Sync stays up through
// ANTIC's DMA cycles before it); released at tick 0 as well
always @(posedge clk or negedge run)
    if (!run) begin
        frz_s <= 2'b00; frozen <= 1'b0;
    end else begin
        frz_s <= {frz_s[0], freeze};
        if (tick == 4'd0) frozen <= frz_s[1] && (frozen || cpu_sync);
    end
wire cyc_end = tick == 4'd15;
assign run_o = run;

//-----------------------------------------------------------------------------
// CPU and chips
//-----------------------------------------------------------------------------
wire [23:0] cpu_a_full;
wire [15:0] cpu_a = cpu_a_full[15:0];
wire [7:0]  cpu_do;
wire        cpu_rw_n;
reg  [7:0]  bus_di;
wire        a_dma, a_rfsh, a_rdy, a_nmi_n;
wire [15:0] a_dma_a;
wire        pokey_irq, pia_irq;
wire        cpu_cyc = !a_dma && !a_rfsh;
reg         cpu_rst;                    // snapshot: CPU-only reset

T65 u_cpu (
    .Mode    (2'b00),
    .BCD_en  (1'b1),
    .Res_n   (mrst_n && !cpu_rst),
    .Enable  (cyc_end && cpu_cyc),
    .Clk     (clk),
    .Rdy     (a_rdy),
    .Abort_n (1'b1),
    .IRQ_n   (!(pokey_irq || pia_irq)),
    .NMI_n   (a_nmi_n || rmode),
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
    .DI      (bus_di),
    .DO      (cpu_do),
    .Regs    (cpu_regs),
    .DEBUG   (),
    .NMI_ack ()
);

// bus latch (tick 1)
reg  [15:0] ba;
reg         b_we, b_antic, b_act;
reg  [7:0]  b_do;
always @(posedge clk or negedge run)
    if (!run) begin
        ba <= 16'd0; b_we <= 1'b0; b_antic <= 1'b0; b_act <= 1'b0; b_do <= 8'd0;
    end else if (tick == 4'd0) begin
        ba      <= a_dma ? a_dma_a : cpu_a;
        b_we    <= cpu_cyc && !cpu_rw_n;
        b_antic <= a_dma;
        b_act   <= !a_rfsh;
        b_do    <= cpu_do;
    end

// Restore mode: on with the rising edge of rm_req; off at tick 0 of the first CPU opcode fetch
// after an RTI (before its SDRAM request at tick 1)
reg  [2:0] rm_s;
reg  [1:0] crs_s;
reg        rti_seen;
always @(posedge clk or negedge run)
    if (!run) begin
        rm_s <= 3'b000; crs_s <= 2'b00; cpu_rst <= 1'b0; rmode <= 1'b0; rti_seen <= 1'b0;
    end else begin
        rm_s    <= {rm_s[1:0], rm_req};
        crs_s   <= {crs_s[0], cpu_rst_req};
        cpu_rst <= crs_s[1];
        if (rm_s[2:1] == 2'b01) begin
            rmode    <= 1'b1;
            rti_seen <= 1'b0;
        end else if (rmode) begin
            if (cyc_end && cpu_cyc && a_rdy && cpu_sync) rti_seen <= bus_di == 8'h40;
            if (tick == 4'd0 && cpu_sync && rti_seen) begin
                rmode    <= 1'b0;
                rti_seen <= 1'b0;
            end
        end
    end

// MMU
wire [7:0]  pb;                         // PIA port B as the MMU sees it
wire        os_on  = pb[0];
wire        bas_on = !pb[1];
wire        st_on  = !pb[7] && pb[0];
wire        win_on = model130 && (b_antic ? !pb[5] : !pb[4]);
wire        in_io  = ba[15:11] == 5'b11010;                       // $D000-$D7FF
wire        is_st  = st_on && ba[15:11] == 5'b01010;               // $5000-$57FF
wire        is_os  = os_on && ba[15:14] == 2'b11 && !in_io;        // $C000-$CFFF, $D800-$FFFF
reg  [6:0]  c_bank;                     // Atarimax: the 8 KB bank at $A000
reg         c_off;                      // Atarimax: cartridge switched off
wire        c_max  = cart >= 3'd3;
assign      cart_st = {c_off, c_bank, 1'b0, cart};
wire        c_in   = cart != 3'd0 && !(c_max && c_off);                  // RD5: a cartridge at $A000
wire        is_car = (c_in && ba[15:13] == 3'b101) || (cart == 3'd2 && ba[15:13] == 3'b100);
wire        is_bas = bas_on && ba[15:13] == 3'b101 && !is_car;     // $A000-$BFFF
wire        is_win = win_on && ba[15:14] == 2'b01;                 // $4000-$7FFF
wire        is_rom = is_st || is_os || is_bas || is_car;
wire        is_rb  = rmode && !b_antic;                            // restore mode: the CPU sees the bank
wire [20:0] sd_ad  = is_rb  ? {5'b0_0011, ba} :                       // 0x30000 + A
                     is_car ? (c_max ? {1'b1, c_bank, ba[12:0]} :            // 0x100000 + bank * 8 KB
                               cart == 3'd2 ? {7'b0_0010_10, ba[13:0]} :     // 0x28000 + (A - $8000)
                                              {8'b0_0010_100, ba[12:0]}) :   // 0x28000 + (A - $A000)
                     is_st  ? {10'b0_0010_0010_0, ba[10:0]} :        // 0x22000 + offset (OS $D000-$D7FF)
                     is_os  ? {7'b0_0010_00, ba[13:0]} + 21'h01000 : // 0x21000 + (A - $C000)
                     is_bas ? {8'b0_0010_010, ba[12:0]} + 21'h01000 : // 0x25000 + (A - $A000)
                     is_win ? {5'b0_0001, pb[3:2], ba[13:0]} :        // 0x10000 + bank * 16 KB
                              {5'b0_0000, ba};

// chip selects
wire        cs_gtia  = in_io && ba[10:8] == 3'd0;
wire        cs_pokey = in_io && ba[10:8] == 3'd2;
wire        cs_pia   = in_io && ba[10:8] == 3'd3;
wire        cs_antic = in_io && ba[10:8] == 3'd4;
wire        io_we    = tick == 4'd12 && b_act && b_we && in_io;
wire        io_re    = tick == 4'd12 && b_act && !b_we && !b_antic && in_io;
wire [7:0]  q_gtia, q_pokey, q_pia, q_antic;
wire [7:0]  io_q     = cs_gtia ? q_gtia : cs_pokey ? q_pokey : cs_pia ? q_pia : cs_antic ? q_antic : 8'hFF;

// Atarimax banking (manual 8.2): any access (read or write, CPU or ANTIC) to $D500-$D5FF; 128 KB:
// $D500-$D51F, bits 3:0 bank, bit 4 off; 1 MB: bits 6:0 bank, bit 7 off. The cartridge cannot see
// the Reset key: only a cold start (run) resets it.
always @(posedge clk or negedge run)
    if (!run) begin
        c_bank <= cart == 3'd5 ? 7'd127 : 7'd0;
        c_off  <= 1'b0;
    end else if (tick == 4'd12 && b_act && ba[15:8] == 8'hD5) begin
        if (cart == 3'd3 && ba[7:5] == 3'b000) begin c_bank <= {3'b000, ba[3:0]}; c_off <= ba[4]; end
        if (cart == 3'd4 || cart == 3'd5)      begin c_bank <= ba[6:0];           c_off <= ba[7]; end
    end

// I/O shadow address of a register write (mirrors folded)
wire [7:0]  io_lo  = cs_gtia ? {3'd0, ba[4:0]} : cs_pia ? {6'd0, ba[1:0]} :
                     (cs_pokey || cs_antic) ? {4'd0, ba[3:0]} : ba[7:0];

// SDRAM request (tick 1): RAM reads / writes, ROM reads; an I/O write also goes to the shadow
always @(posedge clk or negedge run)
    if (!run) begin
        m_req_tgl <= 1'b0; m_we <= 1'b0; m_addr <= 21'd0; m_din <= 8'd0;
    end else if (tick == 4'd1 && b_act && !in_io && !(b_we && is_rom && !is_rb)) begin
        m_req_tgl <= !m_req_tgl;
        m_we      <= b_we;
        m_addr    <= sd_ad;
        m_din     <= b_do;
    end else if (tick == 4'd1 && b_act && in_io && b_we) begin
        m_req_tgl <= !m_req_tgl;
        m_we      <= 1'b1;
        m_addr    <= {10'b0_0011_1101_0, ba[10:8], io_lo};                // 0x3D000 + chip page + register
        m_din     <= b_do;
    end

// read data (tick 13)
always @(posedge clk)
    if (tick == 4'd13) bus_di <= in_io ? io_q : m_dout;

wire        an_stb, an_hires, pm_we;
wire [2:0]  an_q, pm_sel;
wire [7:0]  an_cc, pm_d;
wire [8:0]  an_vc;

antic u_antic (
    .clk      (clk),
    .rst_n    (mrst_n),
    .tick     (tick),
    .cyc_end  (cyc_end),
    .reg_we   (io_we && cs_antic),
    .reg_a    (ba[3:0]),
    .reg_d    (b_do),
    .reg_q    (q_antic),
    .dma      (a_dma),
    .rfsh     (a_rfsh),
    .dma_a    (a_dma_a),
    .dma_d    (bus_di),
    .rdy      (a_rdy),
    .nmi_n    (a_nmi_n),
    .an_stb   (an_stb),
    .an_q     (an_q),
    .an_cc    (an_cc),
    .an_vc    (an_vc),
    .an_hires (an_hires),
    .pm_we    (pm_we),
    .pm_sel   (pm_sel),
    .pm_d     (pm_d)
);

gtia u_gtia (
    .clk      (clk),
    .rst_n    (run),                    // GTIA has no reset: power-up only
    .reg_we   (io_we && cs_gtia),
    .reg_a    (ba[4:0]),
    .reg_d    (b_do),
    .reg_q    (q_gtia),
    .an_stb   (an_stb),
    .an_q     (an_q),
    .an_cc    (an_cc),
    .an_vc    (an_vc),
    .an_hires (an_hires),
    .pm_we    (pm_we),
    .pm_sel   (pm_sel),
    .pm_d     (pm_d),
    .trig_n   ({c_in, 1'b1, joy_trig_n}),   // TRIG3 = 1: a cartridge at $A000; TRIG2 = 1 (XL/XE)
    .consol_n (consol_n),
    .speaker  (speaker),
    .px_stb   (px_stb),
    .px_cc    (px_cc),
    .px_vc    (px_vc),
    .px_blank (px_blank),
    .px0      (px0),
    .px1      (px1)
);

pokey u_pokey (
    .clk       (clk),
    .rst_n     (run),                   // no reset pin: power-up only
    .cyc_end   (cyc_end),
    .reg_we    (io_we && cs_pokey),
    .reg_re    (io_re && cs_pokey),
    .reg_a     (ba[3:0]),
    .reg_d     (b_do),
    .reg_q     (q_pokey),
    .irq       (pokey_irq),
    .key_stb   (key_stb),
    .key_code  (key_code),
    .key_down  (key_down),
    .key_shift (key_shift),
    .key_ctrl  (key_ctrl),
    .key_break (key_break),
    .sio_out   (sio_out),
    .sio_in    (sio_in),
    .so_stb    (so_stb),
    .so_byte   (so_byte),
    .audio     (audio)
);

pia u_pia (
    .clk     (clk),
    .rst_n   (mrst_n),
    .reg_we  (io_we && cs_pia),
    .reg_re  (io_re && cs_pia),
    .reg_a   (ba[1:0]),
    .reg_d   (b_do),
    .reg_q   (q_pia),
    .irq     (pia_irq),
    .pa_in   (joy_dir_n),
    .st      (pia_st),
    .pb_val  (pb),
    .ca2     (sio_motor_n),
    .cb2     (sio_cmd_n),
    .ca1     (1'b1),
    .cb1     (1'b1)
);

endmodule

`default_nettype wire
