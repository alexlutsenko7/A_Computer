// sid_stub -- silent stand-in for sid_top in the system testbench (Questa does not accept
// the SID sources' use-before-declaration, which Quartus does). Registers read back 0.
module sid_top #(parameter MULTI_FILTERS = 1, parameter DUAL = 1) (
    input reset, input clk, input ce_1m, input [0:0] cs, input we, input [4:0] addr,
    input [7:0] data_in, output [7:0] data_out,
    input [12:0] fc_offset_l, input [7:0] pot_x_l, input [7:0] pot_y_l, input [17:0] ext_in_l, output [17:0] audio_l,
    input [12:0] fc_offset_r, input [7:0] pot_x_r, input [7:0] pot_y_r, input [17:0] ext_in_r, output [17:0] audio_r,
    input [0:0] filter_en, input [0:0] mode, input [1:0] cfg,
    input ld_clk, input [11:0] ld_addr, input [15:0] ld_data, input ld_wr
);
    assign data_out = 8'h00;
    assign audio_l  = 18'd0;
    assign audio_r  = 18'd0;
endmodule
