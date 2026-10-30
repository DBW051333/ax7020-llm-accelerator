`timescale 1ns/1ps
// SiLU(gate)*up. Sigmoid uses Q30 ROM and linear interpolation, step 1/256.
// Input magnitude is quantized to Q20; tails beyond |32| saturate.
module gateup_silu_mul (
 input wire clk,rst_n,input wire[31:0] gate_value,up_value,
 input wire in_valid,output wire in_ready,
 output reg[31:0] result,output reg out_valid,input wire out_ready
);
 localparam IDLE=0,ROM=1,DIFF=2,PRODUCT=3,SUM=4,NEGATE=5,FIND=6,CONVERT=7,M1=8,W1=9,M2=10,W2=11,HOLD=12;
 reg[3:0] state;
 reg[31:0] gate_reg,up_reg,sigmoid_float,silu_value;
 reg[30:0] sigmoid_rom[0:8192];
 reg[30:0] lower,upper,probability;
 reg[30:0] difference,base_value,positive_probability;
 reg[42:0] interpolation_product;
 reg[4:0] highest;
 reg[13:0] index;
 reg[11:0] fraction;
 reg negative;
 initial $readmemh("sigmoid.hex",sigmoid_rom);
 function automatic[25:0] magnitude_q20(input[31:0] x);
  reg[23:0] m;reg[4:0] shift;reg[25:0] v;
  begin
   m={1'b1,x[22:0]};shift=8'd130-x[30:23];
   if(x[30:23]<=106)magnitude_q20=0;
   else if(x[30:23]>=132)magnitude_q20=26'd33554432;
   else begin
    if(x[30:23]==131)v={2'd0,m}<<1;
    else v={2'd0,m}>>shift;
    magnitude_q20=v[25:0];
   end
  end
 endfunction
 function automatic[4:0] highest_bit(input[30:0] value);
  reg[31:0] v;reg[4:0] h;
  begin
   v={1'b0,value};h=0;
   if(|v[31:16])begin v=v>>16;h[4]=1;end
   if(|v[15:8])begin v=v>>8;h[3]=1;end
   if(|v[7:4])begin v=v>>4;h[2]=1;end
   if(|v[3:2])begin v=v>>2;h[1]=1;end
   if(v[1])h[0]=1;
   highest_bit=h;
  end
 endfunction
 function automatic[31:0] probability_float(input[30:0] v,input[4:0] h);
  reg[23:0] significand;reg[24:0] rounded;reg guard_bit,sticky;reg[7:0] exponent;
  begin
   guard_bit=0;sticky=0;significand=0;exponent=8'd97+{3'd0,h};
   case(h)
    24:begin significand=v>>1;guard_bit=v[0];end
    25:begin significand=v>>2;guard_bit=v[1];sticky=|v[0:0];end
    26:begin significand=v>>3;guard_bit=v[2];sticky=|v[1:0];end
    27:begin significand=v>>4;guard_bit=v[3];sticky=|v[2:0];end
    28:begin significand=v>>5;guard_bit=v[4];sticky=|v[3:0];end
    29:begin significand=v>>6;guard_bit=v[5];sticky=|v[4:0];end
    30:begin significand=v>>7;guard_bit=v[6];sticky=|v[5:0];end
    default:significand=v<<(5'd23-h);
   endcase
   rounded={1'b0,significand}+(guard_bit&&(sticky||significand[0]));
   if(v==0)probability_float=0;
   else if(rounded[24])probability_float={1'b0,exponent+8'd1,23'd0};
   else probability_float={1'b0,exponent,rounded[22:0]};
  end
 endfunction
 wire[25:0] fixed_magnitude=magnitude_q20(gate_value);
 wire mul_in_ready,mul_out_valid;
 wire[31:0] mul_result;
 gateup_fp_mul multiplier(.clk(clk),.rst_n(rst_n),
  .a(state==M1?gate_reg:silu_value),.b(state==M1?sigmoid_float:up_reg),
  .in_valid(state==M1||state==M2),.in_ready(mul_in_ready),
  .result(mul_result),.out_valid(mul_out_valid),.out_ready(state==W1||state==W2));
 assign in_ready=state==IDLE;
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=IDLE;out_valid<=0;result<=0;gate_reg<=0;up_reg<=0;sigmoid_float<=0;
   silu_value<=0;index<=0;fraction<=0;negative<=0;lower<=0;upper<=0;probability<=0;
   difference<=0;base_value<=0;positive_probability<=0;interpolation_product<=0;highest<=0;
  end else case(state)
   IDLE:if(in_valid)begin
    gate_reg<=gate_value;up_reg<=up_value;negative<=gate_value[31];
    index<=fixed_magnitude[25:12];fraction<=fixed_magnitude[11:0];state<=ROM;
   end
   ROM:begin lower<=sigmoid_rom[index];upper<=sigmoid_rom[index<8192?index+1:index];state<=DIFF;end
   DIFF:begin difference<=upper-lower;base_value<=lower;state<=PRODUCT;end
   PRODUCT:begin interpolation_product<=difference*fraction;state<=SUM;end
   SUM:begin positive_probability<=base_value+interpolation_product[42:12]+interpolation_product[11];state<=NEGATE;end
   NEGATE:begin probability<=negative?(31'd1073741824-positive_probability):positive_probability;state<=FIND;end
   FIND:begin highest<=highest_bit(probability);state<=CONVERT;end
   CONVERT:begin sigmoid_float<=probability_float(probability,highest);state<=M1;end
   M1:if(mul_in_ready)state<=W1;
   W1:if(mul_out_valid)begin silu_value<=mul_result;state<=M2;end
   M2:if(mul_in_ready)state<=W2;
   W2:if(mul_out_valid)begin result<=mul_result;out_valid<=1;state<=HOLD;end
   HOLD:if(out_ready)begin out_valid<=0;state<=IDLE;end
   default:state<=IDLE;
  endcase
 end
endmodule
