/* c1541_gcr -- the disk surface of one 1541 track, made on the fly from the track */
/* buffer (the .d64 sectors of the current track), and written back */
/* */
/* Read: the track is an endless loop of sectors (1541 format): */
/* SYNC (5 x FF, not GCR)   header: 08 chk sector track id2 id1 0F 0F (GCR) */
/* gap  (9 x 55)            SYNC (5 x FF) */
/* data: 07 + 256 bytes + chk + 00 00 (GCR)        gap (8 x 55) */
/* GCR: each nibble -> 5 bits, 4 bytes -> 5 bytes, MSB first. Bit cells come at the rate */
/* the drive selects (VIA2 PB6:5 density 3 .. 0: 26 / 28 / 30 / 32 us per byte), counted */
/* in quarter drive cycles (ce = 1 MHz). */
/* Drive side, as the logic board does it: 10 or more one-bits in a row = SYNC */
/* (sync_n low, read mode only); after SYNC every 8 bits make one byte: byte_n is low */
/* for one drive cycle and the byte is in dout (VIA2 port A). Byte framing goes on in */
/* write mode (the DOS paces its writes with byte_n). */
/* */
/* Write (mode = 0): the bytes the DOS writes (din, taken at each byte_n) after FF bytes */
/* are GCR-decoded; a data block (07, 256 bytes, ...) goes into the track buffer at the */
/* sector whose header passed last, and that sector's dirty bit is set. */
/* */
/* Track buffer: sector s, byte b at {s[4:0], b[7:0]}; read through buf_a (registered */
/* here; buf_q follows one more clock later, the RAM's output register), written through buf_wa / buf_we / buf_d (c64_system muxes the two; */
/* a write wins, the read data is not needed while writing). valid = 0 (no disk, or the */
/* track is being loaded): the stream is all zero bits, the DOS finds no SYNC. */
`default_nettype none

module c1541_gcr (
    input  wire        clk,
    input  wire        rst,
/* drive cycle (1 MHz) */
    input  wire        ce,

/* the track buffer holds the track under the head */
    input  wire        valid,
/* 1..35 */
    input  wire [5:0]  track,
/* disk ID (BAM bytes A2 / A3) */
    input  wire [7:0]  id1,
    input  wire [7:0]  id2,
/* VIA2 PB6:5 */
    input  wire [1:0]  density,
    input  wire        motor,
/* 1 = read, 0 = write */
    input  wire        mode,
/* byte being written (VIA2 port A) */
    input  wire [7:0]  din,

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

/* last track of speed zone 3 */
localparam [5:0] ZONE3_LAST = 6'd17;
/* sectors per track in zone 3 */
localparam [4:0] ZONE3_SECTORS = 5'd21;
/* last track of speed zone 2 */
localparam [5:0] ZONE2_LAST = 6'd24;
/* sectors per track in zone 2 */
localparam [4:0] ZONE2_SECTORS = 5'd19;
/* last track of speed zone 1 */
localparam [5:0] ZONE1_LAST = 6'd30;
/* sectors per track in zone 1 */
localparam [4:0] ZONE1_SECTORS = 5'd18;
/* sectors per track in zone 0 */
localparam [4:0] ZONE0_SECTORS = 5'd17;
/* bit cell divider base (16 - density) */
localparam [4:0] BIT_DIV = 5'd16;
/* the bit cell counter's step per 16 MHz enable */
localparam [4:0] BIT_STEP = 5'd4;
/* bytes of a sync mark */
localparam [3:0] SYNC_LEN = 4'd5;
/* bytes of the gap after a header */
localparam [3:0] GAP1_LEN = 4'd9;
/* bytes of the gap after a data block */
localparam [3:0] GAP2_LEN = 4'd8;
/* the byte of the gaps */
localparam [7:0] GAP_BYTE = 8'h55;
/* bits of a raw (not GCR) byte */
localparam [5:0] RAW_BITS = 6'd8;
/* plain bytes of a GCR group */
localparam [2:0] GROUP_BYTES = 3'd4;
/* bits of a GCR group: 5 bytes */
localparam [5:0] GROUP_BITS = 6'd40;
/* plain bytes of a data block: mark, 256 data, checksum, 2 zeros */
localparam [8:0] DATA_END = 9'd260;
/* third byte of a header half */
localparam [1:0] HDR_PART2 = 2'd2;
/* index of the checksum in a data block */
localparam [8:0] DATA_CHK = 9'd257;
/* first byte of a data block */
localparam [7:0] DATA_MARK = 8'h07;
/* clocks until the track buffer's byte is there */
localparam [1:0] RD_WAIT = 2'd2;
/* ones in a row before the tenth, which makes a SYNC */
localparam [3:0] SYNC_ONES = 4'd9;
/* index of the last data byte of a block */
localparam [8:0] DATA_LAST = 9'd256;

/* sectors per track: 21 (1-17), 19 (18-24), 18 (25-30), 17 (31-35) */
wire [4:0] nsec = track <= ZONE3_LAST ? ZONE3_SECTORS : track <= ZONE2_LAST ? ZONE2_SECTORS : track <= ZONE1_LAST ? ZONE1_SECTORS : ZONE0_SECTORS;

function [4:0] gcr(input [3:0] n);
    case (n)
/* nibbles 0 - 2 */
        4'h0: gcr = 5'b01010;
        4'h1: gcr = 5'b01011;
        4'h2: gcr = 5'b10010;
/* 3 - 5 */
        4'h3: gcr = 5'b10011;
        4'h4: gcr = 5'b01110;
        4'h5: gcr = 5'b01111;
/* 6 - 8 */
        4'h6: gcr = 5'b10110;
        4'h7: gcr = 5'b10111;
        4'h8: gcr = 5'b01001;
/* 9 - B */
        4'h9: gcr = 5'b11001;
        4'hA: gcr = 5'b11010;
        4'hB: gcr = 5'b11011;
/* C - E */
        4'hC: gcr = 5'b01101;
        4'hD: gcr = 5'b11101;
        4'hE: gcr = 5'b11110;
/* F */
        default: gcr = 5'b10101;
    endcase
endfunction

function [3:0] ungcr(input [4:0] g);
    case (g)
/* the same table backwards */
        5'b01010: ungcr = 4'h0;
        5'b01011: ungcr = 4'h1;
        5'b10010: ungcr = 4'h2;
/* 3 - 5 */
        5'b10011: ungcr = 4'h3;
        5'b01110: ungcr = 4'h4;
        5'b01111: ungcr = 4'h5;
/* 6 - 8 */
        5'b10110: ungcr = 4'h6;
        5'b10111: ungcr = 4'h7;
        5'b01001: ungcr = 4'h8;
/* 9 - B */
        5'b11001: ungcr = 4'h9;
        5'b11010: ungcr = 4'hA;
        5'b11011: ungcr = 4'hB;
/* C - E */
        5'b01101: ungcr = 4'hC;
        5'b11101: ungcr = 4'hD;
        5'b11110: ungcr = 4'hE;
/* F, and every code that is no GCR code */
        default: ungcr = 4'hF;
    endcase
endfunction

/* Bit clock: 13 / 14 / 15 / 16 quarter cycles per bit (density 3 / 2 / 1 / 0) */
reg  [4:0] bcnt;
wire [4:0] bstep = BIT_DIV - {3'd0, density};
wire [4:0] bnext = bcnt + BIT_STEP;
/* a bit cell has passed */
reg        bit_tick;
always @(posedge clk or posedge rst)
    if (rst)
    begin
/* at reset */
        bcnt     <= 5'd0;
        bit_tick <= 1'b0;
    end
    else
    begin
        bit_tick <= 1'b0;
/* the bit cell counter of the speed zone */
        if (ce && motor)
        begin
            if (bnext >= bstep)
            begin
                bcnt     <= bnext - bstep;
/* a bit cell is over */
                bit_tick <= 1'b1;
            end
            else
            begin
                bcnt <= bnext;
            end
        end
    end

/* Track stream */
localparam [2:0] P_SYNC1 = 3'd0, P_HDR = 3'd1, P_GAP1 = 3'd2, P_SYNC2 = 3'd3, P_DATA = 3'd4, P_GAP2 = 3'd5;

reg  [2:0]  part;
/* byte (raw parts) / group (header) in the part */
reg  [3:0]  pos;
reg  [4:0]  sec;
/* bits still to send, MSB first */
reg  [39:0] sh;
reg  [5:0]  sh_n;
reg  [7:0]  chk;
/* four plain bytes to encode */
reg  [31:0] grp;
/* plain bytes in grp */
reg  [2:0]  gb;
/* next data block byte, 0..259 */
reg  [8:0]  bidx;
reg         building;
/* buffer read: address register, then the RAM's output register */
reg  [1:0]  rd_wait;

function [7:0] hdr_byte(input [2:0] n, input [4:0] s, input [5:0] t, input [7:0] i1, input [7:0] i2);
    case (n)
/* the header block: mark, checksum, sector */
        3'd0: hdr_byte = 8'h08;
        3'd1: hdr_byte = {3'd0, s} ^ {2'd0, t} ^ i2 ^ i1;
        3'd2: hdr_byte = {3'd0, s};
/* track and the disk ID */
        3'd3: hdr_byte = {2'd0, t};
        3'd4: hdr_byte = i2;
        3'd5: hdr_byte = i1;
/* the gap bytes */
        default: hdr_byte = 8'h0F;
    endcase
endfunction

wire [39:0] gcr_grp = {gcr(grp[31:28]), gcr(grp[27:24]), gcr(grp[23:20]), gcr(grp[19:16]),
                       gcr(grp[15:12]), gcr(grp[11:8]),  gcr(grp[7:4]),   gcr(grp[3:0])};
wire        raw_part = part != P_HDR && part != P_DATA;
/* sync marks are five FF bytes, gap 1 nine bytes, gap 2 eight */
wire        is_sync  = part == P_SYNC1 || part == P_SYNC2;
wire [3:0]  raw_len  = is_sync ? SYNC_LEN : part == P_GAP1 ? GAP1_LEN : GAP2_LEN;

always @(posedge clk or posedge rst)
/* at reset: the first sync of sector 0 */
    if (rst)
    begin
        part <= P_SYNC1;
        pos <= 4'd0;
/* empty shift register */
        sec <= 5'd0;
        sh <= 40'd0;
        sh_n <= 6'd0;
/* no checksum, no group */
        chk <= 8'd0;
        grp <= 32'd0;
        gb <= 3'd0;
/* the data block's start */
        bidx <= 9'd0;
        building <= 1'b0;
        rd_wait <= 2'd0;
/* the buffer address */
        buf_a <= 13'd0;
    end
    else
    begin
        if (bit_tick && sh_n != 6'd0)
        begin
            sh   <= {sh[38:0], 1'b0};
/* one bit less */
            sh_n <= sh_n - 6'd1;
        end
/* the next unit is prepared while the last bit of this one is out (a bit cell is */
/* ~100 clocks, a unit takes at most 13) */
        if (!building && (sh_n == 6'd0 || (sh_n == 6'd1 && bit_tick)))
        begin
            building <= 1'b1;
        end
        if (building)
        begin
/* a raw byte: FF in a sync, 55 in a gap */
            if (raw_part)
            begin
                sh       <= {is_sync ? 8'hFF : GAP_BYTE, 32'd0};
                sh_n     <= RAW_BITS;
/* its last byte: the next part */
                building <= 1'b0;
                if (pos == raw_len - 4'd1)
                begin
                    pos  <= 4'd0;
/* a new block */
                    bidx <= 9'd0;
                    gb   <= 3'd0;
                    chk  <= 8'd0;
/* the part after this one */
                    case (part)
                        P_SYNC1: part <= P_HDR;
                        P_GAP1: part <= P_SYNC2;
/* after the data block's gap: the next sector */
                        P_SYNC2: part <= P_DATA;
                        default:
                        begin
                            part <= P_SYNC1;
/* the last sector is followed by the first */
                            sec  <= (sec + 5'd1 == nsec || sec >= nsec) ? 5'd0 : sec + 5'd1;
                        end
                    endcase
                end
                else
                begin
                    pos <= pos + 4'd1;
                end
/* a group is complete */
            end
            else if (gb == GROUP_BYTES)
            begin
                sh       <= gcr_grp;
                sh_n     <= GROUP_BITS;
/* the group is out */
                building <= 1'b0;
                gb       <= 3'd0;
                if (part == P_HDR)
                begin
/* two groups make the header */
                    pos <= pos + 4'd1;
                    if (pos[0])
                    begin
                        part <= P_GAP1;
/* then the first gap; the data block's last group */
                        pos <= 4'd0;
                    end
                end
                else if (bidx == DATA_END)
                begin
                    part <= P_GAP2;
/* then the second gap; the header's next four bytes */
                    pos  <= 4'd0;
                end
            end
            else if (part == P_HDR)
            begin
                grp <= {hdr_byte({pos[0], 2'd0}, sec, track, id1, id2), hdr_byte({pos[0], 2'd1}, sec, track, id1, id2),
                        hdr_byte({pos[0], HDR_PART2}, sec, track, id1, id2), hdr_byte({pos[0], 2'd3}, sec, track, id1, id2)};
/* four bytes to encode */
                gb  <= GROUP_BYTES;
/* 07, checksum, 00, 00 */
            end
            else if (bidx == 9'd0 || bidx >= DATA_CHK)
            begin
                grp  <= {grp[23:0], bidx == 9'd0 ? DATA_MARK : bidx == DATA_CHK ? chk : 8'h00};
                gb   <= gb + 3'd1;
/* the next byte */
                bidx <= bidx + 9'd1;
/* data byte from the buffer */
            end
            else if (rd_wait == 2'd0)
            begin
                buf_a   <= {sec, bidx[7:0] - 8'd1};
                rd_wait <= 2'd1;
/* buf_a is out, the RAM reads it */
            end
            else if (rd_wait == 2'd1)
            begin
                rd_wait <= RD_WAIT;
/* buf_q holds the byte */
            end
            else
            begin
                rd_wait <= 2'd0;
                grp  <= {grp[23:0], buf_q};
                chk  <= chk ^ buf_q;
/* the group grows */
                gb   <= gb + 3'd1;
                bidx <= bidx + 9'd1;
            end
        end
    end

/* Drive side: SYNC detection and byte framing at each bit tick */
wire       bit_now = valid && sh_n != 6'd0 && sh[39];
reg  [3:0] ones;
reg  [6:0] rsh;
/* the bit count of the byte */
reg  [2:0] rbit;

always @(posedge clk or posedge rst)
    if (rst)
    begin
/* at reset */
        ones <= 4'd0;
        rsh <= 7'd0;
        rbit <= 3'd0;
/* no sync, no byte */
        sync_n <= 1'b1;
        byte_n <= 1'b1;
        dout <= 8'd0;
    end
    else
    begin
/* low for one drive cycle */
        if (ce)
        begin
            byte_n <= 1'b1;
        end
        if (bit_tick)
        begin
/* the bit is shifted in; ones in a row are counted */
            rsh  <= {rsh[5:0], bit_now};
            ones <= bit_now ? (ones == 4'd15 ? ones : ones + 4'd1) : 4'd0;
/* 10th one in a row: SYNC */
            if (mode && bit_now && ones >= SYNC_ONES)
            begin
                sync_n <= 1'b0;
                rbit   <= 3'd0;
            end
            else
            begin
/* no sync; the next bit */
                sync_n <= 1'b1;
                rbit   <= rbit + 3'd1;
                if (rbit == 3'd7)
                begin
/* a whole byte for the VIA */
                    dout   <= {rsh, bit_now};
                    byte_n <= 1'b0;
                end
            end
        end
    end

/* Write: GCR bytes after FF bytes -> plain bytes -> data block into the buffer */
/* sector of the last header that passed */
reg  [4:0]  wsec;
/* GCR bytes of the group so far */
reg  [31:0] wsh;
reg  [2:0]  wn;
/* plain byte of the block: 0 = 07, 1..256 data */
reg  [8:0]  widx;
reg         wact, wsync;
reg  [31:0] wgrp;
/* decoded bytes of wgrp still to store */
reg  [2:0]  wst;
reg  [1:0]  bn_s;
/* byte_n just went low: din holds the byte of this byte time */
wire        wbyte = bn_s == 2'b10;

wire [39:0] wg = {wsh, din};
wire [31:0] wdec = {ungcr(wg[39:35]), ungcr(wg[34:30]), ungcr(wg[29:25]), ungcr(wg[24:20]),
                    ungcr(wg[19:15]), ungcr(wg[14:10]), ungcr(wg[9:5]),   ungcr(wg[4:0])};

/* at reset */
always @(posedge clk or posedge rst)
    if (rst)
    begin
        wsec <= 5'd0;
/* empty shift register */
        wsh <= 32'd0;
        wn <= 3'd0;
        widx <= 9'd0;
/* not writing */
        wact <= 1'b0;
        wsync <= 1'b0;
        wgrp <= 32'd0;
/* no bytes to store */
        wst <= 3'd0;
        bn_s <= 2'b11;
        buf_wa <= 13'd0;
/* no buffer write, nothing dirty */
        buf_we <= 1'b0;
        buf_d <= 8'd0;
        dirty <= 21'd0;
    end
    else
    begin
/* byte ready, synchronised; the write strobe lasts one clock */
        bn_s   <= {bn_s[0], byte_n};
        buf_we <= 1'b0;
        if (part == P_HDR)
        begin
/* the sector under the head; dirty flags the loader has cleared */
            wsec <= sec;
        end
        dirty  <= dirty & ~dirty_clr;

        if (mode)
        begin
/* read mode: the writer stops */
            wact <= 1'b0;
            wsync <= 1'b0;
            wn <= 3'd0;
/* a byte written by the drive */
            wst <= 3'd0;
        end
        else if (wbyte)
        begin
            if (din == 8'hFF)
            begin
/* a sync mark: a new block follows */
                wsync <= 1'b1;
                wact <= 1'b0;
                wn <= 3'd0;
/* from its first byte */
                widx <= 9'd0;
                wst <= 3'd0;
            end
            else if (wsync || wact)
            begin
/* GCR bytes are collected */
                wsync <= 1'b0;
                wact  <= 1'b1;
                wsh   <= {wsh[23:0], din};
/* five of them are four plain bytes */
                wn    <= wn + 3'd1;
                if (wn == GROUP_BYTES)
                begin
                    wn   <= 3'd0;
/* decoded; four bytes to store */
                    wgrp <= wdec;
                    wst  <= GROUP_BYTES;
                end
            end
/* store one plain byte per clock */
        end
        else if (wst != 3'd0)
        begin
            wst  <= wst - 3'd1;
            wgrp <= {wgrp[23:0], 8'd0};
/* the block's first byte tells its kind */
            widx <= widx + 9'd1;
            if (widx == 9'd0)
            begin
/* not a data block */
                if (wgrp[31:24] != DATA_MARK)
                begin
                    wact <= 1'b0;
                    wst <= 3'd0;
                end
            end
/* a data byte into the sector's place in the buffer */
            else if (widx <= DATA_LAST)
            begin
                buf_wa <= {wsec, widx[7:0] - 8'd1};
                buf_d  <= wgrp[31:24];
/* written; the last byte marks the sector dirty */
                buf_we <= 1'b1;
                if (widx == DATA_LAST)
                begin
                    dirty[wsec] <= 1'b1;
                end
            end
        end
    end

endmodule

/* other files keep the default net type */
`default_nettype wire
