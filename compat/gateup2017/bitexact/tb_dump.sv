`timescale 1ns/1ps
// Bit-exact comparison driver: replays axis-input.hex through one engine and
// dumps every output beat (value + TLAST) to a file named by +DUMP argument.
module tb_dump;
 `include "params.vh"
 reg clk=0,rst_n=0;always #6 clk=~clk;
 reg sv=0,sl=0,orr=0;reg[63:0] sd=0;
 wire sr,ov,ol,irq;wire[63:0] od;
 gateup_axis dut(.aclk(clk),.aresetn(rst_n),.s_axis_tdata(sd),.s_axis_tvalid(sv),
  .s_axis_tready(sr),.m_axis_tdata(od),.m_axis_tvalid(ov),
  .m_axis_tready(orr),.m_axis_tlast(ol),.irq(irq));
 reg[63:0] packets[0:TX_N-1];
 integer i=0,rx=0,seed=7;reg dumped=0;
 always @(posedge clk)begin
  orr<=rst_n&&((($random(seed))&3)!=0);
  if(ov&&orr)begin
   $fdisplay(fd,"%h %b",od[31:0],ol);
   rx=rx+1;
   if(rx==RX_N)begin $fclose(fd);$display("DUMP-DONE rows=%0d",rx);$finish;end
  end
 end
 integer fd;
 initial begin
  fd=$fopen(`DUMP_FILE,"w");
  $readmemh("axis-input.hex",packets);
  repeat(5)@(negedge clk);rst_n=1;
  for(i=0;i<TX_N;i=i+1)begin
   @(negedge clk);sd=packets[i];sv=1;sl=0;
   @(posedge clk);while(!sr)@(posedge clk);
   @(negedge clk);sv=0;
   if(($random(seed)&7)==0)repeat(4)@(negedge clk);
  end
  sv=0;
 end
 always begin #1000000000; if(!dumped)$display("DUMP-TIMEOUT rx=%0d",rx); end
endmodule
