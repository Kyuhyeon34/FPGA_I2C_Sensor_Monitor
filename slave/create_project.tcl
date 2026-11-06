# Vivado 2020.2 : Tcl Console 에서  source <repo>/slave/create_project.tcl  (slave/vivado/ 에 프로젝트 생성)
set root [file dirname [file normalize [info script]]]

create_project i2c_slave $root/vivado -part xc7a35tcpg236-1 -force

add_files -norecurse [glob $root/src/*.v]
add_files -fileset constrs_1 -norecurse $root/constr/Basys3_slave.xdc
add_files -fileset sim_1 -norecurse [glob $root/sim/*.v]

set_property top top_slave [current_fileset]
set_property top tb_i2c_slave [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts "== i2c_slave project created : $root/vivado =="
