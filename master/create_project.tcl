# Run with Vivado 2020.2: source master/create_project.tcl
set master_dir [file normalize [file dirname [info script]]]
set master_project_dir [file join $master_dir vivado]
set master_project_file [file join $master_project_dir i2c_master.xpr]

if {[current_project -quiet] eq ""} {
    if {[file isfile $master_project_file]} {
        open_project $master_project_file
    } else {
        create_project i2c_master $master_project_dir -part xc7a35tcpg236-1
    }
} elseif {![string equal -nocase [file normalize [get_property DIRECTORY [current_project]]] $master_project_dir]} {
    error "Close the current project before creating/opening $master_project_file"
}

foreach master_source [glob -directory [file join $master_dir src] *.v] {
    if {[llength [get_files -quiet $master_source]] == 0} {
        add_files -norecurse -fileset sources_1 $master_source
    }
}
set master_sim_sources [concat \
    [glob -directory [file join $master_dir sim] *.sv] \
    [glob -directory [file join $master_dir sim reference_slave] *.v]]
foreach master_test $master_sim_sources {
    if {[llength [get_files -quiet $master_test]] == 0} {
        add_files -norecurse -fileset sim_1 $master_test
    }
}
set master_sprite [file join $master_dir assets slowpoke-frames.hex]
if {[llength [get_files -quiet $master_sprite]] == 0} {
    add_files -norecurse -fileset sim_1 $master_sprite
}
set_property file_type {Memory Initialization Files} [get_files $master_sprite]
set master_xdc [file join $master_dir constr Basys3_master.xdc]
if {[llength [get_files -quiet $master_xdc]] == 0} {
    add_files -norecurse -fileset constrs_1 $master_xdc
}
set_property top top [get_filesets sources_1]
set_property top_auto_set 0 [get_filesets sources_1]
set_property top tb_i2c_master [get_filesets sim_1]
set_property top_auto_set 0 [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
puts "PASS: Master project ready: $master_project_file"
