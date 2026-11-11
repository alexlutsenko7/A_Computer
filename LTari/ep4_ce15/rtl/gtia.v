/* gtia -- GTIA (PAL): playfield colours, players / missiles, priorities, collisions, */
/* GTIA modes 9 / 10 / 11, triggers, console */
/* */
/* Written from the Altirra Hardware Reference Manual (ch. 6; LTari/ep4_ce15/NOTES.md). */
/* */
/* Per colour clock from ANTIC (an_stb, ANx code an_q, table 17): the colour clock is processed */
/* one colour clock later (pipeline stage d1), so that the GTIA modes can form their 4-bit */
/* pixels from two colour clocks: modes 9 / 11 group colour clocks 2k, 2k+1; mode 10 is one */
/* colour clock later (2k+1, 2k+2), as the manual describes. */
/* Players / missiles: a shift register per object, loaded (ORed) with GRAFPx / GRAFM bits when */
/* the colour clock equals HPOSx; it shifts when the size state machine (state' = (state + 1) AND */
/* size) returns to 0, so 1 / 2 / 4 colour clocks per bit; it runs all the time (also in blank). */
/* VDELAY: DMA data for that object only on odd scan lines. GRACTL 0 / 1: missile / player DMA */
/* data go to GRAFM / GRAFPx; 2: trigger latches. */
/* Priority: the manual's logic equations (PRIOR 3:0, bit 4 = missiles as a fifth player in PF3's */
/* colour and layer, bit 5 = P0+P1 / P2+P3 colours ORed); colours of all selected objects ORed. */
/* Hi-res lines (modes 2, 3, F): the priority logic sees PF2; PF1's luminance replaces the */
/* luminance where a pixel is 1, on top of everything. */
/* Collisions: within colour clocks $22-$DD of lines 8-247 (not in blank); hi-res pixel pairs */
/* count as PF2 when either pixel is 1; none against the playfield in modes 9 / 11; mode 10's */
/* PF0-PF3 codes do register. HITCLR clears them. */
/* Not modelled: the register write delays of table 18 (writes act at once), the size-change */
/* lockup of table 15, the pseudo mode E of mid-line PRIOR 7:6 changes. */
/* */
/* Output: for each colour clock two hi-res pixels, each an 8-bit colour {hue, luminance}, with */
/* its colour clock and line (px_stb), one colour clock after ANTIC sent it. */
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

/* 0 = pressed (TRIG3 = 0: no cartridge on XL/XE) */
    input  wire [3:0]  trig_n,
/* START, SELECT, OPTION (0 = pressed) */
    input  wire [2:0]  consol_n,
/* CONSOL bit 3 */
    output wire        speaker,

    output reg         px_stb,
    output reg  [7:0]  px_cc,
    output reg  [8:0]  px_vc,
    output reg         px_blank,
/* left hi-res pixel of the colour clock */
    output reg  [7:0]  px0,
    output reg  [7:0]  px1
);

/* GTIA mode 10 (PRIOR bits 7:6 = 10) */
localparam [1:0] GM_10 = 2'd2;
/* first visible colour clock */
localparam [7:0] CC_VIS_BEG = 8'h22;
/* first colour clock after the visible part */
localparam [7:0] CC_VIS_END = 8'hDE;
/* first visible line */
localparam [8:0] VC_VIS_BEG = 9'd8;
/* first line after the visible part */
localparam [8:0] VC_VIS_END = 9'd248;
/* players (and missiles, and playfields) */
localparam integer OBJECTS = 4;
/* player/missile DMA slot of the missiles */
localparam [2:0] PM_MISSILES = 3'd4;

reg  [7:0] hposp [0:3];
reg  [7:0] hposm [0:3];
/* the players' sizes */
reg  [1:0] sizep [0:3];
/* missile sizes, player and missile graphics */
reg  [7:0] sizem;
reg  [7:0] grafp [0:3];
reg  [7:0] grafm;
/* colours of players and playfields */
reg  [7:1] colpm [0:3];
reg  [7:1] colpf [0:3];
/* bit 0: GTIA mode 9 / 11 can use it (the registers keep 7:1) */
reg  [7:0] colbk;
reg  [7:0] prior;
reg  [7:0] vdelay;
/* graphics control, console outputs */
reg  [2:0] gractl;
reg  [3:0] consol_o;
/* latched triggers (GRACTL 2), 0 = was pressed */
reg  [3:0] trig_l;
/* collisions: missile x - playfield n */
reg  [3:0] c_mpf [0:3];
/* player x - playfield n */
reg  [3:0] c_ppf [0:3];
/* missile x - player n */
reg  [3:0] c_mpl [0:3];
/* player x - player n */
reg  [3:0] c_ppl [0:3];

assign speaker = consol_o[3];

wire [3:0] trig_v = gractl[2] ? trig_l : trig_n;

/* the register read */
always @*
begin
    case (reg_a)
        5'h00, 5'h01, 5'h02, 5'h03: reg_q = {4'd0, c_mpf[reg_a[1:0]]};
/* collisions: player to playfield, missile to player */
        5'h04, 5'h05, 5'h06, 5'h07: reg_q = {4'd0, c_ppf[reg_a[1:0]]};
        5'h08, 5'h09, 5'h0A, 5'h0B: reg_q = {4'd0, c_mpl[reg_a[1:0]]};
        5'h0C, 5'h0D, 5'h0E, 5'h0F: reg_q = {4'd0, c_ppl[reg_a[1:0]]};
/* player to player; the triggers */
        5'h10, 5'h11, 5'h12, 5'h13: reg_q = {7'd0, trig_v[reg_a[1:0]]};
/* PAL GTIA */
        5'h14: reg_q = 8'h01;
/* an output 1 pulls the line low */
        5'h1F: reg_q = {5'd0, consol_n & ~consol_o[2:0]};
/* $D015-$D01E read $0F (manual table 13; programs */
        default: reg_q = 8'h0F;
/* test it: Delirium Tremens' depacker branches on LSR $D017) */
    endcase
end

/* Pipeline: d1 = the colour clock being processed, d2 / d3 the ones before */
reg  [2:0] d1_q, d2_q, d3_q;
reg  [7:0] d1_cc;
reg  [8:0] d1_vc;
/* its hi-res flag */
reg        d1_hr;
/* d1 holds a colour clock */
reg        d1_ok;
/* AN1:0 pairs (AN2 ignored in the GTIA modes) */
wire [1:0] pr_c  = d1_q[1:0];
/* next colour clock (the one arriving now) */
wire [1:0] pr_n  = an_q[1:0];
wire [1:0] pr_p  = d2_q[1:0];
wire [1:0] pr_pp = d3_q[1:0];
/* the GTIA mode */
wire [1:0] gm    = prior[7:6];
/* horizontal blank (010 / 011), vertical sync 001 below */
wire       blank = d1_q[2:1] == 2'b01;
wire       vsync = d1_q == 3'b001;
/* hi-res: off in the GTIA modes */
wire       hr    = d1_hr && gm == 2'd0;
/* mode 10: one clock later */
wire [3:0] g4    = gm == GM_10 ? (d1_cc[0] ? {pr_p, pr_c} : {pr_pp, pr_p})
                              : (d1_cc[0] ? {pr_p, pr_c} : {pr_c, pr_n});
wire       vis   = !blank && !vsync && d1_cc >= CC_VIS_BEG && d1_cc < CC_VIS_END && d1_vc >= VC_VIS_BEG && d1_vc < VC_VIS_END;

/* Players / missiles: shift registers (bits out of the top), size state machines */
reg  [7:0] psh [0:3];
reg  [1:0] pst [0:3];
reg  [1:0] msh [0:3];
/* the size state of the missiles */
reg  [1:0] mst [0:3];

/* object pixels at d1 */
reg  [3:0] p_on, m_on;
reg  [7:0] p_ld [0:3];
reg  [1:0] m_ld [0:3];
/* loop index; the objects at this colour clock */
integer k;
always @*
begin
    for (k = 0; k < OBJECTS; k = k + 1)
    begin
/* a shift register is loaded at the object's position */
        p_ld[k] = d1_cc == hposp[k] ? psh[k] | grafp[k] : psh[k];
        m_ld[k] = d1_cc == hposm[k] ? msh[k] | grafm[2 * k +: 2] : msh[k];
        p_on[k] = p_ld[k][7];
/* its top bit is the pixel */
        m_on[k] = m_ld[k][1];
    end
end

/* Playfield signals of d1 */
/* PF0-PF3 for priority */
reg  [3:0] pf;
/* PF0-PF3 for collisions */
reg  [3:0] pfc;
/* mode 10: a player colour code (acts as that player) */
reg        g10_p;
reg  [3:0] g10_pl;
always @*
begin
/* nothing by default */
    pf = 4'd0;
    pfc = 4'd0;
    g10_p = 1'b0;
/* no mode-10 player colours */
    g10_pl = 4'd0;
    if (!blank && !vsync)
    begin
        if (gm == 2'd0)
        begin
/* normal mode, hi-res: PF2 with PF1's luminance */
            if (d1_hr)
            begin
                if (d1_q[2])
                begin
                    pf[2] = 1'b1;
/* collisions see PF2 where a pixel is lit */
                    pfc[2] = d1_q[1:0] != 2'b00;
                end
            end
            else if (d1_q[2])
            begin
                pf[d1_q[1:0]] = 1'b1;
            end
/* otherwise the collisions see the playfield itself */
            if (!d1_hr)
            begin
                pfc = pf;
            end
        end
        else if (gm == GM_10)
        begin
/* mode 10: values 0-3 are the player colours */
            if (g4[3:2] == 2'b00)
            begin
                g10_p = 1'b1;
                g10_pl[g4[1:0]] = 1'b1;
            end
/* values 4-7: the playfields */
            else if (g4[2])
            begin
                pf[g4[1:0]] = 1'b1;
                pfc[g4[1:0]] = 1'b1;
            end
        end
    end
end

/* Priority (manual 6.7) */
wire       fifth = prior[4];
wire       multi = prior[5];
/* players (+ missiles), mode 10 codes */
wire [3:0] pp    = p_on | (fifth ? 4'd0 : m_on) | g10_pl;
wire       p5    = fifth && |m_on;
wire       PF0 = pf[0], PF1 = pf[1], PF2 = pf[2], PF3 = pf[3] | p5;
/* the players and the priority bits as in the manual's equations */
wire       P0 = pp[0], P1 = pp[1], P2 = pp[2], P3 = pp[3];
wire       PRI0 = prior[0], PRI1 = prior[1], PRI2 = prior[2], PRI3 = prior[3];
wire       PRI01 = PRI0 | PRI1, PRI12 = PRI1 | PRI2, PRI23 = PRI2 | PRI3, PRI03 = PRI0 | PRI3;
/* groups; a player is shown unless a playfield has priority */
wire       PF01 = PF0 | PF1, PF23 = PF2 | PF3, P01 = P0 | P1, P23 = P2 | P3;
wire       SP0 = P0 & !(PF01 & PRI23) & !(PRI2 & PF23);
wire       SP1 = P1 & !(PF01 & PRI23) & !(PRI2 & PF23) & (!P0 | multi);
/* players 2 and 3 */
wire       SP2 = P2 & !P01 & !(PF23 & PRI12) & !(PF01 & !PRI0);
wire       SP3 = P3 & !P01 & !(PF23 & PRI12) & !(PF01 & !PRI0) & (!P2 | multi);
wire       SF3 = PF3 & !(P23 & PRI03) & !(P01 & !PRI2);
/* the playfields */
wire       SF0 = PF0 & !(P23 & PRI0) & !(P01 & PRI01) & !SF3;
wire       SF1 = PF1 & !(P23 & PRI0) & !(P01 & PRI01) & !SF3;
wire       SF2 = PF2 & !(P23 & PRI03) & !(P01 & !PRI2) & !SF3;
/* the background */
wire       SB  = !P01 & !P23 & !PF01 & !PF23;

/* colour of the colour clock (before the hi-res luminance) */
reg  [7:0] col;
always @*
begin
    col = 8'h00;
/* every object shown adds its colour (OR, as the chip) */
    if (SP0)
    begin
        col = col | {colpm[0], 1'b0};
    end
    if (SP1)
    begin
/* player 2 */
        col = col | {colpm[1], 1'b0};
    end
    if (SP2)
    begin
        col = col | {colpm[2], 1'b0};
    end
/* player 3 */
    if (SP3)
    begin
        col = col | {colpm[3], 1'b0};
    end
    if (SF0)
    begin
/* playfield 1 */
        col = col | {colpf[0], 1'b0};
    end
    if (SF1)
    begin
        col = col | {colpf[1], 1'b0};
    end
/* playfield 2 */
    if (SF2)
    begin
        col = col | {colpf[2], 1'b0};
    end
    if (SF3)
    begin
/* the background, by GTIA mode */
        col = col | {colpf[3], 1'b0};
    end
    if (SB)
    begin
        case (gm)
/* 16 luminances */
            2'd1: col = {colbk[7:4], colbk[3:0] | g4};
/* 16 hues */
            2'd3: col = {colbk[7:4] | g4, g4 == 4'd0 ? 4'd0 : colbk[3:0]};
/* mode 10 background */
            GM_10: col = g4[3:2] == 2'b10 ? colbk : col;
            default: col = colbk;
        endcase
/* fifth player mixes */
    end
    else if ((gm == 2'd1 || gm == 2'd3) && p5 && !(|p_on))
    begin
        col = gm == 2'd1 ? {colpf[3][7:4], colpf[3][3:1], 1'b0} | {4'd0, g4}
                         : {colpf[3][7:4] | g4, g4 == 4'd0 ? 4'd0 : {colpf[3][3:1], 1'b0}};
    end
end

wire [7:0] c_l = (hr && d1_q[2] && d1_q[1]) ? {col[7:4], colpf[1][3:1], 1'b0} : col;
/* the right half of a hi-res colour clock */
wire [7:0] c_r = (hr && d1_q[2] && d1_q[0]) ? {col[7:4], colpf[1][3:1], 1'b0} : col;

/* Registers, P/M shifting, collisions, output */
always @(posedge clk or negedge rst_n)
    if (!rst_n)
    begin : rst
        integer i;
/* at reset: every register 0 */
        for (i = 0; i < OBJECTS; i = i + 1)
        begin
            hposp[i] <= 8'd0;
            hposm[i] <= 8'd0;
/* sizes, graphics, colours */
            sizep[i] <= 2'd0;
            grafp[i] <= 8'd0;
            colpm[i] <= 7'd0;
/* shift registers and their states */
            colpf[i] <= 7'd0;
            psh[i] <= 8'd0;
            pst[i] <= 2'd0;
/* missiles; collisions */
            msh[i] <= 2'd0;
            mst[i] <= 2'd0;
            c_mpf[i] <= 4'd0;
/* the others */
            c_ppf[i] <= 4'd0;
            c_mpl[i] <= 4'd0;
            c_ppl[i] <= 4'd0;
        end
/* the single registers */
        sizem    <= 8'd0;
        grafm    <= 8'd0;
        colbk    <= 8'd0;
/* priority, delay, control */
        prior    <= 8'd0;
        vdelay   <= 8'd0;
        gractl   <= 3'd0;
/* console, triggers; the pipeline blank */
        consol_o <= 4'd0;
        trig_l   <= 4'hF;
        d1_q <= 3'b010;
/* its later stages */
        d2_q <= 3'b010;
        d3_q <= 3'b010;
        d1_cc <= 8'd0;
/* line, flags */
        d1_vc <= 9'd0;
        d1_hr <= 1'b0;
        d1_ok <= 1'b0;
/* no pixel out */
        px_stb <= 1'b0;
        px_cc <= 8'd0;
        px_vc <= 9'd0;
/* blank */
        px_blank <= 1'b1;
        px0 <= 8'd0;
        px1 <= 8'd0;
    end
    else
    begin : run
/* loop index; the strobe lasts one clock */
        integer i;
        px_stb <= 1'b0;
        if (reg_we)
        begin
/* positions */
            case (reg_a)
                5'h00, 5'h01, 5'h02, 5'h03: hposp[reg_a[1:0]] <= reg_d;
                5'h04, 5'h05, 5'h06, 5'h07: hposm[reg_a[1:0]] <= reg_d;
/* sizes, graphics */
                5'h08, 5'h09, 5'h0A, 5'h0B: sizep[reg_a[1:0]] <= reg_d[1:0];
                5'h0C: sizem <= reg_d;
                5'h0D, 5'h0E, 5'h0F, 5'h10: grafp[reg_a[1:0] - 2'd1] <= reg_d;
/* missile graphics, colours */
                5'h11: grafm <= reg_d;
                5'h12, 5'h13, 5'h14, 5'h15: colpm[reg_a[1:0] - 2'd2] <= reg_d[7:1];
                5'h16, 5'h17, 5'h18, 5'h19: colpf[reg_a[1:0] - 2'd2] <= reg_d[7:1];
/* background, priority, vertical delay */
                5'h1A: colbk  <= {reg_d[7:1], 1'b0};
                5'h1B: prior  <= reg_d;
                5'h1C: vdelay <= reg_d;
/* graphics control: triggers latched or free */
                5'h1D:
                begin
                    gractl <= reg_d[2:0];
                    if (!reg_d[2])
                    begin
/* free again */
                        trig_l <= 4'hF;
                    end
                end
                5'h1E:
                    for (i = 0; i < OBJECTS; i = i + 1)
                    begin
/* HITCLR: all collisions cleared */
                        c_mpf[i] <= 4'd0;
                        c_ppf[i] <= 4'd0;
                        c_mpl[i] <= 4'd0;
/* the console outputs */
                        c_ppl[i] <= 4'd0;
                    end
                5'h1F: consol_o <= reg_d[3:0];
                default: ;
            endcase
        end
/* latched triggers stay pressed */
        if (gractl[2])
        begin
            trig_l <= trig_l & trig_n;
        end

/* P/M DMA data (GRACTL), VDELAY: only on odd lines */
        if (pm_we)
        begin
            if (pm_sel == PM_MISSILES && gractl[0])
            begin
                for (i = 0; i < OBJECTS; i = i + 1)
                begin
/* missile data, two bits each */
                    if (!(vdelay[i] && !an_vc[0]))
                    begin
                        grafm[2 * i +: 2] <= pm_d[2 * i +: 2];
                    end
                end
            end
            if (pm_sel != PM_MISSILES && gractl[1] && !(vdelay[4 + pm_sel[1:0]] && !an_vc[0]))
            begin
/* player data */
                grafp[pm_sel[1:0]] <= pm_d;
            end
        end

        if (an_stb)
        begin
/* the next colour clock comes in; d1 (the one before) is processed now */
            d1_q  <= an_q;
            d2_q <= d1_q;
            d3_q <= d2_q;
/* the colour clock, line and hi-res flag */
            d1_cc <= an_cc;
            d1_vc <= an_vc;
            d1_hr <= an_hires;
/* d1 is valid from now on */
            d1_ok <= 1'b1;

            if (d1_ok)
            begin
/* shift registers: the loaded value, then the size state machine */
                for (i = 0; i < OBJECTS; i = i + 1)
                begin : sh
                    reg [1:0] s;
                    s = (d1_cc == hposp[i] ? 2'd0 : pst[i]) + 2'd1 & sizep[i];
/* the size state; the register shifts in state 0 */
                    pst[i] <= s;
                    psh[i] <= s == 2'd0 ? {p_ld[i][6:0], 1'b0} : p_ld[i];
                    s = (d1_cc == hposm[i] ? 2'd0 : mst[i]) + 2'd1 & sizem[2 * i +: 2];
/* the same for the missile */
                    mst[i] <= s;
                    msh[i] <= s == 2'd0 ? {m_ld[i][0], 1'b0} : m_ld[i];
                end

/* collisions (playfield before priority; players include no missiles here) */
                if (vis)
                begin
                    for (i = 0; i < OBJECTS; i = i + 1)
                    begin
                        if (m_on[i])
                        begin
/* a missile's pixel: its collisions */
                            c_mpf[i] <= c_mpf[i] | pfc;
                            c_mpl[i] <= c_mpl[i] | p_on;
                        end
                        if (p_on[i])
                        begin
/* a player's pixel: playfields and the other players */
                            c_ppf[i] <= c_ppf[i] | pfc;
                            c_ppl[i] <= c_ppl[i] | (p_on & ~(4'd1 << i));
                        end
                    end
                end

                px_stb   <= 1'b1;
/* the pixel's place */
                px_cc    <= d1_cc;
                px_vc    <= d1_vc;
                px_blank <= blank || vsync;
/* the two half pixels */
                px0      <= (blank || vsync) ? 8'h00 : c_l;
                px1      <= (blank || vsync) ? 8'h00 : c_r;
            end
        end
    end

endmodule

`default_nettype wire
