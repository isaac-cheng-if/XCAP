set w C:/dev/xcap
open_project $w/p/xcap.xpr
update_compile_order -fileset sources_1
reset_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 12
wait_on_run impl_1
puts "STATUS=[get_property STATUS [get_runs impl_1]] WNS=[get_property STATS.WNS [get_runs impl_1]] WHS=[get_property STATS.WHS [get_runs impl_1]]"
open_run impl_1
report_timing_summary -file $w/timing.rpt -max_paths 5
report_utilization -file $w/util.rpt
report_cdc -file $w/cdc.rpt
report_methodology -file $w/meth.rpt
file copy -force $w/p/xcap.runs/impl_1/xcap_top.bit $w/xcap_top.bit
puts ALLDONE
