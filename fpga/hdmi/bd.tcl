# Block design "hdmi_sys": HDMI 1.4/2.0 receiver + Video PHY (RX only) + MicroBlaze.
# clk_100 / clk_300 come from the top level. The capture core sees one AXI4-Stream
# (two pixels per clock, 12 bits per component) in the clk_300 domain.
create_bd_design hdmi_sys
set c100 [create_bd_port -dir I -type clk -freq_hz 100000000 clk_100]
set c300 [create_bd_port -dir I -type clk -freq_hz 300000000 clk_300]
set lock [create_bd_port -dir I clk_locked]

create_bd_cell -type ip -vlnv xilinx.com:ip:microblaze microblaze_0
apply_bd_automation -rule xilinx.com:bd_rule:microblaze -config { axi_intc {1} axi_periph {Enabled} cache {None} clk {/clk_100 (100 MHz)} cores {1} debug_module {Debug Only} ecc {None} local_mem {128KB} preset {None}} [get_bd_cells microblaze_0]
puts "CELLS [get_bd_cells]"
set_property -dict [list CONFIG.C_USE_BARREL {1} CONFIG.C_USE_HW_MUL {1} CONFIG.C_USE_DIV {1} CONFIG.C_USE_MSR_INSTR {1} CONFIG.C_USE_PCMP_INSTR {1} CONFIG.C_AREA_OPTIMIZED {0} CONFIG.C_NUMBER_OF_PC_BRK {1}] [get_bd_cells microblaze_0]

create_bd_cell -type ip -vlnv xilinx.com:ip:v_hdmi_rx_ss v_hdmi_rx_ss
set_property -dict [list CONFIG.C_HDMI_VERSION {3} CONFIG.C_INPUT_PIXELS_PER_CLOCK {2} CONFIG.C_MAX_BITS_PER_COMPONENT {12} CONFIG.C_VID_INTERFACE {0} CONFIG.C_EDID_RAM_SIZE {256} CONFIG.C_INCLUDE_HDCP_1_4 {false} CONFIG.C_INCLUDE_HDCP_2_2 {false} CONFIG.C_INCLUDE_LOW_RESO_VID {false} CONFIG.C_INCLUDE_YUV420_SUP {false} CONFIG.C_HPD_INVERT {false} CONFIG.C_CD_INVERT {true} CONFIG.C_ADDR_WIDTH {10}] [get_bd_cells v_hdmi_rx_ss]
create_bd_cell -type ip -vlnv xilinx.com:ip:vid_phy_controller vphy
set_property -dict [list CONFIG.C_Tx_Protocol {HDMI} CONFIG.C_Rx_Protocol {HDMI}] [get_bd_cells vphy]
set_property -dict [list CONFIG.CHANNEL_SITE {X0Y4} CONFIG.C_INT_HDMI_VER_CMPTBLE {3} CONFIG.C_INPUT_PIXELS_PER_CLOCK {2} CONFIG.C_RX_PLL_SELECTION {0} CONFIG.C_RX_REFCLK_SEL {0} CONFIG.C_NIDRU {false} CONFIG.Rx_GT_Line_Rate {5.94} CONFIG.Rx_GT_Ref_Clock_Freq {297} \
  CONFIG.C_TX_PLL_SELECTION {6} CONFIG.C_TX_REFCLK_SEL {4} CONFIG.C_Use_GT_CH4_HDMI {true} CONFIG.C_Txrefclk_Rdy_Invert {true} CONFIG.Tx_GT_Line_Rate {5.94} CONFIG.Tx_GT_Ref_Clock_Freq {297}] [get_bd_cells vphy]
# transmitter: loop-out of the received picture (through the TPG's input), or the test pattern for loopback tests -> HDMI TX subsystem -> GT lanes 0-2, lane 3 carries the TMDS clock
create_bd_cell -type ip -vlnv xilinx.com:ip:v_hdmi_tx_ss v_hdmi_tx_ss
set_property -dict [list CONFIG.C_HDMI_VERSION {3} CONFIG.C_INPUT_PIXELS_PER_CLOCK {2} CONFIG.C_MAX_BITS_PER_COMPONENT {12} CONFIG.C_VID_INTERFACE {0} CONFIG.C_INCLUDE_LOW_RESO_VID {false} CONFIG.C_INCLUDE_YUV420_SUP {false} CONFIG.C_INCLUDE_HDCP_1_4 {false} CONFIG.C_INCLUDE_HDCP_2_2 {false} CONFIG.C_VIDEO_MASK_ENABLE {0} CONFIG.C_HPD_INVERT {false}] [get_bd_cells v_hdmi_tx_ss]
create_bd_cell -type ip -vlnv xilinx.com:ip:v_tpg v_tpg
set_property -dict [list CONFIG.MAX_DATA_WIDTH {12} CONFIG.SAMPLES_PER_CLOCK {2} CONFIG.HAS_AXI4S_SLAVE {1} CONFIG.MAX_COLS {3840} CONFIG.MAX_ROWS {2160} CONFIG.COLOR_SWEEP {0} CONFIG.ZONE_PLATE {0} CONFIG.FOREGROUND {0} CONFIG.SOLID_COLOR {0} CONFIG.RAMP {1}] [get_bd_cells v_tpg]
create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice tpg_rst
set_property -dict [list CONFIG.DIN_WIDTH {4} CONFIG.DIN_FROM {2} CONFIG.DIN_TO {2}] [get_bd_cells tpg_rst]


create_bd_cell -type ip -vlnv xilinx.com:ip:axi_iic axi_iic_0
set_property -dict [list CONFIG.IIC_FREQ_KHZ {100}] [get_bd_cells axi_iic_0]
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio axi_gpio_0
set_property -dict [list CONFIG.C_GPIO_WIDTH {4} CONFIG.C_ALL_OUTPUTS {1}] [get_bd_cells axi_gpio_0]
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_uartlite axi_uartlite_0
set_property -dict [list CONFIG.C_BAUDRATE {115200} CONFIG.C_S_AXI_ACLK_FREQ_HZ {100000000}] [get_bd_cells axi_uartlite_0]
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_timer axi_timer_0
set_property -dict [list CONFIG.enable_timer2 {0}] [get_bd_cells axi_timer_0]
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_300
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant vcc
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}] [get_bd_cells vcc]

# clocks and resets
set rst [get_bd_cells -filter {VLNV =~ *proc_sys_reset* && NAME != rst_300}]
set arst [get_bd_pins $rst/peripheral_aresetn]
foreach r [list $rst [get_bd_cells rst_300]] {
  foreach n [get_bd_nets -quiet -of_objects [get_bd_pins $r/dcm_locked]] { disconnect_bd_net $n [get_bd_pins $r/dcm_locked] }
  connect_bd_net $lock [get_bd_pins $r/dcm_locked]
  foreach n [get_bd_nets -quiet -of_objects [get_bd_pins $r/ext_reset_in]] { disconnect_bd_net $n [get_bd_pins $r/ext_reset_in] }
  connect_bd_net $lock [get_bd_pins $r/ext_reset_in]
}
connect_bd_net $c300 [get_bd_pins rst_300/slowest_sync_clk] [get_bd_pins v_hdmi_rx_ss/s_axis_video_aclk]
connect_bd_net [get_bd_pins rst_300/peripheral_aresetn] [get_bd_pins v_hdmi_rx_ss/s_axis_video_aresetn]
connect_bd_net $c100 [get_bd_pins v_hdmi_rx_ss/s_axi_cpu_aclk] [get_bd_pins v_hdmi_rx_ss/s_axis_audio_aclk] [get_bd_pins vphy/vid_phy_sb_aclk] [get_bd_pins vphy/vid_phy_axi4lite_aclk] [get_bd_pins vphy/drpclk] \
  [get_bd_pins axi_iic_0/s_axi_aclk] [get_bd_pins axi_gpio_0/s_axi_aclk] [get_bd_pins axi_uartlite_0/s_axi_aclk] [get_bd_pins axi_timer_0/s_axi_aclk]
connect_bd_net $arst [get_bd_pins v_hdmi_rx_ss/s_axi_cpu_aresetn] [get_bd_pins v_hdmi_rx_ss/s_axis_audio_aresetn] [get_bd_pins vphy/vid_phy_sb_aresetn] [get_bd_pins vphy/vid_phy_axi4lite_aresetn] \
  [get_bd_pins axi_iic_0/s_axi_aresetn] [get_bd_pins axi_gpio_0/s_axi_aresetn] [get_bd_pins axi_uartlite_0/s_axi_aresetn] [get_bd_pins axi_timer_0/s_axi_aresetn]
connect_bd_net [get_bd_pins vcc/dout] [get_bd_pins vphy/vid_phy_rx_axi4s_aresetn] [get_bd_pins v_hdmi_rx_ss/AUDIO_OUT_tready] [get_bd_pins vphy/vid_phy_tx_axi4s_aresetn]
connect_bd_net $c300 [get_bd_pins v_hdmi_tx_ss/s_axis_video_aclk] [get_bd_pins v_tpg/ap_clk]
connect_bd_net [get_bd_pins rst_300/peripheral_aresetn] [get_bd_pins v_hdmi_tx_ss/s_axis_video_aresetn]
connect_bd_net $c100 [get_bd_pins v_hdmi_tx_ss/s_axi_cpu_aclk] [get_bd_pins v_hdmi_tx_ss/s_axis_audio_aclk]
connect_bd_net $arst [get_bd_pins v_hdmi_tx_ss/s_axi_cpu_aresetn] [get_bd_pins v_hdmi_tx_ss/s_axis_audio_aresetn]
connect_bd_net [get_bd_pins vphy/txoutclk] [get_bd_pins vphy/vid_phy_tx_axi4s_aclk] [get_bd_pins v_hdmi_tx_ss/link_clk]
connect_bd_net [get_bd_pins vphy/tx_video_clk] [get_bd_pins v_hdmi_tx_ss/video_clk]
# link data goes through the top level, where xcap_linkcap can take snapshots of it
foreach i {0 1 2} {
  make_bd_intf_pins_external -name tx_link$i [get_bd_intf_pins v_hdmi_tx_ss/LINK_DATA${i}_OUT]
  make_bd_intf_pins_external -name phy_tx$i [get_bd_intf_pins vphy/vid_phy_tx_axi4s_ch$i]
}
create_bd_port -dir O -type clk tx_link_clk
connect_bd_net [get_bd_ports tx_link_clk] [get_bd_pins vphy/txoutclk]
set_property -dict [list CONFIG.FREQ_HZ 148500000 CONFIG.ASSOCIATED_BUSIF {tx_link0:tx_link1:tx_link2:phy_tx0:phy_tx1:phy_tx2}] [get_bd_ports tx_link_clk]
foreach p {tx_link0 tx_link1 tx_link2 phy_tx0 phy_tx1 phy_tx2} { set_property CONFIG.FREQ_HZ 148500000 [get_bd_intf_ports $p] }
connect_bd_intf_net [get_bd_intf_pins vphy/vid_phy_status_sb_tx] [get_bd_intf_pins v_hdmi_tx_ss/SB_STATUS_IN]
connect_bd_intf_net [get_bd_intf_pins v_tpg/m_axis_video] [get_bd_intf_pins v_hdmi_tx_ss/VIDEO_IN]
connect_bd_net [get_bd_pins axi_gpio_0/gpio_io_o] [get_bd_pins tpg_rst/Din]
connect_bd_net [get_bd_pins tpg_rst/Dout] [get_bd_pins v_tpg/ap_rst_n]
# loop-out: the receiver's picture comes back in from the top level (xcap_ptvideo) and passes through the TPG
foreach sig {TDATA TUSER TLAST TVALID TREADY} { make_bd_pins_external -name pt_[string tolower $sig] [get_bd_pins v_tpg/s_axis_video_$sig] }
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant pt_ones
set_property -dict [list CONFIG.CONST_WIDTH {9} CONFIG.CONST_VAL {511}] [get_bd_cells pt_ones]
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant pt_zero
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] [get_bd_cells pt_zero]
connect_bd_net [get_bd_pins pt_ones/dout] [get_bd_pins v_tpg/s_axis_video_TKEEP] [get_bd_pins v_tpg/s_axis_video_TSTRB]
connect_bd_net [get_bd_pins pt_zero/dout] [get_bd_pins v_tpg/s_axis_video_TID] [get_bd_pins v_tpg/s_axis_video_TDEST] [get_bd_pins v_tpg/fid_in]


# PHY <-> receiver
connect_bd_net [get_bd_pins vphy/rxoutclk] [get_bd_pins vphy/vid_phy_rx_axi4s_aclk] [get_bd_pins v_hdmi_rx_ss/link_clk]
connect_bd_net [get_bd_pins vphy/rx_video_clk] [get_bd_pins v_hdmi_rx_ss/video_clk]
foreach i {0 1 2} {
  make_bd_intf_pins_external -name phy_rx$i [get_bd_intf_pins vphy/vid_phy_rx_axi4s_ch$i]
  make_bd_intf_pins_external -name rx_link$i [get_bd_intf_pins v_hdmi_rx_ss/LINK_DATA${i}_IN]
}
create_bd_port -dir O -type clk rx_link_clk
connect_bd_net [get_bd_ports rx_link_clk] [get_bd_pins vphy/rxoutclk]
set_property -dict [list CONFIG.FREQ_HZ 148500000 CONFIG.ASSOCIATED_BUSIF {rx_link0:rx_link1:rx_link2:phy_rx0:phy_rx1:phy_rx2}] [get_bd_ports rx_link_clk]
foreach p {rx_link0 rx_link1 rx_link2 phy_rx0 phy_rx1 phy_rx2} { set_property CONFIG.FREQ_HZ 148500000 [get_bd_intf_ports $p] }
connect_bd_intf_net [get_bd_intf_pins vphy/vid_phy_status_sb_rx] [get_bd_intf_pins v_hdmi_rx_ss/SB_STATUS_IN]

# interrupts
set cat [get_bd_cells microblaze_0_xlconcat]
set_property CONFIG.NUM_PORTS {6} $cat
connect_bd_net [get_bd_pins vphy/irq] [get_bd_pins $cat/In0]
connect_bd_net [get_bd_pins v_hdmi_rx_ss/irq] [get_bd_pins $cat/In1]
connect_bd_net [get_bd_pins axi_iic_0/iic2intc_irpt] [get_bd_pins $cat/In2]
connect_bd_net [get_bd_pins axi_timer_0/interrupt] [get_bd_pins $cat/In3]
connect_bd_net [get_bd_pins axi_uartlite_0/interrupt] [get_bd_pins $cat/In4]
connect_bd_net [get_bd_pins v_hdmi_tx_ss/irq] [get_bd_pins $cat/In5]

# AXI-Lite peripherals + one external port for the capture core's metadata registers
set per [get_bd_cells microblaze_0_axi_periph]
puts "PERIPH [get_property VLNV $per]"
set n [get_property CONFIG.NUM_MI $per]
set slaves {v_hdmi_rx_ss/S_AXI_CPU_IN vphy/vid_phy_axi4lite axi_iic_0/S_AXI axi_gpio_0/S_AXI axi_uartlite_0/S_AXI axi_timer_0/S_AXI v_hdmi_tx_ss/S_AXI_CPU_IN v_tpg/s_axi_CTRL}
set_property CONFIG.NUM_MI [expr {$n + [llength $slaves] + 1}] $per
set i $n
set meta [create_bd_intf_port -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 M_META]
set_property -dict [list CONFIG.PROTOCOL {AXI4LITE} CONFIG.DATA_WIDTH {32} CONFIG.ADDR_WIDTH {32} CONFIG.HAS_PROT {0} CONFIG.HAS_WSTRB {1}] $meta
set_property CONFIG.ASSOCIATED_BUSIF {M_META} $c100
proc mi {i} { return [format %02d $i] }
foreach s $slaves {
  connect_bd_intf_net [get_bd_intf_pins $per/M[mi $i]_AXI] [get_bd_intf_pins $s]
  if {$s eq "v_tpg/s_axi_CTRL"} {
    if {[get_bd_pins -quiet $per/M[mi $i]_ACLK] ne ""} {
      connect_bd_net $c300 [get_bd_pins $per/M[mi $i]_ACLK]; connect_bd_net [get_bd_pins rst_300/peripheral_aresetn] [get_bd_pins $per/M[mi $i]_ARESETN]
    } else {
      # SmartConnect: one more clock input; the slave's own clock tells it which one
      set_property CONFIG.NUM_CLKS [expr {[get_property CONFIG.NUM_CLKS $per] + 1}] $per
      connect_bd_net $c300 [get_bd_pins $per/aclk[expr {[get_property CONFIG.NUM_CLKS $per] - 1}]]
    }
  }
  incr i
}
connect_bd_intf_net [get_bd_intf_pins $per/M[mi $i]_AXI] $meta
foreach p [get_bd_pins -quiet $per/*ACLK] { if {[get_bd_nets -quiet -of_objects $p] eq ""} { connect_bd_net $c100 $p } }
foreach p [get_bd_pins -quiet $per/*ARESETN] { if {[get_bd_nets -quiet -of_objects $p] eq ""} { connect_bd_net $arst $p } }

# external pins
make_bd_intf_pins_external -name RX_DDC [get_bd_intf_pins v_hdmi_rx_ss/DDC_OUT]
make_bd_intf_pins_external -name CTL_IIC [get_bd_intf_pins axi_iic_0/IIC]
make_bd_intf_pins_external -name UART [get_bd_intf_pins axi_uartlite_0/UART]
create_bd_port -dir O -from 3 -to 0 gpio_o
connect_bd_net [get_bd_ports gpio_o] [get_bd_pins axi_gpio_0/gpio_io_o]
make_bd_pins_external -name rx_hpd [get_bd_pins v_hdmi_rx_ss/hpd]
make_bd_pins_external -name rx_det [get_bd_pins v_hdmi_rx_ss/cable_detect]
make_bd_pins_external -name hdmi_rxp [get_bd_pins vphy/phy_rxp_in]
make_bd_pins_external -name hdmi_rxn [get_bd_pins vphy/phy_rxn_in]
make_bd_pins_external -name hdmi_clk_p [get_bd_pins vphy/mgtrefclk0_pad_p_in]
make_bd_pins_external -name hdmi_clk_n [get_bd_pins vphy/mgtrefclk0_pad_n_in]
make_bd_pins_external -name rx_refclk_p [get_bd_pins vphy/rx_tmds_clk_p]
make_bd_pins_external -name rx_refclk_n [get_bd_pins vphy/rx_tmds_clk_n]
make_bd_pins_external -name hdmi_txp [get_bd_pins vphy/phy_txp_out]
make_bd_pins_external -name hdmi_txn [get_bd_pins vphy/phy_txn_out]
create_bd_port -dir I -type clk tx_ref
connect_bd_net [get_bd_ports tx_ref] [get_bd_pins vphy/gtsouthrefclk0_in] [get_bd_pins vphy/gtsouthrefclk00_in] [get_bd_pins vphy/gtsouthrefclk01_in]
create_bd_port -dir I -type clk tx_ref_div
connect_bd_net [get_bd_ports tx_ref_div] [get_bd_pins vphy/gtsouthrefclk0_odiv2_in]
make_bd_pins_external -name tx_refclk_rdy [get_bd_pins vphy/tx_refclk_rdy]
make_bd_pins_external -name tx_hpd [get_bd_pins v_hdmi_tx_ss/hpd]
make_bd_intf_pins_external -name TX_DDC [get_bd_intf_pins v_hdmi_tx_ss/DDC_OUT]
make_bd_pins_external -name tx_aud_tdata [get_bd_pins v_hdmi_tx_ss/AUDIO_IN_tdata]
make_bd_pins_external -name tx_aud_tid [get_bd_pins v_hdmi_tx_ss/AUDIO_IN_tid]
make_bd_pins_external -name tx_aud_tvalid [get_bd_pins v_hdmi_tx_ss/AUDIO_IN_tvalid]
make_bd_pins_external -name tx_aud_tready [get_bd_pins v_hdmi_tx_ss/AUDIO_IN_tready]
make_bd_pins_external -name acr_n [get_bd_pins v_hdmi_tx_ss/acr_n]
make_bd_pins_external -name acr_cts [get_bd_pins v_hdmi_tx_ss/acr_cts]
make_bd_pins_external -name acr_valid [get_bd_pins v_hdmi_tx_ss/acr_valid]
make_bd_pins_external -name vid_tdata [get_bd_pins v_hdmi_rx_ss/VIDEO_OUT_tdata]
make_bd_pins_external -name vid_tuser [get_bd_pins v_hdmi_rx_ss/VIDEO_OUT_tuser]
make_bd_pins_external -name vid_tlast [get_bd_pins v_hdmi_rx_ss/VIDEO_OUT_tlast]
make_bd_pins_external -name aud_tdata [get_bd_pins v_hdmi_rx_ss/AUDIO_OUT_tdata]
make_bd_pins_external -name aud_tid [get_bd_pins v_hdmi_rx_ss/AUDIO_OUT_tid]
make_bd_pins_external -name aud_tvalid [get_bd_pins v_hdmi_rx_ss/AUDIO_OUT_tvalid]
make_bd_pins_external -name vid_tvalid [get_bd_pins v_hdmi_rx_ss/VIDEO_OUT_tvalid]
connect_bd_net [get_bd_pins vcc/dout] [get_bd_pins v_hdmi_rx_ss/VIDEO_OUT_tready]

# address map used by the firmware (fpga/hdmi/fw/hwmap.h)
assign_bd_address
foreach {cell off rng} {v_hdmi_tx_ss 0x44A20000 128K v_tpg 0x44A60000 64K v_hdmi_rx_ss 0x44A00000 64K vphy 0x44A70000 64K axi_iic_0 0x40800000 64K axi_gpio_0 0x40010000 64K axi_uartlite_0 0x40600000 64K axi_timer_0 0x41C00000 64K microblaze_0_axi_intc 0x41200000 64K} {
  foreach seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces microblaze_0/Data] -filter "NAME =~ *SEG_${cell}_*"] { set_property range $rng $seg; set_property offset $off $seg }
}
# 256 KB of local memory for the receiver + transmitter firmware (the automation offers at most 128 KB)
foreach sp {Data Instruction} { foreach seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces microblaze_0/$sp] -filter {NAME =~ *lmb_bram_if_cntlr*}] { set_property range 256K $seg } }
set seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces microblaze_0/Data] -filter {NAME =~ *M_META*}]
set_property range 64K $seg; set_property offset 0x44B00000 $seg
validate_bd_design
save_bd_design
puts "PORTS [get_bd_ports] IFS [get_bd_intf_ports]"
foreach s [get_bd_addr_segs -of_objects [get_bd_addr_spaces microblaze_0/Data]] { puts "SEG $s [get_property OFFSET $s] [get_property RANGE $s]" }
