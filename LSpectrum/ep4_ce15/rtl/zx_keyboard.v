/* zx_keyboard -- USB keyboard via the CH9350-style UART module (115200 8N1) */
/* -> ZX Spectrum 8 x 5 key matrix */
/* */
/* Packet parsing as in the DE10-Lite reference design (proven with the user's */
/* module): bytes 57, AB, 82, A3 restart the byte counter; counting the other */
/* bytes from 0, byte 3 = HID modifiers, bytes 5, 6, 7 = first three key codes; */
/* the matrix is updated when byte 8 arrives. */
/* */
/* Keys: letters, digits, Enter, Space as on the Spectrum. */
/* Left Shift = CAPS SHIFT; Right Shift or Ctrl = SYMBOL SHIFT. */
/* Extras (not in the reference): Backspace = CAPS+0 (DELETE), arrows = */
/* CAPS+5/6/7/8, Esc = CAPS+SPACE (BREAK). */
/* */
/* rows: 8 x 5 bits, active low; row i is selected by A(8+i): */
/* 0 CAPS Z X C V   1 A S D F G   2 Q W E R T   3 1 2 3 4 5 */
/* 4 0 9 8 7 6      5 P O I U Y   6 ENT L K J H 7 SPC SYM M N B */
/* */
/* Machine and loader keys (docs/SD_TAPE_LOADER.md): */
/* lkeys (1 = held, read by the ESP32 loader firmware, ESP32/v2/src/hw.h K_*): */
/* 0 F12 / keypad / / NumLock   1 keypad 8 / F9 / Up      2 keypad 2 / F10 / Down */
/* 3 keypad 4 / Left            4 keypad 6 / Right        5 keypad Enter / Enter */
/* 6 F11   7 keypad 5   8 keypad -   9 Esc / Backspace   10 F7 / keypad *   11 F6 */
/* 12 F2 (save a snapshot)   13 Page Up   14 Page Down   15 F5 (contention on/off) */
/* 16 F3 (Bluetooth audio menu)   17 F4 (joystick menu) */
/* f1      F1 held (DiagROM when the CPU starts) */
/* f8_tgl  toggles on every F8 press (50/60 Hz video) */
/* cad     Ctrl + Alt + Del held (back to the machine menu, LSpectrum.v) */
/* seen    a complete packet has arrived since power-up */
/* raw     {modifiers, key 1, key 2, key 3} of the last packet (text input in the tape loader) */
/* block   (asynchronous) the OSD browser is open: all Spectrum keys released */
/* Reset by power-on only, so F1 is still known after a KEY0 reset. */
`default_nettype none

module zx_keyboard #(
    parameter integer CLK_HZ = 112000000,
    parameter integer BAUD   = 115200
)(
    input  wire        clk,
    input  wire        rst_n,
/* asynchronous */
    input  wire        rx,
/* asynchronous: release all Spectrum keys */
    input  wire        block,
    output reg  [39:0] rows,
    output reg  [17:0] lkeys,
    output reg         f1,
    output reg         f8_tgl,
    output reg         cad,
    output reg         seen,
    output reg  [31:0] raw
);

/* USB key code: Backspace */
localparam [7:0] KEY_BACKSPACE = 8'h2A;
/* USB key code: cursor left */
localparam [7:0] KEY_LEFT = 8'h50;
/* USB key code: cursor down */
localparam [7:0] KEY_DOWN = 8'h51;
/* USB key code: cursor up */
localparam [7:0] KEY_UP = 8'h52;
/* USB key code: cursor right */
localparam [7:0] KEY_RIGHT = 8'h4F;
/* USB key code: Esc */
localparam [7:0] KEY_ESC = 8'h29;
/* keys of the Spectrum matrix: 8 rows of 5 */
localparam integer MATRIX_KEYS = 40;
/* a byte that restarts the packet's byte counter */
localparam [7:0] PKT_START_57 = 8'h57;
/* a byte that restarts the packet's byte counter */
localparam [7:0] PKT_START_AB = 8'hAB;
/* a byte that restarts the packet's byte counter */
localparam [7:0] PKT_START_82 = 8'h82;
/* a byte that restarts the packet's byte counter */
localparam [7:0] PKT_START_A3 = 8'hA3;
/* matrix bit of SYMBOL SHIFT (row 7, bit 1) */
localparam integer SYM_BIT = 36;
/* USB key code: F4 */
localparam [7:0] KEY_F4 = 8'h3D;
/* USB key code: F3 */
localparam [7:0] KEY_F3 = 8'h3C;
/* USB key code: F5 */
localparam [7:0] KEY_F5 = 8'h3E;
/* USB key code: Page Down */
localparam [7:0] KEY_PGDN = 8'h4E;
/* USB key code: Page Up */
localparam [7:0] KEY_PGUP = 8'h4B;
/* USB key code: F2 */
localparam [7:0] KEY_F2 = 8'h3B;
/* USB key code: F6 */
localparam [7:0] KEY_F6 = 8'h3F;
/* USB key code: F7 */
localparam [7:0] KEY_F7 = 8'h40;
/* USB key code: keypad * */
localparam [7:0] KEY_KP_STAR = 8'h55;
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
/* USB key code: keypad 4 */
localparam [7:0] KEY_KP4 = 8'h5C;
/* USB key code: keypad 2 */
localparam [7:0] KEY_KP2 = 8'h5A;
/* USB key code: F10 */
localparam [7:0] KEY_F10 = 8'h43;
/* USB key code: keypad 8 */
localparam [7:0] KEY_KP8 = 8'h60;
/* USB key code: F9 */
localparam [7:0] KEY_F9 = 8'h42;
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

/* HID key code -> matrix bit (5 * row + column), or 63 for no key */
function [5:0] key_pos(input [7:0] code);
    case (code)
/* Z X C V */
        8'h1D: key_pos = 6'd1;
        8'h1B: key_pos = 6'd2;
        8'h06: key_pos = 6'd3;
/* V */
        8'h19: key_pos = 6'd4;
/* A S D F */
        8'h04: key_pos = 6'd5;
        8'h16: key_pos = 6'd6;
        8'h07: key_pos = 6'd7;
/* F */
        8'h09: key_pos = 6'd8;
/* G */
        8'h0A: key_pos = 6'd9;
/* Q W E R */
        8'h14: key_pos = 6'd10;
        8'h1A: key_pos = 6'd11;
        8'h08: key_pos = 6'd12;
/* R */
        8'h15: key_pos = 6'd13;
/* T */
        8'h17: key_pos = 6'd14;
/* 1 2 3 4 */
        8'h1E: key_pos = 6'd15;
        8'h1F: key_pos = 6'd16;
        8'h20: key_pos = 6'd17;
/* 4 */
        8'h21: key_pos = 6'd18;
/* 5 */
        8'h22: key_pos = 6'd19;
/* 0 9 8 7 */
        8'h27: key_pos = 6'd20;
        8'h26: key_pos = 6'd21;
        8'h25: key_pos = 6'd22;
/* 7 */
        8'h24: key_pos = 6'd23;
/* 6 */
        8'h23: key_pos = 6'd24;
/* P O I U */
        8'h13: key_pos = 6'd25;
        8'h12: key_pos = 6'd26;
        8'h0C: key_pos = 6'd27;
/* U */
        8'h18: key_pos = 6'd28;
/* Y */
        8'h1C: key_pos = 6'd29;
/* ENT L K J */
        8'h28: key_pos = 6'd30;
        8'h0F: key_pos = 6'd31;
        8'h0E: key_pos = 6'd32;
/* J */
        8'h0D: key_pos = 6'd33;
/* H */
        8'h0B: key_pos = 6'd34;
/* SPC M N */
        8'h2C: key_pos = 6'd35;
        8'h10: key_pos = 6'd37;
        8'h11: key_pos = 6'd38;
/* B */
        8'h05: key_pos = 6'd39;
/* extras with CAPS SHIFT (bit 0) */
/* Backspace -> 0 */
        8'h2A: key_pos = 6'd20;
/* Left  -> 5 */
        8'h50: key_pos = 6'd19;
/* Down  -> 6 */
        8'h51: key_pos = 6'd24;
/* Up    -> 7 */
        8'h52: key_pos = 6'd23;
/* Right -> 8 */
        8'h4F: key_pos = 6'd22;
/* Esc   -> SPACE */
        8'h29: key_pos = 6'd35;
        default: key_pos = 6'd63;
    endcase
endfunction

/* keys that are CAPS SHIFT + another key */
function caps_extra(input [7:0] code);
    caps_extra = (code == KEY_BACKSPACE) || (code == KEY_LEFT) || (code == KEY_DOWN) ||
                 (code == KEY_UP) || (code == KEY_RIGHT) || (code == KEY_ESC);
endfunction

function [39:0] one_key(input [7:0] code);
    begin
/* the key's matrix position, if it has one */
        one_key = 40'd0;
        if (key_pos(code) != 6'd63)
        begin
            one_key[key_pos(code)] = 1'b1;
        end
/* with CAPS SHIFT */
        if (caps_extra(code))
        begin
            one_key[0] = 1'b1;
        end
    end
endfunction

/* Packet parser */
reg [3:0]  idx;
reg [7:0]  mods, k1, k2, k3;
reg [39:0] zx_rows;
/* F8 held; the block switch; is a key code in the report? */
reg        f8_held;
reg [1:0]  block_s;

function has(input [7:0] code);
/* the matrix for the machine: no keys while the OSD has the keyboard */
    has = (k1 == code) || (k2 == code) || (k3 == code);
endfunction

always @(posedge clk)
begin
    block_s <= {block_s[0], block};
/* all released then */
    rows    <= block_s[1] ? {MATRIX_KEYS{1'b1}} : zx_rows;
end

/* the packet parser */
always @(posedge clk or negedge rst_n)
    if (!rst_n)
    begin
        idx     <= 4'd0;
/* no keys */
        mods    <= 8'd0;
        k1      <= 8'd0;
        k2      <= 8'd0;
/* third key; nothing pressed */
        k3      <= 8'd0;
        zx_rows <= {MATRIX_KEYS{1'b1}};
        lkeys   <= 18'd0;
/* function keys */
        f1      <= 1'b0;
        f8_tgl  <= 1'b0;
        f8_held <= 1'b0;
/* Ctrl+Alt+Del, a packet seen, the raw report */
        cad     <= 1'b0;
        seen    <= 1'b0;
        raw     <= 32'd0;
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
                    zx_rows <= ~(one_key(k1) | one_key(k2) | one_key(k3) |
/* Left Shift  -> CAPS (bit 0) */
                                 {39'd0, mods[1]} |
/* RShift/Ctrl -> SYM (bit 36) */
                                 ({39'd0, mods[5] | mods[0] | mods[4]} << SYM_BIT));
/* 17 F4 */
                    lkeys <= {has(KEY_F4),
/* 16 F3 */
                              has(KEY_F3),
/* 15 F5 */
                              has(KEY_F5),
/* 14 Page Down */
                              has(KEY_PGDN),
/* 13 Page Up */
                              has(KEY_PGUP),
/* 12 F2 */
                              has(KEY_F2),
/* 11 F6 */
                              has(KEY_F6),
/* 10 F7 / keypad * */
                              has(KEY_F7) | has(KEY_KP_STAR),
/* 9 Esc / Backspace */
                              has(KEY_ESC) | has(KEY_BACKSPACE),
/* 8 keypad - */
                              has(KEY_KP_MINUS),
/* 7 keypad 5 */
                              has(KEY_KP5),
/* 6 F11 */
                              has(KEY_F11),
/* 5 keypad Enter / Enter */
                              has(KEY_KP_ENTER) | has(KEY_ENTER),
/* 4 keypad 6 / Right */
                              has(KEY_KP6) | has(KEY_RIGHT),
/* 3 keypad 4 / Left */
                              has(KEY_KP4) | has(KEY_LEFT),
/* 2 keypad 2 / F10 / Down */
                              has(KEY_KP2) | has(KEY_F10) | has(KEY_DOWN),
/* 1 keypad 8 / F9 / Up */
                              has(KEY_KP8) | has(KEY_F9) | has(KEY_UP),
/* 0 F12 / keypad / / NumLock */
                              has(KEY_F12) | has(KEY_KP_SLASH) | has(KEY_NUMLOCK)};
                    f1      <= has(KEY_F1);
                    f8_held <= has(KEY_F8);
/* a new F8 press toggles 50 / 60 Hz */
                    if (has(KEY_F8) && !f8_held)
                    begin
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
