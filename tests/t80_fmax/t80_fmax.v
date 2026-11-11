/* t80_fmax -- timing-only test: T80 (T80se wrapper) with all I/O registered. */
/* Not for hardware. Measures the T80's internal Fmax on EP4CE15F23C8. */
module t80_fmax (
    input  wire        clk,
    input  wire        reset_n, cen, wait_n, int_n, nmi_n, busrq_n,
    input  wire [7:0]  di,
    output reg  [15:0] a,
    output reg  [7:0]  dout,
    output reg  [7:0]  ctl
);
    reg rst_r, cen_r, wait_r, int_r, nmi_r, busrq_r;
    reg [7:0] di_r;
/* the CPU's outputs */
    wire [15:0] a_w; wire [7:0] do_w;
    wire m1, mreq, iorq, rd, wr, rfsh, halt, busak;
    always @(posedge clk)
    begin
/* every input and output through a register */
        {rst_r, cen_r, wait_r, int_r, nmi_r, busrq_r} <= {reset_n, cen, wait_n, int_n, nmi_n, busrq_n};
        di_r <= di;
        a    <= a_w;
/* data and control outputs; the CPU */
        dout <= do_w;
        ctl  <= {m1, mreq, iorq, rd, wr, rfsh, halt, busak};
    end
    T80se #(.Mode(0), .T2Write(1), .IOWait(1)) cpu (
        .RESET_n(rst_r), .CLK_n(clk), .CLKEN(cen_r), .WAIT_n(wait_r), .INT_n(int_r), .NMI_n(nmi_r),
        .BUSRQ_n(busrq_r), .M1_n(m1), .MREQ_n(mreq), .IORQ_n(iorq), .RD_n(rd), .WR_n(wr), .RFSH_n(rfsh),
        .HALT_n(halt), .BUSAK_n(busak), .A(a_w), .DI(di_r), .DO(do_w));
endmodule
