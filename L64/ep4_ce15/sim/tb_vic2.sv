/* tb_vic2 -- Kawari VIC-II with a memory as c64_system provides it (address taken at tick 2 of */
/* each half, data on dbi until the next tick 2), set up like the KERNAL: screen at $0400 */
/* ("HELLO"), characters from the CHAR ROM at $1000, border light blue, background blue. */
/* Writes vic2.ppm (one VIC-II frame: 504 x 312 dots, raster_x / raster line as c64_fb */
/* takes them); `+define+DBI_EARLY` presents the data from tick 3 on, as the SDRAM path */
/* does at the earliest. */
`timescale 1ns/1ps
module tb_vic2;

/* half a period of the 31.51 MHz clock, ns */
localparam real CLK_HALF = 15.867;
/* the power-on reset ends after 2000 ns */
localparam integer POR_NS = 2000;
/* bytes the VIC-II can address */
localparam integer VIC_MEM = 16384;
/* characters of the text screen */
localparam integer SCREEN_CHARS = 1000;
/* clocks until the bus data arrives */
localparam integer DATA_DELAY = 5;
/* colour 14: light blue */
localparam [3:0] COL_LIGHT_BLUE = 4'd14;
/* dots of a raster line */
localparam integer LINE_DOTS = 504;
/* raster lines of a PAL frame */
localparam integer FRAME_LINES = 312;
reg clk = 0;
/* the dot clock x 4; the power-on reset */
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
/* chip select and write; the data the chip reads */
reg         ce_n = 1, rw = 1;
reg  [7:0]  vdata = 8'hFF;
reg  [3:0]  cdata = 4'h0;
/* the bus owner; the address, latched */
reg         own_vic = 1;
reg  [13:0] vaddr_l;

vicii u_vic (
    .standard_sw(1'b0), .ext_rst(por), .rst(), .clk_dot4x(clk), .clk_phi(clk_phi),
    .clk_col16x(1'b0), .clk_col16x_4tm(1'b0),
    .ado(), .vic_addr(vaddr), .phase(phase), .pixel(pix), .raster_x_o(rx), .raster_line_o(rline), .adi(adi), .dbo(dbo), .dbi({cdata, own_vic ? vdata : wdata}),
    .ce(ce_n), .rw(rw), .irq(irq), .lp(1'b1), .aec(aec), .ba_d2(ba),
    .ras(), .cas(), .ls245_data_dir(), .ls245_addr_dir(), .vic_write_db(), .vic_write_ab(), .rw_ctl(), .chip()
);

/* memory (VIC bank 0): RAM with the screen, CHAR ROM at $1000-$1FFF */
reg [7:0] ram  [0:16383];
reg [7:0] chr  [0:4095];
integer i, fd;
/* the RAM starts empty */
initial
begin
    for (i = 0; i < VIC_MEM; i++)
    begin
        ram[i] = 8'h00;
    end
/* the screen: spaces */
    for (i = 0; i < SCREEN_CHARS; i++)
    begin
        ram[16'h0400 + i] = 8'h20;
    end
    ram[16'h0400] = 8;
/* the text HELLO in screen codes */
    ram[16'h0401] = 5;
    ram[16'h0402] = 12;
    ram[16'h0403] = 12;
/* its last letter; the character ROM */
    ram[16'h0404] = 15;
    fd = $fopen("../roms_local/char.bin", "rb");
    i = $fread(chr, fd);
/* read; the VIC-II's memory view */
    $fclose(fd);
end
function [7:0] mem(input [13:0] a);
    mem = (a[13:12] == 2'b01) ? chr[a[11:0]] : ram[a];
endfunction

/* the bus as c64_system: owner and address at tick 2 */
always @(posedge clk)
    if (phase[2])
    begin
        own_vic <= !aec;
/* a VIC-II cycle */
        if (!aec)
        begin
`ifdef DBI_EARLY
            vdata <= mem(vaddr);
/* the data comes late, as from the SDRAM */
`else
            vdata <= 8'hXX;
            fork
                begin
                    repeat (DATA_DELAY)
                    begin
/* one clock later */
                        @(posedge clk);
                    end
                    vdata <= mem(vaddr_l);
                end
            join_none
`endif
/* the colour RAM: light blue */
            cdata <= COL_LIGHT_BLUE;
        end
    end
always @(posedge clk)
    if (phase[2])
    begin
/* the address of this cycle */
        vaddr_l <= vaddr;
    end

task automatic vic_write(input [5:0] a, input [7:0] d);
    begin
        @(posedge clk);
/* until the chip takes a write */
        while (!(phase[2] && !clk_phi))
        begin
            @(posedge clk);
        end
        adi = a;
/* data; selected, as a write */
        wdata = d;
        ce_n = 0;
        rw = 0;
/* one clock, then until it is taken */
        @(posedge clk);
        while (!(phase[2] && !clk_phi))
        begin
            @(posedge clk);
        end
/* the port idle */
        ce_n = 1;
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

/* Kawari's palette (c64_fb.v), 8 bits per colour */
function automatic [23:0] rgb8(input [3:0] c);
    case (c)
        0: rgb8 = 24'h000000;
/* white, red, cyan */
        1: rgb8 = 24'hFFFFFF;
        2: rgb8 = 24'hAC2828;
        3: rgb8 = 24'h60D8CC;
/* purple, green, blue */
        4: rgb8 = 24'hB03CB4;
        5: rgb8 = 24'h48C448;
        6: rgb8 = 24'h3438C4;
/* yellow, orange, brown */
        7: rgb8 = 24'hE4EC4C;
        8: rgb8 = 24'hB4581C;
        9: rgb8 = 24'h683808;
/* light red, dark grey, grey */
        10: rgb8 = 24'hE8746C;
        11: rgb8 = 24'h4C4C4C;
        12: rgb8 = 24'h848484;
/* light green, light blue, light grey */
        13: rgb8 = 24'hA4F89C;
        14: rgb8 = 24'h707CE4;
        default: rgb8 = 24'hB4B4B4;
    endcase
endfunction

/* one frame into a picture file */
task automatic grab(input string fname);
    reg [23:0] img [0:504*312-1];
    integer f, k;
    begin
/* from the frame's first dot */
        wait (rline == 9'd0 && rx == 10'd0);
        @(posedge clk);
        while (!(rline == 9'd0 && rx == 10'd0))
        begin
/* every dot once */
            @(posedge clk);
            if (rx != x_d && x_d < LINE_DOTS)
            begin
                img[rline * 504 + x_d] = rgb8(p_d);
            end
        end
/* a PPM header, then the dots */
        f = $fopen(fname, "w");
        $fwrite(f, "P3\n504 312\n255\n");
        for (k = 0; k < LINE_DOTS * FRAME_LINES; k++)
        begin
/* written */
            $fwrite(f, "%0d %0d %0d\n", img[k][23:16], img[k][15:8], img[k][7:0]);
        end
        $fclose(f);
    end
endtask

initial
begin
/* the registers as after a reset of the C64: screen on, 40 columns */
    #20us;
    vic_write(6'h11, 8'h1B);
    vic_write(6'h16, 8'hC8);
/* memory pointers, border and background colour */
    vic_write(6'h18, 8'h15);
    vic_write(6'h20, 8'h0E);
    vic_write(6'h21, 8'h06);
/* a frame later the picture is taken */
    #25ms;
    grab("vic2.ppm");
    $display("RESULT: frame written");
/* the end */
    $finish;
end
endmodule
