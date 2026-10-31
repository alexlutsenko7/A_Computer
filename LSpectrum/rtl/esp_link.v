//=============================================================================
// esp_link -- SPI slave for the ESP32 system controller: the master of the
// tape loader's register bus (register offsets in tape_loader.v).
//
// SPI mode 0, MSB first, ESP32 = master. SCK, MOSI and CS_N are synchronised
// to clk (56 MHz LSpectrum, 94.5 MHz L64) and SCK is oversampled, so SCK
// high and low must each last >= 3 clocks: SCK <= 8 MHz. MOSI goes through the
// same two flip-flops as SCK (its value at the rising edge is taken). MISO
// changes 2-3 clocks after a falling edge (and after CS_N falls), so each bit
// is stable from just after one falling edge to just after the next: the ESP32
// samples MISO late, near the falling edge that ends the bit (its GPIO-matrix
// input; changing MISO after the rising edge gave bit errors / a 1-bit shift).
// Leave >= 100 ns between CS_N falling and the first SCK edge.
// After a reset the first frame is the one whose CS_N falling edge comes after CS_N was seen
// high (a frame running while the FPGA starts is ignored).
//
// A frame (CS_N low) is one command byte and its arguments. Byte n of the
// frame is numbered from 0 (the command). The FPGA sends status bytes
// {error, 7'd0} except where data is returned.
//   01 WR   r, d3 d2 d1 d0        write the register at byte offset r (0x00-0x3C)
//   02 RD   r, x, -> d3 d2 d1 d0  read register r (x = dummy byte)
//   03 OSD  a1 a0, b...           OSD text bytes from a (0-767), auto-increment
//   04 FIFO (d3 d2 d1 d0)...      push player commands
//   05 MWR  a2 a1 a0, b...        Spectrum memory writes from a (18 bits), auto-increment
//   06 MRD  a2 a1 a0, x, -> b...  Spectrum memory reads, auto-increment (prefetched)
//   07 STAT x, -> d3 d2 d1 d0     {error, 31'd0}; reading clears the error flag
// MWR/MRD need the Spectrum frozen (SNAPCTL). Each memory byte is one snapshot
// command (well under the 1 us a byte takes at 8 MHz). The error flag is set
// when a byte arrives while the previous access is still running (it is
// dropped) or when an MRD byte is not ready in time (0xEE is sent).
//=============================================================================
`default_nettype none

module esp_link (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        sck,             // asynchronous pins
    input  wire        mosi,
    input  wire        cs_n,
    output wire        miso,

    // register bus (valid held until ready)
    output reg         mem_valid,
    output reg  [31:0] mem_addr,
    output reg  [31:0] mem_wdata,
    output reg  [3:0]  mem_wstrb,
    input  wire        mem_ready,
    input  wire [31:0] mem_rdata
);

localparam [7:0] CMD_WR = 8'h01, CMD_RD = 8'h02, CMD_OSD = 8'h03, CMD_FIFO = 8'h04,
                 CMD_MWR = 8'h05, CMD_MRD = 8'h06, CMD_STAT = 8'h07;
localparam [31:0] IO = 32'h1000_0000, OSD = 32'h2000_0000;
localparam [7:0]  R_FIFO = 8'h0C, R_SNAPCTL = 8'h2C, R_SNAPCMD = 8'h30, R_SNAPDAT = 8'h34;
localparam [3:0]  C_MRD = 4'd1, C_MWR = 4'd2;

//-----------------------------------------------------------------------------
// Pins
//-----------------------------------------------------------------------------
reg [2:0] sck_s, cs_s;
reg [1:0] mosi_s;
always @(posedge clk) begin
    sck_s  <= {sck_s[1:0], sck};
    cs_s   <= {cs_s[1:0], cs_n};
    mosi_s <= {mosi_s[0], mosi};
end
wire rise   = sck_s[1] && !sck_s[2];
wire fall   = !sck_s[1] && sck_s[2];
reg  armed;                                    // CS_N was high since the reset: a transfer the
                                               // ESP32 began before (FPGA starting) is not decoded
wire active = !cs_s[1] && armed;
wire start  = cs_s[2] && !cs_s[1] && armed;    // CS_N fell

//-----------------------------------------------------------------------------
// State
//-----------------------------------------------------------------------------
reg  [7:0]  rx_sh, tx_sh;
reg  [2:0]  bitn;
reg         rx_stb;                             // rx_sh holds byte nb (one clock)
reg  [3:0]  nb;                                 // number of the byte being received (saturates at 15)
reg  [7:0]  cmd;
reg  [31:0] acc;                                // previous argument bytes
reg  [17:0] addr;
reg  [1:0]  gb;                                 // FIFO: byte within the word
reg  [31:0] rd_word;                            // RD / STAT result
reg         err;
reg         miso_q;                             // the pin (I/O register): tx_sh[7] taken at each falling edge
assign miso = miso_q;

// bus jobs
localparam [1:0] J_ONE = 2'd0, J_MWR = 2'd1, J_MRD = 2'd2;
reg         busy;                               // a job is running
reg  [1:0]  job, step;
reg         poll;                               // next: read SNAPCTL
reg  [17:0] job_a;
reg         mrd_ok;                             // mrd_b holds the prefetched byte
reg  [7:0]  mrd_b;

// byte sent after the one ending now (that is byte nb + 1; nb saturates, so compare nb)
reg  [7:0] tx_next;
reg        tx_mrd;                              // that byte is MRD data
always @* begin
    tx_next = {err, 7'd0};
    tx_mrd  = 1'b0;
    case (cmd)
        CMD_RD:   if (nb >= 4'd2 && nb <= 4'd5) tx_next = rd_word[8 * (5 - nb) +: 8];   // bytes 3-6
        CMD_STAT: if (nb >= 4'd1 && nb <= 4'd4) tx_next = rd_word[8 * (4 - nb) +: 8];   // bytes 2-5
        CMD_MRD:  if (nb >= 4'd4) begin tx_mrd = 1'b1; tx_next = mrd_ok ? mrd_b : 8'hEE; end   // bytes 5-
        default: ;
    endcase
    if (nb == 4'd0) tx_next = {err, 7'd0};     // cmd is not known yet
end

always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
        armed <= 1'b0;
        rx_sh <= 8'd0; tx_sh <= 8'd0; miso_q <= 1'b0; bitn <= 3'd0; rx_stb <= 1'b0; nb <= 4'd0;
        cmd <= 8'd0; acc <= 32'd0; addr <= 18'd0; gb <= 2'd0; rd_word <= 32'd0; err <= 1'b0;
        busy <= 1'b0; job <= J_ONE; step <= 2'd0; poll <= 1'b0; job_a <= 18'd0;
        mrd_ok <= 1'b0; mrd_b <= 8'd0;
        mem_valid <= 1'b0; mem_addr <= 32'd0; mem_wdata <= 32'd0; mem_wstrb <= 4'd0;
    end else begin
        rx_stb <= 1'b0;
        if (cs_s[1]) armed <= 1'b1;

        //---------------- SPI shift ----------------
        if (!active) begin
            bitn <= 3'd0;
            nb   <= 4'd0;
            cmd  <= 8'd0;
        end else if (start) begin
            bitn  <= 3'd0;
            nb    <= 4'd0;
            cmd   <= 8'd0;
            tx_sh  <= {err, 7'd0};
            miso_q <= err;
        end else if (fall)
            miso_q <= tx_sh[7];
        else if (rise) begin
            rx_sh <= {rx_sh[6:0], mosi_s[1]};
            bitn  <= bitn + 3'd1;
            if (bitn == 3'd7) begin
                rx_stb <= 1'b1;
                tx_sh  <= tx_next;
                if (tx_mrd) begin                   // MRD byte handed out: fetch the next one
                    if (!mrd_ok) err <= 1'b1;
                    mrd_ok <= 1'b0;
                    if (!busy) begin
                        busy <= 1'b1; job <= J_MRD; step <= 2'd0; job_a <= addr;
                        mem_valid <= 1'b1; mem_addr <= IO | R_SNAPCMD;
                        mem_wdata <= {C_MRD, 10'd0, addr}; mem_wstrb <= 4'hF;
                        addr <= addr + 18'd1;
                    end
                end
            end else
                tx_sh <= {tx_sh[6:0], 1'b0};
        end

        //---------------- received bytes ----------------
        if (rx_stb) begin
            if (nb != 4'd15) nb <= nb + 4'd1;
            acc <= {acc[23:0], rx_sh};
            if (nb == 4'd0) begin
                cmd <= rx_sh;
                gb  <= 2'd0;
                if (rx_sh == CMD_STAT) begin
                    rd_word <= {err, 31'd0};
                    err     <= 1'b0;
                end
            end else case (cmd)
                CMD_WR: if (nb == 4'd5) begin
                        if (busy) err <= 1'b1;
                        else begin
                            busy <= 1'b1; job <= J_ONE;
                            mem_valid <= 1'b1; mem_addr <= IO | acc[31:24];
                            mem_wdata <= {acc[23:0], rx_sh}; mem_wstrb <= 4'hF;
                        end
                    end
                CMD_RD: if (nb == 4'd1) begin           // read during the dummy byte
                        if (busy) err <= 1'b1;
                        else begin
                            busy <= 1'b1; job <= J_ONE;
                            mem_valid <= 1'b1; mem_addr <= IO | rx_sh; mem_wstrb <= 4'h0;
                        end
                    end
                CMD_OSD: begin
                    if (nb == 4'd2) addr <= {8'd0, acc[7:0], rx_sh};
                    if (nb >= 4'd3) begin
                        if (busy) err <= 1'b1;
                        else begin
                            busy <= 1'b1; job <= J_ONE;
                            mem_valid <= 1'b1; mem_addr <= OSD | addr[9:0];
                            mem_wdata <= {4{rx_sh}}; mem_wstrb <= 4'b0001 << addr[1:0];
                        end
                        addr <= addr + 18'd1;
                    end
                end
                CMD_FIFO: begin
                    gb <= gb + 2'd1;
                    if (gb == 2'd3) begin
                        if (busy) err <= 1'b1;
                        else begin
                            busy <= 1'b1; job <= J_ONE;
                            mem_valid <= 1'b1; mem_addr <= IO | R_FIFO;
                            mem_wdata <= {acc[23:0], rx_sh}; mem_wstrb <= 4'hF;
                        end
                    end
                end
                CMD_MWR: begin
                    if (nb == 4'd3) addr <= {acc[9:0], rx_sh};
                    if (nb >= 4'd4) begin
                        if (busy) err <= 1'b1;
                        else begin
                            busy <= 1'b1; job <= J_MWR; step <= 2'd0; job_a <= addr;
                            mem_valid <= 1'b1; mem_addr <= IO | R_SNAPDAT;
                            mem_wdata <= {24'd0, rx_sh}; mem_wstrb <= 4'hF;
                        end
                        addr <= addr + 18'd1;
                    end
                end
                CMD_MRD: if (nb == 4'd3) begin          // address complete: fetch the first byte
                        mrd_ok <= 1'b0;
                        if (busy) err <= 1'b1;
                        else begin
                            busy <= 1'b1; job <= J_MRD; step <= 2'd0; job_a <= {acc[9:0], rx_sh};
                            mem_valid <= 1'b1; mem_addr <= IO | R_SNAPCMD;
                            mem_wdata <= {C_MRD, 10'd0, acc[9:0], rx_sh}; mem_wstrb <= 4'hF;
                        end
                        addr <= {acc[9:0], rx_sh} + 18'd1;
                    end
                default: ;
            endcase
        end

        //---------------- bus jobs ----------------
        if (poll) begin                             // read SNAPCTL ([1] = command busy)
            poll <= 1'b0;
            mem_valid <= 1'b1; mem_addr <= IO | R_SNAPCTL; mem_wstrb <= 4'h0;
        end else if (mem_valid && mem_ready) begin
            mem_valid <= 1'b0;
            case (job)
                J_ONE: begin
                    if (cmd == CMD_RD) rd_word <= mem_rdata;
                    busy <= 1'b0;
                end
                J_MWR: case (step)
                    2'd0: begin                     // data written: start the command
                        step <= 2'd1;
                        mem_valid <= 1'b1; mem_addr <= IO | R_SNAPCMD;
                        mem_wdata <= {C_MWR, 10'd0, job_a}; mem_wstrb <= 4'hF;
                    end
                    2'd1: begin step <= 2'd2; poll <= 1'b1; end
                    default: if (mem_rdata[1]) poll <= 1'b1;
                             else busy <= 1'b0;
                endcase
                J_MRD: case (step)
                    2'd0: begin step <= 2'd1; poll <= 1'b1; end
                    2'd1: if (mem_rdata[1]) poll <= 1'b1;
                          else begin
                              step <= 2'd2;
                              mem_valid <= 1'b1; mem_addr <= IO | R_SNAPDAT; mem_wstrb <= 4'h0;
                          end
                    default: begin
                        mrd_b  <= mem_rdata[7:0];
                        mrd_ok <= 1'b1;
                        busy   <= 1'b0;
                    end
                endcase
                default: busy <= 1'b0;
            endcase
        end
    end

endmodule

`default_nettype wire
