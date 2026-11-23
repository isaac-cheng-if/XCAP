create_project -in_memory -part xcau15p-ffvb676-2-i
create_bd_design q
set v [create_bd_cell -type ip -vlnv xilinx.com:ip:vid_phy_controller vphy]
set_property -dict [list CONFIG.C_Tx_Protocol {HDMI} CONFIG.C_Rx_Protocol {HDMI}] $v
set_property -dict [list CONFIG.CHANNEL_SITE {X0Y4} CONFIG.C_INT_HDMI_VER_CMPTBLE {3} CONFIG.C_INPUT_PIXELS_PER_CLOCK {2} CONFIG.C_RX_PLL_SELECTION {0} CONFIG.C_RX_REFCLK_SEL {0} CONFIG.C_NIDRU {false} CONFIG.Rx_GT_Line_Rate {5.94} CONFIG.Rx_GT_Ref_Clock_Freq {297} CONFIG.C_TX_PLL_SELECTION {6} CONFIG.C_TX_REFCLK_SEL {4} CONFIG.C_Use_GT_CH4_HDMI {true} CONFIG.C_Txrefclk_Rdy_Invert {true} CONFIG.Tx_GT_Line_Rate {5.94} CONFIG.Tx_GT_Ref_Clock_Freq {297}] $v
foreach p {CHANNEL_ENABLE C_TX_PLL_SELECTION C_TX_REFCLK_SEL C_Use_GT_CH4_HDMI C_Txrefclk_Rdy_Invert Transceiver} { puts "VP $p=[get_property CONFIG.$p $v]" }
foreach p [get_bd_pins vphy/*] { puts "VPIN [get_property NAME $p] [get_property DIR $p] [get_property LEFT $p]" }
foreach p [get_bd_intf_pins vphy/*] { puts "VIF [get_property NAME $p]" }
set t [create_bd_cell -type ip -vlnv xilinx.com:ip:v_hdmi_tx_ss txss]
set_property -dict [list CONFIG.C_HDMI_VERSION {3} CONFIG.C_INPUT_PIXELS_PER_CLOCK {2} CONFIG.C_MAX_BITS_PER_COMPONENT {12} CONFIG.C_VID_INTERFACE {0} CONFIG.C_INCLUDE_LOW_RESO_VID {false} CONFIG.C_INCLUDE_YUV420_SUP {false}] $t
foreach p [get_bd_pins txss/*] { puts "TPIN [get_property NAME $p] [get_property DIR $p] [get_property LEFT $p]" }
foreach p [get_bd_intf_pins txss/*] { puts "TIF [get_property NAME $p] [get_property VLNV $p]" }
set g [create_bd_cell -type ip -vlnv xilinx.com:ip:v_tpg tpg]
set_property -dict [list CONFIG.MAX_DATA_WIDTH {12} CONFIG.SAMPLES_PER_CLOCK {2} CONFIG.HAS_AXI4S_SLAVE {0} CONFIG.MAX_COLS {3840} CONFIG.MAX_ROWS {2160}] $g
foreach p [lsort [list_property $g CONFIG.*]] { puts "GP $p=[get_property $p $g]" }
foreach p [get_bd_pins tpg/*] { puts "GPIN [get_property NAME $p] [get_property DIR $p]" }
