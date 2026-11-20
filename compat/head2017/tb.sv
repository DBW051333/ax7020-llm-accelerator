`timescale 1ns/1ps
module tb_head;
    localparam INPUT_WORDS=4048, OUTPUT_WORDS=32;
    reg clk=0, rst_n=0;
    always #6 clk=!clk;
    reg [63:0] input_words[0:INPUT_WORDS-1];
    reg [64:0] expected[0:OUTPUT_WORDS-1];
    reg [63:0] data=0;
    reg valid=0, last=0, out_ready=0, consumed=0;
    wire ready, out_valid, out_last;
    wire [63:0] result;
    integer sent=0, received=0, cycles=0, seed=123;
    head_lane dut(clk,rst_n,data,valid,last,ready,result,out_valid,out_last,out_ready,);
    initial begin
        $readmemh("input.hex",input_words);
        $readmemh("output.hex",expected);
        repeat(5) @(negedge clk);
        rst_n=1;
    end
    always @(negedge clk) if (rst_n) begin
        if (!valid || consumed) begin
            valid=sent<INPUT_WORDS && ($urandom(seed)%17!=0);
            if (valid) begin data=input_words[sent]; last=(sent%233==0); end
        end
        out_ready=(cycles%321<286) && ($urandom(seed)%7!=0);
    end
    always @(posedge clk) if (rst_n) begin
        cycles=cycles+1;
        consumed=valid && ready;
        if (consumed) sent=sent+1;
        if (out_valid && out_ready) begin
            if ({out_last,result} !== expected[received])
                $fatal(1,"Mismatch row %d got %h expected %h", received,{out_last,result},expected[received]);
            received=received+1;
            if(received==OUTPUT_WORDS) begin
                if(sent!=INPUT_WORDS) $fatal(1,"Wrong input count %d",sent);
                $display("HEAD-SIM-PASS rows=%d words=%d cycles=%d",received,sent,cycles);
                $finish;
            end
        end
        if (cycles>20000) $fatal(1,"Timeout rows=%d sent=%d",received,sent);
    end
endmodule
