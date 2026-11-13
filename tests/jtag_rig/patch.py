"""patch.py WORK -- the test rig into the four tops and the 10cl025 project files of the scratch copy"""
import re, sys, os
W = sys.argv[1]
def patch(path, ident, status, key_old=None, key_new=None, extra_decl='', extra_end=''):
    s = open(path, encoding='utf-8').read()
    if key_old:
        assert s.count(key_old) == 1, (path, key_old)
        s = s.replace(key_old, key_new)
    # declarations right after the first module header, the instance before the last endmodule
    m = re.search(r'^\);\s*$', s, flags=re.M)
    s = s[:m.end()] + '\nwire t_key;\nwire [7:0] t_code;\n' + extra_decl + s[m.end():]
    k = s.rindex('endmodule')
    inst = ('%sjtag_test #(.ID(32\'h%s)) u_jt (.clk50(CLOCK_50), .pclk(pclk), .hs(VGA_HS), .vs(VGA_VS),\n'
            '    .rgb({VGA_R, VGA_G, VGA_B}), .status(%s), .key(t_key), .code(t_code));\n\n') % (extra_end, ident, status)
    s = s[:k] + inst + s[k:]
    open(path, 'w', encoding='utf-8', newline='\n').write(s)
K_OLD = 'k1_s <= {k1_s[1:0], KEY1};'
K_NEW = 'k1_s <= {k1_s[1:0], KEY1 & !t_key};'
patch(W + '/LSpectrum/ep4_ce15/rtl/LSpectrum.v', '5A580001', '{15\'d0, LEDR}', K_OLD, K_NEW)
patch(W + '/L64/ep4_ce15/rtl/L64.v', '43360002', '{15\'d0, LEDR}', K_OLD, K_NEW)
patch(W + '/LTari/ep4_ce15/rtl/LTari.v', '41540001', '{14\'d0, MODEL130 != 0, LEDR}', K_OLD, K_NEW)
patch(W + '/AMenu/ep4_ce15/rtl/AMenu.v', '4D4E0002',
      '{1\'b0, ru_trig, ru_mode, init_done, started, err, sel, 1\'b0, LEDR}',
      '.raw    (kb_raw)', '.raw    (kb_raw_k)', 'wire [31:0] kb_raw_k;\n',
      'assign kb_raw = kb_raw_k | {8\'d0, t_code, 16\'d0};\n')
for d, revs in (('AMenu', ['AMenu']), ('LSpectrum', ['LSpectrum']), ('L64', ['L64']), ('LTari', ['LTari', 'LTari800'])):
    for r in revs:
        q = '%s/%s/10cl025/%s.qsf' % (W, d, r)
        s = open(q).read()
        s += '\nset_global_assignment -name VERILOG_FILE ../../../jtag_test.v\n'
        open(q, 'w', newline='\n').write(s)
print('patched')
