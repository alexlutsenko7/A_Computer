//=============================================================================
// c1541_gcr -- the disk surface of one 1541 track, made on the fly from the track
//              buffer (the .d64 sectors of the current track), and written back
//
// Read: the track is an endless loop of sectors (1541 format):
//   SYNC (5 x FF, not GCR)   header: 08 chk sector track id2 id1 0F 0F (GCR)
//   gap  (9 x 55)            SYNC (5 x FF)
//   data: 07 + 256 bytes + chk + 00 00 (GCR)        gap (8 x 55)
// GCR: each nibble -> 5 bits, 4 bytes -> 5 bytes, MSB first. Bit cells come at the rate
// the drive selects (VIA2 PB6:5 density 3 .. 0: 26 / 28 / 30 / 32 us per byte), counted
// in quarter drive cycles (ce = 1 MHz).
// Drive side, as the logic board does it: 10 or more one-bits in a row = SYNC
// (sync_n low, read mode only); after SYNC every 8 bits make one byte: byte_n is low
// for one drive cycle and the byte is in dout (VIA2 port A). Byte framing goes on in
// write mode (the DOS paces its writes with byte_n).
//
// Write (mode = 0): the bytes the DOS writes (din, taken at each byte_n) after FF bytes
// are GCR-decoded; a data block (07, 256 bytes, ...) goes into the track buffer at the
// sector whose header passed last, and that sector's dirty bit is set.
//
// Track buffer: sector s, byte b at {s[4:0], b[7:0]}; read through buf_a (registered
// here; buf_q follows one more clock later, the RAM's output register), written through buf_wa / buf_we / buf_d (c64_system muxes the two;
// a write wins, the read data is not needed while writing). valid = 0 (no disk, or the
// track is being loaded): the stream is all zero bits, the DOS finds no SYNC.
//=============================================================================
`default_nettype none

module c1541_gcr (
    input  wire        clk,
    input  wire        rst,
    input  wire        ce,              // drive cycle (1 MHz)

    input  wire        valid,           // the track buffer holds the track under the head
    input  wire [5:0]  track,           // 1..35
    input  wire [7:0]  id1,             // disk ID (BAM bytes A2 / A3)
    input  wire [7:0]  id2,
    input  wire [1:0]  density,         // VIA2 PB6:5
    input  wire        motor,
    input  wire        mode,            // 1 = read, 0 = write
    input  wire [7:0]  din,             // byte being written (VIA2 port A)

    output reg         sync_n,
    output reg         byte_n,
    output reg  [7:0]  dout,

    output reg  [12:0] buf_a,
    input  wire [7:0]  buf_q,
    output reg  [12:0] buf_wa,
    output reg         buf_we,
    output reg  [7:0]  buf_d,
    output reg  [20:0] dirty,
    input  wire [20:0] dirty_clr
);

// sectors per track: 21 (1-17), 19 (18-24), 18 (25-30), 17 (31-35)
wire [4:0] nsec = track <= 6'd17 ? 5'd21 : track <= 6'd24 ? 5'd19 : track <= 6'd30 ? 5'd18 : 5'd17;

function [4:0] gcr(input [3:0] n);
    case (n)
        4'h0: gcr = 5'b01010; 4'h1: gcr = 5'b01011; 4'h2: gcr = 5'b10010; 4'h3: gcr = 5'b10011;
        4'h4: gcr = 5'b01110; 4'h5: gcr = 5'b01111; 4'h6: gcr = 5'b10110; 4'h7: gcr = 5'b10111;
        4'h8: gcr = 5'b01001; 4'h9: gcr = 5'b11001; 4'hA: gcr = 5'b11010; 4'hB: gcr = 5'b11011;
        4'hC: gcr = 5'b01101; 4'hD: gcr = 5'b11101; 4'hE: gcr = 5'b11110; default: gcr = 5'b10101;
    endcase
endfunction

function [3:0] ungcr(input [4:0] g);
    case (g)
        5'b01010: ungcr = 4'h0; 5'b01011: ungcr = 4'h1; 5'b10010: ungcr = 4'h2; 5'b10011: ungcr = 4'h3;
        5'b01110: ungcr = 4'h4; 5'b01111: ungcr = 4'h5; 5'b10110: ungcr = 4'h6; 5'b10111: ungcr = 4'h7;
        5'b01001: ungcr = 4'h8; 5'b11001: ungcr = 4'h9; 5'b11010: ungcr = 4'hA; 5'b11011: ungcr = 4'hB;
        5'b01101: ungcr = 4'hC; 5'b11101: ungcr = 4'hD; 5'b11110: ungcr = 4'hE; default:  ungcr = 4'hF;
    endcase
endfunction

//-----------------------------------------------------------------------------
// Bit clock: 13 / 14 / 15 / 16 quarter cycles per bit (density 3 / 2 / 1 / 0)
//-----------------------------------------------------------------------------
reg  [4:0] bcnt;
wire [4:0] bstep = 5'd16 - {3'd0, density};
wire [4:0] bnext = bcnt + 5'd4;
reg        bit_tick;
always @(posedge clk or posedge rst)
    if (rst) begin
        bcnt     <= 5'd0;
        bit_tick <= 1'b0;
    end else begin
        bit_tick <= 1'b0;
        if (ce && motor) begin
            if (bnext >= bstep) begin
                bcnt     <= bnext - bstep;
                bit_tick <= 1'b1;
            end else
                bcnt <= bnext;
        end
    end

//-----------------------------------------------------------------------------
// Track stream
//-----------------------------------------------------------------------------
localparam [2:0] P_SYNC1 = 3'd0, P_HDR = 3'd1, P_GAP1 = 3'd2, P_SYNC2 = 3'd3, P_DATA = 3'd4, P_GAP2 = 3'd5;

reg  [2:0]  part;
reg  [3:0]  pos;                        // byte (raw parts) / group (header) in the part
reg  [4:0]  sec;
reg  [39:0] sh;                         // bits still to send, MSB first
reg  [5:0]  sh_n;
reg  [7:0]  chk;
reg  [31:0] grp;
reg  [2:0]  gb;                         // plain bytes in grp
reg  [8:0]  bidx;                       // next data block byte, 0..259
reg         building;
reg  [1:0]  rd_wait;                    // buffer read: address register, then the RAM's output register

function [7:0] hdr_byte(input [2:0] n, input [4:0] s, input [5:0] t, input [7:0] i1, input [7:0] i2);
    case (n)
        3'd0:    hdr_byte = 8'h08;
        3'd1:    hdr_byte = {3'd0, s} ^ {2'd0, t} ^ i2 ^ i1;
        3'd2:    hdr_byte = {3'd0, s};
        3'd3:    hdr_byte = {2'd0, t};
        3'd4:    hdr_byte = i2;
        3'd5:    hdr_byte = i1;
        default: hdr_byte = 8'h0F;
    endcase
endfunction

wire [39:0] gcr_grp = {gcr(grp[31:28]), gcr(grp[27:24]), gcr(grp[23:20]), gcr(grp[19:16]),
                       gcr(grp[15:12]), gcr(grp[11:8]),  gcr(grp[7:4]),   gcr(grp[3:0])};
wire        raw_part = part != P_HDR && part != P_DATA;
wire        is_sync  = part == P_SYNC1 || part == P_SYNC2;
wire [3:0]  raw_len  = is_sync ? 4'd5 : part == P_GAP1 ? 4'd9 : 4'd8;

always @(posedge clk or posedge rst)
    if (rst) begin
        part <= P_SYNC1; pos <= 4'd0; sec <= 5'd0; sh <= 40'd0; sh_n <= 6'd0;
        chk <= 8'd0; grp <= 32'd0; gb <= 3'd0; bidx <= 9'd0; building <= 1'b0; rd_wait <= 2'd0;
        buf_a <= 13'd0;
    end else begin
        if (bit_tick && sh_n != 6'd0) begin
            sh   <= {sh[38:0], 1'b0};
            sh_n <= sh_n - 6'd1;
        end
        // the next unit is prepared while the last bit of this one is out (a bit cell is
        // ~100 clocks, a unit takes at most 13)
        if (!building && (sh_n == 6'd0 || (sh_n == 6'd1 && bit_tick)))
            building <= 1'b1;
        if (building) begin
            if (raw_part) begin
                sh       <= {is_sync ? 8'hFF : 8'h55, 32'd0};
                sh_n     <= 6'd8;
                building <= 1'b0;
                if (pos == raw_len - 4'd1) begin
                    pos  <= 4'd0;
                    bidx <= 9'd0;
                    gb   <= 3'd0;
                    chk  <= 8'd0;
                    case (part)
                        P_SYNC1: part <= P_HDR;
                        P_GAP1:  part <= P_SYNC2;
                        P_SYNC2: part <= P_DATA;
                        default: begin
                            part <= P_SYNC1;
                            sec  <= (sec + 5'd1 == nsec || sec >= nsec) ? 5'd0 : sec + 5'd1;
                        end
                    endcase
                end else
                    pos <= pos + 4'd1;
            end else if (gb == 3'd4) begin                          // a group is complete
                sh       <= gcr_grp;
                sh_n     <= 6'd40;
                building <= 1'b0;
                gb       <= 3'd0;
                if (part == P_HDR) begin
                    pos <= pos + 4'd1;
                    if (pos[0]) begin part <= P_GAP1; pos <= 4'd0; end
                end else if (bidx == 9'd260) begin
                    part <= P_GAP2;
                    pos  <= 4'd0;
                end
            end else if (part == P_HDR) begin
                grp <= {hdr_byte({pos[0], 2'd0}, sec, track, id1, id2), hdr_byte({pos[0], 2'd1}, sec, track, id1, id2),
                        hdr_byte({pos[0], 2'd2}, sec, track, id1, id2), hdr_byte({pos[0], 2'd3}, sec, track, id1, id2)};
                gb  <= 3'd4;
            end else if (bidx == 9'd0 || bidx >= 9'd257) begin     // 07, checksum, 00, 00
                grp  <= {grp[23:0], bidx == 9'd0 ? 8'h07 : bidx == 9'd257 ? chk : 8'h00};
                gb   <= gb + 3'd1;
                bidx <= bidx + 9'd1;
            end else if (rd_wait == 2'd0) begin                     // data byte from the buffer
                buf_a   <= {sec, bidx[7:0] - 8'd1};
                rd_wait <= 2'd1;
            end else if (rd_wait == 2'd1) begin                     // buf_a is out, the RAM reads it
                rd_wait <= 2'd2;
            end else begin                                          // buf_q holds the byte
                rd_wait <= 2'd0;
                grp  <= {grp[23:0], buf_q};
                chk  <= chk ^ buf_q;
                gb   <= gb + 3'd1;
                bidx <= bidx + 9'd1;
            end
        end
    end

//-----------------------------------------------------------------------------
// Drive side: SYNC detection and byte framing at each bit tick
//-----------------------------------------------------------------------------
wire       bit_now = valid && sh_n != 6'd0 && sh[39];
reg  [3:0] ones;
reg  [6:0] rsh;
reg  [2:0] rbit;

always @(posedge clk or posedge rst)
    if (rst) begin
        ones <= 4'd0; rsh <= 7'd0; rbit <= 3'd0;
        sync_n <= 1'b1; byte_n <= 1'b1; dout <= 8'd0;
    end else begin
        if (ce) byte_n <= 1'b1;                                     // low for one drive cycle
        if (bit_tick) begin
            rsh  <= {rsh[5:0], bit_now};
            ones <= bit_now ? (ones == 4'd15 ? ones : ones + 4'd1) : 4'd0;
            if (mode && bit_now && ones >= 4'd9) begin              // 10th one in a row: SYNC
                sync_n <= 1'b0;
                rbit   <= 3'd0;
            end else begin
                sync_n <= 1'b1;
                rbit   <= rbit + 3'd1;
                if (rbit == 3'd7) begin
                    dout   <= {rsh, bit_now};
                    byte_n <= 1'b0;
                end
            end
        end
    end

//-----------------------------------------------------------------------------
// Write: GCR bytes after FF bytes -> plain bytes -> data block into the buffer
//-----------------------------------------------------------------------------
reg  [4:0]  wsec;                       // sector of the last header that passed
reg  [31:0] wsh;                        // GCR bytes of the group so far
reg  [2:0]  wn;
reg  [8:0]  widx;                       // plain byte of the block: 0 = 07, 1..256 data
reg         wact, wsync;
reg  [31:0] wgrp;
reg  [2:0]  wst;                        // decoded bytes of wgrp still to store
reg  [1:0]  bn_s;
wire        wbyte = bn_s == 2'b10;      // byte_n just went low: din holds the byte of this byte time

wire [39:0] wg = {wsh, din};
wire [31:0] wdec = {ungcr(wg[39:35]), ungcr(wg[34:30]), ungcr(wg[29:25]), ungcr(wg[24:20]),
                    ungcr(wg[19:15]), ungcr(wg[14:10]), ungcr(wg[9:5]),   ungcr(wg[4:0])};

always @(posedge clk or posedge rst)
    if (rst) begin
        wsec <= 5'd0; wsh <= 32'd0; wn <= 3'd0; widx <= 9'd0; wact <= 1'b0; wsync <= 1'b0;
        wgrp <= 32'd0; wst <= 3'd0; bn_s <= 2'b11;
        buf_wa <= 13'd0; buf_we <= 1'b0; buf_d <= 8'd0; dirty <= 21'd0;
    end else begin
        bn_s   <= {bn_s[0], byte_n};
        buf_we <= 1'b0;
        if (part == P_HDR) wsec <= sec;
        dirty  <= dirty & ~dirty_clr;

        if (mode) begin
            wact <= 1'b0; wsync <= 1'b0; wn <= 3'd0; wst <= 3'd0;
        end else if (wbyte) begin
            if (din == 8'hFF) begin
                wsync <= 1'b1; wact <= 1'b0; wn <= 3'd0; widx <= 9'd0; wst <= 3'd0;
            end else if (wsync || wact) begin
                wsync <= 1'b0;
                wact  <= 1'b1;
                wsh   <= {wsh[23:0], din};
                wn    <= wn + 3'd1;
                if (wn == 3'd4) begin
                    wn   <= 3'd0;
                    wgrp <= wdec;
                    wst  <= 3'd4;
                end
            end
        end else if (wst != 3'd0) begin                             // store one plain byte per clock
            wst  <= wst - 3'd1;
            wgrp <= {wgrp[23:0], 8'd0};
            widx <= widx + 9'd1;
            if (widx == 9'd0) begin
                if (wgrp[31:24] != 8'h07) begin wact <= 1'b0; wst <= 3'd0; end     // not a data block
            end else if (widx <= 9'd256) begin
                buf_wa <= {wsec, widx[7:0] - 8'd1};
                buf_d  <= wgrp[31:24];
                buf_we <= 1'b1;
                if (widx == 9'd256) dirty[wsec] <= 1'b1;
            end
        end
    end

endmodule

`default_nettype wire
