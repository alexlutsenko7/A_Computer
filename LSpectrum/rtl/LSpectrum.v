//=============================================================================
// LSpectrum -- ZX Spectrum 128K on the QMTECH Cyclone IV EP4CE15 core board
//              with the Extra_PCB_CycloneIV I/O board (its J1 wired to the core
//              board's U8, each pin pair swapped; see docs/BOARD_PINOUT.md)
//
// Clocks: sys_pll  c0 = 112 MHz system clock, c1 = 112 MHz delayed (SDRAM clock),
//                  c2 = 56 MHz (tape loader hardware + ESP32 link, aligned with c0)
//         vga_pll  c0 = 25.208 MHz (640x480@60), c1 = 27.009 MHz (720x576@50), switched
//                  by the global clock control block (sequenced as in VGA_TEST)
//
// Controls (USB keyboard keys: see zx_keyboard.v, docs/SD_TAPE_LOADER.md). The SD card,
// browser and file handling are on the ESP32 (esp32/), which drives the loader hardware
// over the SPI link (rtl/esp_link.v):
//   KEY0 (W13)    reset (CPU, ports, ROM reload, tape loader; the ESP32 restarts)
//   Ctrl+Alt+Del  back to the machine menu, as KEY1 (when the keys are released)
//   F1            held while the CPU starts (power-up or after a reset): DiagROM
//   F2            save a snapshot (.z80) to the SD card; the F12 browser loads them
//   F8            swap 50/60 Hz video (power-up default: 640x480@60, which every
//                 monitor accepts; 576p50 is not supported by all of them)
//   F12 / numpad  SD card tape loader (browser on the OSD)
//   Turbo         the SD tape loader switches the CPU to 28 MHz while it plays or saves (F6: normal speed)
//   LED           on = turbo; fast blink = no ROM image in flash (program the .jic)
//   KEY1 (Y13)    back to the machine menu (reconfigures to the factory image, AMenu/)
//   F3            Bluetooth audio menu (scan, connect, PIN, volume)
//   BT_*          machine sound as I2S to the ESP32 Bluetooth bridge, UART for its control
//=============================================================================
`default_nettype none

module LSpectrum #(
    parameter         SD_PHASE_PS   = "1250"    // SDRAM clock delay (as DDR_TEST, 1339 ps achieved)
)(
    input  wire        CLOCK_50,
    input  wire        RESET_N,
    input  wire        KEY1,
    output wire        LEDR,

    // SDRAM
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

    // I/O board: VGA, 4 bits per colour (binary-weighted DAC, bit 3 = MSB)
    output reg  [3:0]  VGA_R,
    output reg  [3:0]  VGA_G,
    output reg  [3:0]  VGA_B,
    output reg         VGA_HS,
    output reg         VGA_VS,

    // I/O board: keyboard module J5 (USB-HID -> UART); both lines are inputs (pulled up), RX = KB_OUT & KB_IN
    input  wire        KB_OUT,
    input  wire        KB_IN,

    // SPI link from the ESP32 system controller; the SD card is on the ESP32
    input  wire        ESP_SCK,
    input  wire        ESP_MOSI,
    input  wire        ESP_CS_N,
    output wire        ESP_MISO,
    output wire        ESP_IRQ,

    // I/O board: audio jack, joysticks (DB9, active low)
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

    // ESP32 Bluetooth audio (esp32/)
    input  wire        BT_BCLK,         // I2S bit clock from the ESP32 (master)
    input  wire        BT_LRCK,         // I2S word select from the ESP32
    output wire        BT_DATA,         // I2S data to the ESP32
    output wire        BT_TX,           // UART to the ESP32 (its RX2, GPIO16)
    input  wire        BT_RX            // UART from the ESP32 (its TX2, GPIO17)
);

//-----------------------------------------------------------------------------
// System clock and reset
//-----------------------------------------------------------------------------
wire clk, clk_sd, clk56, sys_locked;

sys_pll #(.SD_PHASE_PS(SD_PHASE_PS)) u_pll (
    .inclk0 (CLOCK_50),
    .c0     (clk),
    .c1     (clk_sd),
    .c2     (clk56),
    .locked (sys_locked)
);

// por_n: power-up only (keyboard); rst_n: machine (+ KEY0);
// rst56_n: tape loader (+ KEY0)
wire       kbd_cad, kbd_f8_tgl;
reg  [2:0] por_sr, rst_sr, rst56_sr;
reg        cad_q;
wire       key_arst_n = RESET_N & sys_locked;
wire       arst_n     = key_arst_n;

always @(posedge clk or negedge sys_locked)
    if (!sys_locked) por_sr <= 3'b000;
    else             por_sr <= {por_sr[1:0], 1'b1};
wire por_n = por_sr[2];

always @(posedge clk or negedge por_n)
    if (!por_n) cad_q <= 1'b0;
    else        cad_q <= kbd_cad;

always @(posedge clk or negedge arst_n)
    if (!arst_n) rst_sr <= 3'b000;
    else         rst_sr <= {rst_sr[1:0], 1'b1};
wire rst_n = rst_sr[2];

always @(posedge clk56 or negedge key_arst_n)
    if (!key_arst_n) rst56_sr <= 3'b000;
    else             rst56_sr <= {rst56_sr[1:0], 1'b1};
wire rst56_n = rst56_sr[2];

// SDRAM clock = inverted clk_sd through a DDIO output (same I/O delay as the
// command/data pins), exactly as in DDR_TEST
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
    .outclock   (clk_sd),
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
// Video clock: 25 / 27 MHz, switched from the 50 MHz domain (see VGA_TEST)
//-----------------------------------------------------------------------------
wire clk25, clk27, vga_locked;

vga_pll u_vpll (
    .inclk0 (CLOCK_50),
    .c0     (clk25),
    .c1     (clk27),
    .locked (vga_locked)
);

reg  [2:0] rst50_sr;
always @(posedge CLOCK_50 or negedge vga_locked)
    if (!vga_locked) rst50_sr <= 3'b000;
    else             rst50_sr <= {rst50_sr[1:0], 1'b1};
wire rst50_n = rst50_sr[2];

// F8 (keyboard, power-on reset only) toggles kbd_f8_tgl: the video mode survives resets.
// kbd_f8_tgl = 0 after power-up -> 640x480@60 (sel = 0); each F8 press swaps.
reg [1:0] f8_s;
always @(posedge CLOCK_50 or negedge rst50_n)
    if (!rst50_n) f8_s <= 2'b00;
    else          f8_s <= {f8_s[0], kbd_f8_tgl};

wire mode_req = f8_s[1];

localparam [1:0] S_OFF = 2'd0, S_SEL = 2'd1, S_ENA = 2'd2, S_RUN = 2'd3;
reg  [1:0] vstate;
reg  [3:0] vwait;
reg        sel, clk_ena, video_run;

always @(posedge CLOCK_50 or negedge rst50_n)
    if (!rst50_n) begin
        vstate    <= S_OFF;
        vwait     <= 4'd0;
        sel       <= 1'b0;
        clk_ena   <= 1'b0;
        video_run <= 1'b0;
    end else begin
        vwait <= vwait + 4'd1;
        case (vstate)
            S_OFF: if (&vwait) begin sel <= mode_req; vstate <= S_SEL; end
            S_SEL: if (&vwait) begin clk_ena <= 1'b1; vstate <= S_ENA; end
            S_ENA: if (&vwait) begin video_run <= 1'b1; vstate <= S_RUN; end
            S_RUN: begin
                vwait <= 4'd0;
                if (mode_req != sel) begin
                    video_run <= 1'b0;
                    clk_ena   <= 1'b0;
                    vstate    <= S_OFF;
                end
            end
        endcase
    end

wire pclk;
vga_clkmux u_clkmux (
    .clk0   (clk25),
    .clk1   (clk27),
    .sel    (sel),
    .ena    (clk_ena),
    .outclk (pclk)
);

reg [2:0] prst_sr;
always @(posedge pclk or negedge video_run)
    if (!video_run) prst_sr <= 3'b000;
    else            prst_sr <= {prst_sr[1:0], 1'b1};
wire prst_n = prst_sr[2];

//-----------------------------------------------------------------------------
// KEY1 / Ctrl+Alt+Del: back to the machine menu. This is an application image of the remote
// update scheme (docs/PLAN.md): a reconfiguration request loads the factory
// image (AMenu). KEY1 must be held for ~20 ms (debounce). The remote update
// block runs on CLOCK_50 / 4 (at most 20 MHz).
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

altremote_update #(
    .check_app_pof            ("false"),
    .config_device_addr_width (24),
    .in_data_width            (24),
    .out_data_width           (29),
    .operation_mode           ("remote")
) u_ru (
    .clock    (ruclk),
    .reset    (1'b0),
    .reconfig    (ru_reconfig),
    .reset_timer (wd_reset),
    .busy        (),
    .data_out ()
);

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

wire led;
wire vga_r, vga_r_low, vga_g, vga_g_low, vga_b, vga_b_low, vga_hs, vga_vs;

zx_system u_sys (
    .clk          (clk),
    .por_n        (por_n),
    .rst_n        (rst_n),
    .clk56        (clk56),
    .rst56_n      (rst56_n),
    .pclk         (pclk),
    .prst_n       (prst_n),
    .mode50       (sel),
    .kbd_rx       (KB_OUT & KB_IN),
    // joystick mode (Kempston / Cursor / Sinclair) in zx_system, F4 menu
    .joy1_n       ({JOY1_FIRE_N, JOY1_UP_N, JOY1_DOWN_N, JOY1_LEFT_N, JOY1_RIGHT_N}),
    .joy2_n       ({JOY2_FIRE_N, JOY2_UP_N, JOY2_DOWN_N, JOY2_LEFT_N, JOY2_RIGHT_N}),
    .sd_cke       (DRAM_CKE),
    .sd_cs_n      (DRAM_CS_N),
    .sd_ras_n     (DRAM_RAS_N),
    .sd_cas_n     (DRAM_CAS_N),
    .sd_we_n      (DRAM_WE_N),
    .sd_ba        (DRAM_BA),
    .sd_a         (DRAM_ADDR),
    .sd_dqm       ({DRAM_UDQM, DRAM_LDQM}),
    .sd_dq_o      (dq_o),
    .sd_dq_oe     (dq_oe),
    .sd_dq_i      (DRAM_DQ),
    .esp_sck      (ESP_SCK),
    .esp_mosi     (ESP_MOSI),
    .esp_cs_n     (ESP_CS_N),
    .esp_miso     (ESP_MISO),
    .esp_irq      (ESP_IRQ),
    .kbd_f8_tgl   (kbd_f8_tgl),
    .kbd_cad      (kbd_cad),
    .f_dclk       (f_dclk),
    .f_ncs        (f_ncs),
    .f_mosi       (f_mosi),
    .f_miso       (f_miso),
    .vga_r        (vga_r),
    .vga_r_low    (vga_r_low),
    .vga_g        (vga_g),
    .vga_g_low    (vga_g_low),
    .vga_b        (vga_b),
    .vga_b_low    (vga_b_low),
    .vga_hs       (vga_hs),
    .vga_vs       (vga_vs),
    .audio_ay     (AUDIO_AY),
    .audio_beeper (AUDIO_BEEP),
    .bt_bclk      (BT_BCLK),
    .bt_lrck      (BT_LRCK),
    .bt_data      (BT_DATA),
    .bt_tx        (BT_TX),
    .bt_rx        (BT_RX),
    .led          (led)
);

assign LEDR = led & up_cnt[25];        // active low: led = 0 -> on; on for the first 2.7 s after start

// 2-bit ZX colour -> 4-bit DAC: normal (high bit) = 4'hE, bright (both bits) = 4'hF
// (the low bit is only ever set together with the high bit). One more pclk register
// stage for colours and syncs alike: these are the I/O registers of the VGA pins.
always @(posedge pclk) begin
    VGA_R  <= {vga_r, vga_r, vga_r, vga_r_low};
    VGA_G  <= {vga_g, vga_g, vga_g, vga_g_low};
    VGA_B  <= {vga_b, vga_b, vga_b, vga_b_low};
    VGA_HS <= vga_hs;
    VGA_VS <= vga_vs;
end

endmodule

`default_nettype wire
