/* LNES -- Nintendo Entertainment System (NTSC) on the QMTECH Cyclone IV EP4CE15 core board with */
/* the Extra_PCB_CycloneIV I/O board (same pins as the other machines); the 10CL025 board's project */
/* uses the same sources (../10cl025). */
/* */
/* Application image of the machine menu (AMenu/, docs/PLAN.md), installed from the SD card into */
/* one of the flash's three machine positions. The NES has no system ROM: nothing is loaded */
/* from the flash. A game (.nes file) is written into the SDRAM by the ESP32 (nes.cpp). */
/* */
/* Clocks: */
/* nes_pll    clk    21.449 MHz  the whole machine (4 clk per PPU dot, 12 per CPU cycle) */
/* clk_sd 85.795 MHz  4 x clk, aligned: SDRAM, tape loader + ESP32 link, audio, */
/* frame buffer */
/* clk_sdo 85.795 MHz delayed: SDRAM clock (inverted, DDIO), as the other machines */
/* atari_vpll pclk   25.208 MHz  VGA pixel clock: 640 x 480 @ 60 Hz (the NES is a 60 Hz machine; */
/* no 50 Hz mode) */
/* */
/* Controls: */
/* KEY0 (W13)    reset everything (the ESP32 restarts; the game has to be loaded again) */
/* Ctrl+Alt+Del  back to the machine menu, as KEY1 (when the keys are released) */
/* KEY1 (Y13)    back to the machine menu (reconfigures to the factory image) */
/* joysticks     DB9-1 = controller 1, DB9-2 = controller 2: the four directions and the button = A */
/* (ESP32 F4 menu, mode bit 0: the two swapped; bit 1: the button is B, and A is on the keyboard) */
/* keyboard      nes_keyboard.v: the buttons the joysticks do not have (B, Select, Start), Alt+F5 Reset */
/* LED           on 2.7 s after the start */
`default_nettype none

module LNES #(
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

/* DDS step of the Bluetooth audio's sample clock enable: 3.5469 / 85.795 * 2^32 */
localparam [32:0] BT_DDS_STEP = 33'd177559750;
/* snapshot command: memory write */
localparam [3:0] SNAP_MWR = 4'd2;
/* SDRAM bank (128 KB units) of the first frame buffer */
localparam [2:0] FB_BANK0 = 3'd2;
/* MCTL bits 30:27: the 256 KB page of the ESP32's memory commands */
localparam integer PAGE_LSB = 27;
localparam integer PAGE_BITS = 4;
/* MSTAT / MCLR bit 0: the cartridge RAM was written */
localparam integer ST_WRAM = 0;

localparam integer CLK_HZ      = 21448864;
localparam integer KBD_WAIT_MS = 1500;

/* Clocks and resets */
wire clk, clk_sd, clk_sdo, locked, pclk, vlocked;

nes_pll #(.SD_PHASE_PS(SD_PHASE_PS)) u_pll (
    .inclk0 (CLOCK_50),
    .c0     (clk),
    .c1     (clk_sd),
    .c2     (clk_sdo),
    .locked (locked)
);

/* the VGA pixel clock: only the 60 Hz output of the PLL is used */
atari_vpll u_vpll (
    .inclk0 (CLOCK_50),
    .c0     (),
    .c1     (pclk),
    .locked (vlocked)
);

/* por_n: power-up only (keyboard, frame buffer writer); rst_n: the machine (+ KEY0); rst_sd_n: */
/* clk_sd (+ KEY0) */
wire       kbd_cad;
reg  [2:0] por_sr, rst_sr, rsd_sr;
reg        cad_q;
/* the reset of the key: the button and the PLL lock */
wire       key_arst_n = RESET_N & locked;

always @(posedge clk or negedge locked)
    if (!locked)
    begin
/* held */
        por_sr <= 3'b000;
    end
    else
    begin
/* released after three clocks */
        por_sr <= {por_sr[1:0], 1'b1};
    end
wire por_n = por_sr[2];

/* Ctrl+Alt+Del, taken into the machine's clock domain */
always @(posedge clk or negedge por_n)
    if (!por_n)
    begin
        cad_q <= 1'b0;
    end
    else
    begin
/* as the keyboard reports it */
        cad_q <= kbd_cad;
    end

always @(posedge clk or negedge key_arst_n)
    if (!key_arst_n)
    begin
/* held */
        rst_sr <= 3'b000;
    end
    else
    begin
/* released after three clocks */
        rst_sr <= {rst_sr[1:0], 1'b1};
    end
wire rst_n = rst_sr[2];

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

/* the pixel domain's reset */
reg [2:0] prst_sr;
always @(posedge pclk or negedge vlocked)
    if (!vlocked)
    begin
/* asserted; released after three pixel clocks */
        prst_sr <= 3'b000;
    end
    else
    begin
        prst_sr <= {prst_sr[1:0], 1'b1};
    end
wire prst_n = prst_sr[2];

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

/* Keyboard (power-up reset only) */
wire [3:0]  k_btn1, k_btn2;
wire        k_reset, kb_seen;
/* keys for the loader, the raw keyboard word, the OSD state */
wire [17:0] lkeys;
wire [31:0] kb_raw;
wire        l_osd_on, l_osd_full;

/* the keyboard */
nes_keyboard #(.CLK_HZ(CLK_HZ)) u_kbd (
    .clk       (clk),
    .rst_n     (por_n),
    .rx        (KB_OUT & KB_IN),
    .block     (l_osd_on & l_osd_full),
    .btn1      (k_btn1),
    .btn2      (k_btn2),
    .reset_key (k_reset),
    .lkeys     (lkeys),
    .f8_tgl    (),
    .cad       (kbd_cad),
    .seen      (kb_seen),
    .raw       (kb_raw)
);

/* Controllers: the joystick gives the directions and one button, the keyboard the rest. */
/* Mode (tape loader INTPOS[29:28], ESP32 F4 menu): bit 0 = the two joysticks swapped, */
/* bit 1 = the joystick's button is B (A is then the keyboard's key only). */
wire [1:0] joy_mode;
reg  [1:0] jm_s1, jm_s;
/* {fire, right, left, down, up}, active low */
reg  [4:0] j1_s1, j1, j2_s1, j2;
always @(posedge clk)
begin
    jm_s1 <= joy_mode;
/* the mode, synchronised */
    jm_s  <= jm_s1;
/* the two joysticks, synchronised */
    j1_s1 <= {JOY1_FIRE_N, JOY1_RIGHT_N, JOY1_LEFT_N, JOY1_DOWN_N, JOY1_UP_N};
    j1    <= j1_s1;
    j2_s1 <= {JOY2_FIRE_N, JOY2_RIGHT_N, JOY2_LEFT_N, JOY2_DOWN_N, JOY2_UP_N};
/* the second joystick */
    j2    <= j2_s1;
end
wire [4:0] stick1 = jm_s[0] ? ~j2 : ~j1;
wire [4:0] stick2 = jm_s[0] ? ~j1 : ~j2;
/* the joystick's button as A or as B */
wire       s1_a = stick1[4] && !jm_s[1];
wire       s1_b = stick1[4] && jm_s[1];
wire       s2_a = stick2[4] && !jm_s[1];
/* the second controller's button */
wire       s2_b = stick2[4] && jm_s[1];
/* {Right, Left, Down, Up, Start, Select, B, A} */
wire [7:0] pad1 = {stick1[3:0], k_btn1[3:2], k_btn1[1] | s1_b, k_btn1[0] | s1_a};
wire [7:0] pad2 = {stick2[3:0], k_btn2[3:2], k_btn2[1] | s2_b, k_btn2[0] | s2_a};

/* The machine */
wire        px_stb, px_eof, a_run, wram_tgl;
wire [7:0]  px_x, px_y;
wire [5:0]  px_c;
/* emphasis bits, sound */
wire [2:0]  px_e;
wire [9:0]  a_audio;
/* the machine-specific registers of the tape loader */
wire        l_reload;
wire [31:0] l_mctl, l_mclr;
wire        l_mclr_we;
/* the frame buffer's SDRAM port */
wire        fb_req, fb_we, fb_ack;
wire [21:0] fb_addr;
wire [15:0] fb_wdata, fb_rdata;
/* the ESP32's memory port */
reg         x_req, x_we;
reg  [21:0] x_addr;
reg  [7:0]  x_din;
/* its answer */
wire        x_ack;
wire [7:0]  x_dout;

nes_system #(.PULSE_HEX("../ep4_ce15/rtl/nes_pulse.hex"), .TND_HEX("../ep4_ce15/rtl/nes_tnd.hex")) u_sys (
    .clk       (clk),
    .rst_n     (rst_n),
    .clk_sd    (clk_sd),
    .rst_sd_n  (rst_sd_n),
    .cart      (l_mctl),
    .reset_key (k_reset),
    .pad1      (pad1),
    .pad2      (pad2),
    .sd_cke    (DRAM_CKE),
    .sd_cs_n   (DRAM_CS_N),
    .sd_ras_n  (DRAM_RAS_N),
    .sd_cas_n  (DRAM_CAS_N),
    .sd_we_n   (DRAM_WE_N),
    .sd_ba     (DRAM_BA),
    .sd_a      (DRAM_ADDR),
    .sd_dqm    ({DRAM_UDQM, DRAM_LDQM}),
    .sd_dq_o   (dq_o),
    .sd_dq_oe  (dq_oe),
    .sd_dq_i   (DRAM_DQ),
    .px_stb    (px_stb),
    .px_x      (px_x),
    .px_y      (px_y),
    .px_c      (px_c),
    .px_e      (px_e),
    .px_eof    (px_eof),
    .audio     (a_audio),
    .run_o     (a_run),
    .wram_tgl  (wram_tgl),
    .fb_req    (fb_req),
    .fb_we     (fb_we),
    .fb_addr   (fb_addr),
    .fb_wdata  (fb_wdata),
    .fb_ack    (fb_ack),
    .fb_rdata  (fb_rdata),
    .x_req     (x_req),
    .x_we      (x_we),
    .x_addr    (x_addr),
    .x_din     (x_din),
    .x_ack     (x_ack),
    .x_dout    (x_dout)
);

/* MSTAT bit 0: the game wrote its cartridge RAM since the ESP32 last cleared the bit */
/* (MCLR bit 0); the ESP32 saves battery RAM to the card from it */
reg  [1:0]  wt_s;
reg         wram_dirty;
always @(posedge clk_sd or negedge rst_sd_n)
/* at reset */
    if (!rst_sd_n)
    begin
        wt_s       <= 2'b00;
        wram_dirty <= 1'b0;
    end
    else
    begin
/* the write toggle, synchronised */
        wt_s <= {wt_s[0], wram_tgl};
/* cleared by the ESP32, set by a write (the write wins) */
        if (l_mclr_we && l_mclr[ST_WRAM])
        begin
            wram_dirty <= 1'b0;
        end
        if (wt_s[1] != wt_s[0])
        begin
/* a write was seen */
            wram_dirty <= 1'b1;
        end
    end
wire [31:0] l_mstat = {31'd0, wram_dirty};

/* Audio: the sound chip's mix -> sigma-delta pin and Bluetooth I2S */
reg [9:0]  snd;
always @(posedge clk_sd) snd <= a_audio;

wire audio;
/* the sigma-delta DAC of the audio pin */
sd_dac #(.W(10)) u_dac (
    .clk   (clk_sd),
    .rst_n (rst_sd_n),
    .din   (snd),
    .dout  (audio)
);

/* bt_i2s low-passes at its "AY" sample rate: 3.5469 MHz from a DDS, as in the other machines */
reg  [31:0] bt_dds;
reg         bt_cen;
wire [32:0] bt_next = {1'b0, bt_dds} + BT_DDS_STEP;
/* the DDS of the Bluetooth sample clock enable */
always @(posedge clk_sd)
begin
    bt_dds <= bt_next[31:0];
    bt_cen <= bt_next[32];
end

/* the Bluetooth audio stream */
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
/* no beeper pin */
assign AUDIO_BEEP = 1'b0;

/* Tape loader hardware + ESP32 link (clk_sd): OSD, keys, Bluetooth UART, F4 joystick mode, */
/* memory commands. Core ID 4E45_0001 ("NE"). */
wire       osd_we;
wire [9:0] osd_addr;
wire [7:0] osd_data;
/* the snapshot port: here only the memory commands */
wire       snap_req;
wire [3:0] snap_cmd;
wire [17:0] snap_addr;
/* its data and answers */
wire [31:0] snap_wdata;
reg        snap_ack;
reg [31:0] snap_rdata;

/* the loader's hardware */
tape_loader #(.BAUD_DIV(745), .CORE_ID(32'h4E45_0001)) u_tape (
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
    .fl_miso     (1'b1),
    .reload      (l_reload),
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

/* Memory commands (tape loader SNAPCMD / SNAPDAT; codes as the other machines): */
/* 1 MRD  read the SDRAM byte at MCTL[30:27] * 256 KB + addr[17:0] -> rdata[7:0]; while the frame */
/* buffer hold is on (CTL[2], screenshots): the byte at addr[16:0] of the newest frame buffer */
/* 2 MWR  write wdata[7:0] there */
/* 4 CTL  wdata[2] = frame buffer hold; rdata 0 */
/* others: done at once, rdata 0 */
/* (the memory map is in nes_system.v: RAM, cartridge RAM, pattern and program memory) */
reg  [1:0] sreq_s;
reg        fb_hold;
wire [1:0] fb_newest;
/* the memory commands */
always @(posedge clk_sd or negedge rst_sd_n)
    if (!rst_sd_n)
    begin
        sreq_s     <= 2'b00;
/* no answer yet */
        snap_ack   <= 1'b0;
        snap_rdata <= 32'd0;
        fb_hold    <= 1'b0;
/* no memory access */
        x_req      <= 1'b0;
        x_we       <= 1'b0;
        x_addr     <= 22'd0;
/* no data */
        x_din      <= 8'd0;
    end
    else
    begin
/* the request, synchronised */
        sreq_s <= {sreq_s[0], snap_req};
        if (x_req)
        begin
            if (x_ack)
            begin
/* a memory access ends: the byte is the answer */
                x_req      <= 1'b0;
                snap_rdata <= {24'd0, x_dout};
                snap_ack   <= sreq_s[1];
            end
        end
/* a new command */
        else if (sreq_s[1] != snap_ack)
        begin
            case (snap_cmd)
                4'd1, SNAP_MWR:
                begin
/* the request to the machine's memory port */
                    x_req  <= 1'b1;
                    x_we   <= snap_cmd == SNAP_MWR;
                    x_addr <= (fb_hold && snap_cmd == 4'd1) ? {2'b00, FB_BANK0 + {1'b0, fb_newest}, snap_addr[16:0]} :
                                                              {l_mctl[PAGE_LSB +: PAGE_BITS], snap_addr};
/* the byte to write */
                    x_din  <= snap_wdata[7:0];
                end
/* the control word */
                4'd4:
                begin
                    fb_hold    <= snap_wdata[2];
                    snap_rdata <= 32'd0;
/* done at once */
                    snap_ack   <= sreq_s[1];
                end
                default:
                begin
                    snap_rdata <= 32'd0;
/* unknown commands answer 0 */
                    snap_ack   <= sreq_s[1];
                end
            endcase
        end
    end

/* Video: frame buffer -> OSD -> VGA */
wire [11:0] f_rgb;
wire        f_hs, f_vs, f_act;
wire [3:0]  vr, vg, vb;
/* the VGA signals before the sync hold */
wire        vhs, vvs;

nes_fb #(.PAL_HEX("../ep4_ce15/rtl/nes_palette.hex")) u_fb (
    .clk      (clk),
    .rst_n    (por_n),
    .px_stb   (px_stb),
    .px_x     (px_x),
    .px_y     (px_y),
    .px_c     (px_c),
    .px_e     (px_e),
    .px_eof   (px_eof),
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
    .rgb      (f_rgb),
    .hsync    (f_hs),
    .vsync    (f_vs),
    .active   (f_act)
);

c64_video #(.FONT_HEX("../../AMenu/ep4_ce15/rtl/menu_font.hex")) u_video (
    .clk       (pclk),
    .red       ({f_rgb[11:8], 2'b00}),
    .green     ({f_rgb[7:4], 2'b00}),
    .blue      ({f_rgb[3:0], 2'b00}),
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

/* Syncs off for 2 s after the start (as the other machines): the monitor first sees the mode */
/* with a picture (the ESP32's file list), so its auto-adjust finds the picture's edges */
/* 2 s of ruclk (12.5 MHz) */
localparam [24:0] SP_RUN = 25'd25_000_000;
reg  [2:0]  run_s = 3'd0;
reg  [24:0] sp_cnt = 25'd0;
/* syncs off */
reg         sp_off = 1'b1;
always @(posedge ruclk)
begin
    run_s <= {run_s[1:0], prst_n};
/* the video does not run yet: syncs off */
    if (!run_s[2])
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
always @(posedge pclk)
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
