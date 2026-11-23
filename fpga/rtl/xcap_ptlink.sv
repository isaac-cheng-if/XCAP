// HDMI loop-out: copies of the receiver's picture and sound for the transmitter, without ever holding the receiver up
// (the capture path keeps its own copy and must not see back-pressure).
//
// Video (clk = 300 MHz AXI4-Stream clock of both HDMI subsystems): frames enter an elastic FIFO only from their first
// beat (tuser). If the FIFO runs full the rest of that frame is dropped and the next frame starts clean, so the
// transmitter's bridge sees at most one short frame and locks again. With the transmitter's reference clock locked to
// the receiver's TMDS clock both ends run at the same pixel rate and the FIFO stays nearly empty.
// Audio (mclk, the subsystems' audio clock): the same idea per sample, no frame structure to keep.
// Both are cleared while disabled, so a restart never replays stale data.
`default_nettype none
module xcap_ptvideo #(parameter int DEPTH = 2048) (
  input  wire        clk,
  input  wire        en,                       // async (firmware register); cleared FIFO while 0
  input  wire [71:0] d, input wire sof, eol, valid,
  output wire [71:0] q, output wire q_sof, q_eol, q_valid,
  input  wire        q_ready,
  output logic [15:0] drops,                   // frames cut short, clk domain (quasi-static for readers)
  output logic        drop_t                   // toggles with every frame cut short (for a counter in another clock)
);
  initial drop_t = 1'b0;
  wire en_s;
  xpm_cdc_single #(.DEST_SYNC_FF(3), .INIT_SYNC_FF(1), .SRC_INPUT_REG(0)) u_en (.src_clk(1'b0), .src_in(en), .dest_clk(clk), .dest_out(en_s));
  logic rst = 1'b1;
  always @(posedge clk) rst <= !en_s;
  wire full, prog_full, empty, wr_busy, rd_busy;
  logic pass = 1'b0;
  // a frame is admitted at its first beat only when there is room for a good part of it
  wire admit = en_s && !prog_full && !wr_busy;
  wire pass_now = sof ? admit : pass;
  wire wr = valid && pass_now && !full && !wr_busy;
  always @(posedge clk) begin
    if (rst) begin pass <= 1'b0; drops <= 16'd0; end
    else if (valid) begin
      pass <= pass_now && !full;
      if (pass_now && full) begin drops <= drops + 16'd1; drop_t <= ~drop_t; end
    end
  end
  wire [73:0] dout;
  xpm_fifo_sync #(.FIFO_MEMORY_TYPE("block"), .FIFO_WRITE_DEPTH(DEPTH), .WRITE_DATA_WIDTH(74), .READ_DATA_WIDTH(74),
    .READ_MODE("fwft"), .FIFO_READ_LATENCY(0), .PROG_FULL_THRESH(DEPTH - 256), .USE_ADV_FEATURES("0002"),
    .WAKEUP_TIME(0), .ECC_MODE("no_ecc"), .DOUT_RESET_VALUE("0"), .FULL_RESET_VALUE(1)) u_f (
    .wr_clk(clk), .rst(rst), .wr_en(wr), .din({eol, sof, d}), .full(full), .prog_full(prog_full),
    .rd_en(q_valid && q_ready), .dout(dout), .empty(empty), .wr_rst_busy(wr_busy), .rd_rst_busy(rd_busy),
    .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0), .overflow(), .underflow(), .almost_full(), .almost_empty(),
    .wr_ack(), .data_valid(), .prog_empty(), .rd_data_count(), .wr_data_count(), .sbiterr(), .dbiterr());
  assign q_valid = !empty && !rd_busy;
  assign q = dout[71:0];
  assign q_sof = dout[72];
  assign q_eol = dout[73];
endmodule

module xcap_ptaudio (
  input  wire        clk,
  input  wire        en,                       // clk domain (firmware register)
  input  wire [31:0] d, input wire [2:0] id, input wire valid,
  output wire [31:0] q, output wire [2:0] q_id, output wire q_valid,
  input  wire        q_ready,
  output logic       drop_t                    // toggles with every subframe that found the FIFO full
);
  initial drop_t = 1'b0;
  logic rst = 1'b1;
  always @(posedge clk) rst <= !en;
  wire full, empty, wr_busy, rd_busy;
  always @(posedge clk) if (en && !rst && valid && full && !wr_busy) drop_t <= ~drop_t;
  wire [34:0] dout;
  xpm_fifo_sync #(.FIFO_MEMORY_TYPE("distributed"), .FIFO_WRITE_DEPTH(64), .WRITE_DATA_WIDTH(35), .READ_DATA_WIDTH(35),
    .READ_MODE("fwft"), .FIFO_READ_LATENCY(0), .USE_ADV_FEATURES("0000"), .WAKEUP_TIME(0), .ECC_MODE("no_ecc"),
    .DOUT_RESET_VALUE("0"), .FULL_RESET_VALUE(1)) u_f (
    .wr_clk(clk), .rst(rst), .wr_en(valid && !full && !wr_busy), .din({id, d}), .full(full),
    .rd_en(q_valid && q_ready), .dout(dout), .empty(empty), .wr_rst_busy(wr_busy), .rd_rst_busy(rd_busy),
    .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0), .overflow(), .underflow(), .almost_full(), .almost_empty(),
    .wr_ack(), .data_valid(), .prog_empty(), .prog_full(), .rd_data_count(), .wr_data_count(), .sbiterr(), .dbiterr());
  assign q_valid = !empty && !rd_busy;
  assign q = dout[31:0];
  assign q_id = dout[34:32];
endmodule

// What the receiver's sound is, for the firmware: a sink must only be sent a bitstream it lists in its EDID, and HDMI
// sources do not name the format in the audio infoframe. Taken from the IEC 60958 subframes themselves
// ([3:0] preamble code, 1 = block start; [27:4] sample; [30] channel status bit):
//   - channel status bit 1 of channel 0 ("not linear PCM"), the second bit of every 192-frame block
//   - the data type (Pc bits 4:0) of the IEC 61937 bursts: 16-bit words Pa = F872, Pb = 4E1F, Pc in consecutive
//     subframes. Null (0) and pause (3) bursts keep the last type.
// Both are forgotten when they have not been seen for a quarter of a second.
//   stat: [0] not PCM  [1] bursts seen  [2] channel status seen  [12:8] data type (0 = none yet)
module xcap_audfmt (
  input  wire        clk,                      // 100 MHz
  input  wire [31:0] d, input wire [2:0] id, input wire valid,
  output wire [31:0] stat
);
  logic        nonpcm = 1'b0;
  logic [1:0]  fr = 2'd3;                      // channel 0 frames since the block start: 1 = this one carries bit 1
  logic [1:0]  ps = 2'd0;                      // burst preamble words matched
  logic [4:0]  dtype = 5'd0;
  logic [19:0] pre = '0;                       // 10.5 ms steps for the two ages
  logic [4:0]  cs_age = '1, b_age = '1;        // 31 = not seen
  wire [15:0]  w = d[27:12];
  wire         step = &pre;
  always @(posedge clk) begin
    pre <= pre + 1'b1;
    if (step) begin                            // (what a subframe in this same cycle sets below wins)
      if (cs_age != 5'd31) cs_age <= cs_age + 5'd1;
      if (b_age  != 5'd31) b_age  <= b_age  + 5'd1;
      if (cs_age == 5'd23) begin nonpcm <= 1'b0; fr <= 2'd3; end
      if (b_age  == 5'd23) begin dtype <= 5'd0; ps <= 2'd0; end
    end
    if (valid) begin
      if (id == 3'd0) begin
        if (d[3:0] == 4'd1) fr <= 2'd1;
        else begin
          if (fr == 2'd1) begin nonpcm <= d[30]; cs_age <= '0; end
          if (fr != 2'd3) fr <= fr + 2'd1;
        end
      end
      case (ps)
        2'd0: if (w == 16'hF872) ps <= 2'd1;
        2'd1: ps <= (w == 16'h4E1F) ? 2'd2 : (w == 16'hF872) ? 2'd1 : 2'd0;
        default: begin
          ps <= 2'd0; b_age <= '0;
          if (w[4:0] != 5'd0 && w[4:0] != 5'd3) dtype <= w[4:0];
        end
      endcase
    end
  end
  assign stat = {19'd0, dtype, 5'd0, cs_age < 5'd24, b_age < 5'd24, nonpcm};
endmodule
`default_nettype wire
