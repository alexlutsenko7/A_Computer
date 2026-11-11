// config.vh -- VIC-II Kawari build configuration for L64 (our file, from config.vh.template)
// A plain VIC-II: no Kawari extensions, no luma/chroma, no DVI, no RGB output (NEED_RGB
// is not set: L64 takes the colour index and makes its own VGA picture, c64_fb.v).
`ifndef config_vh_
`define config_vh_

`define VERSION_MAJOR 8'd0
`define VERSION_MINOR 8'd8
`define VARIANT_SUFFIX_1 8'd0
`define VARIANT_SUFFIX_2 8'd0
`define VARIANT_SUFFIX_3 8'd0
`define VARIANT_SUFFIX_4 8'd0

`endif
