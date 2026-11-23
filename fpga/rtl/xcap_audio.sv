// Audio from the HDMI receiver (IEC 60958 subframes, PCM or compressed, up to eight
// channels at 192 kHz) or a counting test source, sent as fixed 2048-byte packets on
// their own DMA channel so that audio does not wait for video frames.
//   packet: 16-byte header {ts, flags|words, seq, 'XCAU'}, then up to 508 words, zero padded
//   word:   [23:0] sample  [26:24] channel  [27] V  [28] C  [29] block start  [31] 1
// Words are collected four at a time. A part-filled group is thrown away when the capture is off, the source is
// switched or the source falls silent (2^20 mclk cycles), so nothing old is put in front of the next stream.
// Stopped capture (enable low): as in xcap_framer, a packet the DMA does not take within 2^24 cycles, or abort,
// returns the packetizer to idle.
`default_nettype none
module xcap_audio #(parameter int MCLK_HZ = 100000000) (
  input  wire         mclk, mrst,
  input  wire         src_hdmi, tpg_en,        // aclk, quasi-static
  input  wire [31:0]  tpg_rate,                // test words per second
  input  wire [31:0]  s_tdata, input wire [2:0] s_tid, input wire s_tvalid,
  input  wire         aclk, aresetn, enable, flush, abort,   // flush, abort: one-cycle pulses
  input  wire [31:0]  ts,
  output logic [127:0] m_tdata, output logic m_tvalid, m_tlast, input wire m_tready,
  output logic [31:0] packets, overflows
);
  wire hdmi_m, tpg_m, en_m;
  xpm_cdc_single #(.DEST_SYNC_FF(3), .INIT_SYNC_FF(1), .SRC_INPUT_REG(0)) u_a (.src_clk(aclk), .src_in(src_hdmi), .dest_clk(mclk), .dest_out(hdmi_m));
  xpm_cdc_single #(.DEST_SYNC_FF(3), .INIT_SYNC_FF(1), .SRC_INPUT_REG(0)) u_b (.src_clk(aclk), .src_in(tpg_en), .dest_clk(mclk), .dest_out(tpg_m));
  xpm_cdc_single #(.DEST_SYNC_FF(3), .INIT_SYNC_FF(1), .SRC_INPUT_REG(0)) u_e (.src_clk(aclk), .src_in(enable), .dest_clk(mclk), .dest_out(en_m));
  (* ASYNC_REG = "TRUE" *) logic [31:0] rate_a = 0, rate = 0;
  logic [31:0] acc = 0; logic tick = 0; logic [23:0] ramp = 0; logic [2:0] tch = 0;
  wire [31:0] next = acc + rate;
  always @(posedge mclk) begin
    rate_a <= tpg_rate; rate <= rate_a;
    tick <= 0;
    if (tpg_m && !hdmi_m) begin
      if (next >= MCLK_HZ) begin acc <= next - MCLK_HZ; tick <= 1; end else acc <= next;
    end
    if (tick) begin ramp <= ramp + 24'd1; tch <= (rate >= 300000) ? tch + 3'd1 : {2'b00, ~tch[0]}; end
  end
  wire        w_v = hdmi_m ? s_tvalid : tick;
  wire [31:0] w_d = hdmi_m ? {1'b1, 1'b0, (s_tdata[3:0] == 4'b0001), s_tdata[30], s_tdata[28], s_tid, s_tdata[27:4]}
                           : {1'b1, 4'b0000, tch, ramp};
  logic [1:0] ph = 0; logic [127:0] pk = 0; logic we = 0, t_ovf = 0;
  logic hdmi_q = 0; logic [20:0] quiet = 0;
  wire full, wbusy, e, rbusy, a_ovf; wire [9:0] rcount; wire [127:0] rd; wire ren;
  always @(posedge mclk) begin
    we <= 0;
    hdmi_q <= hdmi_m;
    if (w_v) begin pk[ph*32 +: 32] <= w_d; ph <= ph + 2'd1; we <= (ph == 2'd3); quiet <= '0; end
    else if (quiet[20]) ph <= 0;                 // the source stopped in the middle of a group
    else quiet <= quiet + 1'b1;
    if (we && full) t_ovf <= ~t_ovf;
    if (mrst || !en_m || hdmi_q != hdmi_m) begin ph <= 0; we <= 0; end
  end
  xpm_fifo_async #(.CDC_SYNC_STAGES(3), .FIFO_MEMORY_TYPE("block"), .FIFO_READ_LATENCY(0), .READ_MODE("fwft"),
    .FIFO_WRITE_DEPTH(512), .WRITE_DATA_WIDTH(128), .READ_DATA_WIDTH(128), .RD_DATA_COUNT_WIDTH(10), .USE_ADV_FEATURES("0400")) u_fifo (
    .rst(1'b0), .wr_clk(mclk), .wr_en(we & ~full & ~wbusy), .din(pk), .full(full), .wr_rst_busy(wbusy),
    .rd_clk(aclk), .rd_en(ren), .dout(rd), .empty(e), .rd_rst_busy(rbusy), .rd_data_count(rcount),
    .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0));
  xpm_cdc_single #(.DEST_SYNC_FF(3), .INIT_SYNC_FF(1), .SRC_INPUT_REG(0)) u_o (.src_clk(mclk), .src_in(t_ovf), .dest_clk(aclk), .dest_out(a_ovf));

  typedef enum logic [1:0] {IDLE, HEAD, BODY} st_t;
  st_t st = IDLE; logic [7:0] cnt = 0; logic [6:0] n = 0; logic [31:0] seq = 0; logic [17:0] timer = 0; logic oq = 0;
  logic [31:0] ts_q = 0;
  logic flush_p = 0;                             // flush asked for, packet not yet sent
  logic [24:0] swd = 0;                          // cycles a stopped capture has waited for the DMA
  wire adv = !m_tvalid || m_tready;
  wire body_rd = (st == BODY) && adv && (cnt <= 8'(n)) && !e;
  assign ren = (body_rd || (st == IDLE && !enable)) && !e && !rbusy;
  initial begin m_tvalid = 0; m_tlast = 0; packets = 0; overflows = 0; end
  always @(posedge aclk) begin
    oq <= a_ovf; if (oq != a_ovf) overflows <= overflows + 1;
    if (adv) begin m_tvalid <= 0; m_tlast <= 0; end
    timer <= (st == IDLE && enable && !(&timer)) ? timer + 1 : (st == IDLE) ? timer : '0;
    if (flush && !enable) flush_p <= 1;          // kept until the packet can go out
    if (enable) flush_p <= 0;
    swd <= (!enable && m_tvalid && !m_tready) ? swd + 1'b1 : '0;
    if (!enable && (abort || swd[24])) begin     // nobody takes the rest of this packet any more
      st <= IDLE; m_tvalid <= 0; m_tlast <= 0; swd <= '0;
    end else case (st)
      IDLE: begin
        cnt <= 0;
        if ((flush || flush_p) && !enable && adv) begin m_tdata <= '0; m_tvalid <= 1; m_tlast <= 1; flush_p <= 0; end
        if (enable && !e && !rbusy && (rcount >= 127 || (timer[17:16] == 2'b11 && rcount != 0))) begin   // 0.8 ms
          n <= (rcount >= 127) ? 7'd127 : rcount[6:0]; ts_q <= ts; st <= HEAD;
        end
        if (!enable) timer <= 0;
      end
      HEAD: if (adv) begin
        m_tdata <= {ts_q, 23'd0, n, 2'b00, seq, 32'h55414358}; m_tvalid <= 1;
        seq <= seq + 1; cnt <= 1; st <= BODY;
      end
      BODY: if (adv) begin
        m_tdata <= body_rd ? rd : '0; m_tvalid <= 1; m_tlast <= (cnt == 127);
        cnt <= cnt + 1;
        if (cnt == 127) begin st <= IDLE; packets <= packets + 1; end
      end
      default: st <= IDLE;
    endcase
    if (!aresetn) begin st <= IDLE; m_tvalid <= 0; m_tlast <= 0; seq <= 0; packets <= 0; overflows <= 0; timer <= 0; flush_p <= 0; swd <= '0; end
  end
endmodule
`default_nettype wire
