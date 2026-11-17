/* nes_system -- LNES: the NES (NTSC) without the PLLs and pins */
/* */
/* CPU T65 (6502 without decimal mode, as the NES's 2A03), our own PPU (nes_ppu), sound */
/* (nes_apu) and cartridge mappers (nes_mapper). No system ROM: the NES has none. */
/* */
/* Time base: clk = 21.449 MHz = 4 per PPU dot (ph 0..3) and 12 per CPU cycle (dn 0..2 dots): */
/* dn 0 ph 0   the cycle's owner (CPU or DMA) and its address, data and direction are latched */
/* dn 0 ph 1   SDRAM request for RAM / cartridge memory */
/* dn 2 ph 1   register strobes: PPU, sound, controllers, mapper */
/* dn 2 ph 2   the read data is latched */
/* dn 2 ph 3   the cycle ends: the CPU (T65 enable) takes the data */
/* */
/* Memory (SDRAM, 22-bit byte addresses): */
/* 0x000000-0x0007FF  the NES's 2 KB RAM ($0000-$1FFF, mirrored) */
/* 0x002000-0x003FFF  cartridge RAM, 8 KB at $6000-$7FFF (battery RAM of the games that have it) */
/* 0x040000-0x09FFFF  frame buffers (nes_fb, 3 x 128 KB, 16-bit accesses) */
/* 0x100000-0x17FFFF  pattern memory (CHR ROM, or 8 KB of CHR RAM): the two planes of a tile row */
/* share a 16-bit word (address bit 3 is the byte lane), so the PPU reads */
/* both with one access; every other user's address is converted the same way */
/* 0x200000-0x2FFFFF  program ROM (PRG), 8 KB banks */
/* SDRAM users, by priority: the CPU's cycle, the PPU's pattern fetch, the ESP32's memory port, */
/* the RAM clear, the frame buffer. */
/* */
/* Cartridge (cart word, written by the ESP32 after it loaded the file into the SDRAM): */
/* [7:0] mapper, [14:8] program mask (8 KB banks - 1), [23:15] pattern mask (1 KB banks - 1), */
/* [24] vertical mirroring, [25] four screens, [26] pattern memory is RAM, [31] cartridge in */
/* (the machine runs; 0 holds it in reset). When [31] rises the 2 KB RAM is cleared first. */
/* */
/* DMA: a write to $4014 copies 256 bytes into the sprite table (the CPU stops at its next read */
/* cycle, then read / write pairs); the sound's sample channel takes single read cycles the */
/* same way. */
`default_nettype none

module nes_system #(
    parameter integer SD_MHZ    = 86,
    parameter         PULSE_HEX = "nes_pulse.hex",
    parameter         TND_HEX   = "nes_tnd.hex"
)(
    input  wire        clk,
/* power-up, KEY0 */
    input  wire        rst_n,
/* 4 x clk, rising edges aligned */
    input  wire        clk_sd,
    input  wire        rst_sd_n,
/* the cartridge word (clk_sd, quasi-static) */
    input  wire [31:0] cart,
/* the console's Reset button */
    input  wire        reset_key,
/* controllers: A, B, Select, Start, Up, Down, Left, Right (bit 0 first), 1 = pressed */
    input  wire [7:0]  pad1,
    input  wire [7:0]  pad2,

/* SDRAM */
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

/* picture and sound */
    output wire        px_stb,
    output wire [7:0]  px_x,
    output wire [7:0]  px_y,
    output wire [5:0]  px_c,
    output wire [2:0]  px_e,
    output wire        px_eof,
    output wire [9:0]  audio,
/* the machine is out of reset (clk) */
    output wire        run_o,
/* toggles at every CPU write to the cartridge RAM (clk) */
    output reg         wram_tgl,

/* frame buffer SDRAM port (clk_sd, 16-bit words: fb_req held until fb_ack) */
    input  wire        fb_req,
    input  wire        fb_we,
    input  wire [21:0] fb_addr,
    input  wire [15:0] fb_wdata,
    output wire        fb_ack,
    output wire [15:0] fb_rdata,

/* ESP32 memory port (clk_sd, bytes: x_req held until x_ack) */
    input  wire        x_req,
    input  wire        x_we,
    input  wire [21:0] x_addr,
    input  wire [7:0]  x_din,
    output wire        x_ack,
    output wire [7:0]  x_dout
);

/* SDRAM access owners */
localparam [2:0] OWN_BUS = 3'd0;
localparam [2:0] OWN_FB  = 3'd1;
localparam [2:0] OWN_X   = 3'd2;
/* the PPU's pattern fetch, the RAM clear */
localparam [2:0] OWN_PPU = 3'd3;
localparam [2:0] OWN_CLR = 3'd4;
/* the last dot of a CPU cycle */
localparam [1:0] DN_LAST = 2'd2;
/* DMA cycle kinds */
localparam [1:0] K_DMC = 2'd1;
localparam [1:0] K_OAM_RD = 2'd2;
localparam [1:0] K_OAM_WR = 2'd3;
/* registers: the PPU's sprite data port, the sprite DMA, the two controller ports, the sound's status */
localparam [15:0] A_OAMDATA = 16'h2004;
localparam [15:0] A_OAMDMA = 16'h4014;
localparam [15:0] A_PAD1 = 16'h4016;
/* the second controller port (read), the sound's status */
localparam [15:0] A_PAD2 = 16'h4017;
localparam [15:0] A_STATUS = 16'h4015;
/* the PPU's data register */
localparam [2:0] R_PPUDATA = 3'd7;
/* the SDRAM areas (the top address bits) */
localparam [2:0] AREA_CHR = 3'b010;
localparam [1:0] AREA_PRG = 2'b10;
localparam [8:0] AREA_WRAM = 9'b0_0000_0001;
/* the data lines' upper bits when a controller port is read */
localparam [7:0] PAD_OPEN = 8'h40;
/* bits of the cartridge word */
localparam integer C_VERT = 24;
localparam integer C_FOUR = 25;
localparam integer C_CHRRAM = 26;
/* the cartridge is in */
localparam integer C_RUN = 31;
/* the RAM clear's last address */
localparam [10:0] CLR_LAST = 11'h7FF;

/* ---- cartridge in: clear the RAM, then run ---- */
reg  [2:0]  run_sd;
reg  [10:0] clr_a;
reg         clr_req, clr_done;
/* a byte was cleared */
wire        clr_ack;
always @(posedge clk_sd or negedge rst_sd_n)
    if (!rst_sd_n)
    begin
/* at reset */
        run_sd   <= 3'b000;
        clr_a    <= 11'd0;
        clr_req  <= 1'b0;
/* not done */
        clr_done <= 1'b0;
    end
    else
    begin
        run_sd <= {run_sd[1:0], cart[C_RUN]};
/* no cartridge: everything starts again */
        if (!run_sd[1])
        begin
            clr_a    <= 11'd0;
            clr_req  <= 1'b0;
/* not done */
            clr_done <= 1'b0;
        end
        else if (!clr_done)
        begin
            clr_req <= 1'b1;
/* a byte is cleared: the next one */
            if (clr_ack)
            begin
                clr_a <= clr_a + 11'd1;
                if (clr_a == CLR_LAST)
                begin
/* all 2 KB are cleared */
                    clr_done <= 1'b1;
                    clr_req  <= 1'b0;
                end
            end
        end
    end

/* resets (clk): crst_n the cartridge's (mapper), mrst_n the machine's (+ the Reset button) */
reg  [1:0] cd_s;
reg        crst_n, mrst_n;
always @(posedge clk or negedge rst_n)
/* at reset */
    if (!rst_n)
    begin
        cd_s   <= 2'b00;
        crst_n <= 1'b0;
/* the machine's reset */
        mrst_n <= 1'b0;
    end
    else
    begin
        cd_s   <= {cd_s[0], clr_done};
        crst_n <= cd_s[1];
/* the Reset button resets the machine, not the cartridge */
        mrst_n <= cd_s[1] && !reset_key;
    end
assign run_o = crst_n;

/* ---- the time base ---- */
reg  [1:0] ph, dn;
reg        odd;
always @(posedge clk or negedge crst_n)
/* at reset */
    if (!crst_n)
    begin
        ph  <= 2'd0;
        dn  <= 2'd0;
/* the first half of a sound cycle */
        odd <= 1'b0;
    end
    else
    begin
        ph <= ph + 2'd1;
        if (ph == 2'b11)
        begin
/* the next dot of the CPU cycle */
            dn <= dn == DN_LAST ? 2'd0 : dn + 2'd1;
/* the sound's half cycle */
            if (dn == DN_LAST)
            begin
                odd <= !odd;
            end
        end
    end
wire t_bus  = dn == 2'd0 && ph == 2'b00;
/* the SDRAM request, the register strobes, the read data */
wire t_req  = dn == 2'd0 && ph == 2'b01;
wire t_io   = dn == DN_LAST && ph == 2'b01;
wire t_rd   = dn == DN_LAST && ph == 2'b10;
/* the end of the CPU cycle */
wire cyc_end = dn == DN_LAST && ph == 2'b11;

/* ---- CPU ---- */
wire [23:0] cpu_a_full;
wire [15:0] cpu_a = cpu_a_full[15:0];
wire [7:0]  cpu_do;
/* its direction, the data it reads */
wire        cpu_rw_n;
reg  [7:0]  bus_di;
wire        ppu_nmi_n, apu_irq, map_irq;
/* the CPU may go on */
reg         rdy;

T65 u_cpu (
    .Mode    (2'b00),
    .BCD_en  (1'b0),
    .Res_n   (mrst_n),
    .Enable  (cyc_end),
    .Clk     (clk),
    .Rdy     (rdy),
    .Abort_n (1'b1),
    .IRQ_n   (!(apu_irq || map_irq)),
    .NMI_n   (ppu_nmi_n),
    .SO_n    (1'b1),
    .R_W_n   (cpu_rw_n),
    .Sync    (),
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
    .Regs    (),
    .DEBUG   (),
    .NMI_ack ()
);

/* ---- DMA: the sprite copy and the sample channel's reads ---- */
wire        dmc_req;
wire [15:0] dmc_addr;
reg         oam_on, oam_have, dma_next, dmc_dummy;
/* the copy's page, byte number and byte */
reg  [7:0]  oam_page, oam_idx, oam_lat;
reg  [1:0]  d_kind;
/* the bus of this cycle */
reg  [15:0] ba;
reg         b_we, b_act, b_dma;
reg  [7:0]  b_do;
/* a write to $4014 */
wire        oam_start = t_io && b_act && b_we && ba == A_OAMDMA;
/* the next cycle is the first half of a sound cycle: a read ("get") cycle */
wire        next_get = odd;
wire        dmc_ack  = cyc_end && b_dma && d_kind == K_DMC;
/* the CPU is asked to stop; it does at a read cycle, and stays so through the DMA's cycles */
wire        stop     = oam_on || oam_start || dmc_req;
wire        stopped  = (stop || b_dma) && cpu_rw_n;
wire        oam_fin  = b_dma && d_kind == K_OAM_WR && oam_idx == 8'hFF;
/* something is left to do */
wire        more     = (oam_on && !oam_fin) || (dmc_req && !dmc_ack);
/* a byte of the copy is waiting to be written, as it will be after this cycle */
wire        oam_have_n = (b_dma && d_kind == K_OAM_RD) || (oam_have && !(b_dma && d_kind == K_OAM_WR));
always @*
begin
    rdy = !(stop || b_dma);
end

/* the DMA's state */
always @(posedge clk or negedge mrst_n)
    if (!mrst_n)
    begin
        oam_on <= 1'b0;
/* no byte read yet */
        oam_have <= 1'b0;
        dma_next <= 1'b0;
        dmc_dummy <= 1'b0;
/* nothing copied yet */
        oam_page <= 8'd0;
        oam_idx <= 8'd0;
        oam_lat <= 8'd0;
/* no DMA cycle */
        d_kind <= 2'd0;
    end
    else
    begin
/* a write to $4014 starts the copy */
        if (oam_start)
        begin
            oam_on   <= 1'b1;
            oam_page <= b_do;
/* from the page's first byte */
            oam_idx  <= 8'd0;
            oam_have <= 1'b0;
        end

        if (cyc_end)
        begin
/* what this cycle did */
            if (b_dma && d_kind == K_OAM_RD)
            begin
                oam_lat  <= bus_di;
                oam_have <= 1'b1;
            end
/* a byte went into the sprite table */
            if (b_dma && d_kind == K_OAM_WR)
            begin
                oam_have <= 1'b0;
                oam_idx  <= oam_idx + 8'd1;
/* the last of the 256 */
                if (oam_fin)
                begin
                    oam_on <= 1'b0;
                end
            end

/* the next cycle is the DMA's while the CPU is stopped and something is left to do */
            dma_next <= stopped && more;
            if (!(stopped && more))
            begin
                dmc_dummy <= 1'b0;
/* an ordinary CPU cycle follows */
                d_kind    <= 2'd0;
            end
/* the sample's byte first: one idle cycle, then a read cycle */
            else if (dmc_req && !dmc_ack && !dmc_dummy && !oam_on)
            begin
                dmc_dummy <= 1'b1;
                d_kind    <= 2'd0;
            end
/* the sample's byte, on a read cycle */
            else if (dmc_req && !dmc_ack && next_get)
            begin
                d_kind <= K_DMC;
            end
            else if (oam_on && next_get && !oam_have_n)
            begin
/* a byte of the page is read */
                d_kind <= K_OAM_RD;
            end
            else if (oam_on && !next_get && oam_have_n && !oam_fin)
            begin
                d_kind <= K_OAM_WR;
            end
            else
            begin
/* an idle cycle (alignment) */
                d_kind <= 2'd0;
            end
        end
    end

/* the bus latch */
always @(posedge clk or negedge crst_n)
    if (!crst_n)
    begin
        ba    <= 16'd0;
/* a read of nothing */
        b_we  <= 1'b0;
        b_act <= 1'b0;
        b_dma <= 1'b0;
/* no data */
        b_do  <= 8'd0;
    end
    else if (t_bus)
    begin
        b_dma <= dma_next;
/* the CPU's own cycle */
        if (!dma_next)
        begin
/* the CPU's own cycle */
            ba    <= cpu_a;
            b_we  <= !cpu_rw_n;
            b_do  <= cpu_do;
/* not while the machine is in reset */
            b_act <= mrst_n;
        end
        else
        begin
            case (d_kind)
                K_DMC:    ba <= dmc_addr;
/* the next byte of the page */
                K_OAM_RD: ba <= {oam_page, oam_idx};
                default:  ba <= A_OAMDATA;
            endcase
            b_we  <= d_kind == K_OAM_WR;
/* the byte read before */
            b_do  <= oam_lat;
            b_act <= d_kind != 2'd0;
        end
    end

/* ---- address decoding ---- */
wire        is_ram  = ba[15:13] == 3'b000;
wire        is_ppu  = ba[15:13] == 3'b001;
wire        is_wram = ba[15:13] == 3'b011;
/* cartridge ROM; the sound and controller registers */
wire        is_prg  = ba[15];
wire        is_apu  = ba[15:5] == 11'b0100_0000_000;
/* $2007 below $2000 is the pattern memory */
wire [14:0] ppu_v;
wire        is_chr  = is_ppu && ba[2:0] == R_PPUDATA && !ppu_v[13];
wire        chr_ram = cart[C_CHRRAM];

/* the mapper's banks */
wire [27:0] prg_bank;
wire [71:0] chr_bank;
wire [2:0]  mirror;
/* the program bank of this address, the pattern bank of v */
wire [6:0]  prg_b  = prg_bank[ba[14:13] * 7 +: 7];
wire [8:0]  chr_bv = chr_bank[ppu_v[12:10] * 9 +: 9];
wire [12:0] pt_addr;
/* the pattern bank of the PPU's fetch */
wire [8:0]  chr_bp = chr_bank[pt_addr[12:10] * 9 +: 9];
/* pattern memory address -> SDRAM address: bit 3 becomes the byte lane */
wire [18:0] chr_cv = {chr_bv, ppu_v[9:0]};
wire [21:0] sd_chr_v = {AREA_CHR, chr_cv[18:4], chr_cv[2:0], chr_cv[3]};
wire [21:0] sd_chr_p = {AREA_CHR, chr_bp, pt_addr[9:4], pt_addr[2:0], 1'b0};
/* the SDRAM address of this cycle */
wire [21:0] sd_ad  = is_ram  ? {11'd0, ba[10:0]} :
                     is_wram ? {AREA_WRAM, ba[12:0]} :
                     is_chr  ? sd_chr_v :
                               {AREA_PRG, prg_b, ba[12:0]};

/* ---- SDRAM request of the cycle ---- */
reg         m_req_tgl, m_we;
reg  [21:0] m_addr;
reg  [7:0]  m_din;
/* what may be written and what is read from the SDRAM */
wire        m_wr_ok = is_ram || is_wram || (is_chr && chr_ram);
wire        m_rd_ok = is_ram || is_wram || is_chr || is_prg;
always @(posedge clk or negedge crst_n)
/* at reset */
    if (!crst_n)
    begin
        m_req_tgl <= 1'b0;
        m_we      <= 1'b0;
/* no address */
        m_addr    <= 22'd0;
        m_din     <= 8'd0;
        wram_tgl  <= 1'b0;
    end
/* a memory cycle */
    else if (t_req && b_act && (b_we ? m_wr_ok : m_rd_ok))
    begin
        m_req_tgl <= !m_req_tgl;
        m_we      <= b_we;
/* its address and data */
        m_addr    <= sd_ad;
        m_din     <= b_do;
/* the cartridge RAM changed */
        if (b_we && is_wram)
        begin
            wram_tgl <= !wram_tgl;
        end
    end

/* ---- arbiter (clk_sd) ---- */
wire        pt_tgl;
reg         m_rq_d, pt_d;
reg  [7:0]  m_dout;
/* both planes of the tile row fetched last */
reg  [15:0] pt_q;
reg         a_req, a_busy, a_we, a_wide;
reg  [2:0]  a_own;
/* its address and data */
reg  [21:0] a_addr;
reg  [7:0]  a_din, a_dhi;
reg  [7:0]  x_q;
/* the ESP32's access is done */
reg         x_done;
wire [7:0]  ram_dout;
wire [15:0] ram_dout_w;
/* the SDRAM controller's answers */
wire        ram_ack, ram_ready;
/* the ESP32's address into the pattern memory is converted like the CPU's */
wire [21:0] x_sd = x_addr[21:19] == AREA_CHR ? {AREA_CHR, x_addr[18:4], x_addr[2:0], x_addr[3]} : x_addr;

always @(posedge clk_sd or negedge rst_sd_n)
    if (!rst_sd_n)
    begin
/* at reset */
        m_rq_d <= 1'b0;
        pt_d   <= 1'b0;
        m_dout <= 8'hFF;
/* no pattern data */
        pt_q   <= 16'd0;
/* no access */
        a_req  <= 1'b0;
        a_busy <= 1'b0;
        a_we   <= 1'b0;
/* a byte access */
        a_wide <= 1'b0;
        a_own  <= OWN_BUS;
        a_addr <= 22'd0;
/* no data */
        a_din  <= 8'd0;
        a_dhi  <= 8'd0;
/* the ESP32's port */
        x_q    <= 8'hFF;
        x_done <= 1'b0;
    end
    else
    begin
        a_req <= 1'b0;
/* the ESP32 took its answer */
        if (!x_req)
        begin
            x_done <= 1'b0;
        end
        if (!a_busy)
        begin
/* a byte access unless said otherwise */
            a_wide <= 1'b0;
/* the CPU's cycle */
            if (m_req_tgl != m_rq_d)
            begin
                m_rq_d <= m_req_tgl;
                a_busy <= 1'b1;
/* its request */
                a_req  <= 1'b1;
                a_own  <= OWN_BUS;
                a_we   <= m_we;
/* address and data */
                a_addr <= m_addr;
                a_din  <= m_din;
            end
/* the PPU's pattern fetch: both planes in one word */
            else if (pt_tgl != pt_d)
            begin
                pt_d   <= pt_tgl;
                a_busy <= 1'b1;
/* its request */
                a_req  <= 1'b1;
                a_own  <= OWN_PPU;
                a_wide <= 1'b1;
/* a read */
                a_we   <= 1'b0;
                a_addr <= sd_chr_p;
            end
/* the ESP32 */
            else if (x_req && !x_done)
            begin
                a_busy <= 1'b1;
                a_req  <= 1'b1;
/* its owner and direction */
                a_own  <= OWN_X;
                a_we   <= x_we;
                a_addr <= x_sd;
/* its data */
                a_din  <= x_din;
            end
/* the RAM clear */
            else if (clr_req && !clr_ack)
            begin
                a_busy <= 1'b1;
                a_req  <= 1'b1;
/* its owner: a write of 0 */
                a_own  <= OWN_CLR;
                a_we   <= 1'b1;
                a_addr <= {11'd0, clr_a};
/* zero */
                a_din  <= 8'd0;
            end
/* the frame buffer */
            else if (fb_req && !fb_ack)
            begin
                a_busy <= 1'b1;
                a_req  <= 1'b1;
/* its owner: a word access */
                a_own  <= OWN_FB;
                a_wide <= 1'b1;
                a_we   <= fb_we;
/* address and data */
                a_addr <= fb_addr;
                a_din  <= fb_wdata[7:0];
                a_dhi  <= fb_wdata[15:8];
            end
        end
/* the access is over */
        else if (ram_ack)
        begin
            a_busy <= 1'b0;
/* the read data goes to its owner */
            if (a_own == OWN_BUS && !a_we)
            begin
                m_dout <= ram_dout;
            end
            if (a_own == OWN_PPU)
            begin
/* both planes */
                pt_q <= ram_dout_w;
            end
            if (a_own == OWN_X)
            begin
                if (!a_we)
                begin
/* the byte read */
                    x_q <= ram_dout;
                end
                x_done <= 1'b1;
            end
        end
    end

assign fb_ack   = a_busy && a_own == OWN_FB && ram_ack;
/* the frame buffer's read data; the clear's and the ESP32's answers */
assign fb_rdata = ram_dout_w;
assign clr_ack  = a_busy && a_own == OWN_CLR && ram_ack;
assign x_ack    = x_done;
/* the ESP32's byte; the SDRAM controller */
assign x_dout   = x_q;

sdram_ram #(.ADDR_BITS(22), .CLK_MHZ(SD_MHZ)) u_ram (
    .clk      (clk_sd),
    .rst_n    (rst_sd_n),
    .req      (a_req),
    .we       (a_we),
    .addr     (a_addr),
    .din      (a_din),
    .wide     (a_wide),
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

/* ---- the chips ---- */
wire [7:0] ppu_q, apu_q;
wire       ppu_a12;

nes_ppu u_ppu (
    .clk     (clk),
    .rst_n   (mrst_n),
    .ph      (ph),
    .reg_we  (t_io && b_act && b_we && is_ppu),
    .reg_re  (t_io && b_act && !b_we && is_ppu),
    .reg_a   (ba[2:0]),
    .reg_d   (b_do),
    .reg_q   (ppu_q),
    .nmi_n   (ppu_nmi_n),
    .mirror  (mirror),
    .v_o     (ppu_v),
    .chr_q   (m_dout),
    .pt_tgl  (pt_tgl),
    .pt_addr (pt_addr),
    .pt_q    (pt_q),
    .a12     (ppu_a12),
    .px_stb  (px_stb),
    .px_x    (px_x),
    .px_y    (px_y),
    .px_c    (px_c),
    .px_e    (px_e),
    .px_eof  (px_eof)
);

/* the sound */
nes_apu #(.PULSE_HEX(PULSE_HEX), .TND_HEX(TND_HEX)) u_apu (
    .clk      (clk),
    .rst_n    (mrst_n),
    .cyc      (cyc_end),
    .odd      (odd),
    .reg_we   (t_io && b_act && b_we && is_apu),
    .reg_re   (t_io && b_act && !b_we && !b_dma && is_apu),
    .reg_a    (ba[4:0]),
    .reg_d    (b_do),
    .reg_q    (apu_q),
    .irq      (apu_irq),
    .dmc_req  (dmc_req),
    .dmc_addr (dmc_addr),
    .dmc_ack  (dmc_ack),
    .dmc_d    (bus_di),
    .audio    (audio)
);

nes_mapper u_map (
    .clk      (clk),
    .rst_n    (crst_n),
    .mapper   (cart[7:0]),
    .prg_mask (cart[14:8]),
    .chr_mask (cart[23:15]),
    .hdr_vert (cart[C_VERT]),
    .hdr_four (cart[C_FOUR]),
    .we       (t_io && b_act && b_we && is_prg),
    .a        (ba[14:0]),
    .d        (b_do),
    .cyc      (cyc_end),
    .cyc_we   (b_act && b_we),
    .a12      (ppu_a12),
    .prg_bank (prg_bank),
    .chr_bank (chr_bank),
    .mirror   (mirror),
    .irq      (map_irq)
);

/* ---- controllers: a shift register each, loaded while the strobe bit is 1 ---- */
reg        pad_strobe;
reg  [7:0] pad_sr1, pad_sr2;
reg  [7:0] p1_s, p2_s, p1_q, p2_q;
/* the buttons, synchronised */
always @(posedge clk)
begin
    p1_s <= pad1;
    p2_s <= pad2;
/* a second stage */
    p1_q <= p1_s;
    p2_q <= p2_s;
end
always @(posedge clk or negedge mrst_n)
/* at reset */
    if (!mrst_n)
    begin
        pad_strobe <= 1'b0;
        pad_sr1    <= 8'd0;
/* the second controller's */
        pad_sr2    <= 8'd0;
    end
    else
    begin
        if (pad_strobe)
        begin
            pad_sr1 <= p1_q;
/* the second controller's */
            pad_sr2 <= p2_q;
        end
        if (t_io && b_act && b_we && ba == A_PAD1)
        begin
            pad_strobe <= b_do[0];
        end
/* a read shifts to the next button; ones follow the eighth */
        if (cyc_end && b_act && !b_we && !pad_strobe)
        begin
            if (ba == A_PAD1)
            begin
                pad_sr1 <= {1'b1, pad_sr1[7:1]};
            end
/* the second controller's */
            if (ba == A_PAD2)
            begin
                pad_sr2 <= {1'b1, pad_sr2[7:1]};
            end
        end
    end

/* ---- read data ---- */
always @(posedge clk)
    if (t_rd && b_act)
    begin
        if (b_we)
        begin
/* a write: the bus keeps the written value */
            bus_di <= b_do;
        end
        else if (is_ppu)
        begin
            bus_di <= ppu_q;
        end
/* RAM and cartridge memory */
        else if (m_rd_ok)
        begin
            bus_di <= m_dout;
        end
        else if (ba == A_STATUS)
        begin
/* the status: bit 5 keeps the bus's last value */
            bus_di <= {apu_q[7:6], bus_di[5], apu_q[4:0]};
        end
        else if (ba == A_PAD1)
        begin
            bus_di <= PAD_OPEN | {7'd0, pad_sr1[0]};
        end
/* the second controller */
        else if (ba == A_PAD2)
        begin
            bus_di <= PAD_OPEN | {7'd0, pad_sr2[0]};
        end
    end

endmodule

`default_nettype wire
