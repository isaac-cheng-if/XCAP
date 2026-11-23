## AXAU15 (XCAU15P-2FFVB676I) + RK-FH1159 : replacement for the seller's KU5P project top.xdc
## (ku5p/project_1.srcs/constrs_1/new/top.xdc). Port names are kept identical to that project's
## block design so this file can be dropped in unchanged.
##
## Sources: RK-FH1159 V1.0 FMC pin sheet + schematic, ALINX AXAU15 User Manual sections 2.3, 3.4, 3.5, 3.11.
## Not yet verified on hardware. Assumes AXAU15 VADJ = 1.8 V (default jumper).

# ----------------------------------------------------------------------------
# System clock 200 MHz (AXAU15 G1 oscillator) - Bank 65, 1.8 V
# Same pins as the KU5P board, but bank 65 is 1.8 V here, so DIFF_SSTL12 is replaced by LVDS.
# If ALINX's own AXAU15 examples use a different standard for SYS_CLK, follow theirs.
# ----------------------------------------------------------------------------
set_property PACKAGE_PIN T24 [get_ports clk_200M_clk_p]
set_property PACKAGE_PIN U24 [get_ports clk_200M_clk_n]
set_property IOSTANDARD LVDS [get_ports {clk_200M_clk_p clk_200M_clk_n}]

# ----------------------------------------------------------------------------
# UART (CP2102) - Bank 86, 3.3 V
# ----------------------------------------------------------------------------
set_property PACKAGE_PIN A12 [get_ports uart_rx]
set_property PACKAGE_PIN A13 [get_ports uart_tx]
set_property IOSTANDARD LVCMOS33 [get_ports {uart_rx uart_tx}]

# ----------------------------------------------------------------------------
# User LED1 - Bank 65, 1.8 V
# ----------------------------------------------------------------------------
set_property PACKAGE_PIN W21 [get_ports led]
set_property IOSTANDARD LVCMOS18 [get_ports led]

# ----------------------------------------------------------------------------
# RK-FH1159 low-speed control - FMC LA pins, Banks 64/65, 1.8 V
#                                                    FMC pin  RK net
# ----------------------------------------------------------------------------
set_property PACKAGE_PIN U22  [get_ports IDT_8T49N241_LOL_IN]     ;# G19 LA16_N 8T49N241_LOL
set_property PACKAGE_PIN N21  [get_ports RX_DET_IN]               ;# G9  LA03_P HDMI_RX_PWR_DET
set_property PACKAGE_PIN N22  [get_ports RX_HPD_OUT]              ;# G10 LA03_N HDMI_RX_HPD_F
set_property PACKAGE_PIN AA22 [get_ports TX_HPD_IN]               ;# G27 LA25_P TX_HPD_SRC_F
set_property PACKAGE_PIN R20  [get_ports {TX_EN_OUT_tri_o[0]}]    ;# G12 LA08_P HDMI_TX_EN_F
set_property PACKAGE_PIN AF17 [get_ports {TX_EN_OUT_tri_o[1]}]    ;# G22 LA20_N 8T49N241_RST (seller drives it from TX_EN bit 1)
set_property PACKAGE_PIN U21  [get_ports iic_dp159_scl_io]        ;# G18 LA16_P HDMI_CTL_SCL_F (DP159 + TMDS181 + 8T49N241)
set_property PACKAGE_PIN R23  [get_ports iic_dp159_sda_io]        ;# G16 LA12_N HDMI_CTL_SDA_F
set_property PACKAGE_PIN AC17 [get_ports RX_DDC_OUT_scl_io]       ;# G25 LA22_N HDMI_RX_SNK_SCL (EDID slave)
set_property PACKAGE_PIN AB17 [get_ports RX_DDC_OUT_sda_io]       ;# G24 LA22_P HDMI_RX_SNK_SDA
set_property PACKAGE_PIN R21  [get_ports TX_DDC_OUT_scl_io]       ;# G13 LA08_N HDMI_TX_SRC_SCL_F
set_property PACKAGE_PIN R22  [get_ports TX_DDC_OUT_sda_io]       ;# G15 LA12_P HDMI_TX_SRC_SDA_F

set_property IOSTANDARD LVCMOS18 [get_ports {IDT_8T49N241_LOL_IN RX_DET_IN RX_HPD_OUT TX_HPD_IN \
    {TX_EN_OUT_tri_o[*]} iic_dp159_scl_io iic_dp159_sda_io RX_DDC_OUT_scl_io RX_DDC_OUT_sda_io \
    TX_DDC_OUT_scl_io TX_DDC_OUT_sda_io}]
set_property DRIVE 12 [get_ports {RX_HPD_OUT {TX_EN_OUT_tri_o[*]}}]
set_property SLEW SLOW [get_ports {iic_dp159_scl_io iic_dp159_sda_io RX_DDC_OUT_scl_io RX_DDC_OUT_sda_io \
    TX_DDC_OUT_scl_io TX_DDC_OUT_sda_io}]
set_property PULLUP true [get_ports {iic_dp159_scl_io iic_dp159_sda_io TX_DDC_OUT_scl_io TX_DDC_OUT_sda_io}]

# Recovered RX clock out to 8T49N241 CLK0 (100R termination on the card) - FMC G6/G7 LA00_CC, Bank 65
set_property PACKAGE_PIN V23 [get_ports RX_REFCLK_P_OUT]
set_property IOSTANDARD LVDS [get_ports RX_REFCLK_P_OUT]

# ----------------------------------------------------------------------------
# GTH - HDMI lanes in Quad 225 (Vid PHY CHANNEL_SITE should be the Quad 225 channel 0 site,
# expected GTHE4_CHANNEL_X0Y4 because PCIe sits in Quad 224 - confirm in Vivado's device view)
# ----------------------------------------------------------------------------
# HDMI TX D0/D1/D2/CLK : FMC DP0..DP3 C2M -> 225 TX0..TX3
set_property PACKAGE_PIN AA5 [get_ports {HDMI_TX_DAT_P_OUT[0]}]
set_property PACKAGE_PIN W5  [get_ports {HDMI_TX_DAT_P_OUT[1]}]
set_property PACKAGE_PIN U5  [get_ports {HDMI_TX_DAT_P_OUT[2]}]
set_property PACKAGE_PIN R5  [get_ports {HDMI_TX_DAT_P_OUT[3]}]

# HDMI RX D0/D1/D2 : FMC DP0..DP2 M2C -> 225 RX0..RX2
set_property PACKAGE_PIN Y2 [get_ports {HDMI_RX_DAT_P_IN[0]}]
set_property PACKAGE_PIN V2 [get_ports {HDMI_RX_DAT_P_IN[1]}]
set_property PACKAGE_PIN T2 [get_ports {HDMI_RX_DAT_P_IN[2]}]

# RX TMDS clock : FMC GBTCLK0 -> 225 MGTREFCLK0  (Vid PHY RX refclk = GTREFCLK0, as in the KU5P project)
set_property PACKAGE_PIN V7 [get_ports HDMI_RX_CLK_P_IN]

# TX refclk from 8T49N241 : FMC GBTCLK1 -> 226 MGTREFCLK0, one quad above the lanes
# (Vid PHY TX refclk = GTSOUTHREFCLK0, the same relative setting the KU5P project uses: C_TX_REFCLK_SEL = 4)
set_property PACKAGE_PIN P7 [get_ports TX_REFCLK_P_IN]
