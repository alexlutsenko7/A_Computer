/* DDR_TEST_C10 -- the DDR_TEST SDRAM test on the QMTECH Cyclone 10 LP board */
/* (10CL025YU256, W9825G6KH SDRAM, 50 MHz oscillator) */
/* */
/* The board has one user key and one user LED, so DDR_TEST runs without a */
/* reset key: SW3 (nCONFIG) restarts everything by reconfiguring the FPGA. */
/* LED D1 (N9):  slow blink (~0.8 Hz) = tests passing */
/* fast blink (~13 Hz)  = data error detected (sticky) */
/* steady               = no pass completed for ~2.4 s (stalled) */
/* KEY0 (F3, SW1): press to inject a single bit error -> LED must go to fast blink */
`default_nettype none

module DDR_TEST_C10 (
    input  wire        CLOCK_50,
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

/* the EP4CE15 top level, its reset tied inactive */
DDR_TEST u_top (
    .CLOCK_50   (CLOCK_50),
    .RESET_N    (1'b1),
    .KEY        (KEY),
    .LEDR       (LEDR),
    .DRAM_ADDR  (DRAM_ADDR),
    .DRAM_BA    (DRAM_BA),
    .DRAM_CAS_N (DRAM_CAS_N),
    .DRAM_CKE   (DRAM_CKE),
    .DRAM_CLK   (DRAM_CLK),
    .DRAM_CS_N  (DRAM_CS_N),
    .DRAM_DQ    (DRAM_DQ),
    .DRAM_LDQM  (DRAM_LDQM),
    .DRAM_RAS_N (DRAM_RAS_N),
    .DRAM_UDQM  (DRAM_UDQM),
    .DRAM_WE_N  (DRAM_WE_N)
);

endmodule

`default_nettype wire
