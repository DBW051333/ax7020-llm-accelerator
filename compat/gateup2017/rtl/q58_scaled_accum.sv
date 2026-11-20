`timescale 1ns/1ps
`default_nettype none
// Dual-term scaled accumulator with a third (activation) scale factor.
// Q5_0/Q8_0 path (dx3=1.0): term = (dw*dx)*dot, bit-identical to the
// delivery snapshot's q58_scaled_accum.
// Q4_K path (dx=6-bit sc as fp16, dw2/dx2 = dmin/m, dx3 = Q8_0 activation
// block scale): term = (dw*dx)*dot*mx3 - (dw2*dx2)*sx*mx3, i.e.
// sum_blocks [ d*sc*Snq - dmin*m*Sx ] * xscale per activation block.
// All products are exact integer mantissa multiplies; one FP32 RNE at the
// end; accumulator LSB is 2^-48 in real units (the per-block shift formula
// absorbs the exponents; negative shifts round down below the LSB).
module q58_scaled_accum (
 input wire clk,rst_n,
 input wire signed[31:0] dot,input wire signed[31:0] sx,
 input wire[15:0] dw,dx,dw2,dx2,dx3,
 input wire in_first,in_last,in_valid,output wire in_ready,
 output reg[31:0] result,output reg out_valid,input wire out_ready
);
 localparam IDLE=0,PRODUCT=1,ALIGN1=2,ALIGN2=3,ADD=4,FIND=5,ROUND=6,HOLD=7;
 reg[2:0] state;
 wire[10:0] mw={dw[14:10]!=0,dw[9:0]},mx={dx[14:10]!=0,dx[9:0]};
 wire[10:0] mw2={dw2[14:10]!=0,dw2[9:0]},mx2={dx2[14:10]!=0,dx2[9:0]};
 wire[10:0] mx3={dx3[14:10]!=0,dx3[9:0]};
 wire[5:0] ew=dw[14:10]==0?6'd1:{1'b0,dw[14:10]};
 wire[5:0] ex=dx[14:10]==0?6'd1:{1'b0,dx[14:10]};
 wire[5:0] ew2=dw2[14:10]==0?6'd1:{1'b0,dw2[14:10]};
 wire[5:0] ex2=dx2[14:10]==0?6'd1:{1'b0,dx2[14:10]};
 wire[5:0] ex3=dx3[14:10]==0?6'd1:{1'b0,dx3[14:10]};
 reg[21:0] coefficient,coefficient2;
 reg[10:0] coefficient3;
 reg signed[20:0] integer_dot;
 reg signed[12:0] integer_sx;
 reg signed[53:0] product,product2;
 reg signed[7:0] sh1,sh2;
 reg negate,negate2,first_block,last_block;
 reg signed[111:0] term,term2,accumulator;
 wire signed[111:0] extended_product={{57{product[53]}},product};
 wire signed[111:0] signed_product=negate?-extended_product:extended_product;
 wire signed[111:0] extended_product2={{57{product2[53]}},product2};
 wire signed[111:0] signed_product2=negate2?-extended_product2:extended_product2;
 wire signed[111:0] scaled1=signed_product*$signed({1'b0,coefficient3});
 wire signed[111:0] scaled2=signed_product2*$signed({1'b0,coefficient3});
 wire signed[111:0] combined=term-term2;
 wire signed[111:0] next_sum=first_block?combined:accumulator+combined;
 reg[111:0] magnitude;
 reg negative;
 reg[6:0] highest;
 assign in_ready=state==IDLE;
 function automatic[6:0] msb_index(input[111:0] mag);
  reg[127:0] v;reg[6:0] n;
  begin
   v={16'd0,mag};n=0;
   if(|v[127:64])begin n=n+64;v=v>>64;end
   if(|v[63:32])begin n=n+32;v=v>>32;end
   if(|v[31:16])begin n=n+16;v=v>>16;end
   if(|v[15:8])begin n=n+8;v=v>>8;end
   if(|v[7:4])begin n=n+4;v=v>>4;end
   if(|v[3:2])begin n=n+2;v=v>>2;end
   if(v[1])n=n+1;
   msb_index=n;
  end
 endfunction
 function automatic[31:0] to_fp32(input[111:0] mag,input sign_bit,input[6:0] h);
  reg[6:0] s;reg[23:0] significand;reg[24:0] rounded;
  reg[7:0] exponent;reg guard_bit,sticky;
  begin
   s=0;guard_bit=0;sticky=0;exponent=8'd79+{1'b0,h};
   if(h>=23)begin
    s=h-23;significand=mag>>s;
    if(s!=0)begin
     guard_bit=mag[s-1];sticky=|(mag&((112'd1<<(s-1))-112'd1));
    end
   end else significand=mag<<(23-h);
   rounded={1'b0,significand}+(guard_bit&&(sticky||significand[0]));
   if(mag==0)to_fp32=0;
   else if(rounded[24])to_fp32={sign_bit,exponent+8'd1,23'd0};
   else to_fp32={sign_bit,exponent,rounded[22:0]};
  end
 endfunction
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=IDLE;out_valid<=0;result<=0;accumulator<=0;
   coefficient<=0;coefficient2<=0;coefficient3<=0;
   integer_dot<=0;integer_sx<=0;
   product<=0;product2<=0;term<=0;term2<=0;
   sh1<=0;sh2<=0;negate<=0;negate2<=0;first_block<=0;last_block<=0;
   magnitude<=0;negative<=0;highest<=0;
  end else case(state)
   IDLE:if(in_valid)begin
    coefficient<=mw*mx;coefficient2<=mw2*mx2;coefficient3<=mx3;
    integer_dot<=dot[20:0];integer_sx<=$signed(sx[12:0]);
    sh1<=$signed({2'b0,ew})+$signed({2'b0,ex})+$signed({2'b0,ex3})-8'd27;
    sh2<=$signed({2'b0,ew2})+$signed({2'b0,ex2})+$signed({2'b0,ex3})-8'd27;
    negate<=dw[15]^dx[15]^dx3[15];negate2<=dw2[15]^dx2[15]^dx3[15];
    first_block<=in_first;last_block<=in_last;state<=PRODUCT;
   end
   PRODUCT:begin
    product<=integer_dot*$signed({1'b0,coefficient});
    product2<=integer_sx*$signed({1'b0,coefficient2});
    state<=ALIGN1;
   end
   ALIGN1:begin
    term<=sh1[7]?(scaled1>>>(~sh1+8'd1)):(scaled1<<<sh1[6:0]);
    state<=ALIGN2;
   end
   ALIGN2:begin
    term2<=sh2[7]?(scaled2>>>(~sh2+8'd1)):(scaled2<<<sh2[6:0]);
    state<=ADD;
   end
   ADD:begin
    accumulator<=next_sum;
    if(last_block)begin magnitude<=next_sum[111]?-next_sum:next_sum;
     negative<=next_sum[111];state<=FIND;end else state<=IDLE;
   end
   FIND:begin highest<=msb_index(magnitude);state<=ROUND;end
   ROUND:begin result<=to_fp32(magnitude,negative,highest);out_valid<=1;state<=HOLD;end
   HOLD:if(out_ready)begin out_valid<=0;state<=IDLE;end
   default:state<=IDLE;
  endcase
 end
endmodule
`default_nettype wire
