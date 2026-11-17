/* nes_mapper -- LNES: the cartridge's bank switching (our own design, from the NESdev documentation) */
/* */
/* Mappers (the number in the .nes header): */
/* 0  NROM        nothing switched */
/* 1  MMC1        serial register: 16 KB program banks, 4 KB pattern banks, mirroring */
/* 2  UxROM       16 KB program bank at $8000, the last one fixed at $C000 */
/* 3  CNROM       8 KB pattern bank */
/* 4  MMC3        8 KB program banks, 1 KB pattern banks, mirroring, line counter interrupt */
/* 7  AxROM       32 KB program bank, one-screen mirroring */
/* 11 Color Dreams, 66 GxROM   32 KB program bank + 8 KB pattern bank */
/* */
/* Outputs: for each of the four 8 KB parts of $8000-$FFFF the program bank (prg_bank, 4 x 7 bits, */
/* part 0 in the low bits), for each of the eight 1 KB parts of the pattern memory the bank */
/* (chr_bank, 8 x 9 bits), both already cut to the cartridge's size (prg_mask, chr_mask), and the */
/* name table layout for the PPU (mirror: 0 horizontal, 1 vertical, 2 / 3 one screen, 4 four screens). */
/* we = one clk: the CPU writes d to address {1, a} ($8000-$FFFF); cyc = the end of a CPU cycle, */
/* cyc_we = that cycle was a write (MMC1 ignores the second of two writes in a row). */
/* MMC3's counter: clocked by a rise of the PPU's address line 12 after it was low for three CPU */
/* cycle ends. */
`default_nettype none

module nes_mapper (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [7:0]  mapper,
    input  wire [6:0]  prg_mask,
    input  wire [8:0]  chr_mask,
/* header: vertical mirroring, four screens */
    input  wire        hdr_vert,
    input  wire        hdr_four,

    input  wire        we,
    input  wire [14:0] a,
    input  wire [7:0]  d,
    input  wire        cyc,
    input  wire        cyc_we,
    input  wire        a12,

    output wire [27:0] prg_bank,
    output wire [71:0] chr_bank,
    output reg  [2:0]  mirror,
    output wire        irq
);

/* mapper numbers */
localparam [7:0] M_MMC1 = 8'd1;
localparam [7:0] M_UXROM = 8'd2;
localparam [7:0] M_CNROM = 8'd3;
/* the mappers with registers of their own */
localparam [7:0] M_MMC3 = 8'd4;
localparam [7:0] M_AXROM = 8'd7;
localparam [7:0] M_COLOR = 8'd11;
/* the two mappers with a 32 KB program bank and an 8 KB pattern bank */
localparam [7:0] M_GXROM = 8'd66;
/* mirror codes for the PPU */
localparam [2:0] MIR_H = 3'd0;
localparam [2:0] MIR_V = 3'd1;
localparam [2:0] MIR_A = 3'd2;
/* one screen, four screens */
localparam [2:0] MIR_B = 3'd3;
localparam [2:0] MIR_4 = 3'd4;
/* MMC1: the control register after reset (program mode 3) */
localparam [4:0] MMC1_RESET = 5'h0C;
/* MMC1: the bit that marks the fifth write in the shift register */
localparam [4:0] MMC1_EMPTY = 5'h10;
/* MMC3: CPU cycle ends with line 12 low before a rise counts */
localparam [1:0] A12_LOW_MIN = 2'd3;
/* MMC3 registers of the pattern banks */
localparam [2:0] R_CHR2 = 3'd2;
localparam [2:0] R_CHR3 = 3'd3;
localparam [2:0] R_CHR4 = 3'd4;
/* the program banks' registers */
localparam [2:0] R_CHR5 = 3'd5;
localparam [2:0] R_PRG6 = 3'd6;
localparam [2:0] R_PRG7 = 3'd7;
/* the 8 KB parts of the program area and the 1 KB parts of the pattern memory */
localparam integer PRG_PARTS = 4;
localparam integer CHR_PARTS = 8;
/* the second last program bank (cut to the cartridge's size by the mask) */
localparam [6:0] BANK_2ND_LAST = 7'h7E;

integer i;

/* the simple mappers' one register */
reg  [7:0] sreg;
/* MMC1 */
reg  [4:0] m1_sh, m1_ctl, m1_chr0, m1_chr1, m1_prg;
reg        prev_we;
/* MMC3 */
reg  [7:0] m3_sel, m3_latch, m3_cnt;
reg  [7:0] m3_r [0:7];
reg        m3_mir, m3_rl, m3_en, m3_irq;
/* line 12 of the PPU's address: low time, previous level */
reg  [1:0] a12_low;
reg        a12_d;

assign irq = m3_irq;

/* the 8 KB program banks and the 1 KB pattern banks before masking */
reg  [6:0] pb [0:3];
reg  [8:0] cb [0:7];
/* MMC1: 16 KB banks of the two halves, 4 KB pattern banks */
reg  [4:0] m1_lo, m1_hi;
reg  [4:0] m1_c0, m1_c1;
always @*
begin
/* MMC1's program modes */
    case (m1_ctl[3:2])
        2'b00, 2'b01:
        begin
            m1_lo = {m1_chr0[4], m1_prg[3:1], 1'b0};
/* the upper half of the 32 KB bank */
            m1_hi = {m1_chr0[4], m1_prg[3:1], 1'b1};
        end
        2'b10:
        begin
            m1_lo = {m1_chr0[4], 4'h0};
/* the bank at $C000 is switched */
            m1_hi = {m1_chr0[4], m1_prg[3:0]};
        end
        default:
        begin
            m1_lo = {m1_chr0[4], m1_prg[3:0]};
/* the bank at $C000 is the last one */
            m1_hi = {m1_chr0[4], 4'hF};
        end
    endcase
/* MMC1's pattern modes: one 8 KB bank or two of 4 KB */
    m1_c0 = m1_ctl[4] ? m1_chr0 : {m1_chr0[4:1], 1'b0};
    m1_c1 = m1_ctl[4] ? m1_chr1 : {m1_chr0[4:1], 1'b1};

/* NROM: everything in order */
    for (i = 0; i < PRG_PARTS; i = i + 1)
    begin
        pb[i] = i[6:0];
    end
    for (i = 0; i < CHR_PARTS; i = i + 1)
    begin
/* the 1 KB parts in order */
        cb[i] = i[8:0];
    end
    mirror = hdr_four ? MIR_4 : hdr_vert ? MIR_V : MIR_H;

    case (mapper)
/* MMC1: its four 8 KB parts and eight 1 KB parts */
        M_MMC1:
        begin
            pb[0] = {1'b0, m1_lo, 1'b0};
            pb[1] = {1'b0, m1_lo, 1'b1};
/* the upper 16 KB */
            pb[2] = {1'b0, m1_hi, 1'b0};
            pb[3] = {1'b0, m1_hi, 1'b1};
/* four 1 KB parts per 4 KB bank */
            for (i = 0; i < PRG_PARTS; i = i + 1)
            begin
                cb[i]     = {2'b00, m1_c0, i[1:0]};
                cb[i + 4] = {2'b00, m1_c1, i[1:0]};
            end
/* MMC1's mirroring */
            case (m1_ctl[1:0])
                2'b00:   mirror = MIR_A;
                2'b01:   mirror = MIR_B;
/* by the header's layout: vertical or horizontal */
                2'b10:   mirror = MIR_V;
                default: mirror = MIR_H;
            endcase
        end
        M_UXROM:
        begin
/* UxROM: the switched bank */
            pb[0] = {sreg[5:0], 1'b0};
            pb[1] = {sreg[5:0], 1'b1};
            pb[2] = BANK_2ND_LAST;
/* the last 8 KB */
            pb[3] = 7'h7F;
        end
        M_CNROM:
        begin
            for (i = 0; i < CHR_PARTS; i = i + 1)
            begin
/* CNROM: one 8 KB pattern bank */
                cb[i] = {sreg[5:0], i[2:0]};
            end
        end
        M_MMC3:
        begin
/* program: R6 and the second last bank change places with bit 6 */
            pb[0] = m3_sel[6] ? BANK_2ND_LAST : m3_r[R_PRG6][6:0];
            pb[1] = m3_r[R_PRG7][6:0];
            pb[2] = m3_sel[6] ? m3_r[R_PRG6][6:0] : BANK_2ND_LAST;
/* the last bank */
            pb[3] = 7'h7F;
/* patterns: two 2 KB and four 1 KB banks, the halves swapped by bit 7 */
            cb[{m3_sel[7], 2'b00}]  = {1'b0, m3_r[0][7:1], 1'b0};
            cb[{m3_sel[7], 2'b01}]  = {1'b0, m3_r[0][7:1], 1'b1};
            cb[{m3_sel[7], 2'b10}]  = {1'b0, m3_r[1][7:1], 1'b0};
/* the second 2 KB bank */
            cb[{m3_sel[7], 2'b11}]  = {1'b0, m3_r[1][7:1], 1'b1};
            cb[{!m3_sel[7], 2'b00}] = {1'b0, m3_r[R_CHR2]};
            cb[{!m3_sel[7], 2'b01}] = {1'b0, m3_r[R_CHR3]};
/* the four 1 KB banks */
            cb[{!m3_sel[7], 2'b10}] = {1'b0, m3_r[R_CHR4]};
            cb[{!m3_sel[7], 2'b11}] = {1'b0, m3_r[R_CHR5]};
            mirror = hdr_four ? MIR_4 : m3_mir ? MIR_H : MIR_V;
        end
/* AxROM: one 32 KB bank, one screen */
        M_AXROM:
        begin
            for (i = 0; i < PRG_PARTS; i = i + 1)
            begin
                pb[i] = {2'b00, sreg[2:0], i[1:0]};
            end
/* the screen comes from bit 4 */
            mirror = sreg[4] ? MIR_B : MIR_A;
        end
        M_COLOR:
        begin
            for (i = 0; i < PRG_PARTS; i = i + 1)
            begin
/* Color Dreams: bits 1:0 program, bits 7:4 patterns */
                pb[i] = {3'b000, sreg[1:0], i[1:0]};
            end
            for (i = 0; i < CHR_PARTS; i = i + 1)
            begin
                cb[i] = {2'b00, sreg[7:4], i[2:0]};
            end
        end
/* GxROM: bits 5:4 program, bits 1:0 patterns */
        M_GXROM:
        begin
            for (i = 0; i < PRG_PARTS; i = i + 1)
            begin
                pb[i] = {3'b000, sreg[5:4], i[1:0]};
            end
/* its 8 KB pattern bank */
            for (i = 0; i < CHR_PARTS; i = i + 1)
            begin
                cb[i] = {4'b0000, sreg[1:0], i[2:0]};
            end
        end
        default: ;
    endcase
end

/* cut to the cartridge's size */
genvar g;
generate
    for (g = 0; g < PRG_PARTS; g = g + 1)
    begin : g_prg
        assign prg_bank[g * 7 +: 7] = pb[g] & prg_mask;
    end
/* the eight pattern parts */
    for (g = 0; g < CHR_PARTS; g = g + 1)
    begin : g_chr
        assign chr_bank[g * 9 +: 9] = cb[g] & chr_mask;
    end
endgenerate

/* the registers */
always @(posedge clk or negedge rst_n)
    if (!rst_n)
    begin
        sreg <= 8'd0;
/* MMC1 as after power-up */
        m1_sh <= MMC1_EMPTY;
        m1_ctl <= MMC1_RESET;
        m1_chr0 <= 5'd0;
/* the second pattern register, the program register */
        m1_chr1 <= 5'd0;
        m1_prg <= 5'd0;
        prev_we <= 1'b0;
/* MMC3 */
        m3_sel <= 8'd0;
        m3_latch <= 8'd0;
        m3_cnt <= 8'd0;
/* no mirroring bit, no reload, interrupt off */
        m3_mir <= 1'b0;
        m3_rl <= 1'b0;
        m3_en <= 1'b0;
/* no interrupt */
        m3_irq <= 1'b0;
        a12_low <= 2'd0;
        a12_d <= 1'b0;
/* the bank registers */
        for (i = 0; i < CHR_PARTS; i = i + 1)
        begin
            m3_r[i] <= 8'd0;
        end
/* program banks 0 and 1 in R6 / R7 at the start */
        m3_r[R_PRG7] <= 8'd1;
    end
    else
    begin
        if (cyc)
        begin
            prev_we <= cyc_we;
        end

/* MMC3's line counter */
        a12_d <= a12;
        if (a12)
        begin
            a12_low <= 2'd0;
        end
/* a CPU cycle with line 12 low */
        else if (cyc && a12_low != A12_LOW_MIN)
        begin
            a12_low <= a12_low + 2'd1;
        end
        if (a12 && !a12_d && a12_low == A12_LOW_MIN)
        begin
/* the counter is loaded again at 0 or when asked */
            if (m3_cnt == 8'd0 || m3_rl)
            begin
                m3_cnt <= m3_latch;
                m3_rl  <= 1'b0;
/* reloaded with 0: the interrupt comes at once */
                if (m3_latch == 8'd0 && m3_en)
                begin
                    m3_irq <= 1'b1;
                end
            end
            else
            begin
                m3_cnt <= m3_cnt - 8'd1;
/* the counter reaches 0: the interrupt */
                if (m3_cnt == 8'd1 && m3_en)
                begin
                    m3_irq <= 1'b1;
                end
            end
        end

        if (we)
        begin
/* the simple mappers take every write */
            sreg <= d;
/* MMC1: bit 7 resets, else five writes fill a register */
            if (mapper == M_MMC1 && !prev_we)
            begin
                if (d[7])
                begin
                    m1_sh  <= MMC1_EMPTY;
/* a write with bit 7 set */
                    m1_ctl <= m1_ctl | MMC1_RESET;
                end
                else if (m1_sh[0])
                begin
                    m1_sh <= MMC1_EMPTY;
/* the address picks the register */
                    case (a[14:13])
                        2'b00:   m1_ctl  <= {d[0], m1_sh[4:1]};
                        2'b01:   m1_chr0 <= {d[0], m1_sh[4:1]};
/* the second pattern bank */
                        2'b10:   m1_chr1 <= {d[0], m1_sh[4:1]};
                        default: m1_prg  <= {d[0], m1_sh[4:1]};
                    endcase
                end
                else
                begin
                    m1_sh <= {d[0], m1_sh[4:1]};
                end
            end
/* MMC3: four register pairs, even and odd addresses */
            if (mapper == M_MMC3)
            begin
                case ({a[14:13], a[0]})
                    3'b000: m3_sel <= d;
/* the register chosen before */
                    3'b001: m3_r[m3_sel[2:0]] <= d;
                    3'b010: m3_mir <= d[0];
                    3'b011: ;
/* the counter's reload value */
                    3'b100: m3_latch <= d;
                    3'b101: m3_rl <= 1'b1;
/* interrupt off (and acknowledged), on */
                    3'b110:
                    begin
                        m3_en  <= 1'b0;
                        m3_irq <= 1'b0;
                    end
/* the interrupt on */
                    default: m3_en <= 1'b1;
                endcase
            end
        end
    end

endmodule

`default_nettype wire
