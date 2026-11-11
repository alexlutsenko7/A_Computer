/* c64_keyboard -- USB keyboard via the CH9350-style UART module (115200 8N1) */
/* -> Commodore 64 8 x 8 key matrix */
/* */
/* Packet parsing and the UART as zx_keyboard (LSpectrum): bytes 57, AB, 82, A3 */
/* restart the byte counter; byte 3 = HID modifiers, bytes 5..7 = three key codes; */
/* the matrix is updated when byte 8 arrives. */
/* */
/* Matrix: keys[8 * a + b] = 1 while the key at CIA1 port A bit a (column, driven */
/* low by the KERNAL) / port B bit b (row, read) is held: */
/* a=0: DEL RETURN CRSR-RIGHT F7 F1 F3 F5 CRSR-DOWN      (b = 0..7) */
/* a=1: 3 W A 4 Z S E LSHIFT      a=2: 5 R D 6 C F T X */
/* a=3: 7 Y G 8 B H U V           a=4: 9 I J 0 M K O N */
/* a=5: + P L - . : @ ,           a=6: POUND * ; HOME RSHIFT = UP-ARROW / */
/* a=7: 1 LEFT-ARROW CTRL 2 SPACE C= Q RUN/STOP */
/* PC keys (by position, US layout): letters, digits, Enter, Space, , . / as on the C64; */
/* - = [ ] ; ' `  ->  + - @ * : ; LEFT-ARROW;  \ -> =;  Insert -> POUND;  End -> UP-ARROW; */
/* Home -> CLR/HOME;  Backspace / Delete -> DEL;  Esc -> RUN/STOP;  Tab / Ctrl -> CTRL; */
/* Windows -> C=;  Shift -> SHIFT;  Right / Down -> CRSR, Left / Up -> SHIFT + CRSR; */
/* Alt + F1..F8 -> C64 F1..F8 (F2/F4/F6/F8 = SHIFT + F1/F3/F5/F7); */
/* Page Up -> RESTORE (restore = 1 while held: the NMI line, not in the matrix). */
/* */
/* Machine and loader keys as zx_keyboard (lkeys bit meanings identical, read by the */
/* ESP32 firmware), except that F-keys held together with Alt go to the C64 only: */
/* lkeys: 0 F12 / keypad / / NumLock   1 keypad 8 / F9 / Up   2 keypad 2 / F10 / Down */
/* 3 keypad 4 / Left   4 keypad 6 / Right   5 keypad Enter / Enter   6 F11   7 keypad 5 */
/* 8 keypad -   9 Esc / Backspace   10 F7 / keypad *   11 F6   12 F2   13 Page Up */
/* 14 Page Down   15 F5   16 F3   17 F4 */
/* f1 F1 held, f8_tgl toggles on F8, cad = Ctrl + Alt + Del, seen = a packet arrived, */
/* raw = {modifiers, key 1, key 2, key 3}, block (asynchronous) = OSD open: all C64 keys up. */
/* Reset by power-on only. */
`default_nettype none

module c64_keyboard #(
    parameter integer CLK_HZ = 31510000,
    parameter integer BAUD   = 115200
)(
    input  wire        clk,
    input  wire        rst_n,
/* asynchronous */
    input  wire        rx,
/* asynchronous: release all C64 keys */
    input  wire        block,
    output reg  [63:0] keys,
    output reg         restore,
    output reg  [17:0] lkeys,
    output reg         f1,
    output reg         f8_tgl,
    output reg         cad,
    output reg         seen,
    output reg  [31:0] raw
);

/* decoder step of the report's second key */
localparam [1:0] DEC_KEY2 = 2'd2;
/* a byte that restarts the packet's byte counter */
localparam [7:0] PKT_START_57 = 8'h57;
/* a byte that restarts the packet's byte counter */
localparam [7:0] PKT_START_AB = 8'hAB;
/* a byte that restarts the packet's byte counter */
localparam [7:0] PKT_START_82 = 8'h82;
/* a byte that restarts the packet's byte counter */
localparam [7:0] PKT_START_A3 = 8'hA3;
/* matrix bit of the left SHIFT key (column 1, row 7) */
localparam integer LSHIFT_BIT = 15;
/* matrix bit of the right SHIFT key (column 6, row 4) */
localparam integer RSHIFT_BIT = 52;
/* matrix bit of CTRL (column 7, row 2) */
localparam integer CTRL_BIT = 58;
/* matrix bit of the C= key (column 7, row 5) */
localparam integer CBM_BIT = 61;
/* USB key code: Page Up */
localparam [7:0] KEY_PGUP = 8'h4B;
/* USB key code: F4 */
localparam [7:0] KEY_F4 = 8'h3D;
/* USB key code: F3 */
localparam [7:0] KEY_F3 = 8'h3C;
/* USB key code: F5 */
localparam [7:0] KEY_F5 = 8'h3E;
/* USB key code: Page Down */
localparam [7:0] KEY_PGDN = 8'h4E;
/* USB key code: F2 */
localparam [7:0] KEY_F2 = 8'h3B;
/* USB key code: F6 */
localparam [7:0] KEY_F6 = 8'h3F;
/* USB key code: F7 */
localparam [7:0] KEY_F7 = 8'h40;
/* USB key code: keypad * */
localparam [7:0] KEY_KP_STAR = 8'h55;
/* USB key code: Esc */
localparam [7:0] KEY_ESC = 8'h29;
/* USB key code: Backspace */
localparam [7:0] KEY_BACKSPACE = 8'h2A;
/* USB key code: keypad - */
localparam [7:0] KEY_KP_MINUS = 8'h56;
/* USB key code: keypad 5 */
localparam [7:0] KEY_KP5 = 8'h5D;
/* USB key code: F11 */
localparam [7:0] KEY_F11 = 8'h44;
/* USB key code: keypad Enter */
localparam [7:0] KEY_KP_ENTER = 8'h58;
/* USB key code: Enter */
localparam [7:0] KEY_ENTER = 8'h28;
/* USB key code: keypad 6 */
localparam [7:0] KEY_KP6 = 8'h5E;
/* USB key code: cursor right */
localparam [7:0] KEY_RIGHT = 8'h4F;
/* USB key code: keypad 4 */
localparam [7:0] KEY_KP4 = 8'h5C;
/* USB key code: cursor left */
localparam [7:0] KEY_LEFT = 8'h50;
/* USB key code: keypad 2 */
localparam [7:0] KEY_KP2 = 8'h5A;
/* USB key code: F10 */
localparam [7:0] KEY_F10 = 8'h43;
/* USB key code: cursor down */
localparam [7:0] KEY_DOWN = 8'h51;
/* USB key code: keypad 8 */
localparam [7:0] KEY_KP8 = 8'h60;
/* USB key code: F9 */
localparam [7:0] KEY_F9 = 8'h42;
/* USB key code: cursor up */
localparam [7:0] KEY_UP = 8'h52;
/* USB key code: F12 */
localparam [7:0] KEY_F12 = 8'h45;
/* USB key code: keypad / */
localparam [7:0] KEY_KP_SLASH = 8'h54;
/* USB key code: Num Lock */
localparam [7:0] KEY_NUMLOCK = 8'h53;
/* USB key code: F1 */
localparam [7:0] KEY_F1 = 8'h3A;
/* USB key code: F8 */
localparam [7:0] KEY_F8 = 8'h41;
/* USB key code: Delete */
localparam [7:0] KEY_DELETE = 8'h4C;

/* UART receiver */
localparam integer BIT  = CLK_HZ / BAUD;
localparam integer HALF = BIT / 2;

reg [2:0]  rx_s;
/* bit timer, bit counter, shift register */
reg [10:0] tcnt;
reg [3:0]  bcnt;
reg [7:0]  shreg;
/* receiving; a byte is complete */
reg        busy, byte_ok;
reg [7:0]  rx_byte;

always @(posedge clk or negedge rst_n)
/* reset */
    if (!rst_n)
    begin
        rx_s    <= 3'b111;
        tcnt    <= 11'd0;
/* nothing received */
        bcnt    <= 4'd0;
        shreg   <= 8'd0;
        busy    <= 1'b0;
/* no byte */
        byte_ok <= 1'b0;
        rx_byte <= 8'd0;
    end
    else
    begin
        rx_s    <= {rx_s[1:0], rx};
/* idle: wait for the start bit */
        byte_ok <= 1'b0;
        if (!busy)
        begin
/* start bit */
            if (!rx_s[2])
            begin
                busy <= 1'b1;
                tcnt <= HALF[10:0];
/* from its middle on */
                bcnt <= 4'd0;
            end
        end
        else if (tcnt != 11'd0)
        begin
            tcnt <= tcnt - 11'd1;
        end
        else
        begin
/* a bit time later: the next bit */
            tcnt <= BIT[10:0] - 11'd1;
            bcnt <= bcnt + 4'd1;
            case (bcnt)
/* false start */
                4'd0:
                    if (rx_s[2])
                    begin
                        busy <= 1'b0;
                    end
/* stop bit */
                4'd9:
                begin
                    busy <= 1'b0;
                    if (rx_s[2])
                    begin
/* a byte, if the stop bit is high */
                        rx_byte <= shreg;
                        byte_ok <= 1'b1;
                    end
                end
/* LSB first */
                default: shreg <= {rx_s[2], shreg[7:1]};
            endcase
        end
    end

/* HID key code -> matrix position (8 * a + b), 7'h7F = none; [6] = with LSHIFT */
function [6:0] key_pos(input [7:0] code, input alt);
    case (code)
/* A B C D */
        8'h04: key_pos = 7'd10;
        8'h05: key_pos = 7'd28;
        8'h06: key_pos = 7'd20;
/* D */
        8'h07: key_pos = 7'd18;
/* E F G H */
        8'h08: key_pos = 7'd14;
        8'h09: key_pos = 7'd21;
        8'h0A: key_pos = 7'd26;
/* H */
        8'h0B: key_pos = 7'd29;
/* I J K L */
        8'h0C: key_pos = 7'd33;
        8'h0D: key_pos = 7'd34;
        8'h0E: key_pos = 7'd37;
/* L */
        8'h0F: key_pos = 7'd42;
/* M N O P */
        8'h10: key_pos = 7'd36;
        8'h11: key_pos = 7'd39;
        8'h12: key_pos = 7'd38;
/* P */
        8'h13: key_pos = 7'd41;
/* Q R S T */
        8'h14: key_pos = 7'd62;
        8'h15: key_pos = 7'd17;
        8'h16: key_pos = 7'd13;
/* T */
        8'h17: key_pos = 7'd22;
/* U V W X */
        8'h18: key_pos = 7'd30;
        8'h19: key_pos = 7'd31;
        8'h1A: key_pos = 7'd9;
/* X */
        8'h1B: key_pos = 7'd23;
/* Y Z */
        8'h1C: key_pos = 7'd25;
        8'h1D: key_pos = 7'd12;
/* 1 2 3 4 */
        8'h1E: key_pos = 7'd56;
        8'h1F: key_pos = 7'd59;
        8'h20: key_pos = 7'd8;
/* 4 */
        8'h21: key_pos = 7'd11;
/* 5 6 7 8 */
        8'h22: key_pos = 7'd16;
        8'h23: key_pos = 7'd19;
        8'h24: key_pos = 7'd24;
/* 8 */
        8'h25: key_pos = 7'd27;
/* 9 0 */
        8'h26: key_pos = 7'd32;
        8'h27: key_pos = 7'd35;
/* RETURN RUN/STOP DEL CTRL(Tab) */
        8'h28: key_pos = 7'd1;
        8'h29: key_pos = 7'd63;
        8'h2A: key_pos = 7'd0;
/* Tab = CTRL */
        8'h2B: key_pos = 7'd58;
/* SPACE + - @ */
        8'h2C: key_pos = 7'd60;
        8'h2D: key_pos = 7'd40;
        8'h2E: key_pos = 7'd43;
/* [ = @ */
        8'h2F: key_pos = 7'd46;
/* = : ; */
        8'h30: key_pos = 7'd49;
        8'h31: key_pos = 7'd53;
        8'h33: key_pos = 7'd45;
/* ' = ; */
        8'h34: key_pos = 7'd50;
/* <- , . / */
        8'h35: key_pos = 7'd57;
        8'h36: key_pos = 7'd47;
        8'h37: key_pos = 7'd44;
/* / */
        8'h38: key_pos = 7'd55;
/* POUND HOME DEL UP-ARROW */
        8'h49: key_pos = 7'd48;
        8'h4A: key_pos = 7'd51;
        8'h4C: key_pos = 7'd0;
/* End = UP-ARROW */
        8'h4D: key_pos = 7'd54;
/* CRSR-RIGHT CRSR-DOWN */
        8'h4F: key_pos = 7'd2;
        8'h51: key_pos = 7'd7;
/* SHIFT + CRSR-RIGHT / -DOWN */
        8'h50: key_pos = 7'd66;
        8'h52: key_pos = 7'd71;
/* F1 F2 */
        8'h3A: key_pos = alt ? 7'd4  : 7'h7F;
        8'h3B: key_pos = alt ? 7'd68 : 7'h7F;
/* F3 F4 */
        8'h3C: key_pos = alt ? 7'd5  : 7'h7F;
        8'h3D: key_pos = alt ? 7'd69 : 7'h7F;
/* F5 F6 */
        8'h3E: key_pos = alt ? 7'd6  : 7'h7F;
        8'h3F: key_pos = alt ? 7'd70 : 7'h7F;
/* F7 F8 */
        8'h40: key_pos = alt ? 7'd3  : 7'h7F;
        8'h41: key_pos = alt ? 7'd67 : 7'h7F;
        default: key_pos = 7'h7F;
    endcase
endfunction

/* the matrix bit of one key */
function [63:0] one_key(input [7:0] code, input alt);
    reg [6:0] p;
    begin
        p       = key_pos(code, alt);
/* no bit for a key the C64 does not have */
        one_key = 64'd0;
        if (p != 7'h7F)
        begin
            one_key[p[5:0]] = 1'b1;
/* LSHIFT */
            if (p[6])
            begin
                one_key[15] = 1'b1;
            end
        end
    end
endfunction

/* Packet parser */
reg [3:0]  idx;
reg [7:0]  mods, k1, k2, k3;
/* acc: the matrix being built, one key code per clock */
reg [63:0] c64_keys, acc;
/* 0 idle, 1..3: decode k1..k3 */
reg [1:0]  dec;
reg        c64_restore;
/* F8 held; the block switch; is a key code in the report? */
reg        f8_held;
reg [1:0]  block_s;

function has(input [7:0] code);
/* the matrix for the machine: no keys while the OSD has the keyboard */
    has = (k1 == code) || (k2 == code) || (k3 == code);
endfunction

/* F-key for the loader: only without Alt (Alt + F-key goes to the C64) */
function fk(input [7:0] code);
    fk = has(code) && !(mods[2] | mods[6]);
endfunction

always @(posedge clk)
begin
/* the outputs, all keys up while the OSD has the keyboard */
    block_s <= {block_s[0], block};
    keys    <= block_s[1] ? 64'd0 : c64_keys;
    restore <= !block_s[1] && c64_restore;
end

/* Alt held; the key being decoded */
wire alt_held = mods[2] | mods[6];
wire [63:0] dk = one_key(dec == 2'd1 ? k1 : dec == DEC_KEY2 ? k2 : k3, alt_held);

/* the packet parser */
always @(posedge clk or negedge rst_n)
    if (!rst_n)
    begin
        idx         <= 4'd0;
/* at reset: no keys */
        mods        <= 8'd0;
        k1          <= 8'd0;
        k2          <= 8'd0;
/* an empty matrix */
        k3          <= 8'd0;
        c64_keys    <= 64'd0;
        acc         <= 64'd0;
/* the decoder idle */
        dec         <= 2'd0;
        c64_restore <= 1'b0;
        lkeys       <= 18'd0;
/* F1, F8 */
        f1          <= 1'b0;
        f8_tgl      <= 1'b0;
        f8_held     <= 1'b0;
/* Ctrl+Alt+Del, no packet seen */
        cad         <= 1'b0;
        seen        <= 1'b0;
        raw         <= 32'd0;
/* three clocks after a packet (a byte takes ~2700) */
    end
    else if (dec != 2'd0)
    begin
        acc <= acc | dk;
        if (dec == 2'd3)
        begin
/* the matrix is complete after the third key */
            c64_keys <= acc | dk;
        end
        dec <= dec == 2'd3 ? 2'd0 : dec + 2'd1;
    end
/* a byte of the keyboard module's packet */
    else if (byte_ok)
    begin
        if (rx_byte == PKT_START_57 || rx_byte == PKT_START_AB || rx_byte == PKT_START_82 || rx_byte == PKT_START_A3)
        begin
            idx <= 4'd0;
        end
        else
        begin
/* by its place in the packet */
            case (idx)
                4'd3: mods <= rx_byte;
                4'd5: k1   <= rx_byte;
/* the keys */
                4'd6: k2   <= rx_byte;
                4'd7: k3   <= rx_byte;
/* the last key: the whole report is there */
                4'd8:
                begin
/* Left Shift  -> LSHIFT */
                    acc <= ({63'd0, mods[1]} << LSHIFT_BIT) |
/* Right Shift -> RSHIFT */
                           ({63'd0, mods[5]} << RSHIFT_BIT) |
/* Ctrl        -> CTRL */
                           ({63'd0, mods[0] | mods[4]} << CTRL_BIT) |
/* Windows     -> C= */
                           ({63'd0, mods[3] | mods[7]} << CBM_BIT);
/* + k1..k3, next clocks */
                    dec <= 2'd1;
                    c64_restore <= has(KEY_PGUP);
/* 17 F4 */
                    lkeys <= {fk(KEY_F4),
/* 16 F3 */
                              fk(KEY_F3),
/* 15 F5 */
                              fk(KEY_F5),
/* 14 Page Down */
                              has(KEY_PGDN),
/* 13 Page Up */
                              has(KEY_PGUP),
/* 12 F2 */
                              fk(KEY_F2),
/* 11 F6 */
                              fk(KEY_F6),
/* 10 F7 / keypad * */
                              fk(KEY_F7) | has(KEY_KP_STAR),
/* 9 Esc / Backspace */
                              has(KEY_ESC) | has(KEY_BACKSPACE),
/* 8 keypad - */
                              has(KEY_KP_MINUS),
/* 7 keypad 5 */
                              has(KEY_KP5),
/* 6 F11 */
                              fk(KEY_F11),
/* 5 keypad Enter / Enter */
                              has(KEY_KP_ENTER) | has(KEY_ENTER),
/* 4 keypad 6 / Right */
                              has(KEY_KP6) | has(KEY_RIGHT),
/* 3 keypad 4 / Left */
                              has(KEY_KP4) | has(KEY_LEFT),
/* 2 keypad 2 / F10 / Down */
                              has(KEY_KP2) | fk(KEY_F10) | has(KEY_DOWN),
/* 1 keypad 8 / F9 / Up */
                              has(KEY_KP8) | fk(KEY_F9) | has(KEY_UP),
/* 0 F12 / keypad / / NumLock */
                              fk(KEY_F12) | has(KEY_KP_SLASH) | has(KEY_NUMLOCK)};
                    f1      <= fk(KEY_F1);
                    f8_held <= fk(KEY_F8);
                    if (fk(KEY_F8) && !f8_held)
                    begin
/* Ctrl+Alt+Del */
                        f8_tgl <= !f8_tgl;
                    end
                    cad     <= has(KEY_DELETE) && (mods[0] | mods[4]) && (mods[2] | mods[6]);
/* a packet was seen; the report for the tape loader */
                    seen    <= 1'b1;
                    raw     <= {mods, k1, k2, k3};
                end
                default: ;
            endcase
/* the next byte's place */
            if (idx != 4'd15)
            begin
                idx <= idx + 4'd1;
            end
        end
    end

endmodule

`default_nettype wire
