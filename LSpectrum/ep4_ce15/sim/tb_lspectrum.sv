/* tb_lspectrum -- whole machine (zx_system) with the real ROMs: */
/* flash model (bit-reversed image, as in the .jic) -> ROM loader -> SDRAM */
/* model (with I/O delays, as tb_ddr_test) -> T80 boots the 128K ROM. */
/* */
/* +define+TURBO=0|1     CPU speed (default 1: 28 MHz, boots 8x faster) */
/* +define+MODE50=0|1    video mode (default 0: 640x480@60, INT from the T-state counter) */
/* +define+DIAG=0|1      hold F1 (USB keyboard frame) at start -> DiagROM */
/* +define+RUN_MS=<ms>   simulated time after the ROM load (default 120) */
/* +define+KEYS=<ms>     at <ms> after the ROM load, type DOWN, ENTER (menu -> 128 BASIC) */
/* The ESP32 link is idle (no system controller): the tape loader hardware stays off. */
/* Output: progress lines, checks, and screen.ppm (picture of the screen shadow). */
`timescale 1ns/1ps

/* defaults of the command line switches */
`ifndef TURBO
 `define TURBO 1
`endif
/* 50 Hz video mode */
`ifndef MODE50
 `define MODE50 0
`endif
/* DiagROM instead of the 128K ROM */
`ifndef DIAG
 `define DIAG 0
`endif
/* milliseconds simulated after the ROM load */
`ifndef RUN_MS
 `define RUN_MS 120
`endif

/* the testbench */
module tb_lspectrum;

/* half periods of a clock period */
localparam integer HALVES = 2;
/* half a period of the 27 MHz pixel clock, ns */
localparam real PCLK_HALF_50 = 18.519;
/* half a period of the 25 MHz pixel clock, ns */
localparam real PCLK_HALF_60 = 20.0;
/* the reset ends after 200 ns */
localparam integer RST_NS = 200;
/* the pixel domain's reset ends 100 ns after the main one */
localparam integer PRST_GAP_NS = 100;
/* both data masks high */
localparam integer DQM_OFF = 3;
/* a bit of the keyboard's UART at 115200 baud, ns */
localparam integer BIT_NS = 8680;
/* bits of a byte */
localparam integer BYTE_BITS = 8;
/* lines of the screen dump */
localparam integer DUMP_H = 240;
/* columns of the screen dump */
localparam integer DUMP_W = 320;
/* first column of the picture in the screen dump (the left border) */
localparam integer PIC_X0 = 32;
/* first column after the picture in the screen dump */
localparam integer PIC_X_END = 288;
/* first line of the picture in the screen dump (the top border) */
localparam integer PIC_Y0 = 24;
/* first line after the picture in the screen dump */
localparam integer PIC_Y_END = 216;
/* pixels per character: 8 */
localparam integer CHAR_SHIFT = 3;
/* the three colour bits */
localparam integer COLOUR_MASK = 7;
/* the paper colour's place in an attribute */
localparam integer PAPER_SHIFT = 3;
/* the bright bit's place in an attribute */
localparam integer BRIGHT_SHIFT = 6;
/* colour bit: red */
localparam integer COL_RED = 2;
/* colour level of a normal (not bright) colour */
localparam [7:0] LEVEL_NORMAL = 8'hCD;
/* colour bit: green */
localparam integer COL_GREEN = 4;
/* clocks since the last clock enable at which a new one may come */
localparam integer CEN_GAP = 3;
/* RAM page 7: the second screen */
localparam integer PAGE_7 = 7;
/* RAM page 5: the normal screen */
localparam integer PAGE_5 = 5;
/* bytes of the ROM image */
localparam integer ROM_IMG = 49152;
/* SDRAM address of the ROMs */
localparam [17:0] ROM_BASE = 18'h20000;
/* mismatches listed */
localparam integer LIST_MAX = 5;
/* a millisecond in ns */
localparam integer MS_NS = 1_000_000;
/* milliseconds between two progress lines */
localparam integer PROGRESS_MS = 10;
/* time between two key events, ns */
localparam integer KEY_GAP_NS = 30_000_000;

/* half period of 112 MHz; clk56 = exactly 2 x */
localparam realtime H = 4.464;
localparam real T_CK  = 2 * H;
/* pin delays, the SDRAM clock's shift */
localparam real TCO   = 4.0;
localparam real TBACK = 0.5;
localparam real SD_SHIFT = 1.339;

/* the three clocks */
reg clk = 0, clk56 = 0, pclk = 0;
always #(H) clk = ~clk;
/* rising edges aligned with clk */
initial
begin
/* 56 MHz, rising edges aligned */
    #(H);
    forever
    begin
        clk56 = ~clk56;
/* every 112 MHz period */
        #(HALVES * H);
    end
end
always #(`MODE50 ? PCLK_HALF_50 : PCLK_HALF_60) pclk = ~pclk;

reg rst_n = 0, prst_n = 0;
/* the resets are released one after the other */
initial
begin
    #RST_NS rst_n = 1;
    #PRST_GAP_NS prst_n = 1;
end

/* the keyboard's UART line, idle */
reg       kbd_rx = 1;

/* SDRAM pins */
wire        cke, cs_n, ras_n, cas_n, we_n, dq_oe;
wire [1:0]  ba, dqm;
wire [12:0] a;
/* data out and in */
wire [15:0] dq_o;
reg  [15:0] dq_i;
wire        f_dclk, f_ncs, f_mosi, f_miso;
/* video, sound and LED pins; the machine */
wire        vr, vrl, vg, vgl, vb, vbl, hs, vs, ay, beep, led;

zx_system #(
    .FLASH_DIV(2), .KBD_WAIT_MS(1),
    .FONT_HEX("../../../AMenu/ep4_ce15/rtl/menu_font.hex"), .FORCE_TURBO(`TURBO)
) u_sys (
    .clk(clk), .por_n(rst_n), .rst_n(rst_n), .clk56(clk56), .rst56_n(rst_n),
    .pclk(pclk), .prst_n(prst_n), .mode50(1'b`MODE50),
    .kbd_rx(kbd_rx), .joy1_n(5'b11111), .joy2_n(5'b11111),
    .bt_tx(), .bt_rx(1'b1), .esp_sck(1'b0), .esp_mosi(1'b0), .esp_cs_n(1'b1), .esp_miso(), .esp_irq(),
    .kbd_f8_tgl(), .kbd_cad(),
    .sd_cke(cke), .sd_cs_n(cs_n), .sd_ras_n(ras_n), .sd_cas_n(cas_n), .sd_we_n(we_n),
    .sd_ba(ba), .sd_a(a), .sd_dqm(dqm), .sd_dq_o(dq_o), .sd_dq_oe(dq_oe), .sd_dq_i(dq_i),
    .f_dclk(f_dclk), .f_ncs(f_ncs), .f_mosi(f_mosi), .f_miso(f_miso),
    .vga_r(vr), .vga_r_low(vrl), .vga_g(vg), .vga_g_low(vgl), .vga_b(vb), .vga_b_low(vbl),
    .vga_hs(hs), .vga_vs(vs), .audio_ay(ay), .audio_beeper(beep), .led(led)
);

flash_model #(.REVERSE(1)) u_flash (.dclk(f_dclk), .ncs(f_ncs), .mosi(f_mosi), .miso(f_miso));

/* pins as seen by the SDRAM (transport delays, as tb_ddr_test) */
reg         m_clk = 0, m_cke = 0, m_cs_n = 1, m_ras_n = 1, m_cas_n = 1, m_we_n = 1;
reg  [1:0]  m_ba = 0, m_dqm = DQM_OFF;
reg  [12:0] m_a = 0;
/* data */
reg  [15:0] m_dq_drv = 'z;
wire [15:0] m_dq;
always @(clk) m_clk <= #(TCO + SD_SHIFT) ~clk;
/* commands and address, delayed */
always @(cke, cs_n, ras_n, cas_n, we_n, ba, a, dqm)
    {m_cke, m_cs_n, m_ras_n, m_cas_n, m_we_n, m_ba, m_a, m_dqm}
       <= #(TCO) {cke, cs_n, ras_n, cas_n, we_n, ba, a, dqm};
/* the data bus, delayed */
always @(dq_oe, dq_o) m_dq_drv <= #(TCO) (dq_oe ? dq_o : 16'hzzzz);
assign m_dq = m_dq_drv;
/* data back, delayed; the model */
always @(m_dq) dq_i <= #(TBACK) m_dq;

sdram_model #(.T_CK(T_CK)) u_sdram (
    .clk(m_clk), .cke(m_cke), .cs_n(m_cs_n), .ras_n(m_ras_n), .cas_n(m_cas_n), .we_n(m_we_n),
    .ba(m_ba), .a(m_a), .dqm(m_dqm), .dq(m_dq)
);

/* Helpers */
reg [7:0] rom_img [0:49151];
initial $readmemh("roms.mem", rom_img);

/* a byte straight from the model */
function automatic [7:0] sd_peek(input [17:0] ad);
    logic [15:0] w;
    logic [23:0] key;
    begin
/* {bank, row, column} as in sdram_model */
        key = {ad[11:10], 7'd0, ad[17:12], ad[9:1]};
        w = u_sdram.mem.exists(key) ? u_sdram.mem[key] : 16'hxxxx;
/* its lane */
        sd_peek = ad[0] ? w[15:8] : w[7:0];
    end
endfunction

integer errors = 0;

/* UART byte to the keyboard input (115200 8N1) */
task automatic uart_send(input [7:0] b);
    integer i;
    begin
        kbd_rx = 0;
/* the start bit, then eight data bits */
        #BIT_NS;
        for (i = 0; i < BYTE_BITS; i++)
        begin
            kbd_rx = b[i];
/* the last bit, then the stop bit */
            #BIT_NS;
        end
        kbd_rx = 1;
        #BIT_NS;
    end
endtask
/* CH9350-style frame as parsed by zx_keyboard: header 57 AB, then counted bytes */
/* 0..2 (here 01 88 08), 3 = modifiers, 4 = 0, 5..7 = keys, 8.. = more keys */
task automatic key_frame(input [7:0] mods, input [7:0] k);
    begin
        uart_send(8'h57);
        uart_send(8'hAB);
/* the frame header */
        uart_send(8'h01);
        uart_send(8'h88);
        uart_send(8'h08);
/* modifiers, then the key */
        uart_send(mods);
        uart_send(8'h00);
        uart_send(k);
/* the other key slots are empty */
        uart_send(8'h00);
        uart_send(8'h00);
        uart_send(8'h00);
/* the end of the frame */
        uart_send(8'h00);
        uart_send(8'h00);
    end
endtask

/* Write the screen shadow as a 320x240 PPM (32 px border), Spectrum colours */
task automatic dump_screen(input string fname);
    integer f, x, y, cx, zy, b, at, ink, pix, col, scr7;
    reg [7:0] bm;
/* the screen page shown; the picture file */
    reg [23:0] rgb;
    begin
        scr7 = u_sys.u_bus.p7ffd[3];
        f = $fopen(fname, "w");
/* a PPM header, then 320 x 240 pixels */
        $fwrite(f, "P3\n320 240\n255\n");
        for (y = 0; y < DUMP_H; y++)
        begin
            for (x = 0; x < DUMP_W; x++)
            begin
/* the border */
                if (x < PIC_X0 || x >= PIC_X_END || y < PIC_Y0 || y >= PIC_Y_END)
                begin
                    col = u_sys.u_bus.border;
                    b = 0;
                end
                else
                begin
/* the screen's line and column */
                    zy = y - PIC_Y0;
                    cx = (x - PIC_X0) >> CHAR_SHIFT;
                    bm = scr7 ? u_sys.u_video.sh7[{zy[7:6], zy[2:0], zy[5:3], cx[4:0]}]
                              : u_sys.u_video.sh5[{zy[7:6], zy[2:0], zy[5:3], cx[4:0]}];
/* attribute and pixel */
                    at = scr7 ? u_sys.u_video.sh7[6144 + (zy >> 3) * 32 + cx] : u_sys.u_video.sh5[6144 + (zy >> 3) * 32 + cx];
                    pix = bm[7 - ((x - 32) & 7)];
                    col = pix ? (at & COLOUR_MASK) : ((at >> PAPER_SHIFT) & COLOUR_MASK);
/* bright; the colour as RGB */
                    b = (at >> BRIGHT_SHIFT) & 1;
                end
                rgb = {(col & COL_RED) ? (b ? 8'hFF : LEVEL_NORMAL) : 8'h00, (col & COL_GREEN) ? (b ? 8'hFF : LEVEL_NORMAL) : 8'h00, (col & 1) ? (b ? 8'hFF : LEVEL_NORMAL) : 8'h00};
                $fwrite(f, "%0d %0d %0d\n", rgb[23:16], rgb[15:8], rgb[7:0]);
            end
        end
/* the file is written */
        $fclose(f);
        $display("%t screen written to %s (screen page %0d, border %0d)", $realtime, fname, scr7 ? 7 : 5, u_sys.u_bus.border);
    end
endtask

/* Monitors */
longint m1_count = 0, cen_count = 0, stall_clk = 0, sd_wr = 0;
reg [15:0] last_pc = 0;
always @(posedge clk)
begin
/* opcode fetches counted, the last PC kept */
    if (u_sys.u_bus.mstart && !u_sys.u_bus.cpu_m1_n)
    begin
        m1_count++;
        last_pc = u_sys.u_bus.cpu_a;
    end
/* T-states counted */
    if (u_sys.u_bus.cen)
    begin
        cen_count++;
    end
    if (u_sys.u_bus.cpu_rst_n && (u_sys.u_bus.tick | u_sys.u_bus.owed) && u_sys.u_bus.since == CEN_GAP && u_sys.u_bus.stall)
    begin
/* clocks the CPU was held */
        stall_clk++;
    end
/* the posted-write buffer must never be overwritten */
    if (u_sys.u_bus.t2_3rd && u_sys.u_bus.smp_wr2 && !u_sys.u_bus.smp_io2 && u_sys.u_bus.wb_valid)
    begin
        errors++;
        $display("%t ERROR: write buffer overrun", $realtime);
    end
end

/* interrupts counted; paging changes reported */
integer ints = 0;
always @(negedge u_sys.u_bus.int_n) ints++;

reg [7:0] p7ffd_prev = 0;
/* a write to 7FFD */
always @(posedge clk)
    if (u_sys.u_bus.p7ffd !== p7ffd_prev)
    begin
        p7ffd_prev = u_sys.u_bus.p7ffd;
/* reported with its fields */
        $display("%t 7FFD <= %02h  (RAM %0d, screen %0d, ROM %0d, lock %0d)  PC~%04h", $realtime, p7ffd_prev,
                 p7ffd_prev[2:0], p7ffd_prev[3] ? PAGE_7 : PAGE_5, p7ffd_prev[4], p7ffd_prev[5], last_pc);
    end

/* Run */
integer i, bad;
realtime t_load;
initial
begin
/* the options of this run */
    $display("TURBO=%0d MODE50=%0d DIAG=%0d", `TURBO, `MODE50, `DIAG);
    if (`DIAG)
    begin
/* F1 held from power-up */
        #1000 key_frame(8'h00, 8'h3A);
        $display("%t F1 frame sent", $realtime);
    end
    wait (u_sys.ld_done === 1'b1);
/* the time of the ROM load */
    t_load = $realtime;
    $display("%t ROM loader done, bad_image=%0d, bit-reversed image detected=%0d", $realtime,
             u_sys.u_loader.bad_image, u_sys.u_loader.reverse);
    if (u_sys.u_loader.bad_image !== 1'b0)
    begin
/* an error; the ROM copy in the SDRAM is compared with the image */
        errors++;
    end
    bad = 0;
    for (i = 0; i < ROM_IMG; i++)
    begin
/* a wrong byte */
        if (sd_peek(ROM_BASE + i) !== rom_img[i])
        begin
            bad++;
            if (bad <= LIST_MAX)
            begin
/* the first five are listed; the sum */
                $display("  SDRAM %05h = %02h, ROM image %02h", 18'h20000 + i, sd_peek(18'h20000 + i), rom_img[i]);
            end
        end
    end
    $display("  ROM copy in SDRAM: %0d mismatches of 49152", bad);
    if (bad)
    begin
/* an error; the machine runs, a line every 10 ms */
        errors++;
    end

    for (i = 1; i <= `RUN_MS; i++)
    begin
        #MS_NS;
/* progress */
        if (i % PROGRESS_MS == 0)
        begin
            $display("%t %0d ms: PC~%04h  M1=%0d  T-states=%0d  INTs=%0d  stall clks=%0d  border=%0d  diag=%0d  SDRAM model errors=%0d",
                     $realtime, i, last_pc, m1_count, cen_count, ints, stall_clk, u_sys.u_bus.border, u_sys.u_bus.diag_rom, u_sdram.errors);
        end
`ifdef KEYS
/* menu is up: cursor down, ENTER -> "128 BASIC" */
        if (i == `KEYS)
        begin
            $display("%t typing DOWN, ENTER", $realtime);
            key_frame(8'h00, 8'h51);
/* a key released, the next one 30 ms later */
            #KEY_GAP_NS;
            key_frame(8'h00, 8'h00);
            #KEY_GAP_NS;
/* Enter */
            key_frame(8'h00, 8'h28);
            #KEY_GAP_NS;
            key_frame(8'h00, 8'h00);
/* the screen after the keys; the final screen */
            dump_screen("screen_menu_keys.ppm");
        end
`endif
    end
    dump_screen("screen.ppm");
/* the model's own errors */
    if (u_sdram.errors)
    begin
        errors++;
    end
/* the verdict */
    if (errors)
    begin
        $display("FAIL (%0d errors)", errors);
    end
    else
    begin
        $display("DONE (no errors detected)");
    end
/* the end */
    $finish;
end

endmodule
