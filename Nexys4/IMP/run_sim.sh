#!/bin/bash
# Vivado xvlog syntax check + xelab + xsim simulation
set -e

VIVADO="/media/alice/workplace/tools/xilinx/2025.2/Vivado/bin"
RTL_DIR="/media/alice/workplace/CPU_ICP/RTL"
SIM_DIR="/tmp/cpu_icp_sim"
HF_DIR="$RTL_DIR/berkeley-hardfloat/extract"
HF_RISCV_DIR="$HF_DIR/RISCV"

rm -rf "$SIM_DIR"
mkdir -p "$SIM_DIR"
cd "$SIM_DIR"

# ---- Collect all source files in dependency order ----
SRC=(
    # Berkeley HardFloat
    "$HF_DIR/HardFloat_primitives.v"
    "$HF_DIR/HardFloat_rawFN.v"
    "$HF_DIR/isSigNaNRecFN.v"
    "$HF_DIR/fNToRecFN.v"
    "$HF_DIR/recFNToFN.v"
    "$HF_DIR/recFNToIN.v"
    "$HF_DIR/iNToRecFN.v"
    "$HF_DIR/addRecFN.v"
    "$HF_DIR/mulRecFN.v"
    "$HF_DIR/mulAddRecFN.v"
    "$HF_DIR/divSqrtRecFN_small.v"
    "$HF_RISCV_DIR/HardFloat_specialize.v"
    # Packages first
    "$RTL_DIR/cpu/cpu_pkg.sv"
    # CPU core (alphabetical-ish, cpu_core.sv last of this group)
    "$RTL_DIR/cpu/cpu_alu.sv"
    "$RTL_DIR/cpu/cpu_bru.sv"
    "$RTL_DIR/cpu/cpu_cdb.sv"
    "$RTL_DIR/cpu/cpu_csr_file.sv"
    "$RTL_DIR/cpu/cpu_decode.sv"
    "$RTL_DIR/cpu/cpu_ex_stage.sv"
    "$RTL_DIR/cpu/cpu_f_regfile.sv"
    "$RTL_DIR/cpu/cpu_id_stage.sv"
    "$RTL_DIR/cpu/cpu_if_stage.sv"
    "$RTL_DIR/cpu/cpu_instr_buffer.sv"
    "$RTL_DIR/cpu/cpu_issue_queue.sv"
    "$RTL_DIR/cpu/cpu_lsq.sv"
    "$RTL_DIR/cpu/cpu_mem_stage.sv"
    "$RTL_DIR/cpu/cpu_muldiv.sv"
    "$RTL_DIR/cpu/cpu_prf.sv"
    "$RTL_DIR/cpu/cpu_rat.sv"
    "$RTL_DIR/cpu/cpu_regfile.sv"
    "$RTL_DIR/cpu/cpu_rob.sv"
    "$RTL_DIR/cpu/cpu_wb_stage.sv"
    "$RTL_DIR/cpu/cpu_core.sv"
    "$RTL_DIR/cpu/cpu_core_mem_top.sv"
    # FPU wrapper uses Berkeley HardFloat sources above.
    "$RTL_DIR/cpu/fpu_wrapper.sv"
    # rst_sync.sv not used by fpga_top
    # "$RTL_DIR/cpu/rst_sync.sv"
    # BP
    "$RTL_DIR/cpu/bp/bp_direction_2bit.sv"
    "$RTL_DIR/cpu/bp/bp_btb_direct.sv"
    "$RTL_DIR/cpu/bp/bp_ras.sv"
    "$RTL_DIR/cpu/bp/bp_gshare.sv"
    "$RTL_DIR/cpu/bp/bp_tage.sv"
    "$RTL_DIR/cpu/bp/bp_predictor_simple.sv"
    # New UART / memory / top
    "$RTL_DIR/cpu/uart_rx.sv"
    "$RTL_DIR/cpu/uart_tx.sv"
    "$RTL_DIR/cpu/uart_bridge.sv"
    "$RTL_DIR/cpu/l1_mem_wrapper.sv"
    "$RTL_DIR/cpu/fpga_top.sv"
    # Testbench
    "$RTL_DIR/TB/tb_fpga_top.sv"
    "$RTL_DIR/TB/tb_fpga_top_test_add.sv"
    "$RTL_DIR/TB/tb_fpga_top_g3_test2.sv"
    "$RTL_DIR/TB/tb_fpga_top_g3_test5.sv"
    "$RTL_DIR/TB/tb_fpga_top_g5_test1.sv"
    "$RTL_DIR/TB/tb_fpga_top_g5_test2.sv"
)

echo "===[1/8] xvlog -- Compiling ${#SRC[@]} files ==="
"$VIVADO"/xvlog -sv -i "$RTL_DIR/cpu" -i "$RTL_DIR/cpu/bp" -i "$HF_RISCV_DIR" -i "$HF_DIR" "${SRC[@]}" 2>&1

echo ""
echo "===[2/8] xelab -- Elaborating tb_fpga_top ==="
"$VIVADO"/xelab -debug typical -timescale 1ns/1ps -L xil_defaultlib tb_fpga_top 2>&1

echo ""
echo "===[3/8] xsim -- Running tb_fpga_top ==="
"$VIVADO"/xsim tb_fpga_top "$@" --runall 2>&1

echo ""
echo "===[4/8] xelab/xsim -- Running tb_fpga_top_test_add ==="
"$VIVADO"/xelab -debug typical -timescale 1ns/1ps -L xil_defaultlib tb_fpga_top_test_add 2>&1
"$VIVADO"/xsim tb_fpga_top_test_add "$@" --runall 2>&1

echo ""
echo "===[5/8] xelab/xsim -- Running tb_fpga_top_g3_test2 ==="
"$VIVADO"/xelab -debug typical -timescale 1ns/1ps -L xil_defaultlib tb_fpga_top_g3_test2 2>&1
"$VIVADO"/xsim tb_fpga_top_g3_test2 "$@" --runall 2>&1

echo ""
echo "===[6/8] xelab/xsim -- Running tb_fpga_top_g3_test5 ==="
"$VIVADO"/xelab -debug typical -timescale 1ns/1ps -L xil_defaultlib tb_fpga_top_g3_test5 2>&1
"$VIVADO"/xsim tb_fpga_top_g3_test5 "$@" --runall 2>&1

echo ""
echo "===[7/8] xelab/xsim -- Running tb_fpga_top_g5_test1 ==="
"$VIVADO"/xelab -debug typical -timescale 1ns/1ps -L xil_defaultlib tb_fpga_top_g5_test1 2>&1
"$VIVADO"/xsim tb_fpga_top_g5_test1 "$@" --runall 2>&1

echo ""
echo "===[8/8] xelab/xsim -- Running tb_fpga_top_g5_test2 ==="
"$VIVADO"/xelab -debug typical -timescale 1ns/1ps -L xil_defaultlib tb_fpga_top_g5_test2 2>&1
"$VIVADO"/xsim tb_fpga_top_g5_test2 "$@" --runall 2>&1

echo ""
echo "=== Simulation DONE ==="
