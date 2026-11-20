#!/usr/bin/env python3
# mk_c10_files.py -- makes the two files of the Next core that LNext replaces, from the unchanged
# copies in ZXNEXT/ (run in LNext/10cl025 after ZXNEXT/ changed):
#
#   rtl/next_sprites.vhd   ZXNEXT/rtl/video/sprites.vhd with the five sprite attribute memories
#                          (128 x 8 each, one block RAM each) as one memory of 128 x 40 with a
#                          write enable per byte (two block RAMs)
#   rtl/next_bootrom.vhd   ZXNEXT/rtl/rom/bootrom.vhd with its last kilobyte (215 bytes used) as
#   rtl/next_bootrom_*.mif logic instead of a block RAM; the first 7 KB are three block ROMs with .mif files
#
# The 10CL025 has 66 block RAMs and the machine needs every one of them.
import re
import sys

# source and destination files
SPRITES_IN = "../../ZXNEXT/rtl/video/sprites.vhd"
SPRITES_OUT = "rtl/next_sprites.vhd"
BOOT_IN = "../../ZXNEXT/rtl/rom/bootrom.vhd"
BOOT_OUT = "rtl/next_bootrom.vhd"
# the block ROMs: name, first byte, size; their contents' files, and the path as the project sees it
ROM_PARTS = (("a", 0, 4096), ("b", 4096, 2048), ("c", 6144, 1024))
MIF_NAME = "next_bootrom_%s.mif"
MIF_DIR = "rtl/"
MIF_PATH = "rtl/"
# the attribute memories
ATTR_COUNT = 5
# the boot ROM: its size, the part kept in block RAM
ROM_SIZE = 8192
ROM_BLOCK = 7168
# an unused byte
EMPTY = 0xFF

NOTE = ("-- Made by LNext/10cl025/tools/mk_c10_files.py from the file of the same entity in ZXNEXT/\n"
        "-- (the copy there is unchanged). Do not edit: change the script.\n")

MERGED = """   -- LNext: the five attribute memories as one of 128 x 40 (next_bram.vhd), a write enable per byte

   attr_all : entity work.aram_128_40
   port map (
      DPRA => spr_attr_a,
      CLK  => clock_master_180o_i,
      WE   => attr4_we & attr3_we & attr2_we & attr1_we & attr0_we,
      DPO(7 downto 0)   => sprite_attr_0,
      DPO(15 downto 8)  => sprite_attr_1,
      DPO(23 downto 16) => sprite_attr_2,
      DPO(31 downto 24) => sprite_attr_3,
      DPO(39 downto 32) => sprite_attr_4,
      A    => attr_a,
      D    => attr_data
   );

"""


def make_sprites():
    text = open(SPRITES_IN, encoding="latin-1").read()
    count = 0
    for index in range(ATTR_COUNT):
        # one instance: from its label to the end of its port map
        pattern = re.compile(r"   attr%d : sdpram_128_8\s*\n   port map \(.*?\);\n" % index, re.S)
        replacement = MERGED if index == 0 else ""
        text, found = pattern.subn(lambda m: replacement, text, count=1)
        count += found
    if count != ATTR_COUNT:
        sys.exit("sprites.vhd: %d attribute memories found, %d expected" % (count, ATTR_COUNT))
    open(SPRITES_OUT, "w", encoding="latin-1", newline="\n").write(NOTE + text)


def make_bootrom():
    text = open(BOOT_IN, encoding="latin-1").read()
    data = [int(value, 16) for value in re.findall(r'x"([0-9A-Fa-f]{2})"', text)]
    if len(data) != ROM_SIZE:
        sys.exit("bootrom.vhd: %d bytes found, %d expected" % (len(data), ROM_SIZE))
    # the block ROMs' contents
    for name, first, size in ROM_PARTS:
        mif = ["-- Made by LNext/10cl025/tools/mk_c10_files.py: bytes 0x%04X-0x%04X of the Next's boot ROM\n"
               % (first, first + size - 1)]
        mif.append("DEPTH = %d;\nWIDTH = 8;\nADDRESS_RADIX = HEX;\nDATA_RADIX = HEX;\nCONTENT BEGIN\n" % size)
        for address in range(size):
            mif.append("%04X : %02X;\n" % (address, data[first + address]))
        mif.append("END;\n")
        open(MIF_DIR + MIF_NAME % name, "w", newline="\n").write("".join(mif))
    header = text[:text.index("library ieee")]
    lines = [NOTE, header]
    lines.append("library ieee;\n  use ieee.std_logic_1164.all;\n  use ieee.numeric_std.all;\n\n")
    lines.append("library altera_mf;\n  use altera_mf.altera_mf_components.all;\n\n")
    lines.append("entity bootrom is\n  port (\n    CLK         : in    std_logic;\n")
    lines.append("    ADDR        : in    std_logic_vector(12 downto 0);\n")
    lines.append("    DATA        : out   std_logic_vector(7 downto 0)\n    );\nend;\n\n")
    lines.append("architecture RTL of bootrom is\n\n")
    for name, first, size in ROM_PARTS:
        lines.append("  signal %s_q    : std_logic_vector(7 downto 0);\n" % name)
    lines.append("  signal hi_q   : std_logic_vector(7 downto 0);\n")
    lines.append("  signal addr_q : std_logic_vector(12 downto 0);\n\n")
    lines.append("begin\n\n")
    lines.append("  -- the first 7 KB: block ROMs of 4, 2 and 1 KB (seven block RAMs; one ROM of 7 KB would take eight)\n")
    for name, first, size in ROM_PARTS:
        bits = size.bit_length() - 1
        lines.append("  rom_%s : altsyncram\n  generic map (\n" % name)
        lines.append('    operation_mode => "ROM",\n    width_a => 8,\n    widthad_a => %d,\n    numwords_a => %d,\n' % (bits, size))
        lines.append('    init_file => "%s",\n    outdata_reg_a => "UNREGISTERED",\n' % (MIF_PATH + MIF_NAME % name))
        lines.append('    intended_device_family => "Cyclone 10 LP",\n    lpm_type => "altsyncram"\n  )\n')
        lines.append("  port map (\n    clock0 => CLK,\n    address_a => ADDR(%d downto 0),\n    q_a => %s_q\n  );\n\n" % (bits - 1, name))
    lines.append("  process (CLK)\n  begin\n    if rising_edge(CLK) then\n")
    lines.append("      addr_q <= ADDR;\n")
    lines.append("    end if;\n  end process;\n\n")
    lines.append("  -- the last kilobyte: logic\n")
    lines.append("  process (addr_q)\n  begin\n    case to_integer(unsigned(addr_q)) is\n")
    for address in range(ROM_BLOCK, ROM_SIZE):
        if data[address] != EMPTY:
            lines.append('      when %d => hi_q <= x"%02X";\n' % (address, data[address]))
    lines.append('      when others => hi_q <= x"%02X";\n' % EMPTY)
    lines.append("    end case;\n  end process;\n\n")
    lines.append("  -- 0000-0FFF, 1000-17FF, 1800-1BFF, 1C00-1FFF\n")
    lines.append("  DATA <= a_q when addr_q(12) = '0' else\n")
    lines.append("          b_q when addr_q(11) = '0' else\n")
    lines.append("          c_q when addr_q(10) = '0' else\n")
    lines.append("          hi_q;\n\n")
    lines.append("end RTL;\n")
    open(BOOT_OUT, "w", encoding="latin-1", newline="\n").write("".join(lines))


def main():
    make_sprites()
    make_bootrom()
    print("made %s, %s and its three .mif files" % (SPRITES_OUT, BOOT_OUT))
    return 0


sys.exit(main())
