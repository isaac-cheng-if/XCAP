create_project -in_memory -part xcau15p-ffvb676-2-i
foreach p {*v_hdmi_tx_ss* *v_hdmi_rx_ss* *v_tpg* *aud_pat_gen* *hdmi_acr_ctrl* *vid_phy_controller* *v_tc:*} { foreach d [get_ipdefs -all $p] { puts "IPDEF $d" } }
create_ip -name v_hdmi_tx_ss -vendor xilinx.com -library ip -module_name t0
set_property -dict [list CONFIG.C_HDMI_VERSION {3} CONFIG.C_INPUT_PIXELS_PER_CLOCK {2} CONFIG.C_MAX_BITS_PER_COMPONENT {12} CONFIG.C_VID_INTERFACE {0}] [get_ips t0]
foreach p [lsort [list_property [get_ips t0] CONFIG.*]] { puts "TXP $p=[get_property $p [get_ips t0]]" }
