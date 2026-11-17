/* tb_md -- LMega (md_system + md_mem) with the SDRAM model: runs testrom.bin (mk_testrom.py) */
/* */
/* The test cartridge is written straight into the SDRAM model; then the cartridge is "put in" */
/* as LMega.v does it (RAM clear, VDP reset, machine start). */
/* +define+RUN_MS=<ms>  simulated time (default 45) */
/* Every 5 ms: the 68000's address, frames. At the end: the last complete frame of the VDP as */
/* frame.ppm (320 x 224), the two RAM words the test program leaves ($FF0010: 600D = RAM test */
/* passed, $FF0012: a running counter), the SDRAM model's error count, and RESULT. */
`timescale 1ns/1ps
`ifndef RUN_MS
 `define RUN_MS 45
/* the testbench */
`endif

module tb_md;

/* the reset ends after 300 ns */
localparam integer RST_NS = 300;
/* both data masks high */
localparam integer DQM_OFF = 3;
/* picture size */
localparam integer PIC_W = 320;
localparam integer PIC_H = 224;
/* bytes of the test cartridge */
localparam integer ROM_LEN = 65536;
/* SDRAM: the 68000's RAM */
localparam [22:0] SD_RAM = 23'h400000;
/* 4-bit colour to 8 bits */
localparam integer C4_TO_8 = 17;
/* milliseconds between two reports */
localparam integer STEP_MS = 5;
/* the test program's mark */
localparam [15:0] PASS_MARK = 16'h600D;
/* where the test program leaves its mark and its counter in the RAM */
localparam [22:0] MARK_AT = 23'h10;
localparam [22:0] COUNT_AT = 23'h12;
/* clk_sd half period (107.386 MHz) */
localparam realtime HSD = 4.6561;
localparam real T_CK  = 2 * HSD;
/* pin delays, the SDRAM clock's shift */
localparam real TCO   = 4.0;
localparam real TBACK = 0.5;
localparam real SD_SHIFT = 1.339;

/* the two clocks: mclk every second edge of clk_sd */
reg clk_sd = 0, mclk = 0;
always #(HSD)
begin
    clk_sd = ~clk_sd;
/* the machine clock */
    if (clk_sd)
    begin
        mclk = ~mclk;
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
/* the machine's ports */
wire        mem_req, mem_ack, mem_we, sram_wr;
wire [23:1] mem_addr;
wire [1:0]  mem_be;
/* its data */
wire [15:0] mem_wdata, mem_rdata;
wire        vram_req, vram_ack, vram_we, vram_u_n, vram_l_n, vram32_req, vram32_ack;
wire [15:1] vram_a, vram32_a;
/* the video RAM's data */
wire [15:0] vram_d, vram_q;
wire [31:0] vram32_q;
wire [3:0]  m_r, m_g, m_b;
/* syncs, blankings, the pixel enable */
wire        m_hs, m_vs, m_hbl, m_vbl, m_ce_pix;
wire [1:0]  m_res;
wire signed [15:0] m_audio;

/* the cartridge goes in, as in LMega.v */
reg        run = 0;
reg  [2:0] run_s = 0;
reg        vdp_rst = 1, cart_on = 0;
/* the clear is done */
wire       clr_done;
reg  [1:0] cd_s = 0;
always @(posedge mclk)
begin
/* the cartridge word's run bit, synchronised */
    run_s   <= {run_s[1:0], run};
    cd_s    <= {cd_s[0], clr_done};
    vdp_rst <= !rst_n || (run_s[1] && !run_s[2]);
/* the machine starts when RAM and video RAM are cleared */
    cart_on <= run_s[2] && cd_s[1];
end

md_system u_sys (
    .mclk(mclk), .cart_on(cart_on), .vdp_rst(vdp_rst), .pal(1'b0), .overseas(1'b1), .has_sram(1'b0),
    .reset_btn(1'b0), .pad1(8'd0), .pad2(8'd0),
    .mem_req(mem_req), .mem_ack(mem_ack), .mem_we(mem_we), .mem_addr(mem_addr), .mem_be(mem_be),
    .mem_wdata(mem_wdata), .mem_rdata(mem_rdata), .sram_wr(sram_wr),
    .vram_req(vram_req), .vram_ack(vram_ack), .vram_we(vram_we), .vram_a(vram_a), .vram_d(vram_d), .vram_q(vram_q),
    .vram_u_n(vram_u_n), .vram_l_n(vram_l_n), .vram32_req(vram32_req), .vram32_ack(vram32_ack),
    .vram32_a(vram32_a), .vram32_q(vram32_q),
    .red(m_r), .green(m_g), .blue(m_b), .hs(m_hs), .vs(m_vs), .hbl(m_hbl), .vbl(m_vbl), .ce_pix(m_ce_pix),
    .interlace(), .field(), .resolution(m_res), .audio(m_audio)
);

md_mem u_mem (
    .clk_sd(clk_sd), .rst_sd_n(rst_n),
    .mem_req(mem_req), .mem_ack(mem_ack), .mem_we(mem_we), .mem_addr(mem_addr), .mem_be(mem_be),
    .mem_wdata(mem_wdata), .mem_rdata(mem_rdata),
    .vram_req(vram_req), .vram_ack(vram_ack), .vram_we(vram_we), .vram_a(vram_a), .vram_d(vram_d), .vram_q(vram_q),
    .vram_u_n(vram_u_n), .vram_l_n(vram_l_n), .vram32_req(vram32_req), .vram32_ack(vram32_ack),
    .vram32_a(vram32_a), .vram32_q(vram32_q),
    .x_req(1'b0), .x_we(1'b0), .x_addr(23'd0), .x_din(8'd0), .x_ack(), .x_dout(),
    .clr_go(run_s[2]), .clr_done(clr_done),
    .sd_cke(cke), .sd_cs_n(cs_n), .sd_ras_n(ras_n), .sd_cas_n(cas_n), .sd_we_n(we_n),
    .sd_ba(ba), .sd_a(a), .sd_dqm(dqm), .sd_dq_o(dq_o), .sd_dq_oe(dq_oe), .sd_dq_i(dq_i)
);

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

/* a byte straight into / out of the SDRAM model: {bank, row, column} as in sdram_model */
task automatic sd_poke(input [22:0] ad, input [7:0] v);
    logic [23:0] key;
    logic [15:0] w;
    begin
/* the word as it is now */
        key = {ad[11:10], 2'd0, ad[22:12], ad[9:1]};
        w = u_sdram.mem.exists(key) ? u_sdram.mem[key] : 16'h0000;
        if (ad[0])
        begin
/* the high byte */
            w[15:8] = v;
        end
        else
        begin
            w[7:0] = v;
        end
        u_sdram.mem[key] = w;
    end
endtask

/* a byte out of the model */
function automatic [7:0] sd_peek(input [22:0] ad);
    logic [15:0] w;
    logic [23:0] key;
    begin
/* the word */
        key = {ad[11:10], 2'd0, ad[22:12], ad[9:1]};
        w = u_sdram.mem.exists(key) ? u_sdram.mem[key] : 16'h0000;
        sd_peek = ad[0] ? w[15:8] : w[7:0];
    end
endfunction

/* the cartridge */
reg [7:0] rom [0:ROM_LEN-1];
integer   fd, i, n;
initial
begin
/* the file */
    fd = $fopen("testrom.bin", "rb");
    n = $fread(rom, fd);
    $fclose(fd);
/* into the cartridge's place */
    for (i = 0; i < ROM_LEN; i = i + 1)
    begin
        sd_poke(i, rom[i]);
    end
    #(RST_NS);
/* then the cartridge is put in */
    #(RST_NS);
    run = 1'b1;
end

/* the picture: the VDP's pixels between the blankings */
reg [11:0] pic [0:PIC_W*PIC_H-1];
reg [11:0] shown [0:PIC_W*PIC_H-1];
integer    px = 0, py = 0, n_frames = 0, pk;
/* black until the first pixels come */
initial
begin
    for (pk = 0; pk < PIC_W * PIC_H; pk = pk + 1)
    begin
        pic[pk] = 12'd0;
    end
end
/* the blankings as seen last */
reg        hbl_d = 1, vbl_d = 1;
always @(posedge mclk)
begin
    hbl_d <= m_hbl;
/* a pixel of the picture */
    vbl_d <= m_vbl;
    if (m_ce_pix && !m_hbl && !m_vbl)
    begin
        if (px < PIC_W && py < PIC_H)
        begin
/* its colour */
            pic[py * PIC_W + px] <= {m_r, m_g, m_b};
        end
        px <= px + 1;
    end
/* the line and the frame end */
    if (m_hbl && !hbl_d)
    begin
        px <= 0;
        if (!m_vbl)
        begin
/* the next line */
            py <= py + 1;
        end
    end
    if (m_vbl && !vbl_d)
    begin
        py <= 0;
/* the frame is complete */
        shown <= pic;
        n_frames <= n_frames + 1;
    end
end

/* reports and the result */
integer ms = 0, f, k;
reg [15:0] mark, count;
initial
begin
/* every few milliseconds */
    forever
    begin
        #(STEP_MS * 1ms);
        ms = ms + STEP_MS;
/* where the 68000 is */
        $display("%0d ms: 68000 at %06x, frames %0d, cart_on %b", ms, {u_sys.m68k_a, 1'b0}, n_frames, cart_on);
        if (ms >= `RUN_MS)
        begin
            f = $fopen("frame.ppm", "w");
/* the picture file */
            $fwrite(f, "P3\n%0d %0d\n255\n", PIC_W, PIC_H);
            for (k = 0; k < PIC_W * PIC_H; k = k + 1)
            begin
                $fwrite(f, "%0d %0d %0d\n", shown[k][11:8] * C4_TO_8, shown[k][7:4] * C4_TO_8, shown[k][3:0] * C4_TO_8);
            end
/* the file is complete */
            $fclose(f);
/* the 68000's words have their high byte at the even address */
            mark  = {sd_peek(SD_RAM + MARK_AT), sd_peek(SD_RAM + MARK_AT + 1)};
            count = {sd_peek(SD_RAM + COUNT_AT), sd_peek(SD_RAM + COUNT_AT + 1)};
            $display("RAM mark %04x, counter %04x, SDRAM errors %0d", mark, count, u_sdram.errors);
/* the mark, a running counter and no SDRAM timing error */
            $display("RESULT: %s", (mark == PASS_MARK && count != 16'd0 && u_sdram.errors == 0) ? "PASS" : "FAIL");
            $finish;
        end
    end
end

endmodule
