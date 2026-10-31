// tb_vic2 -- Kawari VIC-II with a memory as c64_system provides it (address taken at tick 2 of
// each half, data on dbi until the next tick 2), set up like the KERNAL: screen at $0400
// ("HELLO"), characters from the CHAR ROM at $1000, border light blue, background blue.
// Writes vic2.ppm (one VIC-II frame: 504 x 312 dots, raster_x / raster line as c64_fb
// takes them); `+define+DBI_EARLY` presents the data from tick 3 on, as the SDRAM path
// does at the earliest.
`timescale 1ns/1ps
module tb_vic2;
reg clk = 0;
always #15.867 clk = !clk;
reg por = 1;
initial #2000 por = 0;

wire        clk_phi, aec, ba, irq;
wire [15:0] phase;
wire [13:0] vaddr;
wire [7:0]  dbo;
wire [3:0]  pix;
wire [9:0]  rx;
wire [8:0]  rline;
reg  [5:0]  adi = 6'h3F;
reg  [7:0]  wdata = 8'h00;
reg         ce_n = 1, rw = 1;
reg  [7:0]  vdata = 8'hFF;
reg  [3:0]  cdata = 4'h0;
reg         own_vic = 1;
reg  [13:0] vaddr_l;

vicii u_vic (
    .standard_sw(1'b0), .ext_rst(por), .rst(), .clk_dot4x(clk), .clk_phi(clk_phi),
    .clk_col16x(1'b0), .clk_col16x_4tm(1'b0),
    .ado(), .vic_addr(vaddr), .phase(phase), .pixel(pix), .raster_x_o(rx), .raster_line_o(rline), .adi(adi), .dbo(dbo), .dbi({cdata, own_vic ? vdata : wdata}),
    .ce(ce_n), .rw(rw), .irq(irq), .lp(1'b1), .aec(aec), .ba_d2(ba),
    .ras(), .cas(), .ls245_data_dir(), .ls245_addr_dir(), .vic_write_db(), .vic_write_ab(), .rw_ctl(), .chip()
);

// memory (VIC bank 0): RAM with the screen, CHAR ROM at $1000-$1FFF
reg [7:0] ram  [0:16383];
reg [7:0] chr  [0:4095];
integer i, fd;
initial begin
    for (i = 0; i < 16384; i++) ram[i] = 8'h00;
    for (i = 0; i < 1000; i++) ram[16'h0400 + i] = 8'h20;
    ram[16'h0400] = 8; ram[16'h0401] = 5; ram[16'h0402] = 12; ram[16'h0403] = 12; ram[16'h0404] = 15;
    fd = $fopen("../roms_local/char.bin", "rb");
    i = $fread(chr, fd);
    $fclose(fd);
end
function [7:0] mem(input [13:0] a);
    mem = (a[13:12] == 2'b01) ? chr[a[11:0]] : ram[a];
endfunction

// the bus as c64_system: owner and address at tick 2
always @(posedge clk)
    if (phase[2]) begin
        own_vic <= !aec;
        if (!aec) begin
`ifdef DBI_EARLY
            vdata <= mem(vaddr);
`else
            vdata <= 8'hXX;
            fork begin repeat (5) @(posedge clk); vdata <= mem(vaddr_l); end join_none
`endif
            cdata <= 4'd14;
        end
    end
always @(posedge clk) if (phase[2]) vaddr_l <= vaddr;

task automatic vic_write(input [5:0] a, input [7:0] d);
    begin
        @(posedge clk); while (!(phase[2] && !clk_phi)) @(posedge clk);
        adi = a; wdata = d; ce_n = 0; rw = 0;
        @(posedge clk); while (!(phase[2] && !clk_phi)) @(posedge clk);
        ce_n = 1; rw = 1; adi = 6'h3F;
    end
endtask

// dots as c64_fb takes them: the dot at raster_x is complete when raster_x moves on
reg  [3:0] p_d;
reg  [9:0] x_d;
always @(posedge clk) begin p_d <= pix; x_d <= rx; end

// Kawari's palette (c64_fb.v), 8 bits per colour
function automatic [23:0] rgb8(input [3:0] c);
    case (c)
        0: rgb8 = 24'h000000;  1: rgb8 = 24'hFFFFFF;  2: rgb8 = 24'hAC2828;  3: rgb8 = 24'h60D8CC;
        4: rgb8 = 24'hB03CB4;  5: rgb8 = 24'h48C448;  6: rgb8 = 24'h3438C4;  7: rgb8 = 24'hE4EC4C;
        8: rgb8 = 24'hB4581C;  9: rgb8 = 24'h683808;  10: rgb8 = 24'hE8746C; 11: rgb8 = 24'h4C4C4C;
        12: rgb8 = 24'h848484; 13: rgb8 = 24'hA4F89C; 14: rgb8 = 24'h707CE4; default: rgb8 = 24'hB4B4B4;
    endcase
endfunction

task automatic grab(input string fname);
    reg [23:0] img [0:504*312-1];
    integer f, k;
    begin
        wait (rline == 9'd0 && rx == 10'd0);
        @(posedge clk);
        while (!(rline == 9'd0 && rx == 10'd0)) begin
            @(posedge clk);
            if (rx != x_d && x_d < 504) img[rline * 504 + x_d] = rgb8(p_d);
        end
        f = $fopen(fname, "w");
        $fwrite(f, "P3\n504 312\n255\n");
        for (k = 0; k < 504 * 312; k++) $fwrite(f, "%0d %0d %0d\n", img[k][23:16], img[k][15:8], img[k][7:0]);
        $fclose(f);
    end
endtask

initial begin
    #20us;
    vic_write(6'h11, 8'h1B);
    vic_write(6'h16, 8'hC8);
    vic_write(6'h18, 8'h15);
    vic_write(6'h20, 8'h0E);
    vic_write(6'h21, 8'h06);
    #25ms;
    grab("vic2.ppm");
    $display("RESULT: frame written");
    $finish;
end
endmodule
