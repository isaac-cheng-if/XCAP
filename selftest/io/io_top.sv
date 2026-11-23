// AXAU15 low-speed / IO self-test, registers over JTAG-AXI
`timescale 1ns/1ps
module io_top #(parameter N=140)(
  input sys_clk_p, sys_clk_n,
  input key1, key2, sd_cd, fmc_prsnt, pcie_perst,
  output [1:0] led,
  inout eep_scl, eep_sda, fmc_scl, fmc_sda,
  output sd_clk, inout sd_cmd, inout sd_d0, sd_d1, sd_d2, output sd_d3,
  output phy_rst, phy_mdc, inout phy_mdio, input phy_rxc,
  input uart_rxd, output uart_txd,
  inout [N-1:0] pin,
  input gt225_clk1_p, gt225_clk1_n, gt225_clk0_p, gt225_clk0_n, gt226_clk0_p, gt226_clk0_n, gt224_clk0_p, gt224_clk0_n
);
  wire clk_i, clk200, clk;
  IBUFDS u_ib(.I(sys_clk_p), .IB(sys_clk_n), .O(clk_i));
  BUFG u_bg(.I(clk_i), .O(clk200));
  BUFGCE_DIV #(.BUFGCE_DIVIDE(2)) u_bd(.I(clk_i), .CE(1'b1), .CLR(1'b0), .O(clk));
  reg [7:0] rsh=0; always @(posedge clk) rsh<={rsh[6:0],1'b1}; wire rstn=rsh[7];

  // ---------------- AXI4-Lite via JTAG -----------------
  wire [31:0] awaddr, wdata, araddr; reg [31:0] rdata; wire awvalid, wvalid, arvalid, bready, rready; reg bvalid=0, rvalid=0;
  wire [2:0] p0,p1; wire [3:0] ws; wire awready, wready, arready;
  jtag_axi_0 u_j(.aclk(clk), .aresetn(rstn),
    .m_axi_awaddr(awaddr), .m_axi_awprot(p0), .m_axi_awvalid(awvalid), .m_axi_awready(awready),
    .m_axi_wdata(wdata), .m_axi_wstrb(ws), .m_axi_wvalid(wvalid), .m_axi_wready(wready),
    .m_axi_bresp(2'b00), .m_axi_bvalid(bvalid), .m_axi_bready(bready),
    .m_axi_araddr(araddr), .m_axi_arprot(p1), .m_axi_arvalid(arvalid), .m_axi_arready(arready),
    .m_axi_rdata(rdata), .m_axi_rresp(2'b00), .m_axi_rvalid(rvalid), .m_axi_rready(rready));
  wire wgo = awvalid && wvalid && !bvalid; assign awready=wgo, wready=wgo;
  wire rgo = arvalid && !rvalid; assign arready=rgo;
  always @(posedge clk) begin
    if(wgo) bvalid<=1; else if(bready) bvalid<=0;
    if(rgo) rvalid<=1; else if(rready) rvalid<=0;
  end

  // ---------------- control regs ------------------------
  reg [31:0] ctl=0, i2c=0, ser_ctl=0, ser_div=100; reg [63:0] so=0, soe=0; reg ser_go=0;
  reg [159:0] po=0, poe=0; reg [31:0] sc_ctl=0; reg sc_go=0;
  always @(posedge clk) begin
    ser_go<=0; sc_go<=0;
    if(wgo) case(awaddr[11:0])
      12'h004: ctl<=wdata;
      12'h00c: i2c<=wdata;
      12'h040: begin ser_ctl<=wdata; ser_go<=wdata[31]; end
      12'h044: ser_div<=wdata;
      12'h048: so[31:0]<=wdata;   12'h04c: so[63:32]<=wdata;
      12'h050: soe[31:0]<=wdata;  12'h054: soe[63:32]<=wdata;
      12'h100: po[31:0]<=wdata; 12'h104: po[63:32]<=wdata; 12'h108: po[95:64]<=wdata; 12'h10c: po[127:96]<=wdata; 12'h110: po[159:128]<=wdata;
      12'h120: poe[31:0]<=wdata; 12'h124: poe[63:32]<=wdata; 12'h128: poe[95:64]<=wdata; 12'h12c: poe[127:96]<=wdata; 12'h130: poe[159:128]<=wdata;
      12'h160: begin sc_ctl<=wdata; sc_go<=wdata[31]; end
      default: ;
    endcase
  end
  assign led = ctl[1:0];
  assign phy_rst = ctl[8];
  assign uart_txd = uart_rxd;
  // ---------------- open-drain i2c bit-bang -------------
  wire eep_scl_i, eep_sda_i, fmc_scl_i, fmc_sda_i;
  IOBUF b0(.IO(eep_scl), .I(1'b0), .T(~i2c[0]), .O(eep_scl_i));
  IOBUF b1(.IO(eep_sda), .I(1'b0), .T(~i2c[1]), .O(eep_sda_i));
  IOBUF b2(.IO(fmc_scl), .I(1'b0), .T(~i2c[2]), .O(fmc_scl_i));
  IOBUF b3(.IO(fmc_sda), .I(1'b0), .T(~i2c[3]), .O(fmc_sda_i));
  // ---------------- serial engine (mode 0) --------------
  // ser_ctl: [6:0] nbits, [9:8] target 0=QSPI 1=SD 2=MDIO
  reg busy=0, sck=0; reg [31:0] dv=0; reg [6:0] nb=0; reg [63:0] sh=0, she=0, si=0; wire sin;
  wire [1:0] tgt=ser_ctl[9:8];
  always @(posedge clk) begin
    if(ser_go) begin busy<=1; sck<=0; dv<=0; nb<=ser_ctl[6:0]; sh<=so; she<=soe; si<=0; end
    else if(busy) begin
      if(dv>=ser_div) begin dv<=0;
        if(!sck) begin sck<=1; si<={si[62:0],sin}; end
        else begin sck<=0; sh<={sh[62:0],1'b1}; she<={she[62:0],1'b0}; nb<=nb-1; if(nb==1) busy<=0; end
      end else dv<=dv+1;
    end
  end
  wire mo=sh[63], moe=she[63]&busy;
  wire [3:0] qdi; wire sd_cmd_i, sd_d0_i, sd_d1_i, sd_d2_i, mdio_i;
  assign sin = (tgt==0)? qdi[1] : (tgt==1)? sd_d0_i : mdio_i;
  STARTUPE3 #(.PROG_USR("FALSE"), .SIM_CCLK_FREQ(0.0)) u_st(
    .CFGCLK(), .CFGMCLK(), .DI(qdi), .EOS(), .PREQ(), .DO({2'b11,1'b0,(tgt==0)&mo}), .DTS({2'b00,1'b1,1'b0}),
    .FCSBO(~(ctl[16])), .FCSBTS(1'b0), .GSR(1'b0), .GTS(1'b0), .KEYCLEARB(1'b1), .PACK(1'b0),
    .USRCCLKO((tgt==0)&sck), .USRCCLKTS(1'b0), .USRDONEO(1'b1), .USRDONETS(1'b1));
  assign sd_clk=(tgt==1)&sck, sd_d3=~ctl[17];
  IOBUF b4(.IO(sd_cmd), .I(tgt==1 ? mo : 1'b1), .T(1'b0), .O(sd_cmd_i));
  IOBUF b5(.IO(sd_d0), .I(1'b1), .T(1'b1), .O(sd_d0_i));
  IOBUF b6(.IO(sd_d1), .I(1'b1), .T(1'b1), .O(sd_d1_i));
  IOBUF b7(.IO(sd_d2), .I(1'b1), .T(1'b1), .O(sd_d2_i));
  assign phy_mdc=(tgt==2)&sck;
  IOBUF b8(.IO(phy_mdio), .I(mo), .T(~(moe&&tgt==2)), .O(mdio_i));
  // ---------------- IO scan -----------------------------
  wire [N-1:0] pi; reg [N-1:0] ro=0, rt={N{1'b1}};
  genvar g; generate for(g=0;g<N;g=g+1) begin:gp
    IOBUF b(.IO(pin[g]), .I(ro[g]), .T(rt[g]), .O(pi[g])); end endgenerate
  // pulse test: masked pins driven to ~pol for 'hold' clocks then released; count 200MHz clocks until they reach pol
  reg g1=0,g2=0,g3=0; reg [15:0] h=0; reg act=0, meas=0; reg [10:0] t=0; reg pol=0;
  reg [N-1:0] s1=0,s2=0,done=0; reg [10:0] cnt[0:N-1]; integer i;
  reg tg=0; always @(posedge clk) if(sc_go) tg<=~tg;
  always @(posedge clk200) begin
    g1<=tg; g2<=g1; g3<=g2; s1<=pi; s2<=s1;
    if(g2!=g3) begin act<=1; h<=0; pol<=sc_ctl[0]; meas<=0; end
    else if(act) begin h<=h+1; if(h==16'd2000) begin act<=0; meas<=1; t<=0; done<=0; end end
    else if(meas) begin t<=t+1; if(&t) meas<=0;
      for(i=0;i<N;i=i+1) if(!done[i] && s2[i]==pol) begin done[i]<=1; cnt[i]<=t; end
        else if(!done[i] && &t) cnt[i]<=11'h7ff; end
    ro <= act ? {N{~pol}} : po[N-1:0];
    rt <= (act ? ~poe[N-1:0] : (meas ? {N{1'b1}} : (sc_ctl[1] ? ~poe[N-1:0] : {N{1'b1}})));
  end
  reg [N-1:0] q1,q2; always @(posedge clk) begin q1<=pi; q2<=q1; end
  wire [159:0] piq = {{(160-N){1'b0}},q2};
  // ---------------- frequency counters, window 0.1 s ----
  wire [4:0] fclk; wire [31:0] fc[0:4];
  wire [3:0] gtp={gt224_clk0_p,gt226_clk0_p,gt225_clk0_p,gt225_clk1_p}, gtn={gt224_clk0_n,gt226_clk0_n,gt225_clk0_n,gt225_clk1_n};
  generate for(g=0;g<4;g=g+1) begin:gr
    wire od; IBUFDS_GTE4 #(.REFCLK_HROW_CK_SEL(2'b00)) ib(.I(gtp[g]), .IB(gtn[g]), .CEB(1'b0), .O(), .ODIV2(od));
    BUFG_GT bg(.I(od), .CE(1'b1), .CEMASK(1'b0), .CLR(1'b0), .CLRMASK(1'b0), .DIV(3'b000), .O(fclk[g])); end endgenerate
  BUFG bgr(.I(phy_rxc), .O(fclk[4]));
  reg [24:0] w=0; reg win=0; always @(posedge clk200) if(w==25'd19999999) begin w<=0; win<=~win; end else w<=w+1;
  generate for(g=0;g<5;g=g+1) begin:gf
    (* ASYNC_REG="true" *) reg a=0,b=0; reg c=0; reg [31:0] n=0, l=0; reg tk=0;
    always @(posedge fclk[g]) begin a<=win; b<=a; c<=b; if(b!=c) begin l<=n; n<=1; tk<=~tk; end else n<=n+1; end
    // stale detection: report 0 when no toggle seen for 0.3 s
    (* ASYNC_REG="true" *) reg ta=0,tb=0; reg tc=0; reg [25:0] to=0;
    always @(posedge clk) begin ta<=tk; tb<=ta; tc<=tb; if(tb!=tc) to<=0; else if(!to[25]) to<=to+1; end
    assign fc[g] = to[25] ? 32'd0 : l; end endgenerate
  // ---------------- read mux ----------------------------
  reg [10:0] cq; 
  always @(posedge clk) begin
    if(rgo) begin
      casez(araddr[11:0])
        12'h000: rdata<=32'h5E1F7E57;
        12'h004: rdata<=ctl;
        12'h008: rdata<={26'b0,meas|act,pcie_perst,fmc_prsnt,sd_cd,key2,key1};
        12'h00c: rdata<={i2c[15:0],12'b0,fmc_sda_i,fmc_scl_i,eep_sda_i,eep_scl_i};
        12'h010: rdata<=fc[0]; 12'h014: rdata<=fc[1]; 12'h018: rdata<=fc[2]; 12'h01c: rdata<=fc[3]; 12'h020: rdata<=fc[4];
        12'h024: rdata<={26'b0,uart_rxd,mdio_i,sd_d2_i,sd_d1_i,sd_d0_i,sd_cmd_i};
        12'h040: rdata<={31'b0,busy};
        12'h058: rdata<=si[31:0]; 12'h05c: rdata<=si[63:32];
        12'h140: rdata<=piq[31:0]; 12'h144: rdata<=piq[63:32]; 12'h148: rdata<=piq[95:64]; 12'h14c: rdata<=piq[127:96]; 12'h150: rdata<=piq[159:128];
        12'b01??_????_????: rdata<={21'b0,cnt[araddr[9:2]<N ? araddr[9:2] : 0]};
        default: rdata<=32'hDEAD0000;
      endcase end
  end
endmodule
