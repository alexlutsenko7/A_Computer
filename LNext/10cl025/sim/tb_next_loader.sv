/* tb_next_loader: next_loader.v's two FIFOs in their one block RAM, through the ESP32 link. */
/* The pulse player's commands (128) and the UART's received bytes (512) run at the same time: */
/* 1. 140 commands into the stopped player: 130 are taken (one runs, one waits, 128 queued) */
/* 2. the player runs; the test refills the FIFO as the firmware does (fill level, then a frame) */
/*    while UART bytes arrive without a pause and are read through the link */
/* 3. every pulse's length is measured in T-states, every byte compared */
/* 4. 515 bytes without a read: 512 are kept in order, the overrun flag is set */
`timescale 1ps / 1ps

module tb_next_loader;

/* half a period of the 56 MHz clock, ps */
localparam integer CLKH = 8929;
/* clocks per bit of the UART (56 MHz / 115200) */
localparam integer BAUD_DIV = 486;
/* clocks per T-state toggle in this test */
localparam integer T_CLKS = 4;
/* SPI half period: 8 MHz, ps */
localparam integer HALF = 62500;
/* chip select: before the first clock, after the last one, between frames, ps */
localparam integer CS_SETUP_PS = 150000;
localparam integer CS_HOLD_PS = 100000;
localparam integer FRAME_GAP_PS = 200000;
/* the bit sent first of a byte */
localparam integer MSB = 7;
/* link frames: register write, register read, FIFO commands */
localparam [7:0] F_WR = 8'h01;
localparam [7:0] F_RD = 8'h02;
localparam [7:0] F_FIFO = 8'h04;
/* registers: interrupt causes, FIFO, tape control, UART */
localparam [7:0] R_IRQ = 8'h04;
localparam [7:0] R_FIFO = 8'h0C;
localparam [7:0] R_TAPE = 8'h10;
localparam [7:0] R_UART = 8'h3C;
/* UART register: a byte is there, drop it, the overrun flag */
localparam integer U_VALID = 8;
localparam [31:0] U_DROP = 32'h0000_0200;
localparam integer U_OVR = 10;
localparam [31:0] U_OVR_CLEAR = 32'h0000_0400;
/* tape control: flush */
localparam [31:0] TAPE_FLUSH = 32'h0000_0004;
/* the command FIFO's size; commands of the first, blind burst; commands the player holds besides */
localparam integer DEPTH = 128;
localparam integer BLIND = 140;
localparam integer HELD = 2;
/* commands played in all; commands per refill frame; bytes of a command */
localparam integer N_CMDS = 400;
localparam integer PER_FRAME = 8;
localparam integer CMD_BYTES = 4;
/* pulse lengths: base, multiplier and modulus of the pattern */
localparam integer LEN_BASE = 200;
localparam integer LEN_MUL = 37;
localparam integer LEN_MOD = 101;
/* UART bytes of the first part, of the overrun part; the receive FIFO's size */
localparam integer N_BYTES = 300;
localparam integer N_OVER = 515;
localparam integer RX_DEPTH = 512;
/* byte pattern: multiplier and added constant */
localparam integer PAT_MUL = 7;
localparam integer PAT_ADD = 3;
/* bits of a UART character with start and stop */
localparam integer DATA_BITS = 8;
/* clocks of the reset, clocks waited after things settle */
localparam integer RESET_CLKS = 20;
localparam integer SETTLE_CLKS = 200;
/* longest frame of the test, bytes */
localparam integer FRAME_MAX = 1024;
/* mismatches listed */
localparam integer SHOWN_MAX = 10;

/* clock, reset, the T-state toggle and its enable */
reg clk = 0;
reg rst_n = 0;
reg cen_tgl = 0;
reg cen_run = 0;
/* the link, the UART line */
reg sck = 0;
reg mosi = 0;
reg cs_n = 1;
reg bt_rx = 1;
/* the design's answers */
wire miso;
wire irq;
wire tape_lvl;

/* counters of the test */
integer errors = 0;
integer t_div = 0;
integer toggles = 0;
integer toggles_at_edge = 0;
integer edges = 0;
/* commands pushed, bytes read */
integer pushed = 0;
integer got_bytes = 0;
integer i;
integer room;
integer count;
/* register data, the frame buffers */
reg [31:0] d;
reg [7:0]  tx [0:FRAME_MAX - 1];
reg [7:0]  rx [0:FRAME_MAX - 1];
reg        lvl_q = 0;
reg        uart_done = 0;

always #CLKH clk = !clk;

/* the design under test */
next_loader #(.BAUD_DIV(BAUD_DIV)) dut (
    .clk (clk), .rst_n (rst_n),
    .keys (18'd0), .keyraw (32'd0), .cen_tgl (cen_tgl), .mic (1'b0), .hold (),
    .tape_on (), .tape_turbo (), .tape_lvl (tape_lvl),
    .osd_on (), .osd_full (), .osd_we (), .osd_addr (), .osd_data (),
/* nothing behind these */
    .bt_tx (), .bt_rx (bt_rx), .int_pos (), .cont_on (), .joy_mode (),
    .fl_en (), .fl_ncs (), .fl_dclk (), .fl_mosi (), .fl_miso (1'b1), .reload (),
    .mctl (), .mstat (32'd0), .mclr (), .mclr_we (),
/* the snapshot port rests */
    .snap_freeze (), .snap_req (), .snap_cmd (), .snap_addr (), .snap_wdata (),
    .snap_frozen (1'b0), .snap_ack (1'b0), .snap_rdata (32'd0),
    .esp_sck (sck), .esp_mosi (mosi), .esp_cs_n (cs_n), .esp_miso (miso), .esp_irq (irq)
);

/* the length of pulse k, T-states */
function integer len_of(input integer k);
    len_of = LEN_BASE + ((k * LEN_MUL) % LEN_MOD);
endfunction

/* UART byte k */
function [7:0] pat(input integer k);
    pat = (k * PAT_MUL) + PAT_ADD;
endfunction

/* T-states */
always @(posedge clk)
begin
    if (cen_run)
    begin
        if (t_div == T_CLKS - 1)
        begin
/* one more T-state */
            t_div   <= 0;
            cen_tgl <= !cen_tgl;
            toggles <= toggles + 1;
        end
        else
        begin
            t_div <= t_div + 1;
        end
    end
end

/* every edge of the player's line: the T-states since the edge before are the pulse's length */
always @(posedge clk)
begin
    lvl_q <= tape_lvl;
    if (tape_lvl !== lvl_q)
    begin
/* the first edge has no edge before it */
        if (edges != 0)
        begin
            if ((toggles - toggles_at_edge) != len_of(edges))
            begin
                errors = errors + 1;
/* only the first ones are listed */
                if (errors <= SHOWN_MAX)
                begin
                    $display("FAIL: pulse %0d is %0d T-states, expected %0d", edges, toggles - toggles_at_edge, len_of(edges));
                end
            end
        end
        edges           <= edges + 1;
        toggles_at_edge <= toggles;
    end
end

/* SPI master (mode 0): one frame of n bytes, the answer in rx */
task automatic frame(input integer n);
    integer k;
    integer b;
    begin
        cs_n = 0;
        #CS_SETUP_PS;
/* every byte, MSB first */
        for (k = 0; k < n; k = k + 1)
        begin
            for (b = MSB; b >= 0; b = b - 1)
            begin
                mosi = tx[k][b];
/* the rising edge; the answer is taken at the falling one */
                #HALF sck = 1;
                #HALF sck = 0;
                rx[k][b] = miso;
            end
        end
        #CS_HOLD_PS cs_n = 1;
/* a pause between frames */
        #FRAME_GAP_PS;
    end
endtask

/* a register write */
task automatic wr(input [7:0] r, input [31:0] value);
    begin
        tx[0] = F_WR;
        tx[1] = r;
        {tx[2], tx[3], tx[4], tx[5]} = value;
/* sent */
        frame(6);
    end
endtask

/* a register read */
task automatic rd(input [7:0] r, output [31:0] value);
    begin
        tx[0] = F_RD;
        tx[1] = r;
/* dummy bytes: the data comes in the last four */
        tx[2] = 0;
        tx[3] = 0;
        tx[4] = 0;
        tx[5] = 0;
        tx[6] = 0;
/* sent; the answer */
        frame(7);
        value = {rx[3], rx[4], rx[5], rx[6]};
    end
endtask

/* n pulse commands from number first on, in one frame */
task automatic push_cmds(input integer first, input integer n);
    integer k;
    reg [31:0] cmd;
    begin
        tx[0] = F_FIFO;
        for (k = 0; k < n; k = k + 1)
        begin
/* PULSE: the length in the low 24 bits */
            cmd = len_of(first + k);
            {tx[1 + (CMD_BYTES * k)], tx[2 + (CMD_BYTES * k)], tx[3 + (CMD_BYTES * k)], tx[4 + (CMD_BYTES * k)]} = cmd;
        end
        frame(1 + (CMD_BYTES * n));
    end
endtask

/* one character on the UART line */
task automatic uart_byte(input [7:0] value);
    integer b;
    begin
        bt_rx = 0;
        repeat (BAUD_DIV) @(posedge clk);
/* the data bits, LSB first */
        for (b = 0; b < DATA_BITS; b = b + 1)
        begin
            bt_rx = value[b];
            repeat (BAUD_DIV) @(posedge clk);
        end
/* the stop bit */
        bt_rx = 1;
        repeat (BAUD_DIV) @(posedge clk);
    end
endtask

/* the oldest received byte, if there is one: compared and dropped */
task automatic uart_take;
    begin
        rd(R_UART, d);
        if (d[U_VALID])
        begin
            if (d[7:0] !== pat(got_bytes))
            begin
/* a wrong byte */
                errors = errors + 1;
                if (errors <= SHOWN_MAX)
                begin
                    $display("FAIL: UART byte %0d is %02h, expected %02h", got_bytes, d[7:0], pat(got_bytes));
                end
            end
            got_bytes = got_bytes + 1;
/* the next one */
            wr(R_UART, U_DROP);
        end
    end
endtask

/* the UART's sender: the first part without a pause, the overrun part when the test asks */
reg over_go = 0;
integer sent = 0;
initial
begin
    wait (cen_run);
    for (sent = 0; sent < N_BYTES; sent = sent + 1)
    begin
        uart_byte(pat(sent));
    end
/* the overrun part */
    wait (over_go);
    for (sent = N_BYTES; sent < (N_BYTES + N_OVER); sent = sent + 1)
    begin
        uart_byte(pat(sent));
    end
    uart_done = 1;
end

/* the test */
initial
begin
    repeat (RESET_CLKS) @(posedge clk);
    rst_n = 1;
    repeat (RESET_CLKS) @(posedge clk);
    wr(R_TAPE, TAPE_FLUSH);

/* 1. the stopped player: the FIFO empty, then 140 commands in two frames */
    rd(R_IRQ, d);
    if (d[0] !== 1'b1)
    begin
        $display("FAIL: empty FIFO does not ask for commands");
        errors = errors + 1;
    end
    push_cmds(0, BLIND / 2);
    push_cmds(BLIND / 2, BLIND / 2);
    rd(R_FIFO, d);
/* 128 queued */
    if (d[9:0] !== DEPTH)
    begin
        $display("FAIL: FIFO holds %0d commands, expected %0d", d[9:0], DEPTH);
        errors = errors + 1;
    end
    else
    begin
        $display("ok    FIFO full at %0d commands", d[9:0]);
    end
    rd(R_IRQ, d);
    if (d[0] !== 1'b0)
    begin
/* a full FIFO must not ask */
        $display("FAIL: full FIFO asks for commands");
        errors = errors + 1;
    end
    pushed = DEPTH + HELD;

/* 2. the player runs, the UART sends; refill as the firmware does, read the bytes */
    cen_run = 1;
    while ((pushed < N_CMDS) || (got_bytes < N_BYTES))
    begin
        if (pushed < N_CMDS)
        begin
            rd(R_FIFO, d);
            room = DEPTH - d[9:0];
/* a frame of at most 8 commands */
            count = room;
            if (count > PER_FRAME)
            begin
                count = PER_FRAME;
            end
            if (count > (N_CMDS - pushed))
            begin
                count = N_CMDS - pushed;
            end
/* into the FIFO */
            if (count > 0)
            begin
                push_cmds(pushed, count);
                pushed = pushed + count;
            end
        end
        uart_take;
    end
/* all commands played out */
    rd(R_FIFO, d);
    while (d[16] !== 1'b1)
    begin
        rd(R_FIFO, d);
    end
    repeat (SETTLE_CLKS) @(posedge clk);
/* 3. the counts */
    if (edges != N_CMDS)
    begin
        $display("FAIL: %0d pulses played, expected %0d", edges, N_CMDS);
        errors = errors + 1;
    end
    else
    begin
        $display("ok    %0d pulses played", edges);
    end
    $display("ok    %0d UART bytes read while the player ran", got_bytes);

/* 4. 515 bytes without a read */
    over_go = 1;
    wait (uart_done);
    repeat (SETTLE_CLKS) @(posedge clk);
    rd(R_UART, d);
    if (d[U_OVR] !== 1'b1)
    begin
        $display("FAIL: no overrun flag");
        errors = errors + 1;
    end
/* the 512 kept, in order */
    for (i = 0; i < RX_DEPTH; i = i + 1)
    begin
        uart_take;
    end
    if (got_bytes != (N_BYTES + RX_DEPTH))
    begin
        $display("FAIL: %0d bytes read in all, expected %0d", got_bytes, N_BYTES + RX_DEPTH);
        errors = errors + 1;
    end
/* then nothing more, and the flag clears */
    rd(R_UART, d);
    if (d[U_VALID] !== 1'b0)
    begin
        $display("FAIL: a byte after the last one");
        errors = errors + 1;
    end
    wr(R_UART, U_OVR_CLEAR);
    rd(R_UART, d);
    if (d[U_OVR] !== 1'b0)
    begin
        $display("FAIL: the overrun flag stays");
        errors = errors + 1;
    end
    else
    begin
        $display("ok    512 bytes kept, overrun flagged and cleared");
    end

/* the result */
    if (errors == 0)
    begin
        $display("PASS");
    end
    else
    begin
        $display("FAIL: %0d errors", errors);
    end
    $finish;
end

endmodule
