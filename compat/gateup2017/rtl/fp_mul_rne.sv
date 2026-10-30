`timescale 1ns/1ps
// Finite IEEE float32 multiplication, round-to-nearest-even including subnormals.
// Registered input, normalization, product, alignment and rounding.
module gateup_fp_mul (
 input wire clk,rst_n,input wire[31:0] a,b,input wire in_valid,output wire in_ready,
 output reg[31:0] result,output reg out_valid,input wire out_ready
);
 reg[2:0] state;
 reg sgn;
 reg[31:0] ar,br;
 reg[35:0] an,bn;
 reg[47:0] product;
 reg signed[11:0] exponent;
 reg[38:0] fields;
 reg zero_product;
 function automatic[35:0] norm(input[31:0] x);
  reg[23:0] m;reg signed[11:0] e;reg[4:0] shift;
  begin
   m={x[30:23]!=0,x[22:0]};shift=0;
   if(m!=0)begin
    if(!( |m[23:8]))begin m=m<<16;shift[4]=1;end
    if(!( |m[23:16]))begin m=m<<8;shift[3]=1;end
    if(!( |m[23:20]))begin m=m<<4;shift[2]=1;end
    if(!( |m[23:22]))begin m=m<<2;shift[1]=1;end
    if(!m[23])begin m=m<<1;shift[0]=1;end
   end
   e=(x[30:23]==0?-126:$signed({1'b0,x[30:23]})-127)-$signed({7'd0,shift});
   norm={e,m};
  end
 endfunction
 function automatic[38:0] align_fields(input[47:0] p,input signed[11:0] ex);
  reg signed[12:0] e;reg[8:0] shift;
  reg[47:0] q,shifted_low;reg guard_bit,sticky;
  begin
   e=$signed(ex)+$signed({12'd0,p[47]});shift=p[47]?9'd24:9'd23;
   if(e<=0)shift=shift+9'd1-e[8:0];
   q=shift>=49?0:p>>shift;
   guard_bit=shift>0 && shift<=48 ? p[shift-1]:0;
   shifted_low=shift>1 && shift<=48 ? (p<<(9'd49-shift)):0;
   sticky=shift>48 ? |p : |shifted_low;
   align_fields={e,q[23:0],guard_bit,sticky};
  end
 endfunction
 function automatic[31:0] round_fields(input[38:0] f,input is_zero,input s);
  reg signed[12:0] e;reg[24:0] rounded;
  begin
   e=$signed(f[38:26]);
   rounded={1'b0,f[25:2]}+(f[1]&&(f[0]||f[2]));
   if(is_zero)round_fields={s,31'd0};
   else if(e>=255)round_fields={s,8'hff,23'd0};
   else if(e<=0)round_fields={s,7'd0,rounded[23:0]};
   else if(rounded[24])begin
    if(e>=254)round_fields={s,8'hff,23'd0};
    else round_fields={s,8'(e+1),23'd0};
   end else round_fields={s,8'(e),rounded[22:0]};
  end
 endfunction
 assign in_ready=state==0;
 always @(posedge clk)begin
  if(!rst_n)begin state<=0;out_valid<=0;result<=0;product<=0;exponent<=0;sgn<=0;ar<=0;br<=0;an<=0;bn<=0;fields<=0;zero_product<=0;end
  else case(state)
   0:if(in_valid)begin ar<=a;br<=b;state<=1;end
   1:begin an<=norm(ar);bn<=norm(br);sgn<=ar[31]^br[31];state<=2;end
   2:begin
    product<=an[23:0]*bn[23:0];
    exponent<=$signed(an[35:24])+$signed(bn[35:24])+127;
    state<=3;
   end
   3:begin fields<=align_fields(product,exponent);zero_product<=product==0;state<=4;end
   4:begin result<=round_fields(fields,zero_product,sgn);out_valid<=1;state<=5;end
   5:if(out_ready)begin out_valid<=0;state<=0;end
   default:state<=0;
  endcase
 end
endmodule
