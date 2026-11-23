`timescale 1ns/1ps
module tb_core;
  logic aclk = 0, vclk = 0, rstn = 0;
  always #2 aclk = ~aclk;
  always #1.684 vclk = ~vclk;
  logic [31:0] awaddr, wdata, araddr; logic awvalid = 0, wvalid = 0, arvalid = 0; wire awready, wready, arready, bvalid, rvalid; wire [31:0] rdata;
  wire [127:0] td; wire tv, tl;
  wire [127:0] atd; wire atv, atl; logic atr = 0; logic [127:0] aq[$]; int apk = 0, agaps = 0, afl = 0, aud_total = 0, errors = 0; logic [31:0] aseq = 0; logic [23:0] aexp = 0; bit ahave = 0;
  always @(negedge aclk) atr <= ($urandom_range(0, 9) < 7);
  always @(posedge aclk) if (atv && atr) begin
    aq.push_back(atd);
    if (atl) begin
      if (aq.size() == 1) afl++;
      else begin
        int nw; apk++; nw = aq[0][95:64]; aud_total += nw;
        if (aq.size() != 128 || aq[0][31:0] != 32'h55414358 || aq[0][63:32] != aseq || nw > 508) begin errors++; $display("ERR audio packet size %0d hdr %h seq %0d", aq.size(), aq[0], aseq); end
        aseq = aq[0][63:32] + 1;
        for (int i = 0; i < nw; i++) begin
          logic [31:0] aw; aw = aq[1 + i/4][(i%4)*32 +: 32];
          if (!aw[31]) begin errors++; $display("ERR audio word"); end
          if (ahave && aw[23:0] != aexp) agaps++;
          aexp = aw[23:0] + 24'd1; ahave = 1;
        end
        for (int i = nw; i < 508; i++) if (aq[1 + i/4][(i%4)*32 +: 32] != 0) begin errors++; $display("ERR audio pad"); end
      end
      aq.delete();
    end
  end logic tr = 0;
  int W = 24, H = 6;
  xcap_core #(.FIFO_DEPTH(512), .WATCHDOG(12), .MCLK_HZ(480000)) dut (.aclk, .aresetn(rstn), .vclk, .vlock(1'b1), .ext_valid(1'b0), .ext_sof(1'b0), .ext_eol(1'b0), .ext_data('0), .ext_meta('0), .host_ctrl(), .tx_ctrl(), .edid_we(), .edid_wa(), .edid_wd(), .mclk(vclk), .mrst(1'b0), .aud_tdata('0), .aud_tid('0), .aud_tvalid(1'b0), .pt_vdrop(1'b0), .pt_adrop(1'b0), .a_tdata(atd), .a_tvalid(atv), .a_tlast(atl), .a_tready(atr),
    .s_awaddr(awaddr), .s_awvalid(awvalid), .s_awready(awready), .s_wdata(wdata), .s_wstrb(4'hF), .s_wvalid(wvalid), .s_wready(wready),
    .s_bresp(), .s_bvalid(bvalid), .s_bready(1'b1), .s_araddr(araddr), .s_arvalid(arvalid), .s_arready(arready), .s_rdata(rdata), .s_rresp(), .s_rvalid(rvalid), .s_rready(1'b1),
    .m_tdata(td), .m_tvalid(tv), .m_tlast(tl), .m_tready(tr), .activity());
  task wr(input [31:0] a, d);
    @(posedge aclk); #0.1; awaddr = a; wdata = d; awvalid = 1; wvalid = 1;
    fork
      begin do @(posedge aclk); while (!awready); #0.1 awvalid = 0; end
      begin do @(posedge aclk); while (!wready);  #0.1 wvalid = 0; end
    join
    while (!bvalid) @(posedge aclk); @(posedge aclk);
  endtask
  task rd(input [31:0] a, output [31:0] d);
    @(posedge aclk); #0.1; araddr = a; arvalid = 1;
    do @(posedge aclk); while (!arready); #0.1 arvalid = 0; do @(posedge aclk); while (!rvalid); d = rdata; @(posedge aclk);
  endtask
  function automatic [31:0] crc1(input [31:0] c, input [31:0] d);
    logic [31:0] x = c ^ d; for (int i = 0; i < 32; i++) x = x[0] ? ((x >> 1) ^ 32'h82F63B78) : (x >> 1); return x;
  endfunction
  logic [127:0] q[$]; int frames = 0, good = 0, bads = 0, reps = 0, discs = 0; int stallmode = 0; logic [31:0] exp_seq = 0;
  int fmt = 0, data_beats, pad_beats;
  int rnd; int sb = 8; int flushing = 0, fl_pk = 0, fl_beats = 0;
  always @(posedge aclk) begin
    if (tv && tr) begin
      q.push_back(td);
      if (tl) begin if (flushing) begin fl_pk++; fl_beats = q.size(); end else check(); q.delete(); end
    end
  end
  always @(negedge aclk) begin rnd = $urandom_range(0, 99); tr <= (stallmode == 0) ? 1'b1 : (stallmode == 1) ? (rnd < 50) : 1'b0; end
  function automatic [9:0] Y(int x, int y, int n); return 10'(x + 3*y + 7*n); endfunction
  function automatic [9:0] C(int x, int y, int n); return 10'(x) ^ 10'(y) ^ 10'(5*n); endfunction
  task automatic check();
    logic [127:0] w, e; logic [31:0] crc[4]; logic [31:0] n; int b, flags, bandn; logic [127:0] bands[$];
    frames++;
    if (q.size() != 512 + data_beats + pad_beats) begin errors++; $display("ERR size %0d at frame %0d", q.size(), frames); return; end
    if (q[0][31:0] != 32'h48464358 || q[0][95:64] != exp_seq) begin errors++; $display("ERR hdr %h seq exp %0d", q[0], exp_seq); end
    exp_seq = q[0][95:64] + 1;
    n = q[2][95:64];
    w = q[256 + data_beats + pad_beats]; flags = w[95:64];
    if (w[31:0] != 32'h54464358 || w[63:32] != q[0][95:64]) begin errors++; $display("ERR trl %h", w); end
    if (q[0][96+2]) discs++;
    if (flags & 1) begin bads++; return; end
    good++; if (flags & 2) reps++;
    for (int l = 0; l < 4; l++) crc[l] = 32'hFFFFFFFF;
    for (b = 0; b < data_beats; b++) begin
      w = q[256 + b];
      for (int l = 0; l < 4; l++) crc[l] = crc1(crc[l], w[l*32 +: 32]);
      if (b == data_beats-1 || (b % sb) == sb-1) bands.push_back({crc[3], crc[2], crc[1], crc[0]});
      if (fmt == 0) begin
        int wpl = W/6; int y = b / wpl; int x = (b % wpl) * 6;
        e = {2'b0, Y(x+5,y,n), C(x+5,y,n), Y(x+4,y,n), 2'b0, C(x+4,y,n), Y(x+3,y,n), C(x+3,y,n), 2'b0, Y(x+2,y,n), C(x+2,y,n), Y(x+1,y,n), 2'b0, C(x+1,y,n), Y(x,y,n), C(x,y,n)};
      end else begin
        int wpl = W/4; int y = b / wpl; int x = (b % wpl) * 4; e = 0;
        for (int k = 0; k < 4; k++) begin logic [9:0] yy = Y(x+k,y,n), cc = C(x+k,y,n), rr = yy ^ cc; e[k*32 +: 32] = {8'hFF, rr[9:2], yy[9:2], cc[9:2]}; end
      end
      if (w !== e) begin errors++; if (errors < 10) $display("ERR data frame %0d beat %0d got %h exp %h", frames, b, w, e); end
    end
    w = q[256 + data_beats + pad_beats + 3];
    if (w !== {crc[3], crc[2], crc[1], crc[0]}) begin errors++; $display("ERR crc %h exp %h", w, {crc[3],crc[2],crc[1],crc[0]}); end
    w = q[256 + data_beats + pad_beats + 2];
    if (w[127:96] != bands.size()) begin errors++; $display("ERR bands %0d exp %0d", w[127:96], bands.size()); end
    foreach (bands[i]) if (q[256 + data_beats + pad_beats + 4 + i] !== bands[i]) begin errors++; $display("ERR band %0d", i); end
  endtask
  logic [31:0] v;
  task automatic cfg(input int f);
    fmt = f; data_beats = f ? (W/4)*H : (W/6)*H; pad_beats = 5;
    wr(32'h10, data_beats); wr(32'h14, pad_beats); wr(32'h18, {16'(H), 16'(W)}); wr(32'h1C, f ? W*4 : (W/6)*16); wr(32'h20, f); wr(32'h24, sb);
    wr(32'h60, 0); wr(32'h64, 2); wr(32'h68, {16'd200, 16'(W/2)}); wr(32'h6C, {16'd12, 16'(H)});
  endtask
  initial begin
    repeat (20) @(posedge aclk); rstn = 1; repeat (50) @(posedge aclk);
    rd(0, v); if (v != 32'h58434150) begin errors++; $display("ERR id %h", v); end
    wr(32'h80, 32'hCAFEBABE); rd(32'h80, v); if (v != 32'hCAFEBABE) errors++;
    cfg(0); wr(32'h8, 32'hD); repeat (40000) @(posedge aclk);
    $display("A v210 free: frames %0d good %0d rep %0d err %0d", frames, good, reps, errors);
    stallmode = 1; repeat (40000) @(posedge aclk);
    $display("B random stall: frames %0d good %0d bad %0d err %0d", frames, good, bads, errors);
    stallmode = 2; repeat (30000) @(posedge aclk); stallmode = 0; repeat (20000) @(posedge aclk);
    rd(32'h40, v); $display("C long stall: frames %0d good %0d bad %0d disc %0d drop %0d err %0d", frames, good, bads, discs, v, errors);
    // stop, change format, restart
    wr(32'h8, 32'h0); do begin rd(32'hC, v); end while (v & 1); repeat (30000) @(posedge aclk);
    cfg(1); wr(32'h8, 32'h5); repeat (30000) @(posedge aclk);
    $display("D bgrx: frames %0d good %0d bad %0d err %0d", frames, good, bads, errors);
    // source stops in the middle of a frame: watchdog pads it, stream recovers
    do @(posedge vclk); while (!dut.v_valid); repeat (2500) @(posedge vclk); do @(posedge vclk); while (!(dut.v_valid && dut.u_framer.vrun && dut.u_framer.vcount == 10)); force dut.v_valid = 1'b0; repeat (9000) @(posedge aclk); release dut.v_valid; repeat (20000) @(posedge aclk);
    $display("E source gap: frames %0d good %0d bad %0d err %0d", frames, good, bads, errors);
    // bigger frame than the FIFO with the DMA stalled: overflow path
    wr(32'h8, 32'h0); do begin rd(32'hC, v); end while (v & 1); repeat (30000) @(posedge aclk);
    W = 96; H = 64; sb = 32; cfg(0); wr(32'h68, {16'd56, 16'd48}); wr(32'h6C, {16'd70, 16'd64}); wr(32'h8, 32'h5);
    repeat (20000) @(posedge aclk);
    stallmode = 2; repeat (6000) @(posedge aclk); stallmode = 0; repeat (30000) @(posedge aclk);
    rd(32'h44, v); $display("F overflow: frames %0d good %0d bad %0d (reg %0d) err %0d", frames, good, bads, v, errors);
    wr(32'h8, 32'h0); do begin rd(32'hC, v); end while (v & 1); repeat (3000) @(posedge aclk);
    q.delete(); flushing = 1; wr(32'h50, 3); repeat (50) @(posedge aclk);
    $display("G flush: packets %0d beats-in-packet %0d err %0d", fl_pk, fl_beats, errors); if (fl_pk != 1 || fl_beats != 1) errors++;
    flushing = 0; exp_seq = exp_seq; wr(32'h8, 32'h5); repeat (20000) @(posedge aclk); $display("H restart: frames %0d good %0d err %0d", frames, good, errors);
    // the DMA stops taking data in the middle of a frame and the host stops the stream: the framer gives the frame up by
    // itself (2^WATCHDOG cycles), or at once on abort, and the next run starts with a whole frame
    stallmode = 2; repeat (3000) @(posedge aclk); wr(32'h8, 32'h0); repeat (3000) @(posedge aclk);
    rd(32'hC, v); if (!(v & 1)) begin errors++; $display("ERR stalled frame was not kept"); end
    repeat (3000) @(posedge aclk); rd(32'hC, v); if (v & 1) begin errors++; $display("ERR no give-up after stop"); end
    q.delete(); stallmode = 0; wr(32'h8, 32'h5); repeat (20000) @(posedge aclk); $display("I stop while stalled: frames %0d good %0d err %0d", frames, good, errors);
    stallmode = 2; repeat (3000) @(posedge aclk); wr(32'h8, 32'h0); wr(32'h50, 32'h4); rd(32'hC, v); if (v & 1) begin errors++; $display("ERR abort"); end
    q.delete(); stallmode = 0; wr(32'h8, 32'h5); repeat (20000) @(posedge aclk); $display("J abort: frames %0d good %0d err %0d", frames, good, errors);
    $display("audio packets %0d words %0d gaps %0d flushes %0d", apk, aud_total, agaps, afl); $display(errors == 0 && aud_total > 1000 && agaps == 0 && afl == 1 && good > 80 && bads > 0 ? "TB PASS" : "TB FAIL"); $finish;
  end
endmodule
