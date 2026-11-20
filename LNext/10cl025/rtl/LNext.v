/* LNext -- ZX Spectrum Next on the QMTECH Cyclone 10 LP 10CL025 core board with the */
/* Extra_PCB_CycloneIV I/O board (same pins as the other machines). This machine needs the */
/* larger FPGA: there is no EP4CE15 build. */
/* */
/* The machine itself is the Spectrum Next core in its MiSTer port (../../ZXNEXT, unchanged): */
/* zxnext_top with the CPU's memory port on wait states and Layer 2's own memory port. Ours are */
/* the memories for this FPGA (next_bram.vhd), the SDRAM (next_sdram.v), the keyboard, the video */
/* output and this top level. */
/* */
/* Application image of the machine menu (AMenu/, docs/PLAN.md), installed from the SD card into */
/* one of the flash's three machine positions. The Next starts from its SD card: the core's boot */
/* ROM loads TBBLUE.FW, which loads the ROMs and NextZXOS. The card is on the ESP32, so the core */
/* talks to an SD card made of logic (ZXNEXT/sys/sd_card.sv) and the ESP32 moves the sectors */
/* between it and the real card (ESP32/vN/src/next.cpp, rtl/next_sd.v; the card's size comes */
/* through the MCLR register). */
/* */
/* Clocks: next_pll: clk28 the machine, clk14 / clk7 its pixel clocks, clk_sd 112 MHz (SDRAM, */
/* audio DAC), clk_sdo the SDRAM clock (inverted, DDIO), as the other machines; */
/* next_pll2: clk56 the tape loader with the ESP32 link and the keyboard, asynchronous to the rest. */
/* */
/* Controls: */
/* KEY0          reset everything (the ESP32 restarts, the Next starts again from the card) */
/* Ctrl+Alt+Del  back to the machine menu, as KEY1 (when the keys are released) */
/* KEY1          back to the machine menu (reconfigures to the factory image) */
/* joysticks     DB9-1 = the Next's left joystick, DB9-2 its right one: directions and one button (B); */
/*               the buttons C, A and Start are keys: Insert, Home, Page Up for the left joystick, */
/*               Delete, End, Page Down for the right one */
/* keyboard      next_keyboard.v: F1 hard reset, F4 soft reset, F6 CPU speed, F8 50 / 60 Hz, */
/*               F9 Multiface NMI, F10 DivMMC NMI; F3 Bluetooth menu */
/* LED           on 2.7 s after the start */
`default_nettype none

module LNext #(
    parameter         SD_PHASE_PS = "1250"
)(
    input  wire        CLOCK_50,
    input  wire        RESET_N,
    input  wire        KEY1,
    output wire        LEDR,

/* SDRAM */
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

/* I/O board: VGA, 4 bits per colour (binary-weighted DAC, bit 3 = MSB) */
    output reg  [3:0]  VGA_R,
    output reg  [3:0]  VGA_G,
    output reg  [3:0]  VGA_B,
    output reg         VGA_HS,
    output reg         VGA_VS,

/* I/O board: keyboard module J5 (USB-HID -> UART); both lines are inputs (pulled up), RX = KB_OUT & KB_IN */
    input  wire        KB_OUT,
    input  wire        KB_IN,

/* SPI link from the ESP32 system controller; the SD card is on the ESP32 */
    input  wire        ESP_SCK,
    input  wire        ESP_MOSI,
    input  wire        ESP_CS_N,
    output wire        ESP_MISO,
    output wire        ESP_IRQ,

/* I/O board: audio jack, joysticks (DB9, active low) */
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

/* ESP32 Bluetooth audio (esp32/) */
/* I2S bit clock from the ESP32 (master) */
    input  wire        BT_BCLK,
/* I2S word select from the ESP32 */
    input  wire        BT_LRCK,
/* I2S data to the ESP32 */
    output wire        BT_DATA,
/* UART to the ESP32 (its RX2, GPIO16) */
    output wire        BT_TX,
/* UART from the ESP32 (its TX2, GPIO17) */
    input  wire        BT_RX
);

/* what the core reports as its machine and board (as the MiSTer port's defaults) */
localparam [7:0] MACHINE_ID = 8'hDA;
localparam [3:0] BOARD_ISSUE = 4'h0;
/* T-states for the tape player: clocks of 28 MHz per half T-state toggle at 3.5 MHz */
localparam [3:0] T_DIV = 4'd8;
/* joystick mode bit 0 (ESP32 F4 menu): the two joysticks swapped */
localparam integer JM_SWAP = 0;
/* the keyboard's joystick buttons (next_keyboard.v pad): the left joystick's C, A, Start, then the right one's */
localparam integer PAD_INSERT = 0;
localparam integer PAD_HOME = 1;
localparam integer PAD_PAGE_UP = 2;
/* the right joystick's */
localparam integer PAD_DELETE = 3;
localparam integer PAD_END = 4;
localparam integer PAD_PAGE_DOWN = 5;

localparam integer CLK56_HZ = 56000000;

/* Clocks and resets */
wire clk28, clk14, clk7, clk_sd, clk_sdo, locked1;
wire clk56, locked2;

next_pll #(.SD_PHASE_PS(SD_PHASE_PS)) u_pll (
    .inclk0 (CLOCK_50),
    .c0     (clk28),
    .c1     (clk14),
    .c2     (clk7),
    .c3     (clk_sd),
    .c4     (clk_sdo),
    .locked (locked1)
);

next_pll2 u_pll2 (
    .inclk0 (CLOCK_50),
    .c0     (clk56),
    .locked (locked2)
);

/* por56_n: power-up only (keyboard); rst56_n: the tape loader (+ KEY0); rst28: the machine */
/* (+ KEY0), active high; rst_sd_n: clk_sd (+ KEY0) */
wire       kbd_cad;
reg  [2:0] por_sr, r56_sr, r28_sr, rsd_sr;
/* the reset of the key: the button and the PLLs' locks */
wire       key_arst_n = RESET_N & locked1 & locked2;

always @(posedge clk56 or negedge locked2)
    if (!locked2)
    begin
/* held */
        por_sr <= 3'b000;
    end
    else
    begin
/* released after three clocks */
        por_sr <= {por_sr[1:0], 1'b1};
    end
wire por56_n = por_sr[2];

always @(posedge clk56 or negedge key_arst_n)
    if (!key_arst_n)
    begin
/* held */
        r56_sr <= 3'b000;
    end
    else
    begin
/* released after three clocks */
        r56_sr <= {r56_sr[1:0], 1'b1};
    end
wire rst56_n = r56_sr[2];

always @(posedge clk28 or negedge key_arst_n)
    if (!key_arst_n)
    begin
/* held */
        r28_sr <= 3'b000;
    end
    else
    begin
/* released after three clocks */
        r28_sr <= {r28_sr[1:0], 1'b1};
    end
wire rst28 = !r28_sr[2];

always @(posedge clk_sd or negedge key_arst_n)
/* the SDRAM domain's reset */
    if (!key_arst_n)
    begin
        rsd_sr <= 3'b000;
    end
    else
    begin
        rsd_sr <= {rsd_sr[1:0], 1'b1};
    end
/* released */
wire rst_sd_n = rsd_sr[2];

/* Ctrl+Alt+Del for the remote update block (its own synchroniser there) */
wire cad_q = kbd_cad;

/* SDRAM clock = inverted clk_sdo through a DDIO output, as LSpectrum / DDR_TEST */
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
/* tri-state data pins */
assign DRAM_DQ = dq_oe ? dq_o : 16'hzzzz;

/* Remote update block: KEY1 / Ctrl+Alt+Del back to the machine menu (as L64) */
reg  [1:0]  ru_div = 2'd0;
always @(posedge CLOCK_50) ru_div <= ru_div + 2'd1;
wire ruclk = ru_div[1];

/* KEY1: synchroniser, hold time counter */
reg  [2:0]  k1_s;
reg  [17:0] k1_cnt;
/* the reconfiguration request; the watchdog's reset */
reg         ru_reconfig = 1'b0;
reg  [9:0]  wd_cnt = 10'd0;
always @(posedge ruclk) wd_cnt <= wd_cnt + 10'd1;
/* watchdog reset every 82 us: it never expires, whatever the menu set */
wire        wd_reset = wd_cnt[9];
/* KEY1 held >= 21 ms; the request goes out when it is released */
reg         k1_held = 1'b0;
reg  [2:0]  cad_s = 3'd0;
/* Ctrl+Alt+Del: the same request when the keys are released */
reg         cad_held = 1'b0;
/* 2.7 s after configuration: LED on (shows the machine started) */
reg  [25:0] up_cnt = 26'd0;
always @(posedge ruclk)
begin
    k1_s <= {k1_s[1:0], KEY1};
/* the hold time counts while the key is down */
    if (k1_s[2])
    begin
        k1_cnt <= 18'd0;
    end
    else if (!(&k1_cnt))
    begin
/* held for 21 ms */
        k1_cnt <= k1_cnt + 18'd1;
    end
    if (&k1_cnt)
    begin
        k1_held <= 1'b1;
    end
/* Ctrl+Alt+Del */
    cad_s <= {cad_s[1:0], cad_q};
    if (cad_s[2])
    begin
        cad_held <= 1'b1;
    end
/* reconfigure when the key or the keys are released */
    ru_reconfig <= ru_reconfig | (k1_held && k1_s[2]) | (cad_held && !cad_s[2]);
    if (!up_cnt[25])
    begin
        up_cnt <= up_cnt + 26'd1;
    end
end

/* the remote update block: back to the factory image (the menu) */
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

/* Keyboard (power-up reset only), in the tape loader's clock */
wire [10:0] ps2_key56;
/* keys for the loader, the raw keyboard word, the OSD state */
wire [17:0] lkeys;
wire [31:0] kb_raw;
/* the joysticks' extra buttons from the keyboard: Page Down, End, Delete, Page Up, Home, Insert */
wire [5:0]  kbd_pad;
wire        l_osd_on, l_osd_full, kb_seen;

/* the keyboard */
next_keyboard #(.CLK_HZ(CLK56_HZ)) u_kbd (
    .clk     (clk56),
    .rst_n   (por56_n),
    .rx      (KB_OUT & KB_IN),
    .block   (l_osd_on & l_osd_full),
    .ps2_key (ps2_key56),
    .pad     (kbd_pad),
    .lkeys   (lkeys),
    .cad     (kbd_cad),
    .seen    (kb_seen),
    .raw     (kb_raw)
);

/* a key event into the machine's clock: the data is there before its strobe toggles */
reg  [1:0]  ps2_s;
reg  [10:0] ps2_key;
always @(posedge clk28)
begin
    ps2_s <= {ps2_s[0], ps2_key56[10]};
/* the strobe changed: the event's data is taken with it */
    if (ps2_s[1] != ps2_key[10])
    begin
        ps2_key <= {ps2_s[1], ps2_key56[9:0]};
    end
end

/* Joysticks (DB9, active low): directions and one button. Mode bit 0 (tape loader */
/* INTPOS[28], ESP32 F4 menu) swaps the two. Three more buttons of each come from the keyboard */
/* (next_keyboard.v): Insert / Home / Page Up = the left joystick's C, A and Start (Kempston */
/* fire 2 and fire 3; Start in the Mega Drive pad modes), Delete / End / Page Down the right one's. */
wire [1:0] joy_mode;
reg  [1:0] jm_s1, jm_s;
/* {fire, up, down, left, right}, active low */
reg  [4:0] j1_s1, j1, j2_s1, j2;
/* the keys' buttons, synchronised: {Start, A, C} of each joystick, active high */
reg  [5:0] pad_s1, pad_s;
always @(posedge clk28)
begin
    jm_s1 <= joy_mode;
/* the mode, synchronised */
    jm_s  <= jm_s1;
/* the two joysticks, synchronised */
    j1_s1 <= {JOY1_FIRE_N, JOY1_UP_N, JOY1_DOWN_N, JOY1_LEFT_N, JOY1_RIGHT_N};
    j1    <= j1_s1;
    j2_s1 <= {JOY2_FIRE_N, JOY2_UP_N, JOY2_DOWN_N, JOY2_LEFT_N, JOY2_RIGHT_N};
/* the second joystick */
    j2    <= j2_s1;
/* the buttons on the keyboard */
    pad_s1 <= kbd_pad;
    pad_s  <= pad_s1;
end
/* the core's joystick word, active high: bit 7 = Start, 6 = A, 5 = C, 4 = B, bits 3:0 = up, */
/* down, left, right; the keys stay with their side */
wire [2:0]  pad_l = {pad_s[PAD_PAGE_UP], pad_s[PAD_HOME], pad_s[PAD_INSERT]};
wire [2:0]  pad_r = {pad_s[PAD_PAGE_DOWN], pad_s[PAD_END], pad_s[PAD_DELETE]};
wire [11:0] joy_l = {4'd0, pad_l, jm_s[JM_SWAP] ? ~j2 : ~j1};
wire [11:0] joy_r = {4'd0, pad_r, jm_s[JM_SWAP] ? ~j1 : ~j2};

/* The machine: held in reset until the ESP32 has put the card in (it starts from the card) */
wire        rst_m;
wire [20:0] ram_a_addr, ram_b_addr;
wire        ram_a_req, ram_a_rd_n, ram_a_wait, ram_b_req;
/* the memory ports' data */
wire [7:0]  ram_a_dout, ram_a_din, ram_b_din;
wire [1:0]  cpu_speed;
/* the core's SD card port */
wire        sd_cs0_n, sd_cs1_n, sd_sck, sd_mosi, sd_miso;
/* sound, picture */
wire [11:0] aud_l, aud_r;
wire [8:0]  rgb;
wire        vs_n, hs_n, vb_n, hb_n;
/* the tape player's level, the CPU held for the card */
wire        tape_on, tape_lvl, sd_wait;

zxnext_top u_next (
    .g_machine_id  (MACHINE_ID),
    .g_board_issue (BOARD_ISSUE),
    .CLK_28        (clk28),
    .CLK_14        (clk14),
    .CLK_7         (clk7),
    .HW_RESET      (rst_m),
    .SW_RESET      (rst_m),
    .CPU_SPEED     (cpu_speed),
    .CPU_SPEED_SW  (1'b0),
    .CPU_WAIT      (ram_a_wait | sd_wait),
    .RAM_A_ADDR    (ram_a_addr),
    .RAM_A_REQ     (ram_a_req),
    .RAM_A_RD_n    (ram_a_rd_n),
    .RAM_A_DI      (ram_a_din),
    .RAM_A_DO      (ram_a_dout),
    .RAM_B_ADDR    (ram_b_addr),
    .RAM_B_REQ     (ram_b_req),
    .RAM_B_DI      (ram_b_din),
    .ps2_key       (ps2_key),
    .ps2_mouse     (25'd0),
    .ps2_mouse_ext (8'd0),
    .sd_cs0_n_o    (sd_cs0_n),
    .sd_cs1_n_o    (sd_cs1_n),
    .sd_sclk_o     (sd_sck),
    .sd_mosi_o     (sd_mosi),
    .sd_miso_i     (sd_miso),
    .joy_left      (joy_l),
    .joy_right     (joy_r),
    .audio_L       (aud_l),
    .audio_R       (aud_r),
    .ear_port_i    (!(tape_on & tape_lvl)),
    .mic_port_o    (),
    .RGB           (rgb),
    .RGB_VS_n      (vs_n),
    .RGB_HS_n      (hs_n),
    .RGB_VB_n      (vb_n),
    .RGB_HB_n      (hb_n),
    .RGB_NTSC      (),
    .center        (1'b0),
    .i2c_scl_o     (),
    .i2c_sda_o     (),
    .i2c_sda_i     (1'b1),
    .uart_rx_i     (1'b1),
    .uart_tx_o     (),
    .esp_reset_o   ()
);

/* the SDRAM: the Next's 2 MB */
next_sdram u_ram (
    .clk        (clk_sd),
    .init       (!rst_sd_n),
    .sd_a       (DRAM_ADDR),
    .sd_ba      (DRAM_BA),
    .sd_dqm     ({DRAM_UDQM, DRAM_LDQM}),
    .sd_we_n    (DRAM_WE_N),
    .sd_cas_n   (DRAM_CAS_N),
    .sd_ras_n   (DRAM_RAS_N),
    .sd_cs_n    (DRAM_CS_N),
    .sd_cke     (DRAM_CKE),
    .sd_dq_o    (dq_o),
    .sd_dq_oe   (dq_oe),
    .sd_dq_i    (DRAM_DQ),
    .ram_a_addr (ram_a_addr),
    .ram_a_req  (ram_a_req),
    .ram_a_rd_n (ram_a_rd_n),
    .ram_a_di   (ram_a_dout),
    .ram_a_do   (ram_a_din),
    .ram_a_wait (ram_a_wait),
    .ram_b_addr (ram_b_addr),
    .ram_b_req  (ram_b_req),
    .ram_b_do   (ram_b_din)
);

/* The SD card of logic and the ESP32's side of it (next_sd.v) */
wire [31:0] l_mctl, l_mclr, l_mstat;
wire        l_mclr_we, card_in;
/* the card's size as the ESP32 wrote it (clk56; it does not change while a card is in) */
reg  [31:0] sd_sectors = 32'd0;
always @(posedge clk56)
    if (l_mclr_we)
    begin
        sd_sectors <= l_mclr;
    end

/* the snapshot port: here the sector buffer's bytes */
wire        snap_req, snap_ack;
wire [3:0]  snap_cmd;
wire [17:0] snap_addr;
/* its data and answers */
wire [31:0] snap_wdata, snap_rdata;

next_sd u_sd (
    .clk        (clk28),
    .rst        (rst28),
    .mctl       (l_mctl[1:0]),
    .sectors    (sd_sectors),
    .mstat      (l_mstat),
    .snap_req   (snap_req),
    .snap_cmd   (snap_cmd),
    .snap_addr  (snap_addr[8:0]),
    .snap_wdata (snap_wdata[7:0]),
    .snap_ack   (snap_ack),
    .snap_rdata (snap_rdata),
    .sd_cs_n    (sd_cs0_n),
    .sd_sck     (sd_sck),
    .sd_mosi    (sd_mosi),
    .sd_miso    (sd_miso),
    .sd_wait    (sd_wait),
    .card_in    (card_in)
);
/* without a card the machine stays in reset */
assign rst_m = rst28 | !card_in;

/* Audio: both channels mixed -> sigma-delta pin and Bluetooth I2S */
reg [11:0] snd;
wire [12:0] snd_sum = {1'b0, aud_l} + {1'b0, aud_r};
always @(posedge clk28) snd <= snd_sum[12:1];

wire audio;
/* the sigma-delta DAC of the audio pin */
sd_dac #(.W(12)) u_dac (
    .clk   (clk_sd),
    .rst_n (rst_sd_n),
    .din   (snd),
    .dout  (audio)
);

/* T-state toggle for the tape player (3.5 MHz, faster with the CPU up to 14 MHz) and the */
/* Bluetooth audio's sample clock enable (3.5 MHz) */
reg  [3:0] t_cnt = 4'd0, bt_cnt = 4'd0;
reg        cen_tgl = 1'b0, bt_cen = 1'b0;
/* clocks per T-state at the CPU's speed */
wire [3:0] t_len = cpu_speed == 2'd0 ? T_DIV : (cpu_speed == 2'd1 ? (T_DIV >> 1) : (T_DIV >> 2));
always @(posedge clk28)
begin
    if (t_cnt >= t_len - 4'd1)
    begin
        t_cnt   <= 4'd0;
        cen_tgl <= !cen_tgl;
    end
    else
    begin
        t_cnt <= t_cnt + 4'd1;
    end
/* one clock in eight */
    bt_cnt <= bt_cnt == T_DIV - 4'd1 ? 4'd0 : bt_cnt + 4'd1;
    bt_cen <= bt_cnt == 4'd0;
end

/* the Bluetooth audio stream */
bt_i2s u_bt (
    .clk      (clk28),
    .rst_n    (!rst28),
    .ay_cen   (bt_cen),
    .ay_sound (snd[11:2]),
    .beeper   (1'b0),
    .i2s_bclk (BT_BCLK),
    .i2s_lrck (BT_LRCK),
    .i2s_data (BT_DATA)
);

assign AUDIO_AY   = audio;
/* no beeper pin */
assign AUDIO_BEEP = 1'b0;

/* Loader hardware + ESP32 link (clk56; next_loader.v, LNext's copy of the tape loader): OSD, keys, */
/* Bluetooth UART, the machine word and the memory commands. Core ID 4E58_0001 ("NX"). */
wire       osd_we;
wire [9:0] osd_addr;
wire [7:0] osd_data;
/* the loader's hardware */
next_loader #(.CORE_ID(32'h4E58_0001)) u_tape (
    .clk         (clk56),
    .rst_n       (rst56_n),
    .keys        (lkeys),
    .keyraw      (kb_raw),
    .cen_tgl     (cen_tgl),
    .mic         (1'b0),
    .hold        (),
    .tape_on     (tape_on),
    .tape_turbo  (),
    .tape_lvl    (tape_lvl),
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
    .fl_miso     (1'b1),
    .reload      (),
    .mctl        (l_mctl),
    .mstat       (l_mstat),
    .mclr        (l_mclr),
    .mclr_we     (l_mclr_we),
    .snap_freeze (),
    .snap_req    (snap_req),
    .snap_cmd    (snap_cmd),
    .snap_addr   (snap_addr),
    .snap_wdata  (snap_wdata),
    .snap_frozen (1'b0),
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

/* Video: the core's picture, line-doubled, with the OSD */
wire [3:0]  vr, vg, vb;
wire        vhs, vvs;

next_video #(.FONT_HEX("../../AMenu/ep4_ce15/rtl/menu_font.hex")) u_video (
    .clk14     (clk14),
    .rgb       (rgb),
    .hs_n      (hs_n),
    .vs_n      (vs_n),
    .hb_n      (hb_n),
    .vb_n      (vb_n),
    .clk28     (clk28),
    .osd_wclk  (clk56),
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

/* Syncs off for 2 s after the start (as the other machines): the monitor first sees the mode */
/* with a picture (the ESP32's file list), so its auto-adjust finds the picture's edges */
/* 2 s of ruclk (12.5 MHz) */
localparam [24:0] SP_RUN = 25'd25_000_000;
reg  [2:0]  sp_run = 3'd0;
reg  [24:0] sp_cnt = 25'd0;
/* syncs off */
reg         sp_off = 1'b1;
always @(posedge ruclk)
begin
    sp_run <= {sp_run[1:0], !rst28};
/* the video does not run yet: syncs off */
    if (!sp_run[2])
    begin
        sp_cnt <= 25'd0;
        sp_off <= 1'b1;
    end
/* the delay counts */
    else if (sp_cnt != SP_RUN)
    begin
        sp_cnt <= sp_cnt + 25'd1;
    end
    else
    begin
        sp_off <= 1'b0;
    end
end

/* the sync-off flag in the pixel domain */
reg [1:0] sp_s = 2'b11;
/* the I/O registers of the VGA pins */
always @(posedge clk28)
begin
    sp_s   <= {sp_s[0], sp_off};
    VGA_R  <= sp_s[1] ? 4'd0 : vr;
/* green and blue */
    VGA_G  <= sp_s[1] ? 4'd0 : vg;
    VGA_B  <= sp_s[1] ? 4'd0 : vb;
/* off: the syncs keep their level (no edges) */
    if (!sp_s[1])
    begin
        VGA_HS <= vhs;
        VGA_VS <= vvs;
    end
end

/* LED (active low): on from 2.7 s after the start */
assign LEDR = up_cnt[25];

endmodule

/* other files keep the default net type */
`default_nettype wire
