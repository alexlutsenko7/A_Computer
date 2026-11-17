/* nes_keyboard -- USB keyboard via the CH9350-style UART module (115200 8N1) */
/* -> the NES controllers' buttons that are not on the joysticks, the Reset button, loader keys */
/* */
/* UART and packet parsing as the other machines' keyboards: bytes 57, AB, 82, A3 restart the */
/* byte counter; byte 3 = HID modifiers, bytes 5..7 = three key codes; a report is complete */
/* when byte 8 arrives. */
/* */
/* The joysticks give a controller's directions and its A button (LNES.v); the keyboard gives */
/* the other buttons: */
/* controller 1:  B = Z or left Ctrl,  Select = Tab,  Start = Enter;  A also on X and Space */
/* controller 2:  B = F,  Select = R,  Start = T;  A also on G */
/* btn1 / btn2 = {Start, Select, B, A}, 1 = pressed; none while the OSD has the keyboard (block). */
/* Alt + F5 = the console's Reset button. */
/* */
/* Machine and loader keys as the other machines (lkeys bit meanings identical, read by the */
/* ESP32 firmware); F-keys held together with Alt are not loader keys: */
/* lkeys: 0 F12 / keypad / / NumLock   1 keypad 8 / F9 / Up   2 keypad 2 / F10 / Down */
/* 3 keypad 4 / Left   4 keypad 6 / Right   5 keypad Enter / Enter   6 F11   7 keypad 5 */
/* 8 keypad -   9 Esc / Backspace   10 F7 / keypad *   11 F6   12 F2   13 Page Up */
/* 14 Page Down   15 F5   16 F3   17 F4 */
/* f8_tgl toggles on F8 (LMega: 50 Hz allowed; LNES does not use it), cad = Ctrl + Alt + Del, seen = a packet arrived, raw = {modifiers, key 1, key 2, key 3}. */
/* Reset by power-on only. */
`default_nettype none

module nes_keyboard #(
    parameter integer CLK_HZ = 21448864,
    parameter integer BAUD   = 115200
)(
    input  wire        clk,
    input  wire        rst_n,
/* asynchronous */
    input  wire        rx,
/* asynchronous: no pad buttons */
    input  wire        block,

    output reg  [3:0]  btn1,
    output reg  [3:0]  btn2,
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
/* USB key code: Delete */
localparam [7:0] KEY_DELETE = 8'h4C;

/* USB key codes of the pad buttons: Z, X, Tab, F, G, R, T */
localparam [7:0] KEY_Z = 8'h1D;
localparam [7:0] KEY_X = 8'h1B;
localparam [7:0] KEY_TAB = 8'h2B;
/* controller 2's keys */
localparam [7:0] KEY_F = 8'h09;
localparam [7:0] KEY_G = 8'h0A;
localparam [7:0] KEY_R = 8'h15;
/* Start of controller 2 */
localparam [7:0] KEY_T = 8'h17;
/* USB key code: F8 */
localparam [7:0] KEY_F8 = 8'h41;
/* USB key code: space */
localparam [7:0] KEY_SPACE = 8'h2C;

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

/* Packet parser */
reg [3:0]  idx;
reg [7:0]  mods, k1, k2, k3;
reg [1:0]  block_s;
/* what the parser found: the buttons, Reset */
reg [3:0]  a_btn1, a_btn2;
reg        a_rst;
/* F8 as seen in the report before */
reg        f8_held;

/* is a USB code among the three keys held? */
function has(input [7:0] code);
    has = (k1 == code) || (k2 == code) || (k3 == code);
endfunction

/* Alt held */
wire alt_held = mods[2] | mods[6];

/* F-key for the loader: only without Alt */
function fk(input [7:0] code);
    fk = has(code) && !alt_held;
endfunction

always @(posedge clk)
begin
/* the OSD's state, synchronised */
    block_s   <= {block_s[0], block};
/* the outputs, blocked while the OSD has the keyboard */
    btn1      <= block_s[1] ? 4'd0 : a_btn1;
    btn2      <= block_s[1] ? 4'd0 : a_btn2;
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
/* the third key */
        k3       <= 8'd0;
/* no buttons, no Reset */
        a_btn1   <= 4'd0;
        a_btn2   <= 4'd0;
        a_rst    <= 1'b0;
/* the loader's keys */
        lkeys    <= 18'd0;
        f8_tgl   <= 1'b0;
        f8_held  <= 1'b0;
/* no Ctrl+Alt+Del, no packet seen */
        cad      <= 1'b0;
        seen     <= 1'b0;
/* no report yet */
        raw      <= 32'd0;
    end
    else
    begin
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
/* the second key */
                    4'd6: k2   <= rx_byte;
                    4'd7: k3   <= rx_byte;
/* the last key: the whole report is there */
                    4'd8:
                    begin
/* {Start, Select, B, A} of the two controllers */
                        a_btn1 <= {has(KEY_ENTER), has(KEY_TAB), has(KEY_Z) | mods[0],
                                   has(KEY_X) | has(KEY_SPACE)};
                        a_btn2 <= {has(KEY_T), has(KEY_R), has(KEY_F), has(KEY_G)};
                        a_rst  <= has(KEY_F5) && alt_held;
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
/* F8: once per press */
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
