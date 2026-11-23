set w C:/dev/xcap
file mkdir $w/p
create_project -force xcap $w/p -part xcau15p-ffvb676-2-i
create_ip -name xdma -vendor xilinx.com -library ip -module_name xdma_0
set ip [get_ips xdma_0]
set_property -dict {
  CONFIG.mode_selection {Advanced}
  CONFIG.pcie_blk_locn {PCIE4C_X0Y0}
  CONFIG.pl_link_cap_max_link_width {X4}
  CONFIG.pl_link_cap_max_link_speed {8.0_GT/s}
  CONFIG.axi_data_width {128_bit}
  CONFIG.axisten_freq {250}
  CONFIG.plltype {QPLL1}
  CONFIG.disable_gt_loc {true}
  CONFIG.xdma_axi_intf_mm {AXI_Stream}
  CONFIG.xdma_rnum_chnl {1}
  CONFIG.xdma_wnum_chnl {2}
  CONFIG.axilite_master_en {true}
  CONFIG.axilite_master_size {64}
  CONFIG.axilite_master_scale {Kilobytes}
  CONFIG.pf0_device_id {A15C}
  CONFIG.pf0_subsystem_id {0001}
  CONFIG.pf0_base_class_menu {Multimedia_device}
  CONFIG.pf0_sub_class_interface_menu {Other_multimedia_device}
  CONFIG.pf0_class_code_base {04}
  CONFIG.pf0_class_code_sub {80}
  CONFIG.pf0_class_code_interface {00}
  CONFIG.pf0_msi_enabled {true}
  CONFIG.pf0_msix_enabled {false}
  CONFIG.cfg_mgmt_if {false}
  CONFIG.xdma_num_usr_irq {1}
} $ip
foreach p {xdma_axi_intf_mm axil_master_64bit_en pf0_class_code pf0_device_id pl_link_cap_max_link_speed pl_link_cap_max_link_width axisten_freq axi_data_width plltype disable_gt_loc select_quad pf0_bar0_size pf0_bar0_scale pf0_bar1_size pf0_bar1_scale pf0_bar1_enabled pf0_msi_enabled pf0_msix_enabled} { puts "IPCFG $p = [get_property CONFIG.$p $ip]" }
generate_target all $ip
add_files [glob $w/rtl/*.sv]
add_files -fileset constrs_1 $w/xcap.xdc
set_property top xcap_top [current_fileset]
update_compile_order -fileset sources_1
set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]
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
