/* md_system -- LMega: the Sega Mega Drive / Genesis without the PLL, the memory and the pins */
/* */
/* The machine's bus logic follows the system module of the MiSTer Genesis core (system.sv, */
/* Copyright (c) 2010 Gregory Estrade, Copyright (c) 2018 Sorgelig; its licence text is in */
/* genesis/SOURCE.md and must stay with this file's distribution): the same bus state machine */
/* between the 68000, the Z80 and the VDP's DMA, the same Z80 bus and bus request handshake. */
/* Changed for this board: no block RAM for the 68000's RAM, the cartridge RAM and the video */
/* RAM (all three are in the SDRAM, through the memory port and the VDP's two video RAM ports), */
/* no cheat codes, no cartridge processors or serial EEPROMs, no multitap / mouse / light gun, */
/* one mono sound output. */
/* */
/* Cores: fx68k (68000, FX68K/), T80 (Z80, T80/), jt12 (YM2612, JT12/), jt89 (SN76489, JT89/), */
/* the VDP of the MiSTer Genesis core (genesis/vdp.vhd). The controller ports are ours. */
/* */
/* Clock: mclk = 53.693 MHz, the console's master clock; everything runs on clock enables: */
/* 68000 mclk / 7 (two phases), Z80 and SN76489 mclk / 15, YM2612 mclk / 7. */
/* */
/* Memory port (toggle handshake: a request is mem_req != mem_ack; the answer sets them equal): */
/* mem_addr = word address: 0x000000 cartridge ROM (4 MB), 0x400000 the 68000's RAM (64 KB), */
/* 0x420000 cartridge RAM (64 KB); mem_be = {upper, lower} byte written; data as the 68000 has */
/* it (bits 15:8 = the byte at the even address). */
/* Video RAM ports: the VDP's own (vram_* 16 bits read / write, vram32_* 32 bits read). */
/* */
/* cart_on = 0 holds everything in reset (no cartridge, or one is being loaded). */
/* Controllers (3-button pads): pad1 / pad2 = {Start, C, B, A, Up, Down, Left, Right}, 1 = pressed. */
`default_nettype none

module md_system (
    input  wire        mclk,
    input  wire        cart_on,
/* resets the VDP alone (its timing runs on without a cartridge, for the on-screen display) */
    input  wire        vdp_rst,
/* the console's region: 50 Hz machine, overseas (not Japan) model */
    input  wire        pal,
    input  wire        overseas,
/* the cartridge has battery RAM at $200000 */
    input  wire        has_sram,
/* the Reset button */
    input  wire        reset_btn,

    input  wire [7:0]  pad1,
    input  wire [7:0]  pad2,

/* memory port */
    output reg         mem_req,
    input  wire        mem_ack,
    output reg         mem_we,
    output reg  [23:1] mem_addr,
    output wire [1:0]  mem_be,
    output wire [15:0] mem_wdata,
    input  wire [15:0] mem_rdata,
/* cartridge RAM written (one mclk) */
    output wire        sram_wr,

/* video RAM ports of the VDP */
    output wire        vram_req,
    input  wire        vram_ack,
    output wire        vram_we,
    output wire [15:1] vram_a,
    output wire [15:0] vram_d,
    input  wire [15:0] vram_q,
    output wire        vram_u_n,
    output wire        vram_l_n,
    output wire        vram32_req,
    input  wire        vram32_ack,
    output wire [15:1] vram32_a,
    input  wire [31:0] vram32_q,

/* picture: 4 bits per colour, valid with ce_pix */
    output wire [3:0]  red,
    output wire [3:0]  green,
    output wire [3:0]  blue,
    output wire        hs,
    output wire        vs,
    output wire        hbl,
    output wire        vbl,
    output wire        ce_pix,
    output wire        interlace,
    output wire        field,
/* [0] = 320 pixels per line (else 256) */
    output wire [1:0]  resolution,

/* sound: signed */
    output reg  signed [15:0] audio
);

/* bus owners */
localparam [1:0] MSRC_M68K = 2'd1;
localparam [1:0] MSRC_Z80  = 2'd2;
localparam [1:0] MSRC_VDP  = 2'd3;
/* states of the main bus */
localparam [3:0] MBUS_IDLE        = 4'd0;
localparam [3:0] MBUS_SELECT      = 4'd1;
localparam [3:0] MBUS_MEM_WRITE   = 4'd2;
/* waiting for the memory, the VDP, the controller ports */
localparam [3:0] MBUS_MEM_WAIT    = 4'd3;
localparam [3:0] MBUS_VDP_READ    = 4'd5;
localparam [3:0] MBUS_IO_READ     = 4'd6;
/* the Z80's memory seen from the main bus */
localparam [3:0] MBUS_ZBUS_PRE    = 4'd9;
localparam [3:0] MBUS_ZBUS_WS     = 4'd10;
localparam [3:0] MBUS_ZBUS_READ   = 4'd11;
/* the answer, and the Z80's first wait */
localparam [3:0] MBUS_FINISH      = 4'd14;
localparam [3:0] MBUS_Z80_PREREAD = 4'd15;
/* states of the Z80's bus */
localparam [1:0] ZBUS_IDLE   = 2'd0;
localparam [1:0] ZBUS_READ   = 2'd1;
localparam [1:0] ZBUS_FINISH = 2'd2;
/* clock dividers: the last count of the 68000's (7) and of the Z80's (15), and their middles */
localparam [3:0] DIV7_LAST = 4'd6;
localparam [3:0] DIV7_MID = 4'd3;
localparam [3:0] DIV15_LAST = 4'd14;
/* the Z80's divider */
localparam [3:0] DIV15_MID = 4'd7;
/* what an unconnected bus reads at the start: the last instruction word, here a NOP */
localparam [15:0] OPCODE_NOP = 16'h4E71;
/* interrupt levels (inverted on the pins): vertical 6, horizontal 4, external 2 */
localparam [2:0] IPL_V = 3'b001;
localparam [2:0] IPL_H = 3'b011;
localparam [2:0] IPL_EX = 3'b101;
/* address areas (the top bits of the 24-bit address) */
localparam [3:0] AREA_ROM_END = 4'hA;
localparam [7:0] AREA_Z80 = 8'hA0;
localparam [15:0] AREA_IO = 16'hA100;
/* the Z80 control registers, the cartridge RAM switch, the VDP's page for the Z80 */
localparam [11:0] AREA_CTRL = 12'hA11;
localparam [15:0] AREA_BANK = 16'hA130;
localparam [15:0] Z80_VDP_PAGE = 16'hC000;
/* control registers: Z80 bus request, Z80 reset */
localparam [3:0] CTRL_BUSREQ = 4'd1;
localparam [3:0] CTRL_RESET = 4'd2;
/* memory port areas: the 68000's RAM, the cartridge RAM (word addresses' top bits) */
localparam [7:0] MEM_RAM = 8'b0100_0000;
localparam [7:0] MEM_SRAM = 8'b0100_0010;
/* controller port registers (the address bits 4:1), and the data registers' value after reset */
localparam [3:0] IO_DATA1 = 4'd1;
localparam [3:0] IO_DATA2 = 4'd2;
localparam [3:0] IO_DATA3 = 4'd3;
/* the three direction registers */
localparam [3:0] IO_CTRL1 = 4'd4;
localparam [3:0] IO_CTRL2 = 4'd5;
localparam [3:0] IO_CTRL3 = 4'd6;
/* a port's pins after reset */
localparam [7:0] IO_DATA_RESET = 8'h7F;
/* the first 64 KB of the cartridge RAM's area; address bits of the Z80's 8 KB RAM */
localparam [7:0] PAGE_SRAM = 8'h20;
localparam integer ZRAM_BITS = 13;
/* Z80 side: the bank register's page */
localparam [6:0] Z80_BANK_PAGE = 7'h60;
/* sound mix: the FM sum times 11, the PSG times 8 */
localparam integer FM_GAIN = 11;
localparam integer PSG_SHIFT = 3;
localparam signed [20:0] MIX_MAX = 21'sd32767;
/* the limits of the 16-bit output */
localparam signed [20:0] MIX_MIN = -21'sd32768;

/* ---- resets ---- */
reg reset, hard_reset;
reg [1:0] on_s;
wire m68k_clkenp, m68k_clkenn;
/* the clock enables */
reg       m68k_clkenp_r, m68k_clkenn_r, z80_clkenp, z80_clkenn, psg_clken, fm_clken;
always @(posedge mclk)
begin
    on_s <= {on_s[0], cart_on};
/* taken on the 68000's clock */
    if (m68k_clkenn_r)
    begin
        reset      <= !on_s[1] || reset_btn;
        hard_reset <= !on_s[1];
    end
end

/* ---- clock enables ---- */
reg [3:0] fclkcnt, vclkcnt, zclkcnt, pclkcnt;
assign m68k_clkenp = m68k_clkenp_r;
assign m68k_clkenn = m68k_clkenn_r;
/* all enables from one set of counters, half a clock before they are used */
always @(negedge mclk)
    if (!on_s[1])
    begin
        vclkcnt <= 4'd0;
/* the other counters */
        pclkcnt <= 4'd0;
        fclkcnt <= 4'd0;
        zclkcnt <= 4'd0;
/* everything enabled, so the resets get through */
        z80_clkenp <= 1'b1;
        z80_clkenn <= 1'b1;
        psg_clken <= 1'b1;
/* the YM2612's */
        fm_clken <= 1'b1;
        m68k_clkenp_r <= 1'b1;
        m68k_clkenn_r <= 1'b1;
    end
    else
    begin
/* the Z80: mclk / 15 */
        z80_clkenn <= 1'b0;
        z80_clkenp <= 1'b0;
        zclkcnt <= zclkcnt + 4'd1;
/* the falling half */
        if (zclkcnt == DIV15_LAST)
        begin
            zclkcnt <= 4'd0;
            z80_clkenn <= 1'b1;
        end
/* the rising half */
        if (zclkcnt == DIV15_MID)
        begin
            z80_clkenp <= 1'b1;
        end
/* the SN76489: mclk / 15 */
        psg_clken <= 1'b0;
        pclkcnt <= pclkcnt + 4'd1;
        if (pclkcnt == DIV15_LAST)
        begin
/* the next period */
            pclkcnt <= 4'd0;
            psg_clken <= 1'b1;
        end
/* the 68000: mclk / 7, two phases */
        m68k_clkenp_r <= 1'b0;
        m68k_clkenn_r <= 1'b0;
        vclkcnt <= vclkcnt + 4'd1;
/* the first phase */
        if (vclkcnt == DIV7_LAST)
        begin
            vclkcnt <= 4'd0;
            m68k_clkenp_r <= 1'b1;
        end
/* the second phase */
        if (vclkcnt == DIV7_MID)
        begin
            m68k_clkenn_r <= 1'b1;
        end
/* the YM2612: mclk / 7 */
        fm_clken <= 1'b0;
        fclkcnt <= fclkcnt + 4'd1;
        if (fclkcnt == DIV7_LAST)
        begin
/* the next period */
            fclkcnt <= 4'd0;
            fm_clken <= 1'b1;
        end
    end

/* ---- 68000 ---- */
wire [23:1] m68k_a;
wire [15:0] m68k_do;
wire        m68k_as_n, m68k_uds_n, m68k_lds_n, m68k_rnw, m68k_bg_n;
/* its function code, the interrupt level */
wire [2:0]  m68k_fc;
reg  [2:0]  m68k_ipl_n;
reg         m68k_mbus_dtack_n;
/* the data it reads */
reg  [15:0] m68k_mbus_d;
wire        m68k_exint, m68k_hint, m68k_vint, z80_vint;
wire        vbus_br_n, vbus_bgack_n;
/* the Z80's bus request to the 68000 */
reg         z80_br_n, z80_bgack_n;
wire        m68k_intack = &m68k_fc;

/* the interrupt level changes between bus cycles only */
reg       old_as;
reg [1:0] scnt;
always @(posedge mclk)
/* no interrupt during reset */
    if (reset)
    begin
        m68k_ipl_n <= 3'b111;
    end
    else if (m68k_clkenp)
    begin
/* the end of a bus cycle, or a while without one */
        old_as <= m68k_as_n;
        scnt   <= m68k_as_n ? scnt + 2'd1 : 2'd0;
        if ((!old_as && m68k_as_n) || (&scnt))
        begin
/* the highest request wins */
            m68k_ipl_n <= m68k_vint ? IPL_V : m68k_hint ? IPL_H : m68k_exint ? IPL_EX : 3'b111;
        end
    end

fx68k u_m68k (
    .clk     (mclk),
    .HALTn   (1'b1),
    .extReset(reset),
    .pwrUp   (hard_reset),
    .enPhi1  (m68k_clkenp),
    .enPhi2  (m68k_clkenn),
    .eRWn    (m68k_rnw),
    .ASn     (m68k_as_n),
    .LDSn    (m68k_lds_n),
    .UDSn    (m68k_uds_n),
    .E       (),
    .VMAn    (),
    .FC0     (m68k_fc[0]),
    .FC1     (m68k_fc[1]),
    .FC2     (m68k_fc[2]),
    .BGn     (m68k_bg_n),
    .oRESETn (),
    .oHALTEDn(),
    .DTACKn  (m68k_mbus_dtack_n),
    .VPAn    (!m68k_intack),
    .BERRn   (1'b1),
    .BRn     (vbus_br_n & z80_br_n),
    .BGACKn  (vbus_bgack_n & z80_bgack_n),
    .IPL0n   (m68k_ipl_n[0]),
    .IPL1n   (m68k_ipl_n[1]),
    .IPL2n   (m68k_ipl_n[2]),
    .iEdb    (m68k_mbus_d),
    .oEdb    (m68k_do),
    .eab     (m68k_a)
);

/* ---- the main bus ---- */
reg  [23:1] mbus_a;
reg  [15:0] mbus_do;
reg         mbus_rnw, mbus_uds_n, mbus_lds_n;
/* the bus's last value */
reg  [15:0] no_data;
reg  [3:0]  mstate;
reg  [1:0]  msrc;
/* the data being collected */
reg  [15:0] mdata;
reg  [1:0]  cycle_cnt;
reg         bank_sram, mem_is_sram;
/* what the address selects */
reg         vdp_sel, io_sel, ctrl_sel, zbus_sel;
reg         z80_mbus_dtack_n, vdp_mbus_dtack_n;
reg  [7:0]  z80_mbus_d;
/* the DMA's data */
reg  [15:0] vdp_mbus_d;
/* the VDP's bus (DMA) */
wire [23:1] vbus_a;
wire        vbus_sel;
wire [15:0] vdp_do;
/* its answers */
wire        vdp_dtack_n;
/* controller ports */
wire [7:0]  io_do;
wire        io_dtack_n;
wire        hl;
/* the Z80 */
reg         z80_reset_n, z80_busrq_n;
wire        z80_busak_n, z80_mreq_n, z80_rd_n, z80_wr_n;
wire [15:0] z80_a;
/* the Z80's data out */
wire [7:0]  z80_do;
wire        z80_io   = !z80_mreq_n && (!z80_rd_n || !z80_wr_n);
wire        z80_zbus = !z80_a[15] && !(&z80_a[14:8]);
/* the Z80's bank register: address bits 23:15 */
reg  [23:15] bar;
reg  [7:0]  mbus_zbus_d;
reg         mbus_zbus_dtack_n;
/* the control registers' answer */
wire        ctrl_f  = (mbus_a[11:8] == CTRL_BUSREQ) ? z80_busak_n :
                      (mbus_a[11:8] == CTRL_RESET)  ? z80_reset_n : no_data[8];
wire [15:0] ctrl_do = {no_data[15:9], ctrl_f, no_data[7:0]};

assign mem_be    = {!mbus_uds_n, !mbus_lds_n};
/* what is written; a write to the cartridge RAM */
assign mem_wdata = mbus_do;
assign sram_wr   = mstate == MBUS_MEM_WAIT && mem_we && mem_is_sram && mem_req == mem_ack;

/* is the address in the cartridge (ROM, or its RAM when the game has one)? */
wire        a_rom  = mbus_a[23:20] < AREA_ROM_END;
wire        a_sram = has_sram && mbus_a[23:21] == 3'b001 && (bank_sram || !mbus_rnw || mbus_a[23:16] == PAGE_SRAM);

always @(posedge mclk)
/* at reset */
    if (reset)
    begin
        m68k_mbus_dtack_n <= 1'b1;
        z80_mbus_dtack_n  <= 1'b1;
/* no answer to the VDP */
        vdp_mbus_dtack_n  <= 1'b1;
/* nothing selected */
        vdp_sel   <= 1'b0;
        io_sel    <= 1'b0;
        zbus_sel  <= 1'b0;
/* no control register */
        ctrl_sel  <= 1'b0;
        bank_sram <= 1'b0;
        mem_is_sram <= 1'b0;
/* the bus idle */
        mstate    <= MBUS_IDLE;
        mbus_rnw  <= 1'b1;
        mbus_uds_n <= 1'b1;
/* no byte strobes */
        mbus_lds_n <= 1'b1;
        no_data   <= OPCODE_NOP;
        mem_we    <= 1'b0;
/* no memory request */
        mem_req   <= mem_ack;
        cycle_cnt <= 2'd0;
    end
    else
    begin
        if (m68k_clkenp && cycle_cnt != 2'd0)
        begin
/* the Z80's wait */
            cycle_cnt <= cycle_cnt - 2'd1;
        end
/* an answer ends with its request */
        if (m68k_as_n)
        begin
            m68k_mbus_dtack_n <= 1'b1;
        end
        if (!z80_io)
        begin
/* the Z80's answer ends */
            z80_mbus_dtack_n <= 1'b1;
        end
        if (!vbus_sel)
        begin
            vdp_mbus_dtack_n <= 1'b1;
        end

/* the bus's state */
        case (mstate)
/* who wants the bus: the 68000, the VDP's DMA, the Z80 (through its bank window) */
            MBUS_IDLE:
            begin
                ctrl_sel   <= 1'b0;
                mbus_rnw   <= 1'b1;
/* no byte strobes */
                mbus_uds_n <= 1'b1;
                mbus_lds_n <= 1'b1;
                if (!m68k_as_n && m68k_mbus_dtack_n)
                begin
/* the 68000 */
                    msrc     <= MSRC_M68K;
                    mbus_a   <= m68k_a;
                    mdata    <= no_data;
/* its data and direction */
                    mbus_do  <= m68k_do;
                    mbus_rnw <= m68k_rnw;
                    mstate   <= MBUS_SELECT;
                end
/* the VDP's DMA reads the bus */
                else if (vbus_sel && vdp_mbus_dtack_n)
                begin
                    msrc    <= MSRC_VDP;
                    mbus_a  <= vbus_a;
/* its data so far */
                    mdata   <= no_data;
                    mbus_do <= 16'd0;
                    mstate  <= MBUS_SELECT;
                end
/* the Z80 through its bank window */
                else if (z80_io && !z80_zbus && z80_mbus_dtack_n && !z80_bgack_n && z80_br_n)
                begin
                    msrc      <= MSRC_Z80;
                    mbus_a    <= z80_a[15] ? {bar, z80_a[14:1]} : {Z80_VDP_PAGE, z80_a[7:1]};
/* an unconnected bus reads ones here */
                    mdata     <= 16'hFFFF;
                    mbus_do   <= {z80_do, z80_do};
                    mbus_rnw  <= z80_wr_n;
/* one 68000 clock later */
                    mstate    <= MBUS_Z80_PREREAD;
                    cycle_cnt <= 2'd1;
                end
            end

            MBUS_Z80_PREREAD:
/* the wait is over */
                if (cycle_cnt == 2'd0)
                begin
                    mstate    <= MBUS_SELECT;
                    cycle_cnt <= 2'd1;
                end

/* what the address means */
            MBUS_SELECT:
            begin
/* nothing there: the bus keeps its last value */
                mstate <= MBUS_FINISH;
                if (a_rom)
                begin
/* cartridge RAM instead of ROM, when the game has it */
                    mem_is_sram <= a_sram;
                    mem_addr    <= a_sram ? {MEM_SRAM, mbus_a[15:1]} : {2'b00, mbus_a[21:1]};
                    if (!mbus_rnw && a_sram)
                    begin
/* a write to the cartridge RAM */
                        mstate <= MBUS_MEM_WRITE;
                    end
                    else if (mbus_rnw)
                    begin
                        mem_we  <= 1'b0;
/* a read */
                        mem_req <= !mem_ack;
                        mstate  <= MBUS_MEM_WAIT;
                    end
                end
/* the Z80's memory, seen by the 68000 while it holds the Z80's bus */
                else if (mbus_a[23:16] == AREA_Z80)
                begin
                    mstate <= !z80_busrq_n ? MBUS_ZBUS_PRE : MBUS_FINISH;
                end
/* controller ports */
                else if (mbus_a[23:8] == AREA_IO && mbus_a[7:5] == 3'b000)
                begin
                    io_sel <= 1'b1;
                    mstate <= MBUS_IO_READ;
                end
/* Z80 bus request and reset */
                else if (mbus_a[23:12] == AREA_CTRL && mbus_a[7:1] == 7'd0)
                begin
                    ctrl_sel <= 1'b1;
                    mdata    <= ctrl_do;
                end
/* cartridge RAM switch */
                else if (mbus_a[23:8] == AREA_BANK)
                begin
                    if (!mbus_rnw)
                    begin
                        bank_sram <= mbus_do[0];
                    end
                end
/* the VDP (and the SN76489 behind it) */
                else if (mbus_a[23:21] == 3'b110 && mbus_a[18:16] == 3'b000 && mbus_a[7:5] == 3'b000)
                begin
                    vdp_sel <= 1'b1;
                    mstate  <= MBUS_VDP_READ;
                end
/* the 68000's RAM */
                else if (&mbus_a[23:21])
                begin
                    mem_is_sram <= 1'b0;
                    mem_addr    <= {MEM_RAM, mbus_a[15:1]};
/* a write waits for the byte strobes */
                    if (!mbus_rnw)
                    begin
                        mstate <= MBUS_MEM_WRITE;
                    end
                    else
                    begin
                        mem_we  <= 1'b0;
/* a read */
                        mem_req <= !mem_ack;
                        mstate  <= MBUS_MEM_WAIT;
                    end
                end
            end

/* a memory write waits until the byte strobes are known */
            MBUS_MEM_WRITE:
                case (msrc)
                    MSRC_M68K:
/* the strobes are valid */
                        if (m68k_as_n || !m68k_uds_n || !m68k_lds_n)
                        begin
                            mbus_uds_n <= m68k_uds_n;
                            mbus_lds_n <= m68k_lds_n;
/* the write goes out */
                            mem_we     <= 1'b1;
                            mem_req    <= !mem_ack;
                            mstate     <= MBUS_MEM_WAIT;
                        end
/* the Z80 writes one byte */
                    MSRC_Z80:
                    begin
                        mbus_uds_n <= z80_a[0];
                        mbus_lds_n <= !z80_a[0];
/* the write goes out */
                        mem_we     <= 1'b1;
                        mem_req    <= !mem_ack;
                        mstate     <= MBUS_MEM_WAIT;
                    end
/* the VDP does not write */
                    default: mstate <= MBUS_FINISH;
                endcase

            MBUS_MEM_WAIT:
                if (mem_req == mem_ack)
                begin
/* the access is done */
                    mem_we <= 1'b0;
                    if (mbus_rnw)
                    begin
                        mdata <= mem_rdata;
/* the bus keeps what the 68000 read */
                        if (msrc == MSRC_M68K)
                        begin
                            no_data <= mem_rdata;
                        end
                    end
                    if (msrc != MSRC_Z80 || cycle_cnt == 2'd0)
                    begin
/* the answer follows */
                        mstate <= MBUS_FINISH;
                    end
                end

/* the Z80's memory for the 68000 or the VDP */
            MBUS_ZBUS_PRE:
                case (msrc)
                    MSRC_M68K:
/* the strobes are valid */
                        if (m68k_as_n || !m68k_uds_n || !m68k_lds_n)
                        begin
                            mbus_uds_n <= m68k_uds_n;
                            mbus_lds_n <= m68k_lds_n;
/* the Z80's bus takes it from here */
                            zbus_sel   <= 1'b1;
                            mstate     <= mbus_rnw ? MBUS_ZBUS_WS : MBUS_ZBUS_READ;
                        end
                    MSRC_Z80:
                    begin
/* the Z80's own byte */
                        mbus_uds_n <= z80_a[0];
                        mbus_lds_n <= !z80_a[0];
                        zbus_sel   <= 1'b1;
/* the access itself */
                        mstate     <= MBUS_ZBUS_READ;
                    end
                    default:
                    begin
                        mbus_uds_n <= 1'b0;
/* both strobes */
                        mbus_lds_n <= 1'b0;
                        zbus_sel   <= 1'b1;
                        mstate     <= MBUS_ZBUS_READ;
                    end
                endcase

/* a read waits a clock */
            MBUS_ZBUS_WS:
                if (m68k_clkenp)
                begin
                    mstate <= MBUS_ZBUS_READ;
                end

/* until the Z80's bus answers */
            MBUS_ZBUS_READ:
                if (!mbus_zbus_dtack_n)
                begin
                    zbus_sel <= 1'b0;
/* the byte on both halves */
                    mdata    <= {mbus_zbus_d, mbus_zbus_d};
                    mstate   <= MBUS_FINISH;
                end

            MBUS_VDP_READ:
/* the VDP answered */
                if (!vdp_dtack_n)
                begin
                    vdp_sel <= 1'b0;
                    mdata   <= vdp_do;
/* the status register's unused bits and the sound chip's place read the bus's last value */
                    if (mbus_a[4:2] == 3'b001)
                    begin
                        mdata[15:10] <= no_data[15:10];
                    end
                    else if (mbus_a[4])
                    begin
/* the sound chip's place */
                        mdata <= no_data;
                    end
                    mstate <= MBUS_FINISH;
                end

            MBUS_IO_READ:
/* the ports answered */
                if (!io_dtack_n)
                begin
                    io_sel <= 1'b0;
                    mdata  <= {io_do, io_do};
/* the answer follows */
                    mstate <= MBUS_FINISH;
                end

/* the answer goes to whoever asked */
            MBUS_FINISH:
                case (msrc)
                    MSRC_M68K:
                    begin
/* the data and the acknowledge */
                        m68k_mbus_d       <= mdata;
                        m68k_mbus_dtack_n <= 1'b0;
                        if (m68k_as_n || mbus_rnw || !m68k_uds_n || !m68k_lds_n)
                        begin
/* the strobes of the end of the cycle */
                            mbus_uds_n <= m68k_uds_n;
                            mbus_lds_n <= m68k_lds_n;
                            mstate     <= MBUS_IDLE;
                        end
                    end
/* the Z80 takes its byte at its clock */
                    MSRC_Z80:
                        if (z80_clkenp)
                        begin
                            z80_mbus_d       <= z80_a[0] ? mdata[7:0] : mdata[15:8];
/* its acknowledge */
                            z80_mbus_dtack_n <= 1'b0;
                            mbus_uds_n       <= z80_a[0];
                            mbus_lds_n       <= !z80_a[0];
/* the bus is free */
                            mstate           <= MBUS_IDLE;
                        end
                    default:
                    begin
                        vdp_mbus_d       <= mdata;
/* its acknowledge */
                        vdp_mbus_dtack_n <= 1'b0;
                        mstate           <= MBUS_IDLE;
                    end
                endcase

            default: mstate <= MBUS_IDLE;
        endcase
    end

/* ---- VDP and SN76489 ---- */
wire        vdp_hs, vdp_vs;
assign hs = !vdp_hs;
assign vs = !vdp_vs;

/* the VDP */
vdp u_vdp (
    .RST_N       (!vdp_rst),
    .CLK         (mclk),
    .SEL         (vdp_sel),
    .A           ({mbus_a[4:1], 1'b0}),
    .RNW         (mbus_rnw),
    .DI          (mbus_do),
    .DO          (vdp_do),
    .DTACK_N     (vdp_dtack_n),
    .vram_req    (vram_req),
    .vram_ack    (vram_ack),
    .vram_we     (vram_we),
    .vram_a      (vram_a),
    .vram_d      (vram_d),
    .vram_q      (vram_q),
    .vram_u_n    (vram_u_n),
    .vram_l_n    (vram_l_n),
    .vram32_req  (vram32_req),
    .vram32_ack  (vram32_ack),
    .vram32_a    (vram32_a),
    .vram32_q    (vram32_q),
    .EXINT       (m68k_exint),
    .HL          (hl),
    .HINT        (m68k_hint),
    .VINT_TG68   (m68k_vint),
    .VINT_T80    (z80_vint),
    .INTACK      (m68k_intack),
    .BR_N        (vbus_br_n),
    .BG_N        (m68k_bg_n),
    .BGACK_N     (vbus_bgack_n),
    .VBUS_ADDR   (vbus_a),
    .VBUS_DATA   (vdp_mbus_d),
    .VBUS_SEL    (vbus_sel),
    .VBUS_DTACK_N(vdp_mbus_dtack_n),
    .PAL         (pal),
    .CE_PIX      (ce_pix),
    .FIELD_OUT   (field),
    .INTERLACE   (interlace),
    .RESOLUTION  (resolution),
    .HBL         (hbl),
    .VBL         (vbl),
    .R           (red),
    .G           (green),
    .B           (blue),
    .HS          (vdp_hs),
    .VS          (vdp_vs),
    .SVP_QUIRK   (1'b0),
    .VRAM_SPEED  (1'b1),
    .VSCROLL_BUG (1'b0),
    .BORDER_EN   (1'b0),
    .CRAM_DOTS   (1'b0),
    .OBJ_LIMIT_HIGH_EN (1'b0),
    .TRANSP_DETECT (),
    .BGA_EN      (1'b1),
    .BGB_EN      (1'b1),
    .SPR_EN      (1'b1)
);

/* the SN76489 sits at $C00011 */
wire signed [10:0] psg_snd;
jt89 u_psg (
    .rst    (reset),
    .clk    (mclk),
    .clk_en (psg_clken),
    .wr_n   (mbus_rnw | !vdp_sel | !mbus_a[4] | mbus_a[3]),
    .din    (mbus_do[15:8]),
    .sound  (psg_snd),
    .ready  ()
);

/* ---- controller ports: two 3-button pads ---- */
/* Registers at $A10001-$A1000D (odd bytes): version, the data of the three ports, their direction */
/* bits. A pad answers by its select line (bit 6 of the port, driven by the game): high = */
/* {C, B, Right, Left, Down, Up}, low = {Start, A, 0, 0, Down, Up}, all active low. */
reg  [7:0] io_dat1, io_dat2, io_dat3, io_ctl1, io_ctl2, io_ctl3;
reg  [7:0] io_q;
reg        io_ack_n;
/* the registers' answer */
assign io_do      = io_q;
assign io_dtack_n = io_ack_n;
assign hl         = 1'b1;

/* what a pad drives for a level of its select line; pad = {Start, C, B, A, Up, Down, Left, Right} */
function [7:0] pad_out(input [7:0] pad, input th);
    pad_out = th ? {1'b0, 1'b1, !pad[6], !pad[5], !pad[0], !pad[1], !pad[2], !pad[3]} :
                   {1'b0, 1'b0, !pad[7], !pad[4], 2'b00, !pad[2], !pad[3]};
endfunction
/* the select line: the game's level when the pin is an output, else pulled high */
wire       th1 = !io_ctl1[6] || io_dat1[6];
wire       th2 = !io_ctl2[6] || io_dat2[6];

always @(posedge mclk)
/* at reset: all pins inputs */
    if (hard_reset)
    begin
        io_dat1 <= IO_DATA_RESET;
        io_dat2 <= IO_DATA_RESET;
/* the third port */
        io_dat3 <= IO_DATA_RESET;
        io_ctl1 <= 8'd0;
        io_ctl2 <= 8'd0;
/* the third port's */
        io_ctl3 <= 8'd0;
        io_q     <= 8'hFF;
        io_ack_n <= 1'b1;
    end
/* the access ends */
    else if (!io_sel)
    begin
        io_ack_n <= 1'b1;
    end
    else if (io_ack_n)
    begin
/* answered */
        io_ack_n <= 1'b0;
        if (!mbus_rnw)
        begin
            case (mbus_a[4:1])
/* the data registers */
                IO_DATA1: io_dat1 <= mbus_do[7:0];
                IO_DATA2: io_dat2 <= mbus_do[7:0];
                IO_DATA3: io_dat3 <= mbus_do[7:0];
/* the direction registers */
                IO_CTRL1: io_ctl1 <= mbus_do[7:0];
                IO_CTRL2: io_ctl2 <= mbus_do[7:0];
                IO_CTRL3: io_ctl3 <= mbus_do[7:0];
/* other addresses have no register */
                default: ;
            endcase
        end
        else
        begin
/* output pins read their register, input pins the pad */
            case (mbus_a[4:1])
                4'd0:     io_q <= {overseas, pal, 1'b1, 5'd0};
                IO_DATA1: io_q <= (io_ctl1 & io_dat1) | (~io_ctl1 & pad_out(pad1, th1));
/* the second port */
                IO_DATA2: io_q <= (io_ctl2 & io_dat2) | (~io_ctl2 & pad_out(pad2, th2));
                IO_DATA3: io_q <= io_dat3 | ~io_ctl3;
                IO_CTRL1: io_q <= io_ctl1;
/* the second port's */
                IO_CTRL2: io_q <= io_ctl2;
                IO_CTRL3: io_q <= io_ctl3;
                default:  io_q <= 8'hFF;
            endcase
        end
    end

/* ---- Z80 ---- */
reg  [7:0]  z80_zbus_d;
reg         z80_zbus_dtack_n;
T80s #(.T2Write(1)) u_z80 (
    .RESET_n (z80_reset_n),
    .CLK     (mclk),
    .CEN     (z80_clkenn),
    .WAIT_n  (!z80_mbus_dtack_n | !z80_zbus_dtack_n | !z80_io),
    .INT_n   (!z80_vint),
    .NMI_n   (1'b1),
    .BUSRQ_n (z80_busrq_n),
    .M1_n    (),
    .MREQ_n  (z80_mreq_n),
    .IORQ_n  (),
    .RD_n    (z80_rd_n),
    .WR_n    (z80_wr_n),
    .RFSH_n  (),
    .HALT_n  (),
    .BUSAK_n (z80_busak_n),
    .OUT0    (1'b0),
    .A       (z80_a),
    .DI      (!z80_mbus_dtack_n ? z80_mbus_d : z80_zbus_d),
    .DO      (z80_do)
);

/* the 68000's control over the Z80 */
always @(posedge mclk)
    if (reset)
    begin
        z80_busrq_n <= 1'b1;
/* the Z80 is held in reset */
        z80_reset_n <= 1'b0;
    end
    else if (ctrl_sel && !mbus_rnw && !mbus_uds_n)
    begin
        if (mbus_a[11:8] == CTRL_BUSREQ)
        begin
/* bit 8 asks for the Z80's bus */
            z80_busrq_n <= !mbus_do[8];
        end
        if (mbus_a[11:8] == CTRL_RESET)
        begin
            z80_reset_n <= mbus_do[8];
        end
    end

/* ---- the Z80's bus: its 8 KB RAM, the YM2612, the bank register ---- */
reg         zbus_we;
reg  [14:0] zbus_a;
reg  [7:0]  zbus_do;
/* its state */
reg  [1:0]  zstate;
reg         zsrc_z80, z80_bgack_dis;
wire        zram_sel = !zbus_a[14];
/* the YM2612's four addresses */
wire        fm_sel   = zbus_a[14:13] == 2'b10;
wire        bank_sel = zbus_a[14:8] == Z80_BANK_PAGE;
wire [7:0]  zram_do, fm_do;
/* what the selected part answers */
wire [7:0]  zbus_di  = zram_sel ? zram_do : fm_sel ? fm_do : 8'hFF;
wire        z80_zbus_sel = z80_zbus && z80_io;
wire        z80_mbus_sel = z80_io && !z80_zbus;
/* the 68000 holds the Z80's bus */
wire        zbus_free    = !z80_busrq_n && z80_reset_n;

/* the Z80's 8 KB RAM (block RAM) */
reg  [7:0]  zram [0:(1 << ZRAM_BITS) - 1];
reg  [7:0]  zram_q;
assign zram_do = zram_q;
/* the Z80's RAM */
always @(posedge mclk)
begin
    if (zbus_we && zram_sel)
    begin
        zram[zbus_a[ZRAM_BITS-1:0]] <= zbus_do;
    end
/* its registered read */
    zram_q <= zram[zbus_a[ZRAM_BITS-1:0]];
end

always @(posedge mclk)
begin
    zbus_we <= 1'b0;
/* at reset */
    if (reset)
    begin
        mbus_zbus_dtack_n <= 1'b1;
        z80_zbus_dtack_n  <= 1'b1;
/* idle, no bus request */
        zstate        <= ZBUS_IDLE;
        z80_br_n      <= 1'b1;
        z80_bgack_n   <= 1'b1;
/* no release pending */
        z80_bgack_dis <= 1'b0;
    end
    else
    begin
        if (!zbus_sel)
        begin
            mbus_zbus_dtack_n <= 1'b1;
        end
/* the Z80's answer ends */
        if (!z80_zbus_sel)
        begin
            z80_zbus_dtack_n <= 1'b1;
        end
        case (zstate)
/* the bus is free */
            ZBUS_IDLE:
            begin
                if (z80_rd_n)
                begin
                    z80_zbus_d <= 8'hFF;
                end
/* the 68000 (or the VDP) first, then the Z80 itself */
                if (zbus_sel && mbus_zbus_dtack_n)
                begin
                    zbus_a   <= {mbus_a[14:1], mbus_uds_n};
                    zbus_do  <= !mbus_uds_n ? mbus_do[15:8] : mbus_do[7:0];
/* only while the 68000 holds the bus */
                    zbus_we  <= !mbus_rnw && zbus_free;
                    zsrc_z80 <= 1'b0;
                    zstate   <= ZBUS_READ;
                end
/* the Z80's own access */
                else if (z80_zbus_sel && z80_zbus_dtack_n)
                begin
                    zbus_a   <= z80_a[14:0];
                    zbus_do  <= z80_do;
/* its direction */
                    zbus_we  <= !z80_wr_n;
                    zsrc_z80 <= 1'b1;
                    zstate   <= ZBUS_READ;
                end
            end
/* one clock for the memory */
            ZBUS_READ: zstate <= ZBUS_FINISH;
            default:
            begin
                if (zsrc_z80)
                begin
/* the Z80's byte */
                    z80_zbus_d       <= zbus_di;
                    z80_zbus_dtack_n <= 1'b0;
                end
                else
                begin
                    mbus_zbus_d       <= zbus_free ? zbus_di : 8'hFF;
/* the 68000's acknowledge */
                    mbus_zbus_dtack_n <= 1'b0;
                end
                zstate <= ZBUS_IDLE;
            end
        endcase

/* the Z80 takes the 68000's bus for an access through its bank window */
        if (z80_mbus_sel && z80_br_n && z80_bgack_n && vbus_br_n && vbus_bgack_n && m68k_clkenp)
        begin
            z80_br_n <= 1'b0;
        end
        else if (!z80_br_n && !m68k_bg_n && m68k_as_n && m68k_clkenn)
        begin
/* the bus is the Z80's */
            z80_bgack_n <= 1'b0;
        end
        else if (!z80_bgack_n && !z80_br_n && !m68k_bg_n && m68k_clkenp)
        begin
            z80_br_n <= 1'b1;
        end
/* its access is over */
        else if (!z80_bgack_dis && !z80_bgack_n && z80_br_n && !z80_mbus_sel && m68k_clkenn)
        begin
            z80_bgack_dis <= 1'b1;
        end
        else if (!z80_bgack_n && z80_bgack_dis && m68k_clkenn)
        begin
/* the bus goes back */
            z80_bgack_n   <= 1'b1;
            z80_bgack_dis <= 1'b0;
        end
    end
end

/* the bank register: nine writes shift in address bits 15 to 23 */
always @(posedge mclk)
    if (reset)
    begin
        bar <= 9'd0;
    end
/* a write to the bank register */
    else if (bank_sel && zbus_we)
    begin
        bar <= {zbus_do[0], bar[23:16]};
    end

/* ---- sound ---- */
wire signed [15:0] fm_left, fm_right;
jt12 u_fm (
    .rst         (!z80_reset_n),
    .clk         (mclk),
    .cen         (fm_clken),
    .din         (zbus_do),
    .addr        (zbus_a[1:0]),
    .cs_n        (1'b0),
    .wr_n        (!(fm_sel & zbus_we)),
    .dout        (fm_do),
    .irq_n       (),
    .en_hifi_pcm (1'b1),
    .ladder      (1'b1),
    .snd_right   (fm_right),
    .snd_left    (fm_left),
    .snd_sample  ()
);

/* mono: both FM channels and the PSG, limited to 16 bits */
wire signed [16:0] fm_sum  = fm_left + fm_right;
wire signed [20:0] mix     = fm_sum * FM_GAIN + (psg_snd <<< PSG_SHIFT);
always @(posedge mclk)
/* limited to 16 bits */
    audio <= mix > MIX_MAX ? MIX_MAX[15:0] : mix < MIX_MIN ? MIX_MIN[15:0] : mix[15:0];

endmodule

`default_nettype wire
