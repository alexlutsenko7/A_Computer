/* atari_sio -- SIO bus bridge between POKEY and the ESP32's disk drive emulation */
/* */
/* The ESP32 plays the peripheral (disk drive D1:, the SIO protocol of the hardware */
/* manual, ch. 9-10; LTari/ep4_ce15/NOTES.md). Over the tape loader's machine-specific */
/* registers (LSpectrum/ep4_ce15/rtl/tape_loader.v): */
/* MCTL  (W, kept)   [15:0] bit period of the bytes to the Atari, in clk_sd ticks */
/* (0 = 4433: 19,200 baud at 85.119 MHz); [18:16] cartridge type (atari_system), */
/* [23] / [21:20] memory port to the cartridge area / its 256 KB page (LTari.v) */
/* MSTAT (R)         [7:0] oldest byte from the Atari, [8] it is valid, [9] it was sent with the */
/* command line asserted, [10] it is the first byte since the command line was */
/* asserted, [11] the command line is asserted now, [12] the motor line is on, */
/* [13] everything sent (TX FIFO empty and the last stop bit done), */
/* [14] a byte from the Atari was lost (FIFO full; cleared by MCLR [10]), */
/* [26:16] bytes waiting to go to the Atari */
/* MCLR  (W, strobe) [7:0] byte, [8] push it to the Atari, [9] drop the oldest byte from the */
/* Atari, [10] empty both FIFOs and clear the lost flag */
/* Atari -> ESP32: each byte POKEY loads into its output shift register (so_stb), taken there, */
/* so it does not depend on the baud rate; with the command line state at that moment. */
/* ESP32 -> Atari: a real bit stream on POKEY's serial input (start, 8 data LSB first, stop), */
/* one byte after the other from a 1024-byte FIFO. */
`default_nettype none

module atari_sio (
    input  wire        clk_sd,
/* synchronous to clk_sd */
    input  wire        rst_n,

/* POKEY / PIA side (clk domain: synchronous to clk_sd, 1/3 the rate) */
/* one clk (= 3 clk_sd) per byte */
    input  wire        so_stb,
    input  wire [7:0]  so_byte,
    input  wire        cmd_n,
    input  wire        motor_n,
/* to POKEY (1 = mark) */
    output reg         sio_in,

/* tape loader machine registers (clk_sd) */
    input  wire [31:0] mctl,
    output wire [31:0] mstat,
    input  wire [31:0] mclr,
    input  wire        mclr_we
);

/* clk_sd clocks per bit at 19200 baud (the default speed) */
localparam [15:0] PERIOD_19200 = 16'd4433;
/* bytes of the transmit FIFO */
localparam [10:0] TX_SIZE = 11'd1024;
/* transmitter: the slot of the stop bit */
localparam [3:0] T_STOP = 4'd10;
/* transmitter: the slot of the last data bit */
localparam [3:0] T_LAST_DATA = 4'd8;

/* Atari -> ESP32: 64 x {first, cmd, byte} */
reg  [9:0] rx_mem [0:63];
reg  [5:0] rx_wp, rx_rp;
reg  [9:0] rx_q;
/* so_stb seen (edge in clk_sd) */
reg  [1:0] st_s;
reg  [1:0] cmd_s, mot_s;
/* the next byte is the first of a command frame */
reg        first;
reg        lost;
/* rx_q holds a valid byte (rx_has, in step with rx_q) */
reg        rx_v;
wire       rx_has  = rx_wp != rx_rp;
wire       rx_full = rx_wp + 6'd1 == rx_rp;
/* a byte from POKEY */
wire       so_ev   = st_s == 2'b01;

always @(posedge clk_sd)
begin
    if (so_ev && !rx_full)
    begin
/* the FIFO's memory, read registered */
        rx_mem[rx_wp] <= {first, !cmd_s[1], so_byte};
    end
    rx_q <= rx_mem[rx_rp];
end

/* ESP32 -> Atari: 1024 bytes, UART transmitter */
reg  [7:0]  tx_mem [0:1023];
reg  [9:0]  tx_wp, tx_rp;
reg  [7:0]  tx_q;
/* fill level, the bit timer */
reg  [10:0] tx_used;
reg  [15:0] t_cnt;
/* 0 idle, 1 start, 2-9 data, 10 stop */
reg  [3:0]  t_bit;
reg  [7:0]  t_sh;
/* tx_q is read one clock after tx_rp moves */
reg         t_wait;
wire [15:0] period  = mctl[15:0] == 16'd0 ? PERIOD_19200 : mctl[15:0];
wire        push    = mclr_we && mclr[8] && !mclr[10] && tx_used != TX_SIZE;
/* the next byte is taken when the transmitter is idle */
wire        tx_take = t_bit == 4'd0 && tx_used != 11'd0 && !t_wait && !(mclr_we && mclr[10]);

always @(posedge clk_sd)
begin
    if (push)
    begin
/* the FIFO's memory */
        tx_mem[tx_wp] <= mclr[7:0];
    end
    tx_q <= tx_mem[tx_rp];
end

always @(posedge clk_sd or negedge rst_n)
/* at reset */
    if (!rst_n)
    begin
        st_s    <= 2'b00;
        cmd_s   <= 2'b11;
/* the lines idle */
        mot_s   <= 2'b11;
        first   <= 1'b0;
        lost    <= 1'b0;
/* both FIFOs empty */
        rx_v    <= 1'b0;
        rx_wp   <= 6'd0;
        rx_rp   <= 6'd0;
/* the transmit FIFO */
        tx_wp   <= 10'd0;
        tx_rp   <= 10'd0;
        tx_used <= 11'd0;
/* the transmitter idle */
        t_cnt   <= 16'd0;
        t_bit   <= 4'd0;
        t_sh    <= 8'hFF;
/* the line idle */
        t_wait  <= 1'b0;
        sio_in  <= 1'b1;
    end
    else
    begin
        st_s  <= {st_s[0], so_stb};
/* command and motor lines, synchronised */
        cmd_s <= {cmd_s[0], cmd_n};
        mot_s <= {mot_s[0], motor_n};
/* command line asserted: a frame starts */
        if (cmd_s == 2'b10)
        begin
            first <= 1'b1;
        end

/* Atari -> ESP32 */
        if (so_ev)
        begin
            if (rx_full)
            begin
                lost <= 1'b1;
            end
            else
            begin
/* the next place */
                rx_wp <= rx_wp + 6'd1;
            end
            if (!cmd_s[1])
            begin
                first <= 1'b0;
            end
        end
/* the ESP32 took a byte */
        if (mclr_we && mclr[9] && rx_has)
        begin
            rx_rp <= rx_rp + 6'd1;
        end
        rx_v <= rx_has && !(mclr_we && (mclr[9] || mclr[10]));

/* ESP32 -> Atari */
        if (push)
        begin
            tx_wp <= tx_wp + 10'd1;
        end
        tx_used <= tx_used + {10'd0, push} - {10'd0, tx_take};
/* the wait is over */
        t_wait  <= 1'b0;
        if (tx_take)
        begin
            tx_rp  <= tx_rp + 10'd1;
/* tx_q holds the byte in the next clock */
            t_wait <= 1'b1;
        end
        if (t_wait)
        begin
            t_sh   <= tx_q;
/* the start bit comes first */
            t_bit  <= 4'd1;
            t_cnt  <= period - 16'd1;
/* start bit */
            sio_in <= 1'b0;
        end
        else if (t_bit != 4'd0)
        begin
            if (t_cnt != 16'd0)
            begin
/* the bit's time runs */
                t_cnt <= t_cnt - 16'd1;
            end
            else
            begin
                t_cnt <= period - 16'd1;
                t_bit <= t_bit == T_STOP ? 4'd0 : t_bit + 4'd1;
/* data bits, LSB first */
                if (t_bit <= T_LAST_DATA)
                begin
                    sio_in <= t_sh[0];
                    t_sh   <= {1'b1, t_sh[7:1]};
                end
                else
                begin
/* stop bit (t_bit 9 -> 10), then idle */
                    sio_in <= 1'b1;
                end
            end
        end

/* flush */
        if (mclr_we && mclr[10])
        begin
            rx_rp   <= rx_wp;
            tx_rp   <= tx_wp;
/* both FIFOs emptied */
            tx_used <= 11'd0;
            lost    <= 1'b0;
        end
    end

assign mstat = {5'd0, tx_used, 1'b0, lost, tx_used == 11'd0 && t_bit == 4'd0 && !t_wait,
                !mot_s[1], !cmd_s[1], rx_q[9], rx_q[8], rx_v, rx_q[7:0]};

endmodule

/* other files keep the default net type */
`default_nettype wire
