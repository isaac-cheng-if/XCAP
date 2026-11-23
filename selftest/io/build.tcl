set w C:/Users/i/vivado-mcp-work/selftest/io
create_project -force p $w/p -part xcau15p-ffvb676-2-i
create_ip -name jtag_axi -vendor xilinx.com -library ip -module_name jtag_axi_0
set_property -dict {CONFIG.PROTOCOL 2} [get_ips jtag_axi_0]
add_files $w/io_top.sv
add_files -fileset constrs_1 $w/io.xdc
set_property top io_top [current_fileset]
# GT reference clock pins by site
set f [open $w/gt.xdc w]
foreach {p s} {gt225_clk1 1 gt225_clk0 0} { puts $f "# $p" }
close $f
launch_runs synth_1 -jobs 12; wait_on_run synth_1
open_run synth_1
foreach {p pk} {gt225_clk1 MGTREFCLK1P_225 gt225_clk0 MGTREFCLK0P_225 gt226_clk0 MGTREFCLK0P_226 gt224_clk0 MGTREFCLK0P_224} {
  set pp [get_package_pins -filter "PIN_FUNC == $pk"]; puts "$p $pk -> $pp"
  set_property PACKAGE_PIN $pp [get_ports ${p}_p]
}
opt_design; place_design; route_design
report_timing_summary -file $w/timing.rpt -delay_type min_max -max_paths 3
report_drc -file $w/drc.rpt
write_debug_probes -force $w/io.ltx
write_checkpoint -force $w/routed.dcp
write_bitstream -force $w/io_pu.bit
set_property PULLTYPE PULLDOWN [get_ports pin[*]]
write_bitstream -force $w/io_pd.bit
puts "STATUS=done WNS=[get_property SLACK [get_timing_paths -max_paths 1]]"
