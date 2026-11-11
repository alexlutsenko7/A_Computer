/* tb_gtia -- GTIA unit test: playfield colours, players / missiles (position, size, VDELAY not), */
/* priorities (PRIOR 1 / 4 / 8 / 0 mixing), hi-res luminance, collisions, fifth player, GTIA modes */
/* 9 / 11. A model of ANTIC's ANx stream: one colour clock per 8 clk, lines of 228 colour clocks. */
`timescale 1ns/1ps

module tb_gtia;

/* half a period of the 28.4 MHz machine clock, ns */
localparam real CLK_HALF = 17.6;
/* the line the test runs in */
localparam [8:0] TEST_LINE = 9'd100;
/* colour clocks of a line */
localparam integer LINE_CC = 228;
/* first visible colour clock */
localparam [7:0] CC_VIS_BEG = 8'h22;
/* first colour clock of the test playfield */
localparam [7:0] PF_BEG = 8'h50;
/* first colour clock after the test playfield */
localparam [7:0] PF_END = 8'h58;
/* clocks GTIA needs for a colour clock */
localparam integer GTIA_TICKS = 6;
/* clocks of the rest of a machine cycle */
localparam integer CYCLE_REST = 20;
/* the reset ends after 100 ns */
localparam integer RST_NS = 100;
/* register 04 read: player 0 to playfield collisions */
localparam [4:0] REG_P0PF = 5'h04;
/* register 0C read: player 0 to player collisions */
localparam [4:0] REG_P0PL = 5'h0C;
/* register 0D read: player 1 to player collisions */
localparam [4:0] REG_P1PL = 5'h0D;
reg clk = 0;
/* the machine clock; the register port */
always #CLK_HALF clk = ~clk;
reg rst_n = 0;

reg        we = 0;
/* address, data in and out */
reg  [4:0] ra = 0;
reg  [7:0] rd = 0;
wire [7:0] rq;
/* the ANx input */
reg        an_stb = 0, hires = 0;
reg  [2:0] an_q = 3'b000;
reg  [7:0] an_cc = 0;
/* its line; the pixel output */
reg  [8:0] an_vc = TEST_LINE;
wire       px_stb, px_blank, spk;
wire [7:0] px_cc, px0, px1;
/* the design under test */
wire [8:0] px_vc;

gtia u_g (
    .clk(clk), .rst_n(rst_n), .reg_we(we), .reg_a(ra), .reg_d(rd), .reg_q(rq),
    .an_stb(an_stb), .an_q(an_q), .an_cc(an_cc), .an_vc(an_vc), .an_hires(hires),
    .pm_we(1'b0), .pm_sel(3'd0), .pm_d(8'd0), .trig_n(4'b0111), .consol_n(3'b111), .speaker(spk),
    .px_stb(px_stb), .px_cc(px_cc), .px_vc(px_vc), .px_blank(px_blank), .px0(px0), .px1(px1));

/* the picture of the last line: colour per colour clock (left / right hi-res pixel) */
reg [7:0] l0 [0:227];
reg [7:0] l1 [0:227];
always @(posedge clk)
/* the line as GTIA put it out */
    if (px_stb)
    begin
        l0[px_cc] <= px0;
        l1[px_cc] <= px1;
    end

/* a register write */
task automatic wr(input [4:0] a, input [7:0] d);
    @(posedge clk);
    we <= 1;
/* address and data */
    ra <= a;
    rd <= d;
    @(posedge clk);
/* one clock */
    we <= 0;
endtask

/* one line: code(cc) gives the ANx code of each colour clock */
typedef enum {BK, PF1AT50, HIRES, GTIA} pat_t;
task automatic line(input pat_t p);
    integer c;
/* every colour clock of the line */
    for (c = 0; c < LINE_CC; c++)
    begin
        @(posedge clk);
        an_stb <= 1;
/* its number; hi-res for two of the patterns */
        an_cc <= c;
        hires <= p == HIRES || p == GTIA;
        case (p)
/* playfield 1 at $50-57 */
            PF1AT50: an_q <= c < CC_VIS_BEG ? 3'b010 : (c >= PF_BEG && c < PF_END) ? 3'b101 : 3'b000;
/* pairs 10 at $50-57 */
            HIRES: an_q <= c < CC_VIS_BEG ? 3'b011 : (c >= PF_BEG && c < PF_END) ? 3'b110 : 3'b100;
            GTIA: an_q <= c < CC_VIS_BEG ? 3'b011 : {1'b1, c[1:0] == 2'b00 ? 2'b01 : c[1:0] == 2'b01 ? 2'b10 : 2'b00};
            default: an_q <= c < CC_VIS_BEG ? 3'b010 : 3'b000;
        endcase
/* the strobe ends */
        @(posedge clk);
        an_stb <= 0;
        repeat (GTIA_TICKS)
        begin
/* GTIA's four ticks, then the rest of the cycle */
            @(posedge clk);
        end
    end
    repeat (CYCLE_REST)
    begin
        @(posedge clk);
    end
/* the next line */
    an_vc <= an_vc + 1;
endtask

integer errors = 0;
task automatic check(input string what, input [7:0] got, input [7:0] want);
/* a wrong value */
    if (got !== want)
    begin
        $display("FAIL %s: %02h, expected %02h", what, got, want);
        errors++;
    end
    else
    begin
/* a right value */
        $display("ok   %s: %02h", what, got);
    end
endtask

initial
begin
    #RST_NS rst_n = 1;
/* COLBK */
    wr(5'h1A, 8'h94);
/* COLPM0 */
    wr(5'h12, 8'h1E);
/* COLPM1 */
    wr(5'h13, 8'h46);
/* COLPF0 */
    wr(5'h16, 8'h28);
/* COLPF1 */
    wr(5'h17, 8'h0E);
/* COLPF2 */
    wr(5'h18, 8'h84);
/* COLPF3 */
    wr(5'h19, 8'hC6);

/* background, a normal-width player 0 at $40 (bits 1010_0000) */
    wr(5'h00, 8'h40);
    wr(5'h0D, 8'hA0);
    line(BK);
/* the background colour, the player's bits */
    check("background", l0[8'h30], 8'h94);
    check("P0 bit 7 at $40", l0[8'h40], 8'h1E);
    check("P0 bit 6 at $41", l0[8'h41], 8'h94);
/* bit 5; the blank area */
    check("P0 bit 5 at $42", l0[8'h42], 8'h1E);
    check("blank", l0[8'h10], 8'h00);

/* quadruple width: bit 7 covers $40-$43, bit 6 $44-$47 */
    wr(5'h08, 8'h03);
    line(BK);
    check("4x at $43", l0[8'h43], 8'h1E);
/* the second and third pixel of the wide player */
    check("4x at $44", l0[8'h44], 8'h94);
    check("4x at $48", l0[8'h48], 8'h1E);
    wr(5'h08, 8'h00);

/* player 0 over PF1 ($50-57): PRIOR 0 mixes (OR), PRIOR 1 player wins, PRIOR 4 playfield wins */
    wr(5'h00, 8'h50);
    wr(5'h0D, 8'hFF);
/* HITCLR */
    wr(5'h1E, 8'h00);
    line(PF1AT50);
    check("PRIOR 0: P0 | PF1", l0[8'h52], 8'h1E | 8'h0E);
/* the collision register is read */
    check("after both: background", l0[8'h58], 8'h94);
    @(posedge clk);
    ra <= REG_P0PF;
/* player 0 hit playfield 1 */
    @(posedge clk);
    check("P0PF = PF1", rq, 8'h02);
    wr(5'h1B, 8'h01);
/* priority 1: the player in front */
    line(PF1AT50);
    check("PRIOR 1: P0", l0[8'h52], 8'h1E);
    wr(5'h1B, 8'h04);
/* priority 4: the playfield in front */
    line(PF1AT50);
    check("PRIOR 4: PF1", l0[8'h52], 8'h0E);

/* player 1 overlapping player 0: P0 wins; multicolour (PRIOR 5) ORs; P0PL / P1PL */
    wr(5'h1B, 8'h01);
    wr(5'h01, 8'h50);
    wr(5'h0E, 8'hFF);
/* collisions cleared; the line */
    wr(5'h1E, 8'h00);
    line(BK);
    check("P0 over P1", l0[8'h52], 8'h1E);
/* P0PL is read */
    @(posedge clk);
    ra <= REG_P0PL;
    @(posedge clk);
/* player 1 seen; P1PL */
    check("P0PL = P1", rq, 8'h02);
    @(posedge clk);
    ra <= REG_P1PL;
/* player 0 seen; multicolour players */
    @(posedge clk);
    check("P1PL = P0", rq, 8'h01);
    wr(5'h1B, 8'h21);
/* both colours ORed */
    line(BK);
    check("multicolour P0 | P1", l0[8'h52], 8'h1E | 8'h46);
    wr(5'h0D, 8'h00);
/* player 1 off, priority 1 */
    wr(5'h0E, 8'h00);
    wr(5'h1B, 8'h01);

/* hi-res: PF2 colour, PF1 luminance where a pixel is 1 (pairs 10 at $50-57) */
    line(HIRES);
    check("hi-res 0 pixel = PF2", l0[8'h40], 8'h84);
    check("hi-res left 1 = PF2 hue + PF1 lum", l0[8'h52], 8'h8E);
/* a pixel that is 0 */
    check("hi-res right 0", l1[8'h52], 8'h84);

/* missile 0 at $60 as the fifth player: PF3 colour */
    wr(5'h04, 8'h60);
    wr(5'h11, 8'h03);
    wr(5'h1B, 8'h11);
/* PRIOR bit 4: the missile in PF3's colour */
    line(BK);
    check("fifth player = PF3", l0[8'h60], 8'hC6);
    wr(5'h1B, 8'h01);
/* without it: the player's colour */
    line(BK);
    check("missile 0 = COLPM0", l0[8'h60], 8'h1E);
    wr(5'h11, 8'h00);

/* GTIA mode 9: pixel = {pair(2k), pair(2k+1)}: $40 -> 01 10 = 6, COLBK hue + luminance 6 */
    wr(5'h1A, 8'h90);
    wr(5'h1B, 8'h40);
    line(GTIA);
/* mode 9: 16 luminances of the background colour */
    check("mode 9 at $40", l0[8'h40], 8'h96);
    check("mode 9 at $41", l0[8'h41], 8'h96);
    check("mode 9 at $42", l0[8'h42], 8'h90);
/* mode 11: 16 colours of one luminance */
    wr(5'h1A, 8'h06);
    wr(5'h1B, 8'hC0);
    line(GTIA);
/* its colours; the verdict */
    check("mode 11 at $40", l0[8'h40], 8'h66);
    check("mode 11 at $42 (0: lum 0)", l0[8'h42], 8'h00);

    if (errors)
    begin
/* failed */
        $display("RESULT: FAIL (%0d)", errors);
    end
    else
    begin
        $display("RESULT: PASS");
    end
    $finish;
end
endmodule
