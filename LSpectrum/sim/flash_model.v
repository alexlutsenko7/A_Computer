//=============================================================================
// flash_model -- W25Q64 READ (0x03) behaviour for the testbench
//
// Holds the ROM image (FILE, default roms.mem: the 48 KB ZX ROMs) at BASE. REVERSE = 1 stores every byte
// bit-reversed, as found in the .jic (the loader must detect and undo it).
// SPI mode 0: command/address sampled on rising DCLK, data shifted out on
// falling DCLK, MSB first.
//=============================================================================
`timescale 1ns/1ps

module flash_model #(
    parameter [23:0] BASE    = 24'h500000,
    parameter integer LEN    = 49152,
    parameter        REVERSE = 1,
    parameter        FILE    = "roms.mem"
)(
    input  wire dclk,
    input  wire ncs,
    input  wire mosi,
    output reg  miso
);

reg [7:0]  img [0:LEN-1];
reg [31:0] cmd;
integer    nbits, rd_bits;
reg [23:0] addr;

initial begin
    $readmemh(FILE, img);
    miso = 1'bz;
end

function [7:0] byte_at(input [23:0] a);
    reg [7:0] b;
    begin
        b = (a >= BASE && a < BASE + LEN) ? img[a - BASE] : 8'hFF;
        byte_at = REVERSE ? {b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]} : b;
    end
endfunction

always @(negedge ncs) begin
    nbits   = 0;
    rd_bits = 0;
end
always @(posedge ncs) miso <= #5 1'bz;

always @(posedge dclk) if (!ncs && nbits < 32) begin
    cmd   = {cmd[30:0], mosi};
    nbits = nbits + 1;
    if (nbits == 32) begin
        if (cmd[31:24] != 8'h03) $display("%t FLASH MODEL: unsupported command %h", $realtime, cmd[31:24]);
        addr = cmd[23:0];
    end
end

reg [7:0] cur;
always @(negedge dclk) if (!ncs && nbits == 32) begin
    cur      = byte_at(addr);
    miso    <= #7 cur[7 - rd_bits];
    rd_bits  = rd_bits + 1;
    if (rd_bits == 8) begin
        rd_bits = 0;
        addr    = addr + 1;
    end
end

endmodule
