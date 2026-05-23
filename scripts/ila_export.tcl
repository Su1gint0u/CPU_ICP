# ILA live capture + CSV export — wrapper around ila_capture_export.tcl
# Usage (Vivado Tcl Console, FPGA connected):
#   source scripts/ila_export.tcl
#   ila_cap_export
source [file join [file dirname [info script]] "ila_capture_export.tcl"]
