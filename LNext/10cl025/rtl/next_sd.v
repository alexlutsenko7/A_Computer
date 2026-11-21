/* next_sd -- LNext: the Spectrum Next's SD card. The real card is on the ESP32, so the core */
/* talks (SPI) to an SD card made of logic (ZXNEXT/sys/sd_card.sv, from the MiSTer framework) */
/* and the ESP32 moves 512-byte sectors between that card's buffer and the real one */
/* (ESP32/vN/src/next.cpp), through the tape loader's machine word and memory commands: */
/*   mstat (read by the ESP32):  [31] a sector waits to be written, [30] a sector is wanted, */
/*                               [29:0] its number */
/*   mctl  (written by it):      [0] the ESP32 has the sector buffer, [1] a card is in */
/*   memory commands:            1 MRD read the buffer's byte addr[8:0] -> rdata[7:0] */
/*                               2 MWR write wdata[7:0] there (only while mctl[0] is set) */
/*                               others: done at once, rdata 0 */
/* Commands with ext_sel set are another device's (the screenshot grabber, next_grab.v): they */
/* are answered with ext_rdata, a read after the same two clocks; ext_stb marks one that is */
/* not a read. */
/* A request ends when the ESP32 clears mctl[0]: the card of logic then has the sector for the */
/* core (read) or takes the next one (write). The CPU waits from the request until then (sd_wait). */
/* */
/* Everything here runs in the machine's clock. The loader's signals come from another clock: */
/* mctl goes through synchronisers, a command and its data are held until the answer (snap_ack */
/* follows snap_req), and the ESP32 reads mstat until two readings agree. */
`default_nettype none

module next_sd (
    input  wire        clk,
    input  wire        rst,

/* from / to the tape loader (its clock) */
    input  wire [1:0]  mctl,
/* the card's size in sectors (it does not change while a card is in) */
    input  wire [31:0] sectors,
    output wire [31:0] mstat,
    input  wire        snap_req,
    input  wire [3:0]  snap_cmd,
    input  wire [8:0]  snap_addr,
    input  wire [7:0]  snap_wdata,
    output reg         snap_ack,
    output reg  [31:0] snap_rdata,
/* the command is the other device's; its answer; a command for it that is not a read */
    input  wire        ext_sel,
    input  wire [31:0] ext_rdata,
    output reg         ext_stb,

/* the core's SD card port */
    input  wire        sd_cs_n,
    input  wire        sd_sck,
    input  wire        sd_mosi,
    output wire        sd_miso,
/* the CPU waits: a sector is on its way */
    output reg         sd_wait,
/* a card is in (the machine may run) */
    output wire        card_in
);

/* the machine word: the ESP32 has the sector buffer, a card is in */
localparam integer C_SD_ACK = 0;
localparam integer C_SD_IN = 1;
/* mstat: the sector number's bits */
localparam integer LBA_BITS = 30;
/* memory commands: read, write */
localparam [3:0] SNAP_MRD = 4'd1;
localparam [3:0] SNAP_MWR = 4'd2;
/* a sector's bytes are 512: the bits of the sector count that make it a byte count */
localparam integer SEC_BITS = 9;
/* clocks from the buffer's address to its byte */
localparam [1:0] RD_WAIT = 2'd2;

/* the machine word, synchronised */
reg  [1:0]  ack_s = 2'b00, in_s = 2'b00;
reg         in_q = 1'b0, sd_mount = 1'b0;
always @(posedge clk)
begin
    ack_s    <= {ack_s[0], mctl[C_SD_ACK]};
    in_s     <= {in_s[0], mctl[C_SD_IN]};
/* a card was put in: the card of logic takes its size */
    in_q     <= in_s[1];
    sd_mount <= in_s[1] && !in_q;
end
wire        sd_ack = ack_s[1];
assign      card_in = in_s[1];

wire [31:0] sd_lba;
wire        sd_rd, sd_wr, sd_card_miso;
/* the sector buffer's port */
reg  [8:0]  sd_buff_addr;
reg  [7:0]  sd_buff_dout;
reg         sd_buff_wr;
wire [7:0]  sd_buff_din;

sd_card u_card (
    .clk_sys      (clk),
    .reset        (rst),
    .sdhc         (1'b1),
    .img_mounted  (sd_mount),
    .img_size     ({23'd0, sectors, {SEC_BITS{1'b0}}}),
    .sd_lba       (sd_lba),
    .sd_rd        (sd_rd),
    .sd_wr        (sd_wr),
    .sd_ack       (sd_ack),
    .sd_buff_addr (sd_buff_addr),
    .sd_buff_dout (sd_buff_dout),
    .sd_buff_din  (sd_buff_din),
    .sd_buff_wr   (sd_buff_wr),
    .clk_spi      (clk),
    .ss           (sd_cs_n | !in_s[1]),
    .sck          (sd_sck),
    .mosi         (sd_mosi),
    .miso         (sd_card_miso)
);
/* without a card nothing answers */
assign sd_miso = (!sd_cs_n && in_s[1]) ? sd_card_miso : 1'b1;

/* The CPU waits while a sector is on its way, in either direction: from the request until the */
/* ESP32 gives the buffer back. (The MiSTer port waits for written sectors only; its host */
/* answers within microseconds. Ours takes milliseconds, and a core that went on meanwhile could */
/* send its next read command while a sector read ahead is still coming: the card of logic */
/* would then take that sector for the new command's first one.) */
always @(posedge clk)
    sd_wait <= (sd_wait & sd_ack) | sd_wr | sd_rd;

/* what the ESP32 reads: the request and its sector */
assign mstat = {sd_wr, sd_rd, sd_lba[LBA_BITS-1:0]};

/* the memory commands */
reg  [1:0] sreq_s;
reg  [1:0] rd_cnt;
reg        rd_run;
always @(posedge clk)
    if (rst)
    begin
/* at reset */
        sreq_s       <= 2'b00;
        snap_ack     <= 1'b0;
        snap_rdata   <= 32'd0;
/* no access to the buffer */
        sd_buff_addr <= 9'd0;
        sd_buff_dout <= 8'd0;
        sd_buff_wr   <= 1'b0;
/* no read runs */
        rd_cnt       <= 2'd0;
        rd_run       <= 1'b0;
        ext_stb      <= 1'b0;
    end
    else
    begin
/* the request, synchronised */
        sreq_s     <= {sreq_s[0], snap_req};
        sd_buff_wr <= 1'b0;
        ext_stb    <= 1'b0;
        if (rd_run)
        begin
/* a read: the buffer's byte two clocks after its address */
            if (rd_cnt != 2'd0)
            begin
                rd_cnt <= rd_cnt - 2'd1;
            end
            else
            begin
                rd_run     <= 1'b0;
                snap_rdata <= ext_sel ? ext_rdata : {24'd0, sd_buff_din};
                snap_ack   <= sreq_s[1];
            end
        end
/* a new command */
        else if (sreq_s[1] != snap_ack && ext_sel && snap_cmd != SNAP_MRD)
        begin
/* the other device's command */
            ext_stb    <= 1'b1;
            snap_rdata <= ext_rdata;
            snap_ack   <= sreq_s[1];
        end
        else if (sreq_s[1] != snap_ack)
        begin
            case (snap_cmd)
                SNAP_MRD:
                begin
/* (a read of the other device waits as long; the buffer's address does not matter then) */
                    sd_buff_addr <= snap_addr;
                    rd_cnt       <= RD_WAIT;
                    rd_run       <= 1'b1;
                end
                SNAP_MWR:
                begin
/* the byte into the buffer */
                    sd_buff_addr <= snap_addr;
                    sd_buff_dout <= snap_wdata;
                    sd_buff_wr   <= 1'b1;
                    snap_ack     <= sreq_s[1];
                end
                default:
                begin
                    snap_rdata <= 32'd0;
/* unknown commands answer 0 */
                    snap_ack   <= sreq_s[1];
                end
            endcase
        end
    end

endmodule

`default_nettype wire
