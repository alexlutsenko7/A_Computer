# ZXNEXT: source and version

The ZX Spectrum Next core of LNext (`LNext/10cl025`), in its MiSTer port.

- Origin: https://github.com/MiSTer-devel/ZXNext_MiSTer (the port by Alexey Melnikov of the original core,
  https://gitlab.com/SpectrumNext/ZX_Spectrum_Next_FPGA, by Alvin Albrecht, Victor Trucco and Fabio Belavenuto).
- Commit: `7daebd1983ec4d04f4d22541d2f52d92badbbe5f` (2026-09-28).
- Copied unchanged on 2026-11-19: the `rtl/` folder without the PLL and without the MiSTer-only parts
  (`rtl/mister/ddram.sv`, `rtc.sv`, `tzxplayer.vhd`, `MiSTer.qip`), and `sys/sd_card.sv` (the SD card made of
  logic, from the MiSTer framework). Do not edit these files; put wrappers / changes outside this folder.
- Licence: the core GPL-3 (see the file headers and `LICENSE`); `sys/sd_card.sv` LGPL-3. The sources of a
  distributed bitstream must be offered.
- Not used by LNext: `rtl/mister/bram.vhd` (memories for Cyclone V; ours is `LNext/10cl025/rtl/next_bram.vhd`),
  `rtl/mister/sdram.sv` (written again for our SDRAM pins as `next_sdram.v`), `rtl/video/sprites.vhd` and
  `rtl/rom/bootrom.vhd` (LNext builds adapted copies of the two with `LNext/10cl025/tools/mk_c10_files.py`).
- The boot ROM inside the core loads `TBBLUE.FW` from the SD card. That file, the ROMs and NextZXOS are not
  part of this project: they are the Spectrum Next distribution (https://www.specnext.com/latestdistro/).

## SHA-256 (first 16 hex digits)
```
8177f97513213526  LICENSE
cbfef63ef7553918  rtl/audio/audio_mixer.vhd
9bef96119508463e  rtl/audio/dac.vhd
d363db3f21ef1bff  rtl/audio/i2s.vhd
97ffa8b9aa64abb8  rtl/audio/i2s/i2s_master.vhd
53521a78e51d92bf  rtl/audio/i2s/i2s_receive.vhd
baa7c274d559effc  rtl/audio/i2s/i2s_slave.vhd
af4bd4e81559ecaf  rtl/audio/i2s/i2s_transmit.vhd
113aaf10024300b8  rtl/audio/pwm.vhd
8307ba863862f094  rtl/audio/soundrive.vhd
90a7592134d4f79b  rtl/audio/turbosound.vhd
f08734b72d5c8f45  rtl/audio/ym2149.vhd
a3d7de3af81867c7  rtl/cpu/t80n.vhd
3cdb1e6089b3f0c8  rtl/cpu/t80n_alu.vhd
94708aae35f96e24  rtl/cpu/t80n_mcode.vhd
dcd410b84d1d5d77  rtl/cpu/t80n_pack.vhd
7813bacfb2c5a194  rtl/cpu/t80na.vhd
09c76d9d197024a7  rtl/device/copper.vhd
366e847d31a2b5b2  rtl/device/ctc.vhd
9b3a83f366b2b4fb  rtl/device/ctc_chan.vhd
155b296f2fd49d1c  rtl/device/divmmc.vhd
effe46bf9b31094b  rtl/device/dma.vhd
ec910f377c884b53  rtl/device/im2_control.vhd
61dd77eb5f7e8214  rtl/device/im2_device.vhd
197cc6a4f9fb6cbe  rtl/device/im2_peripheral.vhd
8b95a6cf9a3463bb  rtl/device/multiface.vhd
0820ce26284a113e  rtl/device/peripherals.vhd
c699c3e4d39961c6  rtl/input/keyboard/keymaps.vhd
7fb0c773ef83cc0e  rtl/input/keyboard/ps2_iobase.vhd
3574767362ecd865  rtl/input/keyboard/ps2_keyb.vhd
3e3dbcf490baf837  rtl/input/md6_joystick_connector_x2.vhd
51b7994d97c4f802  rtl/input/membrane/emu_fnkeys.vhd
cddbec80595ae549  rtl/input/membrane/membrane.vhd
9e7441983037221d  rtl/input/membrane/membrane_stick.vhd
e94dc388a355648f  rtl/input/ps2_mouse.v
d1dfd8acc0acdb57  rtl/misc/asymmetrical_debounce.vhd
621c9947cc66da9b  rtl/misc/debounce.vhd
fcfb799ce2b589a4  rtl/misc/flashboot.vhd
8633a7bde08c199d  rtl/misc/flashboot_old.vhd
c6fddf87190be0cb  rtl/misc/relaxation.vhd
59e10efd2081d5ff  rtl/misc/synchronize.vhd
99a8423c0391795d  rtl/mister/bram.vhd
81f13191303b75d7  rtl/mister/keyjoy_sdpram_64_6.mif
fb1ba48a0b8c62bb  rtl/mister/ps2_keyb.vhd
914ccd42f40e7ecf  rtl/mister/sdram.sv
8bd773ac3643eba5  rtl/mister/zxnext_top.vhd
0b908e5ee154e92b  rtl/rom/bootrom.vhd
edf264e08676a843  rtl/serial/fifop.vhd
40db31382ef984c6  rtl/serial/spi_master.vhd
0de734af0ddb4e54  rtl/serial/uart.vhd
b336ada76a1cf93b  rtl/serial/uart_old.vhd
0f46f8f121eab9c4  rtl/serial/uart_rx.vhd
eb228cf33448099a  rtl/serial/uart_tx.vhd
94dd54df28b84d86  rtl/video/layer2.vhd
a0382d77e35de661  rtl/video/lores.vhd
593bfd0781e7e4b5  rtl/video/sprites.vhd
c5e5d25f4a3c852c  rtl/video/tilemap.vhd
f36ec9716a189996  rtl/video/zxula.vhd
8ad5b4bba35b7afb  rtl/video/zxula_timing.vhd
c823aff2adfa2df2  rtl/zxnext.vhd
25114f9a0e9ab4dd  sys/sd_card.sv
```
