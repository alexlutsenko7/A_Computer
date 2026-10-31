//=============================================================================
// sdram_model -- behavioral W9825G6KH-6 (4 x 8192 x 512 x 16) with timing checks
// Simulation only. Supports BL=1 (what the controller uses).
//=============================================================================
`ifndef SD_UNINIT
 `define SD_UNINIT 16'h0000   // never-written words (real SDRAM: random; X would poison the CPU in simulation)
`endif
`timescale 1ns/1ps

module sdram_model #(
    parameter real T_CK = 10.0,
    parameter real T_AC = 6.0,      // access time from clock, CL2
    parameter real T_OH = 3.0,      // data hold after clock
    parameter real T_HZ = 6.0       // data out to high-Z after clock
)(
    input  wire        clk,
    input  wire        cke,
    input  wire        cs_n,
    input  wire        ras_n,
    input  wire        cas_n,
    input  wire        we_n,
    input  wire [1:0]  ba,
    input  wire [12:0] a,
    input  wire [1:0]  dqm,
    inout  wire [15:0] dq
);

localparam real tRCD = 15.0, tRP = 15.0, tRAS = 42.0, tRC = 60.0, tRRD = 12.0,
                tRFC = 60.0, tREFI = 7812.5, tPOWERUP = 200000.0;
// Clock-count based limits; 10 ps tolerance because the testbench clock period
// is rounded to 1 ps (e.g. 112 MHz -> 8.928 ns instead of 8.928571 ns).
localparam real tWR  = 2.0 * T_CK - 0.01;
localparam real tMRD = 2.0 * T_CK - 0.01;

logic [15:0] mem [bit [23:0]];
logic [15:0] dq_drv = 'z;
assign dq = dq_drv;

int          errors = 0;
int          n_act = 0, n_pre = 0, n_rd = 0, n_wr = 0, n_ref = 0;
realtime     max_ref_gap = 0;

bit          open_b [4];
bit  [12:0]  row_b  [4];
realtime     t_act [4] = '{-1e9, -1e9, -1e9, -1e9};
realtime     t_pre [4] = '{-1e9, -1e9, -1e9, -1e9};
realtime     t_wr  [4] = '{-1e9, -1e9, -1e9, -1e9};
realtime     t_last_act = -1e9, t_ref = -1e9, t_mrs = -1e9;
int          cl = 0;
bit          init_done = 0;
int          init_refs = 0;
int          rd_gen = 0;

function automatic void err(string s);
    errors++;
    if (errors <= 20) $display("%t SDRAM MODEL ERROR: %s", $realtime, s);
endfunction

function automatic void chk(bit ok, string s);
    if (!ok) err(s);
endfunction

task automatic drive_read(input int gen, input logic [15:0] d);
    #((cl - 1) * T_CK + T_OH);
    if (gen == rd_gen) dq_drv = 'x;          // low-Z, not yet valid
    #(T_AC - T_OH);
    if (gen == rd_gen) dq_drv = d;           // valid
    #(T_CK + T_OH - T_AC);
    if (gen == rd_gen) dq_drv = 'x;          // hold time over
    #(T_HZ - T_OH);
    if (gen == rd_gen) dq_drv = 'z;
endtask

always @(posedge clk) begin
    automatic realtime now = $realtime;
    if (cke && !cs_n && {ras_n, cas_n, we_n} != 3'b111) begin
        chk(now >= tPOWERUP, "command during 200 us power-up pause");
        chk(now - t_ref >= tRFC, "tRFC violated");
        chk(now - t_mrs >= tMRD, "tMRD violated");

        case ({ras_n, cas_n, we_n})
        3'b011: begin // ACT
            n_act++;
            chk(init_done, "ACT before init");
            chk(!open_b[ba], $sformatf("ACT to open bank %0d", ba));
            chk(now - t_pre[ba] >= tRP, "tRP violated (ACT)");
            chk(now - t_act[ba] >= tRC, "tRC violated");
            chk(now - t_last_act >= tRRD, "tRRD violated");
            open_b[ba] = 1; row_b[ba] = a; t_act[ba] = now; t_last_act = now;
        end
        3'b010: begin // PRE
            n_pre++;
            for (int b = 0; b < 4; b++)
                if ((a[10] || b == ba) && open_b[b]) begin
                    chk(now - t_act[b] >= tRAS, $sformatf("tRAS violated bank %0d", b));
                    chk(now - t_wr[b] >= tWR, $sformatf("tWR violated bank %0d", b));
                    open_b[b] = 0; t_pre[b] = now;
                end
        end
        3'b101: begin // READ
            logic [15:0] d;
            n_rd++;
            chk(init_done, "READ before init");
            chk(open_b[ba], "READ to closed bank");
            chk(now - t_act[ba] >= tRCD, "tRCD violated (READ)");
            chk(!a[10], "unexpected auto-precharge");
            d = mem.exists({ba, row_b[ba], a[8:0]}) ? mem[{ba, row_b[ba], a[8:0]}] : `SD_UNINIT;
            if (dqm[0]) d[7:0]  = 'z;
            if (dqm[1]) d[15:8] = 'z;
            rd_gen++;
            fork
                drive_read(rd_gen, d);
            join_none
        end
        3'b100: begin // WRITE
            logic [15:0] d;
            n_wr++;
            chk(init_done, "WRITE before init");
            chk(open_b[ba], "WRITE to closed bank");
            chk(now - t_act[ba] >= tRCD, "tRCD violated (WRITE)");
            chk(!a[10], "unexpected auto-precharge");
            d = mem.exists({ba, row_b[ba], a[8:0]}) ? mem[{ba, row_b[ba], a[8:0]}] : `SD_UNINIT;
            if (!dqm[0]) begin chk(!$isunknown(dq[7:0]),  "write data low byte unknown");  d[7:0]  = dq[7:0];  end
            if (!dqm[1]) begin chk(!$isunknown(dq[15:8]), "write data high byte unknown"); d[15:8] = dq[15:8]; end
            mem[{ba, row_b[ba], a[8:0]}] = d;
            t_wr[ba] = now;
        end
        3'b001: begin // AUTO REFRESH
            n_ref++;
            for (int b = 0; b < 4; b++) begin
                chk(!open_b[b], "REF with open bank");
                chk(now - t_pre[b] >= tRP, "tRP violated (REF)");
            end
            if (init_done) begin
                if (now - t_ref > max_ref_gap) max_ref_gap = now - t_ref;
                chk(now - t_ref <= tREFI, $sformatf("refresh interval %0.1f ns too long", now - t_ref));
            end else
                init_refs++;
            t_ref = now;
        end
        3'b000: begin // MRS
            for (int b = 0; b < 4; b++) chk(!open_b[b], "MRS with open bank");
            chk(init_refs >= 8, "fewer than 8 refreshes before MRS");
            chk(a[2:0] == 3'b000 && a[3] == 1'b0, "unexpected burst mode");
            chk(a[6:4] == 3'd2 || a[6:4] == 3'd3, "illegal CAS latency");
            cl = a[6:4];
            t_mrs = now;
            init_done = 1;
            $display("%t SDRAM MODEL: mode register set, CL=%0d", now, cl);
        end
        default: err("unsupported command");
        endcase
    end

    // Refresh starvation check while running
    if (init_done && now - t_ref > tREFI + T_CK)
        if (errors == 0 || now - t_ref < tREFI + 2 * T_CK) err("refresh overdue");
end

endmodule
