source [file join [file dirname [info script]] i2c_scope_wave.tcl]
set scope_top_name [lindex [split $i2c_scope_root /] 1]
save_wave_config [string range $scope_top_name 3 end].wcfg
puts "PASS: scope waveform configuration saved"
exit
