/* L64 -- Commodore 64 (PAL) on the QMTECH Cyclone IV EP4CE15 core board with */
/* the Extra_PCB_CycloneIV I/O board (same pins as LSpectrum) */
/* */
/* Application image at flash 0x200000 of the machine menu (AMenu/, docs/PLAN.md). */
/* */
/* Clocks (c64_pll, one VCO 756.25 MHz): */
/* clk    31.510 MHz  VIC-II dot4x: the C64 */
/* clk_sd 94.531 MHz  3 x clk, aligned: SDRAM, ROM loader, tape loader + ESP32 link, audio, */
/* frame buffer */
/* clk_sdo 94.531 MHz delayed: SDRAM clock (inverted, DDIO), as LSpectrum */
/* pclk   VGA pixel clock (frame buffer reader, OSD), switched by F8 as LSpectrum does: */
/* 39.80 MHz = 800 x 600 @ 60 Hz (after power-up), 31.51 MHz = 50 Hz */
/* */
/* Controls: */
/* KEY0 (W13)    reset (C64, ROM reload, tape loader; the ESP32 restarts) */
/* Ctrl+Alt+Del  back to the machine menu, as KEY1 (when the keys are released) */
/* KEY1 (Y13)    back to the machine menu (reconfigures to the factory image) */
/* keyboard      c64_keyboard.v (Esc = RUN/STOP, Page Up = RESTORE, Alt+F1..F8 = C64 F1..F8) */
/* F8            video 60 Hz (power-up) / 50 Hz; the C64 runs on undisturbed */
/* LED           fast blink = no C64 ROM image in flash (0x580000) */
`default_nettype none

module L64 #(
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

/* Clocks and resets */
wire clk, clk_sd, clk_sdo, clk_v50, clk_v60, locked;

c64_pll #(.SD_PHASE_PS(SD_PHASE_PS)) u_pll (
    .inclk0 (CLOCK_50),
    .c0     (clk_v50),
    .c1     (clk_v60),
    .c2     (clk),
    .c3     (clk_sd),
    .c4     (clk_sdo),
    .locked (locked)
);

/* por_n: power-up only (keyboard, bus); rst_n: C64 (+ KEY0); rst_sd_n: clk_sd (+ KEY0) */
wire       kbd_cad;
reg  [2:0] por_sr, rst_sr, rsd_sr;
reg        cad_q;
/* the reset of the key: the button and the PLL lock */
wire       key_arst_n = RESET_N & locked;
wire       arst_n     = key_arst_n;

always @(posedge clk or negedge locked)
/* held */
    if (!locked)
    begin
        por_sr <= 3'b000;
    end
    else
    begin
/* released after three clocks */
        por_sr <= {por_sr[1:0], 1'b1};
    end
wire por_n = por_sr[2];

/* Ctrl+Alt+Del, taken into the 112 MHz domain */
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

/* the machine's reset */
always @(posedge clk or negedge arst_n)
    if (!arst_n)
    begin
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

/* Pixel clock switch (F8), sequenced from CLOCK_50 as in LSpectrum: video reset on, */
/* clock off, select, clock on, video reset off (16 CLOCK_50 cycles per step) */
/* toggles on F8 (power-up: 0 = 60 Hz) */
wire       kbd_f8;
reg  [2:0] rst50_sr;
always @(posedge CLOCK_50 or negedge locked)
/* the 50 MHz domain's reset */
    if (!locked)
    begin
        rst50_sr <= 3'b000;
    end
    else
    begin
/* released after three clocks */
        rst50_sr <= {rst50_sr[1:0], 1'b1};
    end
wire rst50_n = rst50_sr[2];

/* F8 (keyboard, power-on reset only) toggles kbd_f8_tgl: the video mode survives resets. */
/* kbd_f8_tgl = 0 after power-up -> 640x480@60 (sel = 0); each F8 press swaps. */
reg [1:0] f8_s;
always @(posedge CLOCK_50 or negedge rst50_n)
    if (!rst50_n)
    begin
/* synchronised */
        f8_s <= 2'b00;
    end
    else
    begin
        f8_s <= {f8_s[0], kbd_f8};
    end
/* 1 = 60 Hz */
wire mode_req = !f8_s[1];

/* the clock switch sequence, as in VGA_TEST */
localparam [1:0] S_OFF = 2'd0, S_SEL = 2'd1, S_ENA = 2'd2, S_RUN = 2'd3;
reg  [1:0] vstate;
reg  [3:0] vwait;
/* the mode in use, the clock enable, video running */
reg        m60, clk_ena, video_run;

always @(posedge CLOCK_50 or negedge rst50_n)
    if (!rst50_n)
    begin
/* reset */
        vstate    <= S_OFF;
        vwait     <= 4'd0;
        m60       <= 1'b1;
/* nothing enabled; a step every 16 clocks */
        clk_ena   <= 1'b0;
        video_run <= 1'b0;
    end
    else
    begin
        vwait <= vwait + 4'd1;
/* everything off: select the clock */
        case (vstate)
            S_OFF:
                if (&vwait)
                begin
/* the new mode is taken */
                    m60 <= mode_req;
                    vstate <= S_SEL;
                end
/* selected: enable it */
            S_SEL:
                if (&vwait)
                begin
/* the clock runs */
                    clk_ena <= 1'b1;
                    vstate <= S_ENA;
                end
/* enabled: release the video reset */
            S_ENA:
                if (&vwait)
                begin
/* the video logic starts */
                    video_run <= 1'b1;
                    vstate <= S_RUN;
                end
/* running: watch for a mode change */
            S_RUN:
            begin
                vwait <= 4'd0;
                if (mode_req != m60)
                begin
/* everything off again */
                    video_run <= 1'b0;
                    clk_ena   <= 1'b0;
                    vstate    <= S_OFF;
                end
            end
        endcase
    end

/* the pixel clock */
wire pclk;
vga_clkmux u_clkmux (
    .clk0   (clk_v50),
    .clk1   (clk_v60),
    .sel    (m60),
    .ena    (clk_ena),
    .outclk (pclk)
);

/* the pixel domain's reset */
reg [2:0] prst_sr;
always @(posedge pclk or negedge video_run)
    if (!video_run)
    begin
/* asserted; released after three pixel clocks */
        prst_sr <= 3'b000;
    end
    else
    begin
/* released after three clocks */
        prst_sr <= {prst_sr[1:0], 1'b1};
    end
wire prst_n = prst_sr[2];

/* KEY1 / Ctrl+Alt+Del: back to the machine menu (remote update, as LSpectrum) */
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
    .clock    (ruclk),
    .reset    (1'b0),
    .reconfig    (ru_reconfig),
    .reset_timer (wd_reset),
    .busy        (),
    .data_out ()
);

/* The machine */
wire f_dclk, f_ncs, f_mosi, f_miso;

flash_if u_flash (
    .dclk (f_dclk),
    .ncs  (f_ncs),
    .mosi (f_mosi),
    .miso (f_miso)
);

wire       led, audio, c64_run;
/* the picture and the syncs; the machine */
wire [3:0] vr, vg, vb;
wire       vhs, vvs;

c64_system u_sys (
    .clk       (clk),
    .por_n     (por_n),
    .rst_n     (rst_n),
    .clk_sd    (clk_sd),
    .rst_sd_n  (rst_sd_n),
    .kbd_rx    (KB_OUT & KB_IN),
    .joy1_n    ({JOY1_FIRE_N, JOY1_UP_N, JOY1_DOWN_N, JOY1_LEFT_N, JOY1_RIGHT_N}),
    .joy2_n    ({JOY2_FIRE_N, JOY2_UP_N, JOY2_DOWN_N, JOY2_LEFT_N, JOY2_RIGHT_N}),
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
    .kbd_cad   (kbd_cad),
    .kbd_f8    (kbd_f8),
    .f_dclk    (f_dclk),
    .f_ncs     (f_ncs),
    .f_mosi    (f_mosi),
    .f_miso    (f_miso),
    .pclk      (pclk),
    .prst_n    (prst_n),
    .m60       (m60),
    .vga_r     (vr),
    .vga_g     (vg),
    .vga_b     (vb),
    .vga_hs    (vhs),
    .vga_vs    (vvs),
    .audio     (audio),
    .bt_bclk   (BT_BCLK),
    .bt_lrck   (BT_LRCK),
    .bt_data   (BT_DATA),
    .bt_tx     (BT_TX),
    .bt_rx     (BT_RX),
    .esp_sck   (ESP_SCK),
    .esp_mosi  (ESP_MOSI),
    .esp_cs_n  (ESP_CS_N),
    .esp_miso  (ESP_MISO),
    .esp_irq   (ESP_IRQ),
    .led       (led),
    .c64_run   (c64_run)
);

/* active low; on for the first 2.7 s after start */
assign LEDR       = led & up_cnt[25];
assign AUDIO_AY   = audio;
assign AUDIO_BEEP = 1'b0;

/* Syncs off at each start (configuration, KEY0, ROM reload: the C64 is in reset) until 2 s */
/* after the C64 left reset, when BASIC is on the screen: the monitor first sees the mode with a */
/* picture, so its auto-adjust finds the picture's edges. On a black screen it could take the */
/* HSYNC edge's crosstalk on the colour lines, 40 pixels after the picture, for the right edge */
/* (a coloured line at the right). */
/* 2 s of ruclk (12.5 MHz) */
localparam [24:0] SP_RUN = 25'd25_000_000;
reg  [2:0]  run_s = 3'd0;
reg  [24:0] sp_cnt = 25'd0;
/* syncs off */
reg         sp_off = 1'b1;
always @(posedge ruclk)
begin
    run_s <= {run_s[1:0], c64_run};
/* the machine does not run: syncs off */
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

endmodule

/* other files keep the default net type */
`default_nettype wire
