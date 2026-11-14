-- Serial 32/16 divider (1 bit per clock) replacing the two pipelined
-- lpm_divide cores. Results match LPM_REMAINDERPOSITIVE=TRUE semantics:
-- n = q*d + r with 0 <= r < |d|, for both signed and unsigned operation.
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity SPC7110_SERDIV is
	port(
		clock    : in  std_logic;
		start    : in  std_logic;
		sign     : in  std_logic;
		numer    : in  std_logic_vector(31 downto 0);
		denom    : in  std_logic_vector(15 downto 0);
		quotient : out std_logic_vector(31 downto 0);
		remain   : out std_logic_vector(15 downto 0)
	);
end SPC7110_SERDIV;

architecture rtl of SPC7110_SERDIV is
	signal q_r   : unsigned(31 downto 0) := (others => '0');
	signal rem_r : unsigned(15 downto 0) := (others => '0');
	signal d_r   : unsigned(15 downto 0) := (others => '0');
	signal cnt   : unsigned(5 downto 0) := (others => '0');
	signal sg    : std_logic := '0';
	signal nneg  : std_logic := '0';
	signal dneg  : std_logic := '0';
begin

	process(clock)
		variable n : unsigned(31 downto 0);
		variable t : unsigned(16 downto 0);
	begin
		if rising_edge(clock) then
			if start = '1' then
				if sign = '1' and numer(31) = '1' then
					n := unsigned(not numer) + 1;
				else
					n := unsigned(numer);
				end if;
				if sign = '1' and denom(15) = '1' then
					d_r <= unsigned(not denom) + 1;
				else
					d_r <= unsigned(denom);
				end if;
				q_r   <= n;
				rem_r <= (others => '0');
				cnt   <= to_unsigned(32, 6);
				sg    <= sign;
				nneg  <= sign and numer(31);
				dneg  <= sign and denom(15);
			elsif cnt /= 0 then
				t := rem_r & q_r(31);
				if t >= ('0' & d_r) then
					t := t - ('0' & d_r);
					q_r <= q_r(30 downto 0) & '1';
				else
					q_r <= q_r(30 downto 0) & '0';
				end if;
				rem_r <= t(15 downto 0);
				cnt   <= cnt - 1;
			end if;
		end if;
	end process;

	process(q_r, rem_r, d_r, sg, nneg, dneg)
		variable qa : unsigned(31 downto 0);
	begin
		quotient <= std_logic_vector(q_r);
		remain   <= std_logic_vector(rem_r);
		if sg = '1' then
			if nneg = '0' then
				if dneg = '1' then
					quotient <= std_logic_vector(unsigned(not std_logic_vector(q_r)) + 1);
				end if;
			elsif rem_r = 0 then
				if dneg = '0' then
					quotient <= std_logic_vector(unsigned(not std_logic_vector(q_r)) + 1);
				end if;
			else
				remain <= std_logic_vector(d_r - rem_r);
				qa := q_r + 1;
				if dneg = '1' then
					quotient <= std_logic_vector(qa);
				else
					quotient <= std_logic_vector(unsigned(not std_logic_vector(qa)) + 1);
				end if;
			end if;
		end if;
	end process;

end rtl;
