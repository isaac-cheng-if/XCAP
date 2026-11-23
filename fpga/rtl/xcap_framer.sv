// Video-clock FIFO writer + DMA-side framer.
// Every frame that leaves on AXI-Stream has exactly
//   4096 (header) + DATA_BEATS*16 + PAD_BEATS*16 + 4096 (trailer) bytes,
// with TLAST on the last beat, whatever happens on the video side: a frame that
// overflows or ends early is padded and flagged, a frame that starts before the
// previous one has left is dropped whole. The host ring never loses alignment.
// Stopped stream (stream_en low): a frame under way is completed as long as the DMA takes it. If nothing has been
// taken for 2^WATCHDOG cycles, or on abort, the framer drops what it holds and returns to idle, so that the next run
// never starts with the rest of an old frame.
`default_nettype none
module xcap_framer #(
  parameter int FIFO_DEPTH = 8192,
  parameter int WATCHDOG   = 24      // log2 of aclk cycles without data inside a frame
) (
  // video side
  input  wire          vclk,
  input  wire          wvalid, wsof,
  input  wire [127:0]  wdata,
  input  wire [31:0]   v_picture,
  // DMA side
  input  wire          aclk, aresetn,
  input  wire          stream_en, flush, abort,   // flush, abort: one-cycle pulses
  input  wire [31:0]   data_beats, pad_beats, geom, stride, pixfmt, slice_beats,
  input  wire [511:0]  meta,
  input  wire [63:0]   ts,
  input  wire          clr_fifo_max, clr_stall, clr_ovf,
  output logic [31:0]  frames_in, frames_out, frames_drop, frames_bad, fifo_max, stall_max,
  output logic         busy, overflow,
  output logic [127:0] m_tdata,
  output logic         m_tvalid, m_tlast,
  input  wire          m_tready
);
  localparam int CW = $clog2(FIFO_DEPTH) + 1;
  localparam logic [31:0] HDR_MAGIC = 32'h48464358, TRL_MAGIC = 32'h54464358, VERSION = 32'd1;

  initial begin
    frames_in = 0; frames_out = 0; frames_drop = 0; frames_bad = 0; fifo_max = 0; stall_max = 0;
    busy = 0; overflow = 0; m_tvalid = 0; m_tlast = 0;
  end
  // ---------------- video side ----------------
  wire  rd_ready_v, fifo_full, fifo_rst_busy_w;
  logic vrun = 0, t_sof = 0, t_eof = 0, t_abort = 0, t_drop = 0;
  logic [31:0] vcount = 0;
  logic [31:0] vpic = 0;
  (* ASYNC_REG = "TRUE" *) logic [31:0] v_beats_a, v_beats;   // static while streaming
  always @(posedge vclk) begin v_beats_a <= data_beats; v_beats <= v_beats_a; end
  logic [31:0] v_last = 0;
  always @(posedge vclk) v_last <= v_beats - 1;

  logic         fw_en = 0, fw_sof = 0;
  logic [127:0] fw_data;
  logic         ovf_seen = 0;
  always @(posedge vclk) begin
    fw_en <= 1'b0;
    fw_data <= wdata;
    if (fw_en && fifo_full) begin           // previous word was refused
      vrun <= 1'b0; t_abort <= ~t_abort;
    end else if (wvalid) begin
      if (wsof) begin
        if (rd_ready_v && !fifo_rst_busy_w) begin
          vrun <= 1'b1; fw_en <= 1'b1; fw_sof <= 1'b1; vcount <= 1; vpic <= v_picture;
          t_sof <= ~t_sof;
        end else begin
          vrun <= 1'b0; t_drop <= ~t_drop;
          if (vrun) t_abort <= ~t_abort;    // short frame: next one started early
        end
      end else if (vrun) begin
        fw_en <= 1'b1; fw_sof <= 1'b0; vcount <= vcount + 1;
        if (vcount == v_last) begin vrun <= 1'b0; t_eof <= ~t_eof; end
      end
    end
  end

  wire [128:0] fdout;
  wire         fempty, frd_busy;
  wire [CW-1:0] fcount;
  logic        frd;
  xpm_fifo_async #(
    .CDC_SYNC_STAGES(3), .FIFO_MEMORY_TYPE("block"), .FIFO_READ_LATENCY(0), .READ_MODE("fwft"),
    .FIFO_WRITE_DEPTH(FIFO_DEPTH), .WRITE_DATA_WIDTH(129), .READ_DATA_WIDTH(129),
    .RD_DATA_COUNT_WIDTH(CW), .USE_ADV_FEATURES("0400"), .RELATED_CLOCKS(0)
  ) u_fifo (
    .rst(1'b0), .wr_clk(vclk), .wr_en(fw_en & ~fifo_full), .din({fw_sof, fw_data}), .full(fifo_full),
    .wr_rst_busy(fifo_rst_busy_w), .rd_clk(aclk), .rd_en(frd), .dout(fdout), .empty(fempty),
    .rd_rst_busy(frd_busy), .rd_data_count(fcount), .sleep(1'b0),
    .injectsbiterr(1'b0), .injectdbiterr(1'b0)
  );

  // ---------------- crossings ----------------
  logic rd_ready = 0;
  xpm_cdc_single #(.DEST_SYNC_FF(3), .INIT_SYNC_FF(1), .SRC_INPUT_REG(0)) u_rdy (.src_clk(aclk), .src_in(rd_ready), .dest_clk(vclk), .dest_out(rd_ready_v));
  wire a_sof, a_eof, a_abort, a_drop;
  xpm_cdc_single #(.DEST_SYNC_FF(3), .INIT_SYNC_FF(1), .SRC_INPUT_REG(0)) u_c0 (.src_clk(vclk), .src_in(t_sof),   .dest_clk(aclk), .dest_out(a_sof));
  xpm_cdc_single #(.DEST_SYNC_FF(3), .INIT_SYNC_FF(1), .SRC_INPUT_REG(0)) u_c1 (.src_clk(vclk), .src_in(t_eof),   .dest_clk(aclk), .dest_out(a_eof));
  xpm_cdc_single #(.DEST_SYNC_FF(3), .INIT_SYNC_FF(1), .SRC_INPUT_REG(0)) u_c2 (.src_clk(vclk), .src_in(t_abort), .dest_clk(aclk), .dest_out(a_abort));
  xpm_cdc_single #(.DEST_SYNC_FF(3), .INIT_SYNC_FF(1), .SRC_INPUT_REG(0)) u_c3 (.src_clk(vclk), .src_in(t_drop),  .dest_clk(aclk), .dest_out(a_drop));
  logic [3:0] aq = 0;
  wire p_sof = aq[0] ^ a_sof, p_eof = aq[1] ^ a_eof, p_abort = aq[2] ^ a_abort, p_drop = aq[3] ^ a_drop;
  (* ASYNC_REG = "TRUE" *) logic [31:0] a_pic_a;
  logic [31:0] a_pic = 0;
  logic [63:0] ts_first = 0, ts_last = 0, ts_out = 0;
  always @(posedge aclk) begin
    aq <= {a_drop, a_abort, a_eof, a_sof};
    a_pic_a <= vpic;                        // stable for a whole frame after t_sof
    if (p_sof) ts_first <= ts;
  end

  // ---------------- framer ----------------
  typedef enum logic [2:0] {IDLE, SETTLE, HDR, DATA, PAD, TAIL, GAP, TRL} st_t;
  st_t st = IDLE;
  logic [31:0] cnt = 0, seq = 0, drop_at_hdr = 0;
  logic        bad = 0, aborted = 0, discont = 0, repeat_f = 0;
  logic [WATCHDOG:0] wd = 0;
  logic [3:0]  gap = 0;
  logic        flush_p = 0;                     // flush asked for, packet not yet sent
  logic [WATCHDOG:0] swd = 0;                   // cycles a stopped stream has waited for the DMA
  wire adv  = !m_tvalid || m_tready;
  logic [31:0] d_last, p_last, s_last;          // static while streaming
  always @(posedge aclk) begin d_last <= data_beats - 1; p_last <= pad_beats - 1; s_last <= slice_beats - 1; end
  wire last_data = (cnt == d_last);
  wire take = (st == DATA) && adv && !fempty && !(fdout[128] && cnt != 0);
  assign frd = take || (st == IDLE && !fempty && (!fdout[128] || !stream_en));

  logic [5:0]   band = 0;
  // the header's description of the frame, taken in one cycle: a change while the header goes out cannot tear it
  logic [511:0] meta_q = '0;
  logic [31:0]  geom_q = 0, stride_q = 0, pixfmt_q = 0;
  logic [127:0] hdr_w, trl_w;
  logic [127:0] crc, prev_crc = 0;
  logic [127:0] bram_q;
  always_comb begin
    case (cnt[7:0])
      8'd0: hdr_w = {{31'd0, discont} << 2, seq, VERSION, HDR_MAGIC};
      8'd1: hdr_w = {stride_q, geom_q, ts_first};
      8'd2: hdr_w = {32'd0, a_pic, data_beats << 4, pixfmt_q};
      8'd3: hdr_w = meta_q[127:0];
      8'd4: hdr_w = meta_q[255:128];
      8'd5: hdr_w = meta_q[383:256];
      8'd6: hdr_w = meta_q[511:384];
      default: hdr_w = '0;
    endcase
    case (cnt[7:0])
      8'd0: trl_w = {fifo_max, 29'd0, discont, repeat_f, bad, seq, TRL_MAGIC};
      8'd1: trl_w = {ts_out, ts_last};
      8'd2: trl_w = {26'd0, band, stall_max, frames_bad, frames_drop};
      8'd3: trl_w = crc;
      default: trl_w = (cnt < 4 + band) ? bram_q : '0;
    endcase
  end

  // CRC-32C per lane, one word per cycle, two cycles behind the output register
  function automatic [31:0] crc32c(input [31:0] c, input [31:0] d);
    logic [31:0] x;
    x = c ^ d;
    for (int i = 0; i < 32; i++) x = x[0] ? ((x >> 1) ^ 32'h82F63B78) : (x >> 1);
    crc32c = x;
  endfunction
  logic         cv = 0, cv_first = 0, cv_band = 0;
  logic [127:0] cd;
  logic [31:0]  scnt = 0;
  logic [5:0]   bw_addr = 0;
  logic         bw = 0;
  (* ram_style = "distributed" *) logic [127:0] band_ram [0:63];
  always @(posedge aclk) begin
    bw <= 1'b0;
    if (cv)
      for (int l = 0; l < 4; l++)
        crc[l*32 +: 32] <= crc32c(cv_first ? 32'hFFFFFFFF : crc[l*32 +: 32], cd[l*32 +: 32]);
    if (cv && cv_band) begin bw <= 1'b1; end
    if (st == HDR) begin bw_addr <= 0; end
    if (bw && bw_addr != 6'd60) begin band_ram[bw_addr] <= crc; bw_addr <= bw_addr + 6'd1; end   // 60 bands, like band: no wrap
  end
  // trailer beat 4 + i carries band i
  wire [5:0] br_addr = cnt[5:0] - 6'd4;
  assign bram_q = band_ram[br_addr];

  always @(posedge aclk) begin
    cv <= 1'b0;
    if (p_drop && stream_en) frames_drop <= frames_drop + 1;
    if (!stream_en) drop_at_hdr <= frames_drop;
    if (p_sof)  frames_in   <= frames_in + 1;
    if (p_abort) aborted <= 1'b1;
    if (fcount > fifo_max[CW-1:0]) fifo_max <= 32'(fcount);
    if (clr_fifo_max) fifo_max <= 0;
    if (clr_ovf) overflow <= 1'b0; else if (p_abort) overflow <= 1'b1;
    rd_ready <= stream_en && (st == IDLE) && fempty && !frd_busy;
    busy <= (st != IDLE);
    if (p_eof) ts_last <= ts;
    if (flush && !stream_en) flush_p <= 1'b1;   // kept until the packet can go out (frame under way, DMA not ready)
    if (stream_en) flush_p <= 1'b0;
    swd <= (!stream_en && m_tvalid && !m_tready) ? swd + 1'b1 : '0;

    if (adv) begin m_tvalid <= 1'b0; m_tlast <= 1'b0; end
    if (!stream_en && (abort || swd[WATCHDOG])) begin   // nobody takes the rest of this frame (or the flush packet) any more
      st <= IDLE; cnt <= 0; m_tvalid <= 1'b0; m_tlast <= 1'b0; aborted <= 1'b0; swd <= '0;
    end else case (st)
      IDLE: begin
        cnt <= 0; bad <= 1'b0; wd <= 0; band <= 0; scnt <= 0;
        if ((flush || flush_p) && !stream_en && adv) begin m_tdata <= '0; m_tvalid <= 1'b1; m_tlast <= 1'b1; flush_p <= 1'b0; end
        if (stream_en && !fempty && fdout[128]) begin st <= SETTLE; gap <= 0; end
        else aborted <= 1'b0;
      end
      SETTLE: begin                        // let the SOF toggle and picture number arrive
        gap <= gap + 1;
        if (&gap) begin
          st <= HDR; a_pic <= a_pic_a;
          meta_q <= meta; geom_q <= geom; stride_q <= stride; pixfmt_q <= pixfmt;
          discont <= (frames_drop != drop_at_hdr); drop_at_hdr <= frames_drop;
        end
      end
      HDR: if (adv) begin
        m_tdata <= hdr_w; m_tvalid <= 1'b1;
        cnt <= cnt + 1;
        if (cnt == 255) begin cnt <= 0; st <= DATA; end
      end
      DATA: begin
        wd <= take ? '0 : wd + 1;
        if (take) begin
          m_tdata <= fdout[127:0]; m_tvalid <= 1'b1;
          cv <= 1'b1; cd <= fdout[127:0]; cv_first <= (cnt == 0);
          cv_band <= (scnt == s_last) || last_data;
          if ((scnt == s_last) || last_data) begin scnt <= 0; if (band < 60) band <= band + 1; end
          else scnt <= scnt + 1;
          cnt <= cnt + 1;
          if (last_data) begin cnt <= 0; st <= (pad_beats != 0) ? TAIL : GAP; gap <= 0; end
        end else if ((!fempty && fdout[128] && cnt != 0) || (fempty && aborted) || wd[WATCHDOG]) begin
          bad <= 1'b1; st <= PAD;
          ts_last <= ts;                   // no last pixel: when the input was given up
        end
      end
      PAD: if (adv) begin
        m_tdata <= '0; m_tvalid <= 1'b1;
        cnt <= cnt + 1;
        if (last_data) begin cnt <= 0; st <= (pad_beats != 0) ? TAIL : GAP; gap <= 0; end
      end
      TAIL: if (adv) begin
        m_tdata <= '0; m_tvalid <= 1'b1; cnt <= cnt + 1;
        if (cnt == p_last) begin cnt <= 0; st <= GAP; gap <= 0; end
      end
      GAP: begin                           // CRC and the last-pixel timestamp settle
        gap <= gap + 1;
        if (&gap) begin
          st <= TRL;
          repeat_f <= !bad && (crc == prev_crc);
          prev_crc <= bad ? ~crc : crc;
          if (bad) frames_bad <= frames_bad + 1;
        end
      end
      TRL: if (adv) begin
        m_tdata <= trl_w; m_tvalid <= 1'b1; m_tlast <= (cnt == 255);
        cnt <= cnt + 1;
        if (cnt == 255) begin
          cnt <= 0; st <= IDLE; aborted <= 1'b0;
          seq <= seq + 1; frames_out <= frames_out + 1;
        end
      end
    endcase
    if ((st == DATA && take && last_data) || (st == PAD && adv && last_data)) ts_out <= ts;   // padded frames too

    if (!aresetn) begin
      st <= IDLE; cnt <= 0; seq <= 0; m_tvalid <= 1'b0; m_tlast <= 1'b0; rd_ready <= 1'b0;
      frames_in <= 0; frames_out <= 0; frames_drop <= 0; frames_bad <= 0; fifo_max <= 0;
      overflow <= 1'b0; aborted <= 1'b0; drop_at_hdr <= 0; discont <= 1'b0; repeat_f <= 1'b0;
      prev_crc <= '0; flush_p <= 1'b0; swd <= '0;
    end
  end

  logic [31:0] stall = 0;
  always @(posedge aclk) begin
    if (st == DATA && m_tvalid && !m_tready) begin
      stall <= stall + 1;
      if (stall >= stall_max) stall_max <= stall + 1;
    end else stall <= 0;
    if (clr_stall || !aresetn) stall_max <= 0;
  end
endmodule
`default_nettype wire
