/* flash_model -- W25Q64 READ (0x03) behaviour for the testbench */
/* */
/* Holds the ROM image (FILE, default roms.mem: the 48 KB ZX ROMs) at BASE. REVERSE = 1 stores every byte */
/* bit-reversed, as found in the .jic (the loader must detect and undo it). */
/* SPI mode 0: command/address sampled on rising DCLK, data shifted out on */
/* falling DCLK, MSB first. */
`timescale 1ns/1ps

/* the model: image base, length, bit order and file */
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

/* ns from chip select high to the output floating */
localparam integer T_OFF = 5;
/* bits of the read command with its address */
localparam integer CMD_BITS = 32;
/* the only command the model knows: read */
localparam [7:0] CMD_READ = 8'h03;
/* ns from the falling clock to the data */
localparam integer T_OUT = 7;
/* bits of a byte */
localparam integer BYTE_BITS = 8;

reg [7:0]  img [0:LEN-1];
/* the command and address shifted in; bit counters */
reg [31:0] cmd;
integer    nbits, rd_bits;
reg [23:0] addr;

/* the image */
initial
begin
    $readmemh(FILE, img);
    miso = 1'bz;
end

/* the byte at a flash address (FF outside the image), bit-reversed as in a .jic */
function [7:0] byte_at(input [23:0] a);
    reg [7:0] b;
    begin
        b = (a >= BASE && a < BASE + LEN) ? img[a - BASE] : 8'hFF;
/* the result */
        byte_at = REVERSE ? {b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]} : b;
    end
endfunction

/* chip select: a new command */
always @(negedge ncs)
begin
    nbits   = 0;
    rd_bits = 0;
end
/* the output floats; the command's 32 bits */
always @(posedge ncs) miso <= #T_OFF 1'bz;

always @(posedge dclk)
    if (!ncs && nbits < CMD_BITS)
    begin
/* shifted in */
        cmd   = {cmd[30:0], mosi};
        nbits = nbits + 1;
        if (nbits == CMD_BITS)
        begin
/* only READ is known */
            if (cmd[31:24] != CMD_READ)
            begin
                $display("%t FLASH MODEL: unsupported command %h", $realtime, cmd[31:24]);
            end
            addr = cmd[23:0];
        end
    end

/* data out on the falling clock */
reg [7:0] cur;
always @(negedge dclk)
    if (!ncs && nbits == CMD_BITS)
    begin
/* the next bit of the byte */
        cur      = byte_at(addr);
        miso    <= #T_OUT cur[7 - rd_bits];
        rd_bits  = rd_bits + 1;
/* the next byte */
        if (rd_bits == BYTE_BITS)
        begin
            rd_bits = 0;
            addr    = addr + 1;
        end
    end

endmodule
