//=============================================================================
// tb_atari -- LTari (atari_system) boot: AltirraOS cold start -> Altirra BASIC READY
//
//   ROM image atarirom.mem (tools/mk_atarirom.py) in the flash model, bit-reversed as in
//   the .jic -> ROM loader -> SDRAM model -> T65 runs AltirraOS. No SIO device answers, so
//   the OS's disk boot attempt has to time out before BASIC starts.
//   +define+RUN_MS=<ms>   longest simulated time (default 4000); stops at "READY"
//   +define+M800          800XL (64 KB) instead of the 130XE
//   +define+DISK          a disk drive D1: answers through the SIO bridge (atari_sio, as the ESP32 does,
//                         timing of the hardware manual 9.1): status + a boot sector whose code writes
//                         "DISK BOOT OK" to the screen; the run stops there
//   +define+CART=1        a standard 8 KB test cartridge (written into the SDRAM model at 0x28000): its start
//                         code ($A000) writes "CART OK" to the screen; the run stops there
//   +define+CART=4        an Atarimax 1 MB test cartridge (0x100000): bank 0 starts, reads $D501 and so goes on
//                         in bank 1, which writes "BANK OK"
//   +define+SNAPTEST      (with CART=1) after "CART OK": freeze, register read-back, I/O shadow check
//                         (COLBK shadow = the OS's COLOR4), restore program in the restore bank (as the
//                         ESP32 writes it: writes AUDF1, stack, A / X / Y, RTI) run in restore mode after a
//                         CPU-only reset; the CPU must go on in its loop with the same registers
//   +define+INJECT=\"f.xex\" (with DISK) a binary load file (.xex / .com) without the SIO transfer: the boot
//                         sector switches BASIC off and waits on a mailbox ($0600); the testbench writes the
//                         segments into memory (INITAD cleared before each, as our loader), has the Atari call
//                         INITAD (mailbox 1) when a segment set it, and finally jump through RUNAD (mailbox 2).
//                         Runs RUN_MS; reports when the CPU reaches INJ_WATCH (default $9D00); pictures at the end
//   +define+INJRAM=\"f.bin\" (with INJECT) after the segments, a 64 KB memory image (e.g. a depacked demo
//                         from a 6502 run) replaces RAM $0800-$CFFF and $D800-$FFFF before the jump (pages 0-7
//                         stay: OS variables and the boot sector), and RUNAD = INJ_RUN (default $9D00)
//   +define+INJ_DUMP      (with INJECT) at the first opcode fetch at INJ_WATCH: 64 KB RAM to inj_dump.bin, 300 ms
//                         more, then stop
//   +define+INJSTAGE      (with DISK) stage 2 of a depacker from a 6502 reference run: boot sector in page 1
//                         (mailbox $0180: 1 = SEI + NMIEN 0, 2 = PORTB $FE, ANTIC as the depacker, registers,
//                         JMP $0812), memory s2_ram.bin written ($0000-$00FF, $0200-$CFFF, $D800-$FFFF),
//                         registers s2_regs.txt; every 500 instructions from $0812 the zero-page pointers are
//                         compared with s2_ref.txt; the first mismatch stops the run with the last 400 PCs
//   +define+XEX           the same drive serving disk.mem (mk_xextest.py: our .xex boot loader + a test
//                         .xex, as the ESP32 serves an .xex); the run stops at "XEX OK" (or "XEX BAD")
// Output every 50 ms: CPU address, VCOUNT, NMIs, SIO bytes sent, the text screen (from
// SAVMSC, $58/$59, internal codes decoded); at the end screen.ppm (one GTIA frame, 376 x
// 240 hi-res pixels, palette from the PAL hue angles of the hardware manual, table 14)
// and vga.ppm: one frame from the frame buffer (atari_fb, the board's video path: 640 x 480
// at 60 Hz, 25.208 MHz; +define+VGA50: 720 x 576 at 50 Hz, 27.009 MHz; its SDRAM port loads
// the arbiter as on the board).
//=============================================================================
`timescale 1ns/1ps
`ifdef XEX
 `define DISK
`endif
`ifndef RUN_MS
 `define RUN_MS 4000
`endif

module tb_atari;
localparam realtime HSD = 5.8742;       // clk_sd half period (85.119 MHz); clk = clk_sd / 3
localparam real T_CK  = 2 * HSD;
localparam real TCO   = 4.0;
localparam real TBACK = 0.5;
localparam real SD_SHIFT = 1.339;

reg clk_sd = 0, clk = 0;
integer ph = 0;
always #(HSD) begin
    clk_sd = ~clk_sd;
    ph = (ph == 2) ? 0 : ph + 1;
    if (ph == 0) clk = ~clk;
end

reg rst_n = 0;
initial #300 rst_n = 1;

`ifdef VGA50
localparam VW = 720, VH = 576, VM60 = 1'b0;
reg pclk = 0;                           // VGA pixel clock, 27.009 MHz
always #18.512 pclk = ~pclk;
`else
localparam VW = 640, VH = 480, VM60 = 1'b1;
reg pclk = 0;                           // VGA pixel clock, 25.208 MHz
always #19.835 pclk = ~pclk;
`endif
reg prst_n = 0;
initial #1000 prst_n = 1;

wire        cke, cs_n, ras_n, cas_n, we_n, dq_oe;
wire [1:0]  ba, dqm;
wire [12:0] a;
wire [15:0] dq_o;
reg  [15:0] dq_i;
wire        f_dclk, f_ncs, f_mosi, f_miso;
wire        sio_out, sio_cmd_n, sio_motor_n;
wire        px_stb, px_blank, spk, bad;
wire [7:0]  px_cc, px0, px1;
wire [8:0]  px_vc;
wire [5:0]  aud;
wire        fb_req, fb_we, fb_ack, a_run;
wire [20:0] fb_addr;
wire [15:0] fb_wdata, fb_rdata;
wire [17:0] v_rgb;
wire        v_hs, v_vs, v_act;
wire [1:0]  fb_newest;
wire        sio_in, so_stb;
wire [7:0]  so_byte;

reg         t_frz = 1'b0, t_rm = 1'b0, t_rst = 1'b0;   // snapshot port (SNAPTEST)
wire        t_frozen, t_rmode;
wire [63:0] t_regs;

atari_system #(.FLASH_DIV(2)) u_sys (
    .clk(clk), .rst_n(rst_n), .clk_sd(clk_sd), .rst_sd_n(rst_n),
    .freeze(t_frz), .rm_req(t_rm), .cpu_rst_req(t_rst), .frozen(t_frozen), .rmode(t_rmode), .cpu_regs(t_regs),
    .pia_st(), .cart_st(),
`ifdef M800
    .model130(1'b0),
`else
    .model130(1'b1),
`endif
    `ifdef CART
    .reload(1'b0), .cart(`CART), .reset_key(1'b0),
`else
    .reload(1'b0), .cart(3'd0), .reset_key(1'b0),
`endif
    .key_stb(1'b0), .key_code(6'd0), .key_down(1'b0), .key_shift(1'b0), .key_ctrl(1'b0), .key_break(1'b0),
    .consol_n(3'b111), .joy_dir_n(8'hFF), .joy_trig_n(2'b11),
    .sd_cke(cke), .sd_cs_n(cs_n), .sd_ras_n(ras_n), .sd_cas_n(cas_n), .sd_we_n(we_n),
    .sd_ba(ba), .sd_a(a), .sd_dqm(dqm), .sd_dq_o(dq_o), .sd_dq_oe(dq_oe), .sd_dq_i(dq_i),
    .f_dclk(f_dclk), .f_ncs(f_ncs), .f_mosi(f_mosi), .f_miso(f_miso),
    .sio_out(sio_out), .sio_in(sio_in), .sio_cmd_n(sio_cmd_n), .sio_motor_n(sio_motor_n), .so_stb(so_stb), .so_byte(so_byte),
    .px_stb(px_stb), .px_cc(px_cc), .px_vc(px_vc), .px_blank(px_blank), .px0(px0), .px1(px1),
    .audio(aud), .speaker(spk), .bad_image(bad), .run_o(a_run),
    .fb_req(fb_req), .fb_we(fb_we), .fb_addr(fb_addr), .fb_wdata(fb_wdata), .fb_ack(fb_ack), .fb_rdata(fb_rdata),
    .x_req(1'b0), .x_we(1'b0), .x_addr(21'd0), .x_din(8'd0), .x_ack(), .x_dout()
);

atari_fb #(.PAL_HEX("../rtl/atari_palette.hex")) u_fb (
    .clk(clk), .rst_n(rst_n), .px_stb(px_stb), .px_cc(px_cc), .px_vc(px_vc), .px0(px0), .px1(px1),
    .hold(1'b0), .newest(fb_newest),
    .clk_sd(clk_sd), .rst_sd_n(rst_n), .m_req(fb_req), .m_we(fb_we), .m_addr(fb_addr), .m_wdata(fb_wdata),
    .m_ack(fb_ack), .m_rdata(fb_rdata),
    .pclk(pclk), .prst_n(prst_n), .m60(VM60), .rgb(v_rgb), .hsync(v_hs), .vsync(v_vs), .active(v_act)
);

flash_model #(.BASE(24'h380000), .LEN(28672), .REVERSE(1), .FILE("atarirom.mem")) u_flash (
    .dclk(f_dclk), .ncs(f_ncs), .mosi(f_mosi), .miso(f_miso));

// pins as seen by the SDRAM (transport delays, as tb_lspectrum / tb_l64)
reg         m_clk = 0, m_cke = 0, m_cs_n = 1, m_ras_n = 1, m_cas_n = 1, m_we_n = 1;
reg  [1:0]  m_ba = 0, m_dqm = 3;
reg  [12:0] m_a = 0;
reg  [15:0] m_dq_drv = 'z;
wire [15:0] m_dq;
always @(clk_sd)                                      m_clk <= #(TCO + SD_SHIFT) ~clk_sd;
always @(cke, cs_n, ras_n, cas_n, we_n, ba, a, dqm)   {m_cke, m_cs_n, m_ras_n, m_cas_n, m_we_n, m_ba, m_a, m_dqm}
                                                         <= #(TCO) {cke, cs_n, ras_n, cas_n, we_n, ba, a, dqm};
always @(dq_oe, dq_o)                                 m_dq_drv <= #(TCO) (dq_oe ? dq_o : 16'hzzzz);
assign m_dq = m_dq_drv;
always @(m_dq)                                        dq_i <= #(TBACK) m_dq;

sdram_model #(.T_CK(T_CK)) u_sdram (
    .clk(m_clk), .cke(m_cke), .cs_n(m_cs_n), .ras_n(m_ras_n), .cas_n(m_cas_n), .we_n(m_we_n),
    .ba(m_ba), .a(m_a), .dqm(m_dqm), .dq(m_dq)
);

// a byte straight into the SDRAM model (cartridge images, INJECT)
task automatic sd_poke(input [20:0] ad, input [7:0] v);
    logic [23:0] key;
    logic [15:0] w;
    begin
        key = {ad[11:10], 4'd0, ad[20:12], ad[9:1]};
        w = u_sdram.mem.exists(key) ? u_sdram.mem[key] : 16'h0000;
        if (ad[0]) w[15:8] = v; else w[7:0] = v;
        u_sdram.mem[key] = w;
    end
endtask

function automatic [7:0] sd_peek(input [20:0] ad);
    logic [15:0] w;
    logic [23:0] key;
    begin
        key = {ad[11:10], 4'd0, ad[20:12], ad[9:1]};       // {bank, row, column} as in sdram_model
        w = u_sdram.mem.exists(key) ? u_sdram.mem[key] : 16'h0000;
        sd_peek = ad[0] ? w[15:8] : w[7:0];
    end
endfunction

//-----------------------------------------------------------------------------
// counters
//-----------------------------------------------------------------------------
integer n_nmi = 0, n_sio = 0, n_frames = 0;
reg nmi_d = 1;
always @(posedge clk) begin
    nmi_d <= u_sys.a_nmi_n;
    if (nmi_d && !u_sys.a_nmi_n) n_nmi++;
end
always @(posedge clk) if (u_sys.u_pokey.serout_wr) begin
    n_sio++;
    if (n_sio > 16 && n_sio <= 60) $display("%t SEROUT %02h (SIO command line %0d)", $time, u_sys.u_pokey.serout, sio_cmd_n);
end

//-----------------------------------------------------------------------------
// text screen (internal codes) and the frame grab
//-----------------------------------------------------------------------------
string screen_txt;
task automatic show_screen;
    integer r, c;
    reg [15:0] sav;
    reg [7:0]  b, ch;
    string line;
    begin
        sav = {sd_peek(20'h00059), sd_peek(20'h00058)};
        screen_txt = "";
        $display("%t screen at $%04h:", $time, sav);
        for (r = 0; r < 24; r++) begin
            line = "";
            for (c = 0; c < 40; c++) begin
                b  = sd_peek({4'd0, sav + 16'(r * 40 + c)}) & 8'h7F;
                ch = b < 8'h40 ? b + 8'h20 : b < 8'h60 ? b - 8'h40 : b;
                if (ch < 8'h20 || ch > 8'h7E) ch = ".";
                line = {line, string'(ch)};
            end
            $display("  |%s|", line);
            screen_txt = {screen_txt, line, "\n"};
        end
    end
endtask

function automatic bit has_text(input string s, input string t);
    integer i;
    has_text = 0;
    for (i = 0; i + t.len() <= s.len(); i++) if (s.substr(i, i + t.len() - 1) == t) has_text = 1;
endfunction

reg [7:0] frame [0:239][0:375];
always @(posedge clk) if (px_stb && px_vc >= 9'd8 && px_vc < 9'd248 && px_cc >= 8'h22 && px_cc < 8'hDE) begin
    frame[px_vc - 8][(px_cc - 8'h22) * 2]     <= px0;
    frame[px_vc - 8][(px_cc - 8'h22) * 2 + 1] <= px1;
end

// PAL palette: hue angle (table 14), luminance 0-15 (bits 7:4 hue, 3:0 luminance)
function automatic [23:0] rgb(input [7:0] c);
    real ang [1:15] = '{135.0, 112.5, 90.0, 67.5, 45.0, 22.5, 337.5, 315.0, 292.5, 270.0, 225.0, 202.5, 180.0, 157.5, 135.0};
    real y, u, v, r, g, b, th;
    begin
        y = c[3:0] / 15.0;
        if (c[7:4] == 0) begin u = 0; v = 0; end
        else begin th = ang[c[7:4]] * 3.14159265 / 180.0; u = 0.15 * $cos(th); v = 0.15 * $sin(th); end
        r = y + 1.140 * v; g = y - 0.395 * u - 0.581 * v; b = y + 2.032 * u;
        r = r < 0 ? 0 : r > 1 ? 1 : r; g = g < 0 ? 0 : g > 1 ? 1 : g; b = b < 0 ? 0 : b > 1 ? 1 : b;
        rgb = {8'(int'(r * 255)), 8'(int'(g * 255)), 8'(int'(b * 255))};
    end
endfunction

task automatic grab(input string fn);
    integer fd, x, yy;
    reg [23:0] p;
    begin
        fd = $fopen(fn, "w");
        $fwrite(fd, "P3\n376 240\n255\n");
        for (yy = 0; yy < 240; yy++)
            for (x = 0; x < 376; x++) begin
                p = rgb(frame[yy][x]);
                $fwrite(fd, "%0d %0d %0d\n", p[23:16], p[15:8], p[7:0]);
            end
        $fclose(fd);
        $display("%t frame written to %s", $time, fn);
    end
endtask

//-----------------------------------------------------------------------------
// SIO bridge + disk drive model (the ESP32's part, LSpectrum/esp32/src/atari.cpp)
//-----------------------------------------------------------------------------
reg  [31:0] mclr = 0;
reg         mclr_we = 0;
wire [31:0] mstat;
atari_sio u_sio (
    .clk_sd(clk_sd), .rst_n(rst_n), .so_stb(so_stb), .so_byte(so_byte), .cmd_n(sio_cmd_n),
    .motor_n(sio_motor_n), .sio_in(sio_in), .mctl(32'd0), .mstat(mstat), .mclr(mclr), .mclr_we(mclr_we));

`ifdef DISK
reg [7:0] boot [0:127];
reg [7:0] disk [0:65535];
`ifdef XEX
initial $readmemh("disk.mem", disk);
`endif
initial begin : bootsec
    integer i;
    reg [7:0] code [0:22];
    reg [7:0] msg [0:12];
    for (i = 0; i < 128; i++) boot[i] = 8'h00;
    // flags, 1 sector, load $0700, init $0706; code at $0706 (the OS calls load + 6)
    boot[0] = 8'h00; boot[1] = 8'h01; boot[2] = 8'h00; boot[3] = 8'h07; boot[4] = 8'h06; boot[5] = 8'h07;
    code = '{8'hA0, 8'h00,                  // $0706 LDY #0
             8'hB9, 8'h16, 8'h07,           // $0708 LDA $0716,Y
             8'h30, 8'h06,                  // $070B BMI $0713
             8'h91, 8'h58,                  // $070D STA (SAVMSC),Y
             8'hC8,                         // $070F INY
             8'h4C, 8'h08, 8'h07,           // $0710 JMP $0708
             8'h4C, 8'h13, 8'h07,           // $0713 JMP $0713
             8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00};
    msg  = '{8'h24, 8'h29, 8'h33, 8'h2B, 8'h00, 8'h22, 8'h2F, 8'h2F, 8'h34, 8'h00, 8'h2F, 8'h2B, 8'hFF};  // DISK BOOT OK
    for (i = 0; i < 16; i++) boot[6 + i] = code[i];
    for (i = 0; i < 13; i++) boot[22 + i] = msg[i];
`ifdef INJSTAGE
    begin : s2_boot
        reg [7:0] c [0:63];
        // load $0100 (page 1: no memory stage 2 needs), the OS calls $0106
        c = '{8'h00, 8'h01, 8'h00, 8'h01, 8'h06, 8'h01,
              8'hAD, 8'h80, 8'h01,  8'hF0, 8'hFB,  8'hC9, 8'h01,  8'hD0, 8'h0C,    // $0106 LDA $0180 / BEQ / CMP #1 / BNE $011B
              8'h78,  8'hA9, 8'h00,  8'h8D, 8'h0E, 8'hD4,  8'h8D, 8'h80, 8'h01,   // $010F SEI / LDA #0 / STA NMIEN / STA $0180
              8'h4C, 8'h06, 8'h01,  8'hEA,                                        // $0118 JMP $0106
              8'hA9, 8'hFE,  8'h8D, 8'h01, 8'hD3,                                 // $011B PORTB = $FE
              8'hA9, 8'h58,  8'h8D, 8'h02, 8'hD4,  8'hA9, 8'h04,  8'h8D, 8'h03, 8'hD4,  8'h8D, 8'h09, 8'hD4,
              8'hA9, 8'h21,  8'h8D, 8'h00, 8'hD4,                                 // DLIST $0458, CHBASE $04, DMACTL $21
              8'hA2, 8'h00,  8'h9A,  8'hA2, 8'h00,  8'hA0, 8'h00,  8'hA9, 8'h00,  // $0133 LDX #S / TXS / LDX #X / LDY #Y / LDA #A
              8'h38,  8'h4C, 8'h12, 8'h08};                                       // $013C SEC / JMP $0812
        for (i = 0; i < 128; i++) boot[i] = 8'h00;
        for (i = 0; i < 64; i++) boot[i] = c[i];
    end
`endif
`ifdef INJECT
    begin : inj_boot
        reg [7:0] c [0:40];
        // $0706 BASIC off (PORTB bit 1, BASICF), then the mailbox loop at $0713:
        // 0 wait, 1 JSR (INITAD) then mailbox = 0, 2 JMP (RUNAD)
        c = '{8'hAD, 8'h01, 8'hD3,  8'h09, 8'h02,  8'h8D, 8'h01, 8'hD3,     // $0706 LDA PORTB / ORA #2 / STA PORTB
              8'hA9, 8'h01,  8'h8D, 8'hF8, 8'h03,                          // $070E LDA #1 / STA BASICF
              8'hAD, 8'h00, 8'h06,  8'hF0, 8'hFB,                          // $0713 LDA $0600 / BEQ $0713
              8'hC9, 8'h01,  8'hD0, 8'h0B,                                 // $0718 CMP #1 / BNE $0727
              8'h20, 8'h2C, 8'h07,                                         // $071C JSR $072C
              8'hA9, 8'h00,  8'h8D, 8'h00, 8'h06,                          // $071F LDA #0 / STA $0600
              8'h4C, 8'h13, 8'h07,                                         // $0724 JMP $0713
              8'h6C, 8'hE0, 8'h02,                                         // $0727 JMP (RUNAD)
              8'hEA, 8'hEA,                                                // $072A
              8'h6C, 8'hE2, 8'h02};                                        // $072C JMP (INITAD)
        for (i = 6; i < 128; i++) boot[i] = 8'h00;
        for (i = 0; i < 41; i++) boot[6 + i] = c[i];
    end
`endif
end

function automatic [7:0] csum(input [7:0] d [], input integer n);
    integer i, sm;
    sm = 0;
    for (i = 0; i < n; i++) begin sm = sm + d[i]; sm = (sm & 255) + (sm >> 8); end
    csum = sm[7:0];
endfunction

task automatic push(input [7:0] b);
    @(posedge clk_sd); mclr <= {23'd0, 1'b1, b}; mclr_we <= 1'b1;
    @(posedge clk_sd); mclr_we <= 1'b0;
endtask
task automatic pop;
    @(posedge clk_sd); mclr <= 32'h200; mclr_we <= 1'b1;
    @(posedge clk_sd); mclr_we <= 1'b0;
    repeat (4) @(posedge clk_sd);
endtask
task automatic result(input [7:0] b);       // after the ACK: sent, then >= 250 us dead time
    wait (mstat[13]);
    #300us;
    push(b);
endtask

integer n_cmd = 0;
initial begin : drive
    reg [7:0] cf [5];
    reg [7:0] d [];
    integer cn, i, sec;
    cn = 0;
    forever begin
        @(posedge clk_sd);
        if (mstat[8]) begin
            if (mstat[9]) begin
                if (mstat[10]) cn = 0;
                if (cn < 5) begin cf[cn] = mstat[7:0]; cn++; end
            end
            pop;
        end else if (cn == 5 && !mstat[11]) begin
            cn = 0;
            n_cmd++;
            sec = cf[2] + 256 * cf[3];
            $display("%t D1 command %02h %02h %02h %02h %02h", $time, cf[0], cf[1], cf[2], cf[3], cf[4]);
            if (cf[0] == 8'h31 && cf[1] == 8'h53) begin
                push(8'h41);
                d = new[4]; d = '{8'h00, 8'hFF, 8'hE0, 8'h00};
                result(8'h43);
                for (i = 0; i < 4; i++) push(d[i]);
                push(csum(d, 4));
            end else if (cf[0] == 8'h31 && cf[1] == 8'h52) begin
                push(8'h41);
                d = new[128];
`ifdef XEX
                for (i = 0; i < 128; i++) d[i] = disk[(sec - 1) * 128 + i];
`else
                for (i = 0; i < 128; i++) d[i] = sec == 1 ? boot[i] : 8'h00;
`endif
                result(8'h43);
                for (i = 0; i < 128; i++) push(d[i]);
                push(csum(d, 128));
            end else if (cf[0] == 8'h31)
                push(8'h4E);
        end
    end
end
`endif

`ifdef CART
// test cartridge: $A000 LDY #0 / LDA $A010,Y / BMI $A00D / STA (SAVMSC),Y / INY / BNE $A002 / JMP $A00D,
// "CART OK" at $A010; $BFFA start $A000, $BFFC 0 (present), $BFFD 4 (run it, no disk boot), $BFFE init $A00C (RTS)
initial begin : cartimg
    reg [7:0] c [0:23];
    reg [7:0] b1 [0:16];
    integer i;
    c = '{8'hA0, 8'h00, 8'hB9, 8'h10, 8'hA0, 8'h30, 8'h06, 8'h91, 8'h58, 8'hC8, 8'hD0, 8'hF6,
          8'h60, 8'h4C, 8'h0D, 8'hA0,
          8'h23, 8'h21, 8'h32, 8'h34, 8'h00, 8'h2F, 8'h2B, 8'hFF};
    #1;
    if (`CART == 1) begin
        for (i = 0; i < 24; i++) sd_poke(21'h28000 + i, c[i]);
        sd_poke(21'h29FFA, 8'h00); sd_poke(21'h29FFB, 8'hA0); sd_poke(21'h29FFC, 8'h00);
        sd_poke(21'h29FFD, 8'h04); sd_poke(21'h29FFE, 8'h0C); sd_poke(21'h29FFF, 8'hA0);
    end else begin
        // bank 0: $A000 LDA $D501 (-> bank 1), $A00C RTS (init); header as above
        sd_poke(21'h100000, 8'hAD); sd_poke(21'h100001, 8'h01); sd_poke(21'h100002, 8'hD5);
        sd_poke(21'h10000C, 8'h60);
        sd_poke(21'h101FFA, 8'h00); sd_poke(21'h101FFB, 8'hA0); sd_poke(21'h101FFC, 8'h00);
        sd_poke(21'h101FFD, 8'h04); sd_poke(21'h101FFE, 8'h0C); sd_poke(21'h101FFF, 8'hA0);
        // bank 1 from $A003: LDY #0 / LDA $A020,Y / BMI $A010 / STA (SAVMSC),Y / INY / BNE $A005 / NOP /
        // $A010 JMP $A010; "BANK OK" at $A020
        b1 = '{8'hA0, 8'h00, 8'hB9, 8'h20, 8'hA0, 8'h30, 8'h06, 8'h91, 8'h58, 8'hC8, 8'hD0, 8'hF6, 8'hEA,
               8'h4C, 8'h10, 8'hA0, 8'h00};
        for (i = 0; i < 16; i++) sd_poke(21'h102003 + i, b1[i]);
        c = '{8'h22, 8'h21, 8'h2E, 8'h2B, 8'h00, 8'h2F, 8'h2B, 8'hFF, 8'h00, 8'h00, 8'h00, 8'h00,
              8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00};
        for (i = 0; i < 8; i++) sd_poke(21'h102020 + i, c[i]);
    end
end
`endif

// one VGA frame (active area) from the frame buffer: from a vsync to the next
reg [17:0] vga [0:VH-1][0:VW-1];
task automatic grab_vga(input string fn);
    integer fd, x, y, n;
    begin
        @(negedge v_vs);                // negative syncs
        @(posedge v_vs);
        x = 0; y = 0; n = 0;
        while (v_vs) begin
            @(posedge pclk);
            if (v_act) begin
                if (y < VH && x < VW) vga[y][x] = v_rgb;
                x++; n++;
            end else if (x != 0) begin
                x = 0; y++;
            end
        end
        fd = $fopen(fn, "w");
        $fwrite(fd, "P3\n%0d %0d\n255\n", VW, VH);   // 6-bit colours to 8 bits
        for (y = 0; y < VH; y++)
            for (x = 0; x < VW; x++)
                $fwrite(fd, "%0d %0d %0d\n", {vga[y][x][17:12], vga[y][x][17:16]},
                        {vga[y][x][11:6], vga[y][x][11:10]}, {vga[y][x][5:0], vga[y][x][5:4]});
        $fclose(fd);
        $display("%t VGA frame written to %s (%0d active pixels)", $time, fn, n);
    end
endtask

`ifdef INJECT
`ifndef INJ_WATCH
 `define INJ_WATCH 16'h9D00
`endif
reg inj_run = 1'b0;                                 // RUNAD taken: from here the watch counts
reg [7:0] xf [0:131071];
integer   xn;
initial begin : injector
    integer fd, p, s, e, k, nseg;
    fd = $fopen(`INJECT, "rb");
    if (fd == 0) begin $display("FAIL: cannot open %s", `INJECT); $finish; end
    xn = $fread(xf, fd);
    $fclose(fd);
    $display("INJECT: %s, %0d bytes", `INJECT, xn);
    wait (u_sys.ld_done);
    wait (u_sys.cpu_sync && u_sys.cpu_a == 16'h0713);   // an opcode fetch: the boot sector waits on the mailbox
                                                    // (the address alone also matches the OS clearing memory)
    #100us;
    $display("%t INJECT: boot sector running, BASIC off; loading the segments", $time);
    p = 0; nseg = 0;
    while (p + 4 <= xn) begin
        if (xf[p] == 8'hFF && xf[p + 1] == 8'hFF) p = p + 2;
        s = xf[p] | (xf[p + 1] << 8);
        e = xf[p + 2] | (xf[p + 3] << 8);
        p = p + 4;
        sd_poke(21'h002E2, 8'h00); sd_poke(21'h002E3, 8'h00);     // INITAD cleared before each segment
        for (k = s; k <= e && p < xn; k++) begin sd_poke({5'd0, k[15:0]}, xf[p]); p = p + 1; end
        $display("%t INJECT: segment %0d $%04h-$%04h", $time, nseg, s, e);
        nseg++;
        if (sd_peek(21'h002E2) != 0 || sd_peek(21'h002E3) != 0) begin
            $display("%t INJECT: INITAD $%02h%02h called", $time, sd_peek(21'h002E3), sd_peek(21'h002E2));
            sd_poke(21'h00600, 8'h01);
            while (sd_peek(21'h00600) != 0) #20us;
            $display("%t INJECT: INITAD returned", $time);
        end
    end
`ifdef INJRAM
`ifndef INJ_RUN
 `define INJ_RUN 16'h9D00
`endif
    begin : injram
        reg [7:0] im [0:65535];
        integer f2, k2, n2;
        reg [15:0] run;
        f2 = $fopen(`INJRAM, "rb");
        n2 = $fread(im, f2);
        $fclose(f2);
        for (k2 = 'h0800; k2 < 65536; k2++)                 // (a 16-bit 16'h10000 would be 0: no write at all)
            if (k2 < 16'hD000 || k2 >= 16'hD800) sd_poke({5'd0, k2[15:0]}, im[k2]);
        run = `INJ_RUN;
        sd_poke(21'h002E0, run[7:0]); sd_poke(21'h002E1, run[15:8]);
        $display("%t INJECT: memory image %s (%0d bytes) in, run at $%04h; $9D00: %02h %02h %02h %02h %02h %02h %02h %02h",
                 $time, `INJRAM, n2, run, sd_peek(21'h09D00), sd_peek(21'h09D01), sd_peek(21'h09D02), sd_peek(21'h09D03),
                 sd_peek(21'h09D04), sd_peek(21'h09D05), sd_peek(21'h09D06), sd_peek(21'h09D07));
    end
`endif
    $display("%t INJECT: RUNAD $%02h%02h", $time, sd_peek(21'h002E1), sd_peek(21'h002E0));
    sd_poke(21'h00600, 8'h02);
    inj_run = 1'b1;
end
`ifdef INJRAM
// every SDRAM write into $9D00-$9D07 after the image is in: who and when
initial begin : inj_wwatch
    wait (inj_run);
    forever begin
        @(posedge clk_sd);
        if (u_sys.a_req && u_sys.a_we && u_sys.a_addr >= 21'h09D00 && u_sys.a_addr <= 21'h09D07)
            $display("%t INJECT: write $%05h = %02h (owner %0d: 0 bus, 2 ESP32), CPU A %04h", $time,
                     u_sys.a_addr, u_sys.a_din, u_sys.a_own, u_sys.cpu_a);
    end
end
`endif
`ifdef INJ_TRACE
// opcode fetch addresses from RUNAD on, one per line (compared with a 6502 reference run)
initial begin : inj_trace
    integer ft, nt;
    ft = $fopen("inj_trace.txt", "w");
    nt = 0;
    wait (inj_run);
    while (nt < `INJ_TRACE) begin
        @(posedge clk);
        if (u_sys.cyc_end && u_sys.cpu_cyc && u_sys.a_rdy && u_sys.cpu_sync) begin
            $fwrite(ft, "%04h\n", u_sys.cpu_a);
            nt = nt + 1;
        end
    end
    $fclose(ft);
    $display("%t INJECT: %0d instruction addresses in inj_trace.txt", $time, nt);
end
`endif
initial begin : inj_watch
    wait (inj_run);
    wait (u_sys.cpu_sync && u_sys.cpu_a == `INJ_WATCH);   // an opcode fetch there
    $display("%t INJECT: the CPU reached $%04h; $9D00: %02h %02h %02h %02h %02h %02h %02h %02h", $time, `INJ_WATCH,
             sd_peek(21'h09D00), sd_peek(21'h09D01), sd_peek(21'h09D02), sd_peek(21'h09D03),
             sd_peek(21'h09D04), sd_peek(21'h09D05), sd_peek(21'h09D06), sd_peek(21'h09D07));
`ifdef INJ_DUMP
    // the 64 KB the CPU sees with the OS ROM switched out (physical main RAM), for a byte-by-byte comparison
    begin : dump
        integer fd, k;
        fd = $fopen("inj_dump.bin", "wb");
        for (k = 0; k < 65536; k++) $fwrite(fd, "%c", sd_peek(k[20:0]));
        $fclose(fd);
        $display("%t INJECT: RAM dumped to inj_dump.bin", $time);
    end
    #300ms;
    show_screen;
    grab_vga("vga.ppm");
    $display("RESULT: dump done");
    $finish;
`endif
end
`endif

`ifdef INJSTAGE
reg  [7:0]  s2_im [0:65535];
string      s2_ref [0:4095];
integer     s2_nref;
reg  [15:0] s2_ring [0:399];
initial begin : s2_inject
    integer fd, k, n, a, x, y, sp;
    fd = $fopen("s2_ram.bin", "rb"); n = $fread(s2_im, fd); $fclose(fd);
    fd = $fopen("s2_regs.txt", "r"); k = $fscanf(fd, "%h %h %h %h", a, x, y, sp); $fclose(fd);
    fd = $fopen("s2_ref.txt", "r"); s2_nref = 0;
    while (!$feof(fd) && s2_nref < 4096) begin
        string l;
        if ($fgets(l, fd)) begin s2_ref[s2_nref] = l.substr(0, l.len() - 2); s2_nref++; end
    end
    $fclose(fd);
    $display("INJSTAGE: %0d bytes, A %02h X %02h Y %02h S %02h, %0d reference lines", n, a, x, y, sp, s2_nref);
    wait (u_sys.ld_done);
    wait (u_sys.cpu_sync && u_sys.cpu_a == 16'h0106);
    #100us;
    sd_poke(21'h00180, 8'h01);                       // interrupts off
    while (sd_peek(21'h00180) != 0) #20us;
    for (k = 0; k < 65536; k++)
        if (k < 'h100 || (k >= 'h200 && k < 'hD000) || k >= 'hD800) sd_poke(k[20:0], s2_im[k]);
    // operands of LDX #S / LDX #X / LDY #Y / LDA #A at $0133.. (after the NOP at $011B)
    sd_poke(21'h00134, sp[7:0]); sd_poke(21'h00137, x[7:0]); sd_poke(21'h00139, y[7:0]); sd_poke(21'h0013B, a[7:0]);
    $display("%t INJSTAGE: state in, starting stage 2", $time);
    sd_poke(21'h00180, 8'h02);
end
initial begin : s2_check
    integer cnt, line, z;
    string  got;
    reg [7:0] zp [0:10];
    wait (u_sys.cpu_sync && u_sys.cpu_a == 16'h0812 && u_sys.cyc_end && u_sys.cpu_cyc);
    $display("%t INJSTAGE: $0812 reached", $time);
    cnt = 0; line = 0;
    forever begin
        @(posedge clk);
        if (u_sys.cyc_end && u_sys.cpu_cyc && u_sys.a_rdy && u_sys.cpu_sync) begin
            s2_ring[cnt % 400] = u_sys.cpu_a;
            if (u_sys.cpu_a == 16'h089D) begin
                $display("%t INJSTAGE: stage 2 done after %0d instructions (reference 1403806), all %0d checks equal",
                         $time, cnt, line);
                $display("RESULT: stage 2 PASS"); $finish;
            end
            if (cnt % 500 == 0 && line < s2_nref) begin
                got = $sformatf("%02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x",
                                sd_peek(21'hD0), sd_peek(21'hD1), sd_peek(21'hD2), sd_peek(21'hD3), sd_peek(21'hF0),
                                sd_peek(21'hF1), sd_peek(21'hF2), sd_peek(21'hF3), sd_peek(21'hF4), sd_peek(21'hF5),
                                sd_peek(21'hF6));
                if (got != s2_ref[line]) begin
                    integer fr, j;
                    $display("%t INJSTAGE: MISMATCH at instruction %0d (check %0d)", $time, cnt, line);
                    $display("   reference: %s", s2_ref[line]);
                    $display("   LTari    : %s", got);
                    $display("   previous check (equal): instruction %0d", cnt - 500);
                    fr = $fopen("s2_rtl_pcs.txt", "w");
                    for (j = 0; j < 400; j++) $fwrite(fr, "%0d %04h\n", cnt - 399 + j, s2_ring[(cnt + 1 + j) % 400]);
                    $fclose(fr);
                    $display("RESULT: stage 2 MISMATCH"); $finish;
                end
                line++;
            end
            cnt++;
        end
    end
end
`endif

//-----------------------------------------------------------------------------
// run
//-----------------------------------------------------------------------------
initial begin
    integer t_ms, errors;
    errors = 0;
    wait (u_sys.ld_done);
    $display("%t ROMs loaded and RAM cleared (bad_image %0d); OS reset vector %02h%02h", $time, bad,
             sd_peek(20'h24FFD), sd_peek(20'h24FFC));
    for (t_ms = 50; t_ms <= `RUN_MS; t_ms += 50) begin
        #50ms;
        $display("%t %0d ms: CPU A %04h  VCOUNT %0d  NMIs %0d  SIO bytes %0d  DLIST %04h  DMACTL %02h  PORTB %02h",
                 $time, t_ms, u_sys.cpu_a, u_sys.u_antic.vc, n_nmi, n_sio, u_sys.u_antic.dlist,
                 u_sys.u_antic.dmactl, u_sys.pb);
        show_screen;
`ifdef CART
        if (has_text(screen_txt, "CART OK") || has_text(screen_txt, "BANK OK")) break;
`elsif XEX
        if (has_text(screen_txt, "XEX OK") || has_text(screen_txt, "XEX BAD")) break;
`elsif INJECT
        ;                                               // runs RUN_MS
`elsif DISK
        if (has_text(screen_txt, "DISK BOOT OK")) break;
`else
        if (has_text(screen_txt, "READY") || has_text(screen_txt, "Ready")) break;
`endif
    end
    if (bad) begin $display("FAIL: bad ROM image"); errors++; end
`ifdef CART
    if (!has_text(screen_txt, `CART == 1 ? "CART OK" : "BANK OK")) begin $display("FAIL: no CART OK / BANK OK"); errors++; end
`elsif XEX
    if (!has_text(screen_txt, "XEX OK")) begin $display("FAIL: no XEX OK on the screen"); errors++; end
`elsif INJECT
    ;
`elsif DISK
    if (!has_text(screen_txt, "DISK BOOT OK")) begin $display("FAIL: no DISK BOOT OK on the screen"); errors++; end
`else
    if (!has_text(screen_txt, "READY") && !has_text(screen_txt, "Ready")) begin $display("FAIL: no Ready on the screen"); errors++; end
`endif
    if (n_nmi < 2) begin $display("FAIL: no VBI NMIs"); errors++; end
`ifdef SNAPTEST
    begin : snaptest
        reg [63:0] r0;
        reg [7:0]  s;
        integer    n0, i, k;
        reg [7:0]  prog [0:15];
        wait (u_sys.u_antic.vc == 9'd100);                 // far from the VBI: the CPU is in the cartridge loop
        wait (u_sys.cpu_a == 16'hA00D);
        t_frz = 1'b1;
        fork
            begin wait (t_frozen); end
            begin #100us; end
        join_any
        disable fork;
        if (!t_frozen) begin $display("FAIL: no freeze"); errors++; end
        r0 = t_regs;
        $display("%t frozen: PC %04h S %02h P %02h A %02h X %02h Y %02h", $time, r0[63:48], r0[39:32],
                 r0[31:24], r0[7:0], r0[15:8], r0[23:16]);
        if (r0[63:48] != 16'hA00D) begin $display("FAIL: PC not $A00D (the cartridge's loop)"); errors++; end
        $display("COLBK shadow %02h, COLOR4 %02h", sd_peek(21'h3D01A), sd_peek(21'h002C8));
        if (sd_peek(21'h3D01A) != sd_peek(21'h002C8)) begin $display("FAIL: I/O shadow"); errors++; end
        #20us;
        if (u_sys.cpu_a != r0[63:48]) begin $display("FAIL: CPU moved while frozen"); errors++; end
        // restore program at bank $2000: SEI / LDA #$77 / STA $D200 / LDX #S-3 / TXS / LDA #A / LDX #X /
        // LDY #Y / RTI; the stack bytes for the RTI and the reset vector written directly
        s = r0[39:32];
        prog = '{8'h78, 8'hA9, 8'h77, 8'h8D, 8'h00, 8'hD2, 8'hA2, s - 8'd3, 8'h9A, 8'hA9, r0[7:0],
                 8'hA2, r0[15:8], 8'hA0, r0[23:16], 8'h40};
        for (i = 0; i < 16; i++) sd_poke(21'h32000 + i, prog[i]);
        sd_poke({13'h0301, s - 8'd2}, r0[31:24]);           // 0x30100 + S-2: P
        sd_poke({13'h0301, s - 8'd1}, r0[55:48]);           // PCL
        sd_poke({13'h0301, s},        r0[63:56]);           // PCH
        sd_poke(21'h3FFFC, 8'h00); sd_poke(21'h3FFFD, 8'h20);
        n0 = n_nmi;
        t_rm = 1'b1; t_rst = 1'b1;
        #1us t_frz = 1'b0;
        #2us t_rst = 1'b0;
        k = 0;
        fork
            begin wait (t_rmode); wait (!t_rmode); k = 1; end
            begin #2ms; end
        join_any
        disable fork;
        t_rm = 1'b0;
        if (!k) begin $display("FAIL: restore mode did not end"); errors++; end
        $display("%t restore mode over: CPU A %04h, AUDF1 %02h, shadow %02h", $time, u_sys.cpu_a,
                 u_sys.u_pokey.audf[1], sd_peek(21'h3D200));
        if (u_sys.u_pokey.audf[1] != 8'h77 || sd_peek(21'h3D200) != 8'h77) begin $display("FAIL: restore program"); errors++; end
        #200us;
        $display("%t after: PC %04h A %02h X %02h Y %02h S %02h", $time, t_regs[63:48], t_regs[7:0], t_regs[15:8],
                 t_regs[23:16], t_regs[39:32]);
        if (u_sys.cpu_a < 16'hA00D || u_sys.cpu_a > 16'hA00F) begin $display("FAIL: CPU not back in its loop"); errors++; end
        if (t_regs[7:0] != r0[7:0] || t_regs[15:8] != r0[15:8] || t_regs[23:16] != r0[23:16] || t_regs[39:32] != r0[39:32])
            begin $display("FAIL: registers changed"); errors++; end
        #40ms;
        if (n_nmi < n0 + 2) begin $display("FAIL: no NMIs after the restore"); errors++; end
        $display("%t NMIs since the freeze: %0d", $time, n_nmi - n0);
        show_screen;
        if (!has_text(screen_txt, "CART OK")) begin $display("FAIL: screen lost"); errors++; end
    end
`endif
    grab("screen.ppm");
    grab_vga("vga.ppm");
    if (errors) $display("RESULT: FAIL"); else $display("RESULT: PASS");
    $finish;
end

endmodule
