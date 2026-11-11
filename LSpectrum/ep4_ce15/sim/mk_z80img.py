#!/usr/bin/env python3
"""mk_z80img.py SNAP.z80 OUT.hex -- machine image of a .z80 for tb_floatgame.sv:
lines 0..131071 = RAM pages 0-7, then 7 register words (cpu_t80 layout), then 7FFD, border."""
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "esp32", "test"))
import z80ref
st = z80ref.load(open(sys.argv[1], "rb").read(), z80ref.State(fill=0))
with open(sys.argv[2], "w") as f:
    f.write("".join("%02x\n" % b for b in st.ram))
    f.write("".join("%08x\n" % r for r in st.regs))
    f.write("%02x\n%02x\n" % (st.p7ffd, st.border))
print("PC %04x  7FFD %02x  IM %d" % (st.regs[2] & 0xFFFF, st.p7ffd, (st.regs[6] >> 16) & 3))
