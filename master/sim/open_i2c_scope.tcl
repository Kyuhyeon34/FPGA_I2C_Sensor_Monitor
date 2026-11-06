# Vivado Tcl Console: source tests/open_i2c_scope.tcl
# Optional before sourcing: set scope_top tb_i2c_scope_temp
set scope_scripts [file normalize [file dirname [info script]]]
set scope_project [file dirname $scope_scripts]
if {![info exists scope_top]} { set scope_top tb_i2c_scope_all }
if {$scope_top ni {tb_i2c_scope tb_i2c_scope_all tb_i2c_scope_temp tb_i2c_scope_humidity tb_i2c_scope_distance}} {
    error "scope_top must be tb_i2c_scope_all, tb_i2c_scope_temp, tb_i2c_scope_humidity, or tb_i2c_scope_distance"
}
if {[file isfile [file join $scope_project load_sources.tcl]]} {
    source [file join $scope_project load_sources.tcl]
} elseif {[file isfile [file join $scope_project create_project.tcl]]} {
    source [file join $scope_project create_project.tcl]
} else {
    error "Project registration script is missing next to $scope_scripts"
}
# Use a separate simset/run directory so an existing sim_1 waveform is untouched.
if {[llength [get_filesets -quiet sim_scope]] == 0} { create_fileset -simset sim_scope }
set scope_simset [get_filesets sim_scope]
set_property source_set sources_1 $scope_simset
if {[file isfile [file join $scope_project i2c_driver.srcs sim_1 new tb_i2c_scope.sv]]} {
    set scope_bench [file join $scope_project i2c_driver.srcs sim_1 new tb_i2c_scope.sv]
    set scope_refs [file join $scope_project tests reference_slave]
} else {
    set scope_bench [file join $scope_scripts tb_i2c_scope.sv]
    set scope_refs [file join $scope_scripts reference_slave]
}
set scope_files [concat [list $scope_bench] [glob -directory $scope_refs *.v]]
foreach scope_file $scope_files {
    if {[llength [get_files -quiet -of_objects $scope_simset $scope_file]] == 0} {
        add_files -norecurse -fileset sim_scope $scope_file
    }
}
set_property top $scope_top $scope_simset
set_property top_auto_set 0 $scope_simset
set_property xsim.simulate.runtime 0ns $scope_simset
update_compile_order -fileset sim_scope
launch_simulation -simset sim_scope -mode behavioral
source [file join $scope_scripts i2c_scope_wave.tcl]
