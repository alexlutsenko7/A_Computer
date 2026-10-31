//=============================================================================
// tape_loader -- the loader hardware the ESP32 system controller drives: TAP/TZX
// pulse player, MIC recorder, snapshot port, OSD port, keys, Bluetooth UART
//
// Clock: 56 MHz (sys_pll c2), synchronous to the 112 MHz system clock (same
// PLL, edges aligned), so the crossings below are ordinary timed paths:
//   keys, cen_tgl            112 -> 56: levels / a toggle, each value held >= 2 clocks here
//   tape_on/lvl/turbo, osd_* 56 -> 112 / pixel clock: levels, synchronised by the receiver
//   snap_*                   request toggle + data held until the acknowledge toggles back
//
// Register bus: driven by the ESP32 over the SPI link (rtl/esp_link.v, frames WR/RD/OSD/
// FIFO/MWR/MRD/STAT); the ESP32 firmware's names are in esp32/src/hw.h.
//   0x1000_0000  registers:
//     00 ID        R: core ID (CORE_ID: 5A58_0001 = "ZX", 4336_0001 = "C6"; link version 1)
//     04 IRQ       R: [3:0] interrupt causes, [11:8] mask   W: [11:8] mask (see the link section)
//     08 KEYS      R: loader keys
//     0C FIFO      W: push command  R: [9:0] used entries, [16] player idle
//     10 TAPE      W: [0] EAR from player, [1] turbo, [2] flush   R: [1:0]
//     14 OSD       W: [0] on, [1] full screen                    R: same
//     18 TIMER     R: 56 MHz counter
//     1C MARKER    R: last CMD_MARK argument executed by the player
//     20 REC       R: recorder event: [31] pending, [30] gap (no MIC edge for GAP_T),
//                     [29] edges lost, [23:0] T-states since the previous edge; reading clears it
//     24 RECCTL    W: [0] armed (hold the Spectrum while an event is unread), [1] hold the Spectrum
//                  R: T-states since the last MIC edge (saturating)
//     28 KEYRAW    R: last keyboard report {modifiers, key 1, key 2, key 3}
//     2C SNAPCTL   W: [0] freeze the Spectrum CPU (snapshots)   R: [0] frozen, [1] command busy
//     30 SNAPCMD   W: start a snapshot command: [31:28] command, [17:0] address (zx_bus.v)
//     34 SNAPDAT   W: command data   R: result of the last command
//     38 INTPOS    W/R: 50 Hz frame interrupt position in zx_video: [9:0] VGA line, [25:16] pixel (reset INT_POS);
//                  [29:28] joystick mode (zx_system; reset: 0 = both Kempston), [31] memory contention off (zx_bus; reset: on)
//     3C UART      to the ESP32's Bluetooth part, 8N1 at BAUD: W: [8] send [7:0] (ignored while busy), [9] drop the
//                  oldest received byte, [10] clear the overrun flag
//                  R: [7:0] oldest received byte, [8] valid, [9] sending, [10] overrun (512-byte FIFO was full)
//     40 FLASH     configuration flash pass-through (ROM install by the ESP32; machines with flash_* wired):
//                  W: [10] enable (the flash pins belong to this port), [9] chip select active,
//                     [8] start: send [7:0] and receive one byte (SPI mode 0, MSB first, clk / 8)
//                  R: [7:0] last byte received, [8] busy, [9] chip select, [10] enabled
//     44 RELOAD    W: [0] = 1 pulses reload (the machine reloads its ROMs from flash and restarts)
//     48 MCTL      machine-specific: W: mctl (kept)   R: mstat   (L64: the 1541 drive)
//     4C MCLR      machine-specific: W: mclr = data for one clock (mclr_we)
//   0x2000_0000  OSD text (32 x 24 bytes, write only, byte stores)
//
// Recorder (saving): MIC (port FE bit 3) edges, timed in T-states like the
// player. While armed, an unread event holds the Spectrum CPU (hold), so no
// edge is lost however long the ESP32 takes (SD writes, the save dialog);
// holding stops the T-states too, so the recorded timing is unaffected.
// Each access takes 2 clocks (register read).
//
// Pulse player: commands from a 512 x 32 FIFO (esp32/src/hal.h):
//   00: PULSE n     hold the level for n T-states, then toggle
//   01: LEVEL l, n  set the level to l, hold n T-states
//   10: DATA b, k   k+1 bits of b, MSB first; each bit = 2 pulses of len0 / len1
//       (bit 11 set: SAMPLES, each bit sets the level for len0 T-states: TZX 0x15)
//   11: [29:28] = 0 len0 <= n, 1 len1 <= n, 2 marker <= n (no time)
// T-states are counted on the CPU clock enable (cen_tgl), so the signal is
// exact at 3.5 MHz and in turbo, and SDRAM stalls stretch it with the CPU.
// Commands follow each other without gaps; zero-time commands never show on
// the line (see the player section).
//=============================================================================
`default_nettype none

module tape_loader #(
    parameter integer BAUD_DIV  = 486,                  // 56 MHz / 115200 (0.02 % fast)
    parameter [19:0]  INT_POS   = {10'd166, 10'd24},    // INTPOS after reset: {pixel, line} (zx_video; measured, see there)
    parameter integer GAP_T     = 8000,                 // T-states without a MIC edge = end of a block
    parameter [31:0]  CORE_ID   = 32'h5A58_0001         // register 0x00: "ZX" link version 1 (L64: "C6")
)(
    input  wire        clk,             // 56 MHz
    input  wire        rst_n,           // synchronous to clk

    input  wire [17:0] keys,            // loader keys (system clock domain)
    input  wire [31:0] keyraw,          // last keyboard report (system clock domain)
    input  wire        cen_tgl,         // toggles on every CPU T-state (system clock domain)
    input  wire        mic,             // port FE bit 3 (system clock domain)
    output wire        hold,            // pause the Spectrum CPU

    output reg         tape_on,         // EAR from the player
    output reg         tape_turbo,
    output reg         tape_lvl,

    output reg         osd_on,
    output reg         osd_full,
    output reg         osd_we,
    output reg  [9:0]  osd_addr,
    output reg  [7:0]  osd_data,
    output reg         bt_tx,           // UART to the ESP32 Bluetooth bridge (idle high)
    input  wire        bt_rx,           // UART from the ESP32 (asynchronous pin)
    input  wire        esp_sck,         // SPI link from the ESP32 system controller (rtl/esp_link.v)
    input  wire        esp_mosi,
    input  wire        esp_cs_n,
    output wire        esp_miso,
    output reg         esp_irq,
    output reg  [19:0] int_pos,         // frame interrupt {pixel, line} for zx_video (static, pixel clock synchronises)
    output reg         cont_on,         // memory contention on (zx_bus synchronises)
    output reg  [1:0]  joy_mode,        // joystick mode (zx_system synchronises)

    // configuration flash pass-through (register 0x40) and ROM reload (0x44)
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

    // snapshot port to zx_bus (system clock domain)
    output reg         snap_freeze,
    output reg         snap_req,
    output reg  [3:0]  snap_cmd,
    output reg  [17:0] snap_addr,
    output reg  [31:0] snap_wdata,
    input  wire        snap_frozen,
    input  wire        snap_ack,
    input  wire [31:0] snap_rdata
);

//-----------------------------------------------------------------------------
// Register bus, driven by the ESP32 through the SPI link
//-----------------------------------------------------------------------------
wire        mem_valid;
wire [31:0] mem_addr, mem_wdata;
wire [3:0]  mem_wstrb;
reg         mem_ready;
wire [31:0] mem_rdata;

esp_link u_link (
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

wire       access  = mem_valid && !mem_ready;
wire       sel_io  = mem_addr[31:28] == 4'h1;
wire       sel_osd = mem_addr[31:28] == 4'h2;
wire       wr      = access && (mem_wstrb != 4'd0);
wire [4:0] reg_a   = mem_addr[6:2];         // 32 registers (18 used)

//-----------------------------------------------------------------------------
// Inputs from the system clock domain
//-----------------------------------------------------------------------------
reg [17:0] keys_s1, keys_s;
reg [1:0]  sfrz_s, sack_s;
reg [31:0] raw_s1, raw_s;
reg [2:0] cen_s;
always @(posedge clk) begin
    keys_s1 <= keys;
    keys_s  <= keys_s1;
    raw_s1  <= keyraw;
    raw_s   <= raw_s1;
    cen_s   <= {cen_s[1:0], cen_tgl};
    sfrz_s  <= {sfrz_s[0], snap_frozen};
    sack_s  <= {sack_s[0], snap_ack};
end
wire tick = cen_s[2] ^ cen_s[1];

//-----------------------------------------------------------------------------
// Command FIFO (512 x 32, block RAM) with a one-command look-ahead (nxt)
//-----------------------------------------------------------------------------
reg  [31:0] fifo [0:511];
reg  [31:0] fq;
reg  [8:0]  wp, rp;
reg  [9:0]  used;
reg         loading, nxt_valid, flush;
reg  [31:0] nxt;
wire        consume;                                    // the player takes nxt this clock
wire        push  = wr && sel_io && reg_a == 4'd3 && used != 10'd512;
wire        fetch = !loading && (!nxt_valid || consume) && used != 10'd0;

always @(posedge clk) begin
    if (push) fifo[wp] <= mem_wdata;
    fq <= fifo[rp];
end

always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
        wp        <= 9'd0;
        rp        <= 9'd0;
        used      <= 10'd0;
        loading   <= 1'b0;
        nxt_valid <= 1'b0;
        nxt       <= 32'd0;
    end else if (flush) begin
        wp        <= 9'd0;
        rp        <= 9'd0;
        used      <= 10'd0;
        loading   <= 1'b0;
        nxt_valid <= 1'b0;
    end else begin
        if (push) wp <= wp + 9'd1;
        if (fetch) rp <= rp + 9'd1;
        used <= used + (push ? 10'd1 : 10'd0) - (fetch ? 10'd1 : 10'd0);
        loading <= fetch;
        if (loading) begin
            nxt       <= fq;
            nxt_valid <= 1'b1;
        end else if (consume)
            nxt_valid <= 1'b0;
    end

//-----------------------------------------------------------------------------
// Pulse player
//
// Timed commands (PULSE, LEVEL with n > 0, DATA, SAMPLES) run one at a time;
// the next one starts in the clock where the running one ends, so the line has
// no gaps. Zero-time commands (LEVEL with n = 0, LEN0/LEN1, MARK) are taken
// from nxt while a command runs and take effect exactly when it ends (level,
// marker) or when the next DATA/SAMPLES starts (lengths, latched per command).
// If the next command is not there yet when one ends (the CPU is late), the
// ticks of the gap are credited to it (pend, up to 255), so the next edge is
// still on time. After the player went idle (stop, end, flush) nothing is
// credited: the first command then starts counting from its own start.
//
// DATA b, k   (nxt[11] = 0): k+1 bits of b MSB first, each bit 2 pulses of len0 / len1
// SAMPLES b, k (nxt[11] = 1): k+1 bits of b MSB first, each sets the level for len0
//-----------------------------------------------------------------------------
localparam [1:0] K_PULSE = 2'd0, K_WAIT = 2'd1, K_DATA = 2'd2, K_SAMP = 2'd3;

reg         act_q;                      // a timed command is running
reg  [1:0]  kind;
reg  [23:0] cnt;
reg  [7:0]  dbyte;
reg  [2:0]  dbit;
reg         dhalf;
reg  [15:0] len0, len1;                 // set by LEN0 / LEN1
reg  [15:0] dl0, dl1;                   // latched by the running DATA / SAMPLES
reg  [15:0] marker, p_mark;
reg         p_mark_set, p_lvl_set, p_lvl;
reg  [7:0]  pend;                       // ticks of a gap, not yet credited
reg         credit_en;                  // a command ended and the stream goes on

wire        chain     = used != 10'd0 || loading || nxt_valid;
wire        idle      = !act_q && !chain;
wire        n_timed   = nxt[31:30] == 2'd0 || nxt[31:30] == 2'd2 || (nxt[31:30] == 2'd1 && nxt[23:0] != 24'd0);
wire        due       = act_q && (cnt == 24'd0 || (tick && cnt == 24'd1));
wire        last      = kind == K_DATA ? (dhalf && dbit == 3'd0) : kind == K_SAMP ? dbit == 3'd0 : 1'b1;
wire        ends      = due && last;
wire        absorb    = nxt_valid && !n_timed && !ends;
wire        start     = nxt_valid && n_timed && (!act_q || ends);
assign      consume   = absorb || start;

wire        lvl_end   = (kind == K_PULSE || kind == K_DATA) ? !tape_lvl : tape_lvl;
wire        lvl_after = p_lvl_set ? p_lvl : lvl_end;
wire        base      = act_q ? lvl_after : tape_lvl;     // level a new PULSE / DATA starts with
wire [8:0]  credit    = (act_q || !credit_en) ? 9'd0 : {1'b0, pend} + {8'd0, tick};
wire        is_samp   = nxt[11];
wire [23:0] n_raw     = nxt[31:30] == 2'd2 ? {8'd0, (is_samp ? len0 : (nxt[7] ? len1 : len0))} : nxt[23:0];
wire [23:0] n_eff     = n_raw > {15'd0, credit} ? n_raw - {15'd0, credit} : 24'd0;

always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
        act_q      <= 1'b0;
        kind       <= K_PULSE;
        cnt        <= 24'd0;
        dbyte      <= 8'd0;
        dbit       <= 3'd0;
        dhalf      <= 1'b0;
        len0       <= 16'd855;
        len1       <= 16'd1710;
        dl0        <= 16'd855;
        dl1        <= 16'd1710;
        marker     <= 16'd0;
        p_mark     <= 16'd0;
        p_mark_set <= 1'b0;
        p_lvl_set  <= 1'b0;
        p_lvl      <= 1'b0;
        pend       <= 8'd0;
        credit_en  <= 1'b0;
        tape_lvl   <= 1'b0;
    end else if (flush) begin
        act_q      <= 1'b0;
        pend       <= 8'd0;
        credit_en  <= 1'b0;
        marker     <= 16'd0;
        p_mark_set <= 1'b0;
        p_lvl_set  <= 1'b0;
        tape_lvl   <= 1'b0;
    end else begin
        // zero-time commands
        if (absorb) begin
            if (nxt[31:30] == 2'd1) begin
                if (act_q) begin p_lvl_set <= 1'b1; p_lvl <= nxt[24]; end
                else       tape_lvl <= nxt[24];
            end else case (nxt[29:28])
                2'd0:    len0 <= nxt[15:0];
                2'd1:    len1 <= nxt[15:0];
                2'd2:    if (act_q) begin p_mark_set <= 1'b1; p_mark <= nxt[15:0]; end
                         else       marker <= nxt[15:0];
                default: ;
            endcase
        end

        // gap credit
        if (act_q || !chain || start)
            pend <= 8'd0;
        else if (credit_en && tick && pend != 8'd255)
            pend <= pend + 8'd1;
        if (!chain && !act_q)
            credit_en <= 1'b0;

        // running command
        if (due) begin
            if (last) begin
                if (p_mark_set) marker <= p_mark;
                p_mark_set <= 1'b0;
                p_lvl_set  <= 1'b0;
                act_q      <= 1'b0;
                credit_en  <= 1'b1;
                tape_lvl   <= lvl_after;
            end else if (kind == K_DATA) begin                  // 2 pulses per bit
                tape_lvl <= !tape_lvl;
                if (!dhalf) begin
                    dhalf <= 1'b1;
                    cnt   <= dbyte[7] ? {8'd0, dl1} : {8'd0, dl0};
                end else begin
                    dhalf <= 1'b0;
                    dbit  <= dbit - 3'd1;
                    dbyte <= {dbyte[6:0], 1'b0};
                    cnt   <= dbyte[6] ? {8'd0, dl1} : {8'd0, dl0};
                end
            end else begin                                      // SAMPLES: next sample
                dbit     <= dbit - 3'd1;
                dbyte    <= {dbyte[6:0], 1'b0};
                tape_lvl <= dbyte[6];
                cnt      <= {8'd0, dl0};
            end
        end else if (act_q && tick)
            cnt <= cnt - 24'd1;

        // next timed command (in the clock the running one ends, or when idle)
        if (start) begin
            act_q <= 1'b1;
            cnt   <= n_eff;
            dbyte <= nxt[7:0];
            dbit  <= nxt[10:8];
            dhalf <= 1'b0;
            dl0   <= len0;
            dl1   <= len1;
            case (nxt[31:30])
                2'd0:    begin kind <= K_PULSE; tape_lvl <= base;    end
                2'd1:    begin kind <= K_WAIT;  tape_lvl <= nxt[24]; end
                default: begin
                    kind     <= is_samp ? K_SAMP : K_DATA;
                    tape_lvl <= is_samp ? nxt[7] : base;
                end
            endcase
        end
    end

//-----------------------------------------------------------------------------
// Recorder: MIC edges in T-states, one event at a time, Spectrum held while unread
//-----------------------------------------------------------------------------
reg  [1:0]  mic_s;
reg         mic_p, rec_pend, rec_gap, rec_ovf, gap_sent, rec_armed, rec_hold;
reg  [23:0] rec_delta;
reg  [31:0] rec_since;
wire        rd_rec   = access && !wr && sel_io && reg_a == 4'd8;
wire        mic_edge = mic_s[1] != mic_p;

assign hold = (rec_armed && rec_pend) || rec_hold;

always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
        mic_s     <= 2'b00;
        mic_p     <= 1'b0;
        rec_pend  <= 1'b0;
        rec_gap   <= 1'b0;
        rec_ovf   <= 1'b0;
        gap_sent  <= 1'b1;
        rec_delta <= 24'd0;
        rec_since <= 32'd0;
        rec_armed <= 1'b0;
        rec_hold  <= 1'b0;
    end else begin
        mic_s <= {mic_s[0], mic};
        mic_p <= mic_s[1];
        if (wr && sel_io && reg_a == 4'd9) begin
            rec_armed <= mem_wdata[0];
            rec_hold  <= mem_wdata[1];
        end
        if (rd_rec) begin
            rec_pend <= 1'b0;
            rec_ovf  <= 1'b0;
        end
        if (mic_edge) begin
            if (rec_pend && !rd_rec)
                rec_ovf <= 1'b1;                                // previous edge not read yet (not armed)
            else begin
                rec_pend  <= 1'b1;
                rec_gap   <= 1'b0;
                rec_delta <= rec_since > 32'h00FFFFFF ? 24'hFFFFFF : rec_since[23:0];
            end
            rec_since <= 32'd0;
            gap_sent  <= 1'b0;
        end else begin
            if (tick && rec_since != 32'hFFFFFFFF)
                rec_since <= rec_since + 32'd1;
            if (rec_since >= GAP_T && !gap_sent && (!rec_pend || rd_rec)) begin
                rec_pend  <= 1'b1;
                rec_gap   <= 1'b1;
                rec_delta <= GAP_T[23:0];
                gap_sent  <= 1'b1;
            end
        end
    end

//-----------------------------------------------------------------------------
// UART to the ESP32 Bluetooth part (esp32/esp32.ino): 8N1, 512-byte receive FIFO (one M9K, ~45 ms of
// continuous data: the firmware may be busy for a few ms, e.g. redrawing the OSD)
//-----------------------------------------------------------------------------
wire       uart_wr = wr && sel_io && reg_a == 4'd15;
reg  [9:0] tx_sh;                                       // {stop, data, start}, LSB first
reg  [3:0] tx_n;                                        // bit times left (start, 8 data, stop, end of stop)
reg  [9:0] tx_cnt;
wire       tx_busy = tx_n != 4'd0;

always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
        tx_sh  <= 10'h3FF;
        tx_n   <= 4'd0;
        tx_cnt <= 10'd0;
        bt_tx  <= 1'b1;
    end else if (!tx_busy) begin
        bt_tx <= 1'b1;
        if (uart_wr && mem_wdata[8]) begin
            tx_sh  <= {1'b1, mem_wdata[7:0], 1'b0};
            tx_n   <= 4'd11;                            // busy until the stop bit has lasted a whole bit
            tx_cnt <= 10'd0;
        end
    end else if (tx_cnt != 10'd0)
        tx_cnt <= tx_cnt - 10'd1;
    else begin
        bt_tx  <= tx_sh[0];
        tx_sh  <= {1'b1, tx_sh[9:1]};
        tx_n   <= tx_n - 4'd1;
        tx_cnt <= BAUD_DIV[9:0] - 10'd1;
    end

reg  [2:0] rx_s;
reg  [9:0] rx_cnt;
reg  [3:0] rx_n;                                        // 0 = idle, else bits still to sample (start, 8 data, stop)
reg  [7:0] rx_sh;
reg  [7:0] rx_fifo [0:511];
reg  [7:0] rx_q;                                        // rx_fifo[rx_rp], 1 clock behind rx_rp
reg  [8:0] rx_wp, rx_rp;
reg  [9:0] rx_used;
reg  [1:0] rx_seen;                                     // rx_used != 0 for 2 clocks: rx_q is valid
reg        rx_ovr;
wire       rx_valid = rx_used != 10'd0 && rx_seen[1];
wire       rx_pop   = uart_wr && mem_wdata[9] && rx_valid;
reg        rx_push;

always @(posedge clk) begin
    rx_s <= {rx_s[1:0], bt_rx};
    if (rx_push) rx_fifo[rx_wp] <= rx_sh;
    rx_q <= rx_fifo[rx_rp];
end

always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
        rx_cnt  <= 10'd0;
        rx_n    <= 4'd0;
        rx_sh   <= 8'd0;
        rx_wp   <= 9'd0;
        rx_rp   <= 9'd0;
        rx_used <= 10'd0;
        rx_seen <= 2'd0;
        rx_ovr  <= 1'b0;
        rx_push <= 1'b0;
    end else begin
        rx_push <= 1'b0;
        if (rx_n == 4'd0) begin
            if (!rx_s[2]) begin                         // start bit: sample in the middle of each bit
                rx_n   <= 4'd10;
                rx_cnt <= BAUD_DIV[10:1];
            end
        end else if (rx_cnt != 10'd0)
            rx_cnt <= rx_cnt - 10'd1;
        else begin
            rx_cnt <= BAUD_DIV[9:0] - 10'd1;
            rx_n   <= rx_n - 4'd1;
            if (rx_n == 4'd10 && rx_s[2])
                rx_n <= 4'd0;                           // glitch, not a start bit
            else if (rx_n >= 4'd2)
                rx_sh <= {rx_s[2], rx_sh[7:1]};
            else if (rx_s[2]) begin                     // stop bit: keep the byte
                if (rx_used == 10'd512) rx_ovr <= 1'b1;
                else                  rx_push <= 1'b1;
            end
        end
        if (rx_push) rx_wp <= rx_wp + 9'd1;
        if (rx_pop)  rx_rp <= rx_rp + 9'd1;
        rx_used <= rx_used + (rx_push ? 10'd1 : 10'd0) - (rx_pop ? 10'd1 : 10'd0);
        rx_seen <= rx_pop ? 2'd0 : {rx_seen[0], rx_used != 10'd0};   // after a pop rx_q follows 2 clocks later
        if (uart_wr && mem_wdata[10]) rx_ovr <= 1'b0;
    end

//-----------------------------------------------------------------------------
// ESP32 link: core ID (register 0x00) and interrupt (register 0x04)
//   R 0x00: CORE_ID
//   R 0x04: [3:0] causes, [11:8] mask; reading clears cause 1
//   W 0x04: [11:8] mask
// Causes: [0] player FIFO at most half full, [1] key state changed (latched),
//         [2] recorder event pending, [3] snapshot command port idle
// esp_irq = any cause whose mask bit is set (level, active high)
//-----------------------------------------------------------------------------
reg  [3:0]  irq_mask;
reg         key_chg;
reg  [17:0] keys_p;
reg  [31:0] raw_p;
wire [3:0]  irq_cause = {snap_req == sack_s[1], rec_pend, key_chg, used <= 10'd256};
always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
        irq_mask <= 4'd0;
        key_chg  <= 1'b0;
        keys_p   <= 18'd0;
        raw_p    <= 32'd0;
        esp_irq  <= 1'b0;
    end else begin
        keys_p  <= keys_s;
        raw_p   <= raw_s;
        if (wr && sel_io && reg_a == 4'd1) irq_mask <= mem_wdata[11:8];
        if (keys_p != keys_s || raw_p != raw_s) key_chg <= 1'b1;
        else if (access && !wr && sel_io && reg_a == 4'd1) key_chg <= 1'b0;
        esp_irq <= |(irq_cause & irq_mask);
    end

//-----------------------------------------------------------------------------
// Flash pass-through: one byte per start, DCLK = clk / 8 (MISO sampled at the end of
// the high phase, MOSI changes in the low phase, as rom_loader); reload pulse
//-----------------------------------------------------------------------------
wire       fl_wr = wr && sel_io && reg_a == 5'd16;
reg  [7:0] fl_sh, fl_q;
reg  [3:0] fl_bits;
reg  [1:0] fl_div;
wire       fl_busy = fl_bits != 4'd0;

always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
        fl_en   <= 1'b0;
        fl_ncs  <= 1'b1;
        fl_dclk <= 1'b0;
        fl_mosi <= 1'b0;
        fl_sh   <= 8'd0;
        fl_q    <= 8'd0;
        fl_bits <= 4'd0;
        fl_div  <= 2'd0;
        reload  <= 1'b0;
        mctl    <= 32'd0;
        mclr    <= 32'd0;
        mclr_we <= 1'b0;
    end else begin
        reload  <= wr && sel_io && reg_a == 5'd17 && mem_wdata[0];
        mclr_we <= wr && sel_io && reg_a == 5'd19;
        if (wr && sel_io && reg_a == 5'd18) mctl <= mem_wdata;
        if (wr && sel_io && reg_a == 5'd19) mclr <= mem_wdata;
        if (fl_wr && !fl_busy) begin
            fl_en  <= mem_wdata[10];
            fl_ncs <= !mem_wdata[9];
            if (mem_wdata[8]) begin
                fl_sh   <= mem_wdata[7:0];
                fl_mosi <= mem_wdata[7];
                fl_bits <= 4'd8;
                fl_div  <= 2'd0;
            end
        end else if (fl_busy) begin
            fl_div <= fl_div + 2'd1;
            if (fl_div == 2'd3) begin
                if (!fl_dclk)
                    fl_dclk <= 1'b1;
                else begin
                    fl_dclk <= 1'b0;
                    fl_q    <= {fl_q[6:0], fl_miso};
                    fl_sh   <= {fl_sh[6:0], 1'b0};
                    fl_mosi <= fl_sh[6];
                    fl_bits <= fl_bits - 4'd1;
                end
            end
        end
    end

//-----------------------------------------------------------------------------
// Control registers, OSD port, timer, read data
//-----------------------------------------------------------------------------
reg  [31:0] timer, io_q;

assign mem_rdata = io_q;

always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
        mem_ready  <= 1'b0;
        io_q       <= 32'd0;
        timer      <= 32'd0;
        tape_on    <= 1'b0;
        tape_turbo <= 1'b0;
        flush      <= 1'b0;
        osd_on     <= 1'b0;
        osd_full   <= 1'b0;
        osd_we     <= 1'b0;
        osd_addr   <= 10'd0;
        osd_data   <= 8'd0;
        snap_freeze <= 1'b0;
        int_pos    <= INT_POS;
        cont_on    <= 1'b1;
        joy_mode   <= 2'd0;
        snap_req   <= 1'b0;
        snap_cmd   <= 4'd0;
        snap_addr  <= 18'd0;
        snap_wdata <= 32'd0;
    end else begin
        mem_ready <= access;
        timer     <= timer + 32'd1;
        flush     <= 1'b0;
        osd_we    <= 1'b0;

        if (wr && sel_io) begin
            if (reg_a == 4'd4) begin
                tape_on    <= mem_wdata[0];
                tape_turbo <= mem_wdata[1];
                flush      <= mem_wdata[2];
            end
            if (reg_a == 4'd5) begin
                osd_on   <= mem_wdata[0];
                osd_full <= mem_wdata[1];
            end
            if (reg_a == 4'd11)
                snap_freeze <= mem_wdata[0];
            if (reg_a == 4'd12 && snap_req == sack_s[1]) begin     // ignored while busy
                snap_cmd  <= mem_wdata[31:28];
                snap_addr <= mem_wdata[17:0];
                snap_req  <= !snap_req;
            end
            if (reg_a == 4'd13 && snap_req == sack_s[1])
                snap_wdata <= mem_wdata;
            if (reg_a == 4'd14) begin
                int_pos <= {mem_wdata[25:16], mem_wdata[9:0]};
                cont_on <= !mem_wdata[31];
                joy_mode <= mem_wdata[29:28];
            end
        end
        if (wr && sel_osd) begin
            osd_we   <= 1'b1;
            osd_data <= mem_wdata[7:0];                         // byte stores replicate the byte
            casez (mem_wstrb)
                4'b???1: osd_addr <= {mem_addr[9:2], 2'd0};
                4'b??10: osd_addr <= {mem_addr[9:2], 2'd1};
                4'b?100: osd_addr <= {mem_addr[9:2], 2'd2};
                default: osd_addr <= {mem_addr[9:2], 2'd3};
            endcase
        end

        case (reg_a)
            4'd0:    io_q <= CORE_ID;
            4'd1:    io_q <= {20'd0, irq_mask, 4'd0, irq_cause};
            4'd2:    io_q <= {14'd0, keys_s};
            4'd3:    io_q <= {15'd0, idle, 6'd0, used};
            4'd4:    io_q <= {30'd0, tape_turbo, tape_on};
            4'd5:    io_q <= {30'd0, osd_full, osd_on};
            4'd6:    io_q <= timer;
            4'd7:    io_q <= {16'd0, marker};
            4'd8:    io_q <= {rec_pend, rec_gap, rec_ovf, 5'd0, rec_delta};
            4'd9:    io_q <= rec_since;
            4'd11:   io_q <= {30'd0, snap_req != sack_s[1], sfrz_s[1]};
            4'd13:   io_q <= snap_rdata;
            4'd14:   io_q <= {!cont_on, 1'b0, joy_mode, 2'd0, int_pos[19:10], 6'd0, int_pos[9:0]};
            4'd15:   io_q <= {21'd0, rx_ovr, tx_busy, rx_valid, rx_q};
            5'd16:   io_q <= {21'd0, fl_en, !fl_ncs, fl_busy, fl_q};
            5'd18:   io_q <= mstat;
            default: io_q <= raw_s;             // 0x28 KEYRAW
        endcase
    end

endmodule

`default_nettype wire
