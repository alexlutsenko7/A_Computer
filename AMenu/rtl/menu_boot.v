//=============================================================================
// menu_boot -- Cyclone IV remote update (factory image side): reads why the
//              factory image was loaded, then starts an application image
//
// altremote_update parameters (Cyclone III / IV; read_source for reads: 00 = current,
// 01 = previous configuration, 10 = the one before, 11 = value to be written; WRITES MUST
// USE read_source 00: the generated block decodes no other combination for a write, the
// write is then silently dropped (db/rmtupdt_*.tdf, param_decoder_select)):
//   param 3'b010  watchdog time-out (12 bits)
//   param 3'b011  watchdog enable (1 bit)
//   param 3'b100  boot address (24 bits, AS byte address, two LSBs zero)
//   param 3'b111  reconfiguration trigger conditions (5 bits)
// After reset: read the trigger conditions and the boot address of the
// previous configuration (an application that ended, or failed to load), then
// ready = 1. A start_tgl toggle writes the longest watchdog time-out, watchdog off,
// boot_addr, and triggers
// the reconfiguration (the device then loads boot_addr; if that image is
// missing or bad it falls back to this factory image).
//
// Trigger condition bits as reported in practice (Quartus remote update
// controller): [1] watchdog time-out, [2] nSTATUS (no valid image), [3] CRC
// error, [4] nCONFIG / reconfiguration request; 0 = power-up.
// The previous boot address reads back either as written or shifted left by 2
// (reports differ): the menu accepts both.
//
// clk must be at most 20 MHz (the block's limit).
//=============================================================================
`default_nettype none

module menu_boot (
    input  wire        clk,
    input  wire        rst_n,           // synchronous to clk
    input  wire        start_tgl,       // other clock domain: toggle = boot boot_addr
    input  wire [23:0] boot_addr,       // static before start_tgl toggles
    output reg         ready,           // trig / prev_addr valid
    output reg  [4:0]  trig,
    output reg  [25:0] prev_addr,       // 26 bits: a 24-bit address shifted left by 2 keeps its top bits
    output reg  [4:0]  trig2,           // trigger conditions of the configuration before (read_source 10)
    output reg  [1:0]  mode             // master state machine mode (param 000): 0 factory, 1/3 application
);

reg        read_param, write_param, reconfig;
reg  [2:0] param;
reg  [1:0] read_source;
reg [23:0] data_in;
wire       busy;
wire [28:0] data_out;            // Cyclone IV: 29 bits (the widest parameter)

altremote_update #(
    .check_app_pof            ("false"),
    .config_device_addr_width (24),
    .in_data_width            (24),
    .out_data_width           (29),
    .operation_mode           ("remote")
) u_ru (
    .clock       (clk),
    .reset       (!rst_n),
    .read_param  (read_param),
    .write_param (write_param),
    .param       (param),
    .read_source (read_source),
    .data_in     (data_in),
    .reconfig    (reconfig),
    .reset_timer (1'b0),
    .ctl_nupdt   (1'b0),
    .busy        (busy),
    .data_out    (data_out)
);

reg [2:0] st_s;
always @(posedge clk) st_s <= {st_s[1:0], start_tgl};
wire start = st_s[2] ^ st_s[1];

localparam [3:0] S_RTRIG = 4'd0, S_RADDR = 4'd1, S_IDLE = 4'd2, S_WDOG = 4'd3,
                 S_WADDR = 4'd4, S_RECONF = 4'd5, S_WTIME = 4'd6, S_RTRIG2 = 4'd7, S_RMODE = 4'd8;
reg  [3:0] state;
reg        op_run;          // an operation was issued, waiting for busy to drop
reg  [3:0] op_wait;         // clocks before busy is looked at

// one read / write: issue (op_run = 0) -> wait -> done (busy low)
wire op_done = op_run && op_wait == 4'd0 && !busy;

always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
        state       <= S_RTRIG;
        op_run      <= 1'b0;
        op_wait     <= 4'd0;
        read_param  <= 1'b0;
        write_param <= 1'b0;
        reconfig    <= 1'b0;
        param       <= 3'd0;
        read_source <= 2'd0;
        data_in     <= 24'd0;
        ready       <= 1'b0;
        trig        <= 5'd0;
        prev_addr   <= 26'd0;
        trig2       <= 5'd0;
        mode        <= 2'd0;
    end else begin
        read_param  <= 1'b0;
        write_param <= 1'b0;
        if (op_wait != 4'd0) op_wait <= op_wait - 4'd1;

        case (state)
            S_RTRIG, S_RADDR, S_RTRIG2, S_RMODE: begin
                param       <= (state == S_RTRIG || state == S_RTRIG2) ? 3'b111 : state == S_RADDR ? 3'b100 : 3'b000;
                read_source <= state == S_RTRIG2 ? 2'b10 : state == S_RMODE ? 2'b00 : 2'b01;
                if (!op_run && !busy) begin
                    read_param <= 1'b1;
                    op_run     <= 1'b1;
                    op_wait    <= 4'd8;
                end else if (op_done) begin
                    op_run <= 1'b0;
                    case (state)
                        S_RTRIG:  begin trig  <= data_out[4:0]; state <= S_RADDR;  end
                        S_RADDR:  begin prev_addr <= data_out[25:0]; state <= S_RTRIG2; end
                        S_RTRIG2: begin trig2 <= data_out[4:0]; state <= S_RMODE;  end
                        default:  begin mode  <= data_out[1:0]; ready <= 1'b1; state <= S_IDLE; end
                    endcase
                end
            end
            S_IDLE:
                if (start) state <= S_WTIME;
            S_WTIME, S_WDOG, S_WADDR: begin
                param       <= state == S_WTIME ? 3'b010 : state == S_WDOG ? 3'b011 : 3'b100;
                read_source <= 2'b00;               // writes are only decoded with read_source 00
                data_in     <= state == S_WTIME ? 24'h000FFF : state == S_WDOG ? 24'd0 : {boot_addr[23:2], 2'b00};
                if (!op_run && !busy) begin
                    write_param <= 1'b1;
                    op_run      <= 1'b1;
                    op_wait     <= 4'd8;
                end else if (op_done) begin
                    op_run <= 1'b0;
                    state  <= state == S_WTIME ? S_WDOG : state == S_WDOG ? S_WADDR : S_RECONF;
                end
            end
            default:
                reconfig <= 1'b1;               // the device reconfigures; nothing comes after
        endcase
    end

endmodule

`default_nettype wire
