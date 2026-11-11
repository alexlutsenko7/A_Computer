/* tb_vic -- Kawari VIC-II alone, driven as c64_system drives it: a CPU write to $D020 */
/* (border = white) during phi2, then the colour index output (pixel at raster_x_o, as */
/* c64_fb takes it) must be white along a whole raster line of the border. */
`timescale 1ns/1ps
module tb_vic;

/* half a period of the 31.51 MHz clock, ns */
localparam real CLK_HALF = 15.867;
/* the power-on reset ends after 2000 ns */
localparam integer POR_NS = 2000;
/* the raster line that is measured */
localparam [8:0] TEST_LINE = 9'd30;
/* first visible dot of a line */
localparam integer VIS_BEG = 92;
/* first dot after the visible part of a line */
localparam integer VIS_END = 492;
/* visible dots of a raster line */
localparam integer VIS_DOTS = 400;
/* white dots a frame must have at least */
localparam integer WHITE_MIN = 1000;
reg clk = 0;
/* 31.51 MHz */
always #CLK_HALF clk = !clk;
reg por = 1;
initial #POR_NS por = 0;

/* the chip's outputs */
wire        clk_phi, aec, ba, irq;
wire [15:0] phase;
wire [13:0] vaddr;
/* data, pixel, position */
wire [7:0]  dbo;
wire [3:0]  pix;
wire [9:0]  rx;
/* the raster line; the register port */
wire [8:0]  rline;
reg  [5:0]  adi = 6'h3F;
reg  [7:0]  wdata = 8'h00;
/* chip select and write; the VIC-II */
reg         ce_n = 1, rw = 1;

vicii u_vic (
    .standard_sw(1'b0), .ext_rst(por), .rst(), .clk_dot4x(clk), .clk_phi(clk_phi),
    .clk_col16x(1'b0), .clk_col16x_4tm(1'b0),
    .ado(), .vic_addr(vaddr), .phase(phase), .pixel(pix), .raster_x_o(rx), .raster_line_o(rline), .adi(adi), .dbo(dbo), .dbi({4'h0, aec ? wdata : 8'h00}),
    .ce(ce_n), .rw(rw), .irq(irq), .lp(1'b1), .aec(aec), .ba_d2(ba),
    .ras(), .cas(), .ls245_data_dir(), .ls245_addr_dir(), .vic_write_db(), .vic_write_ab(), .rw_ctl(), .chip()
);

/* one CPU write cycle: set the bus at tick 2 of phi1, hold it through phi2 and tick 0 of the next phi1 */
task automatic vic_write(input [5:0] a, input [7:0] d);
    begin
        @(posedge clk);
        while (!(phase[2] && !clk_phi))
        begin
/* address and data */
            @(posedge clk);
        end
        adi = a;
        wdata = d;
/* selected, as a write */
        ce_n = 0;
        rw = 0;
        @(posedge clk);
/* until the chip takes it */
        while (!(phase[2] && !clk_phi))
        begin
            @(posedge clk);
        end
        ce_n = 1;
/* the port idle */
        rw = 1;
        adi = 6'h3F;
    end
endtask

/* dots as c64_fb takes them: the dot at raster_x is complete when raster_x moves on */
reg  [3:0] p_d;
reg  [9:0] x_d;
always @(posedge clk)
begin
/* pixel and position, delayed */
    p_d <= pix;
    x_d <= rx;
end
wire ev = rx != x_d;

/* white and unknown dots counted */
integer n_white = 0, n_x = 0;
always @(posedge clk)
    if (ev)
    begin
/* a white dot */
        if (p_d == 4'd1)
        begin
            n_white++;
        end
        if (^p_d === 1'bx)
        begin
/* an unknown one */
            n_x++;
        end
    end

initial
begin
    #20us;
/* border white */
    vic_write(6'h20, 8'h01);
    $display("%t wrote D020 = 01; registers: ec = %h", $time, u_vic.vic_registers.ec);
    #25ms;
/* raster line 30 (top border): white dots between raster_x 92 and 491 (c64_fb's window) */
    begin
        integer w;
        w = 0;
        wait (rline == 9'd30 && rx == 10'd0);
/* the whole of raster line 30 */
        while (rline == TEST_LINE)
        begin
            @(posedge clk);
            if (ev && x_d >= VIS_BEG && x_d < VIS_END && p_d == 4'd1)
            begin
/* counted; the visible width must be 400 dots */
                w++;
            end
        end
        $display("white dots in raster line 30: %0d (400 expected)", w);
        if (w != VIS_DOTS)
        begin
/* failed */
            $display("RESULT: FAIL (width)");
            $finish;
        end
    end
    $display("white dots %0d, X dots %0d, chip %0d", n_white, n_x, u_vic.chip);
/* enough white dots, none unknown */
    if (n_white > WHITE_MIN && n_x == 0)
    begin
        $display("RESULT: PASS");
    end
    else
    begin
        $display("RESULT: FAIL");
    end
/* the end */
    $finish;
end
endmodule
