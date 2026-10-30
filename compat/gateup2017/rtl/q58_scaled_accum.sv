`timescale 1ns/1ps
`default_nettype none
// Dual-term scaled accumulator (fusion-speedup full_source revision).
// Q5_0/Q8_0 path (dx2==0): term = (dw*dx)*dot, identical arithmetic to the
// delivery snapshot's q58_scaled_accum — exact FP16 mantissa product, exact
// per-block FP16-exponent left shift, 112-bit block-order accumulation, one
// final FP32 RNE.
// Q4_K path (dx2!=0): term = (dw*dx)*dot - (dw2*dx2)*sx, implementing
// sum_blocks [ d*sc*Snq - dmin*m*Sx ] with dw=d, dx=sc, dw2=dmin, dx2=m
// (sc and m are 6-bit integers carried as exact FP16).
// Both coefficient products run in parallel; steady state is 4 cycles per
// block, matching the dot32 feed cadence.
module q58_scaled_accum (
 input wire clk,rst_n,
 input wire signed[31:0] dot,input wire signed[31:0] sx,
 input wire[15:0] dw,dx,dw2,dx2,
 input wire in_first,in_last,in_valid,output wire in_ready,
 output reg[31:0] result,output reg out_valid,input wire out_ready
);
 localparam IDLE=0,PRODUCT=1,ALIGN1=2,ALIGN2=3,ADD=4,FIND=5,ROUND=6,HOLD=7;
 reg[2:0] state;
 wire[10:0] mw={dw[14:10]!=0,dw[9:0]},mx={dx[14:10]!=0,dx[9:0]};
 wire[10:0] mw2={dw2[14:10]!=0,dw2[9:0]},mx2={dx2[14:10]!=0,dx2[9:0]};
 wire[5:0] ew=dw[14:10]==0?6'd1:{1'b0,dw[14:10]};
 wire[5:0] ex=dx[14:10]==0?6'd1:{1'b0,dx[14:10]};
 wire[5:0] ew2=dw2[14:10]==0?6'd1:{1'b0,dw2[14:10]};
 wire[5:0] ex2=dx2[14:10]==0?6'd1:{1'b0,dx2[14:10]};
 reg[21:0] coefficient,coefficient2;
 reg signed[20:0] integer_dot,integer_sx;
 reg signed[43:0] product,product2;
 reg[5:0] shift,shift2;
 reg negate,negate2,first_block,last_block;
 reg signed[111:0] term,term2,accumulator;
 wire signed[111:0] extended_product={{68{product[43]}},product};
 wire signed[111:0] signed_product=negate?-extended_product:extended_product;
 wire signed[111:0] extended_product2={{68{product2[43]}},product2};
 wire signed[111:0] signed_product2=negate2?-extended_product2:extended_product2;
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
   coefficient<=0;coefficient2<=0;integer_dot<=0;integer_sx<=0;
   product<=0;product2<=0;term<=0;term2<=0;
   shift<=0;shift2<=0;negate<=0;negate2<=0;first_block<=0;last_block<=0;
   magnitude<=0;negative<=0;highest<=0;
  end else case(state)
   IDLE:if(in_valid)begin
    coefficient<=mw*mx;coefficient2<=mw2*mx2;
    integer_dot<=dot[20:0];integer_sx<=sx[11:0];
    shift<=ew+ex-6'd2;shift2<=ew2+ex2-6'd2;
    negate<=dw[15]^dx[15];negate2<=dw2[15]^dx2[15];
    first_block<=in_first;last_block<=in_last;state<=PRODUCT;
   end
   PRODUCT:begin
    product<=integer_dot*$signed({1'b0,coefficient});
    product2<=integer_sx*$signed({1'b0,coefficient2});
    state<=ALIGN1;
   end
   ALIGN1:begin term<=signed_product<<<shift;state<=ALIGN2;end
   ALIGN2:begin term2<=signed_product2<<<shift2;state<=ADD;end
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
