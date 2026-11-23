// AXAU15 top: XDMA Gen3 x4 AXI-Stream + capture core + 297 MHz test clock.
`default_nettype none
module xcap_top (
  input  wire       pcie_ref_clk_p, pcie_ref_clk_n, pcie_rstn,
  input  wire [3:0] pcie_mgt_rxp, pcie_mgt_rxn,
  output wire [3:0] pcie_mgt_txp, pcie_mgt_txn,
  input  wire       clk_200m_p, clk_200m_n,
  output wire       led
);
  wire refclk, refclk_div, rstn;
  IBUFDS_GTE4 #(.REFCLK_HROW_CK_SEL(2'b00)) u_ref (.I(pcie_ref_clk_p), .IB(pcie_ref_clk_n), .CEB(1'b0), .O(refclk), .ODIV2(refclk_div));
  IBUF u_rst (.I(pcie_rstn), .O(rstn));

  // 200 MHz -> 297 MHz (4K60 at two pixels per clock)
  wire clk200, fb, fbo, v0, vclk, vlock;
  IBUFDS u_200 (.I(clk_200m_p), .IB(clk_200m_n), .O(clk200));
  MMCME4_BASE #(.CLKIN1_PERIOD(5.000), .DIVCLK_DIVIDE(5), .CLKFBOUT_MULT_F(37.125), .CLKOUT0_DIVIDE_F(5.0)) u_mmcm (
    .CLKIN1(clk200), .CLKFBIN(fb), .CLKFBOUT(fbo), .CLKFBOUTB(), .CLKOUT0(v0), .CLKOUT0B(), .CLKOUT1(), .CLKOUT1B(),
    .CLKOUT2(), .CLKOUT2B(), .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(), .LOCKED(vlock), .PWRDWN(1'b0), .RST(1'b0));
  BUFG u_fb (.I(fbo), .O(fb));
  BUFG u_v  (.I(v0),  .O(vclk));

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
  wire act;
  xcap_core #(.MCLK_HZ(297000000)) u_core (
    .aclk(aclk), .aresetn(aresetn), .vclk(vclk), .vlock(vlock),
    .ext_valid(1'b0), .ext_sof(1'b0), .ext_eol(1'b0), .ext_data(72'd0), .ext_meta(512'd0), .host_ctrl(), .tx_ctrl(), .edid_we(), .edid_wa(), .edid_wd(), .mclk(vclk), .mrst(1'b0), .aud_tdata(32'd0), .aud_tid(3'd0), .aud_tvalid(1'b0), .pt_vdrop(1'b0), .pt_adrop(1'b0),
    .s_awaddr(awaddr), .s_awvalid(awvalid), .s_awready(awready), .s_wdata(wdata), .s_wstrb(wstrb), .s_wvalid(wvalid), .s_wready(wready),
    .s_bresp(bresp), .s_bvalid(bvalid), .s_bready(bready), .s_araddr(araddr), .s_arvalid(arvalid), .s_arready(arready),
    .s_rdata(rdata), .s_rresp(rresp), .s_rvalid(rvalid), .s_rready(rready),
    .m_tdata(td), .m_tvalid(tv), .m_tlast(tl), .m_tready(tr), .a_tdata(atd), .a_tvalid(atv), .a_tlast(atl), .a_tready(atr), .activity(act));
  assign led = act ^ lnk_up;
endmodule
`default_nettype wire
