/* next_sdram -- LNext: the Spectrum Next's 2 MB of memory in the board's SDRAM (W9825G6KH-6, */
/* 16 bits wide), at 112 MHz = 4 x the machine's 28 MHz clock. */
/* */
/* This is the SDRAM controller of the MiSTer port of the Next core (rtl/mister/sdram.sv, */
/* Copyright (C) 2021 Alexey Melnikov, GPL-2 or later), written again for this board: the same */
/* cycle of eight clocks and the same two ports, so the core sees what it sees on MiSTer. */
/* Ours are the pins: separate DQM lines, data in / out / enable as registers for the I/O cells. */
/* The SDRAM clock is made in the top level (inverted, delayed PLL output), as the other machines. */
/* */
/* Port A (the CPU): a rising ram_a_req starts an access. A read of the four bytes read last */
/* is answered at once; anything else sets ram_a_wait until the access is done (CPU wait). */
/* Port B (Layer 2): a change of ram_b_req asks for a byte; no wait, the data is there within */
/* two machine clocks. */
/* */
/* An access: ACTIVE at state 1, READ or WRITE with auto-precharge at state 3, CAS latency 2, */
/* bursts of two words (four bytes, kept for the following reads), the first word in dq_r at */
/* state 7. Refresh: a cycle without an access, at least every 512 clocks. */
/* Address: 0 = low byte of a word, 9:1 column, 20:10 row; bank 0 only. */
`default_nettype none

module next_sdram (
    input  wire        clk,
/* 1 = start again (PLL not locked) */
    input  wire        init,

/* the SDRAM's pins (registers; the top level makes the tri-state) */
    output reg  [12:0] sd_a,
    output reg  [1:0]  sd_ba,
    output reg  [1:0]  sd_dqm,
    output reg         sd_we_n,
    output reg         sd_cas_n,
    output reg         sd_ras_n,
    output wire        sd_cs_n,
    output wire        sd_cke,
    output reg  [15:0] sd_dq_o,
    output reg         sd_dq_oe,
    input  wire [15:0] sd_dq_i,

/* port A: the CPU (machine clock, edges aligned with clk) */
    input  wire [20:0] ram_a_addr,
    input  wire        ram_a_req,
    input  wire        ram_a_rd_n,
    input  wire [7:0]  ram_a_di,
    output reg  [7:0]  ram_a_do,
    output reg         ram_a_wait,

/* port B: Layer 2 */
    input  wire [20:0] ram_b_addr,
    input  wire        ram_b_req,
    output reg  [7:0]  ram_b_do
);

/* the mode register: CAS latency 2, bursts of 2 words when reading, single words when writing */
localparam [12:0] MODE_WORD = 13'h0221;
/* the states of a cycle: idle, the command starts, READ / WRITE (tRCD = 2 clocks), the data is there */
localparam [2:0] ST_IDLE = 3'd0;
localparam [2:0] ST_START = 3'd1;
localparam [2:0] ST_CONT = 3'd3;
localparam [2:0] ST_READY = 3'd7;
/* what the cycles do: accesses, or the start-up's waiting, mode register and precharge */
localparam [1:0] MODE_NORMAL = 2'b00;
localparam [1:0] MODE_RESET = 2'b01;
localparam [1:0] MODE_LDM = 2'b10;
localparam [1:0] MODE_PRE = 2'b11;
/* the start-up: cycles to go, the cycle of the precharge and of the mode register */
localparam [4:0] INIT_CYCLES = 5'h1F;
localparam [4:0] INIT_PRE = 5'd14;
localparam [4:0] INIT_LDM = 5'd3;
/* commands: {RAS, CAS, WE} */
localparam [2:0] CMD_NOP = 3'b111;
localparam [2:0] CMD_ACTIVE = 3'b011;
localparam [2:0] CMD_READ = 3'b101;
localparam [2:0] CMD_WRITE = 3'b100;
localparam [2:0] CMD_PRECHARGE = 3'b010;
localparam [2:0] CMD_AUTO_REFRESH = 3'b001;
localparam [2:0] CMD_LOAD_MODE = 3'b000;
/* precharge all banks: A10 */
localparam [12:0] A_PRE_ALL = 13'b0010000000000;
/* READ / WRITE: A10 = auto-precharge */
localparam [1:0] A_AUTO_PRE = 2'b10;
/* refresh counter: full = a refresh is due; no word kept */
localparam [8:0] RFSH_FULL = 9'h1FF;
localparam [19:0] NO_ADDR = 20'hFFFFF;

reg  [2:0]  state = 3'd0;
/* the access in work: address, write, data, a real access (0: refresh) */
reg  [22:0] a = 23'd0;
reg  [1:0]  bank = 2'd0;
reg  [15:0] data = 16'd0;
reg         we = 1'b0;
reg         ram_req = 1'b0;
/* the four bytes kept per port and their address */
reg  [19:0] last_a0 = NO_ADDR;
reg  [19:0] last_a1 = NO_ADDR;
reg  [31:0] last_data0 = 32'd0;
reg  [31:0] last_data1 = 32'd0;
reg  [8:0]  rfsh_cnt = 9'd0;
/* the requests as seen a clock ago; the data pins' register */
reg         old_a_req = 1'b0;
reg         old_b_req = 1'b0;
reg  [15:0] dq_r = 16'd0;
/* which port's access runs; the second word of a burst goes to {port, half} */
reg         ch0_busy = 1'b0;
reg         ch1_busy = 1'b0;
reg  [2:0]  store = 3'd0;
/* the start-up */
reg  [1:0]  mode = MODE_RESET;
reg  [4:0]  reset = INIT_CYCLES;
reg         init_old = 1'b0;

assign sd_cs_n = 1'b0;
assign sd_cke  = 1'b1;

/* port A needs the SDRAM: a write, or a read outside the four bytes kept */
wire        fetch_req = ram_a_rd_n || (last_a0 != {1'b0, ram_a_addr[20:2]});
/* port B's bytes are the ones kept */
wire        b_hit = last_a1 == {1'b0, ram_b_addr[20:2]};
wire        b_new = old_b_req ^ ram_b_req;
/* the byte lanes of the kept words */
wire [4:0]  a_lane = {ram_a_addr[1:0], 3'b000};
wire [4:0]  b_lane = {ram_b_addr[1:0], 3'b000};
wire [4:0]  w_lane = {a[1:0], 3'b000};

/* the access manager */
always @(posedge clk)
begin
    dq_r <= sd_dq_i;

/* the refresh counter stops when full */
    if (rfsh_cnt != RFSH_FULL)
    begin
        rfsh_cnt <= rfsh_cnt + 9'd1;
    end

/* port A: a new request waits for the SDRAM, or is answered from the bytes kept */
    old_a_req <= ram_a_req;
    if (!old_a_req && ram_a_req)
    begin
        if (rfsh_cnt[8] || fetch_req)
        begin
            ram_a_wait <= 1'b1;
        end
        else
        begin
            ram_a_do <= last_data0[a_lane +: 8];
        end
    end

/* port B: a byte that is kept */
    if (b_new && b_hit)
    begin
        old_b_req <= ram_b_req;
        ram_b_do  <= last_data1[b_lane +: 8];
    end

/* a cycle starts: port B first, then port A, then a refresh that is due */
    if (state == ST_IDLE && mode == MODE_NORMAL)
    begin
        ram_req  <= 1'b0;
        we       <= 1'b0;
        ch0_busy <= 1'b0;
        ch1_busy <= 1'b0;

        if (b_new && !b_hit)
        begin
            old_b_req <= ram_b_req;
            bank      <= 2'd0;
            a         <= {2'b00, ram_b_addr};
            ram_req   <= 1'b1;
/* these four bytes will be kept */
            last_a1   <= {1'b0, ram_b_addr[20:2]};
            ch1_busy  <= 1'b1;
            state     <= ST_START;
        end
        else if ((!old_a_req && ram_a_req && (fetch_req || rfsh_cnt[8])) || ram_a_wait)
        begin
            we        <= ram_a_rd_n;
            bank      <= 2'd0;
            a         <= {2'b00, ram_a_addr};
            data      <= {ram_a_di, ram_a_di};
/* a read of kept bytes that only waited for a refresh: the cycle is that refresh */
            ram_req   <= fetch_req;
            last_a0   <= ram_a_rd_n ? NO_ADDR : {1'b0, ram_a_addr[20:2]};
            ch0_busy  <= 1'b1;
            state     <= ST_START;
        end
        else if (rfsh_cnt == RFSH_FULL)
        begin
            rfsh_cnt  <= 9'd0;
            state     <= ST_START;
        end
    end

/* the second word of a burst */
    if (store != 3'd0)
    begin
        if (store[1])
        begin
            last_data1[(store[0] ? 16 : 0) +: 16] <= dq_r;
        end
        else
        begin
            last_data0[(store[0] ? 16 : 0) +: 16] <= dq_r;
        end
        store <= 3'd0;
    end

/* the first word is there */
    if (state == ST_READY)
    begin
/* a cycle without an access was a refresh */
        if (!ram_req)
        begin
            rfsh_cnt <= 9'd0;
        end
        if (ch0_busy)
        begin
            ch0_busy   <= 1'b0;
            ram_a_wait <= 1'b0;
            if (ram_req)
            begin
                if (we)
                begin
                    ram_a_do <= data[7:0];
                end
                else
                begin
/* the byte asked for; the word is kept, the burst's second word follows */
                    ram_a_do <= a[0] ? dq_r[15:8] : dq_r[7:0];
                    last_data0[(a[1] ? 16 : 0) +: 16] <= dq_r;
                    store    <= {2'b10, !a[1]};
                end
            end
            else
            begin
                ram_a_do <= last_data0[w_lane +: 8];
            end
        end
        if (ch1_busy)
        begin
            ch1_busy <= 1'b0;
            ram_b_do <= a[0] ? dq_r[15:8] : dq_r[7:0];
            last_data1[(a[1] ? 16 : 0) +: 16] <= dq_r;
            store    <= {2'b11, !a[1]};
        end
    end

/* the cycle's states follow each other */
    if (mode != MODE_NORMAL || state != ST_IDLE || reset != 5'd0)
    begin
        state <= state + 3'd1;
        if (state == ST_READY)
        begin
            state <= ST_IDLE;
        end
    end
end

/* the start-up: 31 cycles, with a precharge of all banks and the mode register */
always @(posedge clk)
begin
    init_old <= init;

    if (init_old && !init)
    begin
        reset <= INIT_CYCLES;
    end
    else if (state == ST_READY)
    begin
        if (reset != 5'd0)
        begin
            reset <= reset - 5'd1;
            if (reset == INIT_PRE)
            begin
                mode <= MODE_PRE;
            end
            else if (reset == INIT_LDM)
            begin
                mode <= MODE_LDM;
            end
            else
            begin
                mode <= MODE_RESET;
            end
        end
        else
        begin
            mode <= MODE_NORMAL;
        end
    end
end

/* the SDRAM's pins */
always @(posedge clk)
begin
    if (state == ST_START)
    begin
        sd_ba <= (mode == MODE_NORMAL) ? bank : 2'b00;
    end

/* commands */
    {sd_ras_n, sd_cas_n, sd_we_n} <= CMD_NOP;
    sd_dq_oe <= 1'b0;
    if (mode == MODE_NORMAL)
    begin
        if (state == ST_START)
        begin
            {sd_ras_n, sd_cas_n, sd_we_n} <= ram_req ? CMD_ACTIVE : CMD_AUTO_REFRESH;
        end
        else if (state == ST_CONT && ram_req)
        begin
            if (we)
            begin
/* a write: the data with the command */
                {sd_ras_n, sd_cas_n, sd_we_n} <= CMD_WRITE;
                sd_dq_o  <= data;
                sd_dq_oe <= 1'b1;
            end
            else
            begin
                {sd_ras_n, sd_cas_n, sd_we_n} <= CMD_READ;
            end
        end
    end
    else if (state == ST_START)
    begin
        if (mode == MODE_LDM)
        begin
            {sd_ras_n, sd_cas_n, sd_we_n} <= CMD_LOAD_MODE;
        end
        else if (mode == MODE_PRE)
        begin
            {sd_ras_n, sd_cas_n, sd_we_n} <= CMD_PRECHARGE;
        end
    end

/* address and byte masks: a write stores one byte of the word */
    sd_a   <= 13'd0;
    sd_dqm <= 2'b00;
    if (mode == MODE_NORMAL)
    begin
        if (ram_req && state == ST_START)
        begin
            sd_a <= a[22:10];
        end
        else if (ram_req && state == ST_CONT)
        begin
            sd_a   <= {2'b00, A_AUTO_PRE, a[9:1]};
            sd_dqm <= {we && !a[0], we && a[0]};
        end
    end
    else if (state == ST_START)
    begin
        if (mode == MODE_LDM)
        begin
            sd_a <= MODE_WORD;
        end
        else if (mode == MODE_PRE)
        begin
            sd_a <= A_PRE_ALL;
        end
    end
end

endmodule

`default_nettype wire
