# Nexys4 IO Constraints
# Target: xc7a100tcsg324-1 (Nexys4 Rev. B)

# ---- 100 MHz System Clock Input (E3) ----
set_property PACKAGE_PIN E3 [get_ports sys_clk_100m]
set_property IOSTANDARD LVCMOS33 [get_ports sys_clk_100m]
create_clock -period 10.000 -name sys_clk_100m_in [get_ports sys_clk_100m]

# ---- UART (USB-UART connected to on-board FTDI) ----
# Digilent Nexys4 Rev. B Master XDC:
#   C4 = UART_TXD_IN  (FTDI TX -> FPGA RX)
#   D4 = UART_RXD_OUT (FPGA TX -> FTDI RX)
set_property PACKAGE_PIN D4 [get_ports uart_txd]
set_property IOSTANDARD LVCMOS33 [get_ports uart_txd]

set_property PACKAGE_PIN C4 [get_ports uart_rxd]
set_property IOSTANDARD LVCMOS33 [get_ports uart_rxd]

# ---- Active-low Reset (use CPU_RESET button J15) ----
set_property PACKAGE_PIN C12 [get_ports sys_rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports sys_rst_n]

# ---- Status LEDs (LD0-LD15), Nexys4 Rev. B ----
set_property PACKAGE_PIN T8 [get_ports {led_status[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led_status[0]}]
set_property PACKAGE_PIN V9 [get_ports {led_status[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led_status[1]}]
set_property PACKAGE_PIN R8 [get_ports {led_status[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led_status[2]}]
set_property PACKAGE_PIN T6 [get_ports {led_status[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led_status[3]}]
set_property PACKAGE_PIN T5 [get_ports {led_status[4]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led_status[4]}]
set_property PACKAGE_PIN T4 [get_ports {led_status[5]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led_status[5]}]
set_property PACKAGE_PIN U7 [get_ports {led_status[6]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led_status[6]}]
set_property PACKAGE_PIN U6 [get_ports {led_status[7]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led_status[7]}]
set_property PACKAGE_PIN V4 [get_ports {led_status[8]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led_status[8]}]
set_property PACKAGE_PIN U3 [get_ports {led_status[9]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led_status[9]}]
set_property PACKAGE_PIN V1 [get_ports {led_status[10]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led_status[10]}]
set_property PACKAGE_PIN R1 [get_ports {led_status[11]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led_status[11]}]
set_property PACKAGE_PIN P5 [get_ports {led_status[12]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led_status[12]}]
set_property PACKAGE_PIN U1 [get_ports {led_status[13]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led_status[13]}]
set_property PACKAGE_PIN R2 [get_ports {led_status[14]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led_status[14]}]
set_property PACKAGE_PIN P2 [get_ports {led_status[15]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led_status[15]}]

# ---- Configuration ----
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
