//=============================================================================
// zx_keyboard -- USB keyboard via the CH9350-style UART module (115200 8N1)
//                -> ZX Spectrum 8 x 5 key matrix
//
// Packet parsing as in the DE10-Lite reference design (proven with the user's
// module): bytes 57, AB, 82, A3 restart the byte counter; counting the other
// bytes from 0, byte 3 = HID modifiers, bytes 5, 6, 7 = first three key codes;
// the matrix is updated when byte 8 arrives.
//
// Keys: letters, digits, Enter, Space as on the Spectrum.
//   Left Shift = CAPS SHIFT; Right Shift or Ctrl = SYMBOL SHIFT.
//   Extras (not in the reference): Backspace = CAPS+0 (DELETE), arrows =
//   CAPS+5/6/7/8, Esc = CAPS+SPACE (BREAK).
//
// rows: 8 x 5 bits, active low; row i is selected by A(8+i):
//   0 CAPS Z X C V   1 A S D F G   2 Q W E R T   3 1 2 3 4 5
//   4 0 9 8 7 6      5 P O I U Y   6 ENT L K J H 7 SPC SYM M N B
//
// Machine and loader keys (docs/SD_TAPE_LOADER.md):
//   lkeys (1 = held, read by the ESP32 loader firmware, esp32_v2/src/hw.h K_*):
//     0 F12 / keypad / / NumLock   1 keypad 8 / F9 / Up      2 keypad 2 / F10 / Down
//     3 keypad 4 / Left            4 keypad 6 / Right        5 keypad Enter / Enter
//     6 F11   7 keypad 5   8 keypad -   9 Esc / Backspace   10 F7 / keypad *   11 F6
//     12 F2 (save a snapshot)   13 Page Up   14 Page Down   15 F5 (contention on/off)
//     16 F3 (Bluetooth audio menu)   17 F4 (joystick menu)
//   f1      F1 held (DiagROM when the CPU starts)
//   f8_tgl  toggles on every F8 press (50/60 Hz video)
//   cad     Ctrl + Alt + Del held (back to the machine menu, LSpectrum.v)
//   seen    a complete packet has arrived since power-up
//   raw     {modifiers, key 1, key 2, key 3} of the last packet (text input in the tape loader)
//   block   (asynchronous) the OSD browser is open: all Spectrum keys released
// Reset by power-on only, so F1 is still known after a KEY0 reset.
//=============================================================================
`default_nettype none

module zx_keyboard #(
    parameter integer CLK_HZ = 112000000,
    parameter integer BAUD   = 115200
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        rx,              // asynchronous
    input  wire        block,           // asynchronous: release all Spectrum keys
    output reg  [39:0] rows,
    output reg  [17:0] lkeys,
    output reg         f1,
    output reg         f8_tgl,
    output reg         cad,
    output reg         seen,
    output reg  [31:0] raw
);

//-----------------------------------------------------------------------------
// UART receiver
//-----------------------------------------------------------------------------
localparam integer BIT  = CLK_HZ / BAUD;
localparam integer HALF = BIT / 2;

reg [2:0]  rx_s;
reg [10:0] tcnt;
reg [3:0]  bcnt;
reg [7:0]  shreg;
reg        busy, byte_ok;
reg [7:0]  rx_byte;

always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
        rx_s    <= 3'b111;
        tcnt    <= 11'd0;
        bcnt    <= 4'd0;
        shreg   <= 8'd0;
        busy    <= 1'b0;
        byte_ok <= 1'b0;
        rx_byte <= 8'd0;
    end else begin
        rx_s    <= {rx_s[1:0], rx};
        byte_ok <= 1'b0;
        if (!busy) begin
            if (!rx_s[2]) begin                 // start bit
                busy <= 1'b1;
                tcnt <= HALF[10:0];
                bcnt <= 4'd0;
            end
        end else if (tcnt != 11'd0)
            tcnt <= tcnt - 11'd1;
        else begin
            tcnt <= BIT[10:0] - 11'd1;
            bcnt <= bcnt + 4'd1;
            case (bcnt)
                4'd0:    if (rx_s[2]) busy <= 1'b0;             // false start
                4'd9:    begin                                  // stop bit
                             busy <= 1'b0;
                             if (rx_s[2]) begin rx_byte <= shreg; byte_ok <= 1'b1; end
                         end
                default: shreg <= {rx_s[2], shreg[7:1]};        // LSB first
            endcase
        end
    end

//-----------------------------------------------------------------------------
// HID key code -> matrix bit (5 * row + column), or 63 for no key
//-----------------------------------------------------------------------------
function [5:0] key_pos(input [7:0] code);
    case (code)
        8'h1D: key_pos = 6'd1;  8'h1B: key_pos = 6'd2;  8'h06: key_pos = 6'd3;  8'h19: key_pos = 6'd4;   // Z X C V
        8'h04: key_pos = 6'd5;  8'h16: key_pos = 6'd6;  8'h07: key_pos = 6'd7;  8'h09: key_pos = 6'd8;   // A S D F
        8'h0A: key_pos = 6'd9;                                                                            // G
        8'h14: key_pos = 6'd10; 8'h1A: key_pos = 6'd11; 8'h08: key_pos = 6'd12; 8'h15: key_pos = 6'd13;  // Q W E R
        8'h17: key_pos = 6'd14;                                                                           // T
        8'h1E: key_pos = 6'd15; 8'h1F: key_pos = 6'd16; 8'h20: key_pos = 6'd17; 8'h21: key_pos = 6'd18;  // 1 2 3 4
        8'h22: key_pos = 6'd19;                                                                           // 5
        8'h27: key_pos = 6'd20; 8'h26: key_pos = 6'd21; 8'h25: key_pos = 6'd22; 8'h24: key_pos = 6'd23;  // 0 9 8 7
        8'h23: key_pos = 6'd24;                                                                           // 6
        8'h13: key_pos = 6'd25; 8'h12: key_pos = 6'd26; 8'h0C: key_pos = 6'd27; 8'h18: key_pos = 6'd28;  // P O I U
        8'h1C: key_pos = 6'd29;                                                                           // Y
        8'h28: key_pos = 6'd30; 8'h0F: key_pos = 6'd31; 8'h0E: key_pos = 6'd32; 8'h0D: key_pos = 6'd33;  // ENT L K J
        8'h0B: key_pos = 6'd34;                                                                           // H
        8'h2C: key_pos = 6'd35;                                 8'h10: key_pos = 6'd37; 8'h11: key_pos = 6'd38;  // SPC M N
        8'h05: key_pos = 6'd39;                                                                           // B
        // extras with CAPS SHIFT (bit 0)
        8'h2A: key_pos = 6'd20;                                 // Backspace -> 0
        8'h50: key_pos = 6'd19;                                 // Left  -> 5
        8'h51: key_pos = 6'd24;                                 // Down  -> 6
        8'h52: key_pos = 6'd23;                                 // Up    -> 7
        8'h4F: key_pos = 6'd22;                                 // Right -> 8
        8'h29: key_pos = 6'd35;                                 // Esc   -> SPACE
        default: key_pos = 6'd63;
    endcase
endfunction

function caps_extra(input [7:0] code);
    caps_extra = (code == 8'h2A) || (code == 8'h50) || (code == 8'h51) ||
                 (code == 8'h52) || (code == 8'h4F) || (code == 8'h29);
endfunction

function [39:0] one_key(input [7:0] code);
    begin
        one_key = 40'd0;
        if (key_pos(code) != 6'd63) one_key[key_pos(code)] = 1'b1;
        if (caps_extra(code))       one_key[0] = 1'b1;
    end
endfunction

//-----------------------------------------------------------------------------
// Packet parser
//-----------------------------------------------------------------------------
reg [3:0]  idx;
reg [7:0]  mods, k1, k2, k3;
reg [39:0] zx_rows;
reg        f8_held;
reg [1:0]  block_s;

function has(input [7:0] code);
    has = (k1 == code) || (k2 == code) || (k3 == code);
endfunction

always @(posedge clk) begin
    block_s <= {block_s[0], block};
    rows    <= block_s[1] ? {40{1'b1}} : zx_rows;
end

always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
        idx     <= 4'd0;
        mods    <= 8'd0;
        k1      <= 8'd0;
        k2      <= 8'd0;
        k3      <= 8'd0;
        zx_rows <= {40{1'b1}};
        lkeys   <= 18'd0;
        f1      <= 1'b0;
        f8_tgl  <= 1'b0;
        f8_held <= 1'b0;
        cad     <= 1'b0;
        seen    <= 1'b0;
        raw     <= 32'd0;
    end else if (byte_ok) begin
        if (rx_byte == 8'h57 || rx_byte == 8'hAB || rx_byte == 8'h82 || rx_byte == 8'hA3)
            idx <= 4'd0;
        else begin
            case (idx)
                4'd3: mods <= rx_byte;
                4'd5: k1   <= rx_byte;
                4'd6: k2   <= rx_byte;
                4'd7: k3   <= rx_byte;
                4'd8: begin
                    zx_rows <= ~(one_key(k1) | one_key(k2) | one_key(k3) |
                                 {39'd0, mods[1]} |                              // Left Shift  -> CAPS (bit 0)
                                 ({39'd0, mods[5] | mods[0] | mods[4]} << 36));  // RShift/Ctrl -> SYM (bit 36)
                    lkeys <= {has(8'h3D),                               // 17 F4
                              has(8'h3C),                               // 16 F3
                              has(8'h3E),                               // 15 F5
                              has(8'h4E),                               // 14 Page Down
                              has(8'h4B),                               // 13 Page Up
                              has(8'h3B),                               // 12 F2
                              has(8'h3F),                               // 11 F6
                              has(8'h40) | has(8'h55),                  // 10 F7 / keypad *
                              has(8'h29) | has(8'h2A),                  // 9 Esc / Backspace
                              has(8'h56),                               // 8 keypad -
                              has(8'h5D),                               // 7 keypad 5
                              has(8'h44),                               // 6 F11
                              has(8'h58) | has(8'h28),                  // 5 keypad Enter / Enter
                              has(8'h5E) | has(8'h4F),                  // 4 keypad 6 / Right
                              has(8'h5C) | has(8'h50),                  // 3 keypad 4 / Left
                              has(8'h5A) | has(8'h43) | has(8'h51),     // 2 keypad 2 / F10 / Down
                              has(8'h60) | has(8'h42) | has(8'h52),     // 1 keypad 8 / F9 / Up
                              has(8'h45) | has(8'h54) | has(8'h53)};    // 0 F12 / keypad / / NumLock
                    f1      <= has(8'h3A);
                    f8_held <= has(8'h41);
                    if (has(8'h41) && !f8_held) f8_tgl <= !f8_tgl;
                    cad     <= has(8'h4C) && (mods[0] | mods[4]) && (mods[2] | mods[6]);
                    seen    <= 1'b1;
                    raw     <= {mods, k1, k2, k3};
                end
                default: ;
            endcase
            if (idx != 4'd15) idx <= idx + 4'd1;
        end
    end

endmodule

`default_nettype wire
