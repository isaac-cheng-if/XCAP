// AXI-Lite register file, see common/xcap_hw.h
`default_nettype none
module xcap_regs #(parameter int VCLK_HZ = 297000000) (
  input  wire         clk, rstn,
  input  wire [31:0]  s_awaddr, input wire s_awvalid, output logic s_awready,
  input  wire [31:0]  s_wdata,  input wire [3:0] s_wstrb, input wire s_wvalid, output logic s_wready,
  output logic [1:0]  s_bresp,  output logic s_bvalid, input wire s_bready,
  input  wire [31:0]  s_araddr, input wire s_arvalid, output logic s_arready,
  output logic [31:0] s_rdata,  output logic [1:0] s_rresp, output logic s_rvalid, input wire s_rready,
  output logic [31:0] cfg_ctrl, cfg_data_beats, cfg_pad_beats, cfg_geom, cfg_stride, cfg_pixfmt, cfg_slice_beats,
  output logic [31:0] cfg_tpg_mode, cfg_tpg_repeat, cfg_tpg_h, cfg_tpg_v,
  output logic [511:0] cfg_meta,
  output logic [63:0] ts,
  input  wire [511:0] ext_meta,
  output logic [31:0] host_ctrl, tx_ctrl,
  input  wire [31:0]  frames_in, frames_out, frames_drop, frames_bad, fifo_max, stall_max,
  input  wire         busy, vid_lock, overflow,
  output logic        clr_fifo_max, clr_stall, clr_ovf, flush, flush_a, abort, abort_a,
  input  wire [31:0]  pt_drops,
  output logic [31:0] cfg_tpg_audio,
  input  wire [31:0]  aud_packets, aud_ovf,
  output logic        edid_we, output logic [5:0] edid_wa, output logic [31:0] edid_wd   // host EDID, read by the HDMI firmware
);
  initial begin
    cfg_ctrl = 0; cfg_meta = '0; ts = 0; host_ctrl = 0; tx_ctrl = 0; cfg_pixfmt = 0; cfg_tpg_mode = 0;
    s_bvalid = 0; s_rvalid = 0; s_arready = 0; clr_fifo_max = 0; clr_stall = 0; clr_ovf = 0; flush = 0; flush_a = 0; abort = 0; abort_a = 0; cfg_tpg_audio = 96000; edid_we = 0;
  end
  assign s_bresp = 2'b00; assign s_rresp = 2'b00;
  logic [11:0] aw; logic [31:0] wd; logic have_aw = 0, have_w = 0;
  logic [31:0] ts_hi;
  logic [11:0] ar; logic ar_busy = 0, ar_go = 0;
  assign s_awready = !have_aw && !s_bvalid;
  assign s_wready  = !have_w  && !s_bvalid;
  wire we = have_aw && have_w && !s_bvalid;

  always @(posedge clk) begin
    ts <= ts + 1;
    clr_fifo_max <= 0; clr_stall <= 0; clr_ovf <= 0; flush <= 0; flush_a <= 0; abort <= 0; abort_a <= 0; edid_we <= 0;
    if (s_awvalid && s_awready) begin aw <= s_awaddr[11:0]; have_aw <= 1; end
    if (s_wvalid && s_wready)   begin wd <= s_wdata; have_w <= 1; end
    if (we) begin
      have_aw <= 0; have_w <= 0; s_bvalid <= 1;
      if (aw[11:8] == 4'h8) begin edid_we <= 1; edid_wa <= aw[7:2]; edid_wd <= wd; end
      case (aw)
        12'h008: cfg_ctrl <= wd;
        12'h00C: clr_ovf <= wd[2];
        12'h010: cfg_data_beats <= wd;
        12'h014: cfg_pad_beats <= wd;
        12'h018: cfg_geom <= wd;
        12'h01C: cfg_stride <= wd;
        12'h020: cfg_pixfmt <= wd;
        12'h024: cfg_slice_beats <= wd;
        12'h048: clr_fifo_max <= 1;
        12'h04C: clr_stall <= 1;
        12'h050: begin flush <= wd[0]; flush_a <= wd[1]; abort <= wd[2]; abort_a <= wd[3]; end
        12'h058: host_ctrl <= wd;
        12'h05C: tx_ctrl <= wd;
        12'h060: cfg_tpg_mode <= wd;
        12'h074: cfg_tpg_audio <= wd;
        12'h064: cfg_tpg_repeat <= wd;
        12'h068: cfg_tpg_h <= wd;
        12'h06C: cfg_tpg_v <= wd;
        default: if (aw[11:6] == 6'h02) cfg_meta[aw[5:2]*32 +: 32] <= wd;
      endcase
    end
    if (s_bvalid && s_bready) s_bvalid <= 0;

    // one read at a time; RVALID only after the address handshake
    if (s_rvalid && s_rready) s_rvalid <= 0;
    s_arready <= s_arvalid && !s_arready && !ar_busy;
    if (s_arvalid && s_arready) begin ar <= s_araddr[11:0]; ar_busy <= 1; ar_go <= 1; end
    if (s_rvalid && s_rready) ar_busy <= 0;
    if (ar_go) begin
      ar_go <= 0; s_rvalid <= 1;
      case (ar)
        12'h000: s_rdata <= 32'h58434150;
        12'h004: s_rdata <= 32'h00030301;
        12'h008: s_rdata <= cfg_ctrl;
        12'h00C: s_rdata <= {29'd0, overflow, vid_lock, busy};
        12'h010: s_rdata <= cfg_data_beats;
        12'h014: s_rdata <= cfg_pad_beats;
        12'h018: s_rdata <= cfg_geom;
        12'h01C: s_rdata <= cfg_stride;
        12'h020: s_rdata <= cfg_pixfmt;
        12'h024: s_rdata <= cfg_slice_beats;
        12'h030: begin s_rdata <= ts[31:0]; ts_hi <= ts[63:32]; end
        12'h034: s_rdata <= ts_hi;
        12'h038: s_rdata <= frames_in;
        12'h03C: s_rdata <= frames_out;
        12'h040: s_rdata <= frames_drop;
        12'h044: s_rdata <= frames_bad;
        12'h048: s_rdata <= fifo_max;
        12'h04C: s_rdata <= stall_max;
        12'h054: s_rdata <= pt_drops;
        12'h058: s_rdata <= host_ctrl;
        12'h05C: s_rdata <= tx_ctrl;
        12'h060: s_rdata <= cfg_tpg_mode;
        12'h070: s_rdata <= VCLK_HZ;
        12'h074: s_rdata <= cfg_tpg_audio;
        12'h078: s_rdata <= aud_packets;
        12'h07C: s_rdata <= aud_ovf;
        12'h064: s_rdata <= cfg_tpg_repeat;
        12'h068: s_rdata <= cfg_tpg_h;
        12'h06C: s_rdata <= cfg_tpg_v;
        default: s_rdata <= (ar[11:6] == 6'h03) ? ext_meta[ar[5:2]*32 +: 32] : (ar[11:6] == 6'h02) ? cfg_meta[ar[5:2]*32 +: 32] : 32'd0;
      endcase
    end
    if (!rstn) begin
      have_aw <= 0; have_w <= 0; s_bvalid <= 0; s_rvalid <= 0; s_arready <= 0; ar_busy <= 0; ar_go <= 0; ts <= 0;
      cfg_ctrl <= 0; cfg_meta <= '0; host_ctrl <= 0; tx_ctrl <= 0; cfg_tpg_audio <= 96000;
      cfg_data_beats <= 1382400; cfg_pad_beats <= 0;                 // 3840x2160 v210
      cfg_geom <= {16'd2160, 16'd3840}; cfg_stride <= 10240; cfg_pixfmt <= 0;
      cfg_slice_beats <= 46080;                                      // 72 lines
      cfg_tpg_mode <= 0; cfg_tpg_repeat <= 2;
      cfg_tpg_h <= {16'd2200, 16'd1920}; cfg_tpg_v <= {16'd2250, 16'd2160};
    end
  end
endmodule
`default_nettype wire
