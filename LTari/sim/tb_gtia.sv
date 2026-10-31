//=============================================================================
// tb_gtia -- GTIA unit test: playfield colours, players / missiles (position, size, VDELAY not),
// priorities (PRIOR 1 / 4 / 8 / 0 mixing), hi-res luminance, collisions, fifth player, GTIA modes
// 9 / 11. A model of ANTIC's ANx stream: one colour clock per 8 clk, lines of 228 colour clocks.
//=============================================================================
`timescale 1ns/1ps

module tb_gtia;
reg clk = 0;
always #17.6 clk = ~clk;
reg rst_n = 0;

reg        we = 0;
reg  [4:0] ra = 0;
reg  [7:0] rd = 0;
wire [7:0] rq;
reg        an_stb = 0, hires = 0;
reg  [2:0] an_q = 3'b000;
reg  [7:0] an_cc = 0;
reg  [8:0] an_vc = 9'd100;
wire       px_stb, px_blank, spk;
wire [7:0] px_cc, px0, px1;
wire [8:0] px_vc;

gtia u_g (
    .clk(clk), .rst_n(rst_n), .reg_we(we), .reg_a(ra), .reg_d(rd), .reg_q(rq),
    .an_stb(an_stb), .an_q(an_q), .an_cc(an_cc), .an_vc(an_vc), .an_hires(hires),
    .pm_we(1'b0), .pm_sel(3'd0), .pm_d(8'd0), .trig_n(4'b0111), .consol_n(3'b111), .speaker(spk),
    .px_stb(px_stb), .px_cc(px_cc), .px_vc(px_vc), .px_blank(px_blank), .px0(px0), .px1(px1));

// the picture of the last line: colour per colour clock (left / right hi-res pixel)
reg [7:0] l0 [0:227];
reg [7:0] l1 [0:227];
always @(posedge clk) if (px_stb) begin l0[px_cc] <= px0; l1[px_cc] <= px1; end

task automatic wr(input [4:0] a, input [7:0] d);
    @(posedge clk); we <= 1; ra <= a; rd <= d;
    @(posedge clk); we <= 0;
endtask

// one line: code(cc) gives the ANx code of each colour clock
typedef enum {BK, PF1AT50, HIRES, GTIA} pat_t;
task automatic line(input pat_t p);
    integer c;
    for (c = 0; c < 228; c++) begin
        @(posedge clk);
        an_stb <= 1; an_cc <= c; hires <= p == HIRES || p == GTIA;
        case (p)
            PF1AT50: an_q <= c < 8'h22 ? 3'b010 : (c >= 8'h50 && c < 8'h58) ? 3'b101 : 3'b000;
            HIRES:   an_q <= c < 8'h22 ? 3'b011 : (c >= 8'h50 && c < 8'h58) ? 3'b110 : 3'b100;   // pairs 10 at $50-57
            GTIA:    an_q <= c < 8'h22 ? 3'b011 : {1'b1, c[1:0] == 2'b00 ? 2'b01 : c[1:0] == 2'b01 ? 2'b10 : 2'b00};
            default: an_q <= c < 8'h22 ? 3'b010 : 3'b000;
        endcase
        @(posedge clk); an_stb <= 0;
        repeat (6) @(posedge clk);
    end
    repeat (20) @(posedge clk);
    an_vc <= an_vc + 1;
endtask

integer errors = 0;
task automatic check(input string what, input [7:0] got, input [7:0] want);
    if (got !== want) begin $display("FAIL %s: %02h, expected %02h", what, got, want); errors++; end
    else $display("ok   %s: %02h", what, got);
endtask

initial begin
    #100 rst_n = 1;
    wr(5'h1A, 8'h94);                   // COLBK
    wr(5'h12, 8'h1E);                   // COLPM0
    wr(5'h13, 8'h46);                   // COLPM1
    wr(5'h16, 8'h28);                   // COLPF0
    wr(5'h17, 8'h0E);                   // COLPF1
    wr(5'h18, 8'h84);                   // COLPF2
    wr(5'h19, 8'hC6);                   // COLPF3

    // background, a normal-width player 0 at $40 (bits 1010_0000)
    wr(5'h00, 8'h40); wr(5'h0D, 8'hA0);
    line(BK);
    check("background", l0[8'h30], 8'h94);
    check("P0 bit 7 at $40", l0[8'h40], 8'h1E);
    check("P0 bit 6 at $41", l0[8'h41], 8'h94);
    check("P0 bit 5 at $42", l0[8'h42], 8'h1E);
    check("blank", l0[8'h10], 8'h00);

    // quadruple width: bit 7 covers $40-$43, bit 6 $44-$47
    wr(5'h08, 8'h03);
    line(BK);
    check("4x at $43", l0[8'h43], 8'h1E);
    check("4x at $44", l0[8'h44], 8'h94);
    check("4x at $48", l0[8'h48], 8'h1E);
    wr(5'h08, 8'h00);

    // player 0 over PF1 ($50-57): PRIOR 0 mixes (OR), PRIOR 1 player wins, PRIOR 4 playfield wins
    wr(5'h00, 8'h50); wr(5'h0D, 8'hFF);
    wr(5'h1E, 8'h00);                   // HITCLR
    line(PF1AT50);
    check("PRIOR 0: P0 | PF1", l0[8'h52], 8'h1E | 8'h0E);
    check("after both: background", l0[8'h58], 8'h94);
    @(posedge clk); ra <= 5'h04; @(posedge clk);
    check("P0PF = PF1", rq, 8'h02);
    wr(5'h1B, 8'h01);
    line(PF1AT50);
    check("PRIOR 1: P0", l0[8'h52], 8'h1E);
    wr(5'h1B, 8'h04);
    line(PF1AT50);
    check("PRIOR 4: PF1", l0[8'h52], 8'h0E);

    // player 1 overlapping player 0: P0 wins; multicolour (PRIOR 5) ORs; P0PL / P1PL
    wr(5'h1B, 8'h01); wr(5'h01, 8'h50); wr(5'h0E, 8'hFF); wr(5'h1E, 8'h00);
    line(BK);
    check("P0 over P1", l0[8'h52], 8'h1E);
    @(posedge clk); ra <= 5'h0C; @(posedge clk);
    check("P0PL = P1", rq, 8'h02);
    @(posedge clk); ra <= 5'h0D; @(posedge clk);
    check("P1PL = P0", rq, 8'h01);
    wr(5'h1B, 8'h21);
    line(BK);
    check("multicolour P0 | P1", l0[8'h52], 8'h1E | 8'h46);
    wr(5'h0D, 8'h00); wr(5'h0E, 8'h00); wr(5'h1B, 8'h01);

    // hi-res: PF2 colour, PF1 luminance where a pixel is 1 (pairs 10 at $50-57)
    line(HIRES);
    check("hi-res 0 pixel = PF2", l0[8'h40], 8'h84);
    check("hi-res left 1 = PF2 hue + PF1 lum", l0[8'h52], 8'h8E);
    check("hi-res right 0", l1[8'h52], 8'h84);

    // missile 0 at $60 as the fifth player: PF3 colour
    wr(5'h04, 8'h60); wr(5'h11, 8'h03); wr(5'h1B, 8'h11);
    line(BK);
    check("fifth player = PF3", l0[8'h60], 8'hC6);
    wr(5'h1B, 8'h01);
    line(BK);
    check("missile 0 = COLPM0", l0[8'h60], 8'h1E);
    wr(5'h11, 8'h00);

    // GTIA mode 9: pixel = {pair(2k), pair(2k+1)}: $40 -> 01 10 = 6, COLBK hue + luminance 6
    wr(5'h1A, 8'h90); wr(5'h1B, 8'h40);
    line(GTIA);
    check("mode 9 at $40", l0[8'h40], 8'h96);
    check("mode 9 at $41", l0[8'h41], 8'h96);
    check("mode 9 at $42", l0[8'h42], 8'h90);
    wr(5'h1A, 8'h06); wr(5'h1B, 8'hC0);
    line(GTIA);
    check("mode 11 at $40", l0[8'h40], 8'h66);
    check("mode 11 at $42 (0: lum 0)", l0[8'h42], 8'h00);

    if (errors) $display("RESULT: FAIL (%0d)", errors); else $display("RESULT: PASS");
    $finish;
end
endmodule
