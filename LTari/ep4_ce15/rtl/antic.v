/* antic -- ANTIC (PAL): display list, playfield and P/M DMA, refresh, NMIs, WSYNC */
/* */
/* Written from the Altirra Hardware Reference Manual (ch. 4; LTari/ep4_ce15/NOTES.md). */
/* */
/* Timing: one machine cycle = 16 clk ticks; cyc_end is the last tick of a cycle, */
/* when the state moves on and DMA data (dma_d) is taken. hc = cycle in the line */
/* (0-113), vc = scan line (0-311). For the cycle in progress: */
/* dma    ANTIC reads dma_a (the CPU is halted) */
/* rfsh   refresh cycle (the bus is idle, the CPU is halted) */
/* rdy    0 while a WSYNC wait is on (the CPU stops on read cycles) */
/* Per-line slots: cycle 0 missiles, 1 display list, 2-5 players, 6-7 LMS / jump */
/* address; refresh from cycle 25 every 4 (9 per line, one deferred when blocked); */
/* playfield fetches in the window of the mode / width / HSCROL (no DMA from cycle 106). */
/* Line buffer (names / bitmap bytes of a mode line) and character data buffer: block */
/* RAMs read once per colour clock for the display and once per cycle (tick 13) for */
/* the next character data address. */
/* */
/* Display: cce strobes (ticks 3 and 11) give colour clocks cc = 2 hc - 2 and 2 hc - 1; */
/* for each one an_q (ANx code, NOTES.md) and an_cc / an_vc go to GTIA one tick later */
/* (an_stb). Bytes fetched at cycle f are shown from colour clock 2 (f + 4) (bitmap) */
/* or 2 (f + 3) (character data, fetched 3 cycles after its name). */
`default_nettype none

module antic (
    input  wire        clk,
/* power-up / Reset button (XL/XE) */
    input  wire        rst_n,
/* tick in the machine cycle (0-15) */
    input  wire [3:0]  tick,
/* tick == 15 */
    input  wire        cyc_end,

/* registers (CPU): write strobe one clk, read data combinational */
    input  wire        reg_we,
    input  wire [3:0]  reg_a,
    input  wire [7:0]  reg_d,
    output reg  [7:0]  reg_q,

/* bus */
    output wire        dma,
    output wire        rfsh,
    output wire [15:0] dma_a,
/* valid at cyc_end */
    input  wire [7:0]  dma_d,
    output wire        rdy,
    output reg         nmi_n,

/* to GTIA */
/* an_q / an_cc / an_vc valid (twice per cycle) */
    output reg         an_stb,
    output reg  [2:0]  an_q,
/* colour clock 0-227 */
    output reg  [7:0]  an_cc,
/* scan line */
    output reg  [8:0]  an_vc,
/* the line is a hi-res mode line (2, 3, F) */
    output reg         an_hires,
/* P/M DMA byte for GTIA (at cyc_end) */
    output reg         pm_we,
/* 0-3 player, 4 missiles */
    output reg  [2:0]  pm_sel,
    output reg  [7:0]  pm_d
);

/* first visible line */
localparam [8:0] VC_VIS_BEG = 9'd8;
/* first line of the vertical blank (the VBI's line) */
localparam [8:0] VC_VBLANK = 9'd248;
/* cycle from which VCOUNT reads as the next line */
localparam [6:0] HC_VCOUNT_STEP = 7'd111;
/* display mode 2: the first mode with a playfield */
localparam [3:0] MD_2 = 4'd2;
/* display mode 7: the last character mode */
localparam [3:0] MD_7 = 4'd7;
/* display mode 3: text with descenders */
localparam [3:0] MD_3 = 4'd3;
/* display mode 5: the last 40-column character mode */
localparam [3:0] MD_5 = 4'd5;
/* display mode D: the first of the bitmap modes at the full byte rate */
localparam [3:0] MD_D = 4'd13;
/* display mode 8 */
localparam [3:0] MD_8 = 4'd8;
/* display mode 9 */
localparam [3:0] MD_9 = 4'd9;
/* one byte per eight cycles (modes 8 and 9) */
localparam [1:0] RATE_SLOW = 2'd2;
/* bytes per line at the full rate, narrow playfield */
localparam [5:0] BYTES40_NARROW = 6'd32;
/* DMACTL playfield width 2: normal */
localparam [1:0] WIDTH_NORMAL = 2'd2;
/* bytes per line at the full rate, normal playfield */
localparam [5:0] BYTES40_NORMAL = 6'd40;
/* bytes per line at the full rate, wide playfield */
localparam [5:0] BYTES40_WIDE = 6'd48;
/* bytes per line at the half rate, narrow playfield */
localparam [5:0] BYTES20_NARROW = 6'd16;
/* bytes per line at the half rate, normal playfield */
localparam [5:0] BYTES20_NORMAL = 6'd20;
/* bytes per line at the half rate, wide playfield */
localparam [5:0] BYTES20_WIDE = 6'd24;
/* bytes per line at the quarter rate, narrow playfield */
localparam [5:0] BYTES10_NARROW = 6'd8;
/* bytes per line at the quarter rate, normal playfield */
localparam [5:0] BYTES10_NORMAL = 6'd10;
/* bytes per line at the quarter rate, wide playfield */
localparam [5:0] BYTES10_WIDE = 6'd12;
/* first name fetch cycle, narrow playfield */
localparam [6:0] ST_CHR_NARROW = 7'd26;
/* first name fetch cycle, normal playfield */
localparam [6:0] ST_CHR_NORMAL = 7'd18;
/* first name fetch cycle, wide playfield */
localparam [6:0] ST_CHR_WIDE = 7'd10;
/* first bitmap fetch cycle, narrow playfield */
localparam [6:0] ST_MAP_NARROW = 7'd28;
/* first bitmap fetch cycle, normal playfield */
localparam [6:0] ST_MAP_NORMAL = 7'd20;
/* first bitmap fetch cycle, wide playfield */
localparam [6:0] ST_MAP_WIDE = 7'd12;
/* cycles from a name fetch to its character data fetch */
localparam [6:0] CHR_DATA_DELAY = 7'd3;
/* cycle from which playfield DMA is virtual (the bus is not read) */
localparam [6:0] HC_VIRT = 7'd106;
/* first cycle of the player DMA */
localparam [6:0] HC_PLY_FIRST = 7'd2;
/* last cycle of the player DMA */
localparam [6:0] HC_PLY_LAST = 7'd5;
/* cycle of the display list address's low byte */
localparam [6:0] HC_DLA_LO = 7'd6;
/* cycle of the display list address's high byte */
localparam [6:0] HC_DLA_HI = 7'd7;
/* first refresh cycle of a line */
localparam [6:0] HC_RF_FIRST = 7'd25;
/* last refresh cycle of a line */
localparam [6:0] HC_RF_LAST = 7'd57;
/* cycle of player 0's DMA slot */
localparam [1:0] HC_PLY_BASE = 2'd2;
/* mode 3: rows 0 and 1 are blank for characters with descenders */
localparam [3:0] ROW_DESC_TOP = 4'd2;
/* mode 3: rows 8 and 9 are blank for the other characters */
localparam [3:0] ROW_DESC_BODY = 4'd8;
/* first tick of the cycle's second colour clock */
localparam [3:0] TICK_PHASE1 = 4'd8;
/* colour clocks between the cycle counter and the pixel position */
localparam [7:0] CC_OFFSET = 8'd2;
/* colour clock of the first byte, narrow playfield */
localparam [7:0] CC0_NARROW = 8'h40;
/* colour clock of the first byte, normal playfield */
localparam [7:0] CC0_NORMAL = 8'h30;
/* colour clock of the first byte, wide playfield */
localparam [7:0] CC0_WIDE = 8'h20;
/* left edge of the narrow playfield */
localparam [7:0] WL_NARROW = 8'h40;
/* left edge of the normal playfield */
localparam [7:0] WL_NORMAL = 8'h30;
/* left edge of the wide playfield */
localparam [7:0] WL_WIDE = 8'h2C;
/* right edge of the narrow playfield */
localparam [7:0] WR_NARROW = 8'hC0;
/* right edge of the normal playfield */
localparam [7:0] WR_NORMAL = 8'hD0;
/* right edge of the wide playfield */
localparam [7:0] WR_WIDE = 8'hDE;
/* a WSYNC write after this cycle stops the next line too */
localparam [6:0] HC_WSYNC_LATE = 7'd103;
/* tick of the second colour clock's buffer address */
localparam [3:0] TICK_ADDR2 = 4'd9;
/* first visible colour clock */
localparam [7:0] CC_VIS_BEG = 8'h22;
/* first colour clock after the visible part */
localparam [7:0] CC_VIS_END = 8'hDE;
/* tick at which the first colour clock's code goes out */
localparam [3:0] TICK_CODE1 = 4'd3;
/* tick at which the second colour clock's code goes out */
localparam [3:0] TICK_CODE2 = 4'd11;
/* tick at which the next name's buffer address is set */
localparam [3:0] TICK_NAME_ADDR = 4'd13;
/* cycle at which the NMI line goes high again */
localparam [6:0] HC_NMI_END = 7'd60;
/* display mode 6: the first 20-column character mode */
localparam [3:0] MD_6 = 4'd6;
/* player/missile DMA slot of the missiles */
localparam [2:0] PM_MISSILES = 3'd4;
/* cycle at which the NMI status is set */
localparam [6:0] HC_NMI_STATUS = 7'd6;
/* cycle at which the NMI line goes low */
localparam [6:0] HC_NMI_LINE = 7'd7;
/* cycle at which WSYNC lets the CPU go */
localparam [6:0] HC_WSYNC_END = 7'd104;
/* last cycle of a line (114 per line) */
localparam [6:0] HC_LAST = 7'd113;
/* the line after the first visible one */
localparam [8:0] VC_VIS_SECOND = 9'd9;

localparam [8:0] VLINES = 9'd312;

/* Registers */
reg  [5:0]  dmactl;
reg  [2:0]  chactl;
reg  [15:0] dlist;
/* scroll values, base addresses */
reg  [3:0]  hscrol, vscrol;
reg  [7:2]  pmbase;
reg  [7:1]  chbase;
/* [1] DLI, [0] VBI */
reg  [1:0]  nmien;
/* NMIST bits 7, 6 */
reg         st_dli, st_vbi;

reg  [6:0]  hc;
reg  [8:0]  vc;
/* visible lines; the next line number */
wire        vis   = vc >= VC_VIS_BEG && vc < VC_VBLANK;
wire [8:0]  vc_n  = vc == VLINES - 1 ? 9'd0 : vc + 9'd1;
/* VCOUNT moves on at cycle 111 */
wire [8:0]  vc_rd = hc >= HC_VCOUNT_STEP ? vc_n : vc;

always @*
begin
    case (reg_a)
/* VCOUNT */
        4'hB: reg_q = vc_rd[8:1];
/* PENH (no light pen) */
        4'hC: reg_q = 8'h00;
/* PENV */
        4'hD: reg_q = 8'hFF;
/* NMIST */
        4'hF: reg_q = {st_dli, st_vbi, 1'b0, 5'b11111};
        default: reg_q = 8'hFF;
    endcase
end

/* Mode line state */
reg  [7:0]  ir;
reg  [3:0]  row, row_end;
/* this line starts a mode line */
reg         ml_first;
/* jump and wait for vertical blank done */
reg         jvb;
/* the previous mode line had vertical scrolling */
reg         vs_prev;
/* an instruction byte was fetched on this line */
reg         dl_got;
reg  [7:0]  adr_lo;
/* memory scan counter */
reg  [15:0] msc;
reg         wsync, wsync_nx;
/* a mode line was set up in this frame */
reg         dl_any;

wire [3:0]  md     = ir[3:0];
/* a playfield mode line */
wire        pf_md  = md >= MD_2 && !jvb && vis;
wire        chr    = md >= MD_2 && md <= MD_7;
wire        hires  = md == MD_2 || md == MD_3 || md == 4'd15;
/* the last row of the mode line */
wire        last   = row == row_end;
/* display width */
wire [1:0]  dw     = dmactl[1:0];
wire        hs_on  = ir[4] && pf_md;
/* fetch width */
wire [1:0]  fw     = dw == 2'd0 ? 2'd0 : (hs_on && dw != 2'd3) ? dw + 2'd1 : dw;
wire [2:0]  hs_cyc = hs_on ? hscrol[3:1] : 3'd0;

/* mode height - 1 */
function [3:0] hmax(input [7:0] i);
    case (i[3:0])
        4'h0: hmax = {1'b0, i[6:4]};
/* rows per mode line - 1, by mode */
        4'h1, 4'hC, 4'hE, 4'hF: hmax = 4'd0;
        4'h2, 4'h4, 4'h6, 4'h8: hmax = 4'd7;
        4'h3: hmax = 4'd9;
/* 16 rows; 4 rows */
        4'h5, 4'h7: hmax = 4'd15;
        4'h9, 4'hA: hmax = 4'd3;
/* B, D */
        default: hmax = 4'd1;
    endcase
endfunction

/* fetch rate: 0 = every 2 cycles, 1 = 4, 2 = 8 */
wire [1:0]  rate   = (md >= MD_2 && md <= MD_5) || md >= MD_D ? 2'd0 :
                     (md == MD_8 || md == MD_9) ? RATE_SLOW : 2'd1;
wire [5:0]  count  = rate == 2'd0 ? (fw == 2'd1 ? BYTES40_NARROW : fw == WIDTH_NORMAL ? BYTES40_NORMAL : BYTES40_WIDE) :
                     rate == 2'd1 ? (fw == 2'd1 ? BYTES20_NARROW : fw == WIDTH_NORMAL ? BYTES20_NORMAL : BYTES20_WIDE) :
                                    (fw == 2'd1 ? BYTES10_NARROW  : fw == WIDTH_NORMAL ? BYTES10_NORMAL : BYTES10_WIDE);
wire [6:0]  st_chr = (fw == 2'd1 ? ST_CHR_NARROW : fw == WIDTH_NORMAL ? ST_CHR_NORMAL : ST_CHR_WIDE) + {4'd0, hs_cyc};
/* the start of the bitmap fetches */
wire [6:0]  st_map = (fw == 2'd1 ? ST_MAP_NARROW : fw == WIDTH_NORMAL ? ST_MAP_NORMAL : ST_MAP_WIDE) + {4'd0, hs_cyc};

/* is cycle c a fetch slot of a window starting at s? index in n */
function slot(input [6:0] c, input [6:0] s, input [1:0] r, input [5:0] cnt);
    reg [6:0] k;
    begin
        k = c - s;
/* at or after the start, on the mode's fetch grid, within the count */
        slot = c >= s && (r == 2'd0 ? !k[0] : r == 2'd1 ? k[1:0] == 2'd0 : k[2:0] == 3'd0) &&
               (r == 2'd0 ? k[6:1] : r == 2'd1 ? {1'b0, k[6:2]} : {2'b00, k[6:3]}) < cnt;
    end
endfunction
function [5:0] sidx(input [6:0] c, input [6:0] s, input [1:0] r);
    reg [6:0] k;
    begin
/* the cycles since the start */
        k = c - s;
        sidx = r == 2'd0 ? k[6:1] : r == 2'd1 ? {1'b0, k[6:2]} : {2'b00, k[6:3]};
    end
endfunction

wire        pf_on   = pf_md && fw != 2'd0;
/* the three kinds of playfield fetches */
wire        s_name  = pf_on && chr && ml_first && slot(hc, st_chr, rate, count);
wire        s_data  = pf_on && chr && slot(hc - CHR_DATA_DELAY, st_chr, rate, count) && hc >= CHR_DATA_DELAY;
wire        s_map   = pf_on && !chr && ml_first && slot(hc, st_map, rate, count);
/* their index in the line */
wire [5:0]  n_name  = sidx(hc, st_chr, rate);
wire [5:0]  n_data  = sidx(hc - CHR_DATA_DELAY, st_chr, rate);
wire [5:0]  n_map   = sidx(hc, st_map, rate);
/* no DMA, but the slot still counts */
wire        virt    = hc >= HC_VIRT;
wire        pf_dma  = (s_name || s_data || s_map) && !virt;

/* fixed slots */
wire        pm_on   = vis && (dmactl[2] || dmactl[3]);
wire        s_mis   = hc == 7'd0 && pm_on;
wire        s_ply   = hc >= HC_PLY_FIRST && hc <= HC_PLY_LAST && vis && dmactl[3];
/* display list fetches: instruction, then the two address bytes */
wire        s_dl    = hc == 7'd1 && vis && ml_first && dmactl[5] && !jvb;
wire        lms     = ir[6] && md >= MD_2;
wire        s_dla   = (hc == HC_DLA_LO || hc == HC_DLA_HI) && vis && ml_first && dl_got && (md == 4'd1 || lms);

/* refresh: slots 25, 29, ... 57; one blocked slot waits for the next free cycle */
reg         rf_pend;
wire        rf_slot = hc >= HC_RF_FIRST && hc <= HC_RF_LAST && hc[1:0] == 2'b01;
wire        busy    = pf_dma;
/* a refresh cycle is due and the bus is free */
wire        rf_now  = !busy && (rf_slot || rf_pend);

assign dma   = s_mis || s_ply || s_dl || s_dla || pf_dma;
assign rfsh  = rf_now && !(s_mis || s_ply || s_dl || s_dla);

/* P/M addresses */
/* one-line resolution */
wire        pm1   = dmactl[4];
/* +$300 / +$180 */
wire [15:0] a_mis = pm1 ? {pmbase[7:3], 3'b011, vc[7:0]} : {pmbase[7:2], 3'b011, vc[7:1]};
/* player 0-3 at cycles 2-5 */
wire [1:0]  pn    = hc[1:0] - HC_PLY_BASE;
/* +$400 / +$200 */
wire [15:0] a_ply = pm1 ? {pmbase[7:3], 1'b1, pn, vc[7:0]} : {pmbase[7:2], 1'b1, pn, vc[7:1]};

/* character data address (registered at tick 15 of the cycle before, from the name) */
reg  [15:0] a_chr;
/* the name of that data fetch */
reg  [7:0]  name_q;

assign dma_a = s_mis ? a_mis :
               s_ply ? a_ply :
               (s_dl || s_dla) ? dlist :
               s_data ? a_chr : msc;

/* WSYNC: written up to cycle 103 -> released at cycle 105 of this line, else of the next */
assign rdy = !wsync;

/* Line buffer and character data buffer (block RAMs, one read port each) */
reg  [7:0]  lb [0:63];
reg  [7:0]  cd [0:63];
reg  [5:0]  lb_ra;
/* the two line buffers' ports */
reg  [7:0]  lb_q, cd_q;
reg         lb_we, cd_we;
reg  [5:0]  lb_wa, cd_wa;
/* write data; the memories */
reg  [7:0]  lb_wd, cd_wd;
always @(posedge clk)
begin
    if (lb_we)
    begin
/* name / bitmap bytes */
        lb[lb_wa] <= lb_wd;
    end
    if (cd_we)
    begin
        cd[cd_wa] <= cd_wd;
    end
/* read registered */
    lb_q <= lb[lb_ra];
    cd_q <= cd[lb_ra];
end

/* font row of the current scan line, and whether this row is blank (mode 3) */
function [2:0] frow(input [3:0] m, input [3:0] r, input flip);
    reg [2:0] f;
    begin
        f = (m == MD_5 || m == MD_7) ? r[3:1] : r[2:0];
/* flipped by CHACTL bit 2 */
        frow = flip ? 3'd7 - f : f;
    end
endfunction

/* character data byte as shown (modes 2/3: blank / invert by name bit 7; mode 3 rows) */
function [7:0] chproc(input [3:0] m, input [3:0] r, input [7:0] nm, input [7:0] d, input [2:0] ca);
    reg [7:0] v;
    reg       blank_row;
    begin
/* blank rows of mode 3 descenders */
        blank_row = m == MD_3 && (nm[6:5] == 2'b11 ? r < ROW_DESC_TOP : r >= ROW_DESC_BODY);
        v = blank_row ? 8'h00 : d;
        if (m == MD_2 || m == MD_3)
        begin
/* bit 7 with CHACTL 0: blank */
            if (nm[7] && ca[0])
            begin
                v = 8'h00;
            end
            if (nm[7] && ca[1])
            begin
/* inverted; the result */
                v = ~v;
            end
        end
        chproc = v;
    end
endfunction

/* Display: colour clock pipeline (read address at ticks 1 / 9: the block RAM's data is there */
/* one clock later and stays until tick 13; ANx code at ticks 3 / 11) */
wire        ph1    = tick >= TICK_PHASE1;
/* colour clock of this half */
wire [7:0]  cc_now = {hc, ph1} - CC_OFFSET;
wire [7:0]  cc0    = (fw == 2'd1 ? CC0_NARROW : fw == WIDTH_NORMAL ? CC0_NORMAL : CC0_WIDE) + (hs_on ? {4'd0, hscrol} : 8'd0);
/* visible playfield */
wire [7:0]  wl     = dw == 2'd1 ? WL_NARROW : dw == WIDTH_NORMAL ? WL_NORMAL : WL_WIDE;
wire [7:0]  wr     = dw == 2'd1 ? WR_NARROW : dw == WIDTH_NORMAL ? WR_NORMAL : WR_WIDE;
/* colour clocks per byte: 4 (modes 2-5, D-F), 8 (6, 7, A-C), 16 (8, 9) */
wire [1:0]  cpb    = (md >= MD_2 && md <= MD_5) || md >= MD_D ? 2'd0 :
                     (md == MD_8 || md == MD_9) ? RATE_SLOW : 2'd1;
wire [7:0]  off    = cc_now - cc0;
wire [5:0]  d_idx  = cpb == 2'd0 ? off[7:2] : cpb == 2'd1 ? {1'b0, off[7:3]} : {2'b00, off[7:4]};
/* the colour clock inside the byte; inside the playfield */
wire [3:0]  d_sub  = cpb == 2'd0 ? {2'b00, off[1:0]} : cpb == 2'd1 ? {1'b0, off[2:0]} : off[3:0];
wire        d_in   = pf_on && cc_now >= wl && cc_now < wr && cc_now >= cc0 && d_idx < count;

reg  [7:0]  q_cc;
/* the pipeline's stage */
reg  [3:0]  q_sub;
reg         q_in, q_blank;

/* ANx code of one colour clock from the byte (lb_q = name / bitmap, cd_q = char data) */
function [2:0] pix(input [3:0] m, input [3:0] s, input [7:0] nm, input [7:0] cdat);
    reg [1:0] p;
    reg       b;
    begin
/* modes 2, 3: two hi-res pixels */
        case (m)
            4'd2, 4'd3:
            begin
                p = s[1] ? (s[0] ? cdat[1:0] : cdat[3:2]) : (s[0] ? cdat[5:4] : cdat[7:6]);
/* as PF2 with luminance from PF1 */
                pix = {1'b1, p};
            end
            4'd4, 4'd5:
            begin
                p = s[1] ? (s[0] ? cdat[1:0] : cdat[3:2]) : (s[0] ? cdat[5:4] : cdat[7:6]);
/* modes 4, 5: two bits per colour clock; 3 = PF2 or PF3 by name bit 7 */
                pix = p == 2'b00 ? 3'b000 : p == 2'b11 ? (nm[7] ? 3'b111 : 3'b110) : {1'b1, p - 2'd1};
            end
            4'd6, 4'd7:
            begin
                b = cdat[3'd7 - s[2:0]];
/* modes 6, 7: one bit, colour from the name's top bits */
                pix = b ? {1'b1, nm[7:6]} : 3'b000;
            end
            4'd8:
            begin
                p = nm[3'd7 - {s[3:2], 1'b0} -: 2];
/* mode 8: two bits, four colour clocks each */
                pix = p == 2'b00 ? 3'b000 : {1'b1, p - 2'd1};
            end
            4'd9:
            begin
                b = nm[3'd7 - s[3:1]];
/* mode 9: one bit, two colour clocks each */
                pix = b ? 3'b100 : 3'b000;
            end
            4'd10:
            begin
                p = nm[3'd7 - {s[2:1], 1'b0} -: 2];
/* mode A: two bits, two colour clocks each */
                pix = p == 2'b00 ? 3'b000 : {1'b1, p - 2'd1};
            end
            4'd11, 4'd12:
            begin
                b = nm[3'd7 - s[2:0]];
/* modes B, C: one bit per colour clock */
                pix = b ? 3'b100 : 3'b000;
            end
            4'd13, 4'd14:
            begin
                p = nm[3'd7 - {s[1:0], 1'b0} -: 2];
/* modes D, E: two bits per colour clock */
                pix = p == 2'b00 ? 3'b000 : {1'b1, p - 2'd1};
            end
/* F */
            default:
            begin
                p = s[1] ? (s[0] ? nm[1:0] : nm[3:2]) : (s[0] ? nm[5:4] : nm[7:6]);
                pix = {1'b1, p};
            end
        endcase
    end
endfunction

/* Sequencer */
always @(posedge clk or negedge rst_n)
    if (!rst_n)
    begin
        dmactl  <= 6'd0;
/* at reset: registers 0 */
        nmien   <= 2'b00;
        chactl  <= 3'd0;
        hscrol  <= 4'd0;
/* scroll and base registers */
        vscrol  <= 4'd0;
        pmbase  <= 6'd0;
        chbase  <= 7'd0;
/* the display list pointer, status bits */
        dlist   <= 16'd0;
        st_dli  <= 1'b0;
        st_vbi  <= 1'b0;
/* counters, the instruction register */
        hc      <= 7'd0;
        vc      <= 9'd0;
        ir      <= 8'd0;
/* rows */
        row     <= 4'd0;
        row_end <= 4'd0;
        ml_first <= 1'b0;
/* flags of the display list */
        jvb     <= 1'b0;
        vs_prev <= 1'b0;
        dl_got  <= 1'b0;
/* address bytes, the memory scan counter */
        adr_lo  <= 8'd0;
        msc     <= 16'd0;
        wsync   <= 1'b0;
/* WSYNC, refresh, NMI */
        wsync_nx <= 1'b0;
        rf_pend <= 1'b0;
        nmi_n   <= 1'b1;
/* character address and name */
        a_chr   <= 16'd0;
        name_q  <= 8'd0;
        lb_we   <= 1'b0;
/* line buffer ports */
        cd_we   <= 1'b0;
        lb_wa   <= 6'd0;
        cd_wa <= 6'd0;
/* their data */
        lb_wd <= 8'd0;
        cd_wd <= 8'd0;
        lb_ra   <= 6'd0;
/* the ANx output */
        an_stb  <= 1'b0;
        an_q    <= 3'b010;
        an_cc   <= 8'd0;
/* its line; the player/missile port */
        an_vc   <= 9'd0;
        an_hires <= 1'b0;
        pm_we   <= 1'b0;
/* its data; the pipeline */
        pm_sel  <= 3'd0;
        pm_d    <= 8'd0;
        q_cc    <= 8'd0;
/* blank */
        q_sub <= 4'd0;
        q_in <= 1'b0;
        q_blank <= 1'b1;
    end
    else
    begin
/* one-clock strobes */
        lb_we  <= 1'b0;
        cd_we  <= 1'b0;
        pm_we  <= 1'b0;
/* no pixel */
        an_stb <= 1'b0;

/* CPU register writes */
        if (reg_we)
        begin
            case (reg_a)
                4'h0: dmactl <= reg_d[5:0];
/* the registers by address */
                4'h1: chactl <= reg_d[2:0];
                4'h2: dlist[7:0]  <= reg_d;
                4'h3: dlist[15:8] <= reg_d;
/* scroll, player/missile base */
                4'h4: hscrol <= reg_d[3:0];
                4'h5: vscrol <= reg_d[3:0];
                4'h7: pmbase <= reg_d[7:2];
/* character base; WSYNC */
                4'h9: chbase <= reg_d[7:1];
                4'hA:
                begin
                    wsync <= 1'b1;
/* a write late in the line stops the next line; NMIEN */
                    wsync_nx <= hc > HC_WSYNC_LATE;
                end
                4'hE: nmien <= reg_d[7:6];
/* NMIRES */
                4'hF:
                begin
                    st_dli <= 1'b0;
                    st_vbi <= 1'b0;
                end
/* the others are read-only */
                default: ;
            endcase
        end

/* display pipeline: address at ticks 1 / 9, code at 3 / 11 */
        if (tick == 4'd1 || tick == TICK_ADDR2)
        begin
            lb_ra   <= d_idx;
            q_cc    <= cc_now;
/* the pipeline's stage */
            q_sub   <= d_sub;
            q_in    <= d_in;
            q_blank <= !vis || cc_now < CC_VIS_BEG || cc_now >= CC_VIS_END || hc == 7'd0;
        end
/* the code goes out */
        if (tick == TICK_CODE1 || tick == TICK_CODE2)
        begin
            an_stb   <= 1'b1;
            an_cc    <= q_cc;
/* line, hi-res flag, the code */
            an_vc    <= vc;
            an_hires <= hires && pf_on;
            an_q     <= q_blank ? {2'b01, hires && pf_on} : q_in ? pix(md, q_sub, lb_q, cd_q) : 3'b000;
        end
/* the name for the next cycle's character data fetch */
        if (tick == TICK_NAME_ADDR)
        begin
            lb_ra <= sidx(hc + 7'd1 - CHR_DATA_DELAY, st_chr, rate);
        end

/* NMI line: low from cycle 8 (one falling edge per NMI) to cycle 60 */
        if (cyc_end && hc == HC_NMI_END)
        begin
            nmi_n <= 1'b1;
        end

        if (cyc_end)
        begin
/* next cycle's character data address (name read at tick 13, data at tick 14) */
            a_chr  <= md >= MD_6 ? {chbase[7:1], lb_q[5:0], frow(md, row, chactl[2])}
                                 : {chbase[7:2], lb_q[6:0], frow(md, row, chactl[2])};
            name_q <= lb_q;

/* DMA data */
            if (s_mis)
            begin
                pm_we <= 1'b1;
                pm_sel <= PM_MISSILES;
/* missile data */
                pm_d <= dma_d;
            end
            if (s_ply)
            begin
                pm_we <= 1'b1;
/* the player's number and data */
                pm_sel <= {1'b0, pn};
                pm_d <= dma_d;
            end
            if (s_dl)
            begin
/* the instruction; the pointer moves on */
                ir     <= dma_d;
                dl_got <= 1'b1;
                dlist  <= {dlist[15:10], dlist[9:0] + 10'd1};
            end
/* the address's low byte */
            if (s_dla && hc == HC_DLA_LO)
            begin
                adr_lo <= dma_d;
                dlist  <= {dlist[15:10], dlist[9:0] + 10'd1};
            end
/* the high byte: a jump */
            if (s_dla && hc == HC_DLA_HI)
            begin
                if (md == 4'd1)
                begin
                    dlist <= {dma_d, adr_lo};
/* jump and wait for the vertical blank */
                    if (ir[6])
                    begin
                        jvb <= 1'b1;
                    end
                end
                else
                begin
                    msc   <= {dma_d, adr_lo};
/* the pointer moves on; a name or bitmap byte */
                    dlist <= {dlist[15:10], dlist[9:0] + 10'd1};
                end
            end
            if (s_name || s_map)
            begin
                lb_we <= 1'b1;
/* into the line buffer; the scan counter moves on */
                lb_wa <= s_name ? n_name : n_map;
                lb_wd <= virt ? 8'hFF : dma_d;
                msc   <= {msc[15:12], msc[11:0] + 12'd1};
            end
/* a character data byte */
            if (s_data)
            begin
                cd_we <= 1'b1;
                cd_wa <= n_data;
/* processed into the second buffer */
                cd_wd <= chproc(md, row, name_q, virt ? 8'hFF : dma_d, chactl);
            end

/* after the instruction byte (cycle 1): the mode line's rows */
            if (hc == 7'd1 && vis && ml_first)
            begin : newml
                reg [7:0] i;
                reg       vs_on;
/* the instruction of this line; vertical scroll on? */
                i = s_dl ? dma_d : ir;
                vs_on = i[5] && i[3:0] >= MD_2;
                row     <= vs_on && !vs_prev ? vscrol : 4'd0;
/* the first and last row; scroll state kept */
                row_end <= !vs_on && vs_prev ? vscrol : hmax(i);
                vs_prev <= vs_on;
            end

/* refresh deferral */
            if (rf_slot && busy)
            begin
                rf_pend <= 1'b1;
            end
            else if (rf_now && !rf_slot)
            begin
/* done */
                rf_pend <= 1'b0;
            end

/* NMIs: status at cycle 7, line at cycle 8 */
            if (hc == HC_NMI_STATUS)
            begin
                if (vc == VC_VBLANK)
                begin
                    st_vbi <= 1'b1;
/* the DLI flag */
                    st_dli <= 1'b0;
                end
                else if (vis && last && ir[7] && dl_any)
                begin
                    st_dli <= 1'b1;
/* the VBI flag */
                    st_vbi <= 1'b0;
                end
            end
            if (hc == HC_NMI_LINE)
            begin
                if ((vc == VC_VBLANK && nmien[0]) || (vis && last && ir[7] && dl_any && nmien[1]))
                begin
/* the NMI line */
                    nmi_n <= 1'b0;
                end
            end

/* WSYNC release at cycle 105 */
            if (hc == HC_WSYNC_END && wsync && !wsync_nx)
            begin
                wsync <= 1'b0;
            end

/* end of line */
            if (hc == HC_LAST)
            begin
                hc <= 7'd0;
                vc <= vc_n;
/* the line's flags */
                wsync_nx <= 1'b0;
                rf_pend  <= 1'b0;
                dl_got   <= 1'b0;
/* display list starts again */
                if (vc_n == VC_VIS_BEG)
                begin
                    ml_first <= 1'b1;
                    jvb      <= 1'b0;
/* no load-memory-scan left */
                    ir[6]    <= 1'b0;
                end
                else if (vc_n >= VC_VIS_SECOND && vc_n < VC_VBLANK)
                begin
                    ml_first <= last;
/* the next row */
                    if (!last)
                    begin
                        row <= row + 4'd1;
                    end
                end
                else
                begin
                    ml_first <= 1'b0;
                end
            end
            else
            begin
/* the next cycle */
                hc <= hc + 7'd1;
            end
        end
    end

/* a mode line was set up this frame (no DLIs from a stale IR before the first instruction) */
always @(posedge clk or negedge rst_n)
    if (!rst_n)
    begin
        dl_any <= 1'b0;
    end
/* cleared at the vertical blank */
    else if (cyc_end && hc == HC_LAST && vc_n == VC_VBLANK)
    begin
        dl_any <= 1'b0;
    end
    else if (cyc_end && hc == 7'd1 && vis && ml_first)
    begin
/* set by the first instruction */
        dl_any <= 1'b1;
    end

endmodule

`default_nettype wire
