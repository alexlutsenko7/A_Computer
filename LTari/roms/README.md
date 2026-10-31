# LTari ROMs

Free replacement ROMs by Avery Lee (Altirra), taken from the atari800 emulator's source
(`src/roms/altirraos_xl.c`, `src/roms/altirra_basic.c`, github.com/atari800/atari800, branch master,
2026-10-29), where they are compiled from Altirra's ROM sources; the C arrays were converted to binaries.

| File | Size | What | Version |
|---|---|---|---|
| `altirraos_xl.rom` | 16 KB | AltirraOS XL/XE/XEGS kernel, $C000-$FFFF (self-test window $5000-$57FF from its $D000-$D7FF) | 3.11 |
| `altirra_basic.rom` | 8 KB | Altirra BASIC, $A000-$BFFF (cartridge header at $BFFA) | 1.59 |

Licence (both files carry it, copyright Avery Lee 2008-2018 / 2008-2022):

> Copying and distribution of this file, with or without modification, are permitted in any medium without
> royalty provided the copyright notice and this notice are preserved. This file is offered as-is, without
> any warranty.

So they may go into the repository and the .jic. The original Atari OS and BASIC ROMs are not included.
