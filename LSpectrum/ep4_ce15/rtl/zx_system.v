/* zx_system -- the ZX Spectrum 128 without clocks/PLLs and pin buffers */
/* */
/* clk   112 MHz system clock: SDRAM controller, ROM loader, CPU + bus, AY, */
/* keyboard, audio */
/* clk56 56 MHz from the same PLL (edges aligned with clk): tape loader hardware + ESP32 link */
/* pclk  pixel clock (25.208 or 27.009 MHz, mode50 selects the timing): video */
/* */
/* Resets: por_n (power-up only): keyboard, so held keys survive a machine */
/* reset; rst_n (+ KEY0): machine; rst56_n (+ KEY0): tape loader. */
/* */
/* After reset the ROM loader copies the ROMs from flash to SDRAM, then the */
/* CPU starts. Holding F1 while the CPU starts selects DiagROM. At power-up the */
/* CPU also waits for the first keyboard packet (at most KBD_WAIT_MS), so F1 */
/* held during power-up is seen. */
`default_nettype none

module zx_system #(
    parameter integer CLK_MHZ     = 112,
    parameter integer FLASH_DIV   = 4,
    parameter integer KBD_WAIT_MS = 1500,
/* OSD font: Spleen 8x16, shared with the menu */
    parameter         FONT_HEX = "../../AMenu/ep4_ce15/rtl/menu_font.hex",
/* simulation: CPU always at 28 MHz (faster boot) */
    parameter [0:0]   FORCE_TURBO = 1'b0
)(
    input  wire        clk,
/* synchronous to clk: power-up only */
    input  wire        por_n,
/* synchronous to clk: machine reset */
    input  wire        rst_n,
    input  wire        clk56,
/* synchronous to clk56 */
    input  wire        rst56_n,
    input  wire        pclk,
    input  wire        prst_n,
/* video mode (static while prst_n = 1) */
    input  wire        mode50,

/* board inputs (asynchronous) */
    input  wire        kbd_rx,
/* DB9-1: fire, up, down, left, right (active low) */
    input  wire [4:0]  joy1_n,
/* DB9-2 */
    input  wire [4:0]  joy2_n,

/* SDRAM pins (the top level does the DQ tri-state) */
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

/* keyboard machine keys (clk domain) */
/* 50/60 Hz swap */
    output wire        kbd_f8_tgl,
/* Ctrl+Alt+Del */
    output wire        kbd_cad,

/* flash (flash_if) */
    output wire        f_dclk,
    output wire        f_ncs,
    output wire        f_mosi,
    input  wire        f_miso,

/* VGA */
    output wire        vga_r,
    output wire        vga_r_low,
    output wire        vga_g,
    output wire        vga_g_low,
    output wire        vga_b,
    output wire        vga_b_low,
    output wire        vga_hs,
    output wire        vga_vs,

/* audio */
    output wire        audio_ay,
    output wire        audio_beeper,
/* ESP32 Bluetooth bridge: I2S master clocks (asynchronous) */
    input  wire        bt_bclk,
    input  wire        bt_lrck,
/* I2S data to the ESP32 */
    output wire        bt_data,
/* UART to the ESP32's Bluetooth part (F3 menu) */
    output wire        bt_tx,
/* UART from the ESP32 (asynchronous) */
    input  wire        bt_rx,
/* SPI link from the ESP32 system controller (asynchronous) */
    input  wire        esp_sck,
    input  wire        esp_mosi,
    input  wire        esp_cs_n,
    output wire        esp_miso,
    output wire        esp_irq,

/* on = turbo (tape loader); fast blink = ROMs missing in flash */
    output reg         led
);

/* Hz in a MHz */
localparam integer HZ_PER_MHZ = 1000000;
/* DDS step of the AY clock enable: 2^32 * 3.5469 MHz / 112 MHz */
localparam [32:0] AY_DDS_STEP = 33'd136016246;

/* SDRAM controller, shared by the ROM loader (first) and the CPU bus */
wire        ld_req, ld_we, ld_done, bad_image;
wire [17:0] ld_addr;
wire [7:0]  ld_din;
/* the CPU bus's requests */
wire        bus_req, bus_we;
wire [17:0] bus_addr;
wire [7:0]  bus_din;
/* what the RAM answers */
wire [7:0]  ram_dout;
wire        ram_ack, ram_ready;

sdram_ram #(.ADDR_BITS(18), .CLK_MHZ(CLK_MHZ)) u_ram (
    .clk      (clk),
    .rst_n    (rst_n),
    .req      (ld_done ? bus_req  : ld_req),
    .we       (ld_done ? bus_we   : ld_we),
    .addr     (ld_done ? bus_addr : ld_addr),
    .din      (ld_done ? bus_din  : ld_din),
    .wide     (1'b0),
    .din_hi   (8'd0),
    .dout_w   (),
    .dout     (ram_dout),
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

/* the ROM loader */
rom_loader #(.DIV(FLASH_DIV)) u_loader (
    .clk       (clk),
    .rst_n     (rst_n),
    .f_dclk    (f_dclk),
    .f_ncs     (f_ncs),
    .f_mosi    (f_mosi),
    .f_miso    (f_miso),
    .sd_req    (ld_req),
    .sd_we     (ld_we),
    .sd_addr   (ld_addr),
    .sd_din    (ld_din),
    .sd_ack    (ram_ack & !ld_done),
    .done      (ld_done),
    .bad_image (bad_image)
);

/* Keyboard (power-on reset only), AY */
wire [39:0] kb_rows;
wire [17:0] lkeys;
wire        kb_f1, kb_seen;
/* the raw report; the tape loader's OSD switches; the keyboard */
wire [31:0] kb_raw;
wire        l_osd_on, l_osd_full;

zx_keyboard #(.CLK_HZ(CLK_MHZ * HZ_PER_MHZ)) u_kbd (
    .clk    (clk),
    .rst_n  (por_n),
    .rx     (kbd_rx),
    .block  (l_osd_on & l_osd_full),
    .rows   (kb_rows),
    .lkeys  (lkeys),
    .f1     (kb_f1),
    .f8_tgl (kbd_f8_tgl),
    .cad    (kbd_cad),
    .seen   (kb_seen),
    .raw    (kb_raw)
);

/* power-up: wait for the keyboard (first packet) or KBD_WAIT_MS before the CPU starts */
localparam integer KBD_WAIT = KBD_WAIT_MS * CLK_MHZ * 1000;
reg [31:0] kbd_cnt;
reg        kbd_ready;
/* counts until the keyboard answers or the time is over */
always @(posedge clk or negedge por_n)
    if (!por_n)
    begin
        kbd_cnt   <= 32'd0;
/* ready */
        kbd_ready <= 1'b0;
    end
    else if (kb_seen || kbd_cnt == KBD_WAIT)
    begin
        kbd_ready <= 1'b1;
    end
    else
    begin
/* waiting */
        kbd_cnt <= kbd_cnt + 32'd1;
    end

/* AY clock enable: 3.5469 MHz (jt49 divides by 2 -> 1.7734 MHz, as the 128), independent of turbo */
reg  [31:0] ay_dds;
reg         ay_cen;
wire [32:0] ay_next = {1'b0, ay_dds} + AY_DDS_STEP;
/* the carry is the enable */
always @(posedge clk)
begin
    ay_dds <= ay_next[31:0];
    ay_cen <= ay_next[32];
end

/* the AY-3-8912 */
wire        ay_bdir, ay_bc1;
wire [7:0]  ay_din, ay_dout;
wire [9:0]  ay_sound;

/* the sound chip itself */
jt49_bus u_ay (
    .rst_n   (rst_n),
    .clk     (clk),
    .clk_en  (ay_cen),
    .bdir    (ay_bdir),
    .bc1     (ay_bc1),
    .din     (ay_din),
    .sel     (1'b0),
    .dout    (ay_dout),
    .sound   (ay_sound),
    .A       (),
    .B       (),
    .C       (),
    .sample  (),
    .IOA_in  (8'hFF),
    .IOA_out (),
    .IOB_in  (8'hFF),
    .IOB_out ()
);

/* its sigma-delta DAC */
sd_dac #(.W(10)) u_dac (
    .clk   (clk),
    .rst_n (rst_n),
    .din   (ay_sound),
    .dout  (audio_ay)
);

/* Joysticks: mode from the tape loader register INTPOS[29:28] (F4 menu, ESP32) */
/* 0 both ports = Kempston (port 1F) */
/* 1 DB9-1 = Kempston, DB9-2 = Cursor (5 left, 6 down, 7 up, 8 right, 0 fire) */
/* 2 Interface 2: DB9-1 = Sinclair 1 (6 left, 7 right, 8 down, 9 up, 0 fire), */
/* DB9-2 = Sinclair 2 (1 left, 2 right, 3 down, 4 up, 5 fire) */
/* Keys pressed by a joystick are added to the keyboard matrix (row 3 = 1..5 at */
/* bits 15..19, row 4 = 0 9 8 7 6 at bits 20..24). */
/* tape loader (56 MHz), static */
wire [1:0]  joy_mode;
reg  [1:0]  jm_s1, jm_s;
/* synchronised, active high: fire, up, down, left, right */
reg  [4:0]  j1_s1, j1, j2_s1, j2;
reg  [4:0]  kemp_c, kempston;
reg  [39:0] jkeys, zx_rows;

/* the mode, two stages */
always @(posedge clk)
begin
    jm_s1 <= joy_mode;
    jm_s <= jm_s1;
/* both joysticks, active high */
    j1_s1 <= ~joy1_n;
    j1   <= j1_s1;
    j2_s1 <= ~joy2_n;
/* the Kempston port; the keyboard with the joystick keys */
    j2   <= j2_s1;
    kempston <= kemp_c;
    zx_rows  <= kb_rows & ~jkeys;
end

/* the joystick mode */
always @*
begin
    kemp_c = 5'd0;
    jkeys  = 40'd0;
/* by mode */
    case (jm_s)
        2'd1:
        begin
            kemp_c    = j1;
/* left  -> 5 */
            jkeys[19] = j2[1];
/* down  -> 6 */
            jkeys[24] = j2[2];
/* up    -> 7 */
            jkeys[23] = j2[3];
/* right -> 8 */
            jkeys[22] = j2[0];
/* fire  -> 0 */
            jkeys[20] = j2[4];
        end
        2'd2:
        begin
/* Sinclair 1: left  -> 6 */
            jkeys[24] = j1[1];
/* right -> 7 */
            jkeys[23] = j1[0];
/* down  -> 8 */
            jkeys[22] = j1[2];
/* up    -> 9 */
            jkeys[21] = j1[3];
/* fire  -> 0 */
            jkeys[20] = j1[4];
/* Sinclair 2: left  -> 1 */
            jkeys[15] = j2[1];
/* right -> 2 */
            jkeys[16] = j2[0];
/* down  -> 3 */
            jkeys[17] = j2[2];
/* up    -> 4 */
            jkeys[18] = j2[3];
/* fire  -> 5 */
            jkeys[19] = j2[4];
        end
        default: kemp_c = j1 | j2;
    endcase
end

/* CPU, bus, ports */
wire        sh_we, sh_page7, screen7, beeper, diag_rom, cpu_running, cen_tgl;
wire        l_tape_on, l_tape_lvl, l_turbo, l_hold, mic;
wire        snap_freeze, snap_req, snap_frozen, snap_ack;
/* memory contention on (tape loader register, F5) */
wire        cont_on;
/* frame interrupt mark (zx_video, pixel clock) */
wire        frame_n;
wire [3:0]  snap_cmd;
wire [17:0] snap_addr;
/* data and answer, the shadow's write port */
wire [31:0] snap_wdata, snap_rdata;
wire [12:0] sh_addr;
wire [7:0]  sh_data;
/* the border colour; the bus */
wire [2:0]  border;

zx_bus u_bus (
    .clk         (clk),
    .rst_n       (rst_n),
    .run         (ld_done & kbd_ready),
    .turbo       (FORCE_TURBO | l_turbo),
    .diag_key    (kb_f1),
    .vid50       (mode50),
/* frame interrupt mark from the video (50 Hz mode) */
    .vsync_n     (frame_n),
    .kb_rows     (zx_rows),
    .joy         (kempston),
    .ltape_on    (l_tape_on),
    .ltape_lvl   (l_tape_lvl),
    .cen_tgl     (cen_tgl),
    .hold        (l_hold),
    .mic         (mic),
    .sd_req      (bus_req),
    .sd_we       (bus_we),
    .sd_addr     (bus_addr),
    .sd_din      (bus_din),
    .sd_dout     (ram_dout),
    .sd_ack      (ram_ack & ld_done),
    .sh_we       (sh_we),
    .sh_page7    (sh_page7),
    .sh_addr     (sh_addr),
    .sh_data     (sh_data),
    .ay_bdir     (ay_bdir),
    .ay_bc1      (ay_bc1),
    .ay_din      (ay_din),
    .ay_dout     (ay_dout),
    .border      (border),
    .screen7     (screen7),
    .beeper      (beeper),
    .diag_rom    (diag_rom),
    .cpu_running (cpu_running),
    .snap_freeze (snap_freeze),
    .snap_req    (snap_req),
    .snap_cmd    (snap_cmd),
    .snap_addr   (snap_addr),
    .snap_wdata  (snap_wdata),
    .snap_frozen (snap_frozen),
    .snap_ack    (snap_ack),
    .snap_rdata  (snap_rdata),
    .cont_en     (cont_on)
);

assign audio_beeper = beeper;

/* Same sound as I2S for the ESP32 Bluetooth part (esp32/) */
bt_i2s u_bt (
    .clk      (clk),
    .rst_n    (rst_n),
    .ay_cen   (ay_cen),
    .ay_sound (ay_sound),
    .beeper   (beeper),
    .i2s_bclk (bt_bclk),
    .i2s_lrck (bt_lrck),
    .i2s_data (bt_data)
);

/* Tape loader hardware (56 MHz), driven by the ESP32 over the SPI link; also saves / */
/* loads .z80 snapshots through zx_bus */
wire       osd_we;
wire [19:0] int_pos;
wire [9:0] osd_addr;
/* the OSD's write port; the tape loader */
wire [7:0] osd_data;

tape_loader u_tape (
    .clk        (clk56),
    .rst_n      (rst56_n),
    .keys       (lkeys),
    .keyraw     (kb_raw),
    .cen_tgl    (cen_tgl),
    .mic        (mic),
    .hold       (l_hold),
    .tape_on    (l_tape_on),
    .tape_turbo (l_turbo),
    .tape_lvl   (l_tape_lvl),
    .osd_on     (l_osd_on),
    .osd_full   (l_osd_full),
    .osd_we     (osd_we),
    .osd_addr   (osd_addr),
    .osd_data   (osd_data),
    .int_pos    (int_pos),
    .cont_on    (cont_on),
    .joy_mode   (joy_mode),
/* flash pass-through: not wired in LSpectrum */
    .fl_en      (),
    .fl_ncs     (),
    .fl_dclk    (),
    .fl_mosi    (),
    .fl_miso    (1'b1),
    .reload     (),
    .mctl       (),
    .mstat      (32'd0),
    .mclr       (),
    .mclr_we    (),
    .snap_freeze (snap_freeze),
    .snap_req   (snap_req),
    .snap_cmd   (snap_cmd),
    .snap_addr  (snap_addr),
    .snap_wdata (snap_wdata),
    .snap_frozen (snap_frozen),
    .snap_ack   (snap_ack),
    .snap_rdata (snap_rdata),
    .bt_tx      (bt_tx),
    .bt_rx      (bt_rx),
    .esp_sck    (esp_sck),
    .esp_mosi   (esp_mosi),
    .esp_cs_n   (esp_cs_n),
    .esp_miso   (esp_miso),
    .esp_irq    (esp_irq)
);

/* Video */
zx_video #(.FONT_HEX(FONT_HEX)) u_video (
    .pclk      (pclk),
    .prst_n    (prst_n),
    .mode50    (mode50),
    .border    (border),
    .screen7   (screen7),
    .wclk      (clk),
    .sh_we     (sh_we),
    .sh_page7  (sh_page7),
    .sh_addr   (sh_addr),
    .sh_data   (sh_data),
    .osd_wclk  (clk56),
    .osd_we    (osd_we),
    .osd_waddr (osd_addr),
    .osd_wdata (osd_data),
    .osd_on    (l_osd_on),
    .osd_full  (l_osd_full),
    .int_pos   (int_pos),
    .vga_r     (vga_r),
    .vga_r_low (vga_r_low),
    .vga_g     (vga_g),
    .vga_g_low (vga_g_low),
    .vga_b     (vga_b),
    .vga_b_low (vga_b_low),
    .vga_hs    (vga_hs),
    .vga_vs    (vga_vs),
    .frame_n   (frame_n)
);

/* LED (active low): on = turbo, fast blink = ROM image missing / unreadable */
reg [22:0] blink;
reg [2:0]  turbo_s;
always @(posedge clk)
begin
/* a blink counter; turbo, synchronised */
    blink   <= blink + 23'd1;
    turbo_s <= {turbo_s[1:0], FORCE_TURBO | l_turbo};
    led     <= bad_image ? blink[22] : !turbo_s[2];
end

endmodule

/* other files keep the default net type */
`default_nettype wire
