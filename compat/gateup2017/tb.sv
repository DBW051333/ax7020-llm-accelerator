`timescale 1ns/1ps
module tb_gateup;
 `include "params.vh"
 reg clk=0,rst_n=0;always #6 clk=~clk;
 reg mv=0,mr=0,av=0,ar=0;reg[63:0] mi=0,ai=0;
 wire mir,mov,air,aov;wire[31:0] mo,ao;
 gateup_fp_mul mul(.clk(clk),.rst_n(rst_n),.a(mi[63:32]),.b(mi[31:0]),
  .in_valid(mv),.in_ready(mir),.result(mo),.out_valid(mov),.out_ready(mr));
 gateup_silu_mul act(.clk(clk),.rst_n(rst_n),.gate_value(ai[63:32]),.up_value(ai[31:0]),
  .in_valid(av),.in_ready(air),.result(ao),.out_valid(aov),.out_ready(ar));
 reg[63:0] mp[0:MUL_N-1],ap[0:ACT_N-1];
 reg[31:0] mg[0:MUL_N-1],ag[0:ACT_N-1];
 reg sv=0,sl=0,orr=0;reg[63:0] sd=0;
 wire sr,ov,ol,irq;wire[63:0] od;
 gateup_axis dut(.aclk(clk),.aresetn(rst_n),.s_axis_tdata(sd),.s_axis_tvalid(sv),
  .s_axis_tready(sr),.s_axis_tlast(sl),.m_axis_tdata(od),.m_axis_tvalid(ov),
  .m_axis_tready(orr),.m_axis_tlast(ol),.irq(irq));
 reg[63:0] packets[0:TX_N-1];reg[31:0] gold[0:RX_N-1],last[0:RX_N-1];
 integer cycles=0,seed=29,i,rx=0,tx=0;reg pending=0;reg[63:0] held;reg held_last;
 real observed,expected,diff,se=0,sr2=0,maxerr=0;
 function real val(input[31:0] v);
  integer exponent;
  begin
   exponent=v[30:23];
   if(exponent==0)val=(v[31]?-1.0:1.0)*v[22:0]*$pow(2.0,-149);
   else val=(v[31]?-1.0:1.0)*(8388608.0+v[22:0])*$pow(2.0,exponent-150);
  end
 endfunction
 always @(posedge clk)begin
  cycles=cycles+1;if(cycles>3000000)$fatal(1,"GATEUP-WATCHDOG tx=%d rx=%d",tx,rx);
  if(rst_n)begin
   if(pending && (!ov || od!==held || ol!==held_last))$fatal(1,"AXIS backpressure changed output");
   pending<=ov&&!orr;held<=od;held_last<=ol;
   if(ov&&orr)begin
    if(rx>=RX_N || (^od===1'bx) || od[30:23]==255 || od[63:32]!=0)$fatal(1,"AXIS invalid result");
    if(ol!==last[rx][0])$fatal(1,"AXIS TLAST mismatch row %d",rx);
    observed=val(od[31:0]);expected=val(gold[rx]);diff=observed-expected;
    if(diff<0)diff=-diff;
    if(diff>1e-5+5e-6*(expected<0?-expected:expected))$fatal(1,"AXIS numeric row=%d got=%g ref=%g",rx,observed,expected);
    se=se+diff*diff;sr2=sr2+expected*expected;if(diff>maxerr)maxerr=diff;
    rx=rx+1;
   end
  end
 end
 always @(negedge clk)orr=rst_n&&(cycles%997<910)&&(($random(seed)&3)!=0);
 initial begin
  $readmemh("mul-input.hex",mp);$readmemh("mul-gold.hex",mg);
  $readmemh("act-input.hex",ap);$readmemh("act-gold.hex",ag);
  $readmemh("axis-input.hex",packets);$readmemh("axis-gold.hex",gold);$readmemh("axis-last.hex",last);
  repeat(5)@(negedge clk);rst_n=1;
  for(i=0;i<MUL_N;i=i+1)begin
   @(negedge clk);mi=mp[i];mv=1;mr=0;
   @(posedge clk);while(!mir)@(posedge clk);
   @(negedge clk);mv=0;wait(mov);repeat(2)@(negedge clk);
   if(mo!==mg[i])$fatal(1,"FP-MUL mismatch i=%d a=%h b=%h got=%h ref=%h",i,mi[63:32],mi[31:0],mo,mg[i]);
   mr=1;@(posedge clk);@(negedge clk);mr=0;
  end
  $display("FP-MUL-PASS vectors=%d",MUL_N);
  for(i=0;i<ACT_N;i=i+1)begin
   @(negedge clk);ai=ap[i];av=1;ar=0;
   @(posedge clk);while(!air)@(posedge clk);
   @(negedge clk);av=0;wait(aov);repeat(2)@(negedge clk);
   observed=val(ao);expected=val(ag[i]);diff=observed-expected;if(diff<0)diff=-diff;
   if((^ao===1'bx)||ao[30:23]==255||diff>1e-5+5e-6*(expected<0?-expected:expected))
    $fatal(1,"SILU mismatch i=%d gate=%h up=%h got=%g ref=%g",i,ai[63:32],ai[31:0],observed,expected);
   ar=1;@(posedge clk);@(negedge clk);ar=0;
  end
  $display("SILU-MUL-PASS vectors=%d",ACT_N);
  for(tx=0;tx<TX_N;tx=tx+1)begin
   @(negedge clk);sd=packets[tx];sv=1;sl=(tx==TX_N-1);
   @(posedge clk);while(!sr)@(posedge clk);
   @(negedge clk);sv=0;
   if(($random(seed)&7)==0)repeat(4)@(negedge clk);
  end
  wait(rx==RX_N);repeat(50)@(negedge clk);
  $display("GATEUP-AXIS-PASS rows=%d max_abs=%g relative_L2=%g",rx,maxerr,$sqrt(se/sr2));$finish;
 end
endmodule
