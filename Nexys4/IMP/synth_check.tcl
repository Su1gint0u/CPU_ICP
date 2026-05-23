# Synthesis-only check for fpga_top. Keeps BRAM/timing iteration fast.

set project_dir [file dirname [info script]]
set const_dir   [file normalize "$project_dir/../const"]
set rtl_dir     [file normalize "$project_dir/../../RTL/cpu"]
set hf_dir      [file normalize "$project_dir/../../RTL/berkeley-hardfloat/extract"]
set hf_riscv_dir [file join $hf_dir RISCV]
set part_name   "xc7a100tcsg324-1"
set top_module  "fpga_top"

set_param general.maxThreads 2
file mkdir $project_dir/imp

set hardfloat_files [list]
lappend hardfloat_files $hf_dir/HardFloat_primitives.v
lappend hardfloat_files $hf_dir/HardFloat_rawFN.v
lappend hardfloat_files $hf_dir/isSigNaNRecFN.v
lappend hardfloat_files $hf_dir/fNToRecFN.v
lappend hardfloat_files $hf_dir/recFNToFN.v
lappend hardfloat_files $hf_dir/recFNToIN.v
lappend hardfloat_files $hf_dir/iNToRecFN.v
lappend hardfloat_files $hf_dir/addRecFN.v
lappend hardfloat_files $hf_dir/mulRecFN.v
lappend hardfloat_files $hf_dir/mulAddRecFN.v
lappend hardfloat_files $hf_dir/divSqrtRecFN_small.v
lappend hardfloat_files $hf_riscv_dir/HardFloat_specialize.v

read_verilog -sv -I $hf_riscv_dir -I $hf_dir $hardfloat_files
read_verilog -sv -I $hf_riscv_dir -I $hf_dir $rtl_dir/cpu_pkg.sv
set src_files [list]
lappend src_files $rtl_dir/cpu_alu.sv
lappend src_files $rtl_dir/cpu_bru.sv
lappend src_files $rtl_dir/cpu_cdb.sv
lappend src_files $rtl_dir/cpu_csr_file.sv
lappend src_files $rtl_dir/cpu_decode.sv
lappend src_files $rtl_dir/cpu_ex_stage.sv
lappend src_files $rtl_dir/cpu_f_regfile.sv
lappend src_files $rtl_dir/cpu_id_stage.sv
lappend src_files $rtl_dir/cpu_if_stage.sv
lappend src_files $rtl_dir/cpu_instr_buffer.sv
lappend src_files $rtl_dir/cpu_issue_queue.sv
lappend src_files $rtl_dir/cpu_lsq.sv
lappend src_files $rtl_dir/cpu_mem_stage.sv
lappend src_files $rtl_dir/cpu_muldiv.sv
lappend src_files $rtl_dir/cpu_prf.sv
lappend src_files $rtl_dir/cpu_rat.sv
lappend src_files $rtl_dir/cpu_regfile.sv
lappend src_files $rtl_dir/cpu_rob.sv
lappend src_files $rtl_dir/cpu_wb_stage.sv
lappend src_files $rtl_dir/cpu_core.sv
lappend src_files $rtl_dir/cpu_core_mem_top.sv
lappend src_files $rtl_dir/fpu_wrapper.sv
lappend src_files $rtl_dir/rst_sync.sv
lappend src_files $rtl_dir/l1_mem_wrapper.sv
lappend src_files $rtl_dir/uart_rx.sv
lappend src_files $rtl_dir/uart_tx.sv
lappend src_files $rtl_dir/uart_bridge.sv
lappend src_files $rtl_dir/fpga_top.sv
lappend src_files $rtl_dir/bp/bp_direction_2bit.sv
lappend src_files $rtl_dir/bp/bp_btb_direct.sv
lappend src_files $rtl_dir/bp/bp_ras.sv
lappend src_files $rtl_dir/bp/bp_gshare.sv
lappend src_files $rtl_dir/bp/bp_tage.sv
lappend src_files $rtl_dir/bp/bp_predictor_simple.sv

foreach f $src_files {
    if {[file exists $f]} {
        read_verilog -sv -I $hf_riscv_dir -I $hf_dir $f
    } else {
        puts "SYNTH_CHECK WARNING: file not found: $f"
    }
}

foreach xdc [list "nexys4_io.xdc" "timing.xdc"] {
    set xdc_path [file join $const_dir $xdc]
    if {[file exists $xdc_path]} {
        read_xdc $xdc_path
        puts "SYNTH_CHECK Read constraint: $xdc_path"
    }
}

synth_design -top $top_module -part $part_name -directive RuntimeOptimized
report_utilization -file $project_dir/imp/utilization_synth_check.rpt
write_checkpoint -force $project_dir/imp/synth_check.dcp
puts "SYNTH_CHECK Synthesis finished"
