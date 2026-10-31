//=============================================================================
// gtia -- GTIA (PAL): playfield colours, players / missiles, priorities, collisions,
//         GTIA modes 9 / 10 / 11, triggers, console
//
// Written from the Altirra Hardware Reference Manual (ch. 6; LTari/NOTES.md).
//
// Per colour clock from ANTIC (an_stb, ANx code an_q, table 17): the colour clock is processed
// one colour clock later (pipeline stage d1), so that the GTIA modes can form their 4-bit
// pixels from two colour clocks: modes 9 / 11 group colour clocks 2k, 2k+1; mode 10 is one
// colour clock later (2k+1, 2k+2), as the manual describes.
// Players / missiles: a shift register per object, loaded (ORed) with GRAFPx / GRAFM bits when
// the colour clock equals HPOSx; it shifts when the size state machine (state' = (state + 1) AND
// size) returns to 0, so 1 / 2 / 4 colour clocks per bit; it runs all the time (also in blank).
// VDELAY: DMA data for that object only on odd scan lines. GRACTL 0 / 1: missile / player DMA
// data go to GRAFM / GRAFPx; 2: trigger latches.
// Priority: the manual's logic equations (PRIOR 3:0, bit 4 = missiles as a fifth player in PF3's
// colour and layer, bit 5 = P0+P1 / P2+P3 colours ORed); colours of all selected objects ORed.
// Hi-res lines (modes 2, 3, F): the priority logic sees PF2; PF1's luminance replaces the
// luminance where a pixel is 1, on top of everything.
// Collisions: within colour clocks $22-$DD of lines 8-247 (not in blank); hi-res pixel pairs
// count as PF2 when either pixel is 1; none against the playfield in modes 9 / 11; mode 10's
// PF0-PF3 codes do register. HITCLR clears them.
// Not modelled: the register write delays of table 18 (writes act at once), the size-change
// lockup of table 15, the pseudo mode E of mid-line PRIOR 7:6 changes.
//
// Output: for each colour clock two hi-res pixels, each an 8-bit colour {hue, luminance}, with
// its colour clock and line (px_stb), one colour clock after ANTIC sent it.
//=============================================================================
`default_nettype none

module gtia (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        reg_we,
    input  wire [4:0]  reg_a,
    input  wire [7:0]  reg_d,
    output reg  [7:0]  reg_q,

    input  wire        an_stb,
    input  wire [2:0]  an_q,
    input  wire [7:0]  an_cc,
    input  wire [8:0]  an_vc,
    input  wire        an_hires,
    input  wire        pm_we,
    input  wire [2:0]  pm_sel,
    input  wire [7:0]  pm_d,

    input  wire [3:0]  trig_n,          // 0 = pressed (TRIG3 = 0: no cartridge on XL/XE)
    input  wire [2:0]  consol_n,        // START, SELECT, OPTION (0 = pressed)
    output wire        speaker,         // CONSOL bit 3

    output reg         px_stb,
    output reg  [7:0]  px_cc,
    output reg  [8:0]  px_vc,
    output reg         px_blank,
    output reg  [7:0]  px0,             // left hi-res pixel of the colour clock
    output reg  [7:0]  px1
);

reg  [7:0] hposp [0:3];
reg  [7:0] hposm [0:3];
reg  [1:0] sizep [0:3];
reg  [7:0] sizem;
reg  [7:0] grafp [0:3];
reg  [7:0] grafm;
reg  [7:1] colpm [0:3];
reg  [7:1] colpf [0:3];
reg  [7:0] colbk;                       // bit 0: GTIA mode 9 / 11 can use it (the registers keep 7:1)
reg  [7:0] prior;
reg  [7:0] vdelay;
reg  [2:0] gractl;
reg  [3:0] consol_o;
reg  [3:0] trig_l;                      // latched triggers (GRACTL 2), 0 = was pressed
reg  [3:0] c_mpf [0:3];                 // collisions: missile x - playfield n
reg  [3:0] c_ppf [0:3];                 // player x - playfield n
reg  [3:0] c_mpl [0:3];                 // missile x - player n
reg  [3:0] c_ppl [0:3];                 // player x - player n

assign speaker = consol_o[3];

wire [3:0] trig_v = gractl[2] ? trig_l : trig_n;

always @* begin
    case (reg_a)
        5'h00, 5'h01, 5'h02, 5'h03: reg_q = {4'd0, c_mpf[reg_a[1:0]]};
        5'h04, 5'h05, 5'h06, 5'h07: reg_q = {4'd0, c_ppf[reg_a[1:0]]};
        5'h08, 5'h09, 5'h0A, 5'h0B: reg_q = {4'd0, c_mpl[reg_a[1:0]]};
        5'h0C, 5'h0D, 5'h0E, 5'h0F: reg_q = {4'd0, c_ppl[reg_a[1:0]]};
        5'h10, 5'h11, 5'h12, 5'h13: reg_q = {7'd0, trig_v[reg_a[1:0]]};
        5'h14:   reg_q = 8'h01;                              // PAL GTIA
        5'h1F:   reg_q = {5'd0, consol_n & ~consol_o[2:0]};  // an output 1 pulls the line low
        default: reg_q = 8'h0F;                              // $D015-$D01E read $0F (manual table 13; programs
                                                             // test it: Delirium Tremens' depacker branches on LSR $D017)
    endcase
end

//-----------------------------------------------------------------------------
// Pipeline: d1 = the colour clock being processed, d2 / d3 the ones before
//-----------------------------------------------------------------------------
reg  [2:0] d1_q, d2_q, d3_q;
reg  [7:0] d1_cc;
reg  [8:0] d1_vc;
reg        d1_hr;
reg        d1_ok;                       // d1 holds a colour clock
wire [1:0] pr_c  = d1_q[1:0];           // AN1:0 pairs (AN2 ignored in the GTIA modes)
wire [1:0] pr_n  = an_q[1:0];           // next colour clock (the one arriving now)
wire [1:0] pr_p  = d2_q[1:0];
wire [1:0] pr_pp = d3_q[1:0];
wire [1:0] gm    = prior[7:6];
wire       blank = d1_q[2:1] == 2'b01;  // horizontal blank (010 / 011), vertical sync 001 below
wire       vsync = d1_q == 3'b001;
wire       hr    = d1_hr && gm == 2'd0; // hi-res: off in the GTIA modes
wire [3:0] g4    = gm == 2'd2 ? (d1_cc[0] ? {pr_p, pr_c} : {pr_pp, pr_p})      // mode 10: one clock later
                              : (d1_cc[0] ? {pr_p, pr_c} : {pr_c, pr_n});
wire       vis   = !blank && !vsync && d1_cc >= 8'h22 && d1_cc < 8'hDE && d1_vc >= 9'd8 && d1_vc < 9'd248;

//-----------------------------------------------------------------------------
// Players / missiles: shift registers (bits out of the top), size state machines
//-----------------------------------------------------------------------------
reg  [7:0] psh [0:3];
reg  [1:0] pst [0:3];
reg  [1:0] msh [0:3];
reg  [1:0] mst [0:3];

reg  [3:0] p_on, m_on;                  // object pixels at d1
reg  [7:0] p_ld [0:3];
reg  [1:0] m_ld [0:3];
integer k;
always @* begin
    for (k = 0; k < 4; k = k + 1) begin
        p_ld[k] = d1_cc == hposp[k] ? psh[k] | grafp[k] : psh[k];
        m_ld[k] = d1_cc == hposm[k] ? msh[k] | grafm[2 * k +: 2] : msh[k];
        p_on[k] = p_ld[k][7];
        m_on[k] = m_ld[k][1];
    end
end

//-----------------------------------------------------------------------------
// Playfield signals of d1
//-----------------------------------------------------------------------------
reg  [3:0] pf;                          // PF0-PF3 for priority
reg  [3:0] pfc;                         // PF0-PF3 for collisions
reg        g10_p;                       // mode 10: a player colour code (acts as that player)
reg  [3:0] g10_pl;
always @* begin
    pf = 4'd0; pfc = 4'd0; g10_p = 1'b0; g10_pl = 4'd0;
    if (!blank && !vsync) begin
        if (gm == 2'd0) begin
            if (d1_hr) begin
                if (d1_q[2]) begin pf[2] = 1'b1; pfc[2] = d1_q[1:0] != 2'b00; end
            end else if (d1_q[2])
                pf[d1_q[1:0]] = 1'b1;
            if (!d1_hr) pfc = pf;
        end else if (gm == 2'd2) begin
            if (g4[3:2] == 2'b00) begin g10_p = 1'b1; g10_pl[g4[1:0]] = 1'b1; end
            else if (g4[2])            begin pf[g4[1:0]] = 1'b1; pfc[g4[1:0]] = 1'b1; end
        end
    end
end

//-----------------------------------------------------------------------------
// Priority (manual 6.7)
//-----------------------------------------------------------------------------
wire       fifth = prior[4];
wire       multi = prior[5];
wire [3:0] pp    = p_on | (fifth ? 4'd0 : m_on) | g10_pl;       // players (+ missiles), mode 10 codes
wire       p5    = fifth && |m_on;
wire       PF0 = pf[0], PF1 = pf[1], PF2 = pf[2], PF3 = pf[3] | p5;
wire       P0 = pp[0], P1 = pp[1], P2 = pp[2], P3 = pp[3];
wire       PRI0 = prior[0], PRI1 = prior[1], PRI2 = prior[2], PRI3 = prior[3];
wire       PRI01 = PRI0 | PRI1, PRI12 = PRI1 | PRI2, PRI23 = PRI2 | PRI3, PRI03 = PRI0 | PRI3;
wire       PF01 = PF0 | PF1, PF23 = PF2 | PF3, P01 = P0 | P1, P23 = P2 | P3;
wire       SP0 = P0 & !(PF01 & PRI23) & !(PRI2 & PF23);
wire       SP1 = P1 & !(PF01 & PRI23) & !(PRI2 & PF23) & (!P0 | multi);
wire       SP2 = P2 & !P01 & !(PF23 & PRI12) & !(PF01 & !PRI0);
wire       SP3 = P3 & !P01 & !(PF23 & PRI12) & !(PF01 & !PRI0) & (!P2 | multi);
wire       SF3 = PF3 & !(P23 & PRI03) & !(P01 & !PRI2);
wire       SF0 = PF0 & !(P23 & PRI0) & !(P01 & PRI01) & !SF3;
wire       SF1 = PF1 & !(P23 & PRI0) & !(P01 & PRI01) & !SF3;
wire       SF2 = PF2 & !(P23 & PRI03) & !(P01 & !PRI2) & !SF3;
wire       SB  = !P01 & !P23 & !PF01 & !PF23;

// colour of the colour clock (before the hi-res luminance)
reg  [7:0] col;
always @* begin
    col = 8'h00;
    if (SP0) col = col | {colpm[0], 1'b0};
    if (SP1) col = col | {colpm[1], 1'b0};
    if (SP2) col = col | {colpm[2], 1'b0};
    if (SP3) col = col | {colpm[3], 1'b0};
    if (SF0) col = col | {colpf[0], 1'b0};
    if (SF1) col = col | {colpf[1], 1'b0};
    if (SF2) col = col | {colpf[2], 1'b0};
    if (SF3) col = col | {colpf[3], 1'b0};
    if (SB) begin
        case (gm)
            2'd1:    col = {colbk[7:4], colbk[3:0] | g4};                            // 16 luminances
            2'd3:    col = {colbk[7:4] | g4, g4 == 4'd0 ? 4'd0 : colbk[3:0]};        // 16 hues
            2'd2:    col = g4[3:2] == 2'b10 ? colbk : col;                           // mode 10 background
            default: col = colbk;
        endcase
    end else if ((gm == 2'd1 || gm == 2'd3) && p5 && !(|p_on)) begin              // fifth player mixes
        col = gm == 2'd1 ? {colpf[3][7:4], colpf[3][3:1], 1'b0} | {4'd0, g4}
                         : {colpf[3][7:4] | g4, g4 == 4'd0 ? 4'd0 : {colpf[3][3:1], 1'b0}};
    end
end

wire [7:0] c_l = (hr && d1_q[2] && d1_q[1]) ? {col[7:4], colpf[1][3:1], 1'b0} : col;
wire [7:0] c_r = (hr && d1_q[2] && d1_q[0]) ? {col[7:4], colpf[1][3:1], 1'b0} : col;

//-----------------------------------------------------------------------------
// Registers, P/M shifting, collisions, output
//-----------------------------------------------------------------------------
always @(posedge clk or negedge rst_n)
    if (!rst_n) begin : rst
        integer i;
        for (i = 0; i < 4; i = i + 1) begin
            hposp[i] <= 8'd0; hposm[i] <= 8'd0; sizep[i] <= 2'd0; grafp[i] <= 8'd0;
            colpm[i] <= 7'd0; colpf[i] <= 7'd0;
            psh[i] <= 8'd0; pst[i] <= 2'd0; msh[i] <= 2'd0; mst[i] <= 2'd0;
            c_mpf[i] <= 4'd0; c_ppf[i] <= 4'd0; c_mpl[i] <= 4'd0; c_ppl[i] <= 4'd0;
        end
        sizem    <= 8'd0;
        grafm    <= 8'd0;
        colbk    <= 8'd0;
        prior    <= 8'd0;
        vdelay   <= 8'd0;
        gractl   <= 3'd0;
        consol_o <= 4'd0;
        trig_l   <= 4'hF;
        d1_q <= 3'b010; d2_q <= 3'b010; d3_q <= 3'b010;
        d1_cc <= 8'd0; d1_vc <= 9'd0; d1_hr <= 1'b0; d1_ok <= 1'b0;
        px_stb <= 1'b0; px_cc <= 8'd0; px_vc <= 9'd0; px_blank <= 1'b1; px0 <= 8'd0; px1 <= 8'd0;
    end else begin : run
        integer i;
        px_stb <= 1'b0;
        if (reg_we)
            case (reg_a)
                5'h00, 5'h01, 5'h02, 5'h03: hposp[reg_a[1:0]] <= reg_d;
                5'h04, 5'h05, 5'h06, 5'h07: hposm[reg_a[1:0]] <= reg_d;
                5'h08, 5'h09, 5'h0A, 5'h0B: sizep[reg_a[1:0]] <= reg_d[1:0];
                5'h0C: sizem <= reg_d;
                5'h0D, 5'h0E, 5'h0F, 5'h10: grafp[reg_a[1:0] - 2'd1] <= reg_d;
                5'h11: grafm <= reg_d;
                5'h12, 5'h13, 5'h14, 5'h15: colpm[reg_a[1:0] - 2'd2] <= reg_d[7:1];
                5'h16, 5'h17, 5'h18, 5'h19: colpf[reg_a[1:0] - 2'd2] <= reg_d[7:1];
                5'h1A: colbk  <= {reg_d[7:1], 1'b0};
                5'h1B: prior  <= reg_d;
                5'h1C: vdelay <= reg_d;
                5'h1D: begin gractl <= reg_d[2:0]; if (!reg_d[2]) trig_l <= 4'hF; end
                5'h1E: for (i = 0; i < 4; i = i + 1) begin
                           c_mpf[i] <= 4'd0; c_ppf[i] <= 4'd0; c_mpl[i] <= 4'd0; c_ppl[i] <= 4'd0;
                       end
                5'h1F: consol_o <= reg_d[3:0];
                default: ;
            endcase
        if (gractl[2]) trig_l <= trig_l & trig_n;

        // P/M DMA data (GRACTL), VDELAY: only on odd lines
        if (pm_we) begin
            if (pm_sel == 3'd4 && gractl[0]) begin
                for (i = 0; i < 4; i = i + 1)
                    if (!(vdelay[i] && !an_vc[0])) grafm[2 * i +: 2] <= pm_d[2 * i +: 2];
            end
            if (pm_sel != 3'd4 && gractl[1] && !(vdelay[4 + pm_sel[1:0]] && !an_vc[0]))
                grafp[pm_sel[1:0]] <= pm_d;
        end

        if (an_stb) begin
            // the next colour clock comes in; d1 (the one before) is processed now
            d1_q  <= an_q;  d2_q <= d1_q;  d3_q <= d2_q;
            d1_cc <= an_cc; d1_vc <= an_vc; d1_hr <= an_hires; d1_ok <= 1'b1;

            if (d1_ok) begin
                // shift registers: the loaded value, then the size state machine
                for (i = 0; i < 4; i = i + 1) begin : sh
                    reg [1:0] s;
                    s = (d1_cc == hposp[i] ? 2'd0 : pst[i]) + 2'd1 & sizep[i];
                    pst[i] <= s;
                    psh[i] <= s == 2'd0 ? {p_ld[i][6:0], 1'b0} : p_ld[i];
                    s = (d1_cc == hposm[i] ? 2'd0 : mst[i]) + 2'd1 & sizem[2 * i +: 2];
                    mst[i] <= s;
                    msh[i] <= s == 2'd0 ? {m_ld[i][0], 1'b0} : m_ld[i];
                end

                // collisions (playfield before priority; players include no missiles here)
                if (vis)
                    for (i = 0; i < 4; i = i + 1) begin
                        if (m_on[i]) begin
                            c_mpf[i] <= c_mpf[i] | pfc;
                            c_mpl[i] <= c_mpl[i] | p_on;
                        end
                        if (p_on[i]) begin
                            c_ppf[i] <= c_ppf[i] | pfc;
                            c_ppl[i] <= c_ppl[i] | (p_on & ~(4'd1 << i));
                        end
                    end

                px_stb   <= 1'b1;
                px_cc    <= d1_cc;
                px_vc    <= d1_vc;
                px_blank <= blank || vsync;
                px0      <= (blank || vsync) ? 8'h00 : c_l;
                px1      <= (blank || vsync) ? 8'h00 : c_r;
            end
        end
    end

endmodule

`default_nettype wire
