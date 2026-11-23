open_hw_manager
connect_hw_server -quiet
open_hw_target
set d [lindex [get_hw_devices xcau15p*] 0]
current_hw_device $d
refresh_hw_device -quiet $d
foreach p [list_property $d] { if {[regexp -nocase {DONE|EOS|CRC|MMCM|BOOT_STATUS|PROGRAMMED|CONFIG_STATUS} $p]} { puts "P $p=[get_property $p $d]" } }
foreach s [get_hw_sysmons -quiet] { refresh_hw_sysmon $s; puts "P TEMP=[get_property TEMPERATURE $s] VCCINT=[get_property VCCINT $s]" }
close_hw_target
