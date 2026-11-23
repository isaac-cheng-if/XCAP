open_hw_manager
connect_hw_server -quiet
open_hw_target
set t [current_hw_target]
puts "TCK=[get_property PARAM.FREQUENCY $t]"
set d [lindex [get_hw_devices xcau15p*] 0]
current_hw_device $d
set_property PROGRAM.FILE [lindex $argv 0] $d
program_hw_devices $d
refresh_hw_device -quiet $d
puts "DONE=[get_property {REGISTER.CONFIG_STATUS.BIT[14]_DONE_PIN} $d]"
close_hw_target
