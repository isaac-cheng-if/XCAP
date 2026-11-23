set w C:/dev/xcap
set card [lindex $argv 0]
open_project $w/ph/xcap_hdmi.xpr
reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 16
wait_on_run impl_1
puts "STATUS=[get_property STATUS [get_runs impl_1]] WNS=[get_property STATS.WNS [get_runs impl_1]] WHS=[get_property STATS.WHS [get_runs impl_1]]"
open_run impl_1
report_timing_summary -file $w/timing_hdmi.rpt -max_paths 8
report_utilization -file $w/util_hdmi.rpt
report_cdc -file $w/cdc_hdmi.rpt
file copy -force $w/ph/xcap_hdmi.runs/impl_1/xcap_hdmi_top.bit $w/xcap_hdmi_$card.bit
puts ALLDONE
