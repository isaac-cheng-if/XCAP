// AXAU15 + HDMI 2.0 FMC card: HDMI receiver and test pattern into the same capture core, and an HDMI
// transmitter (test pattern, HDR10 infoframes, counting audio) for loopback tests with a cable OUT -> IN.
`default_nettype none
module xcap_hdmi_top (
  input  wire       pcie_ref_clk_p, pcie_ref_clk_n, pcie_rstn,
  input  wire [3:0] pcie_mgt_rxp, pcie_mgt_rxn,
  output wire [3:0] pcie_mgt_txp, pcie_mgt_txn,
  input  wire       clk_200m_p, clk_200m_n,
  output wire       led,
  input  wire [2:0] HDMI_RX_DAT_P_IN, HDMI_RX_DAT_N_IN,
  input  wire       HDMI_RX_CLK_P_IN, HDMI_RX_CLK_N_IN,
  output wire       RX_REFCLK_P_OUT, RX_REFCLK_N_OUT,
  input  wire       RX_DET_IN,
  output wire       RX_HPD_OUT,
  output wire [1:0] TX_EN_OUT_tri_o,
  output wire [3:0] HDMI_TX_DAT_P_OUT, HDMI_TX_DAT_N_OUT,
  input  wire       TX_REFCLK_P_IN, TX_REFCLK_N_IN,
  input  wire       TX_HPD_IN, IDT_LOL_IN,
  inout  wire       TX_DDC_OUT_scl_io, TX_DDC_OUT_sda_io,
  inout  wire       RX_DDC_OUT_scl_io, RX_DDC_OUT_sda_io,
  inout  wire       iic_dp159_scl_io, iic_dp159_sda_io,
  input  wire       uart_rx,
  output wire       uart_tx
);
  wire refclk, refclk_div, rstn;
  // TX GT reference (8T49N241) arrives in the quad above the HDMI lanes
  wire txref, txref_div, txref_bufg;
  IBUFDS_GTE4 #(.REFCLK_HROW_CK_SEL(2'b00)) u_txref (.I(TX_REFCLK_P_IN), .IB(TX_REFCLK_N_IN), .CEB(1'b0), .O(txref), .ODIV2(txref_div));
  BUFG_GT u_txref_bufg (.I(txref_div), .CE(1'b1), .CEMASK(1'b0), .CLR(1'b0), .CLRMASK(1'b0), .DIV(3'd0), .O(txref_bufg));
  IBUFDS_GTE4 #(.REFCLK_HROW_CK_SEL(2'b00)) u_ref (.I(pcie_ref_clk_p), .IB(pcie_ref_clk_n), .CEB(1'b0), .O(refclk), .ODIV2(refclk_div));
  IBUF u_rst (.I(pcie_rstn), .O(rstn));

  // 200 MHz -> 300 MHz video processing clock, 100 MHz MicroBlaze
  wire clk200, fb, fbo, v0, m0, vclk, mclk, vlock;
  IBUFDS u_200 (.I(clk_200m_p), .IB(clk_200m_n), .O(clk200));
  MMCME4_BASE #(.CLKIN1_PERIOD(5.000), .DIVCLK_DIVIDE(1), .CLKFBOUT_MULT_F(6.0), .CLKOUT0_DIVIDE_F(4.0), .CLKOUT1_DIVIDE(12)) u_mmcm (
    .CLKIN1(clk200), .CLKFBIN(fb), .CLKFBOUT(fbo), .CLKFBOUTB(), .CLKOUT0(v0), .CLKOUT0B(), .CLKOUT1(m0), .CLKOUT1B(),
    .CLKOUT2(), .CLKOUT2B(), .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(), .LOCKED(vlock), .PWRDWN(1'b0), .RST(1'b0));
  BUFG u_fb (.I(fbo), .O(fb));
  BUFG u_v  (.I(v0),  .O(vclk));
  BUFG u_m  (.I(m0),  .O(mclk));

  wire aclk, aresetn, lnk_up;
  wire [31:0] awaddr, wdata, araddr, rdata; wire [3:0] wstrb; wire [1:0] bresp, rresp;
  wire awvalid, awready, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rready;
  wire [127:0] td; wire tv, tl, tr;
  wire [127:0] atd; wire atv, atl, atr;
  xdma_0 u_xdma (
    .sys_clk(refclk_div), .sys_clk_gt(refclk), .sys_rst_n(rstn), .user_lnk_up(lnk_up),
    .pci_exp_txp(pcie_mgt_txp), .pci_exp_txn(pcie_mgt_txn), .pci_exp_rxp(pcie_mgt_rxp), .pci_exp_rxn(pcie_mgt_rxn),
    .axi_aclk(aclk), .axi_aresetn(aresetn),
    .usr_irq_req(1'b0), .usr_irq_ack(), .msi_enable(), .msi_vector_width(),
    .m_axil_awaddr(awaddr), .m_axil_awprot(), .m_axil_awvalid(awvalid), .m_axil_awready(awready),
    .m_axil_wdata(wdata), .m_axil_wstrb(wstrb), .m_axil_wvalid(wvalid), .m_axil_wready(wready),
    .m_axil_bvalid(bvalid), .m_axil_bresp(bresp), .m_axil_bready(bready),
    .m_axil_araddr(araddr), .m_axil_arprot(), .m_axil_arvalid(arvalid), .m_axil_arready(arready),
    .m_axil_rdata(rdata), .m_axil_rresp(rresp), .m_axil_rvalid(rvalid), .m_axil_rready(rready),
    .s_axis_c2h_tdata_0(td), .s_axis_c2h_tlast_0(tl), .s_axis_c2h_tvalid_0(tv), .s_axis_c2h_tready_0(tr), .s_axis_c2h_tkeep_0(16'hFFFF),
    .s_axis_c2h_tdata_1(atd), .s_axis_c2h_tlast_1(atl), .s_axis_c2h_tvalid_1(atv), .s_axis_c2h_tready_1(atr), .s_axis_c2h_tkeep_1(16'hFFFF),
    .m_axis_h2c_tdata_0(), .m_axis_h2c_tlast_0(), .m_axis_h2c_tvalid_0(), .m_axis_h2c_tready_0(1'b1), .m_axis_h2c_tkeep_0()
  );

  wire [31:0] tctl, an, acts, arate, acfg, ta_d; wire [7:0] ta_id; wire ta_v, ta_r;
  // loop-out (aud_cfg bit 8: picture, bit 9: sound of the receiver to the transmitter)
  wire [31:0] ga_d; wire [7:0] ga_id; wire ga_v, ga_r;          // test sound generator
  wire [31:0] pa_d; wire [2:0] pa_id; wire pa_v, pa_r;          // receiver sound copy
  wire [71:0] pt_d; wire pt_sof, pt_eol, pt_v, pt_r; wire [15:0] pt_drops; wire pt_vdrop, pt_adrop;
  wire [31:0] astat;                                            // what the receiver's sound is, for the firmware
  wire [31:0] ma, mr, mw, mrd, hctl; wire [2:0] mp0, mp1; wire [3:0] ms; wire [1:0] mb, mrr;
  wire mav, mar, mwv, mwr, mbv, mbr, mrv, mrdy, marv, marr;
  wire [511:0] hmeta;
  wire [31:0] aud_d; wire [2:0] aud_id; wire aud_v;
  wire [71:0] vd; wire vu, vl, vv; wire [3:0] gpio;
  // HDMI link data, routed through here so xcap_linkcap (in u_meta) can take snapshots of it
  wire [39:0] tl0, tl1, tl2, rl0, rl1, rl2; wire tlv0, tlv1, tlv2, rlv0, rlv1, rlv2, tlclk, rlclk;
  hdmi_sys_wrapper u_hdmi (
    .tx_link0_tdata(tl0), .tx_link0_tvalid(tlv0), .tx_link1_tdata(tl1), .tx_link1_tvalid(tlv1), .tx_link2_tdata(tl2), .tx_link2_tvalid(tlv2),
    .phy_tx0_tdata(tl0), .phy_tx0_tvalid(tlv0), .phy_tx0_tready(), .phy_tx1_tdata(tl1), .phy_tx1_tvalid(tlv1), .phy_tx1_tready(),
    .phy_tx2_tdata(tl2), .phy_tx2_tvalid(tlv2), .phy_tx2_tready(),
    .phy_rx0_tdata(rl0), .phy_rx0_tvalid(rlv0), .phy_rx0_tready(1'b1), .phy_rx1_tdata(rl1), .phy_rx1_tvalid(rlv1), .phy_rx1_tready(1'b1),
    .phy_rx2_tdata(rl2), .phy_rx2_tvalid(rlv2), .phy_rx2_tready(1'b1),
    .rx_link0_tdata(rl0), .rx_link0_tvalid(rlv0), .rx_link1_tdata(rl1), .rx_link1_tvalid(rlv1), .rx_link2_tdata(rl2), .rx_link2_tvalid(rlv2),
    .tx_link_clk(tlclk), .rx_link_clk(rlclk),
    .clk_100(mclk), .clk_300(vclk), .clk_locked(vlock),
    .CTL_IIC_scl_io(iic_dp159_scl_io), .CTL_IIC_sda_io(iic_dp159_sda_io),
    .RX_DDC_scl_io(RX_DDC_OUT_scl_io), .RX_DDC_sda_io(RX_DDC_OUT_sda_io),
    .UART_rxd(uart_rx), .UART_txd(uart_tx), .gpio_o(gpio), .rx_hpd(RX_HPD_OUT), .rx_det(RX_DET_IN),
    .hdmi_rxp(HDMI_RX_DAT_P_IN), .hdmi_rxn(HDMI_RX_DAT_N_IN), .hdmi_clk_p(HDMI_RX_CLK_P_IN), .hdmi_clk_n(HDMI_RX_CLK_N_IN),
    .rx_refclk_p(RX_REFCLK_P_OUT), .rx_refclk_n(RX_REFCLK_N_OUT),
    .hdmi_txp(HDMI_TX_DAT_P_OUT), .hdmi_txn(HDMI_TX_DAT_N_OUT), .tx_ref(txref), .tx_ref_div(txref_bufg), .tx_refclk_rdy(IDT_LOL_IN), .tx_hpd(TX_HPD_IN),
    .TX_DDC_scl_io(TX_DDC_OUT_scl_io), .TX_DDC_sda_io(TX_DDC_OUT_sda_io),
    .tx_aud_tdata(ta_d), .tx_aud_tid(ta_id), .tx_aud_tvalid(ta_v), .tx_aud_tready(ta_r),
    .pt_tdata(pt_d), .pt_tuser(pt_sof), .pt_tlast(pt_eol), .pt_tvalid(pt_v), .pt_tready(pt_r), .acr_n(an[19:0]), .acr_cts(acts[19:0]), .acr_valid(acfg[0]),
    .vid_tdata(vd), .vid_tuser(vu), .vid_tlast(vl), .vid_tvalid(vv), .aud_tdata(aud_d), .aud_tid(aud_id), .aud_tvalid(aud_v),
    .M_META_awaddr(ma), .M_META_awprot(mp0), .M_META_awvalid(mav), .M_META_awready(mar),
    .M_META_wdata(mw), .M_META_wstrb(ms), .M_META_wvalid(mwv), .M_META_wready(mwr),
    .M_META_bresp(mb), .M_META_bvalid(mbv), .M_META_bready(mbr),
    .M_META_araddr(mr), .M_META_arprot(mp1), .M_META_arvalid(marv), .M_META_arready(marr),
    .M_META_rdata(mrd), .M_META_rresp(mrr), .M_META_rvalid(mrv), .M_META_rready(mrdy));
  assign TX_EN_OUT_tri_o = gpio[1:0];
  xcap_txaudio u_txaud (.clk(mclk), .rst(~vlock), .en(acfg[1]), .channels(acfg[7:4]), .rate(arate),
    .tdata(ga_d), .tid(ga_id), .tvalid(ga_v), .tready(ga_r));
  xcap_ptaudio u_pta (.clk(mclk), .en(acfg[9]), .d(aud_d), .id(aud_id), .valid(aud_v), .q(pa_d), .q_id(pa_id), .q_valid(pa_v), .q_ready(pa_r), .drop_t(pt_adrop));
  xcap_audfmt u_afmt (.clk(mclk), .d(aud_d), .id(aud_id), .valid(aud_v), .stat(astat));
  assign ta_d  = acfg[9] ? pa_d : ga_d;
  assign ta_id = acfg[9] ? {5'd0, pa_id} : ga_id;
  assign ta_v  = acfg[9] ? pa_v : ga_v;
  assign pa_r  = acfg[9] & ta_r;
  assign ga_r  = !acfg[9] & ta_r;
  // the receiver's picture in its own packing (not the capture remap below) for the transmitter
  xcap_ptvideo u_ptv (.clk(vclk), .en(acfg[8]), .d(vd), .sof(vu), .eol(vl), .valid(vv),
    .q(pt_d), .q_sof(pt_sof), .q_eol(pt_eol), .q_valid(pt_v), .q_ready(pt_r), .drops(pt_drops), .drop_t(pt_vdrop));
  wire ewe; wire [5:0] ewa; wire [31:0] ewd;
  xcap_meta_regs u_meta (.clk(mclk), .rstn(vlock), .s_awaddr(ma), .s_awvalid(mav), .s_awready(mar), .s_wdata(mw), .s_wvalid(mwv), .s_wready(mwr),
    .s_bresp(mb), .s_bvalid(mbv), .s_bready(mbr), .s_araddr(mr), .s_arvalid(marv), .s_arready(marr),
    .s_rdata(mrd), .s_rresp(mrr), .s_rvalid(mrv), .s_rready(mrdy), .aclk(aclk), .host_ctrl(hctl), .tx_ctrl(tctl), .aud_n(an), .aud_cts(acts), .aud_rate(arate), .aud_cfg(acfg), .aud_stat(astat), .meta(hmeta), .edid_we(ewe), .edid_wa(ewa), .edid_wd(ewd),
    .cap_tclk(tlclk), .cap_td({tl2[19:0], tl1[19:0], tl0[19:0]}), .cap_rclk(rlclk), .cap_rd({rl2[19:0], rl1[19:0], rl0[19:0]}));

  // The HDMI receiver packs YCbCr 4:2:2 as two components per pixel: {Cr, Y1, Cb, Y0} in bits 47:0 (measured on a PS5,
  // 2026-11-23). The capture core expects three per pixel ({-, C, Y} each), so spread it out. Colour comes from the
  // firmware's state word (meta word 10, bits 3:1, 1 = 4:2:2); it only changes with the signal format.
  wire [2:0] cs_v;
  xpm_cdc_array_single #(.DEST_SYNC_FF(3), .WIDTH(3), .SRC_INPUT_REG(0)) u_cs (.src_clk(aclk), .src_in(hmeta[32*10+3:32*10+1]), .dest_clk(vclk), .dest_out(cs_v));
  wire [71:0] vdx = (cs_v == 3'd1) ? {12'd0, vd[47:36], vd[35:24], 12'd0, vd[23:12], vd[11:0]} : vd;
  wire act;
  xcap_core #(.FIFO_DEPTH(4096), .VCLK_HZ(300000000)) u_core (
    .aclk(aclk), .aresetn(aresetn), .vclk(vclk), .vlock(vlock),
    .ext_valid(vv), .ext_sof(vu), .ext_eol(vl), .ext_data(vdx), .ext_meta(hmeta), .host_ctrl(hctl), .tx_ctrl(tctl), .edid_we(ewe), .edid_wa(ewa), .edid_wd(ewd),
    .mclk(mclk), .mrst(~vlock), .aud_tdata(aud_d), .aud_tid(aud_id), .aud_tvalid(aud_v), .pt_vdrop(pt_vdrop), .pt_adrop(pt_adrop),
    .s_awaddr(awaddr), .s_awvalid(awvalid), .s_awready(awready), .s_wdata(wdata), .s_wstrb(wstrb), .s_wvalid(wvalid), .s_wready(wready),
    .s_bresp(bresp), .s_bvalid(bvalid), .s_bready(bready), .s_araddr(araddr), .s_arvalid(arvalid), .s_arready(arready),
    .s_rdata(rdata), .s_rresp(rresp), .s_rvalid(rvalid), .s_rready(rready),
    .m_tdata(td), .m_tvalid(tv), .m_tlast(tl), .m_tready(tr), .a_tdata(atd), .a_tvalid(atv), .a_tlast(atl), .a_tready(atr), .activity(act));
  assign led = act ^ lnk_up;
endmodule
`default_nettype wire
