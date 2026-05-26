# Vivado build script for fpga_top (Nexys4 xc7a100tcsg324-1)
# Usage: vivado -mode batch -source build.tcl

set project_name "fpga_top"
set project_dir  [file dirname [info script]]
set const_dir    [file normalize "$project_dir/../const"]
set part_name    "xc7a100tcsg324-1"
set top_module   "fpga_top"

# Keep batch builds usable on modest lab machines.
set_param general.maxThreads 2

# Clean and create project
if {[file exists $project_dir/imp]} {
    file delete -force $project_dir/imp
}
create_project $project_name $project_dir/imp -part $part_name -force
set_property top $top_module [current_fileset]

# ---- Source files ----
set rtl_dir [file normalize "$project_dir/../../RTL/cpu"]

set src_files [list]
lappend src_files $rtl_dir/cpu_pkg.sv
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
# BP
lappend src_files $rtl_dir/bp/bp_direction_2bit.sv
lappend src_files $rtl_dir/bp/bp_btb_direct.sv
lappend src_files $rtl_dir/bp/bp_ras.sv
lappend src_files $rtl_dir/bp/bp_gshare.sv
lappend src_files $rtl_dir/bp/bp_tage.sv
lappend src_files $rtl_dir/bp/bp_predictor_simple.sv

# Add only existing files
set added 0
foreach f $src_files {
    if {[file exists $f]} {
        add_files -fileset sources_1 $f
        incr added
    } else {
        puts "\[BUILD\] WARNING: file not found: $f"
    }
}
puts "\[BUILD\] Added $added source files"

# Set SystemVerilog
set_property FILE_TYPE SystemVerilog [get_files -of_objects [get_filesets sources_1] *.sv]
set_property include_dirs [list $rtl_dir $rtl_dir/bp] [get_filesets sources_1]
set_property verilog_define {SYNTHESIS=1} [get_filesets sources_1]

# ---- Always-on acceptance ILA ----
# Probe width order follows RTL/cpu/fpga_top.sv and Nexys4/ILA_ACCEPTANCE.md.
puts "\[BUILD\] Creating ILA debug IP..."
create_ip -name ila -vendor xilinx.com -library ip -version 6.2 -module_name ila_cpu_uart_dbg
set_property -dict [list \
    CONFIG.C_MONITOR_TYPE {Native} \
    CONFIG.C_DATA_DEPTH {2048} \
    CONFIG.C_NUM_OF_PROBES {18} \
    CONFIG.C_PROBE0_WIDTH {4} \
    CONFIG.C_PROBE1_WIDTH {9} \
    CONFIG.C_PROBE2_WIDTH {13} \
    CONFIG.C_PROBE3_WIDTH {49} \
    CONFIG.C_PROBE4_WIDTH {13} \
    CONFIG.C_PROBE5_WIDTH {76} \
    CONFIG.C_PROBE6_WIDTH {19} \
    CONFIG.C_PROBE7_WIDTH {103} \
    CONFIG.C_PROBE8_WIDTH {103} \
    CONFIG.C_PROBE9_WIDTH {68} \
    CONFIG.C_PROBE10_WIDTH {67} \
    CONFIG.C_PROBE11_WIDTH {25} \
    CONFIG.C_PROBE12_WIDTH {1} \
    CONFIG.C_PROBE13_WIDTH {1} \
    CONFIG.C_PROBE14_WIDTH {1} \
    CONFIG.C_PROBE15_WIDTH {1} \
    CONFIG.C_PROBE16_WIDTH {38} \
    CONFIG.C_PROBE17_WIDTH {1} \
] [get_ips ila_cpu_uart_dbg]
generate_target all [get_ips ila_cpu_uart_dbg]
synth_ip [get_ips ila_cpu_uart_dbg]
puts "\[BUILD\] ILA debug IP ready"

# ---- Constraints ----
set xdc_files [list]
foreach preferred [list "nexys4_io.xdc" "timing.xdc"] {
    set xdc_path [file join $const_dir $preferred]
    if {[file exists $xdc_path]} {
        lappend xdc_files $xdc_path
    }
}
foreach xdc [lsort [glob -nocomplain $const_dir/*.xdc]] {
    if {[lsearch -exact $xdc_files $xdc] < 0} {
        lappend xdc_files $xdc
    }
}

foreach xdc $xdc_files {
    add_files -fileset constrs_1 $xdc
    puts "\[BUILD\] Added constraint: $xdc"
}

# Read constraints immediately (for direct synth_design flow)
foreach xdc $xdc_files {
    read_xdc $xdc
    puts "\[BUILD\] Read constraint: $xdc"
}

# ---- Synthesis ----
puts "\[BUILD\] Starting synthesis..."
# RuntimeOptimized avoids very expensive area rewrite passes that can dominate this CPU-heavy core.
synth_design -top $top_module -part $part_name -directive RuntimeOptimized
write_checkpoint -force $project_dir/imp/synth.dcp
puts "\[BUILD\] Synthesis PASSED"

puts "\[BUILD\] Utilization:"
report_utilization -quiet
report_utilization -file $project_dir/imp/utilization_synth.rpt

puts "\[BUILD\] Starting implementation..."
opt_design
place_design -directive ExtraTimingOpt
phys_opt_design -directive Explore
route_design -directive Explore
phys_opt_design -directive AggressiveExplore
puts "\[BUILD\] Implementation PASSED"
report_route_status -file $project_dir/imp/route_status.rpt
report_drc -file $project_dir/imp/drc.rpt

puts "\[BUILD\] Timing summary:"
report_timing_summary
report_timing_summary -file $project_dir/imp/timing_summary.rpt

puts "\[BUILD\] Generating bitstream..."
write_bitstream -force $project_dir/imp/$top_module.bit
write_debug_probes -force $project_dir/imp/$top_module.ltx

if {[file exists $project_dir/imp/$top_module.bit]} {
    puts "\[BUILD\] SUCCESS: [file size $project_dir/imp/$top_module.bit] bytes -> $project_dir/imp/$top_module.bit"
} else {
    puts "\[BUILD\] ERROR: Bitstream not generated"
    exit 1
}
if {[file exists $project_dir/imp/$top_module.ltx]} {
    puts "\[BUILD\] Debug probes -> $project_dir/imp/$top_module.ltx"
} else {
    puts "\[BUILD\] ERROR: Debug probes not generated"
    exit 1
}
puts "\[BUILD\] Done."
