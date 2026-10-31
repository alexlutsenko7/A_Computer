//=============================================================================
// rom_loader -- copies the ROM images from the configuration flash into SDRAM
//               after power-up / reset, then releases the CPU (done = 1)
//
// Flash layout (see docs/PLAN.md, programmed with the .jic):
//   0x100000  128K ROM set, 32 KB  -> SDRAM 0x20000 (ROM 0 + ROM 1)
//   0x108000  DiagROM,      16 KB  -> SDRAM 0x28000
// One continuous READ (0x03) of 48 KB from 0x100000 to SDRAM 0x20000.
//
// SPI mode 0, DCLK = clk / (2 * DIV) (112 / 8 = 14 MHz). MISO is sampled at
// the end of the high phase, MOSI changes in the low phase.
//
// Bit order check: both ROMs start with F3 (DI). If the first byte reads CF
// (F3 bit-reversed), every byte is bit-reversed back; anything else sets
// bad_image (ROMs missing: program the .jic with the ROM data).
//=============================================================================
`default_nettype none

module rom_loader #(
    parameter [23:0] FLASH_ADDR = 24'h100000,
    parameter [17:0] SD_BASE    = 18'h20000,
    parameter integer LEN       = 49152,
    parameter integer DIV       = 4
)(
    input  wire        clk,
    input  wire        rst_n,

    // flash pins (flash_if)
    output reg         f_dclk,
    output reg         f_ncs,
    output reg         f_mosi,
    input  wire        f_miso,

    // SDRAM port (sdram_ram protocol)
    output reg         sd_req,
    output wire        sd_we,
    output reg  [17:0] sd_addr,
    output reg  [7:0]  sd_din,
    input  wire        sd_ack,

    output reg         done,
    output reg         bad_image
);

assign sd_we = 1'b1;

localparam [2:0] S_CS    = 3'd0,        // select the flash
                 S_CMD   = 3'd1,        // send 03 + 24-bit address
                 S_DATA  = 3'd2,        // read one byte
                 S_WRITE = 3'd3,        // write it to SDRAM
                 S_WAIT  = 3'd4,        // wait for the SDRAM
                 S_END   = 3'd5;

reg [2:0]  state;
reg [7:0]  div_cnt;
reg [5:0]  bit_cnt;                     // bits left in the current transfer
reg [31:0] sh_out;
reg [7:0]  sh_in;
reg        hi;                          // DCLK phase
reg [15:0] count;
reg        first, reverse;

wire [7:0] got = {sh_in[6:0], f_miso};  // byte complete at the last sample
wire [7:0] rev = {got[0], got[1], got[2], got[3], got[4], got[5], got[6], got[7]};

always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
        state     <= S_CS;
        f_dclk    <= 1'b0;
        f_ncs     <= 1'b1;
        f_mosi    <= 1'b0;
        div_cnt   <= 8'd0;
        bit_cnt   <= 6'd0;
        sh_out    <= 32'd0;
        sh_in     <= 8'd0;
        hi        <= 1'b0;
        count     <= 16'd0;
        first     <= 1'b1;
        reverse   <= 1'b0;
        done      <= 1'b0;
        bad_image <= 1'b0;
        sd_req    <= 1'b0;
        sd_addr   <= SD_BASE;
        sd_din    <= 8'd0;
    end else begin
        sd_req <= 1'b0;
        case (state)
            S_CS: begin
                f_ncs <= 1'b0;
                if (div_cnt == DIV - 1) begin
                    div_cnt <= 8'd0;
                    sh_out  <= {8'h03, FLASH_ADDR};
                    bit_cnt <= 6'd32;
                    f_mosi  <= 1'b0;            // first bit = MSB of 0x03
                    state   <= S_CMD;
                end else
                    div_cnt <= div_cnt + 8'd1;
            end

            // Bit engine for S_CMD and S_DATA: low phase (MOSI = next bit), high phase, sample
            S_CMD, S_DATA: begin
                if (div_cnt == DIV - 1) begin
                    div_cnt <= 8'd0;
                    if (!hi) begin
                        f_dclk <= 1'b1;
                        hi     <= 1'b1;
                    end else begin
                        f_dclk  <= 1'b0;
                        hi      <= 1'b0;
                        sh_in   <= got;
                        sh_out  <= {sh_out[30:0], 1'b0};
                        f_mosi  <= sh_out[30];
                        bit_cnt <= bit_cnt - 6'd1;
                        if (bit_cnt == 6'd1) begin
                            if (state == S_CMD) begin
                                bit_cnt <= 6'd8;
                                f_mosi  <= 1'b0;
                                state   <= S_DATA;
                            end else begin
                                if (first) begin
                                    first     <= 1'b0;
                                    reverse   <= (got == 8'hCF);
                                    bad_image <= (got != 8'hF3) && (got != 8'hCF);
                                    sd_din    <= (got == 8'hCF) ? rev : got;
                                end else
                                    sd_din    <= reverse ? rev : got;
                                state <= S_WRITE;
                            end
                        end
                    end
                end else
                    div_cnt <= div_cnt + 8'd1;
            end

            S_WRITE: begin
                sd_req <= 1'b1;
                state  <= S_WAIT;
            end

            S_WAIT:
                if (sd_ack) begin
                    count   <= count + 16'd1;
                    if (count == LEN - 1)
                        state <= S_END;
                    else begin
                        sd_addr <= sd_addr + 18'd1;
                        bit_cnt <= 6'd8;
                        state   <= S_DATA;
                    end
                end

            S_END: begin
                f_ncs <= 1'b1;
                done  <= 1'b1;
            end

            default: state <= S_CS;
        endcase
    end

endmodule

`default_nettype wire
