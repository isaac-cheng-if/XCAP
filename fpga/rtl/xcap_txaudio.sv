// Audio for the HDMI transmitter used in loopback tests: one 24-bit counter, one step per subframe, spread over
// 2 or 8 channels (the capture side checks it like the test pattern audio), plus the ACR values the firmware sets.
//   out: IEC 60958 subframes as the HDMI TX subsystem takes them: [3:0] preamble code (1 B, 2 M, 3 W),
//        [27:4] sample, [28] V, [29] U, [30] C, [31] parity; tid = channel
`default_nettype none
module xcap_txaudio #(parameter int CLK_HZ = 100000000) (
  input  wire        clk, rst,
  input  wire        en,
  input  wire [3:0]  channels,               // 2 or 8
  input  wire [31:0] rate,                   // subframes per second
  output logic [31:0] tdata, output logic [7:0] tid, output logic tvalid, input wire tready
);
  logic [31:0] acc = 0; logic [7:0] owed = 0; logic [23:0] ramp = 0; logic [3:0] ch = 0; logic [7:0] frame = 0;
  initial tvalid = 0;
  wire [31:0] next = acc + rate;
  wire [26:0] body = {3'b000, ramp};               // C U V = 0: linear PCM
  wire [3:0]  pre  = ch != 0 ? (ch[0] ? 4'd3 : 4'd2) : (frame == 0 ? 4'd1 : 4'd2);
  wire tick = next >= CLK_HZ;
  wire take = tvalid && tready;
  always @(posedge clk) begin
    acc <= tick ? next - CLK_HZ : next;
    if (!en || rst) begin owed <= 0; tvalid <= 0; ch <= 0; frame <= 0; end
    else begin
      owed <= owed + (tick && owed != 8'hFF ? 8'd1 : 8'd0) - (take ? 8'd1 : 8'd0);
      if (take) begin
        tvalid <= 0;
        ramp <= ramp + 24'd1;
        if (ch == channels - 4'd1) begin ch <= 0; frame <= (frame == 8'd191) ? 8'd0 : frame + 8'd1; end else ch <= ch + 4'd1;
      end else if (!tvalid && owed != 0) begin
        tvalid <= 1;
        tdata <= {^body, body, pre};
        tid <= {4'd0, ch};
      end
    end
  end
endmodule
`default_nettype wire
