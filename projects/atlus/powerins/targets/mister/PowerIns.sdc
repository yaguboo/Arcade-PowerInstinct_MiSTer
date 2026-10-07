derive_pll_clocks
derive_clock_uncertainty

# SDRAM pins are left unconstrained; the interface is set by the 180 degree
# phase of SDRAM_CLK (outclk_1, -10417 ps at 48 MHz), MiSTer practice
# (NES.sdc / Genesis.sdc), as Stadium Hero and Super Slams do.

# Framework video paths are pipelined and do not settle in one core clock.
set_multicycle_path -to {*Hq2x*} -setup 4
set_multicycle_path -to {*Hq2x*} -hold 3

set_multicycle_path -from [get_clocks {*|pll|pll_inst|altera_pll_i|general[0].*|divclk}] -to {ascal|*} -setup 4
set_multicycle_path -from [get_clocks {*|pll|pll_inst|altera_pll_i|general[0].*|divclk}] -to {ascal|*} -hold 3

# clk_aux -> clk_sys is the pll_alive two-flop synchroniser.  Not a timed path.
set_false_path -from [get_clocks {*|pll|pll_inst|altera_pll_i|general[2].*|divclk}] -to [get_clocks {*|pll|pll_inst|altera_pll_i|general[0].*|divclk}]
