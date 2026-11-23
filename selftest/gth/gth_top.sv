// 12-lane GTH PRBS31 loopback BER test, 12.5 Gb/s, refclk 156.25 MHz (225 CLK1)
`timescale 1ns/1ps
module gth_top(input sys_clk_p, sys_clk_n, input refclk_p, refclk_n,
  input [11:0] gthrxn, gthrxp, output [11:0] gthtxn, gthtxp, output [1:0] led);
  wire ci, clk, ref_o;
  IBUFDS ib(.I(sys_clk_p), .IB(sys_clk_n), .O(ci));
  BUFGCE_DIV #(.BUFGCE_DIVIDE(2)) bd(.I(ci), .CE(1'b1), .CLR(1'b0), .O(clk));
  IBUFDS_GTE4 #(.REFCLK_HROW_CK_SEL(2'b00)) ig(.I(refclk_p), .IB(refclk_n), .CEB(1'b0), .O(ref_o), .ODIV2());
  wire rst_all, rx_rst, ferr, cres; wire [2:0] lb; wire [3:0] ps;
  wire txd, rxd; wire [11:0] lock, perr, pg, txpd, rxpd; wire txu2, rxu2, txact, rxact;
  reg [15:0] por=0; always @(posedge clk) if(!por[15]) por<=por+1; wire prst=!por[15];
  (* ASYNC_REG="true" *) reg [11:0] fe0=0, fe1=0; reg [11:0] fe2=0; always @(posedge txu2) begin fe0<={12{ferr}}; fe1<=fe0; fe2<=fe1; end
  (* ASYNC_REG="true" *) reg cr0=0, cr1=0; always @(posedge rxu2) begin cr0<=cres; cr1<=cr0; end
  gth_0 u(
    .gthrxn_in(gthrxn), .gthrxp_in(gthrxp), .gthtxn_out(gthtxn), .gthtxp_out(gthtxp),
    .gtwiz_userclk_tx_reset_in(~&txpd), .gtwiz_userclk_tx_srcclk_out(), .gtwiz_userclk_tx_usrclk_out(), .gtwiz_userclk_tx_usrclk2_out(txu2), .gtwiz_userclk_tx_active_out(txact),
    .gtwiz_userclk_rx_reset_in(~&rxpd), .gtwiz_userclk_rx_srcclk_out(), .gtwiz_userclk_rx_usrclk_out(), .gtwiz_userclk_rx_usrclk2_out(rxu2), .gtwiz_userclk_rx_active_out(rxact),
    .gtwiz_reset_clk_freerun_in(clk), .gtwiz_reset_all_in(rst_all|prst),
    .gtwiz_reset_tx_pll_and_datapath_in(1'b0), .gtwiz_reset_tx_datapath_in(1'b0),
    .gtwiz_reset_rx_pll_and_datapath_in(1'b0), .gtwiz_reset_rx_datapath_in(rx_rst),
    .gtwiz_reset_rx_cdr_stable_out(), .gtwiz_reset_tx_done_out(txd), .gtwiz_reset_rx_done_out(rxd),
    .gtwiz_userdata_tx_in(768'h0), .gtwiz_userdata_rx_out(),
    .gtrefclk00_in({3{ref_o}}), .qpll0outclk_out(), .qpll0outrefclk_out(),
    .loopback_in({12{lb}}), .rxprbscntreset_in({12{cr1}}), .rxprbssel_in({12{ps}}), .txprbssel_in({12{ps}}), .txprbsforceerr_in(fe2),
    .gtpowergood_out(pg), .rxpmaresetdone_out(rxpd), .txpmaresetdone_out(txpd), .rxprbserr_out(perr), .rxprbslocked_out(lock));
  reg [31:0] ec[0:11]; integer i; reg [11:0] pe=0, lk=0; reg [40:0] cyc=0;
  always @(posedge rxu2) begin
    pe<=perr; lk<=lock;
    if(cr1) begin for(i=0;i<12;i=i+1) ec[i]<=0; cyc<=0; end
    else begin cyc<=cyc+1; for(i=0;i<12;i=i+1) if(pe[i] && ~&ec[i]) ec[i]<=ec[i]+1; end
  end
  vio_g v(.clk, .probe_in0(txd), .probe_in1(rxd), .probe_in2(lk), .probe_in3(pg), .probe_in4(cyc),
   .probe_in5(ec[0]), .probe_in6(ec[1]), .probe_in7(ec[2]), .probe_in8(ec[3]), .probe_in9(ec[4]), .probe_in10(ec[5]),
   .probe_in11(ec[6]), .probe_in12(ec[7]), .probe_in13(ec[8]), .probe_in14(ec[9]), .probe_in15(ec[10]), .probe_in16(ec[11]),
   .probe_out0(rst_all), .probe_out1(rx_rst), .probe_out2(ferr), .probe_out3(cres), .probe_out4(lb), .probe_out5(ps));
  assign led={txd,rxd};
endmodule
