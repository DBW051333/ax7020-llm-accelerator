"""Generate an exact integer oracle for FP16-scaled dot products."""
from pathlib import Path
import random
import sys

out=Path(sys.argv[1])
rng=random.Random(200125)
rows=[]
rows += [[(524288,0x7bff,0x7bff),(-524288,0x7bff,0x7bff),(1,1,1)]]
rows += [[(524288,0x7bff,0x7bff)], [(-524288,0x7bff,0x7bff)], [(1,0x8001,1)], [(0,1,1)]]
scales=[0,1,0x03ff,0x0400,0x3800,0x3c00,0x7bff,0x8001,0x83ff,0xbc00,0xfbff]
for i in range(507):
    row=[]
    for j in range(1+i%8):
        pair=[rng.choice(scales) if i%2 else rng.randrange(0x7c00) | (rng.randrange(2)<<15) for _ in range(2)]
        row.append((rng.randint(-524288,524288),*pair))
    rows.append(row)

def term(dot,w,x):
    def decode(h):
        e=(h>>10)&31
        m=(1024 if e else 0)+(h&1023)
        return (-m if h&32768 else m) << (max(e,1)-1)
    return dot*decode(w)*decode(x)

def bits(value):
    if not value:
        return 0
    m=abs(value)
    h=m.bit_length()-1
    shift=h-23
    if shift>0:
        mantissa,tail=divmod(m,1<<shift)
        half=1<<(shift-1)
        mantissa+=tail>half or (tail==half and mantissa&1)
    else:
        mantissa=m<<(-shift)
    return ((value<0)<<31) + ((h+78)<<23) + mantissa

stim=[]
gold=[]
for row in rows:
    for i,(dot,w,x) in enumerate(row):
        stim.append(f'{(1<<65 if i==0 else 0)+(1<<64 if i==len(row)-1 else 0)+((dot&0xffffffff)<<32)+(w<<16)+x:017x}')
    gold.append(f'{bits(sum(term(*block) for block in row)):08x}')
(out/'range.hex').write_text('\n'.join(stim)+'\n')
(out/'range_expected.hex').write_text('\n'.join(gold)+'\n')
(out/'tb_range.sv').write_text('''`timescale 1ns/1ps
module tb_range;
localparam N=@N@, R=@R@;
reg clk=0,rst=0;
always #2.5 clk=~clk;
reg [65:0] feed[0:N-1];
reg [31:0] gold[0:R-1];
integer n=0,r=0,cycles=0;
wire [65:0] word=n<N ? feed[n] : 66'd0;
wire ready,valid;
wire [31:0] result;
wire in_valid=n<N && (cycles%5)!=1;
wire out_ready=cycles%13>4;
q58_scaled_accum dut(clk,rst,word[63:32],word[31:16],word[15:0],word[65],word[64],in_valid,
                     ready,result,valid,out_ready);
initial begin
    $readmemh("range.hex",feed);
    $readmemh("range_expected.hex",gold);
    repeat(10) @(negedge clk);
    rst=1;
end
always @(posedge clk) if(rst) begin
    if (in_valid && ready) n<=n+1;
    if (valid && out_ready) begin
        if (result !== gold[r]) $fatal(1,"row %0d: %h != %h",r,result,gold[r]);
        r<=r+1;
    end
    if(r==R) begin
        if(n!=N) $fatal(1,"wrong input count");
        $display("SCALE-RANGE-PASS rows=%0d blocks=%0d",r,n);
        $finish;
    end
    if(cycles>20000) $fatal(1,"timeout rows=%0d",r);
    cycles<=cycles+1;
end
endmodule
'''.replace('@N@',str(len(stim))).replace('@R@',str(len(gold))))
