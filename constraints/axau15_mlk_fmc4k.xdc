## AXAU15 (XCAU15P-2FFVB676I) + MILIANKE FMC_4K (schematic V_FMC_3001_1122, 2022-11-22)
## Port names reuse the seller's KU5P project (ku5p/top.xdc) so the same block design can be retargeted.
## Not yet verified on hardware. Assumes AXAU15 VADJ = 1.8 V (card's "VCC_1V8" rail is FMC VADJ).
##
## Differences vs RK-FH1159:
##   - GT lanes / GBTCLK usage is IDENTICAL (so the GT section below is the same as axau15_top_from_ku5p.xdc)
##   - LA pin assignment is different (every control signal moved)
##   - Clock chip is Si5319C (I2C 0x68, A0..A2 = GND, 114.285 MHz crystal) instead of 8T49N241
##   - Extra PWR_EN on LA29_P: card regulators are DISABLED only when PWR_EN > ~2 V (LM393 vs 3V3*10/16.49).
##     A 1.8 V bank can never reach that, and there is a 100k pull-down, so the card is always enabled.
##     Leave it unconnected, or drive it low.

# ----------------------------------------------------------------------------
# AXAU15 board resources
# ----------------------------------------------------------------------------
set_property PACKAGE_PIN T24 [get_ports clk_200M_clk_p]
set_property PACKAGE_PIN U24 [get_ports clk_200M_clk_n]
set_property IOSTANDARD LVDS [get_ports {clk_200M_clk_p clk_200M_clk_n}]
set_property PACKAGE_PIN A12 [get_ports uart_rx]
set_property PACKAGE_PIN A13 [get_ports uart_tx]
set_property IOSTANDARD LVCMOS33 [get_ports {uart_rx uart_tx}]
set_property PACKAGE_PIN W21 [get_ports led]
set_property IOSTANDARD LVCMOS18 [get_ports led]

# ----------------------------------------------------------------------------
# MILIANKE FMC_4K low-speed control - FMC LA pins, Banks 64/65, 1.8 V
#                                                    FMC pin  MLK net
# ----------------------------------------------------------------------------
set_property PACKAGE_PIN N21  [get_ports RX_HPD_OUT]              ;# G9  LA03_P HDMI_RX_HPD_F1V8
set_property PACKAGE_PIN N22  [get_ports {TX_EN_OUT_tri_o[1]}]    ;# G10 LA03_N HDMI_SI5319C_RST_F1V8 (active low)
set_property PACKAGE_PIN R20  [get_ports SI5319_INT_ALM_IN]       ;# G12 LA08_P HDMI_SI5319C_INT_ALM_F1V8 (optional)
set_property PACKAGE_PIN R21  [get_ports IDT_8T49N241_LOL_IN]     ;# G13 LA08_N HDMI_SI5319C_LOL_F1V8 (Si5319 LOL, active high)
set_property PACKAGE_PIN R22  [get_ports RX_DET_IN]               ;# G15 LA12_P HDMI_RX_PWR_DET_F1V8
set_property PACKAGE_PIN R23  [get_ports TX_HPD_IN]               ;# G16 LA12_N HDMI_TX_HPD_F1V8
set_property PACKAGE_PIN U21  [get_ports TX_CEC_OUT]              ;# G18 LA16_P HDMI_TX_CEC_F1V8 (optional)
set_property PACKAGE_PIN U22  [get_ports {TX_EN_OUT_tri_o[0]}]    ;# G19 LA16_N HDMI_TX_EN_F1V8 (SN65DP159 OE)
set_property PACKAGE_PIN AE17 [get_ports TX_DDC_OUT_scl_io]       ;# G21 LA20_P HDMI_TX_SRC_SCL_F1V8
set_property PACKAGE_PIN AF17 [get_ports TX_DDC_OUT_sda_io]       ;# G22 LA20_N HDMI_TX_SRC_SDA_F1V8
set_property PACKAGE_PIN AB17 [get_ports iic_dp159_scl_io]        ;# G24 LA22_P HDMI_CTL_SCL_F1V8 (DP159 + TMDS181 + Si5319 + M24C64)
set_property PACKAGE_PIN AC17 [get_ports iic_dp159_sda_io]        ;# G25 LA22_N HDMI_CTL_SDA_F1V8
set_property PACKAGE_PIN AA22 [get_ports RX_DDC_OUT_scl_io]       ;# G27 LA25_P HDMI_RX_SNK_SCL (EDID slave, via TCA9406)
set_property PACKAGE_PIN AB22 [get_ports RX_DDC_OUT_sda_io]       ;# G28 LA25_N HDMI_RX_SNK_SDA
# set_property PACKAGE_PIN AE25 [get_ports FMC_PWR_EN]            ;# G30 LA29_P PWR_EN - see note above, drive 0 if used

set_property IOSTANDARD LVCMOS18 [get_ports {RX_HPD_OUT {TX_EN_OUT_tri_o[*]} SI5319_INT_ALM_IN IDT_8T49N241_LOL_IN \
    RX_DET_IN TX_HPD_IN TX_CEC_OUT TX_DDC_OUT_scl_io TX_DDC_OUT_sda_io iic_dp159_scl_io iic_dp159_sda_io \
    RX_DDC_OUT_scl_io RX_DDC_OUT_sda_io}]
set_property DRIVE 12 [get_ports {RX_HPD_OUT {TX_EN_OUT_tri_o[*]}}]
set_property SLEW SLOW [get_ports {iic_dp159_scl_io iic_dp159_sda_io RX_DDC_OUT_scl_io RX_DDC_OUT_sda_io \
    TX_DDC_OUT_scl_io TX_DDC_OUT_sda_io}]
set_property PULLUP true [get_ports {iic_dp159_scl_io iic_dp159_sda_io TX_DDC_OUT_scl_io TX_DDC_OUT_sda_io}]

# Recovered RX clock out to Si5319 CKIN1 (100R termination on card) - FMC G6/G7 LA00_CC, Bank 65
set_property PACKAGE_PIN V23 [get_ports RX_REFCLK_P_OUT]
set_property IOSTANDARD LVDS [get_ports RX_REFCLK_P_OUT]

# ----------------------------------------------------------------------------
# GTH - identical to the RK-FH1159 mapping (Quad 225 lanes, refclks on 225/226)
# ----------------------------------------------------------------------------
set_property PACKAGE_PIN AA5 [get_ports {HDMI_TX_DAT_P_OUT[0]}]   ;# DP0_C2M HDMI_TX0
set_property PACKAGE_PIN W5  [get_ports {HDMI_TX_DAT_P_OUT[1]}]   ;# DP1_C2M HDMI_TX1
set_property PACKAGE_PIN U5  [get_ports {HDMI_TX_DAT_P_OUT[2]}]   ;# DP2_C2M HDMI_TX2
set_property PACKAGE_PIN R5  [get_ports {HDMI_TX_DAT_P_OUT[3]}]   ;# DP3_C2M HDMI_TX_OUT (TMDS clock)
set_property PACKAGE_PIN Y2  [get_ports {HDMI_RX_DAT_P_IN[0]}]    ;# DP0_M2C HDMI_RX0
set_property PACKAGE_PIN V2  [get_ports {HDMI_RX_DAT_P_IN[1]}]    ;# DP1_M2C HDMI_RX1
set_property PACKAGE_PIN T2  [get_ports {HDMI_RX_DAT_P_IN[2]}]    ;# DP2_M2C HDMI_RX2
set_property PACKAGE_PIN V7  [get_ports HDMI_RX_CLK_P_IN]         ;# GBTCLK0 -> 225 MGTREFCLK0 (RX TMDS clock)
set_property PACKAGE_PIN P7  [get_ports TX_REFCLK_P_IN]           ;# GBTCLK1 -> 226 MGTREFCLK0 (Si5319 CKOUT1)
