/* esp_link -- SPI slave for the ESP32 system controller: the master of the */
/* tape loader's register bus (register offsets in tape_loader.v). */
/* */
/* SPI mode 0, MSB first, ESP32 = master. SCK, MOSI and CS_N are synchronised */
/* to clk (56 MHz LSpectrum, 94.5 MHz L64) and SCK is oversampled, so SCK */
/* high and low must each last >= 3 clocks: SCK <= 8 MHz. MOSI goes through the */
/* same two flip-flops as SCK (its value at the rising edge is taken). MISO */
/* changes 2-3 clocks after a falling edge (and after CS_N falls), so each bit */
/* is stable from just after one falling edge to just after the next: the ESP32 */
/* samples MISO late, near the falling edge that ends the bit (its GPIO-matrix */
/* input; changing MISO after the rising edge gave bit errors / a 1-bit shift). */
/* Leave >= 100 ns between CS_N falling and the first SCK edge. */
/* After a reset the first frame is the one whose CS_N falling edge comes after CS_N was seen */
/* high (a frame running while the FPGA starts is ignored). */
/* */
/* A frame (CS_N low) is one command byte and its arguments. Byte n of the */
/* frame is numbered from 0 (the command). The FPGA sends status bytes */
/* {error, 7'd0} except where data is returned. */
/* 01 WR   r, d3 d2 d1 d0        write the register at byte offset r (0x00-0x3C) */
/* 02 RD   r, x, -> d3 d2 d1 d0  read register r (x = dummy byte) */
/* 03 OSD  a1 a0, b...           OSD text bytes from a (0-767), auto-increment */
/* 04 FIFO (d3 d2 d1 d0)...      push player commands */
/* 05 MWR  a2 a1 a0, b...        Spectrum memory writes from a (18 bits), auto-increment */
/* 06 MRD  a2 a1 a0, x, -> b...  Spectrum memory reads, auto-increment (prefetched) */
/* 07 STAT x, -> d3 d2 d1 d0     {error, 31'd0}; reading clears the error flag */
/* 08 FLS  b..., -> -, -, r...   flash stream: each byte b goes out on the configuration flash */
/* (FLASH register 0x40 with EN | CS | START); the byte the flash */
/* returned for frame byte n comes back in frame byte n + 2 */
/* (so a read ends with two extra bytes). The shift must end */
/* within a byte time (tape_loader FL_HALF). Only with parameter */
/* FLS = 1 (the machine menu); otherwise ignored */
/* MWR/MRD need the Spectrum frozen (SNAPCTL). Each memory byte is one snapshot */
/* command (well under the 1 us a byte takes at 8 MHz). The error flag is set */
/* when a byte arrives while the previous access is still running (it is */
/* dropped) or when an MRD / FLS byte is not ready in time (0xEE is sent). */
`default_nettype none

module esp_link #(
/* 1: the FLS frame (the machine menu only) */
    parameter FLS = 0
) (
    input  wire        clk,
    input  wire        rst_n,

/* asynchronous pins */
    input  wire        sck,
    input  wire        mosi,
    input  wire        cs_n,
    output wire        miso,

/* register bus (valid held until ready) */
    output reg         mem_valid,
    output reg  [31:0] mem_addr,
    output reg  [31:0] mem_wdata,
    output reg  [3:0]  mem_wstrb,
    input  wire        mem_ready,
    input  wire [31:0] mem_rdata
);

/* RD frame: byte count before its first data byte goes out */
localparam [3:0] RD_FIRST = 4'd2;
/* RD frame: byte count before its last data byte */
localparam [3:0] RD_LAST = 4'd5;
/* STAT frame: byte count before its last data byte */
localparam [3:0] STAT_LAST = 4'd4;
/* MRD frame: byte count from which memory bytes go out */
localparam [3:0] MRD_FIRST = 4'd4;
/* sent in place of a byte that was not fetched in time */
localparam [7:0] NOT_READY = 8'hEE;
/* FLS frame: byte count from which the flash's bytes go out */
localparam [3:0] FLS_FIRST = 4'd2;
/* WR frame: its last byte (register + 4 data bytes) */
localparam [3:0] WR_LAST = 4'd5;
/* OSD frame: the byte that completes the address */
localparam [3:0] OSD_ADDR_END = 4'd2;
/* OSD frame: characters from this byte on */
localparam [3:0] OSD_DATA = 4'd3;
/* bytes of a word: the byte is copied into all four lanes */
localparam integer WORD_BYTES = 4;
/* MWR frame: the byte that completes the address */
localparam [3:0] MWR_ADDR_END = 4'd3;
/* MWR frame: data from this byte on */
localparam [3:0] MWR_DATA = 4'd4;
/* MRD frame: the byte that completes the address */
localparam [3:0] MRD_ADDR_END = 4'd3;
/* memory job step: wait for the snapshot port's answer */
localparam [1:0] STEP_POLL = 2'd2;

localparam [7:0] CMD_WR = 8'h01, CMD_RD = 8'h02, CMD_OSD = 8'h03, CMD_FIFO = 8'h04,
                 CMD_MWR = 8'h05, CMD_MRD = 8'h06, CMD_STAT = 8'h07, CMD_FLS = 8'h08;
/* address spaces and registers of the tape loader */
localparam [31:0] IO = 32'h1000_0000, OSD = 32'h2000_0000;
localparam [7:0]  R_FIFO = 8'h0C, R_SNAPCTL = 8'h2C, R_SNAPCMD = 8'h30, R_SNAPDAT = 8'h34, R_FLASH = 8'h40;
localparam [3:0]  C_MRD = 4'd1, C_MWR = 4'd2;

/* Pins */
reg [2:0] sck_s, cs_s;
reg [1:0] mosi_s;
always @(posedge clk)
begin
/* two or three stages */
    sck_s  <= {sck_s[1:0], sck};
    cs_s   <= {cs_s[1:0], cs_n};
    mosi_s <= {mosi_s[0], mosi};
end
/* the clock's edges */
wire rise   = sck_s[1] && !sck_s[2];
wire fall   = !sck_s[1] && sck_s[2];
/* CS_N was high since the reset: a transfer the */
reg  armed;
/* ESP32 began before (FPGA starting) is not decoded */
wire active = !cs_s[1] && armed;
/* CS_N fell */
wire start  = cs_s[2] && !cs_s[1] && armed;

/* State */
reg  [7:0]  rx_sh, tx_sh;
reg  [2:0]  bitn;
/* rx_sh holds byte nb (one clock) */
reg         rx_stb;
/* number of the byte being received (saturates at 15) */
reg  [3:0]  nb;
reg  [7:0]  cmd;
/* previous argument bytes */
reg  [31:0] acc;
reg  [17:0] addr;
/* FIFO: byte within the word */
reg  [1:0]  gb;
/* RD / STAT result */
reg  [31:0] rd_word;
reg         err;
/* the pin (I/O register): tx_sh[7] taken at each falling edge */
reg         miso_q;
assign miso = miso_q;

/* bus jobs */
localparam [1:0] J_ONE = 2'd0, J_MWR = 2'd1, J_MRD = 2'd2, J_FLS = 2'd3;
/* a job is running */
reg         busy;
reg  [1:0]  job, step;
/* next: read SNAPCTL */
reg         poll;
reg  [17:0] job_a;
/* mrd_b holds the prefetched byte (MRD) / the flash's byte (FLS) */
reg         mrd_ok;
reg  [7:0]  mrd_b;

/* byte sent after the one ending now (that is byte nb + 1; nb saturates, so compare nb) */
reg  [7:0] tx_next;
/* that byte is MRD data */
reg        tx_mrd;
/* that byte is FLS data */
reg        tx_fls;
always @*
begin
    tx_next = {err, 7'd0};
/* not a memory or flash byte; by command */
    tx_mrd  = 1'b0;
    tx_fls  = 1'b0;
    case (cmd)
/* bytes 3-6 */
        CMD_RD:
            if (nb >= RD_FIRST && nb <= RD_LAST)
            begin
                tx_next = rd_word[8 * (5 - nb) +: 8];
            end
/* bytes 2-5 */
        CMD_STAT:
            if (nb >= 4'd1 && nb <= STAT_LAST)
            begin
                tx_next = rd_word[8 * (4 - nb) +: 8];
            end
/* bytes 5- */
        CMD_MRD:
            if (nb >= MRD_FIRST)
            begin
/* the byte fetched, or EE if it was not ready */
                tx_mrd = 1'b1;
                tx_next = mrd_ok ? mrd_b : NOT_READY;
            end
/* bytes 3- */
        CMD_FLS:
            if (FLS && nb >= FLS_FIRST)
            begin
/* the flash's byte, or EE */
                tx_fls = 1'b1;
                tx_next = mrd_ok ? mrd_b : NOT_READY;
            end
        default: ;
    endcase
/* cmd is not known yet */
    if (nb == 4'd0)
    begin
        tx_next = {err, 7'd0};
    end
end

/* the link */
always @(posedge clk or negedge rst_n)
    if (!rst_n)
    begin
        armed <= 1'b0;
/* shift registers */
        rx_sh <= 8'd0;
        tx_sh <= 8'd0;
        miso_q <= 1'b0;
/* bit and byte counters */
        bitn <= 3'd0;
        rx_stb <= 1'b0;
        nb <= 4'd0;
/* command, the bytes so far, the address */
        cmd <= 8'd0;
        acc <= 32'd0;
        addr <= 18'd0;
/* word byte counter, read data, error flag */
        gb <= 2'd0;
        rd_word <= 32'd0;
        err <= 1'b0;
/* no job */
        busy <= 1'b0;
        job <= J_ONE;
        step <= 2'd0;
/* no poll, no memory byte */
        poll <= 1'b0;
        job_a <= 18'd0;
        mrd_ok <= 1'b0;
/* the register bus idle */
        mrd_b <= 8'd0;
        mem_valid <= 1'b0;
        mem_addr <= 32'd0;
/* no write */
        mem_wdata <= 32'd0;
        mem_wstrb <= 4'd0;
    end
    else
    begin
        rx_stb <= 1'b0;
/* armed once chip select was seen high */
        if (cs_s[1])
        begin
            armed <= 1'b1;
        end

/* SPI shift */
        if (!active)
        begin
            bitn <= 3'd0;
            nb   <= 4'd0;
/* no command; a frame starts */
            cmd  <= 8'd0;
        end
        else if (start)
        begin
            bitn  <= 3'd0;
/* the first byte out is the status */
            nb    <= 4'd0;
            cmd   <= 8'd0;
            tx_sh  <= {err, 7'd0};
/* a falling clock: the next bit out */
            miso_q <= err;
        end
        else if (fall)
        begin
            miso_q <= tx_sh[7];
        end
/* a rising clock: the next bit in */
        else if (rise)
        begin
            rx_sh <= {rx_sh[6:0], mosi_s[1]};
            bitn  <= bitn + 3'd1;
/* a whole byte */
            if (bitn == 3'd7)
            begin
                rx_stb <= 1'b1;
                tx_sh  <= tx_next;
/* MRD byte handed out: fetch the next one */
                if (tx_mrd)
                begin
                    if (!mrd_ok)
                    begin
                        err <= 1'b1;
                    end
/* the byte is used up */
                    mrd_ok <= 1'b0;
                    if (!busy)
                    begin
                        busy <= 1'b1;
/* the snapshot port's read command for the next address */
                        job <= J_MRD;
                        step <= 2'd0;
                        job_a <= addr;
/* the command register */
                        mem_valid <= 1'b1;
                        mem_addr <= IO | R_SNAPCMD;
                        mem_wdata <= {C_MRD, 10'd0, addr};
/* all four bytes; the address after it */
                        mem_wstrb <= 4'hF;
                        addr <= addr + 18'd1;
                    end
                end
/* the flash's byte handed out */
                if (tx_fls)
                begin
                    if (!mrd_ok)
                    begin
                        err <= 1'b1;
                    end
/* used up; inside a byte the next bit goes out */
                    mrd_ok <= 1'b0;
                end
            end
            else
            begin
                tx_sh <= {tx_sh[6:0], 1'b0};
            end
        end

/* received bytes */
        if (rx_stb)
        begin
            if (nb != 4'd15)
            begin
                nb <= nb + 4'd1;
            end
/* the last four bytes */
            acc <= {acc[23:0], rx_sh};
            if (nb == 4'd0)
            begin
                cmd <= rx_sh;
/* STAT: the error flag, read and cleared */
                gb  <= 2'd0;
                if (rx_sh == CMD_STAT)
                begin
/* the flag goes out and is cleared */
                    rd_word <= {err, 31'd0};
                    err     <= 1'b0;
                end
            end
            else
            begin
/* the later bytes, by command */
                case (cmd)
/* a register write: 4 data bytes */
                    CMD_WR:
                        if (nb == WR_LAST)
                        begin
                            if (busy)
                            begin
/* a register write while another is under way is an error */
                                err <= 1'b1;
                            end
                            else
                            begin
                                busy <= 1'b1;
                                job <= J_ONE;
/* the register */
                                mem_valid <= 1'b1;
                                mem_addr <= IO | acc[31:24];
/* its data */
                                mem_wdata <= {acc[23:0], rx_sh};
                                mem_wstrb <= 4'hF;
                            end
                        end
/* read during the dummy byte */
                    CMD_RD:
                        if (nb == 4'd1)
                        begin
                            if (busy)
                            begin
/* busy: an error */
                                err <= 1'b1;
                            end
                            else
                            begin
                                busy <= 1'b1;
                                job <= J_ONE;
/* the register's read */
                                mem_valid <= 1'b1;
                                mem_addr <= IO | rx_sh;
                                mem_wstrb <= 4'h0;
                            end
                        end
/* OSD text: an address, then characters */
                    CMD_OSD:
                    begin
                        if (nb == OSD_ADDR_END)
                        begin
                            addr <= {8'd0, acc[7:0], rx_sh};
                        end
/* each byte is one character */
                        if (nb >= OSD_DATA)
                        begin
                            if (busy)
                            begin
                                err <= 1'b1;
                            end
                            else
                            begin
/* a byte write into the OSD's memory */
                                busy <= 1'b1;
                                job <= J_ONE;
                                mem_valid <= 1'b1;
/* at the address, in the right byte lane */
                                mem_addr <= OSD | addr[9:0];
                                mem_wdata <= {WORD_BYTES{rx_sh}};
                                mem_wstrb <= 4'b0001 << addr[1:0];
                            end
/* the next cell */
                            addr <= addr + 18'd1;
                        end
                    end
/* pulse commands for the FIFO */
                    CMD_FIFO:
                    begin
                        gb <= gb + 2'd1;
                        if (gb == 2'd3)
                        begin
/* four bytes are one command */
                            if (busy)
                            begin
                                err <= 1'b1;
                            end
                            else
                            begin
                                busy <= 1'b1;
/* pushed into the FIFO */
                                job <= J_ONE;
                                mem_valid <= 1'b1;
                                mem_addr <= IO | R_FIFO;
/* the word */
                                mem_wdata <= {acc[23:0], rx_sh};
                                mem_wstrb <= 4'hF;
                            end
                        end
                    end
/* memory write: an address, then bytes */
                    CMD_MWR:
                    begin
                        if (nb == MWR_ADDR_END)
                        begin
                            addr <= {acc[9:0], rx_sh};
                        end
/* each byte is written through the snapshot port */
                        if (nb >= MWR_DATA)
                        begin
                            if (busy)
                            begin
                                err <= 1'b1;
                            end
                            else
                            begin
/* data first, then the command */
                                busy <= 1'b1;
                                job <= J_MWR;
                                step <= 2'd0;
/* its address */
                                job_a <= addr;
                                mem_valid <= 1'b1;
                                mem_addr <= IO | R_SNAPDAT;
/* the byte; the next address */
                                mem_wdata <= {24'd0, rx_sh};
                                mem_wstrb <= 4'hF;
                            end
                            addr <= addr + 18'd1;
                        end
                    end
/* every byte: out on the flash */
                    CMD_FLS:
                        if (FLS)
                        begin
                            if (nb == 4'd1)
                            begin
/* no byte back yet */
                                mrd_ok <= 1'b0;
                            end
                            if (busy)
                            begin
                                err <= 1'b1;
                            end
                            else
                            begin
/* one byte through the flash register */
                                busy <= 1'b1;
                                job <= J_FLS;
                                step <= 2'd0;
/* the register */
                                mem_valid <= 1'b1;
                                mem_addr <= IO | R_FLASH;
/* start, chip select, enable, and the byte */
                                mem_wdata <= {21'd0, 3'b111, rx_sh};
                                mem_wstrb <= 4'hF;
                            end
                        end
/* address complete: fetch the first byte */
                    CMD_MRD:
                        if (nb == MRD_ADDR_END)
                        begin
                            mrd_ok <= 1'b0;
/* busy: an error */
                            if (busy)
                            begin
                                err <= 1'b1;
                            end
                            else
                            begin
                                busy <= 1'b1;
/* the read command for that address */
                                job <= J_MRD;
                                step <= 2'd0;
                                job_a <= {acc[9:0], rx_sh};
/* the command register */
                                mem_valid <= 1'b1;
                                mem_addr <= IO | R_SNAPCMD;
                                mem_wdata <= {C_MRD, 10'd0, acc[9:0], rx_sh};
/* then the next address */
                                mem_wstrb <= 4'hF;
                            end
                            addr <= {acc[9:0], rx_sh} + 18'd1;
                        end
                    default: ;
                endcase
            end
        end

/* bus jobs */
/* read SNAPCTL ([1] = command busy) */
        if (poll)
        begin
            poll <= 1'b0;
            mem_valid <= 1'b1;
/* a read */
            mem_addr <= IO | R_SNAPCTL;
            mem_wstrb <= 4'h0;
        end
        else if (mem_valid && mem_ready)
        begin
/* an access is done */
            mem_valid <= 1'b0;
            case (job)
                J_ONE:
                begin
/* a register read's data */
                    if (cmd == CMD_RD)
                    begin
                        rd_word <= mem_rdata;
                    end
                    busy <= 1'b0;
                end
/* a memory write */
                J_MWR:
                    case (step)
/* data written: start the command */
                        2'd0:
                        begin
                            step <= 2'd1;
                            mem_valid <= 1'b1;
/* the write command with the address */
                            mem_addr <= IO | R_SNAPCMD;
                            mem_wdata <= {C_MWR, 10'd0, job_a};
                            mem_wstrb <= 4'hF;
                        end
/* command written: poll */
                        2'd1:
                        begin
                            step <= STEP_POLL;
                            poll <= 1'b1;
                        end
/* busy: poll again */
                        default:
                            if (mem_rdata[1])
                            begin
                                poll <= 1'b1;
                            end
                            else
                            begin
/* done */
                                busy <= 1'b0;
                            end
                    endcase
/* a memory read */
                J_MRD:
                    case (step)
                        2'd0:
                        begin
/* command written: poll */
                            step <= 2'd1;
                            poll <= 1'b1;
                        end
                        2'd1:
/* busy: poll again */
                            if (mem_rdata[1])
                            begin
                                poll <= 1'b1;
                            end
                            else
                            begin
/* done: read the data register */
                                step <= STEP_POLL;
                                mem_valid <= 1'b1;
                                mem_addr <= IO | R_SNAPDAT;
/* a read; then the byte */
                                mem_wstrb <= 4'h0;
                            end
                        default:
                        begin
                            mrd_b  <= mem_rdata[7:0];
/* ready for the frame */
                            mrd_ok <= 1'b1;
                            busy   <= 1'b0;
                        end
                    endcase
/* byte started: read FLASH until it is shifted */
                J_FLS:
                    if (step == 2'd0)
                    begin
                        step <= 2'd1;
/* read the flash register */
                        mem_valid <= 1'b1;
                        mem_addr <= IO | R_FLASH;
                        mem_wstrb <= 4'h0;
                    end
/* still shifting */
                    else if (mem_rdata[8])
                    begin
                        mem_valid <= 1'b1;
                        mem_addr <= IO | R_FLASH;
/* a read; then the flash's byte */
                        mem_wstrb <= 4'h0;
                    end
                    else
                    begin
                        mrd_b  <= mem_rdata[7:0];
                        mrd_ok <= 1'b1;
/* done */
                        busy   <= 1'b0;
                    end
                default: busy <= 1'b0;
            endcase
        end
    end

endmodule

`default_nettype wire
