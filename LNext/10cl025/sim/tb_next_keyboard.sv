/* tb_next_keyboard -- LNext's keyboard (next_keyboard.v): keyboard reports on its UART, the key */
/* events it makes for the Next core are compared with the expected ones. */
/* A report as the keyboard module sends it: 57 AB 01 88 08 mods 00 k1 k2 k3 00 00 00. */
/* The events are taken as LNext.v takes them: in the machine's 28 MHz clock, when the strobe */
/* (bit 10) changes. RESULT: PASS / FAIL. */
`timescale 1ns/1ps

module tb_next_keyboard;

/* half periods: 56 MHz (the keyboard's clock) and 28 MHz (the machine's), not related */
localparam realtime H56 = 8.9286;
localparam realtime H28 = 17.9;
/* a UART bit at 115200 baud, bits of a byte */
localparam integer BIT_NS = 8680;
localparam integer BYTE_BITS = 8;
/* the most events a test expects */
localparam integer MAX_EV = 64;
/* time for the events of one report */
localparam integer SETTLE_NS = 400000;
/* USB key codes used: A, B, Up, F3, F8 */
localparam [7:0] U_A = 8'h04;
localparam [7:0] U_B = 8'h05;
localparam [7:0] U_UP = 8'h52;
localparam [7:0] U_F3 = 8'h3C;
localparam [7:0] U_F8 = 8'h41;
/* modifier bit: left Shift */
localparam [7:0] M_LSHIFT = 8'h02;
/* events: {pressed, extended, code} */
localparam [9:0] E_A_DOWN = {1'b1, 1'b0, 8'h1C};
localparam [9:0] E_A_UP = {1'b0, 1'b0, 8'h1C};
localparam [9:0] E_B_DOWN = {1'b1, 1'b0, 8'h32};
localparam [9:0] E_B_UP = {1'b0, 1'b0, 8'h32};
localparam [9:0] E_SH_DOWN = {1'b1, 1'b0, 8'h12};
localparam [9:0] E_SH_UP = {1'b0, 1'b0, 8'h12};
localparam [9:0] E_UP_DOWN = {1'b1, 1'b1, 8'h75};
localparam [9:0] E_UP_UP = {1'b0, 1'b1, 8'h75};
/* F8 is the Next's F3 key (50 / 60 Hz) */
localparam [9:0] E_F8_DOWN = {1'b1, 1'b0, 8'h04};
localparam [9:0] E_F8_UP = {1'b0, 1'b0, 8'h04};
/* USB codes of joystick button keys, the modifier byte of left Ctrl + left Alt, pad values */
localparam [7:0] U_INSERT = 8'h49;
localparam [7:0] U_DELETE = 8'h4C;
localparam [7:0] U_PAGE_DOWN = 8'h4E;
localparam [7:0] M_CTRL_ALT = 8'h05;
localparam [5:0] PAD_INS_PGDN = 6'b100001;
localparam [5:0] PAD_DEL = 6'b001000;
/* loader key bit of F3 */
localparam integer LK_F3 = 16;

reg clk56 = 0, clk28 = 0, rst_n = 0, rx = 1, block = 0;
always #(H56) clk56 = ~clk56;
always #(H28) clk28 = ~clk28;

wire [10:0] ps2_key56;
wire [17:0] lkeys;
wire        cad, seen;
wire [31:0] raw;
/* the joysticks' buttons: Page Down, End, Delete, Page Up, Home, Insert */
wire [5:0]  pad;

next_keyboard #(.CLK_HZ(56000000)) dut (
    .clk(clk56), .rst_n(rst_n), .rx(rx), .block(block),
    .ps2_key(ps2_key56), .pad(pad), .lkeys(lkeys), .cad(cad), .seen(seen), .raw(raw)
);

/* the events as the machine takes them (LNext.v) */
reg  [1:0]  ps2_s = 0;
reg  [10:0] ps2_key = 0;
reg  [9:0]  got [0:MAX_EV-1];
integer     n_got = 0;
always @(posedge clk28)
begin
    ps2_s <= {ps2_s[0], ps2_key56[10]};
    if (ps2_s[1] != ps2_key[10])
    begin
        ps2_key <= {ps2_s[1], ps2_key56[9:0]};
        got[n_got] = ps2_key56[9:0];
        n_got = n_got + 1;
    end
end

/* one byte on the keyboard's UART */
task automatic uart_send(input [7:0] b);
    integer i;
    begin
        rx = 0;
        #BIT_NS;
        for (i = 0; i < BYTE_BITS; i++)
        begin
            rx = b[i];
            #BIT_NS;
        end
        rx = 1;
        #BIT_NS;
    end
endtask

/* one report: modifiers and three keys */
task automatic report(input [7:0] mods, input [7:0] k1, input [7:0] k2, input [7:0] k3);
    begin
        uart_send(8'h57);
        uart_send(8'hAB);
        uart_send(8'h01);
        uart_send(8'h88);
        uart_send(8'h08);
        uart_send(mods);
        uart_send(8'h00);
        uart_send(k1);
        uart_send(k2);
        uart_send(k3);
        uart_send(8'h00);
        uart_send(8'h00);
        uart_send(8'h00);
        #SETTLE_NS;
    end
endtask

integer errors = 0;
integer n_exp = 0;

/* the next event must be this one */
task automatic expect_ev(input [9:0] ev, input string name);
    begin
        if (n_exp >= n_got)
        begin
            $display("ERROR: event %0d (%s) did not come", n_exp, name);
            errors = errors + 1;
        end
        else if (got[n_exp] !== ev)
        begin
            $display("ERROR: event %0d is %03x, expected %03x (%s)", n_exp, got[n_exp], ev, name);
            errors = errors + 1;
        end
        n_exp = n_exp + 1;
    end
endtask

/* no more events than expected so far */
task automatic expect_none(input string name);
    begin
        if (n_got != n_exp)
        begin
            $display("ERROR: %0d events too many after %s (first %03x)", n_got - n_exp, name, got[n_exp]);
            errors = errors + 1;
            n_exp = n_got;
        end
    end
endtask

initial
begin
    #1000 rst_n = 1;
    #100000;
/* A down */
    report(8'h00, U_A, 8'h00, 8'h00);
    expect_ev(E_A_DOWN, "A down");
    expect_none("A down");
/* the same report again (the keyboard repeats it): nothing */
    report(8'h00, U_A, 8'h00, 8'h00);
    expect_none("A repeated");
/* Shift added */
    report(M_LSHIFT, U_A, 8'h00, 8'h00);
    expect_ev(E_SH_DOWN, "Shift down");
    expect_none("Shift down");
/* cursor up added: an extended code; the key order in the report changes */
    report(M_LSHIFT, U_UP, U_A, 8'h00);
    expect_ev(E_UP_DOWN, "Up down");
    expect_none("Up down");
/* A released, B pressed in one report: the release comes first */
    report(M_LSHIFT, U_UP, U_B, 8'h00);
    expect_ev(E_A_UP, "A up");
    expect_ev(E_B_DOWN, "B down");
    expect_none("A up, B down");
/* the OSD takes the keyboard: everything is released for the machine */
    block = 1;
    #SETTLE_NS;
    expect_ev(E_SH_UP, "Shift up (OSD)");
/* (B took the place A left, so it stands before Up) */
    expect_ev(E_B_UP, "B up (OSD)");
    expect_ev(E_UP_UP, "Up up (OSD)");
    expect_none("OSD on");
/* the OSD goes: the keys still held are pressed again */
    block = 0;
    #SETTLE_NS;
    expect_ev(E_SH_DOWN, "Shift down (OSD off)");
    expect_ev(E_UP_DOWN, "Up down (OSD off)");
    expect_ev(E_B_DOWN, "B down (OSD off)");
    expect_none("OSD off");
/* all released */
    report(8'h00, 8'h00, 8'h00, 8'h00);
    expect_ev(E_SH_UP, "Shift up");
    expect_ev(E_UP_UP, "Up up");
    expect_ev(E_B_UP, "B up");
    expect_none("all released");
/* F8 is the Next's 50 / 60 Hz key */
    report(8'h00, U_F8, 8'h00, 8'h00);
    expect_ev(E_F8_DOWN, "F8 down");
    report(8'h00, 8'h00, 8'h00, 8'h00);
    expect_ev(E_F8_UP, "F8 up");
    expect_none("F8");
/* F3 is the loader's (Bluetooth menu): no event for the machine */
    report(8'h00, U_F3, 8'h00, 8'h00);
    expect_none("F3");
    if (!lkeys[LK_F3])
    begin
        $display("ERROR: F3 is not in the loader keys");
        errors = errors + 1;
    end
    report(8'h00, 8'h00, 8'h00, 8'h00);
    expect_none("F3 released");
/* Insert and Page Down are joystick buttons: no events, their two bits */
    report(8'h00, U_INSERT, U_PAGE_DOWN, 8'h00);
    expect_none("Insert + Page Down");
    if (pad !== PAD_INS_PGDN)
    begin
        $display("ERROR: pad is %02x with Insert + Page Down", pad);
        errors = errors + 1;
    end
/* the OSD takes them away */
    block = 1'b1;
    #SETTLE_NS;
    if (pad !== 6'd0)
    begin
        $display("ERROR: pad is %02x while the OSD has the keyboard", pad);
        errors = errors + 1;
    end
    block = 1'b0;
/* Delete alone is the right joystick's button; with Ctrl + Alt it is not */
    report(8'h00, U_DELETE, 8'h00, 8'h00);
    if ((pad !== PAD_DEL) || cad)
    begin
        $display("ERROR: pad is %02x, cad %b with Delete", pad, cad);
        errors = errors + 1;
    end
    report(8'h00, 8'h00, 8'h00, 8'h00);
    expect_none("Delete");
    report(M_CTRL_ALT, U_DELETE, 8'h00, 8'h00);
    if ((pad !== 6'd0) || !cad)
    begin
        $display("ERROR: pad is %02x, cad %b with Ctrl + Alt + Del", pad, cad);
        errors = errors + 1;
    end
    $display("%0d events, %0d errors", n_got, errors);
    $display("RESULT: %s", errors == 0 ? "PASS" : "FAIL");
    $finish;
end

endmodule
