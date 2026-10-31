//=============================================================================
// LTari -- Atari 130XE / 800XL (PAL) on the QMTECH Cyclone IV EP4CE15 core board with
//             the Extra_PCB_CycloneIV I/O board (same pins as LSpectrum / L64)
//
// Application image of the machine menu (AMenu/, docs/PLAN.md), built twice from these
// sources: revision LTari800 (MODEL130 = 0, flash 0x280000) is the LTari 800 (800XL,
// 64 KB), revision LTari (MODEL130 = 1, flash 0x300000) the LTari 130 (130XE, 128 KB).
// (The remote update block cannot tell an application image its own start address: the
// current state reads back the same value for both.) ROMs (AltirraOS + Altirra BASIC,
// LTari/roms) at 0x380000.
//
// Clocks:
//   atari_pll  clk    28.373 MHz  the whole machine (16 clk per machine cycle)
//              clk_sd 85.119 MHz  3 x clk, aligned: SDRAM, ROM loader, tape loader + ESP32
//                                 link, audio, frame buffer
//              clk_sdo 85.119 MHz delayed: SDRAM clock (inverted, DDIO), as LSpectrum
//   atari_vpll pclk               VGA pixel clock (frame buffer reader, OSD), switched by F8 as
//                                 LSpectrum: 25.208 MHz = 640 x 480 @ 60 Hz (after power-up),
//                                 27.009 MHz = 720 x 576 @ 50 Hz
//
// Controls:
//   KEY0 (W13)    reset (Atari, ROM reload, tape loader; the ESP32 restarts)
//   Ctrl+Alt+Del  back to the machine menu, as KEY1 (when the keys are released)
//   KEY1 (Y13)    back to the machine menu (reconfigures to the factory image)
//   keyboard      atari_keyboard.v (Alt+F2/F3/F4 START/SELECT/OPTION, Alt+F5 Reset, Pause Break)
//   F8            video 60 Hz (power-up) / 50 Hz; the Atari runs on undisturbed
//   joysticks     DB9-1 = stick 0, DB9-2 = stick 1 (ESP32 F4 menu mode 1: swapped)
//   LED           fast blink = no ROM image in flash (0x380000)
//=============================================================================
`default_nettype none

module LTari #(
    parameter         SD_PHASE_PS = "1250",
    parameter         MODEL130    = 1               // 1 = 130XE (128 KB), 0 = 800XL (64 KB); set by the revision
)(
    input  wire        CLOCK_50,
    input  wire        RESET_N,
    input  wire        KEY1,
    output wire        LEDR,

    output wire [12:0] DRAM_ADDR,
    output wire [1:0]  DRAM_BA,
    output wire        DRAM_CAS_N,
    output wire        DRAM_CKE,
    output wire        DRAM_CLK,
    output wire        DRAM_CS_N,
    inout  wire [15:0] DRAM_DQ,
    output wire        DRAM_LDQM,
    output wire        DRAM_RAS_N,
    output wire        DRAM_UDQM,
    output wire        DRAM_WE_N,

    output reg  [3:0]  VGA_R,
    output reg  [3:0]  VGA_G,
    output reg  [3:0]  VGA_B,
    output reg         VGA_HS,
    output reg         VGA_VS,

    input  wire        KB_OUT,
    input  wire        KB_IN,

    input  wire        ESP_SCK,
    input  wire        ESP_MOSI,
    input  wire        ESP_CS_N,
    output wire        ESP_MISO,
    output wire        ESP_IRQ,

    output wire        AUDIO_AY,
    output wire        AUDIO_BEEP,
    input  wire        JOY1_UP_N,
    input  wire        JOY1_DOWN_N,
    input  wire        JOY1_LEFT_N,
    input  wire        JOY1_RIGHT_N,
    input  wire        JOY1_FIRE_N,
    input  wire        JOY2_UP_N,
    input  wire        JOY2_DOWN_N,
    input  wire        JOY2_LEFT_N,
    input  wire        JOY2_RIGHT_N,
    input  wire        JOY2_FIRE_N,

    input  wire        BT_BCLK,
    input  wire        BT_LRCK,
    output wire        BT_DATA,
    output wire        BT_TX,
    input  wire        BT_RX
);

localparam integer CLK_HZ      = 28373016;
localparam integer KBD_WAIT_MS = 1500;

//-----------------------------------------------------------------------------
// Clocks and resets
//-----------------------------------------------------------------------------
wire clk, clk_sd, clk_sdo, locked, clk_v50, clk_v60, vlocked;

atari_pll #(.SD_PHASE_PS(SD_PHASE_PS)) u_pll (
    .inclk0 (CLOCK_50),
    .c0     (clk),
    .c1     (clk_sd),
    .c2     (clk_sdo),
    .locked (locked)
);

atari_vpll u_vpll (
    .inclk0 (CLOCK_50),
    .c0     (clk_v50),
    .c1     (clk_v60),
    .locked (vlocked)
);

// por_n: power-up only (keyboard, frame buffer writer); rst_n: the Atari (+ KEY0); rst_sd_n:
// clk_sd (+ KEY0)
wire       kbd_cad;
reg  [2:0] por_sr, rst_sr, rsd_sr;
reg        cad_q;
wire       key_arst_n = RESET_N & locked;

always @(posedge clk or negedge locked)
    if (!locked) por_sr <= 3'b000;
    else         por_sr <= {por_sr[1:0], 1'b1};
wire por_n = por_sr[2];

always @(posedge clk or negedge por_n)
    if (!por_n) cad_q <= 1'b0;
    else        cad_q <= kbd_cad;

always @(posedge clk or negedge key_arst_n)
    if (!key_arst_n) rst_sr <= 3'b000;
    else             rst_sr <= {rst_sr[1:0], 1'b1};
wire rst_n = rst_sr[2];

always @(posedge clk_sd or negedge key_arst_n)
    if (!key_arst_n) rsd_sr <= 3'b000;
    else             rsd_sr <= {rsd_sr[1:0], 1'b1};
wire rst_sd_n = rsd_sr[2];

// SDRAM clock = inverted clk_sdo through a DDIO output, as LSpectrum / DDR_TEST
altddio_out #(
    .extend_oe_disable      ("OFF"),
    .intended_device_family ("Cyclone IV E"),
    .invert_output          ("OFF"),
    .lpm_hint               ("UNUSED"),
    .lpm_type               ("altddio_out"),
    .oe_reg                 ("UNREGISTERED"),
    .power_up_high          ("OFF"),
    .width                  (1)
) u_sdclk (
    .datain_h   (1'b0),
    .datain_l   (1'b1),
    .outclock   (clk_sdo),
    .dataout    (DRAM_CLK),
    .aclr       (1'b0),
    .aset       (1'b0),
    .oe         (1'b1),
    .outclocken (1'b1),
    .sclr       (1'b0),
    .sset       (1'b0),
    .oe_out     ()
);

wire [15:0] dq_o;
wire        dq_oe;
assign DRAM_DQ = dq_oe ? dq_o : 16'hzzzz;

//-----------------------------------------------------------------------------
// Pixel clock switch (F8), sequenced from CLOCK_50 as in L64: video reset on,
// clock off, select, clock on, video reset off (16 CLOCK_50 cycles per step)
//-----------------------------------------------------------------------------
wire       kbd_f8;                      // toggles on F8 (power-up: 0 = 60 Hz)
reg  [2:0] rst50_sr;
always @(posedge CLOCK_50 or negedge vlocked)
    if (!vlocked) rst50_sr <= 3'b000;
    else          rst50_sr <= {rst50_sr[1:0], 1'b1};
wire rst50_n = rst50_sr[2];

reg [1:0] f8_s;
always @(posedge CLOCK_50 or negedge rst50_n)
    if (!rst50_n) f8_s <= 2'b00;
    else          f8_s <= {f8_s[0], kbd_f8};
wire mode_req = !f8_s[1];               // 1 = 60 Hz

localparam [1:0] S_OFF = 2'd0, S_SEL = 2'd1, S_ENA = 2'd2, S_RUN = 2'd3;
reg  [1:0] vstate;
reg  [3:0] vwait;
reg        m60, clk_ena, video_run;

always @(posedge CLOCK_50 or negedge rst50_n)
    if (!rst50_n) begin
        vstate    <= S_OFF;
        vwait     <= 4'd0;
        m60       <= 1'b1;
        clk_ena   <= 1'b0;
        video_run <= 1'b0;
    end else begin
        vwait <= vwait + 4'd1;
        case (vstate)
            S_OFF: if (&vwait) begin m60 <= mode_req; vstate <= S_SEL; end
            S_SEL: if (&vwait) begin clk_ena <= 1'b1; vstate <= S_ENA; end
            S_ENA: if (&vwait) begin video_run <= 1'b1; vstate <= S_RUN; end
            S_RUN: begin
                vwait <= 4'd0;
                if (mode_req != m60) begin
                    video_run <= 1'b0;
                    clk_ena   <= 1'b0;
                    vstate    <= S_OFF;
                end
            end
        endcase
    end

wire pclk;
vga_clkmux u_clkmux (
    .clk0   (clk_v50),
    .clk1   (clk_v60),
    .sel    (m60),
    .ena    (clk_ena),
    .outclk (pclk)
);

reg [2:0] prst_sr;
always @(posedge pclk or negedge video_run)
    if (!video_run) prst_sr <= 3'b000;
    else            prst_sr <= {prst_sr[1:0], 1'b1};
wire prst_n = prst_sr[2];

//-----------------------------------------------------------------------------
// Remote update block: KEY1 / Ctrl+Alt+Del back to the machine menu (as L64)
//-----------------------------------------------------------------------------
reg  [1:0]  ru_div = 2'd0;
always @(posedge CLOCK_50) ru_div <= ru_div + 2'd1;
wire ruclk = ru_div[1];

reg  [2:0]  k1_s;
reg  [17:0] k1_cnt;
reg         ru_reconfig = 1'b0;
reg  [9:0]  wd_cnt = 10'd0;
always @(posedge ruclk) wd_cnt <= wd_cnt + 10'd1;
wire        wd_reset = wd_cnt[9];           // watchdog reset every 82 us: it never expires, whatever the menu set
reg         k1_held = 1'b0;             // KEY1 held >= 21 ms; the request goes out when it is released
reg  [2:0]  cad_s = 3'd0;
reg         cad_held = 1'b0;            // Ctrl+Alt+Del: the same request when the keys are released
reg  [25:0] up_cnt = 26'd0;             // 2.7 s after configuration: LED on (shows the machine started)
always @(posedge ruclk) begin
    k1_s <= {k1_s[1:0], KEY1};
    if (k1_s[2])                k1_cnt <= 18'd0;
    else if (!(&k1_cnt))        k1_cnt <= k1_cnt + 18'd1;
    if (&k1_cnt)                k1_held <= 1'b1;
    cad_s <= {cad_s[1:0], cad_q};
    if (cad_s[2])               cad_held <= 1'b1;
    ru_reconfig <= ru_reconfig | (k1_held && k1_s[2]) | (cad_held && !cad_s[2]);
    if (!up_cnt[25])            up_cnt <= up_cnt + 26'd1;
end

wire   model130 = MODEL130 != 0;

altremote_update #(
    .check_app_pof            ("false"),
    .config_device_addr_width (24),
    .in_data_width            (24),
    .out_data_width           (29),
    .operation_mode           ("remote")
) u_ru (
    .clock       (ruclk),
    .reset       (1'b0),
    .read_param  (1'b0),
    .write_param (1'b0),
    .param       (3'b100),
    .read_source (2'b00),
    .data_in     (24'd0),
    .reconfig    (ru_reconfig),
    .reset_timer (wd_reset),
    .ctl_nupdt   (1'b0),
    .busy        (),
    .data_out    ()
);

//-----------------------------------------------------------------------------
// Keyboard (power-up reset only); the Atari waits for the first keyboard packet
// (at most KBD_WAIT_MS), so keys held at the start (OPTION: no BASIC) are seen
//-----------------------------------------------------------------------------
wire        k_stb, k_down, k_shift, k_ctrl, k_break, k_reset, kb_seen;
wire [5:0]  k_code;
wire [2:0]  k_consol_n;
wire [17:0] lkeys;
wire [31:0] kb_raw;
wire        l_osd_on, l_osd_full;

atari_keyboard #(.CLK_HZ(CLK_HZ)) u_kbd (
    .clk       (clk),
    .rst_n     (por_n),
    .rx        (KB_OUT & KB_IN),
    .block     (l_osd_on & l_osd_full),
    .key_stb   (k_stb),
    .key_code  (k_code),
    .key_down  (k_down),
    .key_shift (k_shift),
    .key_ctrl  (k_ctrl),
    .key_break (k_break),
    .consol_n  (k_consol_n),
    .reset_key (k_reset),
    .lkeys     (lkeys),
    .f8_tgl    (kbd_f8),
    .cad       (kbd_cad),
    .seen      (kb_seen),
    .raw       (kb_raw)
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

//-----------------------------------------------------------------------------
// Joysticks: PORTA bits 3:0 = stick 0 (up, down, left, right), 7:4 = stick 1; triggers
// on GTIA TRIG0 / TRIG1. Mode (tape loader INTPOS[29:28], ESP32 F4 menu): 1 = swapped.
//-----------------------------------------------------------------------------
wire [1:0] joy_mode;
reg  [1:0] jm_s1, jm_s;
reg  [4:0] j1_s1, j1, j2_s1, j2;        // {fire, right, left, down, up}, active low
always @(posedge clk) begin
    jm_s1 <= joy_mode;  jm_s <= jm_s1;
    j1_s1 <= {JOY1_FIRE_N, JOY1_RIGHT_N, JOY1_LEFT_N, JOY1_DOWN_N, JOY1_UP_N};  j1 <= j1_s1;
    j2_s1 <= {JOY2_FIRE_N, JOY2_RIGHT_N, JOY2_LEFT_N, JOY2_DOWN_N, JOY2_UP_N};  j2 <= j2_s1;
end
wire [4:0] stick0 = jm_s == 2'd1 ? j2 : j1;
wire [4:0] stick1 = jm_s == 2'd1 ? j1 : j2;

//-----------------------------------------------------------------------------
// The machine
//-----------------------------------------------------------------------------
wire f_dclk, f_ncs, f_mosi, f_miso;

flash_if u_flash (
    .dclk (f_dclk),
    .ncs  (f_ncs),
    .mosi (f_mosi),
    .miso (f_miso)
);

wire        px_stb, px_blank, a_speaker, bad_image, a_run;
wire [7:0]  px_cc, px0, px1;
wire [8:0]  px_vc;
wire [5:0]  a_audio;
wire        sio_out, sio_cmd_n, sio_motor_n, sio_in, so_stb;
wire [7:0]  so_byte;
wire        l_reload;
wire [31:0] l_mctl, l_mstat, l_mclr;
wire        l_mclr_we;
wire        fb_req, fb_we, fb_ack;
wire [20:0] fb_addr;
wire [15:0] fb_wdata, fb_rdata;
reg         x_req, x_we;
reg  [20:0] x_addr;
reg  [7:0]  x_din;
wire        x_ack;
wire [7:0]  x_dout;

reg [1:0] kr_s;
always @(posedge clk) kr_s <= {kr_s[0], kbd_ready};

wire        a_frozen, a_rmode;          // snapshots (clk; static while the port uses them)
wire [63:0] a_regs;
wire [47:0] a_pia;
wire [11:0] a_cart;
reg         s_rm, s_rst;                // snapshot CTL (clk_sd): restore mode request, CPU-only reset
wire        snap_freeze;                // snapshot SNAPCTL[0] (clk_sd)
reg  [1:0]  frz_sd, rm_sd;              // a_frozen / a_rmode in clk_sd

atari_system u_sys (
    .clk        (clk),
    .rst_n      (rst_n & kr_s[1]),
    .clk_sd     (clk_sd),
    .rst_sd_n   (rst_sd_n),
    .model130   (model130),
    .freeze     (snap_freeze),
    .rm_req     (s_rm),
    .cpu_rst_req(s_rst),
    .frozen     (a_frozen),
    .rmode      (a_rmode),
    .cpu_regs   (a_regs),
    .pia_st     (a_pia),
    .cart_st    (a_cart),
    .reload     (l_reload),
    .cart       (l_mctl[18:16]),        // ESP32 (atari.cpp): cartridge type (image at SDRAM 0x28000 / 0x100000)
    .reset_key  (k_reset),
    .key_stb    (k_stb),
    .key_code   (k_code),
    .key_down   (k_down),
    .key_shift  (k_shift),
    .key_ctrl   (k_ctrl),
    .key_break  (k_break),
    .consol_n   (k_consol_n),
    .joy_dir_n  ({stick1[3:0], stick0[3:0]}),
    .joy_trig_n ({stick1[4], stick0[4]}),
    .sd_cke     (DRAM_CKE),
    .sd_cs_n    (DRAM_CS_N),
    .sd_ras_n   (DRAM_RAS_N),
    .sd_cas_n   (DRAM_CAS_N),
    .sd_we_n    (DRAM_WE_N),
    .sd_ba      (DRAM_BA),
    .sd_a       (DRAM_ADDR),
    .sd_dqm     ({DRAM_UDQM, DRAM_LDQM}),
    .sd_dq_o    (dq_o),
    .sd_dq_oe   (dq_oe),
    .sd_dq_i    (DRAM_DQ),
    .f_dclk     (f_dclk),
    .f_ncs      (f_ncs),
    .f_mosi     (f_mosi),
    .f_miso     (f_miso),
    .sio_out    (sio_out),
    .sio_in     (sio_in),
    .sio_cmd_n  (sio_cmd_n),
    .sio_motor_n(sio_motor_n),
    .so_stb     (so_stb),
    .so_byte    (so_byte),
    .px_stb     (px_stb),
    .px_cc      (px_cc),
    .px_vc      (px_vc),
    .px_blank   (px_blank),
    .px0        (px0),
    .px1        (px1),
    .audio      (a_audio),
    .speaker    (a_speaker),
    .bad_image  (bad_image),
    .run_o      (a_run),
    .fb_req     (fb_req),
    .fb_we      (fb_we),
    .fb_addr    (fb_addr),
    .fb_wdata   (fb_wdata),
    .fb_ack     (fb_ack),
    .fb_rdata   (fb_rdata),
    .x_req      (x_req),
    .x_we       (x_we),
    .x_addr     (x_addr),
    .x_din      (x_din),
    .x_ack      (x_ack),
    .x_dout     (x_dout)
);

//-----------------------------------------------------------------------------
// Audio: POKEY (0-60) + the console speaker -> sigma-delta pin and Bluetooth I2S
//-----------------------------------------------------------------------------
reg [9:0]  snd;
wire [10:0] snd_sum = {1'b0, a_audio, 4'b0000} + {4'd0, a_speaker, 6'd0};   // up to 960 + 64
always @(posedge clk_sd) snd <= snd_sum[10] ? 10'h3FF : snd_sum[9:0];       // saturate, no wrap

wire audio;
sd_dac #(.W(10)) u_dac (
    .clk   (clk_sd),
    .rst_n (rst_sd_n),
    .din   (snd),
    .dout  (audio)
);

// bt_i2s low-passes at its "AY" sample rate: 3.5469 MHz from a DDS, as in L64
reg  [31:0] bt_dds;
reg         bt_cen;
wire [32:0] bt_next = {1'b0, bt_dds} + 33'd178970747;    // 3.5469 / 85.119 * 2^32
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
    .i2s_bclk (BT_BCLK),
    .i2s_lrck (BT_LRCK),
    .i2s_data (BT_DATA)
);

assign AUDIO_AY   = audio;
assign AUDIO_BEEP = 1'b0;

//-----------------------------------------------------------------------------
// Tape loader hardware + ESP32 link (clk_sd): OSD, keys, Bluetooth UART, F4 joystick mode,
// memory commands. Core ID 4154_0001 ("AT").
//-----------------------------------------------------------------------------
wire       osd_we;
wire [9:0] osd_addr;
wire [7:0] osd_data;
wire       snap_req;
wire [3:0] snap_cmd;
wire [17:0] snap_addr;
wire [31:0] snap_wdata;
reg        snap_ack;
reg [31:0] snap_rdata;

tape_loader #(.BAUD_DIV(739), .CORE_ID(32'h4154_0001)) u_tape (
    .clk         (clk_sd),
    .rst_n       (rst_sd_n),
    .keys        (lkeys),
    .keyraw      (kb_raw),
    .cen_tgl     (1'b0),
    .mic         (1'b0),
    .hold        (),
    .tape_on     (),
    .tape_turbo  (),
    .tape_lvl    (),
    .osd_on      (l_osd_on),
    .osd_full    (l_osd_full),
    .osd_we      (osd_we),
    .osd_addr    (osd_addr),
    .osd_data    (osd_data),
    .int_pos     (),
    .cont_on     (),
    .joy_mode    (joy_mode),
    .fl_en       (),
    .fl_ncs      (),
    .fl_dclk     (),
    .fl_mosi     (),
    .fl_miso     (f_miso),
    .reload      (l_reload),
    .mctl        (l_mctl),
    .mstat       (l_mstat),
    .mclr        (l_mclr),
    .mclr_we     (l_mclr_we),
    .snap_freeze (snap_freeze),
    .snap_req    (snap_req),
    .snap_cmd    (snap_cmd),
    .snap_addr   (snap_addr),
    .snap_wdata  (snap_wdata),
    .snap_frozen (frz_sd[1]),
    .snap_ack    (snap_ack),
    .snap_rdata  (snap_rdata),
    .bt_tx       (BT_TX),
    .bt_rx       (BT_RX),
    .esp_sck     (ESP_SCK),
    .esp_mosi    (ESP_MOSI),
    .esp_cs_n    (ESP_CS_N),
    .esp_miso    (ESP_MISO),
    .esp_irq     (ESP_IRQ)
);

//-----------------------------------------------------------------------------
// SIO bus bridge: the ESP32 is the disk drive (tape loader MCTL / MSTAT / MCLR, atari_sio.v);
// RELOAD (register 0x44) cold-starts the Atari, e.g. after a disk was inserted
//-----------------------------------------------------------------------------
atari_sio u_sio (
    .clk_sd  (clk_sd),
    .rst_n   (rst_sd_n),
    .so_stb  (so_stb),
    .so_byte (so_byte),
    .cmd_n   (sio_cmd_n),
    .motor_n (sio_motor_n),
    .sio_in  (sio_in),
    .mctl    (l_mctl),
    .mstat   (l_mstat),
    .mclr    (l_mclr),
    .mclr_we (l_mclr_we)
);

//-----------------------------------------------------------------------------
// Memory commands (tape loader SNAPCMD / SNAPDAT; codes as L64):
//   1 MRD  read SDRAM byte at addr[17:0] -> rdata[7:0]; while the frame buffer hold is on
//          (CTL[2], screenshots): the byte at addr[16:0] of the newest frame buffer instead
//   2 MWR  write wdata[7:0] to addr[17:0]
//          MCTL[23] = 1 (loading an Atarimax cartridge): MRD / MWR address 0x100000 + MCTL[21:20] * 256 KB
//          + addr instead
//          (RAM 0x00000-0x1FFFF and the restore bank 0x30000-0x3FFFF: with the Atari frozen, SNAPCTL[0])
//   3 REG  addr[2:0] = 0 -> {P, Y, X, A}, 1 -> {PC, S (16 bits, 01xx)}, 2 -> {PACTL, DDRA, ORA},
//          3 -> {PBCTL, DDRB, ORB}, 4 -> {model130, Atarimax off, bank[6:0], 0, cartridge type[2:0]}
//   4 CTL  wdata[0] 0 -> 1: restore mode on (ends by itself at the first opcode fetch after an RTI),
//          wdata[1] = CPU-only reset (level), wdata[2] = frame buffer hold; rdata[0] = restore mode
//   others: done at once, rdata 0
//-----------------------------------------------------------------------------
reg  [1:0] sreq_s;
reg        fb_hold;
wire [1:0] fb_newest;
always @(posedge clk_sd) begin
    frz_sd <= {frz_sd[0], a_frozen};
    rm_sd  <= {rm_sd[0], a_rmode};
end
always @(posedge clk_sd or negedge rst_sd_n)
    if (!rst_sd_n) begin
        sreq_s     <= 2'b00;
        snap_ack   <= 1'b0;
        snap_rdata <= 32'd0;
        fb_hold    <= 1'b0;
        s_rm       <= 1'b0;
        s_rst      <= 1'b0;
        x_req      <= 1'b0;
        x_we       <= 1'b0;
        x_addr     <= 21'd0;
        x_din      <= 8'd0;
    end else begin
        sreq_s <= {sreq_s[0], snap_req};
        if (x_req) begin
            if (x_ack) begin
                x_req      <= 1'b0;
                snap_rdata <= {24'd0, x_dout};
                snap_ack   <= sreq_s[1];
            end
        end else if (sreq_s[1] != snap_ack)
            case (snap_cmd)
                4'd1, 4'd2: begin
                    x_req  <= 1'b1;
                    x_we   <= snap_cmd == 4'd2;
                    x_addr <= (fb_hold && snap_cmd == 4'd1) ? {1'b0, 3'd2 + {1'b0, fb_newest}, snap_addr[16:0]} :
                              l_mctl[23]                     ? {1'b1, l_mctl[21:20], snap_addr} :    // cartridge area
                                                               {3'b000, snap_addr};
                    x_din  <= snap_wdata[7:0];
                end
                4'd3: begin
                    case (snap_addr[2:0])
                        3'd0:    snap_rdata <= a_regs[31:0];
                        3'd1:    snap_rdata <= a_regs[63:32];
                        3'd2:    snap_rdata <= {8'd0, a_pia[23:0]};
                        3'd3:    snap_rdata <= {8'd0, a_pia[47:24]};
                        default: snap_rdata <= {19'd0, model130, a_cart};
                    endcase
                    snap_ack <= sreq_s[1];
                end
                4'd4: begin
                    s_rm       <= snap_wdata[0];
                    s_rst      <= snap_wdata[1];
                    fb_hold    <= snap_wdata[2];
                    snap_rdata <= {31'd0, rm_sd[1]};
                    snap_ack   <= sreq_s[1];
                end
                default: begin snap_rdata <= 32'd0; snap_ack <= sreq_s[1]; end
            endcase
    end

//-----------------------------------------------------------------------------
// Video: frame buffer -> OSD -> VGA
//-----------------------------------------------------------------------------
wire [17:0] f_rgb;
wire        f_hs, f_vs, f_act;
wire [3:0]  vr, vg, vb;
wire        vhs, vvs;

atari_fb #(.PAL_HEX("rtl/atari_palette.hex")) u_fb (
    .clk      (clk),
    .rst_n    (por_n),
    .px_stb   (px_stb),
    .px_cc    (px_cc),
    .px_vc    (px_vc),
    .px0      (px0),
    .px1      (px1),
    .hold     (fb_hold),
    .newest   (fb_newest),
    .clk_sd   (clk_sd),
    .rst_sd_n (rst_sd_n),
    .m_req    (fb_req),
    .m_we     (fb_we),
    .m_addr   (fb_addr),
    .m_wdata  (fb_wdata),
    .m_ack    (fb_ack),
    .m_rdata  (fb_rdata),
    .pclk     (pclk),
    .prst_n   (prst_n),
    .m60      (m60),
    .rgb      (f_rgb),
    .hsync    (f_hs),
    .vsync    (f_vs),
    .active   (f_act)
);

c64_video #(.FONT_HEX("../AMenu/rtl/menu_font.hex")) u_video (
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
    .vga_r     (vr),
    .vga_g     (vg),
    .vga_b     (vb),
    .vga_hs    (vhs),
    .vga_vs    (vvs)
);

//-----------------------------------------------------------------------------
// Syncs off at each start until 2 s after the Atari left reset (as L64): the
// monitor first sees the mode with a picture, so its auto-adjust finds the picture's edges
//-----------------------------------------------------------------------------
localparam [24:0] SP_RUN = 25'd25_000_000;                              // 2 s of ruclk (12.5 MHz)
reg  [2:0]  run_s = 3'd0;
reg  [24:0] sp_cnt = 25'd0;
reg         sp_off = 1'b1;              // syncs off
always @(posedge ruclk) begin
    run_s <= {run_s[1:0], a_run};
    if (!run_s[2]) begin
        sp_cnt <= 25'd0;
        sp_off <= 1'b1;
    end else if (sp_cnt != SP_RUN)
        sp_cnt <= sp_cnt + 25'd1;
    else
        sp_off <= 1'b0;
end

reg [1:0] sp_s = 2'b11;
always @(posedge pclk) begin            // the I/O registers of the VGA pins
    sp_s   <= {sp_s[0], sp_off};
    VGA_R  <= sp_s[1] ? 4'd0 : vr;
    VGA_G  <= sp_s[1] ? 4'd0 : vg;
    VGA_B  <= sp_s[1] ? 4'd0 : vb;
    if (!sp_s[1]) begin                 // off: the syncs keep their level (no edges)
        VGA_HS <= vhs;
        VGA_VS <= vvs;
    end
end

//-----------------------------------------------------------------------------
// LED (active low): on for the first 2.7 s after start; fast blink = ROM image missing
//-----------------------------------------------------------------------------
reg [22:0] blink;
reg        led;
always @(posedge clk) begin
    blink <= blink + 23'd1;
    led   <= bad_image ? blink[21] : 1'b1;
end
assign LEDR = led & up_cnt[25];

endmodule

`default_nettype wire
