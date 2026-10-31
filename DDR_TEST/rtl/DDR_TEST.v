//=============================================================================
// DDR_TEST -- 256K x 8 RAM window on the QMTECH Cyclone IV board's W9825G6KH SDRAM
//            (ZX plan: 128 KB RAM pages + 32 KB ROM + spare)
//
// Runs ram_tester forever against sdram_ram at 112 MHz (= 4 x 28 MHz,
// the future Z80 turbo clock).
// LED (E4):  slow blink (~0.8 Hz) = tests passing
//            fast blink (~13 Hz)  = data error detected (sticky until reset)
//            steady               = no pass completed for ~2.4 s (stalled)
// KEY (Y13): press to inject a single bit error -> LED must go to fast blink
// RESET_N (W13): restarts everything
//=============================================================================
`default_nettype none

module DDR_TEST #(
    parameter integer ADDR_BITS   = 18,
    parameter integer CLK_MHZ     = 112,
    parameter         SD_PHASE_PS = "1250"     // SDRAM clock delay; PLL rounds to 1339 ps (6 x 223 ps)
)(
    input  wire        CLOCK_50,
    input  wire        RESET_N,
    input  wire        KEY,
    output wire        LEDR,

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
    output wire        DRAM_WE_N
);

//-----------------------------------------------------------------------------
// Clock and reset
//-----------------------------------------------------------------------------
wire clk;
wire clk_sd;            // clk delayed by SD_PHASE_PS
wire locked;

sys_pll #(.SD_PHASE_PS(SD_PHASE_PS)) u_pll (
    .inclk0 (CLOCK_50),
    .c0     (clk),
    .c1     (clk_sd),
    .locked (locked)
);

wire       arst_n = RESET_N & locked;
reg  [2:0] rst_sr;
always @(posedge clk or negedge arst_n)
    if (!arst_n) rst_sr <= 3'b000;
    else         rst_sr <= {rst_sr[1:0], 1'b1};
wire rst_n = rst_sr[2];

// SDRAM clock = inverted clk_sd, forwarded through a DDIO output register so
// that it sees the same I/O delay as the command/data pins. The extra delay
// (SD_PHASE_PS) centres both the command and the read data windows.
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

//-----------------------------------------------------------------------------
// RAM
//-----------------------------------------------------------------------------
wire        ram_req, ram_we, ram_ack, ram_ready;
wire [ADDR_BITS-1:0] ram_addr;
wire [7:0]  ram_din, ram_dout;
wire [15:0] dq_o;
wire        dq_oe;

sdram_ram #(.ADDR_BITS(ADDR_BITS), .CLK_MHZ(CLK_MHZ)) u_ram (
    .clk      (clk),
    .rst_n    (rst_n),
    .req      (ram_req),
    .we       (ram_we),
    .addr     (ram_addr),
    .din      (ram_din),
    .dout     (ram_dout),
    .ack      (ram_ack),
    .ready    (ram_ready),
    .sd_cke   (DRAM_CKE),
    .sd_cs_n  (DRAM_CS_N),
    .sd_ras_n (DRAM_RAS_N),
    .sd_cas_n (DRAM_CAS_N),
    .sd_we_n  (DRAM_WE_N),
    .sd_ba    (DRAM_BA),
    .sd_a     (DRAM_ADDR),
    .sd_dqm   ({DRAM_UDQM, DRAM_LDQM}),
    .sd_dq_o  (dq_o),
    .sd_dq_oe (dq_oe),
    .sd_dq_i  (DRAM_DQ)
);

assign DRAM_DQ = dq_oe ? dq_o : 16'hzzzz;

//-----------------------------------------------------------------------------
// Tester
//-----------------------------------------------------------------------------
reg  [2:0] key_sr;
always @(posedge clk) key_sr <= {key_sr[1:0], KEY};
wire inject = key_sr[2] & ~key_sr[1];           // falling edge = press

wire        error, pass_tick;
wire [15:0] pass_count;
wire [ADDR_BITS-1:0] fail_addr;
wire [7:0]  fail_exp, fail_got;

ram_tester #(.ADDR_BITS(ADDR_BITS)) u_test (
    .clk        (clk),
    .rst_n      (rst_n),
    .ram_ready  (ram_ready),
    .req        (ram_req),
    .we         (ram_we),
    .addr       (ram_addr),
    .wdata      (ram_din),
    .rdata      (ram_dout),
    .ack        (ram_ack),
    .inject     (inject),
    .error      (error),
    .pass_tick  (pass_tick),
    .pass_count (pass_count),
    .fail_addr  (fail_addr),
    .fail_exp   (fail_exp),
    .fail_got   (fail_got)
);

//-----------------------------------------------------------------------------
// LED
//-----------------------------------------------------------------------------
reg [26:0] blink;
reg [27:0] watchdog;
always @(posedge clk) begin
    blink <= blink + 27'd1;
    if (!rst_n || pass_tick)   watchdog <= 28'd0;
    else if (!watchdog[27])    watchdog <= watchdog + 28'd1;
end

assign LEDR = error       ? blink[22] :
              watchdog[27] ? 1'b0      :
                             blink[26];

endmodule

`default_nettype wire
