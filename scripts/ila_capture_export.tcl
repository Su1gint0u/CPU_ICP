# Capture ILA data from live FPGA and export to CSV.
# MUST be run in Vivado Tcl Console with FPGA connected & programmed.
# Usage:
#   source scripts/ila_capture_export.tcl
#   ila_cap_export                           # export current buffer
#   ila_cap_export -trigger {probe[0] == 1}  # set trigger, capture, export

set _ila_script_dir [file normalize [file dirname [info script]]]
set _ila_repo_root [file normalize [file join $_ila_script_dir ..]]

proc ila_cap_export {args} {
    global _ila_script_dir _ila_repo_root

    set out_csv  [file join $_ila_repo_root "tests" "hw_ila_data_1.csv"]
    set trigger  ""

    for {set i 0} {$i < [llength $args]} {incr i} {
        set arg [lindex $args $i]
        switch -- $arg {
            -out {
                incr i
                set out_csv [file normalize [lindex $args $i]]
            }
            -trigger {
                incr i
                set trigger [lindex $args $i]
            }
            default {
                puts stderr "\[ILA_CAP\] Unknown option: $arg"
                puts stderr "\[ILA_CAP\] Usage: ila_cap_export \[-out <csv_path>\] \[-trigger <condition>\]"
                return
            }
        }
    }

    file mkdir [file dirname $out_csv]

    # ── find ILA core ──
    if {[catch {set ila_cores [get_hw_ilas *]} err]} {
        puts stderr "\[ILA_CAP\] ERROR: open_hw_manager not run or no FPGA target. Run open_hw_manager first."
        puts stderr "\[ILA_CAP\]   $err"
        return
    }

    if {[llength $ila_cores] == 0} {
        puts stderr "\[ILA_CAP\] ERROR: no ILA cores found. Is the FPGA programmed with a bitstream containing ILA?"
        return
    }

    set ila [lindex $ila_cores 0]
    set ila_name [get_property NAME $ila]
    puts "\[ILA_CAP\] Found ILA core: $ila_name"

    # ── set trigger ──
    if {$trigger ne ""} {
        puts "\[ILA_CAP\] Setting trigger: $trigger"
        set parts [split $trigger]
        set probe_name [lindex $parts 0]
        set op         [lindex $parts 1]
        set val        [lindex $parts 2]

        if {[catch {set probes [get_hw_probes -of_objects $ila $probe_name]} err]} {
            puts stderr "\[ILA_CAP\] ERROR: probe not found: $probe_name"
            puts stderr "\[ILA_CAP\]   Available probes:"
            foreach p [get_hw_probes -of_objects $ila] {
                puts stderr "\[ILA_CAP\]     [get_property NAME $p]"
            }
            return
        }
        set probe_obj [lindex $probes 0]

        reset_hw_ila_trigger $ila

        if {$op eq "=="} {
            set_property CONTROL.TRIGGER_POSITION "0" $ila
            add_hw_ila_trigger_condition $ila -probe $probe_obj -compare eq -value $val
        } elseif {$op eq "R" || $op eq "r"} {
            add_hw_ila_trigger_condition $ila -probe $probe_obj -condition "R"
        } else {
            puts stderr "\[ILA_CAP\] ERROR: unsupported operator '$op'. Use '==' or 'R'."
            return
        }

        puts "\[ILA_CAP\] Arming trigger..."
        run_hw_ila $ila
        puts "\[ILA_CAP\] Waiting for trigger..."
        wait_on_hw_ila $ila
        puts "\[ILA_CAP\] Triggered"
    }

    # ── upload captured data ──
    puts "\[ILA_CAP\] Uploading captured data from FPGA..."
    if {[catch {set ila_data [upload_hw_ila_data $ila]} err]} {
        puts stderr "\[ILA_CAP\] ERROR uploading ILA data: $err"
        return
    }
    puts "\[ILA_CAP\] Data uploaded: $ila_data"

    # ── export to CSV ──
    puts "\[ILA_CAP\] Exporting to CSV: $out_csv"
    if {[catch {write_hw_ila_data -csv_file $out_csv $ila_data} err]} {
        puts stderr "\[ILA_CAP\] ERROR writing CSV: $err"
        display_hw_ila_data $ila_data
        return
    }

    if {[file isfile $out_csv]} {
        set sz [file size $out_csv]
        set lines [llength [split [read [open $out_csv r]] "\n"]]
        puts "\[ILA_CAP\] Exported CSV: $out_csv  ($sz bytes, $lines lines)"
    } else {
        puts stderr "\[ILA_CAP\] WARNING: CSV file was not created"
    }

    puts "\[ILA_CAP\] Done."
}

# ── interactive-mode banner ──
if {[llength $argv] == 0 || [info exists ::env(VIVADO_GUI)]} {
    puts ""
    puts "=================================================================="
    puts "  ila_cap_export ready"
    puts ""
    puts "  ila_cap_export                           # export current buffer"
    puts "  ila_cap_export -trigger {probe\[0\] == 1}  # trigger + capture + export"
    puts "  ila_cap_export -trigger {probe\[2\] R} -out tests/out.csv"
    puts "=================================================================="
}
