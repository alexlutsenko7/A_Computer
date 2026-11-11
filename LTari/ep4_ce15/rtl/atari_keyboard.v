/* atari_keyboard -- USB keyboard via the CH9350-style UART module (115200 8N1) */
/* -> POKEY key codes, console keys, Break, Reset */
/* */
/* UART and packet parsing as c64_keyboard (L64): bytes 57, AB, 82, A3 restart the */
/* byte counter; byte 3 = HID modifiers, bytes 5..7 = three key codes; a report is */
/* complete when byte 8 arrives. */
/* */
/* Atari keys (scan codes: Altirra Hardware Reference Manual table 11, NOTES.md). PC keys */
/* by their meaning where the Atari has the key, else by position (US layout): */
/* letters, digits, Enter = Return, Esc, Backspace = Delete/Back S, Tab, Space, Caps Lock, */
/* - = ; , . / as on the Atari;  ' -> +  \ -> *  [ -> <  ] -> >  ` -> Inverse (Atari logo); */
/* arrows -> Control + - = + * (the Atari's cursor keys);  Home -> Shift + < (Clear); */
/* Delete -> Control + Back S (delete character);  Insert -> Control + > (insert character); */
/* Shift / Control -> Shift / Control;  Pause -> Break. */
/* Alt + F2 / F3 / F4 = START / SELECT / OPTION (CONSOL, held as long as the keys), */
/* Alt + F5 = Reset (the XL/XE system reset), Alt + F6 = Help, Alt + F7 = Break. */
/* POKEY side: key_stb pulses when an Atari key is pressed (the newest key of the report) */
/* with key_code and the Shift / Control state at that moment (key_shift / key_ctrl, which */
/* also follow the modifiers continuously, for SKSTAT); key_down while any Atari key is */
/* held (SKSTAT bit 2: the OS's key repeat); key_break pulses on Break. */
/* */
/* Machine and loader keys as c64_keyboard (lkeys bit meanings identical, read by the */
/* ESP32 firmware); F-keys held together with Alt go to the Atari only: */
/* lkeys: 0 F12 / keypad / / NumLock   1 keypad 8 / F9 / Up   2 keypad 2 / F10 / Down */
/* 3 keypad 4 / Left   4 keypad 6 / Right   5 keypad Enter / Enter   6 F11   7 keypad 5 */
/* 8 keypad -   9 Esc / Backspace   10 F7 / keypad *   11 F6   12 F2   13 Page Up */
/* 14 Page Down   15 F5   16 F3   17 F4 */
/* f8_tgl toggles on F8, cad = Ctrl + Alt + Del, seen = a packet arrived, */
/* raw = {modifiers, key 1, key 2, key 3}, block (asynchronous) = OSD open: no Atari keys. */
/* Reset by power-on only. */
`default_nettype none

module atari_keyboard #(
    parameter integer CLK_HZ = 28373016,
    parameter integer BAUD   = 115200
)(
    input  wire        clk,
    input  wire        rst_n,
/* asynchronous */
    input  wire        rx,
/* asynchronous: release all Atari keys */
    input  wire        block,

    output reg         key_stb,
    output reg  [5:0]  key_code,
    output reg         key_down,
    output reg         key_shift,
    output reg         key_ctrl,
    output reg         key_break,
/* START, SELECT, OPTION (0 = held) */
    output reg  [2:0]  consol_n,
    output reg         reset_key,

    output reg  [17:0] lkeys,
    output reg         f8_tgl,
    output reg         cad,
    output reg         seen,
    output reg  [31:0] raw
);

/* a byte that restarts the packet's byte counter */
localparam [7:0] PKT_START_57 = 8'h57;
/* a byte that restarts the packet's byte counter */
localparam [7:0] PKT_START_AB = 8'hAB;
/* a byte that restarts the packet's byte counter */
localparam [7:0] PKT_START_82 = 8'h82;
/* a byte that restarts the packet's byte counter */
localparam [7:0] PKT_START_A3 = 8'hA3;
/* USB key code: Pause */
localparam [7:0] KEY_PAUSE = 8'h48;
/* USB key code: F7 */
localparam [7:0] KEY_F7 = 8'h40;
/* USB key code: F4 */
localparam [7:0] KEY_F4 = 8'h3D;
/* USB key code: F3 */
localparam [7:0] KEY_F3 = 8'h3C;
/* USB key code: F2 */
localparam [7:0] KEY_F2 = 8'h3B;
/* USB key code: F5 */
localparam [7:0] KEY_F5 = 8'h3E;
/* USB key code: Page Down */
localparam [7:0] KEY_PGDN = 8'h4E;
/* USB key code: Page Up */
localparam [7:0] KEY_PGUP = 8'h4B;
/* USB key code: F6 */
localparam [7:0] KEY_F6 = 8'h3F;
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

/* HID key code -> {valid, forced Control, forced Shift, scan code} */
function [8:0] akey(input [7:0] code, input alt);
    case (code)
/* A B C */
        8'h04: akey = {3'b100, 6'h3F};
        8'h05: akey = {3'b100, 6'h15};
        8'h06: akey = {3'b100, 6'h12};
/* D E F */
        8'h07: akey = {3'b100, 6'h3A};
        8'h08: akey = {3'b100, 6'h2A};
        8'h09: akey = {3'b100, 6'h38};
/* G H I */
        8'h0A: akey = {3'b100, 6'h3D};
        8'h0B: akey = {3'b100, 6'h39};
        8'h0C: akey = {3'b100, 6'h0D};
/* J K L */
        8'h0D: akey = {3'b100, 6'h01};
        8'h0E: akey = {3'b100, 6'h05};
        8'h0F: akey = {3'b100, 6'h00};
/* M N O */
        8'h10: akey = {3'b100, 6'h25};
        8'h11: akey = {3'b100, 6'h23};
        8'h12: akey = {3'b100, 6'h08};
/* P Q R */
        8'h13: akey = {3'b100, 6'h0A};
        8'h14: akey = {3'b100, 6'h2F};
        8'h15: akey = {3'b100, 6'h28};
/* S T U */
        8'h16: akey = {3'b100, 6'h3E};
        8'h17: akey = {3'b100, 6'h2D};
        8'h18: akey = {3'b100, 6'h0B};
/* V W X */
        8'h19: akey = {3'b100, 6'h10};
        8'h1A: akey = {3'b100, 6'h2E};
        8'h1B: akey = {3'b100, 6'h16};
/* Y Z */
        8'h1C: akey = {3'b100, 6'h2B};
        8'h1D: akey = {3'b100, 6'h17};
/* 1 2 3 */
        8'h1E: akey = {3'b100, 6'h1F};
        8'h1F: akey = {3'b100, 6'h1E};
        8'h20: akey = {3'b100, 6'h1A};
/* 4 5 6 */
        8'h21: akey = {3'b100, 6'h18};
        8'h22: akey = {3'b100, 6'h1D};
        8'h23: akey = {3'b100, 6'h1B};
/* 7 8 9 */
        8'h24: akey = {3'b100, 6'h33};
        8'h25: akey = {3'b100, 6'h35};
        8'h26: akey = {3'b100, 6'h30};
/* 0 */
        8'h27: akey = {3'b100, 6'h32};
/* Return Esc Back S */
        8'h28: akey = {3'b100, 6'h0C};
        8'h29: akey = {3'b100, 6'h1C};
        8'h2A: akey = {3'b100, 6'h34};
/* Tab Space - */
        8'h2B: akey = {3'b100, 6'h2C};
        8'h2C: akey = {3'b100, 6'h21};
        8'h2D: akey = {3'b100, 6'h0E};
/* = [-> < ]-> > */
        8'h2E: akey = {3'b100, 6'h0F};
        8'h2F: akey = {3'b100, 6'h36};
        8'h30: akey = {3'b100, 6'h37};
/* \-> * ; '-> + */
        8'h31: akey = {3'b100, 6'h07};
        8'h33: akey = {3'b100, 6'h02};
        8'h34: akey = {3'b100, 6'h06};
/* `-> Inv , . */
        8'h35: akey = {3'b100, 6'h27};
        8'h36: akey = {3'b100, 6'h20};
        8'h37: akey = {3'b100, 6'h22};
/* / Caps */
        8'h38: akey = {3'b100, 6'h26};
        8'h39: akey = {3'b100, 6'h3C};
/* Home: Clear */
        8'h4A: akey = {3'b101, 6'h36};
/* Delete Insert */
        8'h4C: akey = {3'b110, 6'h34};
        8'h49: akey = {3'b110, 6'h37};
/* Right Left */
        8'h4F: akey = {3'b110, 6'h07};
        8'h50: akey = {3'b110, 6'h06};
/* Down Up */
        8'h51: akey = {3'b110, 6'h0F};
        8'h52: akey = {3'b110, 6'h0E};
/* Alt+F6: Help */
        8'h3F: akey = alt ? {3'b100, 6'h11} : 9'd0;
        default: akey = 9'd0;
    endcase
endfunction

/* Packet parser */
reg [3:0]  idx;
reg [7:0]  mods, k1, k2, k3;
/* the report before */
reg [7:0]  p1, p2, p3;
reg [1:0]  block_s;
reg        f8_held, brk_held;
/* what the parser found: strobe, key down, forced Shift / Control, Break, Reset */
reg        a_stb, a_down, a_fs, a_fc, a_brk, a_rst;
reg [5:0]  a_code;
reg [2:0]  a_consol;

/* is a USB code among the three keys held? */
function has(input [7:0] code);
/* the matrix for the machine: no keys while the OSD has the keyboard */
    has = (k1 == code) || (k2 == code) || (k3 == code);
endfunction

function had(input [7:0] code);
    had = (p1 == code) || (p2 == code) || (p3 == code);
endfunction

/* Alt held */
wire alt_held = mods[2] | mods[6];

/* F-key for the loader: only without Alt (Alt + F-key goes to the Atari) */
function fk(input [7:0] code);
    fk = has(code) && !alt_held;
endfunction

function ak(input [7:0] code);
/* the three keys as Atari keys */
    ak = has(code) && alt_held;
endfunction

wire [8:0] m1 = akey(k1, alt_held);
wire [8:0] m2 = akey(k2, alt_held);
/* the third key */
wire [8:0] m3 = akey(k3, alt_held);
/* newly pressed */
wire       n1 = m1[8] && !had(k1);
wire       n2 = m2[8] && !had(k2);
wire       n3 = m3[8] && !had(k3);
/* the newest new key (the last in the report) */
wire [8:0] mn = n3 ? m3 : n2 ? m2 : m1;
/* a held key (forced modifiers while held) */
wire [8:0] mh = m3[8] ? m3 : m2[8] ? m2 : m1;

always @(posedge clk)
begin
    block_s   <= {block_s[0], block};
/* the outputs, blocked while the OSD has the keyboard */
    key_stb   <= a_stb && !block_s[1];
    key_code  <= a_code;
    key_down  <= a_down && !block_s[1];
/* Shift and Control: the real keys or forced by the mapping */
    key_shift <= (mods[1] | mods[5] | (a_down && a_fs)) && !block_s[1];
    key_ctrl  <= (mods[0] | mods[4] | (a_down && a_fc)) && !block_s[1];
    key_break <= a_brk && !block_s[1];
/* the console keys, active low; the Reset key */
    consol_n  <= block_s[1] ? 3'b111 : ~a_consol;
    reset_key <= a_rst && !block_s[1];
end

/* the packet parser */
always @(posedge clk or negedge rst_n)
    if (!rst_n)
    begin
        idx      <= 4'd0;
/* at reset: no keys */
        mods     <= 8'd0;
        k1       <= 8'd0;
        k2       <= 8'd0;
/* the keys of the previous packet */
        k3       <= 8'd0;
        p1       <= 8'd0;
        p2       <= 8'd0;
/* no key event */
        p3       <= 8'd0;
        a_stb    <= 1'b0;
        a_down   <= 1'b0;
/* no forced modifiers */
        a_fs     <= 1'b0;
        a_fc     <= 1'b0;
        a_code   <= 6'd0;
/* no Break, no Reset, no console keys */
        a_brk    <= 1'b0;
        a_rst    <= 1'b0;
        a_consol <= 3'd0;
/* the loader's keys */
        brk_held <= 1'b0;
        lkeys    <= 18'd0;
        f8_tgl   <= 1'b0;
/* F8, Ctrl+Alt+Del, no packet seen */
        f8_held  <= 1'b0;
        cad      <= 1'b0;
        seen     <= 1'b0;
/* the raw word */
        raw      <= 32'd0;
    end
    else
    begin
        a_stb <= 1'b0;
        a_brk <= 1'b0;
/* a byte of the packet */
        if (byte_ok)
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
/* Atari side */
                        if (n1 || n2 || n3)
                        begin
                            a_stb  <= 1'b1;
                            a_code <= mn[5:0];
/* its forced modifiers */
                            a_fs   <= mn[6];
                            a_fc   <= mn[7];
                        end
                        else if (mh[8])
                        begin
/* the key held */
                            a_fs   <= mh[6];
                            a_fc   <= mh[7];
                        end
                        a_down   <= m1[8] | m2[8] | m3[8];
/* Break: once per press */
                        brk_held <= has(KEY_PAUSE) | ak(KEY_F7);
                        if ((has(KEY_PAUSE) | ak(KEY_F7)) && !brk_held)
                        begin
                            a_brk <= 1'b1;
                        end
/* OPTION SELECT START */
                        a_consol <= {ak(KEY_F4), ak(KEY_F3), ak(KEY_F2)};
                        a_rst    <= ak(KEY_F5);
                        p1 <= k1;
/* the keys are remembered */
                        p2 <= k2;
                        p3 <= k3;
/* loader side */
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
                        f8_held <= fk(KEY_F8);
                        if (fk(KEY_F8) && !f8_held)
                        begin
                            f8_tgl <= !f8_tgl;
                        end
/* Ctrl+Alt+Del */
                        cad     <= has(KEY_DELETE) && (mods[0] | mods[4]) && alt_held;
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
    end

endmodule

`default_nettype wire
