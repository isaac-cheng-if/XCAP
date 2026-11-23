// Test pattern source. Same video interface the HDMI receiver will drive:
// two pixels per clock, three 12-bit components per pixel, SOF on the first
// pair of a frame, EOL on the last pair of a line. Never stalls.
//   4:2:2  comp0 = Y, comp1 = Cb (even pixel) / Cr (odd pixel)
//   RGB    comp0 = G, comp1 = B, comp2 = R
`default_nettype none
module xcap_tpg (
  input  wire        clk,
  input  wire        en,            // synchronous to clk
  input  wire        mode,          // 0 verify, 1 bars (static while en)
  input  wire [7:0]  repeat_n,      // identical frames per picture, 0 = 1
  input  wire [15:0] h_active, h_total, v_active, v_total, // h in pixel pairs
  output logic        valid, sof, eol,
  output logic [71:0] data,
  output logic [31:0] picture       // picture number of the frame being sent
);
  logic [15:0] h = 0, v = 0;
  logic [7:0]  rep = 0;
  logic        run = 0;
  logic [31:0] n = 0;
  logic [9:0]  n7 = 0, n5 = 0, y3 = 0;
  wire h_last = (h == h_total - 1);
  wire v_last = (v == v_total - 1);

  always @(posedge clk) begin
    if (!run) begin
      h <= 0; v <= 0; y3 <= 0; rep <= 0;
      run <= en;
    end else begin
      h <= h_last ? 16'd0 : h + 16'd1;
      if (h_last) begin
        v  <= v_last ? 16'd0 : v + 16'd1;
        y3 <= v_last ? 10'd0 : y3 + 10'd3;
        if (v_last) begin
          if (!en) run <= 0;
          if (rep + 8'd1 >= repeat_n) begin
            rep <= 0; n <= n + 1; n7 <= n7 + 10'd7; n5 <= n5 + 10'd5;
          end else rep <= rep + 8'd1;
        end
      end
    end
  end

  // stage 1: addresses
  logic        s1_de, s1_sof, s1_eol;
  logic [9:0]  s1_x, s1_base, s1_cx;
  logic [2:0]  s1_bar;
  logic [12:0] bar_cnt; logic [2:0] bar;
  logic        s1_inx, s1_iny;
  wire  [12:0] bar_w = h_active[15:3];
  wire  [15:0] box_x = {6'd0, n[7:0], 2'd0} + {7'd0, n[7:0], 1'd0}; // pairs, moves 12 pixels per picture
  wire  [15:0] box_y = {5'd0, n[7:0], 3'd0};
  logic [15:0] box_x_q, box_y_q, box_x_e, box_y_e;
  always @(posedge clk) begin
    box_x_q <= box_x; box_y_q <= box_y;
    box_x_e <= box_x_q + 16'd64; box_y_e <= box_y_q + 16'd128;
    s1_de   <= run && (h < h_active) && (v < v_active);
    s1_sof  <= run && (h == 0) && (v == 0);
    s1_eol  <= run && (h == h_active - 1) && (v < v_active);
    s1_x    <= {h[8:0], 1'b0};
    s1_base <= y3 + n7;
    s1_cx   <= v[9:0] ^ n5;
    s1_inx  <= (h >= box_x_q) && (h < box_x_e);
    s1_iny  <= (v >= box_y_q) && (v < box_y_e);
    if (h_last || !run) begin bar_cnt <= 0; bar <= 0; end
    else if (bar_cnt + 13'd1 == bar_w) begin bar_cnt <= 0; bar <= bar + 3'd1; end
    else bar_cnt <= bar_cnt + 13'd1;
    s1_bar  <= bar;
  end

  // stage 2: component values
  function automatic [29:0] bar_ycc(input [2:0] b); // 75 % bars, BT.709 narrow, {Cr,Cb,Y}
    case (b)
      3'd0: bar_ycc = {10'd512, 10'd512, 10'd721};
      3'd1: bar_ycc = {10'd543, 10'd176, 10'd674};
      3'd2: bar_ycc = {10'd176, 10'd589, 10'd581};
      3'd3: bar_ycc = {10'd207, 10'd253, 10'd534};
      3'd4: bar_ycc = {10'd817, 10'd771, 10'd251};
      3'd5: bar_ycc = {10'd848, 10'd435, 10'd204};
      3'd6: bar_ycc = {10'd481, 10'd848, 10'd111};
      default: bar_ycc = {10'd512, 10'd512, 10'd64};
    endcase
  endfunction
  logic        s2_de, s2_sof, s2_eol, s2_box;
  logic [9:0]  s2_y0, s2_y1, s2_c0, s2_c1;
  logic [29:0] s2_bar;
  always @(posedge clk) begin
    s2_de <= s1_de; s2_sof <= s1_sof; s2_eol <= s1_eol; s2_box <= s1_inx & s1_iny;
    s2_y0 <= s1_base + s1_x;
    s2_y1 <= s1_base + s1_x + 10'd1;
    s2_c0 <= s1_cx ^ s1_x;
    s2_c1 <= s1_cx ^ {s1_x[9:1], 1'b1};
    s2_bar <= bar_ycc(s1_bar);
  end

  wire [9:0] f_y0 = mode ? (s2_box ? 10'd940 : s2_bar[9:0])   : s2_y0;
  wire [9:0] f_y1 = mode ? (s2_box ? 10'd940 : s2_bar[9:0])   : s2_y1;
  wire [9:0] f_c0 = mode ? (s2_box ? 10'd512 : s2_bar[19:10]) : s2_c0;
  wire [9:0] f_c1 = mode ? (s2_box ? 10'd512 : s2_bar[29:20]) : s2_c1;
  always @(posedge clk) begin
    valid <= s2_de; sof <= s2_sof; eol <= s2_eol;
    data  <= {f_y1 ^ f_c1, 2'b00, f_c1, 2'b00, f_y1, 2'b00,
              f_y0 ^ f_c0, 2'b00, f_c0, 2'b00, f_y0, 2'b00};
    if (s2_sof) picture <= n;
  end
endmodule
`default_nettype wire
