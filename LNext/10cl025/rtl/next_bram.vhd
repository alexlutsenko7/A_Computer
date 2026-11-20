-- next_bram.vhd: the memories of the ZX Spectrum Next core (ZXNEXT/) for the Cyclone 10 LP.
-- It replaces the MiSTer port's rtl/mister/bram.vhd (same entity names and ports).
--
-- The core was written for an FPGA with asynchronous-read distributed RAM. The Cyclone 10 LP
-- has only M9K blocks, whose read address is always registered. Entity aram gives the
-- asynchronous-read memories a block RAM: the read address is registered on the opposite edge
-- of the write clock, so a value written on one edge and the value of an address set on that
-- edge are both there half a clock later. A one-word bypass covers the read that comes half
-- a clock after a write to the same address (the M9K stores a word on the write clock's
-- second edge: read and write would meet).
--
-- Small memories (16 and 64 words) are registers (entity rram).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library altera_mf;
use altera_mf.altera_mf_components.all;

-- asynchronous-read memory made of a block RAM
entity aram is
   generic
   (
      addr_width : integer := 8;
      data_width : integer := 8
   );
   port
   (
      clk       : in  std_logic;
      rdaddress : in  std_logic_vector(addr_width-1 downto 0);
      q         : out std_logic_vector(data_width-1 downto 0);
      wraddress : in  std_logic_vector(addr_width-1 downto 0);
      data      : in  std_logic_vector(data_width-1 downto 0);
      wren      : in  std_logic
   );
end entity;

architecture rtl of aram is

   signal clk_n    : std_logic;
   signal ram_q    : std_logic_vector(data_width-1 downto 0);
   -- the last write
   signal bw_en    : std_logic := '0';
   signal bw_addr  : std_logic_vector(addr_width-1 downto 0) := (others => '0');
   signal bw_data  : std_logic_vector(data_width-1 downto 0) := (others => '0');
   -- the read meets the last write
   signal hit      : std_logic := '0';
   signal hit_data : std_logic_vector(data_width-1 downto 0) := (others => '0');

begin

   clk_n <= not clk;

   -- port A writes on clk, port B reads on the opposite edge
   ram : altsyncram
   generic map
   (
      address_reg_b => "CLOCK1",
      clock_enable_input_a => "BYPASS",
      clock_enable_input_b => "BYPASS",
      clock_enable_output_b => "BYPASS",
      intended_device_family => "Cyclone 10 LP",
      lpm_type => "altsyncram",
      numwords_a => 2**addr_width,
      numwords_b => 2**addr_width,
      operation_mode => "DUAL_PORT",
      outdata_aclr_b => "NONE",
      outdata_reg_b => "UNREGISTERED",
      power_up_uninitialized => "FALSE",
      widthad_a => addr_width,
      widthad_b => addr_width,
      width_a => data_width,
      width_b => data_width,
      width_byteena_a => 1
   )
   port map
   (
      clock0    => clk,
      wren_a    => wren,
      address_a => wraddress,
      data_a    => data,
      clock1    => clk_n,
      address_b => rdaddress,
      q_b       => ram_q
   );

   -- the last write
   process (clk)
   begin
      if rising_edge(clk) then
         bw_en   <= wren;
         bw_addr <= wraddress;
         bw_data <= data;
      end if;
   end process;

   -- a read of the word written half a clock earlier takes the word from the bypass
   process (clk_n)
   begin
      if rising_edge(clk_n) then
         if bw_en = '1' and bw_addr = rdaddress then
            hit <= '1';
         else
            hit <= '0';
         end if;
         hit_data <= bw_data;
      end if;
   end process;

   q <= hit_data when hit = '1' else ram_q;

end rtl;

------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- asynchronous-read memory made of registers
entity rram is
   generic
   (
      addr_width : integer := 4;
      data_width : integer := 9
   );
   port
   (
      clk       : in  std_logic;
      rdaddress : in  std_logic_vector(addr_width-1 downto 0);
      q         : out std_logic_vector(data_width-1 downto 0);
      wraddress : in  std_logic_vector(addr_width-1 downto 0);
      data      : in  std_logic_vector(data_width-1 downto 0);
      wren      : in  std_logic
   );
end entity;

architecture rtl of rram is

   type mem_t is array (0 to 2**addr_width-1) of std_logic_vector(data_width-1 downto 0);
   signal mem : mem_t := (others => (others => '0'));
   -- registers, not a block RAM (the read is asynchronous)
   attribute ramstyle : string;
   attribute ramstyle of mem : signal is "logic";

begin

   process (clk)
   begin
      if rising_edge(clk) then
         if wren = '1' then
            mem(to_integer(unsigned(wraddress))) <= data;
         end if;
      end if;
   end process;

   q <= mem(to_integer(unsigned(rdaddress)));

end rtl;

------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- joystick-to-key map: 64 x 6 registers with the Sinclair / cursor mappings at power-up
entity keyjoy_sdpram_64_6 is
port
(
   DPRA : in  std_logic_vector(5 downto 0);
   DPO  : out std_logic_vector(5 downto 0);
   CLK  : in  std_logic;
   WE   : in  std_logic;
   A    : in  std_logic_vector(5 downto 0);
   D    : in  std_logic_vector(5 downto 0)
);
end entity;

architecture rtl of keyjoy_sdpram_64_6 is

   type mem_t is array (0 to 63) of std_logic_vector(5 downto 0);
   -- the contents of the MiSTer port's keyjoy_sdpram_64_6.mif
   signal mem : mem_t :=
   (
      "100011", "100100", "100010", "100001", "100000", "011001", "011000", "011010",
      "011011", "011100", "100010", "011100", "100100", "100011", "100000", "111111",
      "000111", "000111", "000111", "000111", "000111", "000111", "000111", "000111",
      "000111", "000111", "000111", "000111", "000111", "000111", "000111", "000111",
      "100011", "100100", "100010", "100001", "100000", "011001", "011000", "011010",
      "011011", "011100", "100010", "011100", "100100", "100011", "100000", "111111",
      "000111", "000111", "000111", "000111", "000111", "000111", "000111", "000111",
      "000111", "000111", "000111", "000111", "000111", "000111", "000111", "000111"
   );
   attribute ramstyle : string;
   attribute ramstyle of mem : signal is "logic";

begin

   process (CLK)
   begin
      if rising_edge(CLK) then
         if WE = '1' then
            mem(to_integer(unsigned(A))) <= D;
         end if;
      end if;
   end process;

   DPO <= mem(to_integer(unsigned(DPRA)));

end rtl;

------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library altera_mf;
use altera_mf.altera_mf_components.all;

-- sprite attributes: the core's five memories of 128 x 8 as one of 128 x 40 with a write enable
-- per byte (rtl/next_sprites.vhd). Asynchronous read as entity aram: the read address is
-- registered on the opposite clock edge, a bypass covers the read half a clock after a write.
entity aram_128_40 is
port
(
   DPRA : in  std_logic_vector(6 downto 0);
   DPO  : out std_logic_vector(39 downto 0);
   CLK  : in  std_logic;
   WE   : in  std_logic_vector(4 downto 0);
   A    : in  std_logic_vector(6 downto 0);
   D    : in  std_logic_vector(7 downto 0)
);
end entity;

architecture rtl of aram_128_40 is

   signal clk_n    : std_logic;
   signal we_any   : std_logic;
   signal d_all    : std_logic_vector(39 downto 0);
   signal ram_q    : std_logic_vector(39 downto 0);
   -- the last write
   signal bw_en    : std_logic_vector(4 downto 0) := (others => '0');
   signal bw_addr  : std_logic_vector(6 downto 0) := (others => '0');
   signal bw_data  : std_logic_vector(7 downto 0) := (others => '0');
   -- the bytes of the read that meet the last write
   signal hit      : std_logic_vector(4 downto 0) := (others => '0');
   signal hit_data : std_logic_vector(7 downto 0) := (others => '0');

begin

   clk_n  <= not CLK;
   we_any <= '1' when WE /= "00000" else '0';
   d_all  <= D & D & D & D & D;

   -- port A writes on CLK, port B reads on the opposite edge
   ram : altsyncram
   generic map
   (
      address_reg_b => "CLOCK1",
      byte_size => 8,
      clock_enable_input_a => "BYPASS",
      clock_enable_input_b => "BYPASS",
      clock_enable_output_b => "BYPASS",
      intended_device_family => "Cyclone 10 LP",
      lpm_type => "altsyncram",
      numwords_a => 128,
      numwords_b => 128,
      operation_mode => "DUAL_PORT",
      outdata_aclr_b => "NONE",
      outdata_reg_b => "UNREGISTERED",
      power_up_uninitialized => "FALSE",
      widthad_a => 7,
      widthad_b => 7,
      width_a => 40,
      width_b => 40,
      width_byteena_a => 5
   )
   port map
   (
      clock0    => CLK,
      wren_a    => we_any,
      byteena_a => WE,
      address_a => A,
      data_a    => d_all,
      clock1    => clk_n,
      address_b => DPRA,
      q_b       => ram_q
   );

   -- the last write
   process (CLK)
   begin
      if rising_edge(CLK) then
         bw_en   <= WE;
         bw_addr <= A;
         bw_data <= D;
      end if;
   end process;

   -- a read of bytes written half a clock earlier takes them from the bypass
   process (clk_n)
   begin
      if rising_edge(clk_n) then
         if bw_addr = DPRA then
            hit <= bw_en;
         else
            hit <= (others => '0');
         end if;
         hit_data <= bw_data;
      end if;
   end process;

   bytes : for i in 0 to 4 generate
      DPO(8*i+7 downto 8*i) <= hit_data when hit(i) = '1' else ram_q(8*i+7 downto 8*i);
   end generate;

end rtl;

------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- sprite line buffer: 512 x 9, one address for read and write
entity spram_320_9 is
port
(
   CLK  : in  std_logic;
   WE   : in  std_logic;
   SPO  : out std_logic_vector(8 downto 0);
   A    : in  std_logic_vector(8 downto 0);
   D    : in  std_logic_vector(8 downto 0)
);
end entity;

architecture rtl of spram_320_9 is
begin

   ram : entity work.aram
   generic map
   (
      addr_width => 9,
      data_width => 9
   )
   port map
   (
      clk       => CLK,
      rdaddress => A,
      q         => SPO,
      wraddress => A,
      data      => D,
      wren      => WE
   );

end rtl;

------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- sprite patterns: 16 KB block RAM
entity sdpbram_16k_8 is
port
(
   WEA    : in  std_logic;
   ADDRA  : in  std_logic_vector(13 downto 0);
   DINA   : in  std_logic_vector(7 downto 0);
   CLKA   : in  std_logic;
   --
   ENB    : in  std_logic;
   ADDRB  : in  std_logic_vector(13 downto 0);
   DOUTB  : out std_logic_vector(7 downto 0);
   CLKB   : in  std_logic
);
end entity;

architecture rtl of sdpbram_16k_8 is
begin

   ram : entity work.dpram
   generic map
   (
      addr_width_a => 14,
      data_width_a => 8,
      addr_width_b => 14,
      data_width_b => 8
   )
   port map
   (
      clock0    => CLKA,
      clock1    => CLKB,

      address_a => ADDRA,
      data_a    => DINA,
      wren_a    => WEA,

      address_b => ADDRB,
      q_b       => DOUTB
   );

end rtl;

------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- tilemap pixels: 16 x 9
entity sdpram_16_9 is
port
(
   DPRA : in  std_logic_vector(3 downto 0);
   DPO  : out std_logic_vector(8 downto 0);
   CLK  : in  std_logic;
   WE   : in  std_logic;
   A    : in  std_logic_vector(3 downto 0);
   D    : in  std_logic_vector(8 downto 0)
);
end entity;

architecture rtl of sdpram_16_9 is
begin

   ram : entity work.rram
   generic map
   (
      addr_width => 4,
      data_width => 9
   )
   port map
   (
      clk       => CLK,
      rdaddress => DPRA,
      q         => DPO,
      wraddress => A,
      data      => D,
      wren      => WE
   );

end rtl;

------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- UART transmit FIFO: 64 x 9
entity sdpram_64_9 is
port
(
   DPRA  : in  std_logic_vector(5 downto 0);
   CLK   : in  std_logic;
   WE    : in  std_logic;
   DPO   : out std_logic_vector(8 downto 0);
   A     : in  std_logic_vector(5 downto 0);
   D     : in  std_logic_vector(8 downto 0)
);
end entity;

architecture rtl of sdpram_64_9 is
begin

   ram : entity work.rram
   generic map
   (
      addr_width => 6,
      data_width => 9
   )
   port map
   (
      clk       => CLK,
      rdaddress => DPRA,
      q         => DPO,
      wraddress => A,
      data      => D,
      wren      => WE
   );

end rtl;

------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;

-- true dual port block RAM
entity tdpram is
generic
(
   addr_width_g : integer := 8;
   data_width_g : integer := 8
);
port
(
   clk_a_i  : in  std_logic;
   we_a_i   : in  std_logic;
   addr_a_i : in  std_logic_vector(addr_width_g-1 downto 0);
   data_a_i : in  std_logic_vector(data_width_g-1 downto 0);
   data_a_o : out std_logic_vector(data_width_g-1 downto 0);
   --
   clk_b_i  : in  std_logic;
   we_b_i   : in  std_logic;
   addr_b_i : in  std_logic_vector(addr_width_g-1 downto 0);
   data_b_i : in  std_logic_vector(data_width_g-1 downto 0);
   data_b_o : out std_logic_vector(data_width_g-1 downto 0)
);
end entity;

architecture rtl of tdpram is
begin

   ram : entity work.dpram
   generic map
   (
      addr_width_a => addr_width_g,
      data_width_a => data_width_g,
      addr_width_b => addr_width_g,
      data_width_b => data_width_g
   )
   port map
   (
      clock0    => clk_a_i,
      clock1    => clk_b_i,

      address_a => addr_a_i,
      data_a    => data_a_i,
      wren_a    => we_a_i,
      q_a       => data_a_o,

      address_b => addr_b_i,
      data_b    => data_b_i,
      wren_b    => we_b_i,
      q_b       => data_b_o
   );

end rtl;

------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;

-- dual port block RAM, port B read only
entity dpram2 is
generic
(
   addr_width_g : integer := 8;
   data_width_g : integer := 8;
   init_file_g  : string  := " "
);
port
(
   clk_a_i  : in  std_logic;
   we_i     : in  std_logic;
   addr_a_i : in  std_logic_vector(addr_width_g-1 downto 0);
   data_a_i : in  std_logic_vector(data_width_g-1 downto 0);
   data_a_o : out std_logic_vector(data_width_g-1 downto 0);
   --
   clk_b_i  : in  std_logic;
   addr_b_i : in  std_logic_vector(addr_width_g-1 downto 0);
   data_b_o : out std_logic_vector(data_width_g-1 downto 0)
);
end entity;

architecture rtl of dpram2 is
begin

   ram : entity work.dpram
   generic map
   (
      addr_width_a  => addr_width_g,
      data_width_a  => data_width_g,
      addr_width_b  => addr_width_g,
      data_width_b  => data_width_g,
      mem_init_file => init_file_g
   )
   port map
   (
      clock0    => clk_a_i,
      clock1    => clk_b_i,

      address_a => addr_a_i,
      data_a    => data_a_i,
      wren_a    => we_i,
      q_a       => data_a_o,

      address_b => addr_b_i,
      q_b       => data_b_o
   );

end rtl;

------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

library altera_mf;
use altera_mf.altera_mf_components.all;

-- dual port block RAM with a clock per port
entity dpram is
   generic
   (
      addr_width_a  : integer := 8;
      data_width_a  : integer := 8;
      addr_width_b  : integer := 8;
      data_width_b  : integer := 8;
      mem_init_file : string := " "
   );
   port
   (
      clock0    : in  std_logic;
      clock1    : in  std_logic;

      address_a : in  std_logic_vector(addr_width_a-1 downto 0);
      data_a    : in  std_logic_vector(data_width_a-1 downto 0) := (others => '0');
      enable_a  : in  std_logic := '1';
      wren_a    : in  std_logic := '0';
      q_a       : out std_logic_vector(data_width_a-1 downto 0);
      cs_a      : in  std_logic := '1';

      address_b : in  std_logic_vector(addr_width_b-1 downto 0) := (others => '0');
      data_b    : in  std_logic_vector(data_width_b-1 downto 0) := (others => '0');
      enable_b  : in  std_logic := '1';
      wren_b    : in  std_logic := '0';
      q_b       : out std_logic_vector(data_width_b-1 downto 0);
      cs_b      : in  std_logic := '1'
   );
end entity;

architecture syn of dpram is

   signal q0 : std_logic_vector(data_width_a-1 downto 0);
   signal q1 : std_logic_vector(data_width_b-1 downto 0);

begin

   q_a <= q0 when cs_a = '1' else (others => '1');
   q_b <= q1 when cs_b = '1' else (others => '1');

   altsyncram_component : altsyncram
   generic map
   (
      address_reg_b => "CLOCK1",
      clock_enable_input_a => "NORMAL",
      clock_enable_input_b => "NORMAL",
      clock_enable_output_a => "BYPASS",
      clock_enable_output_b => "BYPASS",
      indata_reg_b => "CLOCK1",
      intended_device_family => "Cyclone 10 LP",
      lpm_type => "altsyncram",
      numwords_a => 2**addr_width_a,
      numwords_b => 2**addr_width_b,
      operation_mode => "BIDIR_DUAL_PORT",
      outdata_aclr_a => "NONE",
      outdata_aclr_b => "NONE",
      outdata_reg_a => "UNREGISTERED",
      outdata_reg_b => "UNREGISTERED",
      power_up_uninitialized => "FALSE",
      read_during_write_mode_port_a => "NEW_DATA_NO_NBE_READ",
      read_during_write_mode_port_b => "NEW_DATA_NO_NBE_READ",
      init_file => mem_init_file,
      widthad_a => addr_width_a,
      widthad_b => addr_width_b,
      width_a => data_width_a,
      width_b => data_width_b,
      width_byteena_a => 1,
      width_byteena_b => 1,
      wrcontrol_wraddress_reg_b => "CLOCK1"
   )
   port map
   (
      address_a => address_a,
      address_b => address_b,
      clock0 => clock0,
      clock1 => clock1,
      clocken0 => enable_a,
      clocken1 => enable_b,
      data_a => data_a,
      data_b => data_b,
      wren_a => wren_a and cs_a,
      wren_b => wren_b and cs_b,
      q_a => q0,
      q_b => q1
   );

end syn;
