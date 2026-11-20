-- Made by LNext/10cl025/tools/mk_c10_files.py from the file of the same entity in ZXNEXT/
-- (the copy there is unchanged). Do not edit: change the script.
-- generated with romgen v3.0 by MikeJ
-- (machine generated file)

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library altera_mf;
  use altera_mf.altera_mf_components.all;

entity bootrom is
  port (
    CLK         : in    std_logic;
    ADDR        : in    std_logic_vector(12 downto 0);
    DATA        : out   std_logic_vector(7 downto 0)
    );
end;

architecture RTL of bootrom is

  signal a_q    : std_logic_vector(7 downto 0);
  signal b_q    : std_logic_vector(7 downto 0);
  signal c_q    : std_logic_vector(7 downto 0);
  signal hi_q   : std_logic_vector(7 downto 0);
  signal addr_q : std_logic_vector(12 downto 0);

begin

  -- the first 7 KB: block ROMs of 4, 2 and 1 KB (seven block RAMs; one ROM of 7 KB would take eight)
  rom_a : altsyncram
  generic map (
    operation_mode => "ROM",
    width_a => 8,
    widthad_a => 12,
    numwords_a => 4096,
    init_file => "rtl/next_bootrom_a.mif",
    outdata_reg_a => "UNREGISTERED",
    intended_device_family => "Cyclone 10 LP",
    lpm_type => "altsyncram"
  )
  port map (
    clock0 => CLK,
    address_a => ADDR(11 downto 0),
    q_a => a_q
  );

  rom_b : altsyncram
  generic map (
    operation_mode => "ROM",
    width_a => 8,
    widthad_a => 11,
    numwords_a => 2048,
    init_file => "rtl/next_bootrom_b.mif",
    outdata_reg_a => "UNREGISTERED",
    intended_device_family => "Cyclone 10 LP",
    lpm_type => "altsyncram"
  )
  port map (
    clock0 => CLK,
    address_a => ADDR(10 downto 0),
    q_a => b_q
  );

  rom_c : altsyncram
  generic map (
    operation_mode => "ROM",
    width_a => 8,
    widthad_a => 10,
    numwords_a => 1024,
    init_file => "rtl/next_bootrom_c.mif",
    outdata_reg_a => "UNREGISTERED",
    intended_device_family => "Cyclone 10 LP",
    lpm_type => "altsyncram"
  )
  port map (
    clock0 => CLK,
    address_a => ADDR(9 downto 0),
    q_a => c_q
  );

  process (CLK)
  begin
    if rising_edge(CLK) then
      addr_q <= ADDR;
    end if;
  end process;

  -- the last kilobyte: logic
  process (addr_q)
  begin
    case to_integer(unsigned(addr_q)) is
      when 7168 => hi_q <= x"E1";
      when 7169 => hi_q <= x"E5";
      when 7170 => hi_q <= x"71";
      when 7171 => hi_q <= x"23";
      when 7172 => hi_q <= x"70";
      when 7173 => hi_q <= x"C1";
      when 7174 => hi_q <= x"E1";
      when 7175 => hi_q <= x"E5";
      when 7176 => hi_q <= x"C5";
      when 7177 => hi_q <= x"4E";
      when 7178 => hi_q <= x"6B";
      when 7179 => hi_q <= x"62";
      when 7180 => hi_q <= x"23";
      when 7181 => hi_q <= x"66";
      when 7182 => hi_q <= x"D5";
      when 7183 => hi_q <= x"59";
      when 7184 => hi_q <= x"2E";
      when 7185 => hi_q <= x"00";
      when 7186 => hi_q <= x"55";
      when 7187 => hi_q <= x"06";
      when 7188 => hi_q <= x"08";
      when 7189 => hi_q <= x"29";
      when 7190 => hi_q <= x"30";
      when 7191 => hi_q <= x"01";
      when 7192 => hi_q <= x"19";
      when 7193 => hi_q <= x"10";
      when 7194 => hi_q <= x"FA";
      when 7195 => hi_q <= x"D1";
      when 7196 => hi_q <= x"4D";
      when 7197 => hi_q <= x"44";
      when 7198 => hi_q <= x"DD";
      when 7199 => hi_q <= x"6E";
      when 7200 => hi_q <= x"FC";
      when 7201 => hi_q <= x"DD";
      when 7202 => hi_q <= x"66";
      when 7203 => hi_q <= x"FD";
      when 7204 => hi_q <= x"23";
      when 7205 => hi_q <= x"E5";
      when 7206 => hi_q <= x"FD";
      when 7207 => hi_q <= x"E1";
      when 7208 => hi_q <= x"6B";
      when 7209 => hi_q <= x"62";
      when 7210 => hi_q <= x"7E";
      when 7211 => hi_q <= x"DD";
      when 7212 => hi_q <= x"77";
      when 7213 => hi_q <= x"FA";
      when 7214 => hi_q <= x"DD";
      when 7215 => hi_q <= x"6E";
      when 7216 => hi_q <= x"FC";
      when 7217 => hi_q <= x"DD";
      when 7218 => hi_q <= x"66";
      when 7219 => hi_q <= x"FD";
      when 7220 => hi_q <= x"23";
      when 7221 => hi_q <= x"6E";
      when 7222 => hi_q <= x"D5";
      when 7223 => hi_q <= x"C5";
      when 7224 => hi_q <= x"5D";
      when 7225 => hi_q <= x"DD";
      when 7226 => hi_q <= x"66";
      when 7227 => hi_q <= x"FA";
      when 7228 => hi_q <= x"2E";
      when 7229 => hi_q <= x"00";
      when 7230 => hi_q <= x"55";
      when 7231 => hi_q <= x"06";
      when 7232 => hi_q <= x"08";
      when 7233 => hi_q <= x"29";
      when 7234 => hi_q <= x"30";
      when 7235 => hi_q <= x"01";
      when 7236 => hi_q <= x"19";
      when 7237 => hi_q <= x"10";
      when 7238 => hi_q <= x"FA";
      when 7239 => hi_q <= x"C1";
      when 7240 => hi_q <= x"D1";
      when 7241 => hi_q <= x"FD";
      when 7242 => hi_q <= x"75";
      when 7243 => hi_q <= x"00";
      when 7244 => hi_q <= x"FD";
      when 7245 => hi_q <= x"74";
      when 7246 => hi_q <= x"01";
      when 7247 => hi_q <= x"DD";
      when 7248 => hi_q <= x"6E";
      when 7249 => hi_q <= x"FC";
      when 7250 => hi_q <= x"DD";
      when 7251 => hi_q <= x"66";
      when 7252 => hi_q <= x"FD";
      when 7253 => hi_q <= x"23";
      when 7254 => hi_q <= x"23";
      when 7255 => hi_q <= x"23";
      when 7256 => hi_q <= x"E3";
      when 7257 => hi_q <= x"DD";
      when 7258 => hi_q <= x"6E";
      when 7259 => hi_q <= x"FC";
      when 7260 => hi_q <= x"DD";
      when 7261 => hi_q <= x"66";
      when 7262 => hi_q <= x"FD";
      when 7263 => hi_q <= x"23";
      when 7264 => hi_q <= x"E5";
      when 7265 => hi_q <= x"FD";
      when 7266 => hi_q <= x"E1";
      when 7267 => hi_q <= x"DD";
      when 7268 => hi_q <= x"6E";
      when 7269 => hi_q <= x"FC";
      when 7270 => hi_q <= x"DD";
      when 7271 => hi_q <= x"66";
      when 7272 => hi_q <= x"FD";
      when 7273 => hi_q <= x"23";
      when 7274 => hi_q <= x"7E";
      when 7275 => hi_q <= x"23";
      when 7276 => hi_q <= x"66";
      when 7277 => hi_q <= x"6F";
      when 7278 => hi_q <= x"09";
      when 7279 => hi_q <= x"FD";
      when 7280 => hi_q <= x"75";
      when 7281 => hi_q <= x"00";
      when 7282 => hi_q <= x"FD";
      when 7283 => hi_q <= x"74";
      when 7284 => hi_q <= x"01";
      when 7285 => hi_q <= x"BF";
      when 7286 => hi_q <= x"ED";
      when 7287 => hi_q <= x"42";
      when 7288 => hi_q <= x"3E";
      when 7289 => hi_q <= x"00";
      when 7290 => hi_q <= x"17";
      when 7291 => hi_q <= x"E1";
      when 7292 => hi_q <= x"E5";
      when 7293 => hi_q <= x"77";
      when 7294 => hi_q <= x"4B";
      when 7295 => hi_q <= x"42";
      when 7296 => hi_q <= x"1A";
      when 7297 => hi_q <= x"5F";
      when 7298 => hi_q <= x"DD";
      when 7299 => hi_q <= x"6E";
      when 7300 => hi_q <= x"FC";
      when 7301 => hi_q <= x"DD";
      when 7302 => hi_q <= x"66";
      when 7303 => hi_q <= x"FD";
      when 7304 => hi_q <= x"66";
      when 7305 => hi_q <= x"C5";
      when 7306 => hi_q <= x"2E";
      when 7307 => hi_q <= x"00";
      when 7308 => hi_q <= x"55";
      when 7309 => hi_q <= x"06";
      when 7310 => hi_q <= x"08";
      when 7311 => hi_q <= x"29";
      when 7312 => hi_q <= x"30";
      when 7313 => hi_q <= x"01";
      when 7314 => hi_q <= x"19";
      when 7315 => hi_q <= x"10";
      when 7316 => hi_q <= x"FA";
      when 7317 => hi_q <= x"C1";
      when 7318 => hi_q <= x"EB";
      when 7319 => hi_q <= x"7B";
      when 7320 => hi_q <= x"02";
      when 7321 => hi_q <= x"03";
      when 7322 => hi_q <= x"7A";
      when 7323 => hi_q <= x"02";
      when 7324 => hi_q <= x"D1";
      when 7325 => hi_q <= x"C1";
      when 7326 => hi_q <= x"C5";
      when 7327 => hi_q <= x"D5";
      when 7328 => hi_q <= x"AF";
      when 7329 => hi_q <= x"02";
      when 7330 => hi_q <= x"DD";
      when 7331 => hi_q <= x"7E";
      when 7332 => hi_q <= x"04";
      when 7333 => hi_q <= x"DD";
      when 7334 => hi_q <= x"86";
      when 7335 => hi_q <= x"08";
      when 7336 => hi_q <= x"6F";
      when 7337 => hi_q <= x"DD";
      when 7338 => hi_q <= x"7E";
      when 7339 => hi_q <= x"05";
      when 7340 => hi_q <= x"DD";
      when 7341 => hi_q <= x"8E";
      when 7342 => hi_q <= x"09";
      when 7343 => hi_q <= x"67";
      when 7344 => hi_q <= x"DD";
      when 7345 => hi_q <= x"7E";
      when 7346 => hi_q <= x"06";
      when 7347 => hi_q <= x"DD";
      when 7348 => hi_q <= x"8E";
      when 7349 => hi_q <= x"0A";
      when 7350 => hi_q <= x"5F";
      when 7351 => hi_q <= x"DD";
      when 7352 => hi_q <= x"7E";
      when 7353 => hi_q <= x"07";
      when 7354 => hi_q <= x"DD";
      when 7355 => hi_q <= x"8E";
      when 7356 => hi_q <= x"0B";
      when 7357 => hi_q <= x"57";
      when 7358 => hi_q <= x"DD";
      when 7359 => hi_q <= x"F9";
      when 7360 => hi_q <= x"DD";
      when 7361 => hi_q <= x"E1";
      when 7362 => hi_q <= x"C9";
      when 7363 => hi_q <= x"47";
      when 7364 => hi_q <= x"04";
      when 7365 => hi_q <= x"53";
      when 7366 => hi_q <= x"04";
      when 7367 => hi_q <= x"01";
      when 7368 => hi_q <= x"04";
      when 7369 => hi_q <= x"00";
      when 7370 => hi_q <= x"78";
      when 7371 => hi_q <= x"B1";
      when 7372 => hi_q <= x"28";
      when 7373 => hi_q <= x"08";
      when 7374 => hi_q <= x"11";
      when 7375 => hi_q <= x"39";
      when 7376 => hi_q <= x"FC";
      when 7377 => hi_q <= x"21";
      when 7378 => hi_q <= x"C3";
      when 7379 => hi_q <= x"1C";
      when 7380 => hi_q <= x"ED";
      when 7381 => hi_q <= x"B0";
      when 7382 => hi_q <= x"C9";
      when others => hi_q <= x"FF";
    end case;
  end process;

  -- 0000-0FFF, 1000-17FF, 1800-1BFF, 1C00-1FFF
  DATA <= a_q when addr_q(12) = '0' else
          b_q when addr_q(11) = '0' else
          c_q when addr_q(10) = '0' else
          hi_q;

end RTL;
