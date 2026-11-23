# new firmware into the routed design: only write_bitstream runs again     vivado -mode batch -source update_fw.tcl -tclargs rk_fh1159
set w C:/dev/xcap
set card [lindex $argv 0]
open_project $w/ph/xcap_hdmi.xpr
reset_runs impl_1 -from_step write_bitstream
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
puts "STATUS=[get_property STATUS [get_runs impl_1]] WNS=[get_property STATS.WNS [get_runs impl_1]]"
file copy -force $w/ph/xcap_hdmi.runs/impl_1/xcap_hdmi_top.bit $w/xcap_hdmi_$card.bit
puts ALLDONE
