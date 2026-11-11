/* tb_gcr -- c1541_gcr alone: read one track (18, 19 sectors) as the 1541 DOS would: wait for SYNC, */
/* take the bytes at byte_n, GCR-decode, check header (track, sector, ID, checksum) and data block */
/* (marker, 256 bytes against the buffer, checksum) for every sector. Buffer as in c1541.v: buf_a */
/* registered in c1541_gcr, the RAM's output register one more clock. */
`timescale 1ns/1ps
module tb_gcr;

/* half a period of the 31.51 MHz clock, ns */
localparam real CLK_HALF = 15.867;
/* the reset ends after 200 ns */
localparam integer RST_NS = 200;
/* DDS step of the drive's 1 MHz clock enable */
localparam [32:0] DDS_STEP = 33'd136305484;
/* bytes of the track buffer */
localparam integer BUF_SIZE = 8192;
/* buffer pattern: the multiplier */
localparam integer PAT_MUL = 7;
/* buffer pattern: the shift to the high byte */
localparam integer PAT_SHIFT = 8;
/* buffer pattern: the multiplier of the high byte */
localparam integer PAT_MUL2 = 13;
/* GCR bytes of a group */
localparam integer GROUP_GCR = 5;
/* nibbles of a group */
localparam integer GROUP_NIBBLES = 8;
/* nibbles of a byte */
localparam integer NIBBLES = 2;
/* plain bytes of a GCR group */
localparam integer GROUP_PLAIN = 4;
/* GCR bytes of a header block */
localparam integer HDR_GCR = 10;
/* first GCR byte of a header block */
localparam [7:0] HDR_GCR_FIRST = 8'h52;
/* first byte of a header block */
localparam [7:0] HDR_MARK = 8'h08;
/* the track the test reads */
localparam integer TEST_TRACK = 18;
/* second byte of the disk ID */
localparam [7:0] ID2 = 8'h42;
/* first byte of the disk ID */
localparam [7:0] ID1 = 8'h41;
/* GCR bytes of a data block */
localparam integer DATA_GCR = 325;
/* bytes of a sector */
localparam integer SECTOR = 256;
/* first byte of a data block */
localparam [7:0] DATA_MARK = 8'h07;
/* errors listed */
localparam integer LIST_MAX = 20;
/* GCR bytes kept of a block */
localparam integer BLOCK_MAX = 331;
/* sectors of the test track */
localparam integer TRACK_SECTORS = 19;
reg clk = 0;
/* 31.51 MHz */
always #CLK_HALF clk = !clk;
reg rst = 1;
initial #RST_NS rst = 0;
/* the drive's 16 MHz bit clock enable from a DDS */
reg [31:0] dds = 0;
reg ce = 0;
always @(posedge clk)
begin
/* the step; the read side's outputs */
    {ce, dds} <= {1'b0, dds} + DDS_STEP;
end

wire sync_n, byte_n;
wire [7:0] dout;
/* the track buffer's port */
wire [12:0] buf_a, buf_wa;
wire buf_we;
wire [7:0] buf_d;
/* its memory */
reg  [7:0] mem [0:8191];
reg  [7:0] buf_q;
integer i;
/* a pattern in every byte */
initial
    for (i = 0; i < BUF_SIZE; i++)
    begin
        mem[i] = (i * PAT_MUL + (i >> PAT_SHIFT) * PAT_MUL2) & 8'hFF;
    end
/* read registered; the design under test */
always @(posedge clk) buf_q <= mem[buf_a];

c1541_gcr dut (
    .clk(clk), .rst(rst), .ce(ce), .valid(1'b1), .track(6'd18), .id1(8'h41), .id2(8'h42),
    .density(2'd2), .motor(1'b1), .mode(1'b1), .din(8'h00),
    .sync_n(sync_n), .byte_n(byte_n), .dout(dout),
    .buf_a(buf_a), .buf_q(buf_q), .buf_wa(buf_wa), .buf_we(buf_we), .buf_d(buf_d), .dirty(), .dirty_clr(21'd0)
);

integer bad_gcr = 0, errors = 0, hdrs = 0, datas = 0;
/* the GCR table backwards, as a check of the stream */
function [3:0] ungcr(input [4:0] g);
    case (g)
        5'b01010: ungcr = 0;
/* 1 - 3 */
        5'b01011: ungcr = 1;
        5'b10010: ungcr = 2;
        5'b10011: ungcr = 3;
/* 4 - 6 */
        5'b01110: ungcr = 4;
        5'b01111: ungcr = 5;
        5'b10110: ungcr = 6;
/* 7 - 9 */
        5'b10111: ungcr = 7;
        5'b01001: ungcr = 8;
        5'b11001: ungcr = 9;
/* 10 - 12 */
        5'b11010: ungcr = 10;
        5'b11011: ungcr = 11;
        5'b01101: ungcr = 12;
/* 13 - 15 */
        5'b11101: ungcr = 13;
        5'b11110: ungcr = 14;
        5'b10101: ungcr = 15;
/* not a GCR code */
        default:
        begin
            ungcr = 0;
            bad_gcr++;
        end
    endcase
endfunction

/* GCR bytes after a SYNC */
reg [7:0] gb [0:330];
integer   n = 0, insync = 0;
/* decoded plain bytes */
reg [7:0] pl [0:263];
integer   cur_sec = -1;

task automatic decode(input integer ngcr, output integer nplain);
/* a group of five GCR bytes */
    integer g, k;
    reg [39:0] w;
    begin
        nplain = 0;
/* every group gives four plain bytes */
        for (g = 0; g + GROUP_GCR <= ngcr; g += GROUP_GCR)
        begin
            w = {gb[g], gb[g+1], gb[g+2], gb[g+3], gb[g+4]};
            for (k = 0; k < GROUP_NIBBLES; k += NIBBLES)
            begin
/* two nibbles a byte; four more bytes */
                pl[nplain + k / 2] = {ungcr(w[39 - 5*k -: 5]), ungcr(w[34 - 5*k -: 5])};
            end
            nplain += GROUP_PLAIN;
        end
    end
endtask

task automatic block_end;
/* counters; the checksum */
    integer np, k;
    reg [7:0] x;
    begin
/* header (08 -> 01010 01001...) */
        if (n >= HDR_GCR && gb[0] == HDR_GCR_FIRST)
        begin
            decode(10, np);
            hdrs++;
/* the header's checksum, mark, track and ID */
            x = pl[2] ^ pl[3] ^ pl[4] ^ pl[5];
            if (pl[0] != HDR_MARK || pl[1] != x || pl[3] != TEST_TRACK || pl[4] != ID2 || pl[5] != ID1)
            begin
                $display("ERROR header: %02h %02h %02h %02h %02h %02h", pl[0], pl[1], pl[2], pl[3], pl[4], pl[5]);
/* counted; the sector of this header */
                errors++;
            end
            cur_sec = pl[2];
        end
        else if (n >= DATA_GCR && cur_sec >= 0)
        begin
/* decoded; counted */
            decode(325, np);
            datas++;
            x = 0;
/* the checksum of the 256 data bytes */
            for (k = 1; k <= SECTOR; k++)
            begin
                x ^= pl[k];
            end
            if (pl[0] != DATA_MARK)
            begin
/* a wrong mark */
                $display("ERROR data marker %02h (sector %0d)", pl[0], cur_sec);
                errors++;
            end
            if (pl[257] != x)
            begin
/* a wrong checksum */
                $display("ERROR data checksum %02h vs %02h (sector %0d)", pl[257], x, cur_sec);
                errors++;
            end
            for (k = 0; k < SECTOR; k++)
            begin
/* every byte against the buffer */
                if (pl[k + 1] != mem[cur_sec * 256 + k])
                begin
                    if (errors < LIST_MAX)
                    begin
                        $display("ERROR sector %0d byte %0d: %02h, buffer %02h", cur_sec, k, pl[k + 1], mem[cur_sec * 256 + k]);
                    end
/* counted; the next block needs a new header */
                    errors++;
                end
            end
            cur_sec = -1;
        end
    end
endtask

reg sync_p = 1, byte_p = 1;
/* the previous levels of sync and byte ready */
always @(posedge clk)
begin
    sync_p <= sync_n;
    byte_p <= byte_n;
/* SYNC starts: the previous block ends */
    if (!sync_n && sync_p)
    begin
        if (insync)
        begin
            block_end;
        end
/* a block starts */
        insync = 1;
        n = 0;
    end
    if (sync_n && !byte_n && byte_p && insync && n < BLOCK_MAX)
    begin
/* a byte of the block */
        gb[n] = dout;
        n++;
    end
end

initial
begin
/* 250 ms: more than one revolution */
    #250ms;
    $display("headers %0d, data blocks %0d, GCR errors %0d, errors %0d", hdrs, datas, bad_gcr, errors);
    if (hdrs >= TRACK_SECTORS && datas >= TRACK_SECTORS && errors == 0 && bad_gcr == 0)
    begin
/* the verdict */
        $display("RESULT: PASS");
    end
    else
    begin
        $display("RESULT: FAIL");
    end
    $finish;
end
endmodule
