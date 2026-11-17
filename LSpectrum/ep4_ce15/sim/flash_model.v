/* flash_model -- W25Q64 READ (0x03) behaviour for the testbench */
/* */
/* Holds one machine's ROM area at AREA: its 4-byte tag (TAG) at the start and the ROM image (FILE, */
/* default roms.mem: the 48 KB ZX ROMs) at BASE = AREA + 0x1000. REVERSE = 1 stores every byte of the */
/* image bit-reversed, as a .jic made from a plain .hex has it (the loader must detect and undo it). */
/* SPI mode 0: command/address sampled on rising DCLK, data shifted out on */
/* falling DCLK, MSB first. */
`timescale 1ns/1ps

/* the model: image base, length, bit order and file */
module flash_model #(
    parameter [23:0] AREA    = 24'h200000,
    parameter [31:0] TAG     = 32'hA55A_18E7,
    parameter [23:0] BASE    = 24'h201000,
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
/* bytes of the tag, and its third byte's number */
localparam integer TAG_BYTES = 4;
localparam [1:0] TAG_THIRD = 2'd2;

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
    reg [1:0] n;
    begin
/* the image's byte, or FF outside it */
        b = (a >= BASE && a < BASE + LEN) ? img[a - BASE] : 8'hFF;
/* the result */
        byte_at = REVERSE ? {b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]} : b;
/* the tag (its bytes are the same in both bit orders) */
        if (a >= AREA && a < AREA + TAG_BYTES)
        begin
            n = a - AREA;
            byte_at = n == 2'd0 ? TAG[31:24] : n == 2'd1 ? TAG[23:16] : n == TAG_THIRD ? TAG[15:8] : TAG[7:0];
        end
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
