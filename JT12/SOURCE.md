# JT12: source and version

The YM2612 (FM sound) of LMega (the Sega Mega Drive machine, `LMega/10cl025`).

- Origin: https://github.com/MiSTer-devel/Genesis_MiSTer/tree/adc0c42cfb1fa5d484cc8566767f7d68982bc44a/rtl/jt12 (the copy the MiSTer Genesis core uses; jt12 itself: https://github.com/jotego/jt12)
- Commit: `adc0c42cfb1fa5d484cc8566767f7d68982bc44a` (2023-02-24).
- Copied unchanged on 2026-11-17. Do not edit these files; put wrappers / changes outside this folder.
- Author: Jose Tejada (jotego), the author of JT49 (the AY-3-8910 of LSpectrum).
- Licence: GPL-3 (`LICENSE`): the sources of a distributed bitstream must be offered.
- Used: the files of `jt12.qip` (the YM2612 wrapper `jt12.v`). The other files of the folder (YM2203 / YM2610
  variants, ADPCM, mixer) come with the copy and are not built.
- Simulation: `jt12_pcm_interpol.v` uses a register above its declaration, which Questa refuses;
  `LMega/10cl025/sim/run_sim.sh` makes a corrected copy for the simulation only.

## SHA-256 (first 16 hex digits)
```
589ed823e9a84c56  LICENSE
31aea9e22a654cae  README.md
416432ff8e0ab1d4  adpcm/gen_lingain.py
bde15367241204f6  adpcm/jt10_adpcm.v
a0c5f404dc28ab4d  adpcm/jt10_adpcm_acc.v
cf4e1ee18151c982  adpcm/jt10_adpcm_cnt.v
f959c339b51f8979  adpcm/jt10_adpcm_comb.v
9ec98f60d31c4a6a  adpcm/jt10_adpcm_dbrom.v
b8b30c1cae5bb3fa  adpcm/jt10_adpcm_div.v
19d0a46493c5404b  adpcm/jt10_adpcm_drvA.v
5c4aece1eef311c5  adpcm/jt10_adpcm_drvB.v
251203e623465f09  adpcm/jt10_adpcm_dt.v
12894e6f1e828a05  adpcm/jt10_adpcm_gain.v
0aa5eb92479cc775  adpcm/jt10_adpcma_lut.v
dd257407b1077924  adpcm/jt10_adpcmb.v
dadaef9d2e9b28b1  adpcm/jt10_adpcmb_cnt.v
e8ce4953be4ef31c  adpcm/jt10_adpcmb_gain.v
bb6262f41aea467b  adpcm/jt10_adpcmb_interpol.v
720550af9699db08  adpcm/jt10_cen_burst.v
de824e7704bb6d29  alt/eg_cnt.v
ae6052694482a90c  alt/eg_comb.v
427d693c57c02c3c  alt/eg_mux.v
d4a7eb654f6cfd4d  alt/eg_step.v
fb1ce714ed5905d2  alt/eg_step_ram.v
4bead692fa517552  dac/jt12_dac.v
94cbb8d312732290  dac/jt12_dac2.v
b8a2a0e25c1f18c9  jt03.qip
cb2229cfa5e0ca69  jt03.v
51c5251e76390060  jt03.yaml
fb3b4b33790e06b7  jt03_acc.v
a4789215bfea8b2c  jt03_fm.qip
5ebb980b22e1b265  jt10.qip
9615f949884261e9  jt10.v
d70d5a66184bffb8  jt10_acc.v
64d16c0e88467ab2  jt12.qip
3d0f207932a980cb  jt12.v
e41fde4942c88d77  jt12.vhd
5d0ea1e7d9240706  jt12_acc.v
4aaabf1cdaeaa1e7  jt12_csr.v
7eb947c7d2172211  jt12_div.v
cfc26791f2cc21d2  jt12_dout.v
a6d21dbd10c42031  jt12_eg.v
f659140c6881fc52  jt12_eg_cnt.v
1ca6e221ef0e222d  jt12_eg_comb.v
f570518cdd0b653b  jt12_eg_ctrl.v
100cd049e409adfb  jt12_eg_final.v
23a12e8fcc946ae8  jt12_eg_pure.v
77af630259cee627  jt12_eg_step.v
53ca640b882ad1e4  jt12_exprom.v
278906bed31509c7  jt12_kon.v
67839ad9271072b5  jt12_lfo.v
372d99205ac743b1  jt12_logsin.v
76631f26fef4e2bf  jt12_mmr.v
5dd5703ae0d4e235  jt12_mmr_sim.vh
74d9ccf472bd9ea4  jt12_mod.v
9e3cc26a78e981db  jt12_op.v
3b68b1dc76cad3df  jt12_pcm.v
c3c984a9cbd5fe9d  jt12_pcm_interpol.v
45adc7c30419cdfd  jt12_pg.v
5aac7ff07533fd17  jt12_pg_comb.v
ea54be76a10628d3  jt12_pg_dt.v
5c766037c4138062  jt12_pg_inc.v
928128558cf56ecd  jt12_pg_sum.v
1365093deeea115f  jt12_pm.v
ec4d509383b7f381  jt12_reg.v
5aadf3d18c8e52f0  jt12_rst.v
a698c891f13593b2  jt12_sh.v
d15232653c91ecf7  jt12_sh24.v
9c313ef1e013be79  jt12_sh_rst.v
f989b34f1947c158  jt12_single_acc.v
f6b274620e265af8  jt12_sumch.v
ab1f190e0105414c  jt12_timers.v
7a70d118db705b8e  jt12_top.v
9fe2041147fbc379  mixer/jt12_comb.v
6a00bae9ab9fe292  mixer/jt12_decim.v
1dafabd01137a504  mixer/jt12_fm_uprate.v
0a72ab15e644e7de  mixer/jt12_genmix.v
cf735da30db48cb2  mixer/jt12_interpol.v
8fc5f8fa159b63ac  mixer/jt12_mixer.v
```
