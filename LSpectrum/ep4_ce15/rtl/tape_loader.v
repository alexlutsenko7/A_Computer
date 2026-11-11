/* tape_loader -- the loader hardware the ESP32 system controller drives: TAP/TZX */
/* pulse player, MIC recorder, snapshot port, OSD port, keys, Bluetooth UART */
/* */
/* Clock: 56 MHz (sys_pll c2), synchronous to the 112 MHz system clock (same */
/* PLL, edges aligned), so the crossings below are ordinary timed paths: */
/* keys, cen_tgl            112 -> 56: levels / a toggle, each value held >= 2 clocks here */
/* tape_on/lvl/turbo, osd_* 56 -> 112 / pixel clock: levels, synchronised by the receiver */
/* snap_*                   request toggle + data held until the acknowledge toggles back */
/* */
/* Register bus: driven by the ESP32 over the SPI link (rtl/esp_link.v, frames WR/RD/OSD/ */
/* FIFO/MWR/MRD/STAT); the ESP32 firmware's names are in ESP32/v2/src/hw.h. */
/* 0x1000_0000  registers: */
/* 00 ID        R: core ID (CORE_ID: 5A58_0001 = "ZX", 4336_0002 = "C6"; link version 1, L64 2) */
/* 04 IRQ       R: [3:0] interrupt causes, [11:8] mask   W: [11:8] mask (see the link section) */
/* 08 KEYS      R: loader keys */
/* 0C FIFO      W: push command  R: [9:0] used entries, [16] player idle */
/* 10 TAPE      W: [0] EAR from player, [1] turbo, [2] flush   R: [1:0] */
/* 14 OSD       W: [0] on, [1] full screen                    R: same */
/* 18 TIMER     R: 56 MHz counter */
/* 1C MARKER    R: last CMD_MARK argument executed by the player */
/* 20 REC       R: recorder event: [31] pending, [30] gap (no MIC edge for GAP_T), */
/* [29] edges lost, [23:0] T-states since the previous edge; reading clears it */
/* 24 RECCTL    W: [0] armed (hold the Spectrum while an event is unread), [1] hold the Spectrum */
/* R: T-states since the last MIC edge (saturating) */
/* 28 KEYRAW    R: last keyboard report {modifiers, key 1, key 2, key 3} */
/* 2C SNAPCTL   W: [0] freeze the Spectrum CPU (snapshots)   R: [0] frozen, [1] command busy */
/* 30 SNAPCMD   W: start a snapshot command: [31:28] command, [17:0] address (zx_bus.v) */
/* 34 SNAPDAT   W: command data   R: result of the last command */
/* 38 INTPOS    W/R: 50 Hz frame interrupt position in zx_video: [9:0] VGA line, [25:16] pixel (reset INT_POS); */
/* [29:28] joystick mode (zx_system; reset: 0 = both Kempston), [31] memory contention off (zx_bus; reset: on) */
/* 3C UART      to the ESP32's Bluetooth part, 8N1 at BAUD: W: [8] send [7:0] (ignored while busy), [9] drop the */
/* oldest received byte, [10] clear the overrun flag */
/* R: [7:0] oldest received byte, [8] valid, [9] sending, [10] overrun (512-byte FIFO was full) */
/* 40 FLASH     configuration flash pass-through (ROM install by the ESP32; machines with flash_* wired): */
/* W: [10] enable (the flash pins belong to this port), [9] chip select active, */
/* [8] start: send [7:0] and receive one byte (SPI mode 0, MSB first, clk / 8) */
/* R: [7:0] last byte received, [8] busy, [9] chip select, [10] enabled */
/* 44 RELOAD    W: [0] = 1 pulses reload (the machine reloads its ROMs from flash and restarts) */
/* 48 MCTL      machine-specific: W: mctl (kept)   R: mstat   (L64: the 1541 drive) */
/* 4C MCLR      machine-specific: W: mclr = data for one clock (mclr_we) */
/* 0x2000_0000  OSD text (32 x 24 bytes, write only, byte stores) */
/* */
/* Recorder (saving): MIC (port FE bit 3) edges, timed in T-states like the */
/* player. While armed, an unread event holds the Spectrum CPU (hold), so no */
/* edge is lost however long the ESP32 takes (SD writes, the save dialog); */
/* holding stops the T-states too, so the recorded timing is unaffected. */
/* Each access takes 2 clocks (register read). */
/* */
/* Pulse player: commands from a 512 x 32 FIFO (ESP32/v2/src/hal.h): */
/* 00: PULSE n     hold the level for n T-states, then toggle */
/* 01: LEVEL l, n  set the level to l, hold n T-states */
/* 10: DATA b, k   k+1 bits of b, MSB first; each bit = 2 pulses of len0 / len1 */
/* (bit 11 set: SAMPLES, each bit sets the level for len0 T-states: TZX 0x15) */
/* 11: [29:28] = 0 len0 <= n, 1 len1 <= n, 2 marker <= n (no time) */
/* T-states are counted on the CPU clock enable (cen_tgl), so the signal is */
/* exact at 3.5 MHz and in turbo, and SDRAM stalls stretch it with the CPU. */
/* Commands follow each other without gaps; zero-time commands never show on */
/* the line (see the player section). */
`default_nettype none

module tape_loader #(
/* 56 MHz / 115200 (0.02 % fast) */
    parameter integer BAUD_DIV  = 486,
/* INTPOS after reset: {pixel, line} (zx_video; measured, see there) */
    parameter [19:0]  INT_POS   = {10'd166, 10'd24},
/* T-states without a MIC edge = end of a block */
    parameter integer GAP_T     = 8000,
/* register 0x00: "ZX" link version 1 (L64: "C6") */
    parameter [31:0]  CORE_ID   = 32'h5A58_0001,
/* flash pass-through: clocks per DCLK half period (2-4) */
    parameter integer FL_HALF   = 4,
/* esp_link flash stream frames (the menu: with FL_HALF 2) */
    parameter         FLS       = 0
)(
/* 56 MHz */
    input  wire        clk,
/* synchronous to clk */
    input  wire        rst_n,

/* loader keys (system clock domain) */
    input  wire [17:0] keys,
/* last keyboard report (system clock domain) */
    input  wire [31:0] keyraw,
/* toggles on every CPU T-state (system clock domain) */
    input  wire        cen_tgl,
/* port FE bit 3 (system clock domain) */
    input  wire        mic,
/* pause the Spectrum CPU */
    output wire        hold,

/* EAR from the player */
    output reg         tape_on,
    output reg         tape_turbo,
    output reg         tape_lvl,

    output reg         osd_on,
    output reg         osd_full,
    output reg         osd_we,
    output reg  [9:0]  osd_addr,
    output reg  [7:0]  osd_data,
/* UART to the ESP32 Bluetooth bridge (idle high) */
    output reg         bt_tx,
/* UART from the ESP32 (asynchronous pin) */
    input  wire        bt_rx,
/* SPI link from the ESP32 system controller (rtl/esp_link.v) */
    input  wire        esp_sck,
    input  wire        esp_mosi,
    input  wire        esp_cs_n,
    output wire        esp_miso,
    output reg         esp_irq,
/* frame interrupt {pixel, line} for zx_video (static, pixel clock synchronises) */
    output reg  [19:0] int_pos,
/* memory contention on (zx_bus synchronises) */
    output reg         cont_on,
/* joystick mode (zx_system synchronises) */
    output reg  [1:0]  joy_mode,

/* configuration flash pass-through (register 0x40) and ROM reload (0x44) */
    output reg         fl_en,
    output reg         fl_ncs,
    output reg         fl_dclk,
    output reg         fl_mosi,
    input  wire        fl_miso,
    output reg         reload,
    output reg  [31:0] mctl,
    input  wire [31:0] mstat,
    output reg  [31:0] mclr,
    output reg         mclr_we,

/* snapshot port to zx_bus (system clock domain) */
    output reg         snap_freeze,
    output reg         snap_req,
    output reg  [3:0]  snap_cmd,
    output reg  [17:0] snap_addr,
    output reg  [31:0] snap_wdata,
    input  wire        snap_frozen,
    input  wire        snap_ack,
    input  wire [31:0] snap_rdata
);

/* address bits 31:28 of the OSD text (0x2000_0000) */
localparam [3:0] AREA_OSD = 4'h2;
/* register 0x0C: a command for the pulse player's FIFO */
localparam [3:0] REG_FIFO = 4'd3;
/* entries of the command FIFO and of the UART receive FIFO */
localparam [9:0] FIFO_SIZE = 10'd512;
/* player command 10: DATA */
localparam [1:0] CMD_DATA = 2'd2;
/* T-states of a pulse of a 0 bit (standard ROM loader) */
localparam [15:0] T_ZERO = 16'd855;
/* T-states of a pulse of a 1 bit */
localparam [15:0] T_ONE = 16'd1710;
/* register 0x20: the recorder's event */
localparam [3:0] REG_REC = 4'd8;
/* register 0x24: recorder control */
localparam [3:0] REG_RECCTL = 4'd9;
/* longest time between two MIC edges that fits an event (24 bits) */
localparam [31:0] REC_MAX = 32'h00FFFFFF;
/* transmitter: 10 bits and one more bit time before it is free again */
localparam [3:0] TX_SLOTS = 4'd11;
/* receiver: start bit, 8 data bits, stop bit */
localparam [3:0] RX_SLOTS = 4'd10;
/* receiver: the slots from here up carry data bits */
localparam [3:0] RX_DATA_END = 4'd2;
/* the FIFO's refill mark: half full */
localparam [9:0] FIFO_HALF = 10'd256;
/* register 0x40: flash pass-through */
localparam [4:0] REG_FLASH = 5'd16;
/* register 0x44: reload the ROMs */
localparam [4:0] REG_RELOAD = 5'd17;
/* register 0x4C: machine-specific strobe data */
localparam [4:0] REG_MCLR = 5'd19;
/* register 0x48: machine-specific control */
localparam [4:0] REG_MCTL = 5'd18;
/* bits of a flash byte */
localparam [3:0] FL_BYTE_BITS = 4'd8;
/* register 0x10: tape control */
localparam [3:0] REG_TAPE = 4'd4;
/* register 0x14: OSD control */
localparam [3:0] REG_OSDC = 4'd5;
/* register 0x2C: snapshot freeze */
localparam [3:0] REG_SNAPCTL = 4'd11;
/* register 0x30: snapshot command and address */
localparam [3:0] REG_SNAPCMD = 4'd12;
/* register 0x34: snapshot data */
localparam [3:0] REG_SNAPDAT = 4'd13;
/* register 0x38: interrupt position, contention, joystick mode */
localparam [3:0] REG_INTPOS = 4'd14;
/* the third byte lane of a word */
localparam [1:0] LANE_2 = 2'd2;

/* Register bus, driven by the ESP32 through the SPI link */
wire        mem_valid;
wire [31:0] mem_addr, mem_wdata;
wire [3:0]  mem_wstrb;
/* ready and read data; the link */
reg         mem_ready;
wire [31:0] mem_rdata;

esp_link #(.FLS(FLS)) u_link (
    .clk       (clk),
    .rst_n     (rst_n),
    .sck       (esp_sck),
    .mosi      (esp_mosi),
    .cs_n      (esp_cs_n),
    .miso      (esp_miso),
    .mem_valid (mem_valid),
    .mem_addr  (mem_addr),
    .mem_wdata (mem_wdata),
    .mem_wstrb (mem_wstrb),
    .mem_ready (mem_ready),
    .mem_rdata (mem_rdata)
);

/* an access in progress; the register block or the OSD */
wire       access  = mem_valid && !mem_ready;
wire       sel_io  = mem_addr[31:28] == 4'h1;
wire       sel_osd = mem_addr[31:28] == AREA_OSD;
/* a write */
wire       wr      = access && (mem_wstrb != 4'd0);
/* 32 registers (18 used) */
wire [4:0] reg_a   = mem_addr[6:2];

/* Inputs from the system clock domain */
reg [17:0] keys_s1, keys_s;
reg [1:0]  sfrz_s, sack_s;
reg [31:0] raw_s1, raw_s;
/* the T-state toggle */
reg [2:0] cen_s;
always @(posedge clk)
begin
    keys_s1 <= keys;
/* keys and the raw report, two stages */
    keys_s  <= keys_s1;
    raw_s1  <= keyraw;
    raw_s   <= raw_s1;
/* T-state toggle, snapshot handshake */
    cen_s   <= {cen_s[1:0], cen_tgl};
    sfrz_s  <= {sfrz_s[0], snap_frozen};
    sack_s  <= {sack_s[0], snap_ack};
end
/* one CPU T-state */
wire tick = cen_s[2] ^ cen_s[1];

/* Command FIFO (512 x 32, block RAM) with a one-command look-ahead (nxt) */
reg  [31:0] fifo [0:511];
reg  [31:0] fq;
reg  [8:0]  wp, rp;
/* entries used; a read under way; the look-ahead */
reg  [9:0]  used;
reg         loading, nxt_valid, flush;
reg  [31:0] nxt;
/* the player takes nxt this clock */
wire        consume;
wire        push  = wr && sel_io && reg_a == REG_FIFO && used != FIFO_SIZE;
wire        fetch = !loading && (!nxt_valid || consume) && used != 10'd0;

/* the FIFO's memory */
always @(posedge clk)
begin
    if (push)
    begin
        fifo[wp] <= mem_wdata;
    end
/* registered read */
    fq <= fifo[rp];
end

/* the FIFO's pointers and the look-ahead */
always @(posedge clk or negedge rst_n)
    if (!rst_n)
    begin
        wp        <= 9'd0;
/* empty */
        rp        <= 9'd0;
        used      <= 10'd0;
        loading   <= 1'b0;
/* no look-ahead */
        nxt_valid <= 1'b0;
        nxt       <= 32'd0;
    end
    else if (flush)
    begin
/* flush: empty */
        wp        <= 9'd0;
        rp        <= 9'd0;
        used      <= 10'd0;
/* no read, no look-ahead */
        loading   <= 1'b0;
        nxt_valid <= 1'b0;
    end
    else
    begin
        if (push)
        begin
/* write pointer, read pointer */
            wp <= wp + 9'd1;
        end
        if (fetch)
        begin
            rp <= rp + 9'd1;
        end
/* entries used */
        used <= used + (push ? 10'd1 : 10'd0) - (fetch ? 10'd1 : 10'd0);
        loading <= fetch;
        if (loading)
        begin
/* the entry read becomes the look-ahead */
            nxt       <= fq;
            nxt_valid <= 1'b1;
        end
        else if (consume)
        begin
/* taken by the player */
            nxt_valid <= 1'b0;
        end
    end

/* Pulse player */
/* */
/* Timed commands (PULSE, LEVEL with n > 0, DATA, SAMPLES) run one at a time; */
/* the next one starts in the clock where the running one ends, so the line has */
/* no gaps. Zero-time commands (LEVEL with n = 0, LEN0/LEN1, MARK) are taken */
/* from nxt while a command runs and take effect exactly when it ends (level, */
/* marker) or when the next DATA/SAMPLES starts (lengths, latched per command). */
/* If the next command is not there yet when one ends (the CPU is late), the */
/* ticks of the gap are credited to it (pend, up to 255), so the next edge is */
/* still on time. After the player went idle (stop, end, flush) nothing is */
/* credited: the first command then starts counting from its own start. */
/* */
/* DATA b, k   (nxt[11] = 0): k+1 bits of b MSB first, each bit 2 pulses of len0 / len1 */
/* SAMPLES b, k (nxt[11] = 1): k+1 bits of b MSB first, each sets the level for len0 */
localparam [1:0] K_PULSE = 2'd0, K_WAIT = 2'd1, K_DATA = 2'd2, K_SAMP = 2'd3;

/* a timed command is running */
reg         act_q;
reg  [1:0]  kind;
reg  [23:0] cnt;
/* the byte of a DATA / SAMPLES command, its bit, its half */
reg  [7:0]  dbyte;
reg  [2:0]  dbit;
reg         dhalf;
/* set by LEN0 / LEN1 */
reg  [15:0] len0, len1;
/* latched by the running DATA / SAMPLES */
reg  [15:0] dl0, dl1;
reg  [15:0] marker, p_mark;
reg         p_mark_set, p_lvl_set, p_lvl;
/* ticks of a gap, not yet credited */
reg  [7:0]  pend;
/* a command ended and the stream goes on */
reg         credit_en;

wire        chain     = used != 10'd0 || loading || nxt_valid;
wire        idle      = !act_q && !chain;
/* the next command takes time */
wire        n_timed   = nxt[31:30] == 2'd0 || nxt[31:30] == CMD_DATA || (nxt[31:30] == 2'd1 && nxt[23:0] != 24'd0);
wire        due       = act_q && (cnt == 24'd0 || (tick && cnt == 24'd1));
wire        last      = kind == K_DATA ? (dhalf && dbit == 3'd0) : kind == K_SAMP ? dbit == 3'd0 : 1'b1;
/* the running one ends; a zero-time command is taken at once; a timed one starts */
wire        ends      = due && last;
wire        absorb    = nxt_valid && !n_timed && !ends;
wire        start     = nxt_valid && n_timed && (!act_q || ends);
/* the level after the running command */
assign      consume   = absorb || start;

wire        lvl_end   = (kind == K_PULSE || kind == K_DATA) ? !tape_lvl : tape_lvl;
wire        lvl_after = p_lvl_set ? p_lvl : lvl_end;
/* level a new PULSE / DATA starts with */
wire        base      = act_q ? lvl_after : tape_lvl;
wire [8:0]  credit    = (act_q || !credit_en) ? 9'd0 : {1'b0, pend} + {8'd0, tick};
wire        is_samp   = nxt[11];
/* the next command's length, less the gap credit */
wire [23:0] n_raw     = nxt[31:30] == CMD_DATA ? {8'd0, (is_samp ? len0 : (nxt[7] ? len1 : len0))} : nxt[23:0];
wire [23:0] n_eff     = n_raw > {15'd0, credit} ? n_raw - {15'd0, credit} : 24'd0;

/* the pulse player */
always @(posedge clk or negedge rst_n)
    if (!rst_n)
    begin
        act_q      <= 1'b0;
/* reset */
        kind       <= K_PULSE;
        cnt        <= 24'd0;
        dbyte      <= 8'd0;
/* bit, half; the standard bit lengths */
        dbit       <= 3'd0;
        dhalf      <= 1'b0;
        len0       <= T_ZERO;
/* a 1 bit; the lengths of the running command */
        len1       <= T_ONE;
        dl0        <= T_ZERO;
        dl1        <= T_ONE;
/* markers */
        marker     <= 16'd0;
        p_mark     <= 16'd0;
        p_mark_set <= 1'b0;
/* no pending level, no credit */
        p_lvl_set  <= 1'b0;
        p_lvl      <= 1'b0;
        pend       <= 8'd0;
/* the line low */
        credit_en  <= 1'b0;
        tape_lvl   <= 1'b0;
    end
    else if (flush)
    begin
/* flush: stop */
        act_q      <= 1'b0;
        pend       <= 8'd0;
        credit_en  <= 1'b0;
/* markers and pending level */
        marker     <= 16'd0;
        p_mark_set <= 1'b0;
        p_lvl_set  <= 1'b0;
/* the line low */
        tape_lvl   <= 1'b0;
    end
    else
    begin
/* zero-time commands */
        if (absorb)
        begin
            if (nxt[31:30] == 2'd1)
            begin
                if (act_q)
                begin
/* a level set during a command takes effect at its end */
                    p_lvl_set <= 1'b1;
                    p_lvl <= nxt[24];
                end
                else
                begin
                    tape_lvl <= nxt[24];
                end
            end
            else
            begin
/* bit lengths and the marker */
                case (nxt[29:28])
                    2'd0: len0 <= nxt[15:0];
                    2'd1: len1 <= nxt[15:0];
/* the marker, at the running command's end */
                    2'd2:
                        if (act_q)
                        begin
                            p_mark_set <= 1'b1;
/* or at once */
                            p_mark <= nxt[15:0];
                        end
                        else
                        begin
                            marker <= nxt[15:0];
                        end
                    default: ;
                endcase
            end
        end

/* gap credit */
        if (act_q || !chain || start)
        begin
            pend <= 8'd0;
        end
        else if (credit_en && tick && pend != 8'd255)
        begin
/* T-states that passed between two commands */
            pend <= pend + 8'd1;
        end
        if (!chain && !act_q)
        begin
            credit_en <= 1'b0;
        end

/* running command */
        if (due)
        begin
            if (last)
            begin
                if (p_mark_set)
                begin
/* pending marker and level */
                    marker <= p_mark;
                end
                p_mark_set <= 1'b0;
                p_lvl_set  <= 1'b0;
/* ended */
                act_q      <= 1'b0;
                credit_en  <= 1'b1;
                tape_lvl   <= lvl_after;
/* 2 pulses per bit */
            end
            else if (kind == K_DATA)
            begin
                tape_lvl <= !tape_lvl;
                if (!dhalf)
                begin
/* first half done */
                    dhalf <= 1'b1;
                    cnt   <= dbyte[7] ? {8'd0, dl1} : {8'd0, dl0};
                end
                else
                begin
/* second half: the next bit */
                    dhalf <= 1'b0;
                    dbit  <= dbit - 3'd1;
                    dbyte <= {dbyte[6:0], 1'b0};
/* its first pulse */
                    cnt   <= dbyte[6] ? {8'd0, dl1} : {8'd0, dl0};
                end
/* SAMPLES: next sample */
            end
            else
            begin
                dbit     <= dbit - 3'd1;
                dbyte    <= {dbyte[6:0], 1'b0};
                tape_lvl <= dbyte[6];
/* the sample's length; else the command's time counts down */
                cnt      <= {8'd0, dl0};
            end
        end
        else if (act_q && tick)
        begin
            cnt <= cnt - 24'd1;
        end

/* next timed command (in the clock the running one ends, or when idle) */
        if (start)
        begin
            act_q <= 1'b1;
            cnt   <= n_eff;
/* its byte and bit count */
            dbyte <= nxt[7:0];
            dbit  <= nxt[10:8];
            dhalf <= 1'b0;
/* the bit lengths in force */
            dl0   <= len0;
            dl1   <= len1;
            case (nxt[31:30])
/* PULSE: hold, then toggle */
                2'd0:
                begin
                    kind <= K_PULSE;
                    tape_lvl <= base;
                end
/* LEVEL */
                2'd1:
                begin
                    kind <= K_WAIT;
                    tape_lvl <= nxt[24];
                end
/* DATA or SAMPLES */
                default:
                begin
                    kind     <= is_samp ? K_SAMP : K_DATA;
                    tape_lvl <= is_samp ? nxt[7] : base;
                end
            endcase
        end
    end

/* Recorder: MIC edges in T-states, one event at a time, Spectrum held while unread */
reg  [1:0]  mic_s;
reg         mic_p, rec_pend, rec_gap, rec_ovf, gap_sent, rec_armed, rec_hold;
reg  [23:0] rec_delta;
/* T-states since the last edge; the event is read; an edge */
reg  [31:0] rec_since;
wire        rd_rec   = access && !wr && sel_io && reg_a == REG_REC;
wire        mic_edge = mic_s[1] != mic_p;

/* the Spectrum is held while an event waits */
assign hold = (rec_armed && rec_pend) || rec_hold;

/* the recorder */
always @(posedge clk or negedge rst_n)
    if (!rst_n)
    begin
        mic_s     <= 2'b00;
/* reset */
        mic_p     <= 1'b0;
        rec_pend  <= 1'b0;
        rec_gap   <= 1'b0;
/* no overflow; no gap to report */
        rec_ovf   <= 1'b0;
        gap_sent  <= 1'b1;
        rec_delta <= 24'd0;
/* not armed */
        rec_since <= 32'd0;
        rec_armed <= 1'b0;
        rec_hold  <= 1'b0;
    end
    else
    begin
/* the MIC line, synchronised; RECCTL */
        mic_s <= {mic_s[0], mic};
        mic_p <= mic_s[1];
        if (wr && sel_io && reg_a == REG_RECCTL)
        begin
/* armed, hold */
            rec_armed <= mem_wdata[0];
            rec_hold  <= mem_wdata[1];
        end
        if (rd_rec)
        begin
/* read: the event is taken */
            rec_pend <= 1'b0;
            rec_ovf  <= 1'b0;
        end
        if (mic_edge)
        begin
/* an edge */
            if (rec_pend && !rd_rec)
            begin
/* previous edge not read yet (not armed) */
                rec_ovf <= 1'b1;
            end
            else
            begin
                rec_pend  <= 1'b1;
                rec_gap   <= 1'b0;
/* the time since the last edge, saturated */
                rec_delta <= rec_since > REC_MAX ? 24'hFFFFFF : rec_since[23:0];
            end
            rec_since <= 32'd0;
            gap_sent  <= 1'b0;
        end
        else
        begin
/* no edge: the time counts */
            if (tick && rec_since != 32'hFFFFFFFF)
            begin
                rec_since <= rec_since + 32'd1;
            end
            if (rec_since >= GAP_T && !gap_sent && (!rec_pend || rd_rec))
            begin
/* a gap event, once */
                rec_pend  <= 1'b1;
                rec_gap   <= 1'b1;
/* its length */
                rec_delta <= GAP_T[23:0];
                gap_sent  <= 1'b1;
            end
        end
    end

/* UART to the ESP32 Bluetooth part (ESP32/v2/v2.ino): 8N1, 512-byte receive FIFO (one M9K, ~45 ms of */
/* continuous data: the firmware may be busy for a few ms, e.g. redrawing the OSD) */
wire       uart_wr = wr && sel_io && reg_a == 4'd15;
/* {stop, data, start}, LSB first */
reg  [9:0] tx_sh;
/* bit times left (start, 8 data, stop, end of stop) */
reg  [3:0] tx_n;
reg  [9:0] tx_cnt;
wire       tx_busy = tx_n != 4'd0;

/* the transmitter */
always @(posedge clk or negedge rst_n)
    if (!rst_n)
    begin
        tx_sh  <= 10'h3FF;
/* idle */
        tx_n   <= 4'd0;
        tx_cnt <= 10'd0;
        bt_tx  <= 1'b1;
    end
/* idle: the line high */
    else if (!tx_busy)
    begin
        bt_tx <= 1'b1;
        if (uart_wr && mem_wdata[8])
        begin
/* start bit, 8 data bits, stop bit */
            tx_sh  <= {1'b1, mem_wdata[7:0], 1'b0};
/* busy until the stop bit has lasted a whole bit */
            tx_n   <= TX_SLOTS;
            tx_cnt <= 10'd0;
        end
    end
    else if (tx_cnt != 10'd0)
    begin
/* inside a bit */
        tx_cnt <= tx_cnt - 10'd1;
    end
    else
    begin
/* the next bit */
        bt_tx  <= tx_sh[0];
        tx_sh  <= {1'b1, tx_sh[9:1]};
        tx_n   <= tx_n - 4'd1;
/* a bit time */
        tx_cnt <= BAUD_DIV[9:0] - 10'd1;
    end

reg  [2:0] rx_s;
reg  [9:0] rx_cnt;
/* 0 = idle, else bits still to sample (start, 8 data, stop) */
reg  [3:0] rx_n;
reg  [7:0] rx_sh;
reg  [7:0] rx_fifo [0:511];
/* rx_fifo[rx_rp], 1 clock behind rx_rp */
reg  [7:0] rx_q;
reg  [8:0] rx_wp, rx_rp;
reg  [9:0] rx_used;
/* rx_used != 0 for 2 clocks: rx_q is valid */
reg  [1:0] rx_seen;
reg        rx_ovr;
wire       rx_valid = rx_used != 10'd0 && rx_seen[1];
/* the ESP32 takes a byte; a byte to store */
wire       rx_pop   = uart_wr && mem_wdata[9] && rx_valid;
reg        rx_push;

always @(posedge clk)
begin
/* the receive line; the FIFO's memory */
    rx_s <= {rx_s[1:0], bt_rx};
    if (rx_push)
    begin
        rx_fifo[rx_wp] <= rx_sh;
    end
/* registered read */
    rx_q <= rx_fifo[rx_rp];
end

/* the receiver */
always @(posedge clk or negedge rst_n)
    if (!rst_n)
    begin
        rx_cnt  <= 10'd0;
/* reset */
        rx_n    <= 4'd0;
        rx_sh   <= 8'd0;
        rx_wp   <= 9'd0;
/* empty */
        rx_rp   <= 9'd0;
        rx_used <= 10'd0;
        rx_seen <= 2'd0;
/* no overrun */
        rx_ovr  <= 1'b0;
        rx_push <= 1'b0;
    end
    else
    begin
        rx_push <= 1'b0;
/* idle */
        if (rx_n == 4'd0)
        begin
/* start bit: sample in the middle of each bit */
            if (!rx_s[2])
            begin
                rx_n   <= RX_SLOTS;
                rx_cnt <= BAUD_DIV[10:1];
            end
        end
/* inside a bit */
        else if (rx_cnt != 10'd0)
        begin
            rx_cnt <= rx_cnt - 10'd1;
        end
        else
        begin
/* a bit time later */
            rx_cnt <= BAUD_DIV[9:0] - 10'd1;
            rx_n   <= rx_n - 4'd1;
            if (rx_n == RX_SLOTS && rx_s[2])
            begin
/* glitch, not a start bit */
                rx_n <= 4'd0;
            end
            else if (rx_n >= RX_DATA_END)
            begin
                rx_sh <= {rx_s[2], rx_sh[7:1]};
            end
/* stop bit: keep the byte */
            else if (rx_s[2])
            begin
                if (rx_used == FIFO_SIZE)
                begin
                    rx_ovr <= 1'b1;
                end
                else
                begin
/* into the FIFO */
                    rx_push <= 1'b1;
                end
            end
        end
        if (rx_push)
        begin
            rx_wp <= rx_wp + 9'd1;
        end
/* taken by the ESP32; bytes held */
        if (rx_pop)
        begin
            rx_rp <= rx_rp + 9'd1;
        end
        rx_used <= rx_used + (rx_push ? 10'd1 : 10'd0) - (rx_pop ? 10'd1 : 10'd0);
/* after a pop rx_q follows 2 clocks later */
        rx_seen <= rx_pop ? 2'd0 : {rx_seen[0], rx_used != 10'd0};
        if (uart_wr && mem_wdata[10])
        begin
            rx_ovr <= 1'b0;
        end
    end

/* ESP32 link: core ID (register 0x00) and interrupt (register 0x04) */
/* R 0x00: CORE_ID */
/* R 0x04: [3:0] causes, [11:8] mask; reading clears cause 1 */
/* W 0x04: [11:8] mask */
/* Causes: [0] player FIFO at most half full, [1] key state changed (latched), */
/* [2] recorder event pending, [3] snapshot command port idle */
/* esp_irq = any cause whose mask bit is set (level, active high) */
reg  [3:0]  irq_mask;
reg         key_chg;
reg  [17:0] keys_p;
/* causes: snapshot answer, recorder event, key change, FIFO half empty */
reg  [31:0] raw_p;
wire [3:0]  irq_cause = {snap_req == sack_s[1], rec_pend, key_chg, used <= FIFO_HALF};
always @(posedge clk or negedge rst_n)
/* reset */
    if (!rst_n)
    begin
        irq_mask <= 4'd0;
        key_chg  <= 1'b0;
/* no history */
        keys_p   <= 18'd0;
        raw_p    <= 32'd0;
        esp_irq  <= 1'b0;
    end
    else
    begin
/* the keys one clock ago; the mask */
        keys_p  <= keys_s;
        raw_p   <= raw_s;
        if (wr && sel_io && reg_a == 4'd1)
        begin
/* a key changed */
            irq_mask <= mem_wdata[11:8];
        end
        if (keys_p != keys_s || raw_p != raw_s)
        begin
            key_chg <= 1'b1;
        end
/* cleared by reading; the pin */
        else if (access && !wr && sel_io && reg_a == 4'd1)
        begin
            key_chg <= 1'b0;
        end
        esp_irq <= |(irq_cause & irq_mask);
    end

/* Flash pass-through: one byte per start, DCLK = clk / (2 * FL_HALF) (MISO sampled at the end */
/* of the high phase, MOSI changes in the low phase, as rom_loader); reload pulse */
wire       fl_wr = wr && sel_io && reg_a == REG_FLASH;
reg  [7:0] fl_sh, fl_q;
reg  [3:0] fl_bits;
/* half-period divider; a byte is shifting */
reg  [1:0] fl_div;
wire       fl_busy = fl_bits != 4'd0;

always @(posedge clk or negedge rst_n)
/* reset */
    if (!rst_n)
    begin
        fl_en   <= 1'b0;
        fl_ncs  <= 1'b1;
/* pins idle */
        fl_dclk <= 1'b0;
        fl_mosi <= 1'b0;
        fl_sh   <= 8'd0;
/* no byte */
        fl_q    <= 8'd0;
        fl_bits <= 4'd0;
        fl_div  <= 2'd0;
/* machine control */
        reload  <= 1'b0;
        mctl    <= 32'd0;
        mclr    <= 32'd0;
/* strobes: reload, clear dirty bits */
        mclr_we <= 1'b0;
    end
    else
    begin
        reload  <= wr && sel_io && reg_a == REG_RELOAD && mem_wdata[0];
        mclr_we <= wr && sel_io && reg_a == REG_MCLR;
/* machine control */
        if (wr && sel_io && reg_a == REG_MCTL)
        begin
            mctl <= mem_wdata;
        end
        if (wr && sel_io && reg_a == REG_MCLR)
        begin
/* the bits to clear; the flash register */
            mclr <= mem_wdata;
        end
        if (fl_wr && !fl_busy)
        begin
            fl_en  <= mem_wdata[10];
/* chip select; start a byte */
            fl_ncs <= !mem_wdata[9];
            if (mem_wdata[8])
            begin
                fl_sh   <= mem_wdata[7:0];
/* first bit out */
                fl_mosi <= mem_wdata[7];
                fl_bits <= FL_BYTE_BITS;
                fl_div  <= 2'd0;
            end
        end
/* a byte shifts */
        else if (fl_busy)
        begin
            fl_div <= fl_div == FL_HALF - 1 ? 2'd0 : fl_div + 2'd1;
            if (fl_div == FL_HALF - 1)
            begin
/* rising edge; falling edge: sample and shift */
                if (!fl_dclk)
                begin
                    fl_dclk <= 1'b1;
                end
                else
                begin
                    fl_dclk <= 1'b0;
/* the flash's bit in, ours out */
                    fl_q    <= {fl_q[6:0], fl_miso};
                    fl_sh   <= {fl_sh[6:0], 1'b0};
                    fl_mosi <= fl_sh[6];
/* one bit less */
                    fl_bits <= fl_bits - 4'd1;
                end
            end
        end
    end

/* Control registers, OSD port, timer, read data */
reg  [31:0] timer, io_q;

assign mem_rdata = io_q;

always @(posedge clk or negedge rst_n)
/* reset */
    if (!rst_n)
    begin
        mem_ready  <= 1'b0;
        io_q       <= 32'd0;
/* tape off */
        timer      <= 32'd0;
        tape_on    <= 1'b0;
        tape_turbo <= 1'b0;
/* no flush, OSD off */
        flush      <= 1'b0;
        osd_on     <= 1'b0;
        osd_full   <= 1'b0;
/* no OSD write */
        osd_we     <= 1'b0;
        osd_addr   <= 10'd0;
        osd_data   <= 8'd0;
/* not frozen; the default interrupt position; contention on */
        snap_freeze <= 1'b0;
        int_pos    <= INT_POS;
        cont_on    <= 1'b1;
/* Kempston; no snapshot command */
        joy_mode   <= 2'd0;
        snap_req   <= 1'b0;
/* no command, address or data */
        snap_cmd   <= 4'd0;
        snap_addr  <= 18'd0;
        snap_wdata <= 32'd0;
    end
    else
    begin
/* an access takes one clock; the timer runs */
        mem_ready <= access;
        timer     <= timer + 32'd1;
        flush     <= 1'b0;
/* strobes; the registers written */
        osd_we    <= 1'b0;

        if (wr && sel_io)
        begin
            if (reg_a == REG_TAPE)
            begin
/* TAPE */
                tape_on    <= mem_wdata[0];
                tape_turbo <= mem_wdata[1];
                flush      <= mem_wdata[2];
            end
/* OSDC */
            if (reg_a == REG_OSDC)
            begin
                osd_on   <= mem_wdata[0];
                osd_full <= mem_wdata[1];
            end
/* SNAPCTL */
            if (reg_a == REG_SNAPCTL)
            begin
                snap_freeze <= mem_wdata[0];
            end
/* ignored while busy */
            if (reg_a == REG_SNAPCMD && snap_req == sack_s[1])
            begin
                snap_cmd  <= mem_wdata[31:28];
                snap_addr <= mem_wdata[17:0];
/* the request toggles; the data register */
                snap_req  <= !snap_req;
            end
            if (reg_a == REG_SNAPDAT && snap_req == sack_s[1])
            begin
                snap_wdata <= mem_wdata;
            end
/* INTPOS: interrupt position, contention, joystick mode */
            if (reg_a == REG_INTPOS)
            begin
                int_pos <= {mem_wdata[25:16], mem_wdata[9:0]};
                cont_on <= !mem_wdata[31];
/* joysticks; the OSD's text */
                joy_mode <= mem_wdata[29:28];
            end
        end
        if (wr && sel_osd)
        begin
            osd_we   <= 1'b1;
/* byte stores replicate the byte */
            osd_data <= mem_wdata[7:0];
            casez (mem_wstrb)
                4'b???1: osd_addr <= {mem_addr[9:2], 2'd0};
/* the second to fourth byte of a word */
                4'b??10: osd_addr <= {mem_addr[9:2], 2'd1};
                4'b?100: osd_addr <= {mem_addr[9:2], LANE_2};
                default: osd_addr <= {mem_addr[9:2], 2'd3};
            endcase
        end

/* the registers read */
        case (reg_a)
            4'd0: io_q <= CORE_ID;
            4'd1: io_q <= {20'd0, irq_mask, 4'd0, irq_cause};
/* keys, FIFO state, tape control */
            4'd2: io_q <= {14'd0, keys_s};
            4'd3: io_q <= {15'd0, idle, 6'd0, used};
            4'd4: io_q <= {30'd0, tape_turbo, tape_on};
/* OSD control, timer, marker */
            4'd5: io_q <= {30'd0, osd_full, osd_on};
            4'd6: io_q <= timer;
            4'd7: io_q <= {16'd0, marker};
/* recorder event and time; snapshot status */
            4'd8: io_q <= {rec_pend, rec_gap, rec_ovf, 5'd0, rec_delta};
            4'd9: io_q <= rec_since;
            4'd11: io_q <= {30'd0, snap_req != sack_s[1], sfrz_s[1]};
/* snapshot data, interrupt position, the UART */
            4'd13: io_q <= snap_rdata;
            4'd14: io_q <= {!cont_on, 1'b0, joy_mode, 2'd0, int_pos[19:10], 6'd0, int_pos[9:0]};
            4'd15: io_q <= {21'd0, rx_ovr, tx_busy, rx_valid, rx_q};
/* the flash, the machine's status */
            5'd16: io_q <= {21'd0, fl_en, !fl_ncs, fl_busy, fl_q};
            5'd18: io_q <= mstat;
/* 0x28 KEYRAW */
            default: io_q <= raw_s;
        endcase
    end

endmodule

`default_nettype wire
