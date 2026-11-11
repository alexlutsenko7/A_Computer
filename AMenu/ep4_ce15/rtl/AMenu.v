/* AMenu -- machine menu, the factory image of the config flash */
/* */
/* Loaded at every power-up (and when a machine returns with KEY1). Shows the */
/* machines on 640x480@60 and starts the chosen one through the Cyclone IV */
/* remote update block (menu_boot): its bitstream is at MACHINE_ADDR in the */
/* flash (docs/PLAN.md "machine menu"). If that image is missing or damaged the */
/* device comes back here, and the menu shows the error under the machine. */
/* */
/* Keys: Up / Down (cursor and keypad 8 / 2), Enter / keypad Enter = start, */
/* 1 .. N (also keypad) = start that machine; joysticks: up / down / fire. */
/* After a machine returned, the cursor is on that machine. */
/* */
/* Clocks: CLOCK_50 (keyboard, menu), vga_pll c0 = 25.208 MHz (video), */
/* ruclk = CLOCK_50 / 4 = 12.5 MHz (remote update block, at most 20 MHz). */
/* LED: on = menu, blinking = the last machine could not start; the error row shows the */
/* reconfiguration reason in hex (02 watchdog, 04 nSTATUS / no image, 08 CRC, 10 nCONFIG). */
/* ESP32 link (as the machines: tape_loader + esp_link at mclk = 75 MHz, core ID 4D4E_0002 "MN", */
/* link version 2 = flash stream frames): the ESP32 draws on an OSD screen (shown instead of the */
/* menu while OSD is on; the menu takes no input meanwhile) and reads / writes the configuration */
/* flash through the FLASH register, DCLK 18.75 MHz (FL_HALF 2), mostly with FLS frames (1 us per byte): */
/* flash update from the SD card (LUPDATE.BIN), "no machines installed" (ESP32/v2/src/update.cpp). */
/* F3 opens the ESP32's Bluetooth menu (loader keys + the UART to its Bluetooth part, BT_TX / BT_RX). */
/* All other I/O board pins stay inputs (weak pull-ups): the SDRAM is deselected (CS_N high). */
`default_nettype none

module AMenu #(
    parameter integer N_MACHINES = 4,
/* machine i at [24*i +: 24] (1 MB slots) */
    parameter [95:0]  MACHINE_ADDR = {24'h400000, 24'h300000, 24'h200000, 24'h100000},
/* Spleen 8x16 (font/, tools/mk_menufont.py) */
    parameter         FONT_HEX = "rtl/menu_font.hex",
    parameter         TEXT_HEX = "rtl/menu_text.hex"
)(
    input  wire       CLOCK_50,
    input  wire       RESET_N,
    output wire       LEDR,

    output reg  [3:0] VGA_R,
    output reg  [3:0] VGA_G,
    output reg  [3:0] VGA_B,
    output reg        VGA_HS,
    output reg        VGA_VS,

    input  wire       KB_OUT,
    input  wire       KB_IN,

    output wire       AUDIO_AY,
    output wire       AUDIO_BEEP,

    input  wire       JOY1_UP_N,
    input  wire       JOY1_DOWN_N,
    input  wire       JOY1_FIRE_N,
    input  wire       JOY2_UP_N,
    input  wire       JOY2_DOWN_N,
    input  wire       JOY2_FIRE_N,

    input  wire       ESP_SCK,
    input  wire       ESP_MOSI,
    input  wire       ESP_CS_N,
    output wire       ESP_MISO,
    output wire       ESP_IRQ,
/* UART to the ESP32's Bluetooth part (its RX2, GPIO16): F3 menu */
    output wire       BT_TX,
/* UART from it (its TX2, GPIO17) */
    input  wire       BT_RX
);

/* USB key code: cursor up */
localparam [7:0] KEY_UP = 8'h52;
/* USB key code: keypad 8 (up) */
localparam [7:0] KEY_KP8 = 8'h60;
/* USB key code: cursor down */
localparam [7:0] KEY_DOWN = 8'h51;
/* USB key code: keypad 2 (down) */
localparam [7:0] KEY_KP2 = 8'h5A;
/* USB key code: Enter */
localparam [7:0] KEY_ENTER = 8'h28;
/* USB key code: keypad Enter */
localparam [7:0] KEY_KP_ENTER = 8'h58;
/* USB key code of the key 1, minus 1 (digit n = base + n) */
localparam [7:0] KEY_DIGIT_BASE = 8'h1D;
/* USB key code of keypad 1, minus 1 (keypad n = base + n) */
localparam [7:0] KEY_KP_BASE = 8'h58;

assign AUDIO_AY   = 1'b0;
assign AUDIO_BEEP = 1'b0;

/* Clocks and resets */
wire pclk, vga_locked;

vga_pll u_vpll (
    .inclk0 (CLOCK_50),
    .c0     (pclk),
    .c1     (),
    .locked (vga_locked)
);

wire mclk, m_locked;

/* 75 MHz for the ESP32's link */
menu_pll u_mpll (
    .inclk0 (CLOCK_50),
    .c0     (mclk),
    .locked (m_locked)
);

reg [2:0] rst_sr, prst_sr, rurst_sr, mrst_sr;
/* power-up value (no reset: it clocks the reset synchroniser) */
reg [1:0] ru_div = 2'd0;
always @(posedge CLOCK_50) ru_div <= ru_div + 2'd1;
wire ruclk = ru_div[1];

/* the reset of the 50 MHz domain */
always @(posedge CLOCK_50 or negedge RESET_N)
    if (!RESET_N)
    begin
        rst_sr <= 3'b000;
    end
    else
    begin
/* released after three clocks */
        rst_sr <= {rst_sr[1:0], 1'b1};
    end
wire rst_n = rst_sr[2];

/* the pixel domain's */
always @(posedge pclk or negedge vga_locked)
    if (!vga_locked)
    begin
        prst_sr <= 3'b000;
    end
    else
    begin
/* released after three clocks */
        prst_sr <= {prst_sr[1:0], 1'b1};
    end
wire prst_n = prst_sr[2];

/* the remote update block's (12.5 MHz) */
always @(posedge ruclk or negedge RESET_N)
    if (!RESET_N)
    begin
        rurst_sr <= 3'b000;
    end
    else
    begin
/* released after three clocks */
        rurst_sr <= {rurst_sr[1:0], 1'b1};
    end
wire rurst_n = rurst_sr[2];

/* the link domain's */
always @(posedge mclk or negedge m_locked)
    if (!m_locked)
    begin
        mrst_sr <= 3'b000;
    end
    else
    begin
/* released after three clocks */
        mrst_sr <= {mrst_sr[1:0], RESET_N};
    end
wire mrst_n = mrst_sr[2];

/* Keyboard (LSpectrum's parser; only the raw report is used here) and joysticks */
wire [31:0] kb_raw;
/* loader keys (F3 etc.) for the ESP32, as in the machines */
wire [17:0] lkeys;

zx_keyboard #(.CLK_HZ(50000000)) u_kbd (
    .clk    (CLOCK_50),
    .rst_n  (rst_n),
    .rx     (KB_OUT & KB_IN),
    .block  (1'b0),
    .rows   (),
    .lkeys  (lkeys),
    .f1     (),
    .f8_tgl (),
    .cad    (),
    .seen   (),
    .raw    (kb_raw)
);

/* is the key code in the report? */
function has(input [31:0] r, input [7:0] code);
    has = r[23:16] == code || r[15:8] == code || r[7:0] == code;
endfunction

/* held: [2] start, [1] down, [0] up; digit: 1-based machine number (0 = none) */
reg  [2:0] held;
reg  [3:0] digit;
integer i;
/* cursor up, cursor down (and the keypad's) */
always @*
begin
    held[0] = has(kb_raw, KEY_UP) | has(kb_raw, KEY_KP8);
    held[1] = has(kb_raw, KEY_DOWN) | has(kb_raw, KEY_KP2);
/* Enter; no digit unless one is held */
    held[2] = has(kb_raw, KEY_ENTER) | has(kb_raw, KEY_KP_ENTER);
    digit   = 4'd0;
    for (i = N_MACHINES; i >= 1; i = i - 1)
    begin
/* 1..9 = 1E.., keypad 59.. */
        if (has(kb_raw, KEY_DIGIT_BASE + i) || has(kb_raw, KEY_KP_BASE + i))
        begin
            digit = i;
        end
    end
end

/* the joysticks: fire, down, up of either one, synchronised */
reg  [2:0] j_s1, j_s;
always @(posedge CLOCK_50)
begin
    j_s1 <= {~JOY1_FIRE_N | ~JOY2_FIRE_N, ~JOY1_DOWN_N | ~JOY2_DOWN_N, ~JOY1_UP_N | ~JOY2_UP_N};
/* second stage */
    j_s  <= j_s1;
end

/* Menu */
wire        ru_ready;
wire [4:0]  ru_trig;
/* previous boot address, as written or shifted left by 2 */
wire [25:0] ru_prev;
wire [4:0]  ru_trig2;
wire [1:0]  ru_mode;
/* ready (synchronised), the cursor, state flags */
reg  [1:0]  rdy_s;
reg  [2:0]  sel;
reg         err, started, start_tgl, init_done;
/* the inputs one clock ago */
reg  [2:0]  held_p, j_p;
reg  [3:0]  digit_p;
reg  [23:0] boot_addr;

/* a new press; a new digit */
wire [2:0] press  = (held & ~held_p) | (j_s & ~j_p);
wire       dpress = digit != 4'd0 && digit != digit_p;

/* a machine's flash address */
function [23:0] maddr(input [2:0] m);
    maddr = MACHINE_ADDR[24 * m +: 24];
endfunction

/* The previous boot address reads back as written or shifted left by 2 (on hardware: shifted, */
/* 0x180000 -> 0x600000). With 1 MB slots a shifted address can equal another machine's written one */
/* (0x100000 << 2 = 0x400000): the shifted match wins (checked last). */
function prev_wr(input [2:0] m);
    prev_wr = ru_prev == {2'b00, maddr(m)};
endfunction

/* or as it reads back shifted */
function prev_sh(input [2:0] m);
    prev_sh = ru_prev == {maddr(m), 2'b00};
endfunction

/* shown address: a machine's address that read back shifted is shown as written */
reg [23:0] prev_show;
integer m;
always @*
begin
/* as read, unless it is a machine's */
    prev_show = ru_prev[23:0];
    for (m = 0; m < N_MACHINES; m = m + 1)
    begin
        if (prev_wr(m))
        begin
/* as written */
            prev_show = maddr(m);
        end
    end
    for (m = 0; m < N_MACHINES; m = m + 1)
    begin
        if (prev_sh(m))
        begin
/* the shifted match wins */
            prev_show = maddr(m);
        end
    end
end

/* tape_loader below */
wire       l_osd_on;
/* the ESP32's screen is up: no menu input */
reg  [1:0] osd_ls;
always @(posedge CLOCK_50) osd_ls <= {osd_ls[0], l_osd_on};
wire osd_lock = osd_ls[1];

/* the menu's state */
integer k;
always @(posedge CLOCK_50 or negedge rst_n)
    if (!rst_n)
    begin
/* the cursor on the first machine */
        rdy_s     <= 2'b00;
        sel       <= 3'd0;
        err       <= 1'b0;
/* nothing started */
        started   <= 1'b0;
        start_tgl <= 1'b0;
        init_done <= 1'b0;
/* keys held at power-up do nothing */
        held_p    <= 3'b111;
        j_p       <= 3'b111;
        digit_p   <= 4'd15;
/* no address yet; ready and the inputs, one clock later */
        boot_addr <= 24'd0;
    end
    else
    begin
        rdy_s   <= {rdy_s[0], ru_ready};
        held_p  <= held;
/* joysticks and digit */
        j_p     <= j_s;
        digit_p <= digit;

/* why are we here: cursor on the machine that ran / failed */
        if (rdy_s[1] && !init_done)
        begin
            init_done <= 1'b1;
            err       <= |ru_trig[3:1];
/* after a watchdog or a failed start */
            if (ru_trig != 5'd0)
            begin
                for (k = 0; k < N_MACHINES; k = k + 1)
                begin
                    if (prev_wr(k))
                    begin
/* the machine at the previous address */
                        sel <= k;
                    end
                end
                for (k = 0; k < N_MACHINES; k = k + 1)
                begin
                    if (prev_sh(k))
                    begin
/* the shifted match wins; then the keys */
                        sel <= k;
                    end
                end
            end
        end
        else if (init_done && !started && !osd_lock)
        begin
            if (press[0] && sel != 3'd0)
            begin
/* up */
                sel <= sel - 3'd1;
                err <= 1'b0;
            end
            else if (press[1] && sel != N_MACHINES - 1)
            begin
/* down */
                sel <= sel + 3'd1;
                err <= 1'b0;
            end
            else if (press[2] || dpress)
            begin
/* Enter or a digit: that machine */
                if (dpress)
                begin
                    sel <= digit - 4'd1;
                end
                boot_addr <= maddr(dpress ? digit - 4'd1 : sel);
/* started */
                started   <= 1'b1;
                err       <= 1'b0;
/* boot_addr is static from here on */
                start_tgl <= 1'b1;
            end
        end
    end

menu_boot u_boot (
    .clk       (ruclk),
    .rst_n     (rurst_n),
    .start_tgl (start_tgl),
    .boot_addr (boot_addr),
    .ready     (ru_ready),
    .trig      (ru_trig),
    .prev_addr (ru_prev),
    .trig2     (ru_trig2),
    .mode      (ru_mode)
);

/* ESP32 link: loader registers (only ID, IRQ, KEYRAW, OSD, FLASH are used here) and the */
/* configuration flash (AS pins through the ASMI block; idle: chip select off) */
wire       osd_we;
wire [9:0] osd_addr;
wire [7:0] osd_data;
/* the flash pass-through; the snapshot port is not used */
wire       fl_en, fl_ncs, fl_dclk, fl_mosi, fl_miso;
wire       snap_req;
reg        snap_ack;
/* no snapshot port: every command is done at once */
always @(posedge mclk) snap_ack <= snap_req;

tape_loader #(.BAUD_DIV(651), .CORE_ID(32'h4D4E_0002), .FL_HALF(2), .FLS(1)) u_tl (
    .clk         (mclk),
    .rst_n       (mrst_n),
    .keys        (lkeys),
    .keyraw      (kb_raw),
    .cen_tgl     (1'b0),
    .mic         (1'b0),
    .hold        (),
    .tape_on     (),
    .tape_turbo  (),
    .tape_lvl    (),
    .osd_on      (l_osd_on),
    .osd_full    (),
    .osd_we      (osd_we),
    .osd_addr    (osd_addr),
    .osd_data    (osd_data),
    .bt_tx       (BT_TX),
    .bt_rx       (BT_RX),
    .esp_sck     (ESP_SCK),
    .esp_mosi    (ESP_MOSI),
    .esp_cs_n    (ESP_CS_N),
    .esp_miso    (ESP_MISO),
    .esp_irq     (ESP_IRQ),
    .int_pos     (),
    .cont_on     (),
    .joy_mode    (),
    .fl_en       (fl_en),
    .fl_ncs      (fl_ncs),
    .fl_dclk     (fl_dclk),
    .fl_mosi     (fl_mosi),
    .fl_miso     (fl_miso),
    .reload      (),
    .mctl        (),
    .mstat       (32'd0),
    .mclr        (),
    .mclr_we     (),
    .snap_freeze (),
    .snap_req    (snap_req),
    .snap_cmd    (),
    .snap_addr   (),
    .snap_wdata  (),
    .snap_frozen (1'b0),
    .snap_ack    (snap_ack),
    .snap_rdata  (32'd0)
);

flash_if u_flash (
    .dclk (fl_en ? fl_dclk : 1'b0),
    .ncs  (fl_en ? fl_ncs  : 1'b1),
    .mosi (fl_mosi),
    .miso (fl_miso)
);

/* Video */
wire [3:0] vr, vg, vb;
wire       vhs, vvs;

menu_video #(.FONT_HEX(FONT_HEX), .TEXT_HEX(TEXT_HEX)) u_video (
    .pclk   (pclk),
    .prst_n (prst_n),
    .sel    (sel),
    .err    (err),
    .cause  (ru_trig),
    .addr   (prev_show),
    .cause2 (ru_trig2),
    .mode   (ru_mode),
    .osd_on    (l_osd_on),
    .osd_wclk  (mclk),
    .osd_we    (osd_we),
    .osd_waddr (osd_addr),
    .osd_wdata (osd_data),
    .vga_r  (vr),
    .vga_g  (vg),
    .vga_b  (vb),
    .vga_hs (vhs),
    .vga_vs (vvs)
);

/* the I/O registers of the VGA pins */
always @(posedge pclk)
begin
    VGA_R  <= vr;
    VGA_G  <= vg;
/* blue and the syncs */
    VGA_B  <= vb;
    VGA_HS <= vhs;
    VGA_VS <= vvs;
end

/* the LED */
reg [24:0] blink;
always @(posedge CLOCK_50) blink <= blink + 25'd1;
/* active low */
assign LEDR = err ? blink[24] : 1'b0;

endmodule

`default_nettype wire
