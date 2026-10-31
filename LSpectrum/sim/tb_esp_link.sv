// tb_esp_link: tape_loader with its ESP32 link (rtl/esp_link.v), driven by an SPI master
// model of the ESP32 (8 MHz; +HALF=<ps> half period, +SAMP=<ps> MISO sample point after the
// rising edge, +CLKH=<ps> FPGA clock half period: run_esp_link_sim.sh runs the ESP32's real
// late sampling for both machines' clocks). Snapshot port: a model of zx_bus (memory + freeze) with a
// configurable command time. Checks every link command, the error flag and the IRQ.
`timescale 1ps/1ps
`default_nettype none

module tb_esp_link;

reg clk = 0;
integer CLKH = 8929;                            // 56 MHz (L64: 5289 = 94.5 MHz)
always #CLKH clk = !clk;
reg rst_n = 0;

integer errors = 0;
reg  [17:0] keys = 0;
reg  [31:0] keyraw = 0;
reg         cen_tgl = 0;
always begin repeat (16) @(posedge clk); cen_tgl = !cen_tgl; end

reg  sck = 0, mosi = 0, cs_n = 1;
wire miso, irq;

wire        osd_we;
wire [9:0]  osd_addr;
wire [7:0]  osd_data;
wire        snap_freeze, snap_req;
wire [3:0]  snap_cmd;
wire [17:0] snap_addr;
wire [31:0] snap_wdata;
reg         snap_frozen = 0, snap_ack = 0;
reg  [31:0] snap_rdata = 0;

tape_loader dut (
    .clk (clk), .rst_n (rst_n),
    .keys (keys), .keyraw (keyraw), .cen_tgl (cen_tgl), .mic (1'b0), .hold (),
    .tape_on (), .tape_turbo (), .tape_lvl (),
    .osd_on (), .osd_full (), .osd_we (osd_we), .osd_addr (osd_addr), .osd_data (osd_data),
    .bt_tx (), .bt_rx (1'b1), .int_pos (), .cont_on (), .joy_mode (),
    .snap_freeze (snap_freeze), .snap_req (snap_req), .snap_cmd (snap_cmd), .snap_addr (snap_addr),
    .snap_wdata (snap_wdata), .snap_frozen (snap_frozen), .snap_ack (snap_ack), .snap_rdata (snap_rdata),
    .esp_sck (sck), .esp_mosi (mosi), .esp_cs_n (cs_n), .esp_miso (miso), .esp_irq (irq)
);

//-----------------------------------------------------------------------------
// zx_bus snapshot port model
//-----------------------------------------------------------------------------
reg [7:0] mem [0:262143];
integer   snap_delay = 20;                      // clocks per command
reg       req_q = 0;
always @(posedge clk) snap_frozen <= snap_freeze;
always @(posedge clk) begin
    if (snap_req != req_q) begin
        req_q <= snap_req;
        repeat (snap_delay) @(posedge clk);
        if (snap_cmd == 4'd1) snap_rdata <= {24'd0, mem[snap_addr]};
        if (snap_cmd == 4'd2) mem[snap_addr] <= snap_wdata[7:0];
        if (!snap_frozen && (snap_cmd == 4'd1 || snap_cmd == 4'd2)) begin
            $display("FAIL: memory command while not frozen"); errors = errors + 1;
        end
        snap_ack <= snap_req;
    end
end

//-----------------------------------------------------------------------------
// SPI master (mode 0): MOSI changes at the falling edge, MISO is taken SAMP after the rising
// edge (the ESP32 samples near the falling edge, through its GPIO matrix)
//-----------------------------------------------------------------------------
integer HALF = 62500;
integer SAMP = 62500;
initial begin
    if ($value$plusargs("HALF=%d", HALF)) ;
    if ($value$plusargs("SAMP=%d", SAMP)) ;
    if ($value$plusargs("CLKH=%d", CLKH)) ;
    $display("SPI half period %0d ps, MISO sampled %0d ps after the rising edge, FPGA clock %0.1f MHz",
             HALF, SAMP, 1.0e6 / (2 * CLKH));
end
reg [7:0] rx [0:1023];

task automatic frame(input integer n, input reg [7:0] tx [0:1023]);
    integer i, b;
    reg [7:0] r;
    begin
        cs_n = 0; #150000;
        for (i = 0; i < n; i = i + 1) begin
            for (b = 7; b >= 0; b = b - 1) begin
                mosi = tx[i][b];
                #HALF sck = 1;
                if (SAMP < HALF) begin #SAMP r[b] = miso; #(HALF - SAMP) sck = 0; end
                else begin #HALF sck = 0; #(SAMP - HALF) r[b] = miso; end
            end
            rx[i] = r;
        end
        #100000 cs_n = 1; #200000;
    end
endtask

reg [7:0] tb [0:1023];

task automatic wr(input [7:0] r, input [31:0] d);
    begin
        tb[0] = 8'h01; tb[1] = r; {tb[2], tb[3], tb[4], tb[5]} = d;
        frame(6, tb);
    end
endtask

task automatic rd(input [7:0] r, output [31:0] d);
    begin
        tb[0] = 8'h02; tb[1] = r; tb[2] = 0; tb[3] = 0; tb[4] = 0; tb[5] = 0; tb[6] = 0;
        frame(7, tb);
        d = {rx[3], rx[4], rx[5], rx[6]};
    end
endtask

task automatic stat(output [31:0] d);
    begin
        tb[0] = 8'h07; tb[1] = 0; tb[2] = 0; tb[3] = 0; tb[4] = 0; tb[5] = 0;
        frame(6, tb);
        d = {rx[2], rx[3], rx[4], rx[5]};
    end
endtask

task check(input [255:0] what, input [31:0] got, input [31:0] exp);
    if (got !== exp) begin
        $display("FAIL: %0s: got %08h, expected %08h", what, got, exp); errors = errors + 1;
    end else
        $display("ok    %0s = %08h", what, got);
endtask

// OSD write log
reg [7:0] osd_mem [0:1023];
always @(posedge clk) if (osd_we) osd_mem[osd_addr] <= osd_data;

integer i, n;
reg [31:0] d;
reg [7:0]  pat [0:255];

initial begin
    for (i = 0; i < 262144; i = i + 1) mem[i] = 8'h00;
    // 0. a frame the ESP32 began while the FPGA was still in reset (a machine starting): one
    //    byte in reset, then reset ends and the rest reads as WR INTPOS 80A50012: must be ignored
    begin
        reg [7:0] cut [0:6];
        integer k, b;
        cut[0] = 8'h02; cut[1] = 8'h01; cut[2] = 8'h38;
        cut[3] = 8'h80; cut[4] = 8'hA5; cut[5] = 8'h00; cut[6] = 8'h12;
        cs_n = 0; #150000;
        for (k = 0; k < 7; k = k + 1) begin
            if (k == 1) begin @(posedge clk); rst_n = 1; #200000; end
            for (b = 7; b >= 0; b = b - 1) begin
                mosi = cut[k][b];
                #HALF sck = 1;
                #HALF sck = 0;
            end
        end
        #100000 cs_n = 1; #200000;
    end
    repeat (10) @(posedge clk);

    rd(8'h38, d);
    if (d === 32'h80A5_0012) begin $display("FAIL: a frame cut by the reset was decoded"); errors = errors + 1; end
    else $display("ok    frame cut by the reset ignored (INTPOS %08h)", d);

    // 1. ID
    rd(8'h00, d); check("core ID", d, 32'h5A58_0001);

    // 2. register write / read (INTPOS)
    wr(8'h38, 32'h80A5_0012);
    rd(8'h38, d); check("INTPOS", d, 32'h80A5_0012);

    // 3. OSD bytes
    tb[0] = 8'h03; tb[1] = 8'h00; tb[2] = 8'd101;
    tb[3] = "H"; tb[4] = "E"; tb[5] = "L"; tb[6] = "L"; tb[7] = "O";
    frame(8, tb);
    check("OSD", {osd_mem[101], osd_mem[102], osd_mem[103], osd_mem[104]}, {"H", "E", "L", "L"});
    check("OSD last", {24'd0, osd_mem[105]}, {24'd0, "O"});

    // 4. FIFO: 3 commands (the player starts one and takes one into its look-ahead)
    tb[0] = 8'h04;
    for (i = 0; i < 12; i = i + 1) tb[1 + i] = i;
    frame(13, tb);
    rd(8'h0C, d);
    if (d[9:0] < 1 || d[9:0] > 3) begin $display("FAIL: FIFO used %0d", d[9:0]); errors = errors + 1; end
    else $display("ok    FIFO used %0d", d[9:0]);
    wr(8'h10, 32'd4);                           // flush

    // 5. memory burst: freeze, MWR 256 bytes, MRD them back
    wr(8'h2C, 32'd1);
    rd(8'h2C, d); check("frozen", d & 1, 1);
    for (i = 0; i < 256; i = i + 1) pat[i] = (i * 37 + 11) ^ (i >> 3);
    tb[0] = 8'h05; tb[1] = 8'h01; tb[2] = 8'h7F; tb[3] = 8'hC0;     // 0x17FC0: crosses a page boundary
    for (i = 0; i < 256; i = i + 1) tb[4 + i] = pat[i];
    frame(260, tb);
    #2000000;                                   // the last write finishes after the frame
    n = 0;
    for (i = 0; i < 256; i = i + 1) if (mem[18'h17FC0 + i] !== pat[i]) begin
        if (n < 6) $display("  MWR %0d: mem %02h pat %02h", i, mem[18'h17FC0 + i], pat[i]); n = n + 1; end
    check("MWR mismatches", n, 0);
    tb[0] = 8'h06; tb[1] = 8'h01; tb[2] = 8'h7F; tb[3] = 8'hC0; tb[4] = 0;
    for (i = 0; i < 256; i = i + 1) tb[5 + i] = 0;
    frame(261, tb);
    n = 0;
    for (i = 0; i < 256; i = i + 1) if (rx[5 + i] !== pat[i]) begin
        if (n < 6) $display("  MRD %0d: rx %02h pat %02h mem %02h", i, rx[5 + i], pat[i], mem[18'h17FC0 + i]); n = n + 1; end
    check("MRD mismatches", n, 0);
    stat(d); check("STAT after bursts", d, 0);

    // 6. error flag: commands slower than a byte (two byte times each: 2 us at 8 MHz)
    snap_delay = 16 * HALF / CLKH;
    tb[0] = 8'h06; tb[1] = 8'h01; tb[2] = 8'h7F; tb[3] = 8'hC0; tb[4] = 0; tb[5] = 0; tb[6] = 0;
    frame(7, tb);
    #3000000;
    stat(d); check("STAT after slow MRD", d, 32'h8000_0000);
    stat(d); check("STAT cleared", d, 0);
    snap_delay = 20;
    wr(8'h2C, 32'd0);

    // 7. IRQ: key change with mask bit 1
    wr(8'h04, 32'h0000_0200);
    if (irq) begin $display("FAIL: IRQ before the key change"); errors = errors + 1; end
    keyraw = 32'h0000_0004;
    #1000000;
    if (!irq) begin $display("FAIL: no IRQ after the key change"); errors = errors + 1; end
    else $display("ok    IRQ on key change");
    rd(8'h04, d); check("IRQ register", d & 32'hF02, 32'h202);
    #1000000;
    if (irq) begin $display("FAIL: IRQ still set after reading"); errors = errors + 1; end
    else $display("ok    IRQ cleared by reading");
    rd(8'h28, d); check("KEYRAW", d, 32'h0000_0004);

    if (errors == 0) $display("PASS");
    else             $display("FAILED: %0d errors", errors);
    $finish;
end

endmodule
