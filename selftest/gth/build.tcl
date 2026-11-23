set w C:/Users/i/vivado-mcp-work/selftest/gth
create_project -force p $w/p -part xcau15p-ffvb676-2-i
set ch {}; set rc {}
for {set i 0} {$i<12} {incr i} { lappend ch X0Y$i; lappend rc "X0Y$i" [lindex {clk1+1 clk1 clk1-1} [expr {$i/4}]] }
create_ip -name gtwizard_ultrascale -vendor xilinx.com -library ip -module_name gth_0
set ip [get_ips gth_0]
set_property -dict [list CONFIG.CHANNEL_ENABLE $ch CONFIG.TX_MASTER_CHANNEL X0Y4 CONFIG.RX_MASTER_CHANNEL X0Y4 CONFIG.TX_LINE_RATE 12.5 CONFIG.RX_LINE_RATE 12.5 CONFIG.TX_REFCLK_FREQUENCY 156.25 CONFIG.RX_REFCLK_FREQUENCY 156.25 CONFIG.TX_PLL_TYPE QPLL0 CONFIG.RX_PLL_TYPE QPLL0 CONFIG.TX_DATA_ENCODING RAW CONFIG.RX_DATA_DECODING RAW CONFIG.TX_USER_DATA_WIDTH 64 CONFIG.RX_USER_DATA_WIDTH 64 CONFIG.TX_INT_DATA_WIDTH 32 CONFIG.RX_INT_DATA_WIDTH 32 CONFIG.FREERUN_FREQUENCY 100 CONFIG.TX_REFCLK_SOURCE $rc CONFIG.RX_REFCLK_SOURCE $rc CONFIG.LOCATE_TX_USER_CLOCKING CORE CONFIG.LOCATE_RX_USER_CLOCKING CORE CONFIG.ENABLE_OPTIONAL_PORTS {loopback_in rxprbscntreset_in rxprbssel_in rxprbserr_out rxprbslocked_out txprbsforceerr_in txprbssel_in}] $ip
create_ip -name vio -vendor xilinx.com -library ip -module_name vio_g
set c {CONFIG.C_NUM_PROBE_IN 17 CONFIG.C_NUM_PROBE_OUT 6 CONFIG.C_EN_PROBE_IN_ACTIVITY 0 CONFIG.C_PROBE_IN2_WIDTH 12 CONFIG.C_PROBE_IN3_WIDTH 12 CONFIG.C_PROBE_IN4_WIDTH 41 CONFIG.C_PROBE_OUT4_WIDTH 3 CONFIG.C_PROBE_OUT5_WIDTH 4 CONFIG.C_PROBE_OUT4_INIT_VAL 0x2 CONFIG.C_PROBE_OUT5_INIT_VAL 0x5}
for {set i 5} {$i<17} {incr i} { lappend c CONFIG.C_PROBE_IN${i}_WIDTH 32 }
set_property -dict $c [get_ips vio_g]
add_files $w/gth_top.sv
add_files -fileset constrs_1 $w/gth.xdc
set_property top gth_top [current_fileset]
launch_runs impl_1 -to_step write_bitstream -jobs 12
wait_on_run impl_1
puts "STATUS=[get_property STATUS [get_runs impl_1]] WNS=[get_property STATS.WNS [get_runs impl_1]] WHS=[get_property STATS.WHS [get_runs impl_1]]"
open_run impl_1
foreach p [lsort -dictionary [get_ports gthtxp*]] { puts "LANE $p [get_property PACKAGE_PIN $p] [get_property PIN_FUNC [get_package_pins [get_property PACKAGE_PIN $p]]]" }
foreach e {bit ltx} { foreach f [glob -nocomplain $w/p/p.runs/impl_1/*.$e] { file copy -force $f $w/gth.$e } }
puts ALLDONE
