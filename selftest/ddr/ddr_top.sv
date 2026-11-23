// AXAU15 DDR4 full-capacity memory test (1 GB, 16 bit, DDR4-2400), controlled over JTAG by VIO
`timescale 1ns/1ps
module ddr_top(
  input  c0_sys_clk_p, c0_sys_clk_n,
  output c0_ddr4_act_n, output [16:0] c0_ddr4_adr, output [1:0] c0_ddr4_ba, output [0:0] c0_ddr4_bg,
  output [0:0] c0_ddr4_cke, c0_ddr4_odt, c0_ddr4_cs_n, c0_ddr4_ck_t, c0_ddr4_ck_c,
  output c0_ddr4_reset_n, inout [1:0] c0_ddr4_dm_dbi_n, inout [15:0] c0_ddr4_dq,
  inout [1:0] c0_ddr4_dqs_c, c0_ddr4_dqs_t,
  output [1:0] led
);
  wire clk, rst, calib;
  wire [28:0] app_addr; wire [2:0] app_cmd; wire app_en, app_rdy;
  wire [127:0] wdata, rdata; wire wren, wrdy, rvalid;
  ddr4_0 u_ddr4(
    .sys_rst(1'b0), .c0_sys_clk_p, .c0_sys_clk_n,
    .c0_ddr4_act_n, .c0_ddr4_adr, .c0_ddr4_ba, .c0_ddr4_bg, .c0_ddr4_cke, .c0_ddr4_odt, .c0_ddr4_cs_n,
    .c0_ddr4_ck_t, .c0_ddr4_ck_c, .c0_ddr4_reset_n, .c0_ddr4_dm_dbi_n, .c0_ddr4_dq, .c0_ddr4_dqs_c, .c0_ddr4_dqs_t,
    .c0_init_calib_complete(calib), .c0_ddr4_ui_clk(clk), .c0_ddr4_ui_clk_sync_rst(rst), .dbg_clk(), .dbg_bus(),
    .c0_ddr4_app_addr(app_addr), .c0_ddr4_app_cmd(app_cmd), .c0_ddr4_app_en(app_en), .c0_ddr4_app_hi_pri(1'b0),
    .c0_ddr4_app_wdf_data(wdata), .c0_ddr4_app_wdf_end(1'b1), .c0_ddr4_app_wdf_mask(16'h0), .c0_ddr4_app_wdf_wren(wren),
    .c0_ddr4_app_rd_data(rdata), .c0_ddr4_app_rd_data_end(), .c0_ddr4_app_rd_data_valid(rvalid),
    .c0_ddr4_app_rdy(app_rdy), .c0_ddr4_app_wdf_rdy(wrdy));

  wire run, clr, inj;                    // VIO controls
  wire [31:0] err_cnt, pass_cnt; wire [15:0] err_dq; wire [2:0] pat; wire [2:0] st;
  wire [25:0] first_addr; wire [127:0] first_diff; wire [31:0] wr_cyc, rd_cyc;
  memtest u_mt(.clk, .rst(rst | ~calib), .run, .clr, .inj,
    .app_addr, .app_cmd, .app_en, .app_rdy, .wdata, .wren, .wrdy, .rdata, .rvalid,
    .err_cnt, .pass_cnt, .err_dq, .pat, .st, .first_addr, .first_diff, .wr_cyc, .rd_cyc);
  vio_0 u_vio(.clk, .probe_in0(calib), .probe_in1(err_cnt), .probe_in2(pass_cnt), .probe_in3(err_dq),
    .probe_in4({st,pat}), .probe_in5(first_addr), .probe_in6(first_diff), .probe_in7(wr_cyc), .probe_in8(rd_cyc),
    .probe_out0(run), .probe_out1(clr), .probe_out2(inj));
  assign led = {calib, |err_cnt};
endmodule

module pgen(input clk, init, next, input [2:0] pat, output [127:0] d, output [25:0] idx_o);
  reg [25:0] idx; reg [31:0] x[0:3]; integer i;
  function [31:0] xs(input [31:0] a); reg [31:0] t; begin t=a^(a<<13); t=t^(t>>17); xs=t^(t<<5); end endfunction
  always @(posedge clk)
    if (init) begin idx<=0; x[0]<=32'h1234ABCD; x[1]<=32'hDEADBEE5; x[2]<=32'h0F1E2D3C; x[3]<=32'hA5C3961F; end
    else if (next) begin idx<=idx+1; for(i=0;i<4;i=i+1) x[i]<=xs(x[i]); end
  wire [127:0] a = {~idx[25:0],6'h15, idx[25:0],6'h2A, ~idx[25:0],6'h33, idx[25:0],6'h0C};
  wire [127:0] p = {x[3],x[2],x[1],x[0]};
  wire [127:0] w; genvar g; generate for(g=0;g<8;g=g+1) begin:gw assign w[g*16+:16] = 16'h1 << (idx[3:0]+g); end endgenerate
  reg [127:0] m;
  always @* case(pat)
    0: m=a; 1: m=~a; 2: m=p; 3: m=~p;
    4: m={4{32'hFFFF0000}}; 5: m={4{32'h0000FFFF}}; 6: m={4{32'h5555AAAA}}; default: m=w; endcase
  assign d=m; assign idx_o=idx;
endmodule

module memtest(input clk, rst, run, clr, inj,
  output [28:0] app_addr, output [2:0] app_cmd, output app_en, input app_rdy,
  output [127:0] wdata, output wren, input wrdy, input [127:0] rdata, input rvalid,
  output reg [31:0] err_cnt, pass_cnt, output reg [15:0] err_dq, output reg [2:0] pat, st,
  output reg [25:0] first_addr, output reg [127:0] first_diff, output reg [31:0] wr_cyc, rd_cyc);
  localparam IDLE=0, WINIT=1, WR=2, WDRAIN=3, RINIT=4, RD=5, RDRAIN=6, NEXT=7;
  reg [26:0] cc, dc, rc; reg [31:0] cyc; reg have_first; reg [9:0] dly;
  wire ginit = (st==WINIT)||(st==RINIT);
  wire [127:0] gd, ed; wire [25:0] gi, ei;
  // write data is registered behind the generator (skid: one output register)
  reg wv; reg [127:0] wd; wire wtake = !wv || wrdy; wire gen_go = (st==WR) && !dc[26] && wtake;
  pgen g_w(.clk, .init(ginit), .next(gen_go), .pat, .d(gd), .idx_o(gi));
  always @(posedge clk) if (rst) begin wv<=0; end else begin
    if (gen_go) begin wv<=1; wd<=gd ^ {127'b0,(inj && gi==26'd12345)}; end else if (wrdy) wv<=0; end
  assign wren=wv, wdata=wd;
  reg [26:0] acc;                         // accepted write-data beats
  // commands: write command only after its data was accepted
  wire can_w = (st==WR||st==WDRAIN) && !cc[26] && (cc<acc);
  reg can_w_q; 
  wire can_r = (st==RD) && !cc[26];
  assign app_en = can_w_q || can_r;
  assign app_cmd = (st==RD) ? 3'b001 : 3'b000;
  assign app_addr = {cc[25:0],3'b000};
  always @(posedge clk) begin
    // can_w_q must reflect the state after an accepted command: conservative margin of 2
    can_w_q <= !rst && (st==WR||st==WDRAIN) && ((cc + 27'd2) <= acc || (dc[26] && acc[26] && (cc + ((can_w_q&&app_rdy)?27'd1:27'd0)) < 27'h4000000));
  end
  // read checker pipeline
  reg v1; reg [127:0] r1,e1; reg [25:0] i1; reg v2; reg [127:0] x2; reg [25:0] i2; reg v3,nz3; reg [127:0] x3; reg [15:0] q3; reg [25:0] i3;
  pgen g_r(.clk, .init(ginit), .next(rvalid), .pat, .d(ed), .idx_o(ei));
  integer k;
  always @(posedge clk) begin
    v1<=rvalid && !rst; r1<=rdata; e1<=ed; i1<=ei;
    v2<=v1; x2<=r1^e1; i2<=i1;
    v3<=v2; x3<=x2; i3<=i2;
    for(k=0;k<16;k=k+1) q3[k] <= x2[k]|x2[k+16]|x2[k+32]|x2[k+48]|x2[k+64]|x2[k+80]|x2[k+96]|x2[k+112];
    if (rst||clr) begin err_cnt<=0; err_dq<=0; have_first<=0; first_addr<=0; first_diff<=0; end
    else if (v3 && |q3) begin err_dq<=err_dq|q3; if(~&err_cnt) err_cnt<=err_cnt+1;
      if(!have_first) begin have_first<=1; first_addr<=i3; first_diff<=x3; end end
  end
  always @(posedge clk) if (rst) begin st<=IDLE; pat<=0; pass_cnt<=0; cc<=0; dc<=0; rc<=0; acc<=0; cyc<=0; wr_cyc<=0; rd_cyc<=0; dly<=0; end
  else begin
    if (clr) pass_cnt<=0;
    cyc<=cyc+1;
    if (gen_go) dc<=dc+1;
    if (wv&&wrdy) acc<=acc+1;
    if (app_en&&app_rdy) cc<=cc+1;
    if (rvalid) rc<=rc+1;
    case(st)
      IDLE: if(run) st<=WINIT;
      WINIT: begin cc<=0; dc<=0; acc<=0; cyc<=0; st<=WR; end
      WR: if (dc[26]) st<=WDRAIN;
      WDRAIN: if (cc[26] && acc[26]) begin wr_cyc<=cyc; st<=RINIT; end
      RINIT: begin cc<=0; rc<=0; cyc<=0; st<=RD; end
      RD: if (cc[26]) st<=RDRAIN;
      RDRAIN: if (rc[26]) begin rd_cyc<=cyc; dly<=0; st<=NEXT; end
      NEXT: begin dly<=dly+1; if(dly==20) begin pat<=pat+1; if(pat==7) pass_cnt<=pass_cnt+1; st<= run?WINIT:IDLE; end end
    endcase
  end
endmodule
