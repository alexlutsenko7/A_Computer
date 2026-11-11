/* tb_esp_link: tape_loader with its ESP32 link (rtl/esp_link.v), driven by an SPI master */
/* model of the ESP32 (8 MHz; +HALF=<ps> half period, +SAMP=<ps> MISO sample point after the */
/* rising edge, +CLKH=<ps> FPGA clock half period: run_esp_link_sim.sh runs the ESP32's real */
/* late sampling for both machines' clocks). Snapshot port: a model of zx_bus (memory + freeze) with a */
/* configurable command time. Checks every link command, the error flag and the IRQ. */
`timescale 1ps/1ps
`default_nettype none

/* menu: -GFL_HALF=2 -GFLS=1 +FLS */
module tb_esp_link #(parameter integer FL_HALF = 4, parameter FLS = 0);

/* half period of the 56 MHz FPGA clock, ps */
localparam integer CLKH_DEF = 8929;
/* the CPU's T-state toggle comes every 16 clocks */
localparam integer CEN_EVERY = 16;
/* clocks the snapshot port's model takes normally */
localparam integer SNAP_DELAY_DEF = 20;
/* snapshot command: memory write */
localparam [3:0] SNAP_MWR = 4'd2;
/* flash answer pattern: the multiplier */
localparam integer FPAT_MUL = 29;
/* flash answer pattern: the added constant */
localparam integer FPAT_ADD = 7;
/* flash answer pattern: the shift */
localparam integer FPAT_SHIFT = 2;
/* the bit sent first of a byte */
localparam integer MSB = 7;
/* flash bytes the model keeps */
localparam integer FL_LOG_MAX = 1024;
/* SPI half period: 8 MHz, ps */
localparam integer HALF_DEF = 62500;
/* half periods of a clock period */
localparam integer HALVES = 2;
/* chip select goes low this long before the first clock, ps */
localparam integer CS_SETUP_PS = 150000;
/* chip select stays low this long after the last clock, ps */
localparam integer CS_HOLD_PS = 100000;
/* pause between two frames, ps */
localparam integer FRAME_GAP_PS = 200000;
/* bytes of the memory behind the snapshot port */
localparam integer MEM_SIZE = 262144;
/* clocks waited after the cut frame */
localparam integer SETTLE_CLKS = 10;
/* the register value the cut frame would have written */
localparam [31:0] CUT_VALUE = 32'h80A5_0012;
/* data bytes of the FIFO test frame: three commands */
localparam integer FIFO_BYTES = 12;
/* highest fill level after three commands */
localparam integer FIFO_USED_MAX = 3;
/* bytes of a memory burst */
localparam integer BURST = 256;
/* memory test pattern: the multiplier */
localparam integer PAT_MUL = 37;
/* memory test pattern: the added constant */
localparam integer PAT_ADD = 11;
/* memory test pattern: the shift */
localparam integer PAT_SHIFT = 3;
/* time for the last memory write after the frame, ps */
localparam integer MWR_FINISH_PS = 2000000;
/* mismatches listed */
localparam integer LIST_MAX = 6;
/* the slow snapshot answer takes two byte times (16 SPI half bits) */
localparam integer SLOW_BYTES = 16;
/* time for the slow memory read, ps */
localparam integer SLOW_WAIT_PS = 3000000;
/* the raw key word of the interrupt test */
localparam [31:0] KEY_TEST = 32'h0000_0004;
/* time given to the interrupt line, ps */
localparam integer IRQ_WAIT_PS = 1000000;
/* bytes of the flash stream test */
localparam integer FLS_OUT = 300;
/* flash stream pattern: the multiplier */
localparam integer FLS_MUL = 13;
/* flash stream pattern: the added constant */
localparam integer FLS_ADD = 5;
/* flash stream bytes whose answers come back inside the frame */
localparam integer FLS_IN = 298;

reg clk = 0;
/* 56 MHz (L64: 5289 = 94.5 MHz) */
integer CLKH = CLKH_DEF;
always #CLKH clk = !clk;
reg rst_n = 0;

/* errors; the key inputs */
integer errors = 0;
reg  [17:0] keys = 0;
reg  [31:0] keyraw = 0;
/* the CPU's T-state toggle: every 16 clocks */
reg         cen_tgl = 0;
always
begin
    repeat (CEN_EVERY)
    begin
/* toggled; the SPI pins */
        @(posedge clk);
    end
    cen_tgl = !cen_tgl;
end

reg  sck = 0, mosi = 0, cs_n = 1;
/* answers of the design; the OSD port */
wire miso, irq;

wire        osd_we;
wire [9:0]  osd_addr;
/* the snapshot port */
wire [7:0]  osd_data;
wire        snap_freeze, snap_req;
wire [3:0]  snap_cmd;
/* its address and data */
wire [17:0] snap_addr;
wire [31:0] snap_wdata;
reg         snap_frozen = 0, snap_ack = 0;
/* the answer; the flash pins */
reg  [31:0] snap_rdata = 0;

wire fl_en, fl_ncs, fl_dclk, fl_mosi;
reg  fl_miso = 1'b1;

/* the design under test */
tape_loader #(.FL_HALF(FL_HALF), .FLS(FLS)) dut (
    .clk (clk), .rst_n (rst_n),
    .fl_en (fl_en), .fl_ncs (fl_ncs), .fl_dclk (fl_dclk), .fl_mosi (fl_mosi), .fl_miso (fl_miso),
    .keys (keys), .keyraw (keyraw), .cen_tgl (cen_tgl), .mic (1'b0), .hold (),
    .tape_on (), .tape_turbo (), .tape_lvl (),
    .osd_on (), .osd_full (), .osd_we (osd_we), .osd_addr (osd_addr), .osd_data (osd_data),
    .bt_tx (), .bt_rx (1'b1), .int_pos (), .cont_on (), .joy_mode (),
    .snap_freeze (snap_freeze), .snap_req (snap_req), .snap_cmd (snap_cmd), .snap_addr (snap_addr),
    .snap_wdata (snap_wdata), .snap_frozen (snap_frozen), .snap_ack (snap_ack), .snap_rdata (snap_rdata),
    .esp_sck (sck), .esp_mosi (mosi), .esp_cs_n (cs_n), .esp_miso (miso), .esp_irq (irq)
);

/* zx_bus snapshot port model */
reg [7:0] mem [0:262143];
/* clocks per command */
integer   snap_delay = SNAP_DELAY_DEF;
reg       req_q = 0;
always @(posedge clk) snap_frozen <= snap_freeze;
/* a model of the snapshot port: a new request */
always @(posedge clk)
begin
    if (snap_req != req_q)
    begin
        req_q <= snap_req;
/* answered after a delay */
        repeat (snap_delay)
        begin
            @(posedge clk);
        end
        if (snap_cmd == 4'd1)
        begin
/* a memory read; a memory write */
            snap_rdata <= {24'd0, mem[snap_addr]};
        end
        if (snap_cmd == SNAP_MWR)
        begin
            mem[snap_addr] <= snap_wdata[7:0];
        end
/* memory commands need the freeze */
        if (!snap_frozen && (snap_cmd == 4'd1 || snap_cmd == SNAP_MWR))
        begin
            $display("FAIL: memory command while not frozen");
            errors = errors + 1;
        end
/* acknowledged */
        snap_ack <= snap_req;
    end
end

/* SPI flash model for FLS: records every byte it gets (MOSI taken at rising DCLK) and answers */
/* byte k of a chip-select period with fpat(k) (shifted out after each falling edge, MSB first) */
function [7:0] fpat(input integer k);
    fpat = (k * FPAT_MUL + FPAT_ADD) ^ (k >> FPAT_SHIFT);
endfunction
reg  [7:0] fl_got [0:1023];
/* byte and bit counters, shift registers */
integer    fl_n = 0, fl_bit = 0;
reg  [7:0] fl_in = 0, fl_out = 0;
wire       fl_sel = fl_en && !fl_ncs;
/* chip select: a new period */
always @(negedge fl_sel)
begin
    fl_n = 0;
    fl_bit = 0;
/* the first byte out */
    fl_out = fpat(0);
    #1 fl_miso = fl_out[7];
end
always @(posedge fl_dclk)
/* a bit in */
    if (fl_sel)
    begin
        fl_in = {fl_in[6:0], fl_mosi};
        if (fl_bit == MSB)
        begin
/* a whole byte: kept */
            if (fl_n < FL_LOG_MAX)
            begin
                fl_got[fl_n] = fl_in;
            end
        end
    end
always @(negedge fl_dclk)
/* a bit out */
    if (fl_sel)
    begin
        if (fl_bit == MSB)
        begin
            fl_bit = 0;
/* the next byte */
            fl_n = fl_n + 1;
            fl_out = fpat(fl_n);
        end
        else
        begin
            fl_bit = fl_bit + 1;
/* the next bit */
            fl_out = {fl_out[6:0], 1'b0};
        end
        #1 fl_miso = fl_out[7];
    end

/* SPI master (mode 0): MOSI changes at the falling edge, MISO is taken SAMP after the rising */
/* edge (the ESP32 samples near the falling edge, through its GPIO matrix) */
integer HALF = HALF_DEF;
integer SAMP = HALF_DEF;
initial
begin
/* the timing can be set on the command line */
    if ($value$plusargs("HALF=%d", HALF))
    begin
        ;
    end
    if ($value$plusargs("SAMP=%d", SAMP))
    begin
/* the sample point, the FPGA clock */
        ;
    end
    if ($value$plusargs("CLKH=%d", CLKH))
    begin
        ;
    end
/* the timing used */
    $display("SPI half period %0d ps, MISO sampled %0d ps after the rising edge, FPGA clock %0.1f MHz",
             HALF, SAMP, 1.0e6 / (HALVES * CLKH));
end
reg [7:0] rx [0:1023];

task automatic frame(input integer n, input reg [7:0] tx [0:1023]);
/* one SPI frame of n bytes */
    integer i, b;
    reg [7:0] r;
    begin
        cs_n = 0;
/* every byte, MSB first */
        #CS_SETUP_PS;
        for (i = 0; i < n; i = i + 1)
        begin
            for (b = MSB; b >= 0; b = b - 1)
            begin
/* data, then the rising edge */
                mosi = tx[i][b];
                #HALF sck = 1;
                if (SAMP < HALF)
                begin
/* sampled before the falling edge */
                    #SAMP r[b] = miso;
                    #(HALF - SAMP) sck = 0;
                end
                else
                begin
                    #HALF sck = 0;
/* sampled after the falling edge; the byte is kept */
                    #(SAMP - HALF) r[b] = miso;
                end
            end
            rx[i] = r;
        end
        #CS_HOLD_PS cs_n = 1;
/* a pause between frames */
        #FRAME_GAP_PS;
    end
endtask

reg [7:0] tb [0:1023];

task automatic wr(input [7:0] r, input [31:0] d);
    begin
/* a register write: command, register, 4 data bytes */
        tb[0] = 8'h01;
        tb[1] = r;
        {tb[2], tb[3], tb[4], tb[5]} = d;
/* sent */
        frame(6, tb);
    end
endtask

task automatic rd(input [7:0] r, output [31:0] d);
    begin
        tb[0] = 8'h02;
/* a register read: the register, then dummy bytes */
        tb[1] = r;
        tb[2] = 0;
        tb[3] = 0;
/* the data comes in these */
        tb[4] = 0;
        tb[5] = 0;
        tb[6] = 0;
/* sent; the answer */
        frame(7, tb);
        d = {rx[3], rx[4], rx[5], rx[6]};
    end
endtask

task automatic stat(output [31:0] d);
    begin
/* the status frame */
        tb[0] = 8'h07;
        tb[1] = 0;
        tb[2] = 0;
/* dummy bytes */
        tb[3] = 0;
        tb[4] = 0;
        tb[5] = 0;
/* sent; the answer */
        frame(6, tb);
        d = {rx[2], rx[3], rx[4], rx[5]};
    end
endtask

task check(input [255:0] what, input [31:0] got, input [31:0] exp);
/* a wrong value */
    if (got !== exp)
    begin
        $display("FAIL: %0s: got %08h, expected %08h", what, got, exp);
        errors = errors + 1;
    end
    else
    begin
/* a right value */
        $display("ok    %0s = %08h", what, got);
    end
endtask

/* OSD write log */
reg [7:0] osd_mem [0:1023];
/* every OSD write is kept */
always @(posedge clk)
    if (osd_we)
    begin
        osd_mem[osd_addr] <= osd_data;
    end

/* counters, a data word, a test pattern */
integer i, n;
reg [31:0] d;
reg [7:0]  pat [0:255];

/* the memory behind the snapshot port starts empty */
initial
begin
    for (i = 0; i < MEM_SIZE; i = i + 1)
    begin
        mem[i] = 8'h00;
    end
/* 0. a frame the ESP32 began while the FPGA was still in reset (a machine starting): one */
/* byte in reset, then reset ends and the rest reads as WR INTPOS 80A50012: must be ignored */
    begin
        reg [7:0] cut [0:6];
        integer k, b;
        cut[0] = 8'h02;
/* a write frame that the reset cuts */
        cut[1] = 8'h01;
        cut[2] = 8'h38;
        cut[3] = 8'h80;
/* its data */
        cut[4] = 8'hA5;
        cut[5] = 8'h00;
        cut[6] = 8'h12;
/* chip select */
        cs_n = 0;
        #CS_SETUP_PS;
        for (k = 0; k < MSB; k = k + 1)
        begin
/* the reset ends inside byte 1 */
            if (k == 1)
            begin
                @(posedge clk);
                rst_n = 1;
/* a pause, then the byte */
                #FRAME_GAP_PS;
            end
            for (b = MSB; b >= 0; b = b - 1)
            begin
                mosi = cut[k][b];
/* a clock pulse */
                #HALF sck = 1;
                #HALF sck = 0;
            end
        end
        #CS_HOLD_PS cs_n = 1;
/* the frame ends */
        #FRAME_GAP_PS;
    end
    repeat (SETTLE_CLKS)
    begin
/* reset, then run */
        @(posedge clk);
    end

    rd(8'h38, d);
    if (d === CUT_VALUE)
    begin
/* the cut frame must not be decoded */
        $display("FAIL: a frame cut by the reset was decoded");
        errors = errors + 1;
    end
    else
    begin
        $display("ok    frame cut by the reset ignored (INTPOS %08h)", d);
    end

/* 1. ID */
    rd(8'h00, d);
    check("core ID", d, 32'h5A58_0001);

/* 2. register write / read (INTPOS) */
    wr(8'h38, 32'h80A5_0012);
    rd(8'h38, d);
    check("INTPOS", d, 32'h80A5_0012);

/* 3. OSD bytes */
    tb[0] = 8'h03;
    tb[1] = 8'h00;
    tb[2] = 8'd101;
/* the text */
    tb[3] = "H";
    tb[4] = "E";
    tb[5] = "L";
/* its end; sent */
    tb[6] = "L";
    tb[7] = "O";
    frame(8, tb);
/* the text must be in the OSD memory */
    check("OSD", {osd_mem[101], osd_mem[102], osd_mem[103], osd_mem[104]}, {"H", "E", "L", "L"});
    check("OSD last", {24'd0, osd_mem[105]}, {24'd0, "O"});

/* 4. FIFO: 3 commands (the player starts one and takes one into its look-ahead) */
    tb[0] = 8'h04;
    for (i = 0; i < FIFO_BYTES; i = i + 1)
    begin
        tb[1 + i] = i;
    end
/* sent; the fill level is read */
    frame(13, tb);
    rd(8'h0C, d);
    if (d[9:0] < 1 || d[9:0] > FIFO_USED_MAX)
    begin
/* a wrong level */
        $display("FAIL: FIFO used %0d", d[9:0]);
        errors = errors + 1;
    end
    else
    begin
        $display("ok    FIFO used %0d", d[9:0]);
    end
/* flush */
    wr(8'h10, 32'd4);

/* 5. memory burst: freeze, MWR 256 bytes, MRD them back */
    wr(8'h2C, 32'd1);
    rd(8'h2C, d);
    check("frozen", d & 1, 1);
/* a pattern of 256 bytes */
    for (i = 0; i < BURST; i = i + 1)
    begin
        pat[i] = (i * PAT_MUL + PAT_ADD) ^ (i >> PAT_SHIFT);
    end
/* 0x17FC0: crosses a page boundary */
    tb[0] = 8'h05;
    tb[1] = 8'h01;
    tb[2] = 8'h7F;
/* address low byte, then the data */
    tb[3] = 8'hC0;
    for (i = 0; i < BURST; i = i + 1)
    begin
        tb[4 + i] = pat[i];
    end
/* the burst */
    frame(260, tb);
/* the last write finishes after the frame */
    #MWR_FINISH_PS;
    n = 0;
    for (i = 0; i < BURST; i = i + 1)
    begin
/* the memory must hold the pattern */
        if (mem[18'h17FC0 + i] !== pat[i])
        begin
            if (n < LIST_MAX)
            begin
                $display("  MWR %0d: mem %02h pat %02h", i, mem[18'h17FC0 + i], pat[i]);
            end
/* counted; the read burst of the same range */
            n = n + 1;
        end
    end
    check("MWR mismatches", n, 0);
    tb[0] = 8'h06;
/* the address */
    tb[1] = 8'h01;
    tb[2] = 8'h7F;
    tb[3] = 8'hC0;
/* dummy bytes for the answer */
    tb[4] = 0;
    for (i = 0; i < BURST; i = i + 1)
    begin
        tb[5 + i] = 0;
    end
/* sent; compared */
    frame(261, tb);
    n = 0;
    for (i = 0; i < BURST; i = i + 1)
    begin
/* a wrong byte */
        if (rx[5 + i] !== pat[i])
        begin
            if (n < LIST_MAX)
            begin
                $display("  MRD %0d: rx %02h pat %02h mem %02h", i, rx[5 + i], pat[i], mem[18'h17FC0 + i]);
            end
/* counted; the status must be clean */
            n = n + 1;
        end
    end
    check("MRD mismatches", n, 0);
    stat(d);
/* no error after the bursts */
    check("STAT after bursts", d, 0);

/* 6. error flag: commands slower than a byte (two byte times each: 2 us at 8 MHz) */
    snap_delay = SLOW_BYTES * HALF / CLKH;
    tb[0] = 8'h06;
    tb[1] = 8'h01;
/* the address */
    tb[2] = 8'h7F;
    tb[3] = 8'hC0;
    tb[4] = 0;
/* dummy bytes */
    tb[5] = 0;
    tb[6] = 0;
    frame(7, tb);
/* the error flag must be set */
    #SLOW_WAIT_PS;
    stat(d);
    check("STAT after slow MRD", d, 32'h8000_0000);
/* and cleared by the read */
    stat(d);
    check("STAT cleared", d, 0);
    snap_delay = SNAP_DELAY_DEF;
/* the delay back to normal */
    wr(8'h2C, 32'd0);

/* 7. IRQ: key change with mask bit 1 */
    wr(8'h04, 32'h0000_0200);
    if (irq)
    begin
        $display("FAIL: IRQ before the key change");
/* a key changes */
        errors = errors + 1;
    end
    keyraw = KEY_TEST;
    #IRQ_WAIT_PS;
/* the interrupt must come */
    if (!irq)
    begin
        $display("FAIL: no IRQ after the key change");
        errors = errors + 1;
    end
    else
    begin
/* the register shows the cause */
        $display("ok    IRQ on key change");
    end
    rd(8'h04, d);
    check("IRQ register", d & 32'hF02, 32'h202);
/* the read must clear it */
    #IRQ_WAIT_PS;
    if (irq)
    begin
        $display("FAIL: IRQ still set after reading");
/* still set */
        errors = errors + 1;
    end
    else
    begin
        $display("ok    IRQ cleared by reading");
    end
    rd(8'h28, d);
/* the raw keys */
    check("KEYRAW", d, 32'h0000_0004);

/* 8. flash stream (FLS, the menu: FL_HALF 2 at 75 MHz): 300 bytes out, the flash's answers */
/* two frame bytes later, chip select kept until FLASH = EN */
    if ($test$plusargs("FLS"))
    begin
        stat(d);
        tb[0] = 8'h08;
/* a pattern of 300 bytes */
        for (i = 0; i < FLS_OUT; i = i + 1)
        begin
            tb[1 + i] = (i * FLS_MUL + FLS_ADD) & 8'hFF;
        end
        frame(301, tb);
/* the last byte shifts after the frame */
        #IRQ_WAIT_PS;
        if (!fl_sel)
        begin
            $display("FAIL: chip select dropped after the stream");
/* all bytes must reach the flash */
            errors = errors + 1;
        end
        check("FLS bytes at the flash", fl_n, 300);
        n = 0;
/* compared with what was sent */
        for (i = 0; i < FLS_OUT; i = i + 1)
        begin
            if (fl_got[i] !== tb[1 + i])
            begin
                if (n < LIST_MAX)
                begin
/* the first six are listed */
                    $display("  FLS out %0d: flash got %02h sent %02h", i, fl_got[i], tb[1 + i]);
                end
                n = n + 1;
            end
        end
        check("FLS out mismatches", n, 0);
/* the flash's answer, two bytes later */
        n = 0;
        for (i = 0; i < FLS_IN; i = i + 1)
        begin
            if (rx[3 + i] !== fpat(i))
            begin
/* the first six are listed */
                if (n < LIST_MAX)
                begin
                    $display("  FLS in %0d: rx %02h flash %02h", i, rx[3 + i], fpat(i));
                end
                n = n + 1;
            end
        end
/* no mismatch; a clean status */
        check("FLS in mismatches", n, 0);
        stat(d);
        check("STAT after FLS", d, 0);
/* EN only: chip select off */
        wr(8'h40, 32'h0000_0400);
        if (fl_sel)
        begin
            $display("FAIL: chip select still on");
/* chip select must be off */
            errors = errors + 1;
        end
        else
        begin
            $display("ok    chip select off");
        end
    end

    if (errors == 0)
    begin
/* the verdict */
        $display("PASS");
    end
    else
    begin
        $display("FAILED: %0d errors", errors);
    end
/* the end */
    $finish;
end

endmodule
