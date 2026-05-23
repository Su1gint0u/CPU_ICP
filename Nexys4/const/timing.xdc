# Nexys4 Timing Constraints
#
# sys_clk_100m is the board oscillator. fpga_top generates the internal
# 50 MHz system clock through u_sysclk/u_clk50_buf.
create_generated_clock -quiet -name sys_clk -source [get_ports sys_clk_100m] -divide_by 2 [get_pins -quiet u_sysclk/u_clk50_buf/O]

# ---- Input delay for UART RXD (async to sys_clk) ----
# UART is a slow interface; false-path the async crossing handled by synchronizers.
set_false_path -from [get_ports uart_rxd]

# ---- Reset input ----
set_false_path -from [get_ports sys_rst_n]

# ---- Asynchronous board outputs ----
# LEDs and USB-UART TXD are not source-synchronous interfaces with an external
# capture clock in this design.
set_false_path -to [get_ports uart_txd]
set_false_path -to [get_ports {led_status[*]}]

# ---- Multicycle for BRAM paths ----
# BRAM read paths are registered (1-cycle read); default constraints are fine.

# ---- Multicycle for the stalled HardFloat pipe ----
# fpu_wrapper latches operands at ST_PIPE entry and does not sample the
# combinational add/mul/madd/conversion result until three sys_clk edges later.
# The CPU holds the EX instruction while stall_fp is asserted.
set_multicycle_path -setup 3 \
    -from [get_pins -quiet -hier -filter {NAME =~ *u_cpu/u_ex/u_fpu/pipe_*_q_reg*/C}] \
    -to [get_pins -quiet -hier -filter {NAME =~ *u_cpu/u_ex/u_fpu/res_q_reg*/D || NAME =~ *u_cpu/u_ex/u_fpu/ff_q_reg*/D}]
set_multicycle_path -hold 2 \
    -from [get_pins -quiet -hier -filter {NAME =~ *u_cpu/u_ex/u_fpu/pipe_*_q_reg*/C}] \
    -to [get_pins -quiet -hier -filter {NAME =~ *u_cpu/u_ex/u_fpu/res_q_reg*/D || NAME =~ *u_cpu/u_ex/u_fpu/ff_q_reg*/D}]
