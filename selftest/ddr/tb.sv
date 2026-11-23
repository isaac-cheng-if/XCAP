`timescale 1ns/1ps
// quick behavioural check of memtest with a small model (forces 2^26 range to be short via early-terminating counters is not possible,
// so this bench only checks the first 4000 bursts of write/command ordering)
module tb; reg clk=0; always #1.667 clk=~clk; reg rst=1; 
 wire [28:0] a; wire [2:0] c; wire en; reg rdy=0; wire [127:0] wd; wire wr; reg wrdy=0; 
 memtest u(.clk,.rst,.run(1'b1),.clr(1'b0),.inj(1'b0),.app_addr(a),.app_cmd(c),.app_en(en),.app_rdy(rdy),.wdata(wd),.wren(wr),.wrdy(wrdy),.rdata(128'h0),.rvalid(1'b0));
 integer na=0, nd=0, bad=0; 
 always @(posedge clk) if(!rst) begin
   if(wr&&wrdy) nd<=nd+1;
   if(en&&rdy) begin na<=na+1; if(a[28:3]!==na[25:0]) bad<=bad+1; if(na>=nd) bad<=bad+1; if(c!==0) bad<=bad+1; end end
 always @(negedge clk) begin rdy<=($random%4)!=0; wrdy<=($random%5)!=0; end
 initial begin #50 rst=0; #30000; $display("cmds=%0d data=%0d bad=%0d",na,nd,bad); $finish; end
endmodule
