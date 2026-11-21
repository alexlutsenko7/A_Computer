/* next_keyboard -- LNext: USB keyboard via the CH9350-style UART module (115200 8N1) */
/* -> key events for the Spectrum Next core, loader keys for the ESP32 */
/* */
/* UART and packet parsing as the other machines' keyboards: bytes 57, AB, 82, A3 restart the */
/* byte counter; byte 3 = HID modifiers, bytes 5..7 = three key codes; a report is complete */
/* when byte 8 arrives. */
/* */
/* The Next core (its MiSTer port) takes key events as PS/2 set 2 codes: ps2_key = {strobe that */
/* toggles, 1 = pressed, extended code, code}. Every change between two reports becomes one */
/* event: the eight modifier keys, then the keys released, then the keys pressed. The core maps */
/* the PC keys onto the Spectrum's matrix itself (the cursor keys, Backspace, punctuation ...). */
/* While the OSD has the keyboard (block), all keys are released for the machine. */
/* */
/* Function keys (one function per key; the core's own numbering where it does not collide with */
/* the board's): F1 hard reset, F4 soft reset, F6 CPU speed, F8 50 / 60 Hz, F9 Multiface NMI, */
/* F10 DivMMC NMI. The ESP32's keys: F3 Bluetooth menu, F12 tape browser, F7 tape stop, F11 tape */
/* pause / go on; F2 and F5 do nothing. */
/* */
/* The six keys above the cursor keys are the joysticks' extra buttons and no keys of the machine: */
/* pad = {Page Down, End, Delete, Page Up, Home, Insert}, 1 = held (Delete not with Ctrl + Alt; */
/* none while the OSD has the keyboard). LNext.v gives Insert / Home / Page Up to the left */
/* joystick and Delete / End / Page Down to the right one. */
/* */
/* lkeys (bit meanings as the other machines, read by the ESP32 firmware): */
/* 0 F12   1 keypad 8 / Up   2 keypad 2 / Down   3 keypad 4 / Left   4 keypad 6 / Right */
/* 5 keypad Enter / Enter   6 F11   9 Esc / Backspace   10 F7   16 F3;   the others are 0 here. */
/* cad = Ctrl + Alt + Del, seen = a packet arrived, raw = {modifiers, key 1, key 2, key 3}. */
/* Reset by power-on only. */
`default_nettype none

module next_keyboard #(
    parameter integer CLK_HZ = 56000000,
    parameter integer BAUD   = 115200
)(
    input  wire        clk,
    input  wire        rst_n,
/* asynchronous */
    input  wire        rx,
/* asynchronous: the OSD has the keyboard */
    input  wire        block,

/* key events for the core: [10] toggles per event, [9] pressed, [8] extended, [7:0] code */
    output reg  [10:0] ps2_key,
/* the joysticks' extra buttons: [5:0] = Page Down, End, Delete, Page Up, Home, Insert */
    output reg  [5:0]  pad,

    output reg  [17:0] lkeys,
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
/* the packet's bytes: modifiers, the three keys */
localparam [3:0] PKT_MODS = 4'd3;
localparam [3:0] PKT_KEY1 = 4'd5;
localparam [3:0] PKT_KEY2 = 4'd6;
localparam [3:0] PKT_KEY3 = 4'd7;
/* the byte that completes a report; the counter's end */
localparam [3:0] PKT_DONE = 4'd8;
localparam [3:0] PKT_LAST = 4'd15;
/* USB key codes of the loader keys */
localparam [7:0] KEY_F3 = 8'h3C;
localparam [7:0] KEY_F12 = 8'h45;
/* the tape player's keys */
localparam [7:0] KEY_F7 = 8'h40;
localparam [7:0] KEY_F11 = 8'h44;
localparam [7:0] KEY_ESC = 8'h29;
/* Backspace, the two Enter keys */
localparam [7:0] KEY_BACKSPACE = 8'h2A;
localparam [7:0] KEY_KP_ENTER = 8'h58;
localparam [7:0] KEY_ENTER = 8'h28;
/* right and left */
localparam [7:0] KEY_KP6 = 8'h5E;
localparam [7:0] KEY_RIGHT = 8'h4F;
localparam [7:0] KEY_KP4 = 8'h5C;
localparam [7:0] KEY_LEFT = 8'h50;
/* down and up */
localparam [7:0] KEY_KP2 = 8'h5A;
localparam [7:0] KEY_DOWN = 8'h51;
localparam [7:0] KEY_KP8 = 8'h60;
localparam [7:0] KEY_UP = 8'h52;
/* the six keys above the cursor keys: the joysticks' extra buttons */
localparam [7:0] KEY_INSERT = 8'h49;
localparam [7:0] KEY_HOME = 8'h4A;
localparam [7:0] KEY_PAGE_UP = 8'h4B;
/* Delete is also the third key of Ctrl + Alt + Del */
localparam [7:0] KEY_DELETE = 8'h4C;
localparam [7:0] KEY_END = 8'h4D;
localparam [7:0] KEY_PAGE_DOWN = 8'h4E;
/* USB codes below this one are no keys (none, rollover errors) */
localparam [7:0] KEY_FIRST = 8'h04;
/* the USB codes of the eight modifier keys start here */
localparam [7:0] KEY_MODS = 8'hE0;

/* the steps of a comparison: 8 modifiers, 3 keys to release, 3 keys to press */
localparam [3:0] STEP_REL = 4'd8;
localparam [3:0] STEP_PRESS = 4'd11;
localparam [3:0] STEP_LAST = 4'd13;
/* the event machine */
localparam [2:0] EV_IDLE = 3'd0;
localparam [2:0] EV_STEP = 3'd1;
localparam [2:0] EV_CODE = 3'd2;
localparam [2:0] EV_DATA = 3'd3;
localparam [2:0] EV_GAP = 3'd4;
/* clocks from the event's data to its strobe, and from the strobe to the next event */
localparam [6:0] T_SETUP = 7'd15;
localparam [6:0] T_GAP = 7'd127;

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

/* the PS/2 set 2 code of a USB key code: {known, extended, code} */
function [9:0] ps2_of(input [7:0] usb);
    begin
        case (usb)
/* A */
            8'h04: ps2_of = {1'b1, 1'b0, 8'h1C};
/* B */
            8'h05: ps2_of = {1'b1, 1'b0, 8'h32};
/* C */
            8'h06: ps2_of = {1'b1, 1'b0, 8'h21};
/* D */
            8'h07: ps2_of = {1'b1, 1'b0, 8'h23};
/* E */
            8'h08: ps2_of = {1'b1, 1'b0, 8'h24};
/* F */
            8'h09: ps2_of = {1'b1, 1'b0, 8'h2B};
/* G */
            8'h0A: ps2_of = {1'b1, 1'b0, 8'h34};
/* H */
            8'h0B: ps2_of = {1'b1, 1'b0, 8'h33};
/* I */
            8'h0C: ps2_of = {1'b1, 1'b0, 8'h43};
/* J */
            8'h0D: ps2_of = {1'b1, 1'b0, 8'h3B};
/* K */
            8'h0E: ps2_of = {1'b1, 1'b0, 8'h42};
/* L */
            8'h0F: ps2_of = {1'b1, 1'b0, 8'h4B};
/* M */
            8'h10: ps2_of = {1'b1, 1'b0, 8'h3A};
/* N */
            8'h11: ps2_of = {1'b1, 1'b0, 8'h31};
/* O */
            8'h12: ps2_of = {1'b1, 1'b0, 8'h44};
/* P */
            8'h13: ps2_of = {1'b1, 1'b0, 8'h4D};
/* Q */
            8'h14: ps2_of = {1'b1, 1'b0, 8'h15};
/* R */
            8'h15: ps2_of = {1'b1, 1'b0, 8'h2D};
/* S */
            8'h16: ps2_of = {1'b1, 1'b0, 8'h1B};
/* T */
            8'h17: ps2_of = {1'b1, 1'b0, 8'h2C};
/* U */
            8'h18: ps2_of = {1'b1, 1'b0, 8'h3C};
/* V */
            8'h19: ps2_of = {1'b1, 1'b0, 8'h2A};
/* W */
            8'h1A: ps2_of = {1'b1, 1'b0, 8'h1D};
/* X */
            8'h1B: ps2_of = {1'b1, 1'b0, 8'h22};
/* Y */
            8'h1C: ps2_of = {1'b1, 1'b0, 8'h35};
/* Z */
            8'h1D: ps2_of = {1'b1, 1'b0, 8'h1A};
/* 1 */
            8'h1E: ps2_of = {1'b1, 1'b0, 8'h16};
/* 2 */
            8'h1F: ps2_of = {1'b1, 1'b0, 8'h1E};
/* 3 */
            8'h20: ps2_of = {1'b1, 1'b0, 8'h26};
/* 4 */
            8'h21: ps2_of = {1'b1, 1'b0, 8'h25};
/* 5 */
            8'h22: ps2_of = {1'b1, 1'b0, 8'h2E};
/* 6 */
            8'h23: ps2_of = {1'b1, 1'b0, 8'h36};
/* 7 */
            8'h24: ps2_of = {1'b1, 1'b0, 8'h3D};
/* 8 */
            8'h25: ps2_of = {1'b1, 1'b0, 8'h3E};
/* 9 */
            8'h26: ps2_of = {1'b1, 1'b0, 8'h46};
/* 0 */
            8'h27: ps2_of = {1'b1, 1'b0, 8'h45};
/* Enter */
            8'h28: ps2_of = {1'b1, 1'b0, 8'h5A};
/* Esc */
            8'h29: ps2_of = {1'b1, 1'b0, 8'h76};
/* Backspace */
            8'h2A: ps2_of = {1'b1, 1'b0, 8'h66};
/* Tab */
            8'h2B: ps2_of = {1'b1, 1'b0, 8'h0D};
/* Space */
            8'h2C: ps2_of = {1'b1, 1'b0, 8'h29};
/* - */
            8'h2D: ps2_of = {1'b1, 1'b0, 8'h4E};
/* = */
            8'h2E: ps2_of = {1'b1, 1'b0, 8'h55};
/* [ */
            8'h2F: ps2_of = {1'b1, 1'b0, 8'h54};
/* ] */
            8'h30: ps2_of = {1'b1, 1'b0, 8'h5B};
/* backslash */
            8'h31: ps2_of = {1'b1, 1'b0, 8'h5D};
/* ; */
            8'h33: ps2_of = {1'b1, 1'b0, 8'h4C};
/* ' */
            8'h34: ps2_of = {1'b1, 1'b0, 8'h52};
/* ` */
            8'h35: ps2_of = {1'b1, 1'b0, 8'h0E};
/* , */
            8'h36: ps2_of = {1'b1, 1'b0, 8'h41};
/* . */
            8'h37: ps2_of = {1'b1, 1'b0, 8'h49};
/* / */
            8'h38: ps2_of = {1'b1, 1'b0, 8'h4A};
/* Caps Lock */
            8'h39: ps2_of = {1'b1, 1'b0, 8'h58};
/* F1 = the Next's F1: hard reset */
            8'h3A: ps2_of = {1'b1, 1'b0, 8'h05};
/* F4 = the Next's F4: soft reset */
            8'h3D: ps2_of = {1'b1, 1'b0, 8'h0C};
/* F6 = the Next's F8: CPU speed */
            8'h3F: ps2_of = {1'b1, 1'b0, 8'h0A};
/* F8 = the Next's F3: 50 / 60 Hz */
            8'h41: ps2_of = {1'b1, 1'b0, 8'h04};
/* F9 = the Next's F9: Multiface NMI */
            8'h42: ps2_of = {1'b1, 1'b0, 8'h01};
/* F10 = the Next's F10: DivMMC NMI */
            8'h43: ps2_of = {1'b1, 1'b0, 8'h09};
/* Scroll Lock */
            8'h47: ps2_of = {1'b1, 1'b0, 8'h7E};
/* Insert, Home, Page Up, Delete, End, Page Down (49 .. 4E) are the joysticks' buttons: no events */
/* Right */
            8'h4F: ps2_of = {1'b1, 1'b1, 8'h74};
/* Left */
            8'h50: ps2_of = {1'b1, 1'b1, 8'h6B};
/* Down */
            8'h51: ps2_of = {1'b1, 1'b1, 8'h72};
/* Up */
            8'h52: ps2_of = {1'b1, 1'b1, 8'h75};
/* Num Lock */
            8'h53: ps2_of = {1'b1, 1'b0, 8'h77};
/* keypad / */
            8'h54: ps2_of = {1'b1, 1'b1, 8'h4A};
/* keypad * */
            8'h55: ps2_of = {1'b1, 1'b0, 8'h7C};
/* keypad - */
            8'h56: ps2_of = {1'b1, 1'b0, 8'h7B};
/* keypad + */
            8'h57: ps2_of = {1'b1, 1'b0, 8'h79};
/* keypad Enter */
            8'h58: ps2_of = {1'b1, 1'b1, 8'h5A};
/* keypad 1 */
            8'h59: ps2_of = {1'b1, 1'b0, 8'h69};
/* keypad 2 */
            8'h5A: ps2_of = {1'b1, 1'b0, 8'h72};
/* keypad 3 */
            8'h5B: ps2_of = {1'b1, 1'b0, 8'h7A};
/* keypad 4 */
            8'h5C: ps2_of = {1'b1, 1'b0, 8'h6B};
/* keypad 5 */
            8'h5D: ps2_of = {1'b1, 1'b0, 8'h73};
/* keypad 6 */
            8'h5E: ps2_of = {1'b1, 1'b0, 8'h74};
/* keypad 7 */
            8'h5F: ps2_of = {1'b1, 1'b0, 8'h6C};
/* keypad 8 */
            8'h60: ps2_of = {1'b1, 1'b0, 8'h75};
/* keypad 9 */
            8'h61: ps2_of = {1'b1, 1'b0, 8'h7D};
/* keypad 0 */
            8'h62: ps2_of = {1'b1, 1'b0, 8'h70};
/* keypad . */
            8'h63: ps2_of = {1'b1, 1'b0, 8'h71};
/* left Ctrl */
            8'hE0: ps2_of = {1'b1, 1'b0, 8'h14};
/* left Shift */
            8'hE1: ps2_of = {1'b1, 1'b0, 8'h12};
/* left Alt */
            8'hE2: ps2_of = {1'b1, 1'b0, 8'h11};
/* left GUI */
            8'hE3: ps2_of = {1'b1, 1'b1, 8'h1F};
/* right Ctrl */
            8'hE4: ps2_of = {1'b1, 1'b1, 8'h14};
/* right Shift */
            8'hE5: ps2_of = {1'b1, 1'b0, 8'h59};
/* right Alt */
            8'hE6: ps2_of = {1'b1, 1'b1, 8'h11};
/* right GUI */
            8'hE7: ps2_of = {1'b1, 1'b1, 8'h27};
            default: ps2_of = 10'd0;
        endcase
    end
endfunction

/* Packet parser */
reg [3:0]  idx;
reg [7:0]  mods, k1, k2, k3;
/* a report is complete */
reg        rep_new;
/* the six joystick button keys as held in the last report */
reg [5:0]  pad_held;

/* is a USB code among the three keys held? */
function has(input [7:0] code);
    has = (k1 == code) || (k2 == code) || (k3 == code);
endfunction

/* Alt held: the F-keys are no loader keys then */
wire alt_held = mods[2] | mods[6];

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
        rep_new  <= 1'b0;
        pad_held <= 6'd0;
/* the loader's keys */
        lkeys    <= 18'd0;
/* no Ctrl+Alt+Del, no packet seen */
        cad      <= 1'b0;
        seen     <= 1'b0;
/* no report yet */
        raw      <= 32'd0;
    end
    else
    begin
        rep_new <= 1'b0;
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
                    PKT_MODS: mods <= rx_byte;
                    PKT_KEY1: k1   <= rx_byte;
/* the second key */
                    PKT_KEY2: k2   <= rx_byte;
                    PKT_KEY3: k3   <= rx_byte;
/* the last key: the whole report is there */
                    PKT_DONE:
                    begin
/* 17 .. 11: F3 only */
                        lkeys <= {1'b0, has(KEY_F3) && !alt_held, 5'd0,
/* 10 F7 */
                                  has(KEY_F7) && !alt_held,
/* 9 Esc / Backspace */
                                  has(KEY_ESC) | has(KEY_BACKSPACE),
/* 8, 7 */
                                  2'd0,
/* 6 F11 */
                                  has(KEY_F11) && !alt_held,
/* 5 keypad Enter / Enter */
                                  has(KEY_KP_ENTER) | has(KEY_ENTER),
/* 4 keypad 6 / Right */
                                  has(KEY_KP6) | has(KEY_RIGHT),
/* 3 keypad 4 / Left */
                                  has(KEY_KP4) | has(KEY_LEFT),
/* 2 keypad 2 / Down */
                                  has(KEY_KP2) | has(KEY_DOWN),
/* 1 keypad 8 / Up */
                                  has(KEY_KP8) | has(KEY_UP),
/* 0 F12 */
                                  has(KEY_F12) && !alt_held};
/* Ctrl+Alt+Del */
                        cad     <= has(KEY_DELETE) && (mods[0] | mods[4]) && alt_held;
/* the joysticks' buttons; Delete is none while Ctrl and Alt are held */
                        pad_held <= {has(KEY_PAGE_DOWN), has(KEY_END),
                                     has(KEY_DELETE) && !((mods[0] | mods[4]) && alt_held),
                                     has(KEY_PAGE_UP), has(KEY_HOME), has(KEY_INSERT)};
/* a packet was seen; the report for the tape loader and for the events */
                        seen    <= 1'b1;
                        raw     <= {mods, k1, k2, k3};
                        rep_new <= 1'b1;
                    end
                    default: ;
                endcase
/* the next byte's place */
                if (idx != PKT_LAST)
                begin
                    idx <= idx + 4'd1;
                end
            end
        end
    end

/* Key events: what the machine was told (cur_*) against what is held now (t_*) */
reg [1:0]  block_s;
reg        block_q, pend;
reg [7:0]  cur_mods, cur_k0, cur_k1, cur_k2;
reg [7:0]  t_mods, t_k0, t_k1, t_k2;
/* the machine, its step, its timer */
reg [2:0]  ev;
reg [3:0]  step;
reg [6:0]  timer;
/* the event in work: the USB code, pressed, its PS/2 code */
reg [7:0]  ev_usb;
reg        ev_press;
reg [9:0]  ev_ps2;

/* a real key */
function is_key(input [7:0] code);
    is_key = code >= KEY_FIRST;
endfunction

/* a key among the ones held now / among the ones the machine knows */
function in_new(input [7:0] code);
    in_new = (t_k0 == code) || (t_k1 == code) || (t_k2 == code);
endfunction
function in_cur(input [7:0] code);
    in_cur = (cur_k0 == code) || (cur_k1 == code) || (cur_k2 == code);
endfunction

/* the key of a release step and of a press step */
wire [7:0] rel_key = step == STEP_REL ? cur_k0 : (step == STEP_REL + 4'd1 ? cur_k1 : cur_k2);
wire [7:0] new_key = step == STEP_PRESS ? t_k0 : (step == STEP_PRESS + 4'd1 ? t_k1 : t_k2);
/* the modifier of a modifier step */
wire [2:0] mod_bit = step[2:0];

always @(posedge clk or negedge rst_n)
    if (!rst_n)
    begin
        block_s  <= 2'b00;
        block_q  <= 1'b0;
        pend     <= 1'b0;
/* the machine knows no keys */
        cur_mods <= 8'd0;
        cur_k0   <= 8'd0;
        cur_k1   <= 8'd0;
        cur_k2   <= 8'd0;
/* nothing held */
        t_mods   <= 8'd0;
        t_k0     <= 8'd0;
        t_k1     <= 8'd0;
        t_k2     <= 8'd0;
/* the machine rests */
        ev       <= EV_IDLE;
        step     <= 4'd0;
        timer    <= 7'd0;
/* no event */
        ev_usb   <= 8'd0;
        ev_press <= 1'b0;
        ev_ps2   <= 10'd0;
        ps2_key  <= 11'd0;
        pad      <= 6'd0;
    end
    else
    begin
/* the OSD's state, synchronised; a change of it or a new report asks for a comparison */
        block_s <= {block_s[0], block};
        block_q <= block_s[1];
/* the joysticks' buttons: none while the OSD has the keyboard */
        pad     <= block_s[1] ? 6'd0 : pad_held;
        if (rep_new || (block_q != block_s[1]))
        begin
            pend <= 1'b1;
        end

        case (ev)
/* a comparison starts: the keys held now, none while the OSD has the keyboard */
            EV_IDLE:
                if (pend)
                begin
                    pend   <= 1'b0;
                    t_mods <= block_s[1] ? 8'd0 : mods;
                    t_k0   <= block_s[1] ? 8'd0 : k1;
                    t_k1   <= block_s[1] ? 8'd0 : k2;
                    t_k2   <= block_s[1] ? 8'd0 : k3;
                    step   <= 4'd0;
                    ev     <= EV_STEP;
                end
/* one step: is there an event? */
            EV_STEP:
            begin
                ev <= EV_CODE;
                if (step < STEP_REL)
                begin
/* a modifier key changed */
                    ev_usb   <= KEY_MODS + {5'd0, mod_bit};
                    ev_press <= t_mods[mod_bit];
                    if (cur_mods[mod_bit] == t_mods[mod_bit])
                    begin
                        ev <= EV_GAP;
                        timer <= 7'd0;
                    end
                    cur_mods[mod_bit] <= t_mods[mod_bit];
                end
                else if (step < STEP_PRESS)
                begin
/* a key the machine knows is not held any more */
                    ev_usb   <= rel_key;
                    ev_press <= 1'b0;
                    if (!is_key(rel_key) || in_new(rel_key))
                    begin
                        ev <= EV_GAP;
                        timer <= 7'd0;
                    end
                    else
                    begin
/* its place is free again */
                        if (step == STEP_REL)
                        begin
                            cur_k0 <= 8'd0;
                        end
                        else if (step == STEP_REL + 4'd1)
                        begin
                            cur_k1 <= 8'd0;
                        end
                        else
                        begin
                            cur_k2 <= 8'd0;
                        end
                    end
                end
                else
                begin
/* a key held that the machine does not know yet: into a free place */
                    ev_usb   <= new_key;
                    ev_press <= 1'b1;
                    if (!is_key(new_key) || in_cur(new_key))
                    begin
                        ev <= EV_GAP;
                        timer <= 7'd0;
                    end
                    else if (!is_key(cur_k0))
                    begin
                        cur_k0 <= new_key;
                    end
                    else if (!is_key(cur_k1))
                    begin
                        cur_k1 <= new_key;
                    end
                    else
                    begin
                        cur_k2 <= new_key;
                    end
                end
            end
/* the key's PS/2 code */
            EV_CODE:
            begin
                ev_ps2 <= ps2_of(ev_usb);
                ev     <= EV_DATA;
                timer  <= T_SETUP;
            end
/* a known key: the data first, the strobe a moment later */
            EV_DATA:
                if (!ev_ps2[9])
                begin
                    ev    <= EV_GAP;
                    timer <= 7'd0;
                end
                else
                begin
                    ps2_key[9:0] <= {ev_press, ev_ps2[8:0]};
                    if (timer != 7'd0)
                    begin
                        timer <= timer - 7'd1;
                    end
                    else
                    begin
                        ps2_key[10] <= !ps2_key[10];
                        ev          <= EV_GAP;
                        timer       <= T_GAP;
                    end
                end
/* the gap after an event, then the next step */
            EV_GAP:
                if (timer != 7'd0)
                begin
                    timer <= timer - 7'd1;
                end
                else if (step == STEP_LAST)
                begin
                    ev <= EV_IDLE;
                end
                else
                begin
                    step <= step + 4'd1;
                    ev   <= EV_STEP;
                end
            default: ev <= EV_IDLE;
        endcase
    end

endmodule

`default_nettype wire
