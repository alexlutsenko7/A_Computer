// tb_gcr -- c1541_gcr alone: read one track (18, 19 sectors) as the 1541 DOS would: wait for SYNC,
// take the bytes at byte_n, GCR-decode, check header (track, sector, ID, checksum) and data block
// (marker, 256 bytes against the buffer, checksum) for every sector. Buffer as in c1541.v: buf_a
// registered in c1541_gcr, the RAM's output register one more clock.
`timescale 1ns/1ps
module tb_gcr;
reg clk = 0;
always #15.867 clk = !clk;              // 31.51 MHz
reg rst = 1;
initial #200 rst = 0;
reg [31:0] dds = 0;
reg ce = 0;
always @(posedge clk) begin {ce, dds} <= {1'b0, dds} + 33'd136305484; end

wire sync_n, byte_n;
wire [7:0] dout;
wire [12:0] buf_a, buf_wa;
wire buf_we;
wire [7:0] buf_d;
reg  [7:0] mem [0:8191];
reg  [7:0] buf_q;
integer i;
initial for (i = 0; i < 8192; i++) mem[i] = (i * 7 + (i >> 8) * 13) & 8'hFF;
always @(posedge clk) buf_q <= mem[buf_a];

c1541_gcr dut (
    .clk(clk), .rst(rst), .ce(ce), .valid(1'b1), .track(6'd18), .id1(8'h41), .id2(8'h42),
    .density(2'd2), .motor(1'b1), .mode(1'b1), .din(8'h00),
    .sync_n(sync_n), .byte_n(byte_n), .dout(dout),
    .buf_a(buf_a), .buf_q(buf_q), .buf_wa(buf_wa), .buf_we(buf_we), .buf_d(buf_d), .dirty(), .dirty_clr(21'd0)
);

integer bad_gcr = 0, errors = 0, hdrs = 0, datas = 0;
function [3:0] ungcr(input [4:0] g);
    case (g)
        5'b01010: ungcr = 0; 5'b01011: ungcr = 1; 5'b10010: ungcr = 2; 5'b10011: ungcr = 3;
        5'b01110: ungcr = 4; 5'b01111: ungcr = 5; 5'b10110: ungcr = 6; 5'b10111: ungcr = 7;
        5'b01001: ungcr = 8; 5'b11001: ungcr = 9; 5'b11010: ungcr = 10; 5'b11011: ungcr = 11;
        5'b01101: ungcr = 12; 5'b11101: ungcr = 13; 5'b11110: ungcr = 14; 5'b10101: ungcr = 15;
        default: begin ungcr = 0; bad_gcr++; end
    endcase
endfunction

reg [7:0] gb [0:330];                   // GCR bytes after a SYNC
integer   n = 0, insync = 0;
reg [7:0] pl [0:263];                   // decoded plain bytes
integer   cur_sec = -1;

task automatic decode(input integer ngcr, output integer nplain);
    integer g, k;
    reg [39:0] w;
    begin
        nplain = 0;
        for (g = 0; g + 5 <= ngcr; g += 5) begin
            w = {gb[g], gb[g+1], gb[g+2], gb[g+3], gb[g+4]};
            for (k = 0; k < 8; k += 2)
                pl[nplain + k / 2] = {ungcr(w[39 - 5*k -: 5]), ungcr(w[34 - 5*k -: 5])};
            nplain += 4;
        end
    end
endtask

task automatic block_end;
    integer np, k;
    reg [7:0] x;
    begin
        if (n >= 10 && gb[0] == 8'h52) begin                       // header (08 -> 01010 01001...)
            decode(10, np);
            hdrs++;
            x = pl[2] ^ pl[3] ^ pl[4] ^ pl[5];
            if (pl[0] != 8'h08 || pl[1] != x || pl[3] != 18 || pl[4] != 8'h42 || pl[5] != 8'h41) begin
                $display("ERROR header: %02h %02h %02h %02h %02h %02h", pl[0], pl[1], pl[2], pl[3], pl[4], pl[5]); errors++;
            end
            cur_sec = pl[2];
        end else if (n >= 325 && cur_sec >= 0) begin
            decode(325, np);
            datas++;
            x = 0;
            for (k = 1; k <= 256; k++) x ^= pl[k];
            if (pl[0] != 8'h07) begin $display("ERROR data marker %02h (sector %0d)", pl[0], cur_sec); errors++; end
            if (pl[257] != x) begin $display("ERROR data checksum %02h vs %02h (sector %0d)", pl[257], x, cur_sec); errors++; end
            for (k = 0; k < 256; k++)
                if (pl[k + 1] != mem[cur_sec * 256 + k]) begin
                    if (errors < 20) $display("ERROR sector %0d byte %0d: %02h, buffer %02h", cur_sec, k, pl[k + 1], mem[cur_sec * 256 + k]);
                    errors++;
                end
            cur_sec = -1;
        end
    end
endtask

reg sync_p = 1, byte_p = 1;
always @(posedge clk) begin
    sync_p <= sync_n;
    byte_p <= byte_n;
    if (!sync_n && sync_p) begin                                    // SYNC starts: the previous block ends
        if (insync) block_end;
        insync = 1; n = 0;
    end
    if (sync_n && !byte_n && byte_p && insync && n < 331) begin gb[n] = dout; n++; end
end

initial begin
    #250ms;
    $display("headers %0d, data blocks %0d, GCR errors %0d, errors %0d", hdrs, datas, bad_gcr, errors);
    if (hdrs >= 19 && datas >= 19 && errors == 0 && bad_gcr == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL");
    $finish;
end
endmodule
