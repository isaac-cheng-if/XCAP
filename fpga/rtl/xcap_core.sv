// Capture core: everything between the video interface and AXI-Stream/AXI-Lite.
`default_nettype none
module xcap_core #(parameter int FIFO_DEPTH = 8192, parameter int WATCHDOG = 24, parameter int VCLK_HZ = 297000000, parameter int MCLK_HZ = 100000000) (
  input  wire         aclk, aresetn,
  // selected video clock domain
  input  wire         vclk, vlock,
  input  wire         ext_valid, ext_sof, ext_eol,     // HDMI receiver (CTRL.SRC_HDMI)
  input  wire [71:0]  ext_data,
  input  wire [511:0] ext_meta,                        // aclk
  output wire [31:0]  host_ctrl, tx_ctrl,
  output wire         edid_we, output wire [5:0] edid_wa, output wire [31:0] edid_wd,   // aclk
  input  wire         mclk, mrst,                      // audio
  input  wire [31:0]  aud_tdata, input wire [2:0] aud_tid, input wire aud_tvalid,
  input  wire         pt_vdrop, pt_adrop,              // loop-out: toggle per dropped frame / subframe, any clock
  // AXI-Lite
  input  wire [31:0]  s_awaddr, input wire s_awvalid, output wire s_awready,
  input  wire [31:0]  s_wdata,  input wire [3:0] s_wstrb, input wire s_wvalid, output wire s_wready,
  output wire [1:0]   s_bresp,  output wire s_bvalid, input wire s_bready,
  input  wire [31:0]  s_araddr, input wire s_arvalid, output wire s_arready,
  output wire [31:0]  s_rdata,  output wire [1:0] s_rresp, output wire s_rvalid, input wire s_rready,
  // AXI-Stream to the DMA
  output wire [127:0] m_tdata, output wire m_tvalid, output wire m_tlast, input wire m_tready,
  output wire [127:0] a_tdata, output wire a_tvalid, output wire a_tlast, input wire a_tready, // audio packets
  output wire         activity
);
  wire [31:0] ctrl, data_beats, pad_beats, geom, stride, pixfmt, slice_beats, tpg_mode, tpg_repeat, tpg_h, tpg_v;
  wire [511:0] meta; wire [63:0] ts;
  wire [31:0] f_in, f_out, f_drop, f_bad, f_max, st_max;
  wire busy, ovf, clr_fm, clr_st, clr_ov, lock_a, flush, flush_a, abort, abort_a; wire [31:0] tpg_audio, aud_packets, aud_ovf;
  // loop-out drop counters for the host (PT_DROPS): each side toggles a line per drop
  wire vdrop_a, adrop_a; logic vdrop_q = 0, adrop_q = 0; logic [31:0] pt_drops = 0;
  xpm_cdc_single #(.DEST_SYNC_FF(3), .INIT_SYNC_FF(1), .SRC_INPUT_REG(0)) u_pd0 (.src_clk(1'b0), .src_in(pt_vdrop), .dest_clk(aclk), .dest_out(vdrop_a));
  xpm_cdc_single #(.DEST_SYNC_FF(3), .INIT_SYNC_FF(1), .SRC_INPUT_REG(0)) u_pd1 (.src_clk(1'b0), .src_in(pt_adrop), .dest_clk(aclk), .dest_out(adrop_a));
  always @(posedge aclk) begin
    vdrop_q <= vdrop_a; adrop_q <= adrop_a;
    if (vdrop_q != vdrop_a) pt_drops[15:0]  <= pt_drops[15:0]  + 16'd1;
    if (adrop_q != adrop_a) pt_drops[31:16] <= pt_drops[31:16] + 16'd1;
    if (!aresetn) pt_drops <= '0;
  end
  xpm_cdc_single #(.DEST_SYNC_FF(3), .INIT_SYNC_FF(1), .SRC_INPUT_REG(0)) u_lk (.src_clk(1'b0), .src_in(vlock), .dest_clk(aclk), .dest_out(lock_a));
  xcap_regs #(.VCLK_HZ(VCLK_HZ)) u_regs (.clk(aclk), .rstn(aresetn), .*, 
    .cfg_ctrl(ctrl), .cfg_data_beats(data_beats), .cfg_pad_beats(pad_beats), .cfg_geom(geom), .cfg_stride(stride),
    .cfg_pixfmt(pixfmt), .cfg_slice_beats(slice_beats), .cfg_tpg_mode(tpg_mode), .cfg_tpg_repeat(tpg_repeat),
    .cfg_tpg_h(tpg_h), .cfg_tpg_v(tpg_v), .cfg_meta(meta), .ts(ts),
    .frames_in(f_in), .frames_out(f_out), .frames_drop(f_drop), .frames_bad(f_bad), .fifo_max(f_max), .stall_max(st_max),
    .busy(busy), .vid_lock(lock_a), .overflow(ovf), .clr_fifo_max(clr_fm), .clr_stall(clr_st), .clr_ovf(clr_ov), .flush(flush), .flush_a(flush_a), .abort(abort), .abort_a(abort_a), .pt_drops(pt_drops), .cfg_tpg_audio(tpg_audio), .aud_packets(aud_packets), .aud_ovf(aud_ovf));

  // ---- video domain ----
  wire tpg_en_v, sel_v, fmt_v, mode_v;
  xpm_cdc_single #(.DEST_SYNC_FF(3), .INIT_SYNC_FF(1), .SRC_INPUT_REG(0)) u_s0 (.src_clk(aclk), .src_in(ctrl[2]),   .dest_clk(vclk), .dest_out(tpg_en_v));
  xpm_cdc_single #(.DEST_SYNC_FF(3), .INIT_SYNC_FF(1), .SRC_INPUT_REG(0)) u_s1 (.src_clk(aclk), .src_in(ctrl[1]),   .dest_clk(vclk), .dest_out(sel_v));
  xpm_cdc_single #(.DEST_SYNC_FF(3), .INIT_SYNC_FF(1), .SRC_INPUT_REG(0)) u_s2 (.src_clk(aclk), .src_in(pixfmt[0]), .dest_clk(vclk), .dest_out(fmt_v));
  xpm_cdc_single #(.DEST_SYNC_FF(3), .INIT_SYNC_FF(1), .SRC_INPUT_REG(0)) u_s3 (.src_clk(aclk), .src_in(tpg_mode[0]), .dest_clk(vclk), .dest_out(mode_v));
  (* ASYNC_REG = "TRUE" *) logic [71:0] qs_a, qs;   // quasi-static timing numbers
  always @(posedge vclk) begin qs_a <= {tpg_repeat[7:0], tpg_v, tpg_h}; qs <= qs_a; end
  wire t_valid, t_sof, t_eol; wire [71:0] t_data; wire [31:0] t_pic;
  xcap_tpg u_tpg (.clk(vclk), .en(tpg_en_v), .mode(mode_v), .repeat_n(qs[71:64]),
    .h_active(qs[15:0]), .h_total(qs[31:16]), .v_active(qs[47:32]), .v_total(qs[63:48]),
    .valid(t_valid), .sof(t_sof), .eol(t_eol), .data(t_data), .picture(t_pic));
  logic v_valid, v_sof, v_eol; logic [71:0] v_data;
  always @(posedge vclk) begin
    v_valid <= sel_v ? ext_valid : t_valid;
    v_sof   <= sel_v ? ext_sof   : t_sof;
    v_eol   <= sel_v ? ext_eol   : t_eol;
    v_data  <= sel_v ? ext_data  : t_data;
  end
  wire wv, ws; wire [127:0] wd;
  xcap_pack u_pack (.clk(vclk), .fmt(fmt_v), .valid(v_valid), .sof(v_sof), .eol(v_eol), .data(v_data), .wvalid(wv), .wsof(ws), .wdata(wd));

  xcap_audio #(.MCLK_HZ(MCLK_HZ)) u_audio (.mclk(mclk), .mrst(mrst), .src_hdmi(ctrl[1]), .tpg_en(ctrl[2]), .tpg_rate(tpg_audio),
    .s_tdata(aud_tdata), .s_tid(aud_tid), .s_tvalid(aud_tvalid), .aclk(aclk), .aresetn(aresetn), .enable(ctrl[3]), .flush(flush_a), .abort(abort_a), .ts(ts[31:0]),
    .m_tdata(a_tdata), .m_tvalid(a_tvalid), .m_tlast(a_tlast), .m_tready(a_tready), .packets(aud_packets), .overflows(aud_ovf));
  xcap_framer #(.FIFO_DEPTH(FIFO_DEPTH), .WATCHDOG(WATCHDOG)) u_framer (
    .vclk(vclk), .wvalid(wv), .wsof(ws), .wdata(wd), .v_picture(t_pic),
    .aclk(aclk), .aresetn(aresetn), .stream_en(ctrl[0]), .flush(flush), .abort(abort),
    .data_beats(data_beats), .pad_beats(pad_beats), .geom(geom), .stride(stride), .pixfmt(pixfmt), .slice_beats(slice_beats),
    .meta(ctrl[1] ? ext_meta : meta), .ts(ts), .clr_fifo_max(clr_fm), .clr_stall(clr_st), .clr_ovf(clr_ov),
    .frames_in(f_in), .frames_out(f_out), .frames_drop(f_drop), .frames_bad(f_bad), .fifo_max(f_max), .stall_max(st_max),
    .busy(busy), .overflow(ovf), .m_tdata(m_tdata), .m_tvalid(m_tvalid), .m_tlast(m_tlast), .m_tready(m_tready));
  assign activity = f_out[5];
endmodule
`default_nettype wire
