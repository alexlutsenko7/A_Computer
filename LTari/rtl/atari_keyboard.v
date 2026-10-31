//=============================================================================
// atari_keyboard -- USB keyboard via the CH9350-style UART module (115200 8N1)
//                   -> POKEY key codes, console keys, Break, Reset
//
// UART and packet parsing as c64_keyboard (L64): bytes 57, AB, 82, A3 restart the
// byte counter; byte 3 = HID modifiers, bytes 5..7 = three key codes; a report is
// complete when byte 8 arrives.
//
// Atari keys (scan codes: Altirra Hardware Reference Manual table 11, NOTES.md). PC keys
// by their meaning where the Atari has the key, else by position (US layout):
//   letters, digits, Enter = Return, Esc, Backspace = Delete/Back S, Tab, Space, Caps Lock,
//   - = ; , . / as on the Atari;  ' -> +  \ -> *  [ -> <  ] -> >  ` -> Inverse (Atari logo);
//   arrows -> Control + - = + * (the Atari's cursor keys);  Home -> Shift + < (Clear);
//   Delete -> Control + Back S (delete character);  Insert -> Control + > (insert character);
//   Shift / Control -> Shift / Control;  Pause -> Break.
//   Alt + F2 / F3 / F4 = START / SELECT / OPTION (CONSOL, held as long as the keys),
//   Alt + F5 = Reset (the XL/XE system reset), Alt + F6 = Help, Alt + F7 = Break.
// POKEY side: key_stb pulses when an Atari key is pressed (the newest key of the report)
// with key_code and the Shift / Control state at that moment (key_shift / key_ctrl, which
// also follow the modifiers continuously, for SKSTAT); key_down while any Atari key is
// held (SKSTAT bit 2: the OS's key repeat); key_break pulses on Break.
//
// Machine and loader keys as c64_keyboard (lkeys bit meanings identical, read by the
// ESP32 firmware); F-keys held together with Alt go to the Atari only:
//   lkeys: 0 F12 / keypad / / NumLock   1 keypad 8 / F9 / Up   2 keypad 2 / F10 / Down
//     3 keypad 4 / Left   4 keypad 6 / Right   5 keypad Enter / Enter   6 F11   7 keypad 5
//     8 keypad -   9 Esc / Backspace   10 F7 / keypad *   11 F6   12 F2   13 Page Up
//     14 Page Down   15 F5   16 F3   17 F4
//   f8_tgl toggles on F8, cad = Ctrl + Alt + Del, seen = a packet arrived,
//   raw = {modifiers, key 1, key 2, key 3}, block (asynchronous) = OSD open: no Atari keys.
// Reset by power-on only.
//=============================================================================
`default_nettype none

module atari_keyboard #(
    parameter integer CLK_HZ = 28373016,
    parameter integer BAUD   = 115200
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        rx,              // asynchronous
    input  wire        block,           // asynchronous: release all Atari keys

    output reg         key_stb,
    output reg  [5:0]  key_code,
    output reg         key_down,
    output reg         key_shift,
    output reg         key_ctrl,
    output reg         key_break,
    output reg  [2:0]  consol_n,        // START, SELECT, OPTION (0 = held)
    output reg         reset_key,

    output reg  [17:0] lkeys,
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
// HID key code -> {valid, forced Control, forced Shift, scan code}
//-----------------------------------------------------------------------------
function [8:0] akey(input [7:0] code, input alt);
    case (code)
        8'h04: akey = {3'b100, 6'h3F};  8'h05: akey = {3'b100, 6'h15};  8'h06: akey = {3'b100, 6'h12};  // A B C
        8'h07: akey = {3'b100, 6'h3A};  8'h08: akey = {3'b100, 6'h2A};  8'h09: akey = {3'b100, 6'h38};  // D E F
        8'h0A: akey = {3'b100, 6'h3D};  8'h0B: akey = {3'b100, 6'h39};  8'h0C: akey = {3'b100, 6'h0D};  // G H I
        8'h0D: akey = {3'b100, 6'h01};  8'h0E: akey = {3'b100, 6'h05};  8'h0F: akey = {3'b100, 6'h00};  // J K L
        8'h10: akey = {3'b100, 6'h25};  8'h11: akey = {3'b100, 6'h23};  8'h12: akey = {3'b100, 6'h08};  // M N O
        8'h13: akey = {3'b100, 6'h0A};  8'h14: akey = {3'b100, 6'h2F};  8'h15: akey = {3'b100, 6'h28};  // P Q R
        8'h16: akey = {3'b100, 6'h3E};  8'h17: akey = {3'b100, 6'h2D};  8'h18: akey = {3'b100, 6'h0B};  // S T U
        8'h19: akey = {3'b100, 6'h10};  8'h1A: akey = {3'b100, 6'h2E};  8'h1B: akey = {3'b100, 6'h16};  // V W X
        8'h1C: akey = {3'b100, 6'h2B};  8'h1D: akey = {3'b100, 6'h17};                                   // Y Z
        8'h1E: akey = {3'b100, 6'h1F};  8'h1F: akey = {3'b100, 6'h1E};  8'h20: akey = {3'b100, 6'h1A};  // 1 2 3
        8'h21: akey = {3'b100, 6'h18};  8'h22: akey = {3'b100, 6'h1D};  8'h23: akey = {3'b100, 6'h1B};  // 4 5 6
        8'h24: akey = {3'b100, 6'h33};  8'h25: akey = {3'b100, 6'h35};  8'h26: akey = {3'b100, 6'h30};  // 7 8 9
        8'h27: akey = {3'b100, 6'h32};                                                                   // 0
        8'h28: akey = {3'b100, 6'h0C};  8'h29: akey = {3'b100, 6'h1C};  8'h2A: akey = {3'b100, 6'h34};  // Return Esc Back S
        8'h2B: akey = {3'b100, 6'h2C};  8'h2C: akey = {3'b100, 6'h21};  8'h2D: akey = {3'b100, 6'h0E};  // Tab Space -
        8'h2E: akey = {3'b100, 6'h0F};  8'h2F: akey = {3'b100, 6'h36};  8'h30: akey = {3'b100, 6'h37};  // = [-> < ]-> >
        8'h31: akey = {3'b100, 6'h07};  8'h33: akey = {3'b100, 6'h02};  8'h34: akey = {3'b100, 6'h06};  // \-> * ; '-> +
        8'h35: akey = {3'b100, 6'h27};  8'h36: akey = {3'b100, 6'h20};  8'h37: akey = {3'b100, 6'h22};  // `-> Inv , .
        8'h38: akey = {3'b100, 6'h26};  8'h39: akey = {3'b100, 6'h3C};                                   // / Caps
        8'h4A: akey = {3'b101, 6'h36};                                                                   // Home: Clear
        8'h4C: akey = {3'b110, 6'h34};  8'h49: akey = {3'b110, 6'h37};                                   // Delete Insert
        8'h4F: akey = {3'b110, 6'h07};  8'h50: akey = {3'b110, 6'h06};                                   // Right Left
        8'h51: akey = {3'b110, 6'h0F};  8'h52: akey = {3'b110, 6'h0E};                                   // Down Up
        8'h3F: akey = alt ? {3'b100, 6'h11} : 9'd0;                                                      // Alt+F6: Help
        default: akey = 9'd0;
    endcase
endfunction

//-----------------------------------------------------------------------------
// Packet parser
//-----------------------------------------------------------------------------
reg [3:0]  idx;
reg [7:0]  mods, k1, k2, k3;
reg [7:0]  p1, p2, p3;                  // the report before
reg [1:0]  block_s;
reg        f8_held, brk_held;
reg        a_stb, a_down, a_fs, a_fc, a_brk, a_rst;
reg [5:0]  a_code;
reg [2:0]  a_consol;

function has(input [7:0] code);
    has = (k1 == code) || (k2 == code) || (k3 == code);
endfunction

function had(input [7:0] code);
    had = (p1 == code) || (p2 == code) || (p3 == code);
endfunction

wire alt_held = mods[2] | mods[6];

// F-key for the loader: only without Alt (Alt + F-key goes to the Atari)
function fk(input [7:0] code);
    fk = has(code) && !alt_held;
endfunction

function ak(input [7:0] code);
    ak = has(code) && alt_held;
endfunction

wire [8:0] m1 = akey(k1, alt_held);
wire [8:0] m2 = akey(k2, alt_held);
wire [8:0] m3 = akey(k3, alt_held);
wire       n1 = m1[8] && !had(k1);      // newly pressed
wire       n2 = m2[8] && !had(k2);
wire       n3 = m3[8] && !had(k3);
wire [8:0] mn = n3 ? m3 : n2 ? m2 : m1; // the newest new key (the last in the report)
wire [8:0] mh = m3[8] ? m3 : m2[8] ? m2 : m1;   // a held key (forced modifiers while held)

always @(posedge clk) begin
    block_s   <= {block_s[0], block};
    key_stb   <= a_stb && !block_s[1];
    key_code  <= a_code;
    key_down  <= a_down && !block_s[1];
    key_shift <= (mods[1] | mods[5] | (a_down && a_fs)) && !block_s[1];
    key_ctrl  <= (mods[0] | mods[4] | (a_down && a_fc)) && !block_s[1];
    key_break <= a_brk && !block_s[1];
    consol_n  <= block_s[1] ? 3'b111 : ~a_consol;
    reset_key <= a_rst && !block_s[1];
end

always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
        idx      <= 4'd0;
        mods     <= 8'd0;
        k1       <= 8'd0;
        k2       <= 8'd0;
        k3       <= 8'd0;
        p1       <= 8'd0;
        p2       <= 8'd0;
        p3       <= 8'd0;
        a_stb    <= 1'b0;
        a_down   <= 1'b0;
        a_fs     <= 1'b0;
        a_fc     <= 1'b0;
        a_code   <= 6'd0;
        a_brk    <= 1'b0;
        a_rst    <= 1'b0;
        a_consol <= 3'd0;
        brk_held <= 1'b0;
        lkeys    <= 18'd0;
        f8_tgl   <= 1'b0;
        f8_held  <= 1'b0;
        cad      <= 1'b0;
        seen     <= 1'b0;
        raw      <= 32'd0;
    end else begin
        a_stb <= 1'b0;
        a_brk <= 1'b0;
        if (byte_ok) begin
            if (rx_byte == 8'h57 || rx_byte == 8'hAB || rx_byte == 8'h82 || rx_byte == 8'hA3)
                idx <= 4'd0;
            else begin
                case (idx)
                    4'd3: mods <= rx_byte;
                    4'd5: k1   <= rx_byte;
                    4'd6: k2   <= rx_byte;
                    4'd7: k3   <= rx_byte;
                    4'd8: begin
                        // Atari side
                        if (n1 || n2 || n3) begin
                            a_stb  <= 1'b1;
                            a_code <= mn[5:0];
                            a_fs   <= mn[6];
                            a_fc   <= mn[7];
                        end else if (mh[8]) begin
                            a_fs   <= mh[6];
                            a_fc   <= mh[7];
                        end
                        a_down   <= m1[8] | m2[8] | m3[8];
                        brk_held <= has(8'h48) | ak(8'h40);
                        if ((has(8'h48) | ak(8'h40)) && !brk_held) a_brk <= 1'b1;
                        a_consol <= {ak(8'h3D), ak(8'h3C), ak(8'h3B)};          // OPTION SELECT START
                        a_rst    <= ak(8'h3E);
                        p1 <= k1;
                        p2 <= k2;
                        p3 <= k3;
                        // loader side
                        lkeys <= {fk(8'h3D),                                // 17 F4
                                  fk(8'h3C),                                // 16 F3
                                  fk(8'h3E),                                // 15 F5
                                  has(8'h4E),                               // 14 Page Down
                                  has(8'h4B),                               // 13 Page Up
                                  fk(8'h3B),                                // 12 F2
                                  fk(8'h3F),                                // 11 F6
                                  fk(8'h40) | has(8'h55),                   // 10 F7 / keypad *
                                  has(8'h29) | has(8'h2A),                  // 9 Esc / Backspace
                                  has(8'h56),                               // 8 keypad -
                                  has(8'h5D),                               // 7 keypad 5
                                  fk(8'h44),                                // 6 F11
                                  has(8'h58) | has(8'h28),                  // 5 keypad Enter / Enter
                                  has(8'h5E) | has(8'h4F),                  // 4 keypad 6 / Right
                                  has(8'h5C) | has(8'h50),                  // 3 keypad 4 / Left
                                  has(8'h5A) | fk(8'h43) | has(8'h51),      // 2 keypad 2 / F10 / Down
                                  has(8'h60) | fk(8'h42) | has(8'h52),      // 1 keypad 8 / F9 / Up
                                  fk(8'h45) | has(8'h54) | has(8'h53)};     // 0 F12 / keypad / / NumLock
                        f8_held <= fk(8'h41);
                        if (fk(8'h41) && !f8_held) f8_tgl <= !f8_tgl;
                        cad     <= has(8'h4C) && (mods[0] | mods[4]) && alt_held;
                        seen    <= 1'b1;
                        raw     <= {mods, k1, k2, k3};
                    end
                    default: ;
                endcase
                if (idx != 4'd15) idx <= idx + 4'd1;
            end
        end
    end

endmodule

`default_nettype wire
