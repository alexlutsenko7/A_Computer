//=============================================================================
// sdram_ram -- byte-wide RAM (2^ADDR_BITS x 8) emulated on W9825G6KH-6 SDR SDRAM
//
// SDRAM: 4 banks x 8192 rows x 512 columns x 16 bit (32 MB).
// ADDR_BITS = 18 -> 256 KB window (ZX: 128 KB RAM pages + ROMs), max 25.
// Clock: CLK_MHZ (100..133 MHz with CL2 on -6 parts; used at 112 MHz), CAS latency 2.
//        SDRAM clock must be the inverted controller clock (DDIO-forwarded in the top level).
//
// Byte address -> SDRAM mapping (16-bit words, byte lanes via DQM):
//   addr[0]      byte lane (0 = DQ[7:0], 1 = DQ[15:8])
//   addr[9:1]    column  (512 words = 1 KB per row)
//   addr[11:10]  bank    (consecutive 1 KB blocks rotate through the 4 banks)
//   addr[ADDR_BITS-1:12]  row  (2^(ADDR_BITS-12) rows per bank)
//
// Open-page policy: each bank keeps its last row open, so up to 4 x 1 KB
// windows are "hot". Refresh closes all rows; it is done early while idle
// and forced only when the 7.5 us refresh interval runs out.
//
// Host protocol (all synchronous to clk):
//   - When an access is wanted, pulse req for one cycle with we/addr/din valid.
//   - Keep we/addr/din stable until ack (they are not latched).
//   - Wait for ack (1-cycle pulse). For reads dout is valid with ack and
//     holds until the next read completes.
//   - Only one access outstanding: do not pulse req again before ack.
//   - Requests before ready=1 are queued and served after initialization.
//
// Latency, cycles from req high to ack high:
//   write, row open : 1 clk            read, row open : 4 clk
//   bank idle       : +2 clk (ACT)     row conflict   : +4 clk (PRE+ACT)
//   a refresh in progress can add up to ~9 clk in the worst case.
// The read data path is: DQ input register -> byte mux -> dout (dout is
// combinational during the ack cycle, then held).
//=============================================================================
`default_nettype none

module sdram_ram #(
    parameter integer ADDR_BITS   = 18,
    parameter integer CLK_MHZ     = 112,
    parameter integer CAS_LATENCY = 2,              // 2 is legal up to 133 MHz on -6 parts
    parameter integer RD_CAPTURE  = CAS_LATENCY + 1 // clk edge after READ that samples DQ
)(
    input  wire        clk,
    input  wire        rst_n,

    // RAM side
    input  wire        req,
    input  wire        we,
    input  wire [ADDR_BITS-1:0] addr,
    input  wire [7:0]  din,
    output wire [7:0]  dout,
    output reg         ack,
    output reg         ready,

    // SDRAM side (tri-state for DQ is done in the top level)
    output wire        sd_cke,
    output wire        sd_cs_n,
    output wire        sd_ras_n,
    output wire        sd_cas_n,
    output wire        sd_we_n,
    output reg  [1:0]  sd_ba,
    output reg  [12:0] sd_a,
    output reg  [1:0]  sd_dqm,
    output reg  [15:0] sd_dq_o,
    output reg         sd_dq_oe,
    input  wire [15:0] sd_dq_i
);

//-----------------------------------------------------------------------------
// Timing (W9825G6KH-6), converted to clock cycles, rounded up
//-----------------------------------------------------------------------------
localparam integer T_RCD   = (15 * CLK_MHZ + 999) / 1000;  // ACT -> RD/WR
localparam integer T_RP    = (15 * CLK_MHZ + 999) / 1000;  // PRE -> ACT/REF
localparam integer T_RAS   = (42 * CLK_MHZ + 999) / 1000;  // ACT -> PRE
localparam integer T_RC    = (60 * CLK_MHZ + 999) / 1000;  // ACT -> ACT same bank
localparam integer T_RRD   = (12 * CLK_MHZ + 999) / 1000;  // ACT -> ACT other bank
localparam integer T_RFC   = (60 * CLK_MHZ + 999) / 1000;  // REF -> any
localparam integer T_WR    = 2;                            // write data -> PRE
localparam integer T_MRD   = 2;                            // MRS -> any
localparam integer T_INIT  = 200 * CLK_MHZ + 100;          // 200 us power-up pause
localparam integer REF_FORCE = 7500 * CLK_MHZ / 1000;      // < 7.8125 us (8192 rows / 64 ms)
// wait_cnt is 4 bits wide: every spacing loaded into it must be < 16
localparam integer REF_EARLY = REF_FORCE / 2;              // refresh early when idle

// Spacings loaded into the 4-bit wait_cnt (command N+1 issued N cycles later)
localparam integer W_RP_I    = T_RP - 1;
localparam integer W_RFC_I   = T_RFC - 1;
localparam integer W_MRD_I   = T_MRD - 1;
localparam integer W_RDCAP_I = RD_CAPTURE - 1;
localparam [3:0]  W_RP    = W_RP_I[3:0];
localparam [3:0]  W_RFC   = W_RFC_I[3:0];
localparam [3:0]  W_MRD   = W_MRD_I[3:0];
localparam [3:0]  W_RDCAP = W_RDCAP_I[3:0];

// Mode register: burst length 1, sequential, CAS latency, single-location write
localparam [2:0]  CL_BITS  = CAS_LATENCY[2:0];
localparam [12:0] MODE_REG = {3'b000, 1'b0, 2'b00, CL_BITS, 1'b0, 3'b000};

// Commands {CS_N, RAS_N, CAS_N, WE_N}
localparam [3:0] CMD_MRS = 4'b0000,
                 CMD_REF = 4'b0001,
                 CMD_PRE = 4'b0010,
                 CMD_ACT = 4'b0011,
                 CMD_WR  = 4'b0100,
                 CMD_RD  = 4'b0101,
                 CMD_NOP = 4'b0111;

localparam [2:0] S_INIT_WAIT = 3'd0,
                 S_INIT_PRE  = 3'd1,
                 S_INIT_REF  = 3'd2,
                 S_INIT_MRS  = 3'd3,
                 S_IDLE      = 3'd4,
                 S_READ      = 3'd5;

reg  [3:0]  cmd = CMD_NOP;
assign {sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n} = cmd;
assign sd_cke = 1'b1;

// Read data capture register; meant to be packed into the DQ input IOEs
reg  [15:0] dq_in;
always @(posedge clk) dq_in <= sd_dq_i;

// dout: straight from the capture register in the ack cycle, held afterwards
reg         rd_hi;
reg         rd_valid;
reg  [7:0]  dout_hold;
wire [7:0]  rd_byte = rd_hi ? dq_in[15:8] : dq_in[7:0];
assign dout = rd_valid ? rd_byte : dout_hold;
always @(posedge clk) if (rd_valid) dout_hold <= rd_byte;

//-----------------------------------------------------------------------------
// Current request: pending, or arriving this very cycle (inputs held to ack)
//-----------------------------------------------------------------------------
reg         pend;
wire        have   = pend | req;
wire [8:0]  c_col  = addr[9:1];
wire [1:0]  c_bank = addr[11:10];
localparam integer ROW_BITS = ADDR_BITS - 12;
wire [ROW_BITS-1:0] c_row = addr[ADDR_BITS-1:12];

//-----------------------------------------------------------------------------
// Bank bookkeeping. Ages count cycles since the last command of each kind
// (1 = issued on the previous edge) and saturate at 15.
//-----------------------------------------------------------------------------
reg  [3:0]  row_open;
reg  [ROW_BITS-1:0] open_row [0:3];
reg  [3:0]  act_age  [0:3];
reg  [3:0]  pre_age  [0:3];
reg  [3:0]  wr_age   [0:3];
reg  [3:0]  act_any_age;

wire [3:0]  pre_ok;     // bank may be precharged now
wire [3:0]  rp_ok;      // bank precharge finished
genvar gb;
generate
    for (gb = 0; gb < 4; gb = gb + 1) begin : g_bank
        assign pre_ok[gb] = !row_open[gb] || (act_age[gb] >= T_RAS && wr_age[gb] >= T_WR);
        assign rp_ok[gb]  = pre_age[gb] >= T_RP;
    end
endgenerate

wire hit = row_open[c_bank] && (open_row[c_bank] == c_row);

//-----------------------------------------------------------------------------
// Main sequencer
//-----------------------------------------------------------------------------
reg  [2:0]  state;
reg  [15:0] init_cnt;   // 200 us power-up pause
reg  [3:0]  wait_cnt;   // command spacing (kept narrow: it sits on the critical path)
reg  [3:0]  nref;
reg  [11:0] ref_timer;
reg         ref_force;  // registered ref_timer >= REF_FORCE / REF_EARLY
reg         ref_early;
reg         served;
integer     i;

always @(posedge clk) begin
    // defaults
    cmd      <= CMD_NOP;
    sd_dq_oe <= 1'b0;
    sd_dqm   <= ready ? 2'b00 : 2'b11;
    ack      <= 1'b0;
    rd_valid <= 1'b0;
    served    = 1'b0;

    for (i = 0; i < 4; i = i + 1) begin
        if (act_age[i] != 4'hF) act_age[i] <= act_age[i] + 4'd1;
        if (pre_age[i] != 4'hF) pre_age[i] <= pre_age[i] + 4'd1;
        if (wr_age[i]  != 4'hF) wr_age[i]  <= wr_age[i]  + 4'd1;
    end
    if (act_any_age != 4'hF) act_any_age <= act_any_age + 4'd1;
    if (ready && ref_timer != 12'hFFF) ref_timer <= ref_timer + 12'd1;
    ref_force <= ready && ref_timer >= REF_FORCE - 1;
    ref_early <= ready && ref_timer >= REF_EARLY - 1;

    // Address/data/mask registers are loaded every cycle while running; the
    // command decides whether the SDRAM uses them. This keeps the request
    // decode out of the paths into these I/O registers.
    if (ready) begin
        sd_ba   <= c_bank;
        sd_a    <= hit ? {4'b0000, c_col} : {{(13-ROW_BITS){1'b0}}, c_row};
        sd_dq_o <= {din, din};
        sd_dqm  <= !we ? 2'b00 : addr[0] ? 2'b01 : 2'b10;
    end
    if (wait_cnt != 0) wait_cnt <= wait_cnt - 4'd1;
    if (init_cnt != 0) init_cnt <= init_cnt - 16'd1;

    if (!rst_n) begin
        state       <= S_INIT_WAIT;
        init_cnt    <= T_INIT[15:0];
        wait_cnt    <= 4'd0;
        ready       <= 1'b0;
        nref        <= 4'd0;
        ref_timer   <= 12'd0;
        ref_force   <= 1'b0;
        ref_early   <= 1'b0;
        row_open    <= 4'b0000;
        act_any_age <= 4'hF;
        for (i = 0; i < 4; i = i + 1) begin
            act_age[i] <= 4'hF;
            pre_age[i] <= 4'hF;
            wr_age[i]  <= 4'hF;
        end
    end else begin
        case (state)
        //---------------------------------------------------------------- init
        S_INIT_WAIT:
            if (init_cnt == 0) state <= S_INIT_PRE;

        S_INIT_PRE: begin                       // precharge all
            cmd      <= CMD_PRE;
            sd_a[10] <= 1'b1;
            wait_cnt <= W_RP;
            state    <= S_INIT_REF;
        end

        S_INIT_REF:                             // 8 auto refresh cycles
            if (wait_cnt == 0) begin
                cmd      <= CMD_REF;
                wait_cnt <= W_RFC;
                nref     <= nref + 4'd1;
                if (nref == 4'd7) state <= S_INIT_MRS;
            end

        S_INIT_MRS:
            if (wait_cnt == 0) begin
                cmd      <= CMD_MRS;
                sd_ba    <= 2'b00;
                sd_a     <= MODE_REG;
                wait_cnt <= W_MRD;
                ready    <= 1'b1;
                state    <= S_IDLE;
            end

        //---------------------------------------------------------------- run
        S_IDLE:
            if (wait_cnt == 0) begin
                if (ref_force || (!have && ref_early)) begin
                    // refresh: close all rows first
                    sd_a[10] <= 1'b1;                       // PRE = precharge all
                    if (row_open == 4'b0000) begin
                        if (&rp_ok) begin
                            cmd       <= CMD_REF;
                            ref_timer <= 12'd0;
                            ref_force <= 1'b0;
                            ref_early <= 1'b0;
                            wait_cnt  <= W_RFC;
                        end
                    end else if (&pre_ok) begin
                        cmd      <= CMD_PRE;
                        row_open <= 4'b0000;
                        for (i = 0; i < 4; i = i + 1)
                            if (row_open[i]) pre_age[i] <= 4'd1;
                    end
                end else if (have) begin
                    if (hit) begin
                        if (act_age[c_bank] >= T_RCD) begin
                            served  = 1'b1;
                            if (we) begin
                                cmd      <= CMD_WR;
                                sd_dq_oe <= 1'b1;
                                wr_age[c_bank] <= 4'd1;
                                ack      <= 1'b1;           // posted write
                            end else begin
                                cmd      <= CMD_RD;
                                rd_hi    <= addr[0];
                                wait_cnt <= W_RDCAP;
                                state    <= S_READ;
                            end
                        end
                    end else if (row_open[c_bank]) begin
                        // other row open in this bank: close it
                        if (pre_ok[c_bank]) begin
                            cmd      <= CMD_PRE;
                            row_open[c_bank] <= 1'b0;
                            pre_age[c_bank]  <= 4'd1;
                        end
                    end else if (rp_ok[c_bank] && act_age[c_bank] >= T_RC && act_any_age >= T_RRD) begin
                        cmd      <= CMD_ACT;
                        row_open[c_bank] <= 1'b1;
                        open_row[c_bank] <= c_row;
                        act_age[c_bank]  <= 4'd1;
                        act_any_age      <= 4'd1;
                    end
                end
            end

        S_READ:
            if (wait_cnt == 0) begin
                // DQ is captured on this same edge
                ack      <= 1'b1;
                rd_valid <= 1'b1;
                state    <= S_IDLE;
            end

        default: state <= S_INIT_WAIT;
        endcase
    end

    // pending request
    if (!rst_n || served)
        pend <= 1'b0;
    else if (req)
        pend <= 1'b1;
end

endmodule

`default_nettype wire
