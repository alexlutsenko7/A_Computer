//=============================================================================
// antic -- ANTIC (PAL): display list, playfield and P/M DMA, refresh, NMIs, WSYNC
//
// Written from the Altirra Hardware Reference Manual (ch. 4; LTari/NOTES.md).
//
// Timing: one machine cycle = 16 clk ticks; cyc_end is the last tick of a cycle,
// when the state moves on and DMA data (dma_d) is taken. hc = cycle in the line
// (0-113), vc = scan line (0-311). For the cycle in progress:
//   dma    ANTIC reads dma_a (the CPU is halted)
//   rfsh   refresh cycle (the bus is idle, the CPU is halted)
//   rdy    0 while a WSYNC wait is on (the CPU stops on read cycles)
// Per-line slots: cycle 0 missiles, 1 display list, 2-5 players, 6-7 LMS / jump
// address; refresh from cycle 25 every 4 (9 per line, one deferred when blocked);
// playfield fetches in the window of the mode / width / HSCROL (no DMA from cycle 106).
// Line buffer (names / bitmap bytes of a mode line) and character data buffer: block
// RAMs read once per colour clock for the display and once per cycle (tick 13) for
// the next character data address.
//
// Display: cce strobes (ticks 3 and 11) give colour clocks cc = 2 hc - 2 and 2 hc - 1;
// for each one an_q (ANx code, NOTES.md) and an_cc / an_vc go to GTIA one tick later
// (an_stb). Bytes fetched at cycle f are shown from colour clock 2 (f + 4) (bitmap)
// or 2 (f + 3) (character data, fetched 3 cycles after its name).
//=============================================================================
`default_nettype none

module antic (
    input  wire        clk,
    input  wire        rst_n,           // power-up / Reset button (XL/XE)
    input  wire [3:0]  tick,            // tick in the machine cycle (0-15)
    input  wire        cyc_end,         // tick == 15

    // registers (CPU): write strobe one clk, read data combinational
    input  wire        reg_we,
    input  wire [3:0]  reg_a,
    input  wire [7:0]  reg_d,
    output reg  [7:0]  reg_q,

    // bus
    output wire        dma,
    output wire        rfsh,
    output wire [15:0] dma_a,
    input  wire [7:0]  dma_d,           // valid at cyc_end
    output wire        rdy,
    output reg         nmi_n,

    // to GTIA
    output reg         an_stb,          // an_q / an_cc / an_vc valid (twice per cycle)
    output reg  [2:0]  an_q,
    output reg  [7:0]  an_cc,           // colour clock 0-227
    output reg  [8:0]  an_vc,           // scan line
    output reg         an_hires,        // the line is a hi-res mode line (2, 3, F)
    output reg         pm_we,           // P/M DMA byte for GTIA (at cyc_end)
    output reg  [2:0]  pm_sel,          // 0-3 player, 4 missiles
    output reg  [7:0]  pm_d
);

localparam [8:0] VLINES = 9'd312;

//-----------------------------------------------------------------------------
// Registers
//-----------------------------------------------------------------------------
reg  [5:0]  dmactl;
reg  [2:0]  chactl;
reg  [15:0] dlist;
reg  [3:0]  hscrol, vscrol;
reg  [7:2]  pmbase;
reg  [7:1]  chbase;
reg  [1:0]  nmien;                      // [1] DLI, [0] VBI
reg         st_dli, st_vbi;             // NMIST bits 7, 6

reg  [6:0]  hc;
reg  [8:0]  vc;
wire        vis   = vc >= 9'd8 && vc < 9'd248;
wire [8:0]  vc_n  = vc == VLINES - 1 ? 9'd0 : vc + 9'd1;
wire [8:0]  vc_rd = hc >= 7'd111 ? vc_n : vc;    // VCOUNT moves on at cycle 111

always @* begin
    case (reg_a)
        4'hB:    reg_q = vc_rd[8:1];                         // VCOUNT
        4'hC:    reg_q = 8'h00;                              // PENH (no light pen)
        4'hD:    reg_q = 8'hFF;                              // PENV
        4'hF:    reg_q = {st_dli, st_vbi, 1'b0, 5'b11111};  // NMIST
        default: reg_q = 8'hFF;
    endcase
end

//-----------------------------------------------------------------------------
// Mode line state
//-----------------------------------------------------------------------------
reg  [7:0]  ir;
reg  [3:0]  row, row_end;
reg         ml_first;                   // this line starts a mode line
reg         jvb;                        // jump and wait for vertical blank done
reg         vs_prev;                    // the previous mode line had vertical scrolling
reg         dl_got;                     // an instruction byte was fetched on this line
reg  [7:0]  adr_lo;
reg  [15:0] msc;                        // memory scan counter
reg         wsync, wsync_nx;
reg         dl_any;                     // a mode line was set up in this frame

wire [3:0]  md     = ir[3:0];
wire        pf_md  = md >= 4'd2 && !jvb && vis;       // a playfield mode line
wire        chr    = md >= 4'd2 && md <= 4'd7;
wire        hires  = md == 4'd2 || md == 4'd3 || md == 4'd15;
wire        last   = row == row_end;
wire [1:0]  dw     = dmactl[1:0];                     // display width
wire        hs_on  = ir[4] && pf_md;
wire [1:0]  fw     = dw == 2'd0 ? 2'd0 : (hs_on && dw != 2'd3) ? dw + 2'd1 : dw;    // fetch width
wire [2:0]  hs_cyc = hs_on ? hscrol[3:1] : 3'd0;

// mode height - 1
function [3:0] hmax(input [7:0] i);
    case (i[3:0])
        4'h0: hmax = {1'b0, i[6:4]};
        4'h1, 4'hC, 4'hE, 4'hF: hmax = 4'd0;
        4'h2, 4'h4, 4'h6, 4'h8: hmax = 4'd7;
        4'h3: hmax = 4'd9;
        4'h5, 4'h7: hmax = 4'd15;
        4'h9, 4'hA: hmax = 4'd3;
        default: hmax = 4'd1;                         // B, D
    endcase
endfunction

// fetch rate: 0 = every 2 cycles, 1 = 4, 2 = 8
wire [1:0]  rate   = (md >= 4'd2 && md <= 4'd5) || md >= 4'd13 ? 2'd0 :
                     (md == 4'd8 || md == 4'd9) ? 2'd2 : 2'd1;
wire [5:0]  count  = rate == 2'd0 ? (fw == 2'd1 ? 6'd32 : fw == 2'd2 ? 6'd40 : 6'd48) :
                     rate == 2'd1 ? (fw == 2'd1 ? 6'd16 : fw == 2'd2 ? 6'd20 : 6'd24) :
                                    (fw == 2'd1 ? 6'd8  : fw == 2'd2 ? 6'd10 : 6'd12);
wire [6:0]  st_chr = (fw == 2'd1 ? 7'd26 : fw == 2'd2 ? 7'd18 : 7'd10) + {4'd0, hs_cyc};
wire [6:0]  st_map = (fw == 2'd1 ? 7'd28 : fw == 2'd2 ? 7'd20 : 7'd12) + {4'd0, hs_cyc};

// is cycle c a fetch slot of a window starting at s? index in n
function slot(input [6:0] c, input [6:0] s, input [1:0] r, input [5:0] cnt);
    reg [6:0] k;
    begin
        k = c - s;
        slot = c >= s && (r == 2'd0 ? !k[0] : r == 2'd1 ? k[1:0] == 2'd0 : k[2:0] == 3'd0) &&
               (r == 2'd0 ? k[6:1] : r == 2'd1 ? {1'b0, k[6:2]} : {2'b00, k[6:3]}) < cnt;
    end
endfunction
function [5:0] sidx(input [6:0] c, input [6:0] s, input [1:0] r);
    reg [6:0] k;
    begin
        k = c - s;
        sidx = r == 2'd0 ? k[6:1] : r == 2'd1 ? {1'b0, k[6:2]} : {2'b00, k[6:3]};
    end
endfunction

wire        pf_on   = pf_md && fw != 2'd0;
wire        s_name  = pf_on && chr && ml_first && slot(hc, st_chr, rate, count);
wire        s_data  = pf_on && chr && slot(hc - 7'd3, st_chr, rate, count) && hc >= 7'd3;
wire        s_map   = pf_on && !chr && ml_first && slot(hc, st_map, rate, count);
wire [5:0]  n_name  = sidx(hc, st_chr, rate);
wire [5:0]  n_data  = sidx(hc - 7'd3, st_chr, rate);
wire [5:0]  n_map   = sidx(hc, st_map, rate);
wire        virt    = hc >= 7'd106;                   // no DMA, but the slot still counts
wire        pf_dma  = (s_name || s_data || s_map) && !virt;

// fixed slots
wire        pm_on   = vis && (dmactl[2] || dmactl[3]);
wire        s_mis   = hc == 7'd0 && pm_on;
wire        s_ply   = hc >= 7'd2 && hc <= 7'd5 && vis && dmactl[3];
wire        s_dl    = hc == 7'd1 && vis && ml_first && dmactl[5] && !jvb;
wire        lms     = ir[6] && md >= 4'd2;
wire        s_dla   = (hc == 7'd6 || hc == 7'd7) && vis && ml_first && dl_got && (md == 4'd1 || lms);

// refresh: slots 25, 29, ... 57; one blocked slot waits for the next free cycle
reg         rf_pend;
wire        rf_slot = hc >= 7'd25 && hc <= 7'd57 && hc[1:0] == 2'b01;
wire        busy    = pf_dma;
wire        rf_now  = !busy && (rf_slot || rf_pend);

assign dma   = s_mis || s_ply || s_dl || s_dla || pf_dma;
assign rfsh  = rf_now && !(s_mis || s_ply || s_dl || s_dla);

// P/M addresses
wire        pm1   = dmactl[4];          // one-line resolution
wire [15:0] a_mis = pm1 ? {pmbase[7:3], 3'b011, vc[7:0]} : {pmbase[7:2], 3'b011, vc[7:1]};   // +$300 / +$180
wire [1:0]  pn    = hc[1:0] - 2'd2;     // player 0-3 at cycles 2-5
wire [15:0] a_ply = pm1 ? {pmbase[7:3], 1'b1, pn, vc[7:0]} : {pmbase[7:2], 1'b1, pn, vc[7:1]};      // +$400 / +$200

// character data address (registered at tick 15 of the cycle before, from the name)
reg  [15:0] a_chr;
reg  [7:0]  name_q;                     // the name of that data fetch

assign dma_a = s_mis ? a_mis :
               s_ply ? a_ply :
               (s_dl || s_dla) ? dlist :
               s_data ? a_chr : msc;

//-----------------------------------------------------------------------------
// WSYNC: written up to cycle 103 -> released at cycle 105 of this line, else of the next
//-----------------------------------------------------------------------------
assign rdy = !wsync;

//-----------------------------------------------------------------------------
// Line buffer and character data buffer (block RAMs, one read port each)
//-----------------------------------------------------------------------------
reg  [7:0]  lb [0:63];
reg  [7:0]  cd [0:63];
reg  [5:0]  lb_ra;
reg  [7:0]  lb_q, cd_q;
reg         lb_we, cd_we;
reg  [5:0]  lb_wa, cd_wa;
reg  [7:0]  lb_wd, cd_wd;
always @(posedge clk) begin
    if (lb_we) lb[lb_wa] <= lb_wd;
    if (cd_we) cd[cd_wa] <= cd_wd;
    lb_q <= lb[lb_ra];
    cd_q <= cd[lb_ra];
end

// font row of the current scan line, and whether this row is blank (mode 3)
function [2:0] frow(input [3:0] m, input [3:0] r, input flip);
    reg [2:0] f;
    begin
        f = (m == 4'd5 || m == 4'd7) ? r[3:1] : r[2:0];
        frow = flip ? 3'd7 - f : f;
    end
endfunction

// character data byte as shown (modes 2/3: blank / invert by name bit 7; mode 3 rows)
function [7:0] chproc(input [3:0] m, input [3:0] r, input [7:0] nm, input [7:0] d, input [2:0] ca);
    reg [7:0] v;
    reg       blank_row;
    begin
        blank_row = m == 4'd3 && (nm[6:5] == 2'b11 ? r < 4'd2 : r >= 4'd8);
        v = blank_row ? 8'h00 : d;
        if (m == 4'd2 || m == 4'd3) begin
            if (nm[7] && ca[0]) v = 8'h00;
            if (nm[7] && ca[1]) v = ~v;
        end
        chproc = v;
    end
endfunction

//-----------------------------------------------------------------------------
// Display: colour clock pipeline (read address at ticks 1 / 9: the block RAM's data is there
// one clock later and stays until tick 13; ANx code at ticks 3 / 11)
//-----------------------------------------------------------------------------
wire        ph1    = tick >= 4'd8;
wire [7:0]  cc_now = {hc, ph1} - 8'd2;                // colour clock of this half
wire [7:0]  cc0    = (fw == 2'd1 ? 8'h40 : fw == 2'd2 ? 8'h30 : 8'h20) + (hs_on ? {4'd0, hscrol} : 8'd0);
wire [7:0]  wl     = dw == 2'd1 ? 8'h40 : dw == 2'd2 ? 8'h30 : 8'h2C;    // visible playfield
wire [7:0]  wr     = dw == 2'd1 ? 8'hC0 : dw == 2'd2 ? 8'hD0 : 8'hDE;
// colour clocks per byte: 4 (modes 2-5, D-F), 8 (6, 7, A-C), 16 (8, 9)
wire [1:0]  cpb    = (md >= 4'd2 && md <= 4'd5) || md >= 4'd13 ? 2'd0 :
                     (md == 4'd8 || md == 4'd9) ? 2'd2 : 2'd1;
wire [7:0]  off    = cc_now - cc0;
wire [5:0]  d_idx  = cpb == 2'd0 ? off[7:2] : cpb == 2'd1 ? {1'b0, off[7:3]} : {2'b00, off[7:4]};
wire [3:0]  d_sub  = cpb == 2'd0 ? {2'b00, off[1:0]} : cpb == 2'd1 ? {1'b0, off[2:0]} : off[3:0];
wire        d_in   = pf_on && cc_now >= wl && cc_now < wr && cc_now >= cc0 && d_idx < count;

reg  [7:0]  q_cc;
reg  [3:0]  q_sub;
reg         q_in, q_blank;

// ANx code of one colour clock from the byte (lb_q = name / bitmap, cd_q = char data)
function [2:0] pix(input [3:0] m, input [3:0] s, input [7:0] nm, input [7:0] cdat);
    reg [1:0] p;
    reg       b;
    begin
        case (m)
            4'd2, 4'd3: begin p = s[1] ? (s[0] ? cdat[1:0] : cdat[3:2]) : (s[0] ? cdat[5:4] : cdat[7:6]); pix = {1'b1, p}; end
            4'd4, 4'd5: begin
                p = s[1] ? (s[0] ? cdat[1:0] : cdat[3:2]) : (s[0] ? cdat[5:4] : cdat[7:6]);
                pix = p == 2'b00 ? 3'b000 : p == 2'b11 ? (nm[7] ? 3'b111 : 3'b110) : {1'b1, p - 2'd1};
            end
            4'd6, 4'd7: begin b = cdat[3'd7 - s[2:0]]; pix = b ? {1'b1, nm[7:6]} : 3'b000; end
            4'd8:       begin p = nm[3'd7 - {s[3:2], 1'b0} -: 2]; pix = p == 2'b00 ? 3'b000 : {1'b1, p - 2'd1}; end
            4'd9:       begin b = nm[3'd7 - s[3:1]]; pix = b ? 3'b100 : 3'b000; end
            4'd10:      begin p = nm[3'd7 - {s[2:1], 1'b0} -: 2]; pix = p == 2'b00 ? 3'b000 : {1'b1, p - 2'd1}; end
            4'd11, 4'd12: begin b = nm[3'd7 - s[2:0]]; pix = b ? 3'b100 : 3'b000; end
            4'd13, 4'd14: begin p = nm[3'd7 - {s[1:0], 1'b0} -: 2]; pix = p == 2'b00 ? 3'b000 : {1'b1, p - 2'd1}; end
            default:    begin p = s[1] ? (s[0] ? nm[1:0] : nm[3:2]) : (s[0] ? nm[5:4] : nm[7:6]); pix = {1'b1, p}; end   // F
        endcase
    end
endfunction

//-----------------------------------------------------------------------------
// Sequencer
//-----------------------------------------------------------------------------
always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
        dmactl  <= 6'd0;
        nmien   <= 2'b00;
        chactl  <= 3'd0;
        hscrol  <= 4'd0;
        vscrol  <= 4'd0;
        pmbase  <= 6'd0;
        chbase  <= 7'd0;
        dlist   <= 16'd0;
        st_dli  <= 1'b0;
        st_vbi  <= 1'b0;
        hc      <= 7'd0;
        vc      <= 9'd0;
        ir      <= 8'd0;
        row     <= 4'd0;
        row_end <= 4'd0;
        ml_first <= 1'b0;
        jvb     <= 1'b0;
        vs_prev <= 1'b0;
        dl_got  <= 1'b0;
        adr_lo  <= 8'd0;
        msc     <= 16'd0;
        wsync   <= 1'b0;
        wsync_nx <= 1'b0;
        rf_pend <= 1'b0;
        nmi_n   <= 1'b1;
        a_chr   <= 16'd0;
        name_q  <= 8'd0;
        lb_we   <= 1'b0;
        cd_we   <= 1'b0;
        lb_wa   <= 6'd0; cd_wa <= 6'd0; lb_wd <= 8'd0; cd_wd <= 8'd0;
        lb_ra   <= 6'd0;
        an_stb  <= 1'b0;
        an_q    <= 3'b010;
        an_cc   <= 8'd0;
        an_vc   <= 9'd0;
        an_hires <= 1'b0;
        pm_we   <= 1'b0;
        pm_sel  <= 3'd0;
        pm_d    <= 8'd0;
        q_cc    <= 8'd0; q_sub <= 4'd0; q_in <= 1'b0; q_blank <= 1'b1;
    end else begin
        lb_we  <= 1'b0;
        cd_we  <= 1'b0;
        pm_we  <= 1'b0;
        an_stb <= 1'b0;

        // CPU register writes
        if (reg_we)
            case (reg_a)
                4'h0: dmactl <= reg_d[5:0];
                4'h1: chactl <= reg_d[2:0];
                4'h2: dlist[7:0]  <= reg_d;
                4'h3: dlist[15:8] <= reg_d;
                4'h4: hscrol <= reg_d[3:0];
                4'h5: vscrol <= reg_d[3:0];
                4'h7: pmbase <= reg_d[7:2];
                4'h9: chbase <= reg_d[7:1];
                4'hA: begin wsync <= 1'b1; wsync_nx <= hc > 7'd103; end
                4'hE: nmien <= reg_d[7:6];
                4'hF: begin st_dli <= 1'b0; st_vbi <= 1'b0; end      // NMIRES
                default: ;
            endcase

        // display pipeline: address at ticks 1 / 9, code at 3 / 11
        if (tick == 4'd1 || tick == 4'd9) begin
            lb_ra   <= d_idx;
            q_cc    <= cc_now;
            q_sub   <= d_sub;
            q_in    <= d_in;
            q_blank <= !vis || cc_now < 8'h22 || cc_now >= 8'hDE || hc == 7'd0;
        end
        if (tick == 4'd3 || tick == 4'd11) begin
            an_stb   <= 1'b1;
            an_cc    <= q_cc;
            an_vc    <= vc;
            an_hires <= hires && pf_on;
            an_q     <= q_blank ? {2'b01, hires && pf_on} : q_in ? pix(md, q_sub, lb_q, cd_q) : 3'b000;
        end
        // the name for the next cycle's character data fetch
        if (tick == 4'd13)
            lb_ra <= sidx(hc + 7'd1 - 7'd3, st_chr, rate);

        // NMI line: low from cycle 8 (one falling edge per NMI) to cycle 60
        if (cyc_end && hc == 7'd60) nmi_n <= 1'b1;

        if (cyc_end) begin
            // next cycle's character data address (name read at tick 13, data at tick 14)
            a_chr  <= md >= 4'd6 ? {chbase[7:1], lb_q[5:0], frow(md, row, chactl[2])}
                                 : {chbase[7:2], lb_q[6:0], frow(md, row, chactl[2])};
            name_q <= lb_q;

            // DMA data
            if (s_mis) begin pm_we <= 1'b1; pm_sel <= 3'd4; pm_d <= dma_d; end
            if (s_ply) begin pm_we <= 1'b1; pm_sel <= {1'b0, pn}; pm_d <= dma_d; end
            if (s_dl) begin
                ir     <= dma_d;
                dl_got <= 1'b1;
                dlist  <= {dlist[15:10], dlist[9:0] + 10'd1};
            end
            if (s_dla && hc == 7'd6) begin
                adr_lo <= dma_d;
                dlist  <= {dlist[15:10], dlist[9:0] + 10'd1};
            end
            if (s_dla && hc == 7'd7) begin
                if (md == 4'd1) begin
                    dlist <= {dma_d, adr_lo};
                    if (ir[6]) jvb <= 1'b1;
                end else begin
                    msc   <= {dma_d, adr_lo};
                    dlist <= {dlist[15:10], dlist[9:0] + 10'd1};
                end
            end
            if (s_name || s_map) begin
                lb_we <= 1'b1;
                lb_wa <= s_name ? n_name : n_map;
                lb_wd <= virt ? 8'hFF : dma_d;
                msc   <= {msc[15:12], msc[11:0] + 12'd1};
            end
            if (s_data) begin
                cd_we <= 1'b1;
                cd_wa <= n_data;
                cd_wd <= chproc(md, row, name_q, virt ? 8'hFF : dma_d, chactl);
            end

            // after the instruction byte (cycle 1): the mode line's rows
            if (hc == 7'd1 && vis && ml_first) begin : newml
                reg [7:0] i;
                reg       vs_on;
                i = s_dl ? dma_d : ir;
                vs_on = i[5] && i[3:0] >= 4'd2;
                row     <= vs_on && !vs_prev ? vscrol : 4'd0;
                row_end <= !vs_on && vs_prev ? vscrol : hmax(i);
                vs_prev <= vs_on;
            end

            // refresh deferral
            if (rf_slot && busy)  rf_pend <= 1'b1;
            else if (rf_now && !rf_slot) rf_pend <= 1'b0;

            // NMIs: status at cycle 7, line at cycle 8
            if (hc == 7'd6) begin
                if (vc == 9'd248) begin st_vbi <= 1'b1; st_dli <= 1'b0; end
                else if (vis && last && ir[7] && dl_any) begin st_dli <= 1'b1; st_vbi <= 1'b0; end
            end
            if (hc == 7'd7) begin
                if ((vc == 9'd248 && nmien[0]) || (vis && last && ir[7] && dl_any && nmien[1]))
                    nmi_n <= 1'b0;
            end

            // WSYNC release at cycle 105
            if (hc == 7'd104 && wsync && !wsync_nx) wsync <= 1'b0;

            // end of line
            if (hc == 7'd113) begin
                hc <= 7'd0;
                vc <= vc_n;
                wsync_nx <= 1'b0;
                rf_pend  <= 1'b0;
                dl_got   <= 1'b0;
                if (vc_n == 9'd8) begin                       // display list starts again
                    ml_first <= 1'b1;
                    jvb      <= 1'b0;
                    ir[6]    <= 1'b0;
                end else if (vc_n >= 9'd9 && vc_n < 9'd248) begin
                    ml_first <= last;
                    if (!last) row <= row + 4'd1;
                end else
                    ml_first <= 1'b0;
            end else
                hc <= hc + 7'd1;
        end
    end

// a mode line was set up this frame (no DLIs from a stale IR before the first instruction)
always @(posedge clk or negedge rst_n)
    if (!rst_n)                                        dl_any <= 1'b0;
    else if (cyc_end && hc == 7'd113 && vc_n == 9'd248) dl_any <= 1'b0;
    else if (cyc_end && hc == 7'd1 && vis && ml_first) dl_any <= 1'b1;

endmodule

`default_nettype wire
