"""setup_next.py -- scratch copy of LNext/10cl025 with the JTAG rig (jtag_test.v) in its top.

Writes tmp/next_rig/LNext/10cl025 (project file, constraints, sources); build it there with
quartus_sh --flow compile LNext. The rig reads the VGA outputs and 16 status bits (card in, SD wait,
memory wait, reset, CPU speed, OSD, keyboard seen, the top 8 bits of the CPU's memory address) and
presses keys: the rig's code byte is a PS/2 set 2 code, its key bit says "extended" (keys.tcl).
The product image never contains the rig.
"""
import os
import shutil

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = ROOT + "/LNext/10cl025"
DST = ROOT + "/tmp/next_rig/LNext/10cl025"
os.makedirs(DST + "/rtl", exist_ok=True)
for f in os.listdir(SRC + "/rtl"):
    shutil.copy(SRC + "/rtl/" + f, DST + "/rtl/" + f)
shutil.copy(SRC + "/LNext.sdc", DST + "/LNext.sdc")
shutil.copy(SRC + "/LNext.qpf", DST + "/LNext.qpf")
q = open(SRC + "/LNext.qsf").read().replace("../../", "../../../../")
q += "set_global_assignment -name VERILOG_FILE ../../../../tests/jtag_rig/jtag_test.v\n"
open(DST + "/LNext.qsf", "w").write(q)
s = open(DST + "/rtl/LNext.v").read()
s = s.replace('"../../AMenu/', '"../../../../AMenu/')
old = s[s.index("/* a key event into the machine's clock"):s.index("/* Joysticks (DB9, active low)")]
new = '''/* RIG: key events from the keyboard or from JTAG (a PS/2 code; 0 = released) */
wire        rig_key;
wire [7:0]  rig_code;
reg  [1:0]  ps2_s;
reg         kb_t;
reg  [10:0] ps2_key;
reg  [7:0]  rc_s1, rc_s2, rc_cur;
reg  [5:0]  rc_wait;
reg         rc_ext;
always @(posedge clk28)
begin
    ps2_s <= {ps2_s[0], ps2_key56[10]};
    rc_s1 <= rig_code;
    rc_s2 <= rc_s1;
    if (rc_wait != 6'd0)
    begin
        rc_wait <= rc_wait - 6'd1;
    end
    else if (ps2_s[1] != kb_t)
    begin
        kb_t    <= ps2_s[1];
        ps2_key <= {!ps2_key[10], ps2_key56[9:0]};
        rc_wait <= 6'd63;
    end
    else if (rc_s2 == rc_s1 && rc_s2 != rc_cur)
    begin
        if (rc_cur != 8'd0)
        begin
            ps2_key <= {!ps2_key[10], 1'b0, rc_ext, rc_cur};
            rc_cur  <= 8'd0;
        end
        else
        begin
            ps2_key <= {!ps2_key[10], 1'b1, rig_key, rc_s2};
            rc_cur  <= rc_s2;
            rc_ext  <= rig_key;
        end
        rc_wait <= 6'd63;
    end
end

'''
s = s.replace(old, new)
old = "/* LED (active low): on from 2.7 s after the start */"
rig = '''/* RIG */
jtag_test #(.ID(32'h4E58_0001)) u_rig (
    .clk50  (CLOCK_50),
    .pclk   (clk28),
    .hs     (VGA_HS),
    .vs     (VGA_VS),
    .rgb    ({VGA_R, VGA_G, VGA_B}),
    .status ({card_in, sd_wait, ram_a_wait, rst_m, cpu_speed, l_osd_on, kb_seen, ram_a_addr[20:13]}),
    .key    (rig_key),
    .code   (rig_code)
);

'''
assert old in s
s = s.replace(old, rig + old)
open(DST + "/rtl/LNext.v", "w").write(s)
print("ok")
