# Source after launching one of the tb_i2c_scope simulations.
set i2c_scope_root ""
foreach candidate {/tb_i2c_scope /tb_i2c_scope_all/scope /tb_i2c_scope_temp/scope /tb_i2c_scope_humidity/scope /tb_i2c_scope_distance/scope} {
    if {[llength [get_objects -quiet $candidate/scl]] > 0} {
        set i2c_scope_root $candidate
        break
    }
}
if {$i2c_scope_root eq ""} { error "Launch a tb_i2c_scope simulation first." }
create_wave_config I2C_SCOPE
add_wave -name CH1_SCL -color yellow $i2c_scope_root/scl
add_wave -name CH2_SDA -color cyan $i2c_scope_root/sda
add_wave -name SENSOR_VALUE -radix ascii $i2c_scope_root/capture_label
add_wave -name BUS_BYTE -radix ascii $i2c_scope_root/byte_label
add_wave -name BUS_PHASE -radix ascii $i2c_scope_root/bus_stage
log_wave -r $i2c_scope_root/*
restart
run all
puts "PASS: I2C scope waveform configured. Select Zoom Fit, then zoom into one capture (~500 us)."
