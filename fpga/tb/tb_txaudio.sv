`timescale 1ns/1ps
module tb_txaudio;
  logic clk = 0, rst = 1, ready = 0; always #5 clk = ~clk;
  wire [31:0] d; wire [7:0] id; wire v;
  xcap_txaudio #(.CLK_HZ(1000000)) dut (.clk, .rst, .en(1'b1), .channels(4'd8), .rate(32'd200000), .tdata(d), .tid(id), .tvalid(v), .tready(ready));
  int n = 0, err = 0, b = 0; logic [23:0] last = 0;
  always @(posedge clk) begin
    ready <= $urandom_range(0, 3) != 0;
    if (v && ready) begin
      if (n && d[27:4] != last + 1) err++;
      if (id != n % 8) err++;
      if (^d[31:4] != 1'b0) err++;                         // even parity over 27:4 plus the parity bit
      if (d[3:0] == 1) begin b++; if (n % (8 * 192) != 0) err++; end
      else if (d[3:0] != (id[0] ? 3 : 2)) err++;
      last = d[27:4]; n++;
    end
  end
  initial begin repeat (5) @(posedge clk); rst = 0; #2000000; $display("TXAUDIO words %0d (want ~400) blocks %0d err %0d", n, b, err); $finish; end
endmodule
