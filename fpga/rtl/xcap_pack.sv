// Packs the two-pixel video interface into 128-bit words.
//   fmt 0: v210   (4:2:2 10-bit, 6 pixels per word)
//   fmt 1: BGRX8  (4 pixels per word)
// A line whose width is not a whole number of words is completed with zeros.
`default_nettype none
module xcap_pack (
  input  wire         clk,
  input  wire         fmt,
  input  wire         valid, sof, eol,
  input  wire [71:0]  data,
  output logic         wvalid, wsof,
  output logic [127:0] wdata
);
  wire [11:0] p0c0 = data[11:0],  p0c1 = data[23:12], p0c2 = data[35:24];
  wire [11:0] p1c0 = data[47:36], p1c1 = data[59:48], p1c2 = data[71:60];
  // one pair as {Cr, Cb, Y1, Y0} 10-bit
  wire [39:0] pair = {p1c1[11:2], p0c1[11:2], p1c0[11:2], p0c0[11:2]};
  wire [63:0] bgrx = {8'hFF, p1c2[11:4], p1c0[11:4], p1c1[11:4],
                      8'hFF, p0c2[11:4], p0c0[11:4], p0c1[11:4]};
  logic [1:0]  ph = 0;
  logic [39:0] a = 0, b = 0;
  logic [63:0] lo = 0;
  logic        first = 0;

  function automatic [127:0] v210(input [39:0] p, q, r);
    logic [9:0] y0, y1, y2, y3, y4, y5, cb0, cr0, cb2, cr2, cb4, cr4;
    {cr0, cb0, y1, y0} = p; {cr2, cb2, y3, y2} = q; {cr4, cb4, y5, y4} = r;
    v210 = {2'b00, y5, cr4, y4,  2'b00, cb4, y3, cr2,  2'b00, y2, cb2, y1,  2'b00, cr0, y0, cb0};
  endfunction

  wire [1:0] phase = sof ? 2'd0 : ph;
  wire       done  = fmt ? (phase == 2'd1 || eol) : (phase == 2'd2 || eol);
  always @(posedge clk) begin
    wvalid <= 1'b0;
    if (valid) begin
      if (sof) first <= 1'b1;
      if (phase == 2'd0) begin a <= pair; lo <= bgrx; end
      if (phase == 2'd1) b <= pair;
      ph <= done ? 2'd0 : phase + 2'd1;
      if (done) begin
        wvalid <= 1'b1;
        wsof   <= first | sof;
        first  <= 1'b0;
        if (fmt) wdata <= (phase == 2'd1) ? {bgrx, lo} : {64'd0, bgrx};
        else     wdata <= (phase == 2'd2) ? v210(a, b, pair) :
                          (phase == 2'd1) ? v210(a, pair, 40'd0) : v210(pair, 40'd0, 40'd0);
      end
    end
  end
endmodule
`default_nettype wire
