/* tb_nes -- LNES (nes_system): runs a .nes file */
/* */
/* The file is read here as the ESP32 does on the board: its program and pattern data go */
/* straight into the SDRAM model, the cartridge word is made from its header, then the */
/* machine is started. */
/* +define+ROM=\"file.nes\"  the cartridge (default nestest.nes) */
/* +define+RUN_MS=<ms>       longest simulated time (default 400) */
/* +define+PRESS_MS=<ms>     Start is pressed at <ms> for 60 ms (PRESS_PAD: the buttons, default Start) */
/* +define+FAST              a plain memory instead of the SDRAM controller and model, clk_sd = 2 x clk */
/* (several times faster; run_sim.sh picks sim/fast_ram.v) */
/* +define+FB                with the frame buffer (rtl/nes_fb.v) on the machine's SDRAM port: one frame of its */
/* VGA output (640 x 480) as vga.ppm at the end */
/* +define+TRACE             every opcode fetch address to trace.txt */
/* Test programs that report through the cartridge RAM (signature DE B0 61 at $6001, status at */
/* $6000, text from $6004) stop the run with their text; "RESULT: PASS" for status 0. */
/* Every 20 ms: CPU address, frame count. At the end the last complete frame as frame.ppm */
/* (256 x 240, the palette of rtl/nes_palette.hex) and bytes $0000-$0003 of the RAM. */
`timescale 1ns/1ps
`ifndef ROM
 `define ROM "nestest.nes"
/* the longest simulated time, in milliseconds */
`endif
`ifndef RUN_MS
 `define RUN_MS 400
/* the buttons the key press holds */
`endif
`ifndef PRESS_PAD
 `define PRESS_PAD 8'h08
/* the testbench */
`endif

module tb_nes;

/* clk toggles on every fourth edge of clk_sd (FAST: every second one, with a plain memory) */
`ifdef FAST
localparam integer PH_LAST = 1;
`else
/* the SDRAM controller: clk every fourth edge */
localparam integer PH_LAST = 3;
`endif
/* the reset ends after 300 ns */
localparam integer RST_NS = 300;
/* both data masks high */
localparam integer DQM_OFF = 3;
/* picture size */
localparam integer PIC_W = 256;
localparam integer PIC_H = 240;
/* bytes of a .nes header, of a trainer, of the program and pattern units */
localparam integer HDR_LEN = 16;
localparam integer TRAINER_LEN = 512;
localparam integer PRG_UNIT = 16384;
/* the pattern data's unit */
localparam integer CHR_UNIT = 8192;
/* the largest file */
localparam integer FILE_MAX = 2 * 1024 * 1024;
/* SDRAM areas */
localparam [21:0] SD_PRG = 22'h200000;
localparam [21:0] SD_CHR = 22'h100000;
localparam [21:0] SD_WRAM = 22'h002000;
/* the test programs' status: running, reset wanted */
localparam [7:0] ST_RUNNING = 8'h80;
localparam [7:0] ST_RESET = 8'h81;
/* milliseconds between two reports, the length of a key press */
localparam integer STEP_MS = 20;
localparam integer PRESS_LEN_MS = 60;
/* 4-bit colour to 8 bits */
localparam integer C4_TO_8 = 17;
/* the longest result text */
localparam integer TEXT_MAX = 2000;
/* VGA: half a period of the 25.208 MHz pixel clock (ns), its reset's end, the picture */
localparam real PCLK_HALF = 19.835;
localparam integer PRST_NS = 1000;
localparam integer VGA_W = 640;
/* its height */
localparam integer VGA_H = 480;
/* bytes of the name table memory */
localparam integer NT_BYTES = 4096;
/* header: the mapper's high half, a nibble, the trainer bit; sizes */
localparam [7:0] HIGH_NIBBLE = 8'hF0;
localparam integer NIBBLE = 4;
localparam [7:0] F6_TRAINER = 8'h04;
/* sizes in the report, the program bank of the cartridge word */
localparam integer KB = 1024;
localparam integer PRG_BANK = 8192;
/* pattern RAM: 8 banks of 1 KB */
localparam [8:0] CHRRAM_MASK = 9'd7;
/* the test programs' signature (three bytes from $6001), their text's place, the most resets */
localparam [23:0] SIGNATURE = 24'hDEB061;
localparam integer SIG_AT = 1;
localparam integer SIG_LAST = 2;
/* the text's place */
localparam integer TEXT_AT = 4;
localparam integer RESETS_MAX = 4;
/* clk_sd half period (85.795 MHz) */
localparam realtime HSD = 5.8278;
localparam real T_CK  = 2 * HSD;
/* pin delays, the SDRAM clock's shift */
localparam real TCO   = 4.0;
localparam real TBACK = 0.5;
localparam real SD_SHIFT = 1.339;

/* the two clocks */
reg clk_sd = 0, clk = 0;
integer cph = 0;
always #(HSD)
begin
/* the faster clock */
    clk_sd = ~clk_sd;
    cph = (cph == PH_LAST) ? 0 : cph + 1;
/* the machine clock */
    if (cph == 0)
    begin
        clk = ~clk;
    end
end

reg rst_n = 0;
/* the reset */
initial #RST_NS rst_n = 1;

/* SDRAM pins */
wire        cke, cs_n, ras_n, cas_n, we_n, dq_oe;
wire [1:0]  ba, dqm;
wire [12:0] a;
/* data out and in */
wire [15:0] dq_o;
reg  [15:0] dq_i;
/* the machine's outputs */
wire        px_stb, px_eof, a_run, wram_tgl;
wire [7:0]  px_x, px_y;
wire [5:0]  px_c;
/* emphasis, sound */
wire [2:0]  px_e;
wire [9:0]  aud;
/* the frame buffer's SDRAM port */
wire        fb_req, fb_we, fb_ack;
wire [21:0] fb_addr;
wire [15:0] fb_wdata, fb_rdata;
/* cartridge word, controller, Reset button */
reg  [31:0] cart = 32'd0;
reg  [7:0]  pad1 = 8'd0;
reg         reset_key = 1'b0;

/* the machine */
nes_system #(.PULSE_HEX("../../rtl/nes_pulse.hex"), .TND_HEX("../../rtl/nes_tnd.hex")) u_sys (
    .clk(clk), .rst_n(rst_n), .clk_sd(clk_sd), .rst_sd_n(rst_n),
    .cart(cart), .reset_key(reset_key), .pad1(pad1), .pad2(8'd0),
    .sd_cke(cke), .sd_cs_n(cs_n), .sd_ras_n(ras_n), .sd_cas_n(cas_n), .sd_we_n(we_n),
    .sd_ba(ba), .sd_a(a), .sd_dqm(dqm), .sd_dq_o(dq_o), .sd_dq_oe(dq_oe), .sd_dq_i(dq_i),
    .px_stb(px_stb), .px_x(px_x), .px_y(px_y), .px_c(px_c), .px_e(px_e), .px_eof(px_eof),
    .audio(aud), .run_o(a_run), .wram_tgl(wram_tgl),
    .fb_req(fb_req), .fb_we(fb_we), .fb_addr(fb_addr), .fb_wdata(fb_wdata), .fb_ack(fb_ack), .fb_rdata(fb_rdata),
    .x_req(1'b0), .x_we(1'b0), .x_addr(22'd0), .x_din(8'd0), .x_ack(), .x_dout()
);

`ifndef FAST
/* pins as seen by the SDRAM (transport delays, as the other machines' testbenches) */
reg         m_clk = 0, m_cke = 0, m_cs_n = 1, m_ras_n = 1, m_cas_n = 1, m_we_n = 1;
reg  [1:0]  m_ba = 0, m_dqm = DQM_OFF;
reg  [12:0] m_a = 0;
/* the data pins */
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
always @(m_dq) dq_i <= #(TBACK) m_dq;

/* the SDRAM */
sdram_model #(.T_CK(T_CK)) u_sdram (
    .clk(m_clk), .cke(m_cke), .cs_n(m_cs_n), .ras_n(m_ras_n), .cas_n(m_cas_n), .we_n(m_we_n),
    .ba(m_ba), .a(m_a), .dqm(m_dqm), .dq(m_dq)
);

`endif

/* a byte straight into / out of the SDRAM model */
task automatic sd_poke(input [21:0] ad, input [7:0] v);
    logic [23:0] key;
    logic [15:0] w;
    begin
/* {bank, row, column} as in sdram_model */
        key = {ad[11:10], 3'd0, ad[21:12], ad[9:1]};
`ifdef FAST
        w = u_sys.u_ram.mem[ad[21:1]];
/* the SDRAM model's own memory */
`else
        w = u_sdram.mem.exists(key) ? u_sdram.mem[key] : 16'h0000;
`endif
/* the lane written */
        if (ad[0])
        begin
            w[15:8] = v;
        end
        else
        begin
            w[7:0] = v;
        end
/* the plain memory */
`ifdef FAST
        u_sys.u_ram.mem[ad[21:1]] = w;
`else
/* the SDRAM model's */
        u_sdram.mem[key] = w;
`endif
    end
endtask

function automatic [7:0] sd_peek(input [21:0] ad);
/* the word and its key */
    logic [15:0] w;
    logic [23:0] key;
    begin
        key = {ad[11:10], 3'd0, ad[21:12], ad[9:1]};
/* the plain memory */
`ifdef FAST
        w = u_sys.u_ram.mem[ad[21:1]];
`else
/* the SDRAM model's */
        w = u_sdram.mem.exists(key) ? u_sdram.mem[key] : 16'h0000;
`endif
        sd_peek = ad[0] ? w[15:8] : w[7:0];
    end
endfunction

/* the cartridge file */
reg [7:0] file [0:FILE_MAX-1];
integer   fd, flen, prg_len, chr_len, off, i, mapper_no;
reg [18:0] ca;
/* the next power of two at or above n, less one */
function automatic integer mask_of(input integer n);
    integer m;
    begin
        m = 1;
/* doubled until it covers n */
        while (m < n)
        begin
            m = m << 1;
        end
        mask_of = m - 1;
    end
endfunction

/* the file goes into the memory */
initial
begin
    fd = $fopen(`ROM, "rb");
    if (fd == 0)
    begin
/* no file: the run ends */
        $display("cannot open %s", `ROM);
        $finish;
    end
    #1;
/* its bytes */
    flen = $fread(file, fd);
    $fclose(fd);
/* the header */
    prg_len   = file[4] * PRG_UNIT;
    chr_len   = file[5] * CHR_UNIT;
    mapper_no = (file[7] & HIGH_NIBBLE) | (file[6] >> NIBBLE);
/* where the data starts */
    off       = HDR_LEN + ((file[6] & F6_TRAINER) != 0 ? TRAINER_LEN : 0);
    $display("%s: %0d bytes, mapper %0d, PRG %0d KB, CHR %0d KB, flags %02x", `ROM, flen, mapper_no,
             prg_len / KB, chr_len / KB, file[6]);
/* program data */
    for (i = 0; i < prg_len; i = i + 1)
    begin
        sd_poke(SD_PRG + i, file[off + i]);
    end
/* pattern data: the two planes of a tile row side by side in a word */
    for (i = 0; i < chr_len; i = i + 1)
    begin
        ca = i;
        sd_poke(SD_CHR + {ca[18:4], ca[2:0], ca[3]}, file[off + prg_len + i]);
    end
/* the cartridge word */
    cart[7:0]   = mapper_no;
    cart[14:8]  = mask_of(prg_len / PRG_BANK);
    cart[23:15] = chr_len == 0 ? CHRRAM_MASK : mask_of(chr_len / KB);
/* mirroring, four screens, pattern RAM */
    cart[24]    = file[6][0];
    cart[25]    = file[6][3];
    cart[26]    = chr_len == 0;
/* then the cartridge is in */
    #(RST_NS);
    #(RST_NS);
    cart[31]    = 1'b1;
end

/* the picture */
reg [5:0]  pic [0:PIC_W*PIC_H-1];
reg [5:0]  shown [0:PIC_W*PIC_H-1];
reg [11:0] pal [0:511];
/* counters */
integer    n_frames = 0, n_px = 0;
initial $readmemh("../../rtl/nes_palette.hex", pal);
always @(posedge clk)
begin
/* a pixel */
    if (px_stb)
    begin
        pic[px_y * PIC_W + px_x] <= px_c;
        n_px <= n_px + 1;
    end
/* a frame is complete */
    if (px_eof)
    begin
        shown <= pic;
        n_frames <= n_frames + 1;
    end
end

/* the shown frame as a picture file */
task automatic write_ppm(input string name);
    integer f, k;
    reg [11:0] c;
    begin
/* the file's header */
        f = $fopen(name, "w");
        $fwrite(f, "P3\n%0d %0d\n255\n", PIC_W, PIC_H);
        for (k = 0; k < PIC_W * PIC_H; k = k + 1)
        begin
/* its colour */
            c = pal[shown[k]];
            $fwrite(f, "%0d %0d %0d\n", c[11:8] * C4_TO_8, c[7:4] * C4_TO_8, c[3:0] * C4_TO_8);
        end
        $fclose(f);
    end
endtask

/* the frame buffer and its VGA output */
`ifdef FB
reg pclk = 0;
always #(PCLK_HALF) pclk = ~pclk;
/* the pixel domain's reset */
reg prst_n = 0;
initial #(PRST_NS) prst_n = 1;
wire [11:0] v_rgb;
/* syncs and the active area */
wire        v_hs, v_vs, v_act;
nes_fb #(.PAL_HEX("../../rtl/nes_palette.hex")) u_fb (
    .clk(clk), .rst_n(rst_n), .px_stb(px_stb), .px_x(px_x), .px_y(px_y), .px_c(px_c), .px_e(px_e), .px_eof(px_eof),
    .hold(1'b0), .newest(),
    .clk_sd(clk_sd), .rst_sd_n(rst_n), .m_req(fb_req), .m_we(fb_we), .m_addr(fb_addr), .m_wdata(fb_wdata),
    .m_ack(fb_ack), .m_rdata(fb_rdata),
    .pclk(pclk), .prst_n(prst_n), .rgb(v_rgb), .hsync(v_hs), .vsync(v_vs), .active(v_act)
);
/* one VGA frame: the pixels while active, lines counted by the horizontal sync */
reg [11:0] vga [0:VGA_W*VGA_H-1];
reg [11:0] vga_shown [0:VGA_W*VGA_H-1];
integer    vx = 0, vy = 0, v_frames = 0, v_lit = 0;
/* the syncs as seen last */
reg        v_hs_d = 1, v_vs_d = 1;
always @(posedge pclk)
begin
    v_hs_d <= v_hs;
/* the vertical sync */
    v_vs_d <= v_vs;
    if (v_act)
    begin
        if (vx < VGA_W && vy < VGA_H)
        begin
/* a pixel of the picture */
            vga[vy * VGA_W + vx] <= v_rgb;
        end
        vx    <= vx + 1;
        v_lit <= 1;
    end
/* the end of a line that had pixels */
    if (v_hs_d && !v_hs)
    begin
        vx <= 0;
        if (v_lit != 0)
        begin
/* the next picture line */
            vy <= vy + 1;
        end
        v_lit <= 0;
    end
/* the end of a frame */
    if (v_vs_d && !v_vs)
    begin
        vy        <= 0;
        vga_shown <= vga;
/* one more frame */
        v_frames  <= v_frames + 1;
    end
end
`else
assign fb_req = 1'b0;
/* no write */
assign fb_we = 1'b0;
assign fb_addr = 22'd0;
assign fb_wdata = 16'd0;
/* the end of the frame buffer part */
`endif

/* opcode fetch addresses */
`ifdef TRACE
integer tf;
initial tf = $fopen("trace.txt", "w");
/* every opcode fetch */
always @(posedge clk)
    if (u_sys.cyc_end && u_sys.u_cpu.Sync && u_sys.rdy)
    begin
        $fwrite(tf, "%04x\n", u_sys.cpu_a);
    end
/* the end of the trace */
`endif

/* the key press */
`ifdef PRESS_MS
initial
begin
    #(`PRESS_MS * 1ms);
/* the buttons go down */
    pad1 = `PRESS_PAD;
    #(PRESS_LEN_MS * 1ms);
    pad1 = 8'd0;
end
/* the end of the key press */
`endif

/* reports, the test programs' result */
integer ms = 0, k, resets = 0, nt_used, vf;
reg [7:0] st, ch;
string    text;
/* the end of a run: the picture, the PPU's state, the RAM's first bytes */
task automatic finish_run;
    begin
        write_ppm("frame.ppm");
`ifdef FB
/* the VGA picture as the monitor gets it */
        vf = $fopen("vga.ppm", "w");
        $fwrite(vf, "P3\n%0d %0d\n255\n", VGA_W, VGA_H);
        for (k = 0; k < VGA_W * VGA_H; k = k + 1)
        begin
/* a pixel's three colours */
            $fwrite(vf, "%0d %0d %0d\n", vga_shown[k][11:8] * C4_TO_8, vga_shown[k][7:4] * C4_TO_8, vga_shown[k][3:0] * C4_TO_8);
        end
        $fclose(vf);
        $display("VGA frames %0d", v_frames);
/* the end of the VGA picture */
`endif
/* the PPU's state: control and mask registers, scroll, the first palette entries, name table bytes in use */
        nt_used = 0;
        for (k = 0; k < NT_BYTES; k = k + 1)
        begin
            if (u_sys.u_ppu.nt_ram[k] !== 8'h00 && u_sys.u_ppu.nt_ram[k] !== 8'hxx)
            begin
/* one more byte in use */
                nt_used = nt_used + 1;
            end
        end
        $display("last pattern fetch: PPU address %04x -> SDRAM %06x = %04x (memory there: %02x %02x), shifters %04x %04x",
                 u_sys.u_ppu.pt_addr, u_sys.sd_chr_p, u_sys.pt_q, sd_peek(u_sys.sd_chr_p), sd_peek(u_sys.sd_chr_p + 1),
                 u_sys.u_ppu.bg_lo, u_sys.u_ppu.bg_hi);
        $display("PPU ctrl %02x mask %02x v %04x t %04x palette %02x %02x %02x %02x, name table bytes used %0d",
                 u_sys.u_ppu.ctrl, u_sys.u_ppu.mask, u_sys.u_ppu.v, u_sys.u_ppu.t, u_sys.u_ppu.pal[0], u_sys.u_ppu.pal[1],
                 u_sys.u_ppu.pal[2], u_sys.u_ppu.pal[3], nt_used);
/* the RAM's first bytes */
        $display("RAM 0000: %02x %02x %02x %02x   frames %0d   SDRAM errors %0d", sd_peek(22'h0), sd_peek(22'h1),
                 sd_peek(22'h2), sd_peek(22'h3), n_frames,
`ifdef FAST
                 0);
`else
/* the SDRAM model's count */
                 u_sdram.errors);
`endif
        $finish;
    end
endtask

/* the reports */
initial
begin
    forever
    begin
        #(STEP_MS * 1ms);
/* the time so far */
        ms = ms + STEP_MS;
        $display("%0d ms: PC %04x frames %0d run %b", ms, u_sys.cpu_a, n_frames, a_run);
/* a test program's status in the cartridge RAM */
        if ({sd_peek(SD_WRAM + SIG_AT), sd_peek(SD_WRAM + SIG_AT + 1), sd_peek(SD_WRAM + SIG_AT + SIG_LAST)} == SIGNATURE)
        begin
            st = sd_peek(SD_WRAM);
            if (st == ST_RESET && resets < RESETS_MAX)
            begin
/* it asks for the Reset button, 100 ms later */
                resets = resets + 1;
                #(100ms);
                reset_key = 1'b1;
/* the button is released */
                #(1ms);
                reset_key = 1'b0;
            end
            else if (st < ST_RUNNING)
            begin
/* the text, character by character */
                text = "";
                for (k = TEXT_AT; k < TEXT_MAX; k = k + 1)
                begin
                    ch = sd_peek(SD_WRAM + k);
/* its end */
                    if (ch == 8'd0)
                    begin
                        break;
                    end
                    text = {text, string'(ch)};
                end
/* the text and the verdict */
                $display("%s", text);
                $display("RESULT: %s (status %02x)", st == 8'd0 ? "PASS" : "FAIL", st);
                finish_run();
            end
        end
/* out of time */
        if (ms >= `RUN_MS)
        begin
            $display("RESULT: time limit");
            finish_run();
        end
    end
end

endmodule
