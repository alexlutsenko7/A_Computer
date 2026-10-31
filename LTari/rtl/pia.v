//=============================================================================
// pia -- 6520 PIA: joystick directions (port A), XL/XE memory control (port B),
//        SIO motor (CA2) / command (CB2), SIO proceed (CA1) / interrupt (CB1)
//
// Written from the Altirra Hardware Reference Manual (2.5; LTari/NOTES.md).
// $D300 PORTA / DDRA, $D301 PORTB / DDRB, $D302 PACTL, $D303 PBCTL; control bit 2 = 1
// selects the data register. DDR bit 1 = output. Port A reads (output AND input) on
// output bits; port B reads its output on output bits. Control bits 7 / 6 = C1 / C2
// interrupt flags (cleared by reading the data register), bit 0 / 3 = their enables,
// bits 5:3 = 11x: C2 is an output at level bit 3. Reset (power-up, Reset button): all 0.
//=============================================================================
`default_nettype none

module pia (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        reg_we,
    input  wire        reg_re,          // a CPU read cycle (one strobe)
    input  wire [1:0]  reg_a,
    input  wire [7:0]  reg_d,
    output reg  [7:0]  reg_q,
    output wire        irq,

    input  wire [7:0]  pa_in,           // joysticks (0 = pressed)
    output wire [7:0]  pb_val,          // port B as the MMU sees it (inputs read 1)
    output wire [47:0] st,              // snapshots: {PBCTL, DDRB, ORB, PACTL, DDRA, ORA}
    output wire        ca2,             // SIO motor (0 = on)
    output wire        cb2,             // SIO command (0 = command frame)
    input  wire        ca1,             // SIO proceed
    input  wire        cb1              // SIO interrupt
);

reg  [7:0] ora, orb, ddra, ddrb;
reg  [7:0] pactl, pbctl;                // bits 5:0 written; 7:6 = flags
reg        ca1_d, cb1_d;

assign pb_val = orb | ~ddrb;
assign st     = {pbctl, ddrb, orb, pactl, ddra, ora};
assign ca2    = pactl[5:4] == 2'b11 ? pactl[3] : 1'b1;
assign cb2    = pbctl[5:4] == 2'b11 ? pbctl[3] : 1'b1;
assign irq    = (pactl[7] && pactl[0]) || (pbctl[7] && pbctl[0]);

always @* begin
    case (reg_a)
        2'd0:    reg_q = pactl[2] ? ((ora & ddra) | ~ddra) & pa_in : ddra;
        2'd1:    reg_q = pbctl[2] ? ((orb & ddrb) | ~ddrb) : ddrb;
        2'd2:    reg_q = pactl;
        default: reg_q = pbctl;
    endcase
end

always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
        ora <= 8'd0; orb <= 8'd0; ddra <= 8'd0; ddrb <= 8'd0; pactl <= 8'd0; pbctl <= 8'd0;
        ca1_d <= 1'b1; cb1_d <= 1'b1;
    end else begin
        ca1_d <= ca1;
        cb1_d <= cb1;
        // C1 edge flags: falling edge (control bit 1 = 0) or rising edge (1)
        if (ca1_d != ca1 && ca1 == pactl[1]) pactl[7] <= 1'b1;
        if (cb1_d != cb1 && cb1 == pbctl[1]) pbctl[7] <= 1'b1;
        if (reg_re) begin
            if (reg_a == 2'd0 && pactl[2]) pactl[7:6] <= 2'b00;
            if (reg_a == 2'd1 && pbctl[2]) pbctl[7:6] <= 2'b00;
        end
        if (reg_we)
            case (reg_a)
                2'd0: if (pactl[2]) ora <= reg_d; else ddra <= reg_d;
                2'd1: if (pbctl[2]) orb <= reg_d; else ddrb <= reg_d;
                2'd2: begin pactl[5:0] <= reg_d[5:0]; if (reg_d[5]) pactl[6] <= 1'b0; end
                default: begin pbctl[5:0] <= reg_d[5:0]; if (reg_d[5]) pbctl[6] <= 1'b0; end
            endcase
    end

endmodule

`default_nettype wire
