/* sdram_model -- behavioral W9825G6KH-6 (4 x 8192 x 512 x 16) with timing checks */
/* Simulation only. Supports BL=1 (what the controller uses). */
`timescale 1ns/1ps

module sdram_model #(
    parameter real T_CK = 10.0,
/* access time from clock, CL2 */
    parameter real T_AC = 6.0,
/* data hold after clock */
    parameter real T_OH = 3.0,
/* data out to high-Z after clock */
    parameter real T_HZ = 6.0
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

/* errors listed */
localparam integer LIST_MAX = 20;
/* banks of the SDRAM */
localparam integer BANKS = 4;
/* clock periods of tolerance on the refresh interval */
localparam integer REF_SLACK = 2;

localparam real tRCD = 15.0, tRP = 15.0, tRAS = 42.0, tRC = 60.0, tRRD = 12.0,
                tRFC = 60.0, tREFI = 7812.5, tPOWERUP = 200000.0;
/* Clock-count based limits; 10 ps tolerance because the testbench clock period */
/* is rounded to 1 ps (e.g. 112 MHz -> 8.928 ns instead of 8.928571 ns). */
localparam real tWR  = 2.0 * T_CK - 0.01;
localparam real tMRD = 2.0 * T_CK - 0.01;

logic [15:0] mem [bit [23:0]];
/* the data pins: driven only while a read is answered */
logic [15:0] dq_drv = 'z;
assign dq = dq_drv;

/* counters for the report */
int          errors = 0;
int          n_act = 0, n_pre = 0, n_rd = 0, n_wr = 0, n_ref = 0;
realtime     max_ref_gap = 0;

/* per bank: open, its row, the time of the last activate */
bit          open_b [4];
bit  [12:0]  row_b  [4];
realtime     t_act [4] = '{-1e9, -1e9, -1e9, -1e9};
/* last precharge and write */
realtime     t_pre [4] = '{-1e9, -1e9, -1e9, -1e9};
realtime     t_wr  [4] = '{-1e9, -1e9, -1e9, -1e9};
realtime     t_last_act = -1e9, t_ref = -1e9, t_mrs = -1e9;
/* the mode set: CAS latency; initialisation done */
int          cl = 0;
bit          init_done = 0;
int          init_refs = 0;
/* the read being answered */
int          rd_gen = 0;

/* an error; the first 20 are shown */
function automatic void err(string s);
    errors++;
    if (errors <= LIST_MAX)
    begin
/* shown */
        $display("%t SDRAM MODEL ERROR: %s", $realtime, s);
    end
endfunction

/* a check */
function automatic void chk(bit ok, string s);
    if (!ok)
    begin
        err(s);
    end
endfunction

/* a read's data on the pins after the CAS latency, held for tOH */
task automatic drive_read(input int gen, input logic [15:0] d);
    #((cl - 1) * T_CK + T_OH);
/* low-Z, not yet valid */
    if (gen == rd_gen)
    begin
        dq_drv = 'x;
    end
    #(T_AC - T_OH);
/* valid */
    if (gen == rd_gen)
    begin
        dq_drv = d;
    end
    #(T_CK + T_OH - T_AC);
/* hold time over */
    if (gen == rd_gen)
    begin
        dq_drv = 'x;
    end
    #(T_HZ - T_OH);
/* high impedance after tHZ */
    if (gen == rd_gen)
    begin
        dq_drv = 'z;
    end
endtask

/* every command the controller issues is checked */
always @(posedge clk)
begin
    automatic realtime now = $realtime;
    if (cke && !cs_n && {ras_n, cas_n, we_n} != 3'b111)
    begin
/* general timing */
        chk(now >= tPOWERUP, "command during 200 us power-up pause");
        chk(now - t_ref >= tRFC, "tRFC violated");
        chk(now - t_mrs >= tMRD, "tMRD violated");

/* by command */
        case ({ras_n, cas_n, we_n})
/* ACT */
            3'b011:
            begin
                n_act++;
                chk(init_done, "ACT before init");
/* the bank must be closed, and its times kept */
                chk(!open_b[ba], $sformatf("ACT to open bank %0d", ba));
                chk(now - t_pre[ba] >= tRP, "tRP violated (ACT)");
                chk(now - t_act[ba] >= tRC, "tRC violated");
/* the bank is open on this row */
                chk(now - t_last_act >= tRRD, "tRRD violated");
                open_b[ba] = 1;
                row_b[ba] = a;
/* the times of this activate */
                t_act[ba] = now;
                t_last_act = now;
            end
/* PRE */
            3'b010:
            begin
                n_pre++;
/* one bank, or all with A10 */
                for (int b = 0; b < BANKS; b++)
                begin
                    if ((a[10] || b == ba) && open_b[b])
                    begin
                        chk(now - t_act[b] >= tRAS, $sformatf("tRAS violated bank %0d", b));
/* write recovery; closed */
                        chk(now - t_wr[b] >= tWR, $sformatf("tWR violated bank %0d", b));
                        open_b[b] = 0;
                        t_pre[b] = now;
                    end
                end
            end
/* READ */
            3'b101:
            begin
                logic [15:0] d;
                n_rd++;
/* the bank must be open long enough */
                chk(init_done, "READ before init");
                chk(open_b[ba], "READ to closed bank");
                chk(now - t_act[ba] >= tRCD, "tRCD violated (READ)");
/* the word stored (x if never written) */
                chk(!a[10], "unexpected auto-precharge");
                d = mem.exists({ba, row_b[ba], a[8:0]}) ? mem[{ba, row_b[ba], a[8:0]}] : 16'hxxxx;
/* the lower byte masked */
                if (dqm[0])
                begin
                    d[7:0]  = 'z;
                end
/* the upper byte masked */
                if (dqm[1])
                begin
                    d[15:8] = 'z;
                end
                rd_gen++;
/* answered after the CAS latency */
                fork
                    drive_read(rd_gen, d);
                join_none
            end
/* WRITE */
            3'b100:
            begin
                logic [15:0] d;
                n_wr++;
/* the bank must be open long enough */
                chk(init_done, "WRITE before init");
                chk(open_b[ba], "WRITE to closed bank");
                chk(now - t_act[ba] >= tRCD, "tRCD violated (WRITE)");
/* the word so far, with the bytes that are not masked */
                chk(!a[10], "unexpected auto-precharge");
                d = mem.exists({ba, row_b[ba], a[8:0]}) ? mem[{ba, row_b[ba], a[8:0]}] : 16'hxxxx;
                if (!dqm[0])
                begin
/* the lower byte */
                    chk(!$isunknown(dq[7:0]),  "write data low byte unknown");
                    d[7:0]  = dq[7:0];
                end
                if (!dqm[1])
                begin
/* the upper byte */
                    chk(!$isunknown(dq[15:8]), "write data high byte unknown");
                    d[15:8] = dq[15:8];
                end
/* stored; the write recovery time starts */
                mem[{ba, row_b[ba], a[8:0]}] = d;
                t_wr[ba] = now;
            end
/* AUTO REFRESH */
            3'b001:
            begin
                n_ref++;
                for (int b = 0; b < BANKS; b++)
                begin
/* every bank closed */
                    chk(!open_b[b], "REF with open bank");
                    chk(now - t_pre[b] >= tRP, "tRP violated (REF)");
                end
                if (init_done)
                begin
/* the longest interval */
                    if (now - t_ref > max_ref_gap)
                    begin
                        max_ref_gap = now - t_ref;
                    end
                    chk(now - t_ref <= tREFI, $sformatf("refresh interval %0.1f ns too long", now - t_ref));
                end
                else
                begin
/* during initialisation they are counted */
                    init_refs++;
                end
                t_ref = now;
            end
/* MRS */
            3'b000:
            begin
                for (int b = 0; b < BANKS; b++)
                begin
                    chk(!open_b[b], "MRS with open bank");
                end
/* eight refreshes first; burst length 1; CAS latency 2 or 3 */
                chk(init_refs >= 8, "fewer than 8 refreshes before MRS");
                chk(a[2:0] == 3'b000 && a[3] == 1'b0, "unexpected burst mode");
                chk(a[6:4] == 3'd2 || a[6:4] == 3'd3, "illegal CAS latency");
/* the mode is set */
                cl = a[6:4];
                t_mrs = now;
                init_done = 1;
/* said */
                $display("%t SDRAM MODEL: mode register set, CL=%0d", now, cl);
            end
            default: err("unsupported command");
        endcase
    end

/* Refresh starvation check while running */
    if (init_done && now - t_ref > tREFI + T_CK)
    begin
        if (errors == 0 || now - t_ref < tREFI + REF_SLACK * T_CK)
        begin
            err("refresh overdue");
        end
    end
end

endmodule
