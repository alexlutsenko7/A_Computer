# The VDP of the MiSTer Genesis core: source and version

The Mega Drive's video chip (VDP) of LMega, with the block RAM wrappers it uses.

- Origin: https://github.com/MiSTer-devel/Genesis_MiSTer/tree/adc0c42cfb1fa5d484cc8566767f7d68982bc44a/rtl (`vdp.vhd`, `vdp_common.vhd`, `bram.vhd`)
- Commit: `adc0c42cfb1fa5d484cc8566767f7d68982bc44a` (2023-02-24).
- Copied unchanged on 2026-11-17. Do not edit these files; put wrappers / changes outside this folder.
- Authors: Gregory Estrade (fpgagen), Till Harbaum, Alexey Melnikov (Sorgelig), Gyorgy Szombathelyi.
- Licence: the BSD-style text below (from the header of vdp.vhd). It must be reproduced with source and with
  synthesized (bitstream) distributions.
- Not copied: the core's `system.sv` (Copyright (c) 2010 Gregory Estrade, Copyright (c) 2018 Sorgelig, the same
  licence text). Our `../md_system.sv` follows its bus logic (the main bus and Z80 bus state machines, the clock
  enables, the bus request handshake) and is therefore covered by the same notice; the memories, the controller
  ports and the sound mix are ours.
- Simulation: Questa refuses two constructs of `bram.vhd` that Quartus accepts (an entity used above its
  declaration, instantiations without the word `entity`); `../../sim/run_sim.sh` makes a corrected copy for the
  simulation only.

## Licence text (vdp.vhd)
```
Copyright (c) 2010 Gregory Estrade (greg@torlus.com)
Copyright (c) 2018 Till Harbaum
Copyright (c) 2018-2019 Alexey Melnikov
Copyright (c) 2018-2019 György Szombathelyi

All rights reserved

Redistribution and use in source and synthezised forms, with or without
modification, are permitted provided that the following conditions are met:

Redistributions of source code must retain the above copyright notice,
this list of conditions and the following disclaimer.

Redistributions in synthesized form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the distribution.

Neither the name of the author nor the names of other contributors may
be used to endorse or promote products derived from this software without
specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

Please report bugs to the author, but before you do so, please
make sure that this is not a derivative work and that
you have the latest version of this file.
```

## SHA-256 (first 16 hex digits)
```
06c5684457daa15a  bram.vhd
829c63e34d8f3c5b  vdp.vhd
1bdda3810bd4ad0f  vdp_common.vhd
```
