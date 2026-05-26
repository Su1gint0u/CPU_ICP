#!/bin/bash
# Unit simulations for UART RX and uart_bridge.
set -e

VIVADO="/media/alice/workplace/tools/xilinx/2025.2/Vivado/bin"
RTL_DIR="/media/alice/workplace/CPU_ICP/RTL"
SIM_ROOT="/tmp/cpu_icp_unit_sims"

rm -rf "$SIM_ROOT"
mkdir -p "$SIM_ROOT/cpu_alu" "$SIM_ROOT/uart_rx" "$SIM_ROOT/uart_bridge"
mkdir -p "$SIM_ROOT/fpu_wrapper"

echo "===[cpu_alu] compile/elab/run ==="
cd "$SIM_ROOT/cpu_alu"
"$VIVADO"/xvlog -sv \
    "$RTL_DIR/cpu/cpu_alu.sv" \
    "$RTL_DIR/TB/tb_cpu_alu.sv"
"$VIVADO"/xelab -debug typical -timescale 1ns/1ps -L xil_defaultlib tb_cpu_alu
"$VIVADO"/xsim tb_cpu_alu --runall

echo "===[uart_rx] compile/elab/run ==="
cd "$SIM_ROOT/uart_rx"
"$VIVADO"/xvlog -sv \
    "$RTL_DIR/cpu/uart_rx.sv" \
    "$RTL_DIR/TB/tb_uart_rx.sv"
"$VIVADO"/xelab -debug typical -timescale 1ns/1ps -L xil_defaultlib tb_uart_rx
"$VIVADO"/xsim tb_uart_rx --runall

echo "===[uart_bridge] compile/elab/run ==="
cd "$SIM_ROOT/uart_bridge"
"$VIVADO"/xvlog -sv \
    "$RTL_DIR/cpu/uart_bridge.sv" \
    "$RTL_DIR/TB/tb_uart_bridge.sv"
"$VIVADO"/xelab -debug typical -timescale 1ns/1ps -L xil_defaultlib tb_uart_bridge
"$VIVADO"/xsim tb_uart_bridge --runall

echo "===[fpu_wrapper] compile/elab/run ==="
cd "$SIM_ROOT/fpu_wrapper"
"$VIVADO"/xvlog -sv \
    "$RTL_DIR/cpu/fpu_wrapper.sv" \
    "$RTL_DIR/TB/tb_fpu_wrapper.sv"
"$VIVADO"/xelab -debug typical -timescale 1ns/1ps -L xil_defaultlib tb_fpu_wrapper
"$VIVADO"/xsim tb_fpu_wrapper --runall

echo "=== Unit simulations DONE ==="
