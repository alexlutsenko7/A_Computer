/* tb_rom_loader -- the ROM loader's search for its machine's ROM area: the tag in the first, the */
/* second or the third area (plain and bit-reversed image), and in none of them (bad_image, nothing */
/* written). Each case is one loader with its own flash model; 256 bytes are loaded and compared. */
`timescale 1ns/1ps
`default_nettype none

/* one loader, one flash, a memory behind the SDRAM port */
module rl_case #(
    parameter [23:0] AREA    = 24'h200000,
    parameter [31:0] FTAG    = 32'hA55A_18E7,
    parameter        REVERSE = 1
)(
    input  wire        clk,
    input  wire        rst_n,
    output wire        done,
    output wire        bad_image,
    output integer     writes,
    output integer     errors
);

/* bytes loaded in this test */
localparam integer LEN = 256;
/* the SDRAM address the image goes to */
localparam [17:0] SD_BASE = 18'h20000;
/* the ROM image inside its area */
localparam [23:0] ROM_OFFSET = 24'h001000;

wire f_dclk, f_ncs, f_mosi, f_miso;
wire sd_req, sd_we;
/* the SDRAM port */
wire [17:0] sd_addr;
wire [7:0]  sd_din;
reg         sd_ack;
/* the image as the file has it */
reg [7:0]   ref_img [0:49151];

flash_model #(.AREA(AREA), .TAG(FTAG), .BASE(AREA + ROM_OFFSET), .REVERSE(REVERSE)) u_flash (
    .dclk(f_dclk), .ncs(f_ncs), .mosi(f_mosi), .miso(f_miso));

rom_loader #(.LEN(LEN), .DIV(4)) u_dut (
    .clk(clk), .rst_n(rst_n), .f_dclk(f_dclk), .f_ncs(f_ncs), .f_mosi(f_mosi), .f_miso(f_miso),
    .sd_req(sd_req), .sd_we(sd_we), .sd_addr(sd_addr), .sd_din(sd_din), .sd_ack(sd_ack),
    .done(done), .bad_image(bad_image));

/* the reference image, the counters */
initial
begin
    $readmemh("roms.mem", ref_img);
/* nothing counted yet */
    writes = 0;
    errors = 0;
end

/* the SDRAM answers one clock later; every byte is compared at once */
always @(posedge clk)
begin
    sd_ack <= sd_req;
    if (sd_req)
    begin
/* counted and compared */
        writes = writes + 1;
        if (!sd_we || sd_addr < SD_BASE || sd_addr >= SD_BASE + LEN || sd_din !== ref_img[sd_addr - SD_BASE])
        begin
            errors = errors + 1;
        end
    end
end

endmodule

/* the five cases side by side */
module tb_rom_loader;

/* half a period of the 112 MHz clock, ps */
localparam integer HALF_PS = 4464;
/* bytes each case loads */
localparam integer LEN = 256;
/* the cases that must load the image (the fifth must not) */
localparam integer GOOD_CASES = 4;
/* clocks of reset */
localparam integer RST_CLKS = 10;

reg clk = 1'b0;
reg rst_n = 1'b0;
/* the clock */
always #(HALF_PS * 1ps) clk = ~clk;

wire [4:0] done, bad;
integer    writes [0:4];
/* per case: bytes that differed */
integer    errors [0:4];
integer    fails;
integer    i;

/* the tag in area 1, 2, 3; in area 2 with a plain image; nowhere (another machine's tag) */
rl_case #(.AREA(24'h200000))                    u_c0 (clk, rst_n, done[0], bad[0], writes[0], errors[0]);
rl_case #(.AREA(24'h400000))                    u_c1 (clk, rst_n, done[1], bad[1], writes[1], errors[1]);
rl_case #(.AREA(24'h600000))                    u_c2 (clk, rst_n, done[2], bad[2], writes[2], errors[2]);
/* a plain image, and another machine's tag */
rl_case #(.AREA(24'h400000), .REVERSE(0))       u_c3 (clk, rst_n, done[3], bad[3], writes[3], errors[3]);
rl_case #(.AREA(24'h400000), .FTAG(32'hA55A_24DB)) u_c4 (clk, rst_n, done[4], bad[4], writes[4], errors[4]);

initial
begin
/* the reset ends after ten clocks */
    fails = 0;
    repeat (RST_CLKS) @(posedge clk);
    rst_n = 1'b1;
/* all five are done well inside 5 ms */
    #5ms;
    for (i = 0; i < GOOD_CASES; i = i + 1)
    begin
        if (!done[i] || bad[i] || writes[i] != LEN || errors[i] != 0)
        begin
/* a case failed */
            fails = fails + 1;
            $display("case %0d FAIL: done %b bad %b writes %0d errors %0d", i, done[i], bad[i], writes[i], errors[i]);
        end
    end
/* no area with the tag: done, bad image, nothing written */
    if (!done[4] || !bad[4] || writes[4] != 0)
    begin
        fails = fails + 1;
        $display("case 4 FAIL: done %b bad %b writes %0d", done[4], bad[4], writes[4]);
    end
/* the verdict */
    if (fails == 0)
    begin
        $display("PASS: ROM area found in position 1, 2, 3 (both bit orders); no area -> bad_image");
    end
    $finish;
end

endmodule

/* the default again */
`default_nettype wire
