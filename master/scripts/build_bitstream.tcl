# vivado -mode batch -source master/scripts/build_bitstream.tcl
source [file join [file dirname [info script]] .. create_project.tcl]
set master_build_started [clock seconds]
proc require_master_artifact {path started} {
    if {![file isfile $path] || [file size $path] == 0 || [file mtime $path] < $started} {
        error "Build did not produce a fresh artifact: $path"
    }
}
reset_run synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1
require_master_artifact [file join $master_project_dir i2c_master.runs synth_1 top.dcp] $master_build_started
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
set master_impl_dir [file join $master_project_dir i2c_master.runs impl_1]
set master_bitstream [file join $master_impl_dir top.bit]
set master_checkpoint [file join $master_impl_dir top_routed.dcp]
require_master_artifact $master_bitstream $master_build_started
require_master_artifact $master_checkpoint $master_build_started
close_project
open_checkpoint $master_checkpoint
set master_reports [file join $master_dir reports]
file mkdir $master_reports
report_timing_summary -file [file join $master_reports timing_summary.txt]
report_utilization -file [file join $master_reports utilization.txt]
report_drc -file [file join $master_reports drc.txt]
if {[llength [get_drc_violations -quiet]] > 0} {
    error "Implemented Master design has DRC violations"
}
set master_setup [get_timing_paths -delay_type max -max_paths 1]
set master_hold [get_timing_paths -delay_type min -max_paths 1]
if {[llength $master_setup] == 0 || [llength $master_hold] == 0} {
    error "Missing implemented timing paths"
}
foreach master_path [concat $master_setup $master_hold] {
    if {[get_property SLACK $master_path] < 0} {
        error "Implemented Master design has a setup/hold timing violation"
    }
}
file mkdir [file join $master_dir bitstream]
file copy -force $master_bitstream [file join $master_dir bitstream top.bit]
puts "PASS: Master bitstream, setup/hold timing and DRC verified"
puts "BITSTREAM: [file join $master_dir bitstream top.bit]"
close_design
exit
