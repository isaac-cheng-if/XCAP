// MicroBlaze side of the signal description. The firmware writes 16 words and
// commits them; the capture core sees a consistent snapshot in its own clock.
`default_nettype none
module xcap_meta_regs (
  input  wire        clk, rstn,
  input  wire [31:0] s_awaddr, input wire s_awvalid, output wire s_awready,
  input  wire [31:0] s_wdata,  input wire s_wvalid,  output wire s_wready,
  output wire [1:0]  s_bresp,  output logic s_bvalid, input wire s_bready,
  input  wire [31:0] s_araddr, input wire s_arvalid, output logic s_arready,
  output logic [31:0] s_rdata, output wire [1:0] s_rresp, output logic s_rvalid, input wire s_rready,
  input  wire        aclk,
  input  wire [31:0] host_ctrl, tx_ctrl,   // aclk, quasi-static
  output logic [31:0] aud_n, aud_cts, aud_rate, aud_cfg,   // clk, set by the firmware for the TX
  input  wire [31:0] aud_stat,             // clk, read only at 0x90: what the receiver's sound is (xcap_audfmt)
  input  wire        edid_we, input wire [5:0] edid_wa, input wire [31:0] edid_wd,   // aclk
  input  wire        cap_tclk, input wire [59:0] cap_td,    // HDMI link data for xcap_linkcap
  input  wire        cap_rclk, input wire [59:0] cap_rd,
  output logic [511:0] meta            // aclk
);
  // 0x8000-0xFFFF: link snapshot. Write 0x8000 to take one; read 0x8000 | side << 14 | sample << 4 | word << 2
  // (side 0 receiver, 1 transmitter; word 0 bits 31:0, 1 bits 59:32, 3 done flags {transmitter, receiver}).
  assign s_bresp = 2'b00; assign s_rresp = 2'b00;
  logic [511:0] shadow, cfg_snap; logic t_commit;
  logic [15:0] aw, ar; logic cap_arm = 0; wire [59:0] cap_q; wire [1:0] cap_done; logic [31:0] wd; logic have_aw, have_w, ar_busy, ar_go;
  (* ASYNC_REG = "TRUE" *) logic [31:0] hc_a, hc, tc_a, tc;
  wire [5:0] ar_next = (s_arvalid && s_arready) ? s_araddr[7:2] : ar[7:2];
  wire [8:0] cap_next = (s_arvalid && s_arready) ? s_araddr[12:4] : ar[12:4];
  wire cap_side = (s_arvalid && s_arready) ? s_araddr[14] : ar[14];
  xcap_linkcap u_cap (.tclk(cap_tclk), .td(cap_td), .rclk(cap_rclk), .rd(cap_rd), .clk(clk), .arm(cap_arm), .side(cap_side),
    .addr(cap_next), .q(cap_q), .done(cap_done));
  wire [31:0] edid_q;                                // 64 words, quiet while the firmware reads them
  xpm_memory_sdpram #(.ADDR_WIDTH_A(6), .ADDR_WIDTH_B(6), .BYTE_WRITE_WIDTH_A(32), .CLOCKING_MODE("independent_clock"),
    .MEMORY_PRIMITIVE("distributed"), .MEMORY_SIZE(2048), .READ_DATA_WIDTH_B(32), .READ_LATENCY_B(1), .WRITE_DATA_WIDTH_A(32),
    .WRITE_MODE_B("read_first"), .USE_EMBEDDED_CONSTRAINT(1)) u_edid (
    .clka(aclk), .ena(edid_we), .wea(1'b1), .addra(edid_wa), .dina(edid_wd),
    .clkb(clk), .enb(1'b1), .addrb(ar_next), .doutb(edid_q), .rstb(1'b0), .regceb(1'b1),
    .sleep(1'b0), .injectsbiterra(1'b0), .injectdbiterra(1'b0), .sbiterrb(), .dbiterrb());
  initial begin aud_n = 6144; aud_cts = 594000; aud_rate = 0; aud_cfg = 0; end
  initial begin shadow = '0; cfg_snap = '0; t_commit = 0; have_aw = 0; have_w = 0; ar_busy = 0; ar_go = 0; s_bvalid = 0; s_rvalid = 0; s_arready = 0; meta = '0; end
  assign s_awready = !have_aw && !s_bvalid;
  assign s_wready  = !have_w  && !s_bvalid;
  always @(posedge clk) begin
    hc_a <= host_ctrl; hc <= hc_a; tc_a <= tx_ctrl; tc <= tc_a;
    if (s_awvalid && s_awready) begin aw <= s_awaddr[15:0]; have_aw <= 1; end
    if (s_wvalid && s_wready)   begin wd <= s_wdata; have_w <= 1; end
    if (have_aw && have_w && !s_bvalid) begin
      have_aw <= 0; have_w <= 0; s_bvalid <= 1;
      if (aw[15]) cap_arm <= ~cap_arm;
      else if (aw[8]) ;                              // host EDID is read only here
      else if (aw[7]) case (aw[3:2]) 2'd0: aud_n <= wd; 2'd1: aud_cts <= wd; 2'd2: aud_rate <= wd; default: aud_cfg <= wd; endcase
      else if (!aw[6]) shadow[aw[5:2]*32 +: 32] <= wd;
      else if (aw[5:2] == 0) begin cfg_snap <= shadow; t_commit <= ~t_commit; end
    end
    if (s_bvalid && s_bready) s_bvalid <= 0;
    if (s_rvalid && s_rready) begin s_rvalid <= 0; ar_busy <= 0; end
    s_arready <= s_arvalid && !s_arready && !ar_busy;
    if (s_arvalid && s_arready) begin ar <= s_araddr[15:0]; ar_busy <= 1; ar_go <= 1; end
    if (ar_go) begin ar_go <= 0; s_rvalid <= 1; s_rdata <= ar[15] ? (ar[3:2] == 0 ? cap_q[31:0] : ar[3:2] == 1 ? {4'd0, cap_q[59:32]} : {30'd0, cap_done}) : ar[8] ? edid_q : ar[7] ? (ar[4] ? aud_stat : ar[3:2] == 0 ? aud_n : ar[3:2] == 1 ? aud_cts : ar[3:2] == 2 ? aud_rate : aud_cfg) : ar[6] ? (ar[2] ? tc : hc) : shadow[ar[5:2]*32 +: 32]; end
    if (!rstn) begin have_aw <= 0; have_w <= 0; s_bvalid <= 0; s_rvalid <= 0; s_arready <= 0; ar_busy <= 0; ar_go <= 0; end
  end
  wire a_commit; logic a_q = 0; logic [1:0] dly = 0;
  xpm_cdc_single #(.DEST_SYNC_FF(3), .INIT_SYNC_FF(1), .SRC_INPUT_REG(0)) u_c (.src_clk(clk), .src_in(t_commit), .dest_clk(aclk), .dest_out(a_commit));
  // the snapshot is stable for many microseconds around the toggle
  always @(posedge aclk) begin
    a_q <= a_commit;
    if (a_q != a_commit) meta <= cfg_snap;
  end
endmodule
`default_nettype wire
