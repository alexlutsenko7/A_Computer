/* menu_names -- reads the machines' names from the configuration flash for the menu */
/* */
/* A machine takes 2 MB of the flash: its bitstream in the first megabyte, its ROM area in the */
/* second (docs/PLAN.md). The first sector of the ROM area is the machine's info sector, written */
/* when the machine is installed (L.jic, or the ESP32 from the SD card): */
/* 0x00  tag A5 5A <machine byte> <its complement>  (the ROM loader looks for it) */
/* 0x10  the menu line, NAME_LEN characters, space padded */
/* For each position the reader sends one READ (0x03) of the area's first NAME_OFF + NAME_LEN */
/* bytes: with A5 5A at the start the position holds a machine (valid) and its line goes into the */
/* menu's name RAM (row = position, column NAME_COL + n); otherwise the row gets "(empty)". */
/* */
/* It runs after reset, after restart (the ESP32 wrote a machine: register RELOAD) and whenever */
/* hold drops (the ESP32 gave the flash pins back); while hold is 1 it keeps off the flash. */
/* SPI mode 0, DCLK = clk / (2 * DIV); MISO is sampled at the end of the high phase. */
`default_nettype none

module menu_names #(
    parameter integer N_AREAS   = 3,
/* the ROM area of position i at [24*i +: 24] */
    parameter [71:0]  ROM_AREAS = {24'h600000, 24'h400000, 24'h200000},
    parameter integer DIV       = 4
)(
    input  wire       clk,
    input  wire       rst_n,
/* read again (one clock) */
    input  wire       restart,
/* the flash pins are someone else's */
    input  wire       hold,

/* flash pins (flash_if) */
    output reg        f_dclk,
    output reg        f_ncs,
    output reg        f_mosi,
    input  wire       f_miso,

/* the menu's name RAM: address {position, column} */
    output reg        we,
    output reg  [6:0] waddr,
    output reg  [7:0] wdata,

/* a machine is installed in position i; all positions were read */
    output reg  [N_AREAS-1:0] valid,
    output reg        done
);

/* flash command: read data */
localparam [7:0] FLASH_READ = 8'h03;
/* bits of the command with its 24-bit address */
localparam [5:0] CMD_BITS = 6'd32;
/* bits of a data byte */
localparam [5:0] BYTE_BITS = 6'd8;
/* the two bytes every info sector starts with */
localparam [7:0] TAG_0 = 8'hA5;
localparam [7:0] TAG_1 = 8'h5A;
/* where the menu line starts in the info sector, and its last byte */
localparam [5:0] NAME_OFF = 6'd16;
localparam [5:0] NAME_END = 6'd44;
/* the first menu column of the line (behind " n ") */
localparam [4:0] NAME_COL = 5'd3;
/* printable characters: space to the tilde */
localparam [7:0] CHAR_SPACE = 8'h20;
localparam [7:0] CHAR_LAST = 8'h7E;

/* select the flash, send the command, read the bytes, release, all done */
localparam [2:0] S_CS = 3'd0, S_CMD = 3'd1, S_DATA = 3'd2, S_GAP = 3'd3, S_END = 3'd4;

reg [2:0]  state;
reg [7:0]  div_cnt;
/* bits left in the current transfer */
reg [5:0]  bit_cnt;
reg [31:0] sh_out;
reg [7:0]  sh_in;
/* DCLK phase */
reg        hi;
/* the position being read, the byte's number, the tag was there so far */
reg [1:0]  area;
reg [5:0]  idx;
reg        ok;

/* byte complete at the last sample */
wire [7:0] got = {sh_in[6:0], f_miso};
/* a character the font has */
wire [7:0] chr = (got >= CHAR_SPACE && got <= CHAR_LAST) ? got : CHAR_SPACE;
/* the character's number in the line */
wire [5:0] npos = idx - NAME_OFF;

/* the line of a position without a machine */
function [7:0] empty_chr(input [5:0] n);
    case (n)
        6'd0: empty_chr = "(";
/* the letters of "(empty)" */
        6'd1: empty_chr = "e";
        6'd2: empty_chr = "m";
        6'd3: empty_chr = "p";
/* its end */
        6'd4: empty_chr = "t";
        6'd5: empty_chr = "y";
        6'd6: empty_chr = ")";
/* spaces behind it */
        default: empty_chr = " ";
    endcase
endfunction

always @(posedge clk or negedge rst_n)
    if (!rst_n)
    begin
/* reset: the flash idle, nothing read */
        state   <= S_CS;
        f_dclk  <= 1'b0;
        f_ncs   <= 1'b1;
/* no bit shifted yet */
        f_mosi  <= 1'b0;
/* the bit engine */
        div_cnt <= 8'd0;
        bit_cnt <= 6'd0;
        sh_out  <= 32'd0;
/* the clock's phase */
        sh_in   <= 8'd0;
        hi      <= 1'b0;
/* the first position */
        area    <= 2'd0;
        idx     <= 6'd0;
        ok      <= 1'b0;
/* the name RAM's port, the results */
        we      <= 1'b0;
        waddr   <= 7'd0;
        wdata   <= 8'd0;
/* no machine known, nothing read */
        valid   <= {N_AREAS{1'b0}};
        done    <= 1'b0;
    end
    else if (restart || hold)
    begin
/* from the start again, once the flash is free */
        state   <= S_CS;
        f_dclk  <= 1'b0;
        f_ncs   <= 1'b1;
/* the bit engine stops */
        div_cnt <= 8'd0;
        hi      <= 1'b0;
        area    <= 2'd0;
/* the flags of the last reading stay until each position is read again (a key pressed during */
/* the ESP32's two-second flash check must not be lost) */
        we      <= 1'b0;
        done    <= 1'b0;
    end
    else
    begin
/* the write strobe lasts one clock */
        we <= 1'b0;
        case (state)
            S_CS:
            begin
/* chip select, then a pause */
                f_ncs <= 1'b0;
                if (div_cnt == DIV - 1)
                begin
                    div_cnt <= 8'd0;
/* the READ command with the area's address */
                    sh_out  <= {FLASH_READ, ROM_AREAS[24 * area +: 24]};
                    bit_cnt <= CMD_BITS;
                    f_mosi  <= 1'b0;
/* the first byte is the tag's */
                    idx     <= 6'd0;
                    ok      <= 1'b1;
                    state   <= S_CMD;
                end
                else
                begin
/* the pause runs */
                    div_cnt <= div_cnt + 8'd1;
                end
            end

/* bit engine: low phase (MOSI = next bit), high phase, sample */
            S_CMD, S_DATA:
            begin
                if (div_cnt == DIV - 1)
                begin
                    div_cnt <= 8'd0;
/* the clock's two phases */
                    if (!hi)
                    begin
/* rising edge */
                        f_dclk <= 1'b1;
                        hi     <= 1'b1;
                    end
                    else
                    begin
/* falling edge: sample, shift, the next bit out */
                        f_dclk  <= 1'b0;
                        hi      <= 1'b0;
                        sh_in   <= got;
/* the shift register moves on */
                        sh_out  <= {sh_out[30:0], 1'b0};
                        f_mosi  <= sh_out[30];
                        bit_cnt <= bit_cnt - 6'd1;
/* the last bit */
                        if (bit_cnt == 6'd1)
                        begin
                            bit_cnt <= BYTE_BITS;
                            if (state == S_CMD)
                            begin
/* the command is out: data bytes follow */
                                f_mosi <= 1'b0;
                                state  <= S_DATA;
                            end
                            else
                            begin
/* a byte: the tag's two, or a character of the line */
                                idx <= idx + 6'd1;
                                if ((idx == 6'd0 && got != TAG_0) || (idx == 6'd1 && got != TAG_1))
                                begin
                                    ok <= 1'b0;
                                end
/* the bytes behind the tag's place are the line */
                                if (idx >= NAME_OFF)
                                begin
/* into the name RAM: the line, or "(empty)" */
                                    we    <= 1'b1;
                                    waddr <= {area, NAME_COL + npos[4:0]};
                                    wdata <= ok ? chr : empty_chr(npos);
                                end
/* the line's last character */
                                if (idx == NAME_END)
                                begin
/* the position is read */
                                    f_ncs <= 1'b1;
                                    valid[area] <= ok;
                                    state <= S_GAP;
                                end
                            end
                        end
                    end
                end
                else
                begin
/* inside a half period */
                    div_cnt <= div_cnt + 8'd1;
                end
            end

/* chip select off for a half period, then the next position */
            S_GAP:
            begin
                if (div_cnt == DIV - 1)
                begin
                    div_cnt <= 8'd0;
/* the last position ends the reading */
                    if (area == N_AREAS - 1)
                    begin
                        state <= S_END;
                    end
                    else
                    begin
/* the next position */
                        area  <= area + 2'd1;
                        state <= S_CS;
                    end
                end
                else
                begin
                    div_cnt <= div_cnt + 8'd1;
                end
            end

/* all positions: the flash stays released */
            default:
            begin
                f_ncs <= 1'b1;
                done  <= 1'b1;
            end
        endcase
    end

endmodule

/* the default again */
`default_nettype wire
