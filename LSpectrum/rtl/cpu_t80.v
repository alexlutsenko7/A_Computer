//=============================================================================
// cpu_t80 -- T80 Z80 core with a single clock enable (T80se-style wrapper)
//
// All registers in here (the T80 core and di_reg) change only on cen, and cen
// pulses are at least 4 system clocks apart (zx_bus guarantees it). The SDC
// gives every path from this hierarchy to itself a multicycle of 4.
//
// Exported for the bus bridge (zx_bus): address, data out, MC/TS, and the
// cycle decode (IORQ/NoRead/Write, which are combinational from the
// instruction register: the bridge samples them 2 clocks after cen).
//
//   din   -> DInst (opcode fetch) and, latched at the end of T2, -> DI
//            (like T80se: DI_Reg <= DI when TState = 2 and WAIT_n = 1)
//
// Snapshots (zx_bus): regs = all registers (T80 REG), dirset loads them from
// dir in one clock (T80 DIR, used right after a reset). Layout, from bit 0:
//   A F A' F' I R SP PC BC DE HL IX BC' DE' HL' IY (8/16 bits each), IM [209:208],
//   IFF1 [210], IFF2 [211]; 16-bit registers low byte first (C at 80, B at 88).
//=============================================================================
`default_nettype none

module cpu_t80 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        cen,
    input  wire        int_n,
    input  wire        nmi_n,
    input  wire [7:0]  din,

    output wire [15:0] a,
    output wire [7:0]  dout,
    output wire [2:0]  mc,
    output wire [2:0]  ts,
    output wire        iorq,          // current M-cycle is an I/O cycle
    output wire        noread,
    output wire        write,
    output wire        m1_n,
    output wire        intcycle_n,    // 0 during the interrupt acknowledge M1
    output wire        halt_n,

    output wire [211:0] regs,
    input  wire        dirset,
    input  wire [211:0] dir
);

reg  [7:0] di_reg;
wire       rfsh_n, busak_n, inte, stop;

T80 #(
    .Mode   (0),                      // Z80
    .IOWait (1)                       // standard I/O cycle (one automatic wait state)
) u_t80 (
    .RESET_n    (rst_n),
    .CLK_n      (clk),
    .CEN        (cen),
    .WAIT_n     (1'b1),
    .INT_n      (int_n),
    .NMI_n      (nmi_n),
    .BUSRQ_n    (1'b1),
    .M1_n       (m1_n),
    .IORQ       (iorq),
    .NoRead     (noread),
    .Write      (write),
    .RFSH_n     (rfsh_n),
    .HALT_n     (halt_n),
    .BUSAK_n    (busak_n),
    .A          (a),
    .DInst      (din),
    .DI         (di_reg),
    .DO         (dout),
    .MC         (mc),
    .TS         (ts),
    .IntCycle_n (intcycle_n),
    .IntE       (inte),
    .Stop       (stop),
    .R800_mode  (1'b0),
    .out0       (1'b0),
    .REG        (regs),
    .DIRSet     (dirset),
    .DIR        (dir)
);

always @(posedge clk or negedge rst_n)
    if (!rst_n)
        di_reg <= 8'h00;
    else if (cen && ts == 3'd2)
        di_reg <= din;

endmodule

`default_nettype wire
