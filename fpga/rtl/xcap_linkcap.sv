// Snapshot of the HDMI link data between the Video PHY and the HDMI cores: 512 clocks of all three TMDS channels
// (20 bits = two 10-bit characters each), one memory for the transmitter and one for the receiver. A debug aid in place
// of an ILA (the Vivado licence here has no debug cores). The MicroBlaze side arms it and reads it back through
// xcap_meta_regs; xsdb can read the same addresses.
`default_nettype none
module xcap_linkcap (
  input  wire        tclk, input wire [59:0] td,     // transmitter link clock and data
  input  wire        rclk, input wire [59:0] rd,     // receiver link clock and data
  input  wire        clk,                            // reader
  input  wire        arm,                            // clk: toggles start a new snapshot on both sides
  input  wire        side,                           // clk: 0 receiver, 1 transmitter
  input  wire [8:0]  addr,                           // clk: sample, one clock read latency
  output wire [59:0] q,
  output wire [1:0]  done                            // clk: {transmitter, receiver} snapshot complete
);
  wire [59:0] qr, qt; logic side_q = 0;
  always @(posedge clk) side_q <= side;
  assign q = side_q ? qt : qr;
  xcap_linkcap_side u_r (.wclk(rclk), .d(rd), .arm(arm), .clk(clk), .addr(addr), .q(qr), .done(done[0]));
  xcap_linkcap_side u_t (.wclk(tclk), .d(td), .arm(arm), .clk(clk), .addr(addr), .q(qt), .done(done[1]));
endmodule

module xcap_linkcap_side (
  input  wire        wclk, input wire [59:0] d,
  input  wire        arm, input wire clk, input wire [8:0] addr,
  output wire [59:0] q, output wire done
);
  wire a; logic a_q = 0; logic [9:0] n = 10'd512; logic [59:0] d_q;
  xpm_cdc_single #(.DEST_SYNC_FF(3), .INIT_SYNC_FF(1), .SRC_INPUT_REG(0)) u_a (.src_clk(clk), .src_in(arm), .dest_clk(wclk), .dest_out(a));
  always @(posedge wclk) begin
    d_q <= d; a_q <= a;
    if (a_q != a) n <= 0; else if (!n[9]) n <= n + 1'b1;
  end
  xpm_cdc_single #(.DEST_SYNC_FF(3), .INIT_SYNC_FF(1), .SRC_INPUT_REG(1)) u_d (.src_clk(wclk), .src_in(n[9]), .dest_clk(clk), .dest_out(done));
  xpm_memory_sdpram #(.ADDR_WIDTH_A(9), .ADDR_WIDTH_B(9), .BYTE_WRITE_WIDTH_A(60), .CLOCKING_MODE("independent_clock"),
    .MEMORY_PRIMITIVE("block"), .MEMORY_SIZE(512 * 60), .READ_DATA_WIDTH_B(60), .READ_LATENCY_B(1), .WRITE_DATA_WIDTH_A(60),
    .WRITE_MODE_B("read_first"), .USE_EMBEDDED_CONSTRAINT(0)) u_m (
    .clka(wclk), .ena(!n[9]), .wea(1'b1), .addra(n[8:0]), .dina(d_q),
    .clkb(clk), .enb(1'b1), .addrb(addr), .doutb(q), .rstb(1'b0), .regceb(1'b1),
    .sleep(1'b0), .injectsbiterra(1'b0), .injectdbiterra(1'b0), .sbiterrb(), .dbiterrb());
endmodule
`default_nettype wire
