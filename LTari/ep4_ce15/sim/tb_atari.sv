/* tb_atari -- LTari (atari_system) boot: AltirraOS cold start -> Altirra BASIC READY */
/* */
/* ROM image atarirom.mem (tools/mk_atarirom.py) in the flash model, bit-reversed as in */
/* the .jic -> ROM loader -> SDRAM model -> T65 runs AltirraOS. No SIO device answers, so */
/* the OS's disk boot attempt has to time out before BASIC starts. */
/* +define+RUN_MS=<ms>   longest simulated time (default 4000); stops at "READY" */
/* +define+M800          800XL (64 KB) instead of the 130XE */
/* +define+DISK          a disk drive D1: answers through the SIO bridge (atari_sio, as the ESP32 does, */
/* timing of the hardware manual 9.1): status + a boot sector whose code writes */
/* "DISK BOOT OK" to the screen; the run stops there */
/* +define+CART=1        a standard 8 KB test cartridge (written into the SDRAM model at 0x28000): its start */
/* code ($A000) writes "CART OK" to the screen; the run stops there */
/* +define+CART=4        an Atarimax 1 MB test cartridge (0x100000): bank 0 starts, reads $D501 and so goes on */
/* in bank 1, which writes "BANK OK" */
/* +define+SNAPTEST      (with CART=1) after "CART OK": freeze, register read-back, I/O shadow check */
/* (COLBK shadow = the OS's COLOR4), restore program in the restore bank (as the */
/* ESP32 writes it: writes AUDF1, stack, A / X / Y, RTI) run in restore mode after a */
/* CPU-only reset; the CPU must go on in its loop with the same registers */
/* +define+INJECT=\"f.xex\" (with DISK) a binary load file (.xex / .com) without the SIO transfer: the boot */
/* sector switches BASIC off and waits on a mailbox ($0600); the testbench writes the */
/* segments into memory (INITAD cleared before each, as our loader), has the Atari call */
/* INITAD (mailbox 1) when a segment set it, and finally jump through RUNAD (mailbox 2). */
/* Runs RUN_MS; reports when the CPU reaches INJ_WATCH (default $9D00); pictures at the end */
/* +define+INJRAM=\"f.bin\" (with INJECT) after the segments, a 64 KB memory image (e.g. a depacked demo */
/* from a 6502 run) replaces RAM $0800-$CFFF and $D800-$FFFF before the jump (pages 0-7 */
/* stay: OS variables and the boot sector), and RUNAD = INJ_RUN (default $9D00) */
/* +define+INJ_DUMP      (with INJECT) at the first opcode fetch at INJ_WATCH: 64 KB RAM to inj_dump.bin, 300 ms */
/* more, then stop */
/* +define+INJSTAGE      (with DISK) stage 2 of a depacker from a 6502 reference run: boot sector in page 1 */
/* (mailbox $0180: 1 = SEI + NMIEN 0, 2 = PORTB $FE, ANTIC as the depacker, registers, */
/* JMP $0812), memory s2_ram.bin written ($0000-$00FF, $0200-$CFFF, $D800-$FFFF), */
/* registers s2_regs.txt; every 500 instructions from $0812 the zero-page pointers are */
/* compared with s2_ref.txt; the first mismatch stops the run with the last 400 PCs */
/* +define+TRIG_MS=<ms>  joystick 0's trigger pressed at <ms> for TRIG_LEN ms (default 300; pictures trig_pre.ppm */
/* 20 ms before, trig_post.ppm 200 ms after the release; CPU addresses every 1 ms meanwhile) */
/* +define+XEX           the same drive serving disk.mem (mk_xextest.py: our .xex boot loader + a test */
/* .xex, as the ESP32 serves an .xex); the run stops at "XEX OK" (or "XEX BAD") */
/* Output every 50 ms: CPU address, VCOUNT, NMIs, SIO bytes sent, the text screen (from */
/* SAVMSC, $58/$59, internal codes decoded); at the end screen.ppm (one GTIA frame, 376 x */
/* 240 hi-res pixels, palette from the PAL hue angles of the hardware manual, table 14) */
/* and vga.ppm: one frame from the frame buffer (atari_fb, the board's video path: 640 x 480 */
/* at 60 Hz, 25.208 MHz; +define+VGA50: 720 x 576 at 50 Hz, 27.009 MHz; its SDRAM port loads */
/* the arbiter as on the board). */
`timescale 1ns/1ps
`ifdef XEX
 `define DISK
/* the end of the cartridge switch */
`endif
/* the longest simulated time, in milliseconds */
`ifndef RUN_MS
 `define RUN_MS 4000
`endif

/* the testbench */
module tb_atari;

/* clk toggles on every third edge of clk_sd */
localparam integer PH_LAST = 2;
/* the reset ends after 300 ns */
localparam integer RST_NS = 300;
/* half a period of the 27.009 MHz pixel clock, ns */
localparam real PCLK_HALF_50 = 18.512;
/* half a period of the 25.208 MHz pixel clock, ns */
localparam real PCLK_HALF_60 = 19.835;
/* the pixel domain's reset ends after 1000 ns */
localparam integer PRST_NS = 1000;
/* both data masks high */
localparam integer DQM_OFF = 3;
/* SIO bytes sent before the log starts */
localparam integer SIO_LOG_FIRST = 16;
/* the last SIO byte logged */
localparam integer SIO_LOG_LAST = 60;
/* rows of the text screen */
localparam integer TEXT_ROWS = 24;
/* columns of the text screen */
localparam integer TEXT_COLS = 40;
/* internal code without the inverse bit */
localparam [7:0] CODE_MASK = 8'h7F;
/* first internal code of the second block (ASCII control characters) */
localparam [7:0] CODE_BLOCK2 = 8'h40;
/* ASCII space; also the offset of the first internal code block */
localparam [7:0] ASCII_SPACE = 8'h20;
/* first internal code of the third block (lower case) */
localparam [7:0] CODE_BLOCK3 = 8'h60;
/* last printable ASCII character */
localparam [7:0] ASCII_LAST = 8'h7E;
/* first visible line */
localparam [8:0] VC_VIS_BEG = 9'd8;
/* first line after the visible part */
localparam [8:0] VC_VIS_END = 9'd248;
/* first visible colour clock */
localparam [7:0] CC_VIS_BEG = 8'h22;
/* first colour clock after the visible part */
localparam [7:0] CC_VIS_END = 8'hDE;
/* highest luminance value of a colour */
localparam real LUM_MAX = 15.0;
/* pi */
localparam real PI = 3.14159265;
/* degrees of half a turn */
localparam real HALF_TURN = 180.0;
/* colour saturation of the picture files */
localparam real CHROMA = 0.15;
/* YUV to RGB: red from V */
localparam real R_V = 1.140;
/* YUV to RGB: green from U */
localparam real G_U = 0.395;
/* YUV to RGB: green from V */
localparam real G_V = 0.581;
/* YUV to RGB: blue from U */
localparam real B_U = 2.032;
/* highest value of a colour byte */
localparam integer RGB_MAX = 255;
/* lines of the picture file */
localparam integer PIC_H = 240;
/* pixels per line of the picture file */
localparam integer PIC_W = 376;
/* bytes of a disk sector */
localparam integer SECTOR = 128;
/* bytes of the plain boot code */
localparam integer BOOT_CODE_LEN = 16;
/* characters of the boot sector's message */
localparam integer MSG_LEN = 13;
/* bytes of the stage test's boot code */
localparam integer STAGE_CODE_LEN = 64;
/* bytes of the boot sector's header */
localparam integer BOOT_HDR = 6;
/* bytes of the injection test's boot code */
localparam integer INJ_CODE_LEN = 41;
/* the low byte of the checksum's sum */
localparam integer BYTE_MASK = 255;
/* bits of a byte */
localparam integer BYTE_BITS = 8;
/* SIO bridge strobe: take a received byte */
localparam [31:0] MCLR_POP = 32'h200;
/* clocks until the next received byte shows */
localparam integer POP_CLKS = 4;
/* bytes of an SIO command frame */
localparam integer CMD_FRAME = 5;
/* weight of the sector number's high byte */
localparam integer BYTE_RANGE = 256;
/* SIO device: drive 1 */
localparam [7:0] SIO_D1 = 8'h31;
/* SIO command: status */
localparam [7:0] SIO_STATUS = 8'h53;
/* bytes of the drive's status */
localparam integer STATUS_LEN = 4;
/* SIO command: read sector */
localparam [7:0] SIO_READ = 8'h52;
/* bytes of the 8 KB cartridge's code */
localparam integer CART_CODE_LEN = 24;
/* bytes of the code in bank 1 */
localparam integer BANK1_CODE_LEN = 16;
/* characters of the text in bank 1 */
localparam integer BANK1_TEXT_LEN = 8;
/* bytes of a segment header: start and end address */
localparam integer SEG_HDR = 4;
/* bytes of the FFFF marker of a load file */
localparam integer MARK_LEN = 2;
/* the memory image replaces RAM from $0800 up */
localparam integer IMG_FIRST = 'h0800;
/* bytes of the 64 KB address space */
localparam integer MEM_64K = 65536;
/* first address of the I/O area, 16 bits */
localparam [15:0] IO_FIRST16 = 16'hD000;
/* first address after the I/O area, 16 bits */
localparam [15:0] IO_END16 = 16'hD800;
/* first address of the watched range */
localparam [20:0] WATCH_FIRST = 21'h09D00;
/* last address of the watched range */
localparam [20:0] WATCH_LAST = 21'h09D07;
/* reference lines that fit */
localparam integer REF_MAX = 4096;
/* characters cut from a reference line (the line end) */
localparam integer EOL_LEN = 2;
/* start of the stack page */
localparam integer PAGE1 = 'h100;
/* first address after the stack page */
localparam integer PAGE2 = 'h200;
/* first address of the I/O area */
localparam integer IO_FIRST = 'hD000;
/* first address after the I/O area */
localparam integer IO_END = 'hD800;
/* address at which stage 2 of the depacker is done */
localparam [15:0] S2_END = 16'h089D;
/* instructions between two checks against the reference */
localparam integer CHECK_EVERY = 500;
/* instruction addresses kept for the mismatch report */
localparam integer RING = 400;
/* milliseconds logged after the trigger's release */
localparam integer TRIG_AFTER_MS = 200;
/* milliseconds between two reports */
localparam integer STEP_MS = 50;
/* NMIs that must have come */
localparam integer NMI_MIN = 2;
/* address of the test cartridge's endless loop */
localparam [15:0] CART_LOOP = 16'hA00D;
/* bytes of the restore program */
localparam integer RESTORE_LEN = 16;
/* the value the restore program writes to AUDF1 */
localparam [7:0] RESTORED_AUDF = 8'h77;
/* last byte of the cartridge's loop instruction */
localparam [15:0] CART_LOOP_END = 16'hA00F;
/* clk_sd half period (85.119 MHz); clk = clk_sd / 3 */
localparam realtime HSD = 5.8742;
localparam real T_CK  = 2 * HSD;
/* pin delays, the SDRAM clock's shift */
localparam real TCO   = 4.0;
localparam real TBACK = 0.5;
localparam real SD_SHIFT = 1.339;

/* the two clocks, clk every third edge of clk_sd */
reg clk_sd = 0, clk = 0;
integer ph = 0;
always #(HSD)
begin
/* the faster clock; the phase */
    clk_sd = ~clk_sd;
    ph = (ph == PH_LAST) ? 0 : ph + 1;
    if (ph == 0)
    begin
/* the machine clock; the reset */
        clk = ~clk;
    end
end

reg rst_n = 0;
initial #RST_NS rst_n = 1;

/* the VGA mode: 50 Hz */
`ifdef VGA50
localparam VW = 720, VH = 576, VM60 = 1'b0;
/* VGA pixel clock, 27.009 MHz */
reg pclk = 0;
always #PCLK_HALF_50 pclk = ~pclk;
`else
/* 60 Hz */
localparam VW = 640, VH = 480, VM60 = 1'b1;
/* VGA pixel clock, 25.208 MHz */
reg pclk = 0;
always #PCLK_HALF_60 pclk = ~pclk;
`endif
/* the pixel domain's reset */
reg prst_n = 0;
initial #PRST_NS prst_n = 1;

/* SDRAM pins */
wire        cke, cs_n, ras_n, cas_n, we_n, dq_oe;
wire [1:0]  ba, dqm;
wire [12:0] a;
/* data out and in */
wire [15:0] dq_o;
reg  [15:0] dq_i;
wire        f_dclk, f_ncs, f_mosi, f_miso;
/* SIO lines, pixel output, flags */
wire        sio_out, sio_cmd_n, sio_motor_n;
wire        px_stb, px_blank, spk, bad;
wire [7:0]  px_cc, px0, px1;
/* line, audio, the frame buffer's port */
wire [8:0]  px_vc;
wire [5:0]  aud;
wire        fb_req, fb_we, fb_ack, a_run;
/* its address and data; the VGA output */
wire [20:0] fb_addr;
wire [15:0] fb_wdata, fb_rdata;
wire [17:0] v_rgb;
/* syncs; the newest buffer; the SIO bridge's lines */
wire        v_hs, v_vs, v_act;
wire [1:0]  fb_newest;
wire        sio_in, so_stb;
/* the byte the Atari sent */
wire [7:0]  so_byte;

/* joystick triggers (TRIG_MS) */
reg  [1:0]  t_trig = 2'b11;
/* snapshot port (SNAPTEST) */
reg         t_frz = 1'b0, t_rm = 1'b0, t_rst = 1'b0;
wire        t_frozen, t_rmode;
wire [63:0] t_regs;

/* the machine */
atari_system #(.FLASH_DIV(2)) u_sys (
    .clk(clk), .rst_n(rst_n), .clk_sd(clk_sd), .rst_sd_n(rst_n),
    .freeze(t_frz), .rm_req(t_rm), .cpu_rst_req(t_rst), .frozen(t_frozen), .rmode(t_rmode), .cpu_regs(t_regs),
    .pia_st(), .cart_st(),
`ifdef M800
    .model130(1'b0),
`else
    .model130(1'b1),
`endif
/* a cartridge, if asked for */
    `ifdef CART
    .reload(1'b0), .cart(`CART), .reset_key(1'b0),
`else
    .reload(1'b0), .cart(3'd0), .reset_key(1'b0),
`endif
/* no keys, no joysticks but the triggers */
    .key_stb(1'b0), .key_code(6'd0), .key_down(1'b0), .key_shift(1'b0), .key_ctrl(1'b0), .key_break(1'b0),
    .consol_n(3'b111), .joy_dir_n(8'hFF), .joy_trig_n(t_trig),
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

flash_model #(.BASE(24'h540000), .LEN(28672), .REVERSE(1), .FILE("atarirom.mem")) u_flash (
    .dclk(f_dclk), .ncs(f_ncs), .mosi(f_mosi), .miso(f_miso));

/* pins as seen by the SDRAM (transport delays, as tb_lspectrum / tb_l64) */
reg         m_clk = 0, m_cke = 0, m_cs_n = 1, m_ras_n = 1, m_cas_n = 1, m_we_n = 1;
reg  [1:0]  m_ba = 0, m_dqm = DQM_OFF;
reg  [12:0] m_a = 0;
/* data */
reg  [15:0] m_dq_drv = 'z;
wire [15:0] m_dq;
always @(clk_sd) m_clk <= #(TCO + SD_SHIFT) ~clk_sd;
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

/* a byte straight into the SDRAM model (cartridge images, INJECT) */
task automatic sd_poke(input [20:0] ad, input [7:0] v);
    logic [23:0] key;
    logic [15:0] w;
    begin
/* the word as it is now */
        key = {ad[11:10], 4'd0, ad[20:12], ad[9:1]};
        w = u_sdram.mem.exists(key) ? u_sdram.mem[key] : 16'h0000;
/* the lane written */
        if (ad[0])
        begin
            w[15:8] = v;
        end
        else
        begin
            w[7:0] = v;
        end
/* back into the model */
        u_sdram.mem[key] = w;
    end
endtask

function automatic [7:0] sd_peek(input [20:0] ad);
    logic [15:0] w;
/* the model's key of the address */
    logic [23:0] key;
    begin
/* {bank, row, column} as in sdram_model */
        key = {ad[11:10], 4'd0, ad[20:12], ad[9:1]};
        w = u_sdram.mem.exists(key) ? u_sdram.mem[key] : 16'h0000;
/* its lane */
        sd_peek = ad[0] ? w[15:8] : w[7:0];
    end
endfunction

/* counters */
integer n_nmi = 0, n_sio = 0, n_frames = 0;
reg nmi_d = 1;
/* the falling edges of the NMI line are counted */
always @(posedge clk)
begin
    nmi_d <= u_sys.a_nmi_n;
    if (nmi_d && !u_sys.a_nmi_n)
    begin
/* counted; the bytes the Atari sends */
        n_nmi++;
    end
end
always @(posedge clk)
    if (u_sys.u_pokey.serout_wr)
    begin
/* counted; some are listed */
        n_sio++;
        if (n_sio > SIO_LOG_FIRST && n_sio <= SIO_LOG_LAST)
        begin
            $display("%t SEROUT %02h (SIO command line %0d)", $time, u_sys.u_pokey.serout, sio_cmd_n);
        end
    end

/* text screen (internal codes) and the frame grab */
string screen_txt;
task automatic show_screen;
    integer r, c;
/* the screen address, a byte, a character */
    reg [15:0] sav;
    reg [7:0]  b, ch;
    string line;
    begin
/* SAVMSC; the text starts empty */
        sav = {sd_peek(20'h00059), sd_peek(20'h00058)};
        screen_txt = "";
        $display("%t screen at $%04h:", $time, sav);
/* 24 lines of 40 characters */
        for (r = 0; r < TEXT_ROWS; r++)
        begin
            line = "";
            for (c = 0; c < TEXT_COLS; c++)
            begin
/* the internal code as ASCII */
                b  = sd_peek({4'd0, sav + 16'(r * TEXT_COLS + c)}) & CODE_MASK;
                ch = b < CODE_BLOCK2 ? b + ASCII_SPACE : b < CODE_BLOCK3 ? b - CODE_BLOCK2 : b;
                if (ch < ASCII_SPACE || ch > ASCII_LAST)
                begin
/* unprintable; the line grows */
                    ch = ".";
                end
                line = {line, string'(ch)};
            end
            $display("  |%s|", line);
/* the whole screen as one string */
            screen_txt = {screen_txt, line, "\n"};
        end
    end
endtask

function automatic bit has_text(input string s, input string t);
    integer i;
/* not found by default */
    has_text = 0;
    for (i = 0; i + t.len() <= s.len(); i++)
    begin
        if (s.substr(i, i + t.len() - 1) == t)
        begin
/* found */
            has_text = 1;
        end
    end
endfunction

reg [7:0] frame [0:239][0:375];
always @(posedge clk)
/* a pixel pair inside the visible picture */
    if (px_stb && px_vc >= VC_VIS_BEG && px_vc < VC_VIS_END && px_cc >= CC_VIS_BEG && px_cc < CC_VIS_END)
    begin
        frame[px_vc - 8][(px_cc - 8'h22) * 2]     <= px0;
        frame[px_vc - 8][(px_cc - 8'h22) * 2 + 1] <= px1;
    end

/* PAL palette: hue angle (table 14), luminance 0-15 (bits 7:4 hue, 3:0 luminance) */
function automatic [23:0] rgb(input [7:0] c);
    real ang [1:15] = '{135.0, 112.5, 90.0, 67.5, 45.0, 22.5, 337.5, 315.0, 292.5, 270.0, 225.0, 202.5, 180.0, 157.5, 135.0};
    real y, u, v, r, g, b, th;
    begin
/* the luminance */
        y = c[3:0] / LUM_MAX;
        if (c[7:4] == 0)
        begin
            u = 0;
/* grey */
            v = 0;
        end
        else
        begin
            th = ang[c[7:4]] * PI / HALF_TURN;
            u = CHROMA * $cos(th);
/* the colour's angle gives U and V */
            v = CHROMA * $sin(th);
        end
        r = y + R_V * v;
        g = y - G_U * u - G_V * v;
/* limited to 0 .. 1 */
        b = y + B_U * u;
        r = r < 0 ? 0 : r > 1 ? 1 : r;
        g = g < 0 ? 0 : g > 1 ? 1 : g;
/* as 24 bits */
        b = b < 0 ? 0 : b > 1 ? 1 : b;
        rgb = {8'(int'(r * RGB_MAX)), 8'(int'(g * RGB_MAX)), 8'(int'(b * RGB_MAX))};
    end
endfunction

task automatic grab(input string fn);
/* the file */
    integer fd, x, yy;
    reg [23:0] p;
    begin
        fd = $fopen(fn, "w");
/* a PPM header, then the pixels */
        $fwrite(fd, "P3\n376 240\n255\n");
        for (yy = 0; yy < PIC_H; yy++)
        begin
            for (x = 0; x < PIC_W; x++)
            begin
/* one pixel */
                p = rgb(frame[yy][x]);
                $fwrite(fd, "%0d %0d %0d\n", p[23:16], p[15:8], p[7:0]);
            end
        end
        $fclose(fd);
/* written */
        $display("%t frame written to %s", $time, fn);
    end
endtask

/* SIO bridge + disk drive model (the ESP32's part, ESP32/v2/src/atari.cpp) */
reg  [31:0] mclr = 0;
reg         mclr_we = 0;
wire [31:0] mstat;
/* the SIO bridge */
atari_sio u_sio (
    .clk_sd(clk_sd), .rst_n(rst_n), .so_stb(so_stb), .so_byte(so_byte), .cmd_n(sio_cmd_n),
    .motor_n(sio_motor_n), .sio_in(sio_in), .mctl(32'd0), .mstat(mstat), .mclr(mclr), .mclr_we(mclr_we));

`ifdef DISK
reg [7:0] boot [0:127];
/* the disk image */
reg [7:0] disk [0:65535];
`ifdef XEX
initial $readmemh("disk.mem", disk);
/* the boot sector of the plain disk test */
`endif
initial
begin : bootsec
    integer i;
/* its code and message */
    reg [7:0] code [0:22];
    reg [7:0] msg [0:12];
    for (i = 0; i < SECTOR; i++)
    begin
/* empty */
        boot[i] = 8'h00;
    end
/* flags, 1 sector, load $0700, init $0706; code at $0706 (the OS calls load + 6) */
    boot[0] = 8'h00;
    boot[1] = 8'h01;
    boot[2] = 8'h00;
/* load and init address */
    boot[3] = 8'h07;
    boot[4] = 8'h06;
    boot[5] = 8'h07;
/* $0706 LDY #0 */
    code = '{8'hA0, 8'h00,
/* $0708 LDA $0716,Y */
             8'hB9, 8'h16, 8'h07,
/* $070B BMI $0713 */
             8'h30, 8'h06,
/* $070D STA (SAVMSC),Y */
             8'h91, 8'h58,
/* $070F INY */
             8'hC8,
/* $0710 JMP $0708 */
             8'h4C, 8'h08, 8'h07,
/* $0713 JMP $0713 */
             8'h4C, 8'h13, 8'h07,
             8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00};
/* DISK BOOT OK */
    msg  = '{8'h24, 8'h29, 8'h33, 8'h2B, 8'h00, 8'h22, 8'h2F, 8'h2F, 8'h34, 8'h00, 8'h2F, 8'h2B, 8'hFF};
    for (i = 0; i < BOOT_CODE_LEN; i++)
    begin
        boot[6 + i] = code[i];
    end
/* the message */
    for (i = 0; i < MSG_LEN; i++)
    begin
        boot[22 + i] = msg[i];
    end
`ifdef INJSTAGE
    begin : s2_boot
/* the boot code of the stage test */
        reg [7:0] c [0:63];
/* load $0100 (page 1: no memory stage 2 needs), the OS calls $0106 */
        c = '{8'h00, 8'h01, 8'h00, 8'h01, 8'h06, 8'h01,
/* $0106 LDA $0180 / BEQ / CMP #1 / BNE $011B */
              8'hAD, 8'h80, 8'h01,  8'hF0, 8'hFB,  8'hC9, 8'h01,  8'hD0, 8'h0C,
/* $010F SEI / LDA #0 / STA NMIEN / STA $0180 */
              8'h78,  8'hA9, 8'h00,  8'h8D, 8'h0E, 8'hD4,  8'h8D, 8'h80, 8'h01,
/* $0118 JMP $0106 */
              8'h4C, 8'h06, 8'h01,  8'hEA,
/* $011B PORTB = $FE */
              8'hA9, 8'hFE,  8'h8D, 8'h01, 8'hD3,
              8'hA9, 8'h58,  8'h8D, 8'h02, 8'hD4,  8'hA9, 8'h04,  8'h8D, 8'h03, 8'hD4,  8'h8D, 8'h09, 8'hD4,
/* DLIST $0458, CHBASE $04, DMACTL $21 */
              8'hA9, 8'h21,  8'h8D, 8'h00, 8'hD4,
/* $0133 LDX #S / TXS / LDX #X / LDY #Y / LDA #A */
              8'hA2, 8'h00,  8'h9A,  8'hA2, 8'h00,  8'hA0, 8'h00,  8'hA9, 8'h00,
/* $013C SEC / JMP $0812 */
              8'h38,  8'h4C, 8'h12, 8'h08};
        for (i = 0; i < SECTOR; i++)
        begin
            boot[i] = 8'h00;
        end
        for (i = 0; i < STAGE_CODE_LEN; i++)
        begin
/* into the sector */
            boot[i] = c[i];
        end
    end
`endif
`ifdef INJECT
    begin : inj_boot
/* the boot code of the injection test */
        reg [7:0] c [0:40];
/* $0706 BASIC off (PORTB bit 1, BASICF), then the mailbox loop at $0713: */
/* 0 wait, 1 JSR (INITAD) then mailbox = 0, 2 JMP (RUNAD) */
/* $0706 LDA PORTB / ORA #2 / STA PORTB */
        c = '{8'hAD, 8'h01, 8'hD3,  8'h09, 8'h02,  8'h8D, 8'h01, 8'hD3,
/* $070E LDA #1 / STA BASICF */
              8'hA9, 8'h01,  8'h8D, 8'hF8, 8'h03,
/* $0713 LDA $0600 / BEQ $0713 */
              8'hAD, 8'h00, 8'h06,  8'hF0, 8'hFB,
/* $0718 CMP #1 / BNE $0727 */
              8'hC9, 8'h01,  8'hD0, 8'h0B,
/* $071C JSR $072C */
              8'h20, 8'h2C, 8'h07,
/* $071F LDA #0 / STA $0600 */
              8'hA9, 8'h00,  8'h8D, 8'h00, 8'h06,
/* $0724 JMP $0713 */
              8'h4C, 8'h13, 8'h07,
/* $0727 JMP (RUNAD) */
              8'h6C, 8'hE0, 8'h02,
/* $072A */
              8'hEA, 8'hEA,
/* $072C JMP (INITAD) */
              8'h6C, 8'hE2, 8'h02};
        for (i = BOOT_HDR; i < SECTOR; i++)
        begin
            boot[i] = 8'h00;
        end
        for (i = 0; i < INJ_CODE_LEN; i++)
        begin
/* into the sector */
            boot[6 + i] = c[i];
        end
    end
`endif
end

function automatic [7:0] csum(input [7:0] d [], input integer n);
/* the SIO checksum: sum with end-around carry */
    integer i, sm;
    sm = 0;
    for (i = 0; i < n; i++)
    begin
/* added; the carry folded in */
        sm = sm + d[i];
        sm = (sm & BYTE_MASK) + (sm >> BYTE_BITS);
    end
    csum = sm[7:0];
endfunction

/* a byte to the Atari */
task automatic push(input [7:0] b);
    @(posedge clk_sd);
    mclr <= {23'd0, 1'b1, b};
/* the write strobe */
    mclr_we <= 1'b1;
    @(posedge clk_sd);
    mclr_we <= 1'b0;
endtask
/* a byte of the Atari is taken */
task automatic pop;
    @(posedge clk_sd);
    mclr <= MCLR_POP;
/* the strobe */
    mclr_we <= 1'b1;
    @(posedge clk_sd);
    mclr_we <= 1'b0;
/* time for the next byte to show */
    repeat (POP_CLKS)
    begin
        @(posedge clk_sd);
    end
endtask
/* after the ACK: sent, then >= 250 us dead time */
task automatic result(input [7:0] b);
    wait (mstat[13]);
    #300us;
/* the byte */
    push(b);
endtask

integer n_cmd = 0;
initial
begin : drive
/* the command frame, the data, counters */
    reg [7:0] cf [5];
    reg [7:0] d [];
    integer cn, i, sec;
/* no frame bytes yet */
    cn = 0;
    forever
    begin
        @(posedge clk_sd);
/* a byte from the Atari */
        if (mstat[8])
        begin
            if (mstat[9])
            begin
                if (mstat[10])
                begin
/* a new frame */
                    cn = 0;
                end
                if (cn < CMD_FRAME)
                begin
                    cf[cn] = mstat[7:0];
/* the next byte */
                    cn++;
                end
            end
            pop;
        end
        else if (cn == CMD_FRAME && !mstat[11])
        begin
/* the frame is complete */
            cn = 0;
            n_cmd++;
            sec = cf[2] + BYTE_RANGE * cf[3];
/* the status command */
            $display("%t D1 command %02h %02h %02h %02h %02h", $time, cf[0], cf[1], cf[2], cf[3], cf[4]);
            if (cf[0] == SIO_D1 && cf[1] == SIO_STATUS)
            begin
                push(8'h41);
/* four status bytes */
                d = new[4];
                d = '{8'h00, 8'hFF, 8'hE0, 8'h00};
                result(8'h43);
/* the four status bytes */
                for (i = 0; i < STATUS_LEN; i++)
                begin
                    push(d[i]);
                end
                push(csum(d, 4));
            end
/* the read command */
            else if (cf[0] == SIO_D1 && cf[1] == SIO_READ)
            begin
                push(8'h41);
                d = new[128];
/* a sector of the disk image */
`ifdef XEX
                for (i = 0; i < SECTOR; i++)
                begin
                    d[i] = disk[(sec - 1) * 128 + i];
                end
/* the boot sector, else zeros */
`else
                for (i = 0; i < SECTOR; i++)
                begin
                    d[i] = sec == 1 ? boot[i] : 8'h00;
                end
/* complete, then the data */
`endif
                result(8'h43);
                for (i = 0; i < SECTOR; i++)
                begin
/* and the checksum */
                    push(d[i]);
                end
                push(csum(d, 128));
            end
            else if (cf[0] == SIO_D1)
            begin
/* other commands: NAK */
                push(8'h4E);
            end
        end
    end
end
`endif

`ifdef CART
/* test cartridge: $A000 LDY #0 / LDA $A010,Y / BMI $A00D / STA (SAVMSC),Y / INY / BNE $A002 / JMP $A00D, */
/* "CART OK" at $A010; $BFFA start $A000, $BFFC 0 (present), $BFFD 4 (run it, no disk boot), $BFFE init $A00C (RTS) */
initial
begin : cartimg
    reg [7:0] c [0:23];
    reg [7:0] b1 [0:16];
/* loop index; the cartridge's code */
    integer i;
    c = '{8'hA0, 8'h00, 8'hB9, 8'h10, 8'hA0, 8'h30, 8'h06, 8'h91, 8'h58, 8'hC8, 8'hD0, 8'hF6,
          8'h60, 8'h4C, 8'h0D, 8'hA0,
          8'h23, 8'h21, 8'h32, 8'h34, 8'h00, 8'h2F, 8'h2B, 8'hFF};
    #1;
/* the 8 KB cartridge */
    if (`CART == 1)
    begin
        for (i = 0; i < CART_CODE_LEN; i++)
        begin
            sd_poke(21'h28000 + i, c[i]);
        end
/* its start and init vectors */
        sd_poke(21'h29FFA, 8'h00);
        sd_poke(21'h29FFB, 8'hA0);
        sd_poke(21'h29FFC, 8'h00);
/* flags */
        sd_poke(21'h29FFD, 8'h04);
        sd_poke(21'h29FFE, 8'h0C);
        sd_poke(21'h29FFF, 8'hA0);
    end
    else
    begin
/* bank 0: $A000 LDA $D501 (-> bank 1), $A00C RTS (init); header as above */
        sd_poke(21'h100000, 8'hAD);
        sd_poke(21'h100001, 8'h01);
        sd_poke(21'h100002, 8'hD5);
/* bank 0's code ends */
        sd_poke(21'h10000C, 8'h60);
        sd_poke(21'h101FFA, 8'h00);
        sd_poke(21'h101FFB, 8'hA0);
/* its vectors */
        sd_poke(21'h101FFC, 8'h00);
        sd_poke(21'h101FFD, 8'h04);
        sd_poke(21'h101FFE, 8'h0C);
/* flags */
        sd_poke(21'h101FFF, 8'hA0);
/* bank 1 from $A003: LDY #0 / LDA $A020,Y / BMI $A010 / STA (SAVMSC),Y / INY / BNE $A005 / NOP / */
/* $A010 JMP $A010; "BANK OK" at $A020 */
        b1 = '{8'hA0, 8'h00, 8'hB9, 8'h20, 8'hA0, 8'h30, 8'h06, 8'h91, 8'h58, 8'hC8, 8'hD0, 8'hF6, 8'hEA,
               8'h4C, 8'h10, 8'hA0, 8'h00};
        for (i = 0; i < BANK1_CODE_LEN; i++)
        begin
            sd_poke(21'h102003 + i, b1[i]);
        end
/* the text */
        c = '{8'h22, 8'h21, 8'h2E, 8'h2B, 8'h00, 8'h2F, 8'h2B, 8'hFF, 8'h00, 8'h00, 8'h00, 8'h00,
              8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00};
        for (i = 0; i < BANK1_TEXT_LEN; i++)
        begin
            sd_poke(21'h102020 + i, c[i]);
        end
    end
end
/* a VGA frame */
`endif

/* one VGA frame (active area) from the frame buffer: from a vsync to the next */
reg [17:0] vga [0:VH-1][0:VW-1];
task automatic grab_vga(input string fn);
    integer fd, x, y, n;
    begin
/* negative syncs */
        @(negedge v_vs);
        @(posedge v_vs);
        x = 0;
/* from the top */
        y = 0;
        n = 0;
        while (v_vs)
        begin
/* a pixel clock */
            @(posedge pclk);
            if (v_act)
            begin
                if (y < VH && x < VW)
                begin
/* a pixel inside the picture */
                    vga[y][x] = v_rgb;
                end
                x++;
                n++;
            end
/* the end of a line */
            else if (x != 0)
            begin
                x = 0;
                y++;
            end
        end
/* the file */
        fd = $fopen(fn, "w");
/* 6-bit colours to 8 bits */
        $fwrite(fd, "P3\n%0d %0d\n255\n", VW, VH);
        for (y = 0; y < VH; y++)
        begin
            for (x = 0; x < VW; x++)
            begin
/* one pixel */
                $fwrite(fd, "%0d %0d %0d\n", {vga[y][x][17:12], vga[y][x][17:16]},
                        {vga[y][x][11:6], vga[y][x][11:10]}, {vga[y][x][5:0], vga[y][x][5:4]});
            end
        end
        $fclose(fd);
        $display("%t VGA frame written to %s (%0d active pixels)", $time, fn, n);
    end
endtask

/* the address the injection test watches */
`ifdef INJECT
`ifndef INJ_WATCH
 `define INJ_WATCH 16'h9D00
/* the default's end */
`endif
/* RUNAD taken: from here the watch counts */
reg inj_run = 1'b0;
reg [7:0] xf [0:131071];
integer   xn;
/* the injection of a binary load file */
initial
begin : injector
    integer fd, p, s, e, k, nseg;
    fd = $fopen(`INJECT, "rb");
/* no file */
    if (fd == 0)
    begin
        $display("FAIL: cannot open %s", `INJECT);
        $finish;
    end
/* the file is read */
    xn = $fread(xf, fd);
    $fclose(fd);
    $display("INJECT: %s, %0d bytes", `INJECT, xn);
/* the ROMs are loaded */
    wait (u_sys.ld_done);
/* an opcode fetch: the boot sector waits on the mailbox */
    wait (u_sys.cpu_sync && u_sys.cpu_a == 16'h0713);
/* (the address alone also matches the OS clearing memory) */
    #100us;
    $display("%t INJECT: boot sector running, BASIC off; loading the segments", $time);
    p = 0;
/* the segments */
    nseg = 0;
    while (p + SEG_HDR <= xn)
    begin
        if (xf[p] == 8'hFF && xf[p + 1] == 8'hFF)
        begin
/* the FFFF marker is skipped; start and end address */
            p = p + MARK_LEN;
        end
        s = xf[p] | (xf[p + 1] << BYTE_BITS);
        e = xf[p + 2] | (xf[p + 3] << BYTE_BITS);
/* the header is done */
        p = p + SEG_HDR;
/* INITAD cleared before each segment */
        sd_poke(21'h002E2, 8'h00);
        sd_poke(21'h002E3, 8'h00);
        for (k = s; k <= e && p < xn; k++)
        begin
/* a byte of the segment */
            sd_poke({5'd0, k[15:0]}, xf[p]);
            p = p + 1;
        end
        $display("%t INJECT: segment %0d $%04h-$%04h", $time, nseg, s, e);
/* counted; an init address was set */
        nseg++;
        if (sd_peek(21'h002E2) != 0 || sd_peek(21'h002E3) != 0)
        begin
            $display("%t INJECT: INITAD $%02h%02h called", $time, sd_peek(21'h002E3), sd_peek(21'h002E2));
/* the Atari calls it; the testbench waits for the return */
            sd_poke(21'h00600, 8'h01);
            while (sd_peek(21'h00600) != 0)
            begin
                #20us;
            end
/* returned */
            $display("%t INJECT: INITAD returned", $time);
        end
    end
`ifdef INJRAM
`ifndef INJ_RUN
/* the run address of the memory image */
`define INJ_RUN 16'h9D00
`endif
    begin : injram
        reg [7:0] im [0:65535];
/* the image file */
        integer f2, k2, n2;
        reg [15:0] run;
        f2 = $fopen(`INJRAM, "rb");
/* read */
        n2 = $fread(im, f2);
        $fclose(f2);
/* (a 16-bit 16'h10000 would be 0: no write at all) */
        for (k2 = IMG_FIRST; k2 < MEM_64K; k2++)
        begin
            if (k2 < IO_FIRST16 || k2 >= IO_END16)
            begin
                sd_poke({5'd0, k2[15:0]}, im[k2]);
            end
        end
/* the run address into RUNAD */
        run = `INJ_RUN;
        sd_poke(21'h002E0, run[7:0]);
        sd_poke(21'h002E1, run[15:8]);
/* reported */
        $display("%t INJECT: memory image %s (%0d bytes) in, run at $%04h; $9D00: %02h %02h %02h %02h %02h %02h %02h %02h",
                 $time, `INJRAM, n2, run, sd_peek(21'h09D00), sd_peek(21'h09D01), sd_peek(21'h09D02), sd_peek(21'h09D03),
                 sd_peek(21'h09D04), sd_peek(21'h09D05), sd_peek(21'h09D06), sd_peek(21'h09D07));
    end
`endif
    $display("%t INJECT: RUNAD $%02h%02h", $time, sd_peek(21'h002E1), sd_peek(21'h002E0));
/* the Atari jumps through RUNAD */
    sd_poke(21'h00600, 8'h02);
    inj_run = 1'b1;
end
`ifdef INJRAM
/* every SDRAM write into $9D00-$9D07 after the image is in: who and when */
initial
begin : inj_wwatch
    wait (inj_run);
    forever
    begin
/* writes into the watched range are reported */
        @(posedge clk_sd);
        if (u_sys.a_req && u_sys.a_we && u_sys.a_addr >= WATCH_FIRST && u_sys.a_addr <= WATCH_LAST)
        begin
            $display("%t INJECT: write $%05h = %02h (owner %0d: 0 bus, 2 ESP32), CPU A %04h", $time,
                     u_sys.a_addr, u_sys.a_din, u_sys.a_own, u_sys.cpu_a);
        end
    end
end
/* the trace of the injection test */
`endif
`ifdef INJ_TRACE
/* opcode fetch addresses from RUNAD on, one per line (compared with a 6502 reference run) */
initial
begin : inj_trace
    integer ft, nt;
    ft = $fopen("inj_trace.txt", "w");
/* from the jump on */
    nt = 0;
    wait (inj_run);
    while (nt < `INJ_TRACE)
    begin
/* an opcode fetch */
        @(posedge clk);
        if (u_sys.cyc_end && u_sys.cpu_cyc && u_sys.a_rdy && u_sys.cpu_sync)
        begin
            $fwrite(ft, "%04h\n", u_sys.cpu_a);
/* counted; the file is closed */
            nt = nt + 1;
        end
    end
    $fclose(ft);
    $display("%t INJECT: %0d instruction addresses in inj_trace.txt", $time, nt);
end
/* the watch */
`endif
initial
begin : inj_watch
    wait (inj_run);
/* an opcode fetch there */
    wait (u_sys.cpu_sync && u_sys.cpu_a == `INJ_WATCH);
    $display("%t INJECT: the CPU reached $%04h; $9D00: %02h %02h %02h %02h %02h %02h %02h %02h", $time, `INJ_WATCH,
             sd_peek(21'h09D00), sd_peek(21'h09D01), sd_peek(21'h09D02), sd_peek(21'h09D03),
             sd_peek(21'h09D04), sd_peek(21'h09D05), sd_peek(21'h09D06), sd_peek(21'h09D07));
`ifdef INJ_DUMP
/* the 64 KB the CPU sees with the OS ROM switched out (physical main RAM), for a byte-by-byte comparison */
    begin : dump
        integer fd, k;
        fd = $fopen("inj_dump.bin", "wb");
        for (k = 0; k < MEM_64K; k++)
        begin
/* the RAM dump is closed */
            $fwrite(fd, "%c", sd_peek(k[20:0]));
        end
        $fclose(fd);
        $display("%t INJECT: RAM dumped to inj_dump.bin", $time);
    end
/* 300 ms more, then the pictures */
    #300ms;
    show_screen;
    grab_vga("vga.ppm");
/* the end */
    $display("RESULT: dump done");
    $finish;
`endif
end
/* the stage test */
`endif

`ifdef INJSTAGE
reg  [7:0]  s2_im [0:65535];
/* the reference lines, the last PCs */
string      s2_ref [0:4095];
integer     s2_nref;
reg  [15:0] s2_ring [0:399];
/* the state goes in */
initial
begin : s2_inject
    integer fd, k, n, a, x, y, sp;
    fd = $fopen("s2_ram.bin", "rb");
/* the memory image */
    n = $fread(s2_im, fd);
    $fclose(fd);
    fd = $fopen("s2_regs.txt", "r");
/* the registers; the reference */
    k = $fscanf(fd, "%h %h %h %h", a, x, y, sp);
    $fclose(fd);
    fd = $fopen("s2_ref.txt", "r");
/* its lines */
    s2_nref = 0;
    while (!$feof(fd) && s2_nref < REF_MAX)
    begin
        string l;
/* a line without its line end */
        if ($fgets(l, fd))
        begin
            s2_ref[s2_nref] = l.substr(0, l.len() - EOL_LEN);
            s2_nref++;
        end
    end
/* all read */
    $fclose(fd);
    $display("INJSTAGE: %0d bytes, A %02h X %02h Y %02h S %02h, %0d reference lines", n, a, x, y, sp, s2_nref);
    wait (u_sys.ld_done);
/* the boot code waits on its mailbox */
    wait (u_sys.cpu_sync && u_sys.cpu_a == 16'h0106);
    #100us;
/* interrupts off */
    sd_poke(21'h00180, 8'h01);
    while (sd_peek(21'h00180) != 0)
    begin
        #20us;
    end
/* RAM except the stack page, the I/O area and the boot code's page */
    for (k = 0; k < MEM_64K; k++)
    begin
        if (k < PAGE1 || (k >= PAGE2 && k < IO_FIRST) || k >= IO_END)
        begin
            sd_poke(k[20:0], s2_im[k]);
        end
    end
/* operands of LDX #S / LDX #X / LDY #Y / LDA #A at $0133.. (after the NOP at $011B) */
    sd_poke(21'h00134, sp[7:0]);
    sd_poke(21'h00137, x[7:0]);
    sd_poke(21'h00139, y[7:0]);
/* the registers for the boot code; it starts stage 2 */
    sd_poke(21'h0013B, a[7:0]);
    $display("%t INJSTAGE: state in, starting stage 2", $time);
    sd_poke(21'h00180, 8'h02);
end
/* the check against the reference */
initial
begin : s2_check
    integer cnt, line, z;
    string  got;
/* the zero-page bytes compared; the start address is waited for */
    reg [7:0] zp [0:10];
    wait (u_sys.cpu_sync && u_sys.cpu_a == 16'h0812 && u_sys.cyc_end && u_sys.cpu_cyc);
    $display("%t INJSTAGE: $0812 reached", $time);
/* instruction and check counters */
    cnt = 0;
    line = 0;
    forever
    begin
/* an opcode fetch: its address is kept */
        @(posedge clk);
        if (u_sys.cyc_end && u_sys.cpu_cyc && u_sys.a_rdy && u_sys.cpu_sync)
        begin
            s2_ring[cnt % 400] = u_sys.cpu_a;
/* the end address */
            if (u_sys.cpu_a == S2_END)
            begin
                $display("%t INJSTAGE: stage 2 done after %0d instructions (reference 1403806), all %0d checks equal",
                         $time, cnt, line);
                $display("RESULT: stage 2 PASS");
/* the end; a check every 500 instructions */
                $finish;
            end
            if (cnt % CHECK_EVERY == 0 && line < s2_nref)
            begin
                got = $sformatf("%02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x",
                                sd_peek(21'hD0), sd_peek(21'hD1), sd_peek(21'hD2), sd_peek(21'hD3), sd_peek(21'hF0),
                                sd_peek(21'hF1), sd_peek(21'hF2), sd_peek(21'hF3), sd_peek(21'hF4), sd_peek(21'hF5),
                                sd_peek(21'hF6));
/* a mismatch */
                if (got != s2_ref[line])
                begin
                    integer fr, j;
                    $display("%t INJSTAGE: MISMATCH at instruction %0d (check %0d)", $time, cnt, line);
/* both lines */
                    $display("   reference: %s", s2_ref[line]);
                    $display("   LTari    : %s", got);
                    $display("   previous check (equal): instruction %0d", cnt - 500);
/* the last 400 addresses into a file */
                    fr = $fopen("s2_rtl_pcs.txt", "w");
                    for (j = 0; j < RING; j++)
                    begin
                        $fwrite(fr, "%0d %04h\n", cnt - 399 + j, s2_ring[(cnt + 1 + j) % 400]);
                    end
/* the end */
                    $fclose(fr);
                    $display("RESULT: stage 2 MISMATCH");
                    $finish;
                end
/* the next check; the next instruction */
                line++;
            end
            cnt++;
        end
    end
end
`endif

/* the trigger test's length */
`ifdef TRIG_MS
`ifndef TRIG_LEN
 `define TRIG_LEN 300
/* a picture before the press */
`endif
initial
begin : trig_pic
    #(`TRIG_MS * 1ms - 20ms);
/* the press */
    grab("trig_pre.ppm");
end
initial
begin : trig_press
    integer k;
/* the time of the press */
    #(`TRIG_MS * 1ms);
    $display("%t TRIG: trigger 0 pressed, CPU A %04h", $time, u_sys.cpu_a);
    t_trig = 2'b10;
/* a line every millisecond */
    for (k = 0; k < `TRIG_LEN; k++)
    begin
        #1ms;
        $display("%t TRIG: +%0d ms CPU A %04h VCOUNT %0d NMIEN %02h", $time, k + 1, u_sys.cpu_a, u_sys.u_antic.vc, u_sys.u_antic.nmien);
    end
/* released */
    t_trig = 2'b11;
    $display("%t TRIG: released", $time);
    for (k = 0; k < TRIG_AFTER_MS; k++)
    begin
/* a line every millisecond */
        #1ms;
        $display("%t TRIG: +%0d ms CPU A %04h VCOUNT %0d", $time, k + 1 + `TRIG_LEN, u_sys.cpu_a, u_sys.u_antic.vc);
    end
    grab("trig_post.ppm");
end
/* the trigger test's end */
`endif

/* run */
initial
begin
    integer t_ms, errors;
    errors = 0;
/* the ROMs are loaded */
    wait (u_sys.ld_done);
    $display("%t ROMs loaded and RAM cleared (bad_image %0d); OS reset vector %02h%02h", $time, bad,
             sd_peek(20'h24FFD), sd_peek(20'h24FFC));
    for (t_ms = STEP_MS; t_ms <= `RUN_MS; t_ms += STEP_MS)
    begin
/* a line every 50 ms */
        #50ms;
        $display("%t %0d ms: CPU A %04h  VCOUNT %0d  NMIs %0d  SIO bytes %0d  DLIST %04h  DMACTL %02h  PORTB %02h",
                 $time, t_ms, u_sys.cpu_a, u_sys.u_antic.vc, n_nmi, n_sio, u_sys.u_antic.dlist,
                 u_sys.u_antic.dmactl, u_sys.pb);
        show_screen;
/* the text each test waits for */
`ifdef CART
        if (has_text(screen_txt, "CART OK") || has_text(screen_txt, "BANK OK"))
        begin
            break;
        end
/* the .xex test */
`elsif XEX
        if (has_text(screen_txt, "XEX OK") || has_text(screen_txt, "XEX BAD"))
        begin
            break;
        end
/* the injection test */
`elsif INJECT
/* runs RUN_MS */
        ;
`elsif DISK
        if (has_text(screen_txt, "DISK BOOT OK"))
        begin
/* done */
            break;
        end
`else
        if (has_text(screen_txt, "READY") || has_text(screen_txt, "Ready"))
        begin
/* BASIC is up */
            break;
        end
`endif
    end
    if (bad)
    begin
/* a bad image */
        $display("FAIL: bad ROM image");
        errors++;
    end
`ifdef CART
/* the cartridge's text */
    if (!has_text(screen_txt, `CART == 1 ? "CART OK" : "BANK OK"))
    begin
        $display("FAIL: no CART OK / BANK OK");
        errors++;
    end
/* the .xex test's text */
`elsif XEX
    if (!has_text(screen_txt, "XEX OK"))
    begin
        $display("FAIL: no XEX OK on the screen");
/* counted */
        errors++;
    end
`elsif INJECT
/* nothing to look for */
    ;
`elsif DISK
    if (!has_text(screen_txt, "DISK BOOT OK"))
    begin
/* the boot sector's text is missing */
        $display("FAIL: no DISK BOOT OK on the screen");
/* counted */
        errors++;
    end
`else
    if (!has_text(screen_txt, "READY") && !has_text(screen_txt, "Ready"))
    begin
/* BASIC's prompt is missing */
        $display("FAIL: no Ready on the screen");
/* one more error */
        errors++;
    end
`endif
    if (n_nmi < NMI_MIN)
    begin
/* no interrupts */
        $display("FAIL: no VBI NMIs");
        errors++;
    end
`ifdef SNAPTEST
    begin : snaptest
/* the registers, the stack pointer, counters */
        reg [63:0] r0;
        reg [7:0]  s;
        integer    n0, i, k;
/* the restore program */
        reg [7:0]  prog [0:15];
/* far from the VBI: the CPU is in the cartridge loop */
        wait (u_sys.u_antic.vc == 9'd100);
        wait (u_sys.cpu_a == 16'hA00D);
        t_frz = 1'b1;
        fork
            begin
/* frozen */
                wait (t_frozen);
            end
            begin
                #100us;
            end
        join_any
        disable fork;
/* never frozen */
        if (!t_frozen)
        begin
            $display("FAIL: no freeze");
            errors++;
        end
/* the registers at the freeze */
        r0 = t_regs;
        $display("%t frozen: PC %04h S %02h P %02h A %02h X %02h Y %02h", $time, r0[63:48], r0[39:32],
                 r0[31:24], r0[7:0], r0[15:8], r0[23:16]);
        if (r0[63:48] != CART_LOOP)
        begin
/* a wrong PC */
            $display("FAIL: PC not $A00D (the cartridge's loop)");
            errors++;
        end
        $display("COLBK shadow %02h, COLOR4 %02h", sd_peek(21'h3D01A), sd_peek(21'h002C8));
/* the shadow must hold the register's value */
        if (sd_peek(21'h3D01A) != sd_peek(21'h002C8))
        begin
            $display("FAIL: I/O shadow");
            errors++;
        end
/* the CPU must stand still */
        #20us;
        if (u_sys.cpu_a != r0[63:48])
        begin
            $display("FAIL: CPU moved while frozen");
/* counted */
            errors++;
        end
/* restore program at bank $2000: SEI / LDA #$77 / STA $D200 / LDX #S-3 / TXS / LDA #A / LDX #X / */
/* LDY #Y / RTI; the stack bytes for the RTI and the reset vector written directly */
        s = r0[39:32];
        prog = '{8'h78, 8'hA9, 8'h77, 8'h8D, 8'h00, 8'hD2, 8'hA2, s - 8'd3, 8'h9A, 8'hA9, r0[7:0],
                 8'hA2, r0[15:8], 8'hA0, r0[23:16], 8'h40};
        for (i = 0; i < RESTORE_LEN; i++)
        begin
/* the program into the restore bank */
            sd_poke(21'h32000 + i, prog[i]);
        end
/* 0x30100 + S-2: P */
        sd_poke({13'h0301, s - 8'd2}, r0[31:24]);
/* PCL */
        sd_poke({13'h0301, s - 8'd1}, r0[55:48]);
/* PCH */
        sd_poke({13'h0301, s},        r0[63:56]);
        sd_poke(21'h3FFFC, 8'h00);
        sd_poke(21'h3FFFD, 8'h20);
/* the NMI count; restore mode and CPU reset */
        n0 = n_nmi;
        t_rm = 1'b1;
        t_rst = 1'b1;
/* unfrozen, the reset ends */
        #1us t_frz = 1'b0;
        #2us t_rst = 1'b0;
        k = 0;
        fork
            begin
/* restore mode on, then off */
                wait (t_rmode);
                wait (!t_rmode);
                k = 1;
            end
            begin
/* a time limit */
                #2ms;
            end
        join_any
        disable fork;
        t_rm = 1'b0;
/* it never ended */
        if (!k)
        begin
            $display("FAIL: restore mode did not end");
            errors++;
        end
/* the state after the restore */
        $display("%t restore mode over: CPU A %04h, AUDF1 %02h, shadow %02h", $time, u_sys.cpu_a,
                 u_sys.u_pokey.audf[1], sd_peek(21'h3D200));
        if (u_sys.u_pokey.audf[1] != RESTORED_AUDF || sd_peek(21'h3D200) != RESTORED_AUDF)
        begin
            $display("FAIL: restore program");
/* counted; some time to run */
            errors++;
        end
        #200us;
        $display("%t after: PC %04h A %02h X %02h Y %02h S %02h", $time, t_regs[63:48], t_regs[7:0], t_regs[15:8],
                 t_regs[23:16], t_regs[39:32]);
/* the PC must be in the cartridge's loop */
        if (u_sys.cpu_a < CART_LOOP || u_sys.cpu_a > CART_LOOP_END)
        begin
            $display("FAIL: CPU not back in its loop");
            errors++;
        end
/* the registers must be the old ones */
        if (t_regs[7:0] != r0[7:0] || t_regs[15:8] != r0[15:8] || t_regs[23:16] != r0[23:16] || t_regs[39:32] != r0[39:32])
        begin
            $display("FAIL: registers changed");
            errors++;
        end
/* the interrupts must run on */
        #40ms;
        if (n_nmi < n0 + NMI_MIN)
        begin
            $display("FAIL: no NMIs after the restore");
/* counted; the screen must be the old one */
            errors++;
        end
        $display("%t NMIs since the freeze: %0d", $time, n_nmi - n0);
        show_screen;
/* the text is gone */
        if (!has_text(screen_txt, "CART OK"))
        begin
            $display("FAIL: screen lost");
            errors++;
        end
    end
/* the pictures */
`endif
    grab("screen.ppm");
    grab_vga("vga.ppm");
/* the verdict */
    if (errors)
    begin
        $display("RESULT: FAIL");
    end
    else
    begin
/* passed */
        $display("RESULT: PASS");
    end
/* the end */
    $finish;
end

endmodule
