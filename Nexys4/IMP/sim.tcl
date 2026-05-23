# Vivado simulation Tcl script
# Source all RTL files, compile, elaborate, and simulate

set script_dir [file dirname [info script]]
set rtl_dir   [file normalize "$script_dir/../../RTL"]
set hf_dir    [file normalize "$rtl_dir/berkeley-hardfloat/extract"]
set hf_riscv_dir [file join $hf_dir RISCV]
set proj_name "sim_fpga_top"

# Clean up previous
if {[file exists $proj_name]} {
    file delete -force $proj_name
}
create_project $proj_name $proj_name -part xc7a100tcsg324-1 -force

# Add source files
set sv_files [list]
# Berkeley HardFloat
lappend sv_files $hf_dir/HardFloat_primitives.v
lappend sv_files $hf_dir/HardFloat_rawFN.v
lappend sv_files $hf_dir/isSigNaNRecFN.v
lappend sv_files $hf_dir/fNToRecFN.v
lappend sv_files $hf_dir/recFNToFN.v
lappend sv_files $hf_dir/recFNToIN.v
lappend sv_files $hf_dir/iNToRecFN.v
lappend sv_files $hf_dir/addRecFN.v
lappend sv_files $hf_dir/mulRecFN.v
lappend sv_files $hf_dir/mulAddRecFN.v
lappend sv_files $hf_dir/divSqrtRecFN_small.v
lappend sv_files $hf_riscv_dir/HardFloat_specialize.v
# CPU core files
lappend sv_files {*}[glob -nocomplain $rtl_dir/cpu/cpu_pkg.sv]
lappend sv_files {*}[glob -nocomplain $rtl_dir/cpu/cpu_alu.sv]
lappend sv_files {*}[glob -nocomplain $rtl_dir/cpu/cpu_bru.sv]
lappend sv_files {*}[glob -nocomplain $rtl_dir/cpu/cpu_cdb.sv]
lappend sv_files {*}[glob -nocomplain $rtl_dir/cpu/cpu_csr_file.sv]
lappend sv_files {*}[glob -nocomplain $rtl_dir/cpu/cpu_decode.sv]
lappend sv_files {*}[glob -nocomplain $rtl_dir/cpu/cpu_ex_stage.sv]
lappend sv_files {*}[glob -nocomplain $rtl_dir/cpu/cpu_f_regfile.sv]
lappend sv_files {*}[glob -nocomplain $rtl_dir/cpu/cpu_id_stage.sv]
lappend sv_files {*}[glob -nocomplain $rtl_dir/cpu/cpu_if_stage.sv]
lappend sv_files {*}[glob -nocomplain $rtl_dir/cpu/cpu_instr_buffer.sv]
lappend sv_files {*}[glob -nocomplain $rtl_dir/cpu/cpu_issue_queue.sv]
lappend sv_files {*}[glob -nocomplain $rtl_dir/cpu/cpu_lsq.sv]
lappend sv_files {*}[glob -nocomplain $rtl_dir/cpu/cpu_mem_stage.sv]
lappend sv_files {*}[glob -nocomplain $rtl_dir/cpu/cpu_muldiv.sv]
lappend sv_files {*}[glob -nocomplain $rtl_dir/cpu/cpu_prf.sv]
lappend sv_files {*}[glob -nocomplain $rtl_dir/cpu/cpu_rat.sv]
lappend sv_files {*}[glob -nocomplain $rtl_dir/cpu/cpu_regfile.sv]
lappend sv_files {*}[glob -nocomplain $rtl_dir/cpu/cpu_rob.sv]
lappend sv_files {*}[glob -nocomplain $rtl_dir/cpu/cpu_wb_stage.sv]
lappend sv_files {*}[glob -nocomplain $rtl_dir/cpu/cpu_core.sv]
lappend sv_files {*}[glob -nocomplain $rtl_dir/cpu/cpu_core_mem_top.sv]
lappend sv_files {*}[glob -nocomplain $rtl_dir/cpu/fpu_wrapper.sv]
lappend sv_files {*}[glob -nocomplain $rtl_dir/cpu/rst_sync.sv]

# BP files
lappend sv_files {*}[glob -nocomplain $rtl_dir/cpu/bp/*.sv]

# Our new files
lappend sv_files {*}[glob -nocomplain $rtl_dir/cpu/uart_rx.sv]
lappend sv_files {*}[glob -nocomplain $rtl_dir/cpu/uart_tx.sv]
lappend sv_files {*}[glob -nocomplain $rtl_dir/cpu/uart_bridge.sv]
lappend sv_files {*}[glob -nocomplain $rtl_dir/cpu/l1_mem_wrapper.sv]
lappend sv_files {*}[glob -nocomplain $rtl_dir/cpu/fpga_top.sv]

# Testbench
lappend sv_files {*}[glob -nocomplain $rtl_dir/TB/tb_fpga_top.sv]

# Add all sources
foreach f $sv_files {
    puts "Adding source: $f"
}

add_files -fileset sim_1 $sv_files

# Set top module
set_property top tb_fpga_top [get_filesets sim_1]

# Update compile order: package first
set_property top_lib xil_defaultlib [get_filesets sim_1]

# Set include dirs
set_property include_dirs [list $rtl_dir/cpu $rtl_dir/cpu/bp $hf_riscv_dir $hf_dir] [get_filesets sim_1]

puts "\[SIM\] Launching simulation..."
launch_simulation

puts "\[SIM\] Running for 5ms..."
run 5ms

puts "\[SIM\] Simulation complete."
close_sim
