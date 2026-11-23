set w C:/Users/i/vivado-mcp-work/selftest/ddr
create_project -force p $w/p -part xcau15p-ffvb676-2-i
create_ip -name ddr4 -vendor xilinx.com -library ip -module_name ddr4_0
set_property -dict {CONFIG.C0.DDR4_TimePeriod 833 CONFIG.C0.DDR4_InputClockPeriod 4998 CONFIG.C0.DDR4_CLKFBOUT_MULT 15 CONFIG.C0.DDR4_CLKOUT0_DIVIDE 5 CONFIG.C0.DDR4_MemoryPart MT40A512M16HA-083E CONFIG.C0.DDR4_DataWidth 16 CONFIG.C0.DDR4_CasLatency 16 CONFIG.C0.DDR4_CasWriteLatency 12} [get_ips ddr4_0]
puts "DM=[get_property CONFIG.C0.DDR4_DataMask [get_ips ddr4_0]]"
create_ip -name vio -vendor xilinx.com -library ip -module_name vio_0
set_property -dict {CONFIG.C_NUM_PROBE_IN 9 CONFIG.C_NUM_PROBE_OUT 3 CONFIG.C_PROBE_IN0_WIDTH 1 CONFIG.C_PROBE_IN1_WIDTH 32 CONFIG.C_PROBE_IN2_WIDTH 32 CONFIG.C_PROBE_IN3_WIDTH 16 CONFIG.C_PROBE_IN4_WIDTH 6 CONFIG.C_PROBE_IN5_WIDTH 26 CONFIG.C_PROBE_IN6_WIDTH 128 CONFIG.C_PROBE_IN7_WIDTH 32 CONFIG.C_PROBE_IN8_WIDTH 32 CONFIG.C_EN_PROBE_IN_ACTIVITY 0} [get_ips vio_0]
add_files $w/ddr_top.sv
add_files -fileset constrs_1 $w/ddr.xdc
set_property top ddr_top [current_fileset]
launch_runs impl_1 -to_step write_bitstream -jobs 12
wait_on_run impl_1
puts "STATUS=[get_property STATUS [get_runs impl_1]] WNS=[get_property STATS.WNS [get_runs impl_1]] WHS=[get_property STATS.WHS [get_runs impl_1]]"
foreach e {bit ltx} { foreach f [glob -nocomplain $w/p/p.runs/impl_1/*.$e] { file copy -force $f $w/ddr.$e } }
